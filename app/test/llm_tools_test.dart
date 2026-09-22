/// LLM 层的**工具调用**协议：编码、分片聚合、以及"不支持时必须报错"。
///
/// ## 这里要守的几条
///
/// - **空 tools 时请求体里不能出现 `tools` 键**。既有的十来个纯文本调用点
///   全靠这一点不受影响 —— 多传一个服务商不认的字段就可能 400。
/// - **工具参数是分片发的**，必须按 `index` 归位、按顺序拼接。
///   少拼一片就是非法 JSON，而那种失败看起来很像"模型乱填参数"。
/// - **"没有正文"不等于失败**。模型决定调工具的那一轮一个字都不产出，
///   早先这里会抛"流式响应里没有文本内容"，工具功能会整个失效。
/// - **非 OpenAI 协议的 history 路径必须报错**。P4 起显式消息列表
///   （工具往返）在三家协议上都有真正的编码（见
///   `llm_p4_protocols_test.dart`），但 history 这条纯文本路不认工具
///   消息 —— 真出现说明消息链被写坏了，要拦下来。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/services/llm/llm_client.dart';
import 'package:kaoyan_math_agent/services/llm/provider_registry.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 脚手架
// ─────────────────────────────────────────────────────────────────────────────

class _Http extends HttpAdapter {
  final List<HttpResponse> sends;
  final List<List<Object>> rounds;
  final List<HttpRequest> requests = [];
  int _i = 0;

  _Http({this.sends = const [], this.rounds = const []});

  @override
  Future<HttpResponse> send(HttpRequest request) async {
    requests.add(request);
    final i = _i < sends.length ? _i : sends.length - 1;
    _i++;
    return sends[i];
  }

  @override
  Stream<HttpStreamChunk> sendStream(HttpRequest request) async* {
    requests.add(request);
    final script = rounds[_i < rounds.length ? _i : rounds.length - 1];
    _i++;
    for (final item in script) {
      if (item is HttpStreamChunk) yield item;
      if (item is Exception) throw item;
    }
  }
}

LlmClient _client(
  HttpAdapter http, {
  String provider = 'deepseek',
  String model = 'deepseek-chat',
}) =>
    LlmClient(
      config: LlmConfig(
        providerId: provider,
        apiKey: 'k',
        modelOverride: model,
      ),
      http: http,
      sleep: (_) async {},
    );

const _tool = ToolSpec(
  name: 'query_wrong_problems',
  description: '查错题',
  parameters: {
    'type': 'object',
    'properties': {
      'limit': {'type': 'integer'},
    },
  },
);

String _sse(String payload) => 'data: $payload\n\n';

HttpStreamChunk _c(String text) => HttpStreamChunk(statusCode: 200, text: text);

Map<String, dynamic> _bodyOf(HttpRequest r) =>
    jsonDecode(r.body ?? '{}') as Map<String, dynamic>;

List<Map<String, dynamic>> _messagesOf(HttpRequest r) =>
    (_bodyOf(r)['messages'] as List).cast<Map<String, dynamic>>();

void main() {
  // ───────────────────────────────────────────────────────────────────────────
  group('ToolSpec 编码', () {
    test('按 OpenAI 的 function 规格编码', () {
      final j = _tool.toOpenAiJson();
      expect(j['type'], 'function');
      final fn = j['function'] as Map;
      expect(fn['name'], 'query_wrong_problems');
      expect(fn['description'], '查错题');
      expect((fn['parameters'] as Map)['type'], 'object');
    });

    test('默认参数是"空对象 schema"，不是 null', () {
      const t = ToolSpec(name: 'x', description: 'y');
      final params = (_tool.toOpenAiJson()['function'] as Map)['parameters'];
      expect(params, isA<Map<String, dynamic>>(),
          reason: 'parameters 为 null 会让部分服务商直接 400');
      expect((t.toOpenAiJson()['function'] as Map)['parameters'],
          isA<Map<String, dynamic>>());
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('请求体：tools 的有无', () {
    test('没有工具时请求体里**不存在** tools 键', () async {
      final http = _Http(sends: [
        HttpResponse(statusCode: 200, body: jsonEncode({
          'choices': [
            {
              'message': {'content': '答'},
            }
          ],
        })),
      ]);
      await _client(http).chat(
        const ChatRequest(system: 's', user: 'u'),
      );

      expect(_bodyOf(http.requests.single).containsKey('tools'), isFalse,
          reason: '多传这个键会让不认识它的兼容端点直接 400');
    });

    test('有工具时 tools 与 messages 一起发出去', () async {
      final http = _Http(sends: [
        HttpResponse(statusCode: 200, body: jsonEncode({
          'choices': [
            {
              'message': {'content': '答'},
            }
          ],
        })),
      ]);
      await _client(http).chat(
        const ChatRequest(system: 's', user: 'u', tools: [_tool]),
      );

      final tools = _bodyOf(http.requests.single)['tools'] as List;
      expect(tools.length, 1);
      expect(((tools.single as Map)['function'] as Map)['name'],
          'query_wrong_problems');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('请求体：工具往返的消息', () {
    test('显式 messages 取代 history + user，且 system 仍在最前', () async {
      final http = _Http(sends: [
        HttpResponse(statusCode: 200, body: jsonEncode({
          'choices': [
            {
              'message': {'content': '答'},
            }
          ],
        })),
      ]);
      await _client(http).chat(ChatRequest(
        system: 'sys',
        user: '这个会被忽略',
        history: const [ChatMessage.user('也不该出现')],
        messages: [
          const ChatMessage.user('真正的问题'),
          ChatMessage.assistant('', toolCalls: [
            ToolCall(id: 'c1', name: 'query_wrong_problems', arguments: '{}'),
          ]),
          const ChatMessage.tool(toolCallId: 'c1', content: '{"matched":1}'),
        ],
      ));

      final msgs = _messagesOf(http.requests.single);
      expect(msgs.length, 4);
      expect(msgs[0], {'role': 'system', 'content': 'sys'});
      expect(msgs[1]['content'], '真正的问题');
      expect(msgs[2]['role'], 'assistant');
      expect(msgs[2].containsKey('tool_calls'), isTrue);
      expect(msgs[3]['role'], 'tool');
      expect(msgs[3]['tool_call_id'], 'c1');
      // 被忽略的那两条不能混进来
      expect(
        msgs.any((m) => m['content'] == '这个会被忽略' || m['content'] == '也不该出现'),
        isFalse,
      );
    });

    test('带工具调用的助手消息：content 键必须在（哪怕为空）', () async {
      final http = _Http(sends: [
        HttpResponse(statusCode: 200, body: jsonEncode({
          'choices': [
            {
              'message': {'content': '答'},
            }
          ],
        })),
      ]);
      await _client(http).chat(ChatRequest(
        system: 's',
        user: '',
        messages: [
          ChatMessage.assistant('', toolCalls: [
            ToolCall(id: 'c1', name: 'n', arguments: '{"a":1}'),
          ]),
        ],
      ));

      final m = _messagesOf(http.requests.single)[1];
      expect(m.containsKey('content'), isTrue,
          reason: '缺 content 键会被当成一条不完整的助手消息');
      final call = (m['tool_calls'] as List).single as Map;
      expect(call['id'], 'c1');
      expect(call['type'], 'function');
      expect((call['function'] as Map)['arguments'], '{"a":1}');
    });

    test('显式 messages 与附件不能同时给（拒绝而不是悄悄丢一个）', () async {
      final http = _Http(sends: []);
      await expectLater(
        _client(http).chat(ChatRequest(
          system: 's',
          user: 'u',
          messages: const [ChatMessage.user('x')],
          attachments: [
            ChatAttachment(
              kind: ChatAttachmentKind.image,
              mimeType: 'image/png',
              bytes: Uint8List.fromList(const [1, 2, 3]),
            ),
          ],
        )),
        throwsA(isA<LlmException>()),
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('协议守卫：非 OpenAI 协议的 history 路径不能回灌工具', () {
    test('Anthropic + 历史里有工具消息 → 报错（那是已经在对话里的内容）', () async {
      final http = _Http(sends: []);
      await expectLater(
        _client(http, provider: 'anthropic', model: 'claude-3-5-sonnet').chat(
          const ChatRequest(
            system: 's',
            user: 'u',
            history: [
              ChatMessage.tool(toolCallId: 'c1', content: '{}'),
            ],
          ),
        ),
        throwsA(isA<LlmException>()),
      );
      expect(http.requests, isEmpty, reason: '拦在编码前，请求根本不该发出去');
    });

    test('supportsTools：已知服务商都为真，未知服务商为假', () {
      // P4 起三家协议都实现了工具（形状各异，见 llm_p4_protocols_test.dart）
      expect(_client(_Http()).supportsTools, isTrue);
      expect(
        _client(_Http(), provider: 'anthropic', model: 'claude-3-5-sonnet')
            .supportsTools,
        isTrue,
      );
      expect(
        _client(_Http(), provider: 'gemini', model: 'gemini-2.0-flash')
            .supportsTools,
        isTrue,
      );
      expect(_client(_Http(), provider: 'nope').supportsTools, isFalse);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('流式：工具调用分片聚合', () {
    test('参数分片按 index 拼接成完整 JSON', () async {
      final http = _Http(rounds: [
        [
          _c(_sse(jsonEncode({
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'call_1',
                      'type': 'function',
                      'function': {
                        'name': 'query_wrong_problems',
                        'arguments': '{"kp":',
                      },
                    }
                  ],
                }
              }
            ],
          }))),
          _c(_sse(jsonEncode({
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'function': {'arguments': '"中值定理"}'},
                    }
                  ],
                }
              }
            ],
          }))),
          _c(_sse(jsonEncode({
            'choices': [
              {'delta': <String, dynamic>{}, 'finish_reason': 'tool_calls'}
            ],
          }))),
        ],
      ]);

      final events = await _client(http)
          .chatStream(const ChatRequest(system: 's', user: 'u', tools: [_tool]))
          .toList();

      final done = events.whereType<ChatDone>().single;
      expect(done.response.toolCalls.length, 1);
      final call = done.response.toolCalls.single;
      expect(call.id, 'call_1');
      expect(call.name, 'query_wrong_problems');
      expect(call.arguments, '{"kp":"中值定理"}');
      expect(call.args['kp'], '中值定理',
          reason: '拼错一片就解析不出来（会退化成"模型乱填参数"的假象）');
      expect(done.response.finishReason, 'tool_calls');
    });

    test('一轮里的多个工具按 index 各归各位，不能串味', () async {
      final http = _Http(rounds: [
        [
          _c(_sse(jsonEncode({
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'a',
                      'function': {'name': 'query_profile', 'arguments': '{"top_kp":'},
                    },
                    {
                      'index': 1,
                      'id': 'b',
                      'function': {'name': 'query_due_reviews', 'arguments': '{"limit":'},
                    },
                  ],
                }
              }
            ],
          }))),
          _c(_sse(jsonEncode({
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {'index': 1, 'function': {'arguments': '5}'}},
                    {'index': 0, 'function': {'arguments': '3}'}},
                  ],
                }
              }
            ],
          }))),
          _c(_sse(jsonEncode({
            'choices': [
              {'delta': <String, dynamic>{}, 'finish_reason': 'tool_calls'}
            ],
          }))),
        ],
      ]);

      final done = (await _client(http)
              .chatStream(const ChatRequest(system: 's', user: 'u', tools: [_tool]))
              .toList())
          .whereType<ChatDone>()
          .single;

      expect(done.response.toolCalls.length, 2);
      expect(done.response.toolCalls[0].name, 'query_profile');
      expect(done.response.toolCalls[0].arguments, '{"top_kp":3}');
      expect(done.response.toolCalls[1].name, 'query_due_reviews');
      expect(done.response.toolCalls[1].arguments, '{"limit":5}');
    });

    test('没有正文但**有**工具调用时不该报错', () async {
      final http = _Http(rounds: [
        [
          _c(_sse(jsonEncode({
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'c',
                      'function': {'name': 'query_profile', 'arguments': '{}'},
                    }
                  ],
                }
              }
            ],
          }))),
          _c(_sse(jsonEncode({
            'choices': [
              {'delta': <String, dynamic>{}, 'finish_reason': 'tool_calls'}
            ],
          }))),
        ],
      ]);

      final events = await _client(http)
          .chatStream(const ChatRequest(system: 's', user: 'u', tools: [_tool]))
          .toList();

      final done = events.whereType<ChatDone>().single;
      expect(done.response.text, '');
      expect(done.response.wantsTools, isTrue);
    });

    test('正文与工具都没有时仍然报错（那是真的坏了）', () async {
      final http = _Http(rounds: [
        [
          _c(_sse(jsonEncode({
            'choices': [
              {'delta': <String, dynamic>{}, 'finish_reason': 'stop'}
            ],
          }))),
        ],
      ]);

      await expectLater(
        _client(http)
            .chatStream(const ChatRequest(system: 's', user: 'u', tools: [_tool]))
            .toList(),
        throwsA(isA<LlmException>()),
      );
    });

    test('分片中途断了：重试仍然允许（工具分片用户看不见）', () async {
      final http = _Http(rounds: [
        [
          _c(_sse(jsonEncode({
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'stale',
                      'function': {'name': 'query_profile', 'arguments': '{"a"'},
                    }
                  ],
                }
              }
            ],
          }))),
          const HttpTransportException('断了'),
        ],
        [
          _c(_sse(jsonEncode({
            'choices': [
              {
                'delta': {'content': '换了条路答你'},
              }
            ],
          }))),
          _c(_sse(jsonEncode({
            'choices': [
              {'delta': <String, dynamic>{}, 'finish_reason': 'stop'}
            ],
          }))),
        ],
      ]);

      final done = (await _client(http)
              .chatStream(const ChatRequest(system: 's', user: 'u', tools: [_tool]))
              .toList())
          .whereType<ChatDone>()
          .single;

      expect(http.requests.length, 2);
      // 第一次尝试里的残缺分片绝不能串到第二次
      expect(done.response.toolCalls, isEmpty);
      expect(done.response.text, '换了条路答你');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('非流式也要认工具', () {
    test('只有 tool_calls 没有正文时不该报错', () async {
      final http = _Http(sends: [
        HttpResponse(statusCode: 200, body: jsonEncode({
          'choices': [
            {
              'message': {
                'content': null,
                'tool_calls': [
                  {
                    'id': 'call_9',
                    'type': 'function',
                    'function': {
                      'name': 'query_wrong_problems',
                      'arguments': '{"limit":5}',
                    },
                  }
                ],
              },
              'finish_reason': 'tool_calls',
            }
          ],
        })),
      ]);

      final resp = await _client(http).chat(
        const ChatRequest(system: 's', user: 'u', tools: [_tool]),
      );
      expect(resp.text, '');
      expect(resp.toolCalls.single.id, 'call_9');
      expect(resp.toolCalls.single.args['limit'], 5);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('ToolCall 的参数解析', () {
    test('空字符串当成"没有参数"，不算解析失败', () {
      final c = ToolCall(id: 'x', name: 'n', arguments: '');
      expect(c.isParsed, isTrue);
      expect(c.args, isEmpty);
    });

    test('非法 JSON：保留原文，args 为空（不能拿半截参数去查询）', () {
      final c = ToolCall(id: 'x', name: 'n', arguments: '{"a":');
      expect(c.isParsed, isFalse);
      expect(c.args, isEmpty);
      expect(c.arguments, '{"a":', reason: '原文是排查的唯一线索，不能丢');
    });

    test('被包成数组时取第一个对象', () {
      final c = ToolCall(id: 'x', name: 'n', arguments: '[{"limit":7}]');
      expect(c.isParsed, isTrue);
      expect(c.args['limit'], 7);
    });

    test('顶层是标量时算解析失败', () {
      final c = ToolCall(id: 'x', name: 'n', arguments: '42');
      expect(c.isParsed, isFalse);
    });
  });
}
