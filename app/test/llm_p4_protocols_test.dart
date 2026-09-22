/// Anthropic 与 Gemini 两家的协议适配（P4）：请求编码、流式分帧、工具往返。
///
/// ## 为什么这两个协议值得一份专门的测试文件
///
/// 它们的失败方式和 OpenAI 完全不同，而且**大多不报错**：
///
/// - Anthropic 的消息是**内容块数组**：把文本发成空 `text` 块会整条 400；
///   工具结果不是独立角色，而是下一条 user 消息里的 `tool_result` 块。
/// - Gemini 的助手角色叫 `model`；`functionResponse.response` 只收
///   **JSON 对象** —— 而我们的工具返回的是 JSON 字符串，不解一层就 400。
/// - 两家的流里都可能**中途夹 error 事件**。忽略它，上层只会看到
///   "流结束了但没内容"，真正的原因（过载 / Key 错）被吞掉。
///
/// ## 用量为什么取 max 合并
///
/// Anthropic 把输入 token 放在 `message_start`、输出放在
/// `message_delta`，两帧各给一半 —— 覆盖式合并会丢掉先到的那一半。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/services/llm/llm_client.dart';
import 'package:kaoyan_math_agent/services/llm/provider_registry.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 脚手架
// ─────────────────────────────────────────────────────────────────────────────

/// 同时支持 send / sendStream 的假适配器。
class _FakeHttp extends HttpAdapter {
  final List<HttpResponse> sends;
  final List<List<Object>> rounds;
  final List<HttpRequest> requests = [];
  int _i = 0;

  _FakeHttp({this.sends = const [], this.rounds = const []});

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
      if (item is HttpStreamChunk) {
        yield item;
      } else if (item is Exception) {
        throw item;
      }
    }
  }
}

LlmClient _client(
  _FakeHttp http, {
  required String provider,
  required String model,
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
      'kp': {'type': 'string'},
    },
  },
);

String _sse(String payload) => 'data: $payload\n\n';

HttpStreamChunk _chunk(String text) =>
    HttpStreamChunk(statusCode: 200, text: text);

Map<String, dynamic> _bodyOf(HttpRequest r) =>
    jsonDecode(r.body ?? '{}') as Map<String, dynamic>;

List<Map<String, dynamic>> _messagesOf(HttpRequest r) =>
    (_bodyOf(r)['messages'] as List).cast<Map<String, dynamic>>();

List<Map<String, dynamic>> _contentsOf(HttpRequest r) =>
    (_bodyOf(r)['contents'] as List).cast<Map<String, dynamic>>();

/// 一条"assistant 要调工具 → tool 回结果"的往返消息链。
List<ChatMessage> _toolRound({String result = '{"found":1}'}) => [
      const ChatMessage.user('查一下中值定理的错题'),
      ChatMessage.assistant(
        '',
        toolCalls: [
          ToolCall(id: 't1', name: 'query_wrong_problems',
              arguments: '{"kp":"中值定理"}'),
        ],
      ),
      ChatMessage.tool(toolCallId: 't1', content: result),
    ];

Future<List<ChatStreamEvent>> _collect(LlmClient client, ChatRequest req) async {
  final out = <ChatStreamEvent>[];
  await for (final e in client.chatStream(req)) {
    out.add(e);
  }
  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// Anthropic：请求编码
// ─────────────────────────────────────────────────────────────────────────────

final anthropicResp = HttpResponse(
  statusCode: 200,
  body: jsonEncode({
    'content': [
      {'type': 'text', 'text': '答'},
    ],
    'usage': {'input_tokens': 5, 'output_tokens': 2},
    'stop_reason': 'end_turn',
  }),
);

void main() {
  group('Anthropic：请求编码', () {
    test('纯文本对话：system 在顶层，messages 是字符串 content，max_tokens 必填', () async {
      final http = _FakeHttp(sends: [anthropicResp]);
      await _client(http, provider: 'anthropic', model: 'claude-3-5-sonnet')
          .chat(const ChatRequest(system: '你是助手', user: '你好'));

      final body = _bodyOf(http.requests.single);
      expect(body['system'], '你是助手');
      expect(body['max_tokens'], 4096, reason: 'Anthropic 的 max_tokens 是必填');
      expect(body.containsKey('tools'), isFalse);
      final messages = _messagesOf(http.requests.single);
      expect(messages, [
        {'role': 'user', 'content': '你好'},
      ]);
    });

    test('流式：body 带 stream，URL 不变', () async {
      final http = _FakeHttp(rounds: [
        [
          _chunk(_sse(jsonEncode({
            'type': 'message_start',
            'message': {'usage': {'input_tokens': 3, 'output_tokens': 1}},
          }))),
          _chunk(_sse(jsonEncode({
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'text_delta', 'text': '好'},
          }))),
          _chunk(_sse(jsonEncode({
            'type': 'message_delta',
            'delta': {'stop_reason': 'end_turn'},
            'usage': {'output_tokens': 6},
          }))),
          _chunk(_sse(jsonEncode({'type': 'message_stop'}))),
        ],
      ]);
      await _collect(
        _client(http, provider: 'anthropic', model: 'claude-3-5-sonnet'),
        const ChatRequest(system: 's', user: 'u'),
      );

      expect(http.requests.single.url, endsWith('/messages'));
      expect(_bodyOf(http.requests.single)['stream'], isTrue);
    });

    test('工具声明用 input_schema，而不是 OpenAI 的 parameters', () async {
      final http = _FakeHttp(sends: [anthropicResp]);
      await _client(http, provider: 'anthropic', model: 'claude-3-5-sonnet')
          .chat(const ChatRequest(system: 's', user: 'u', tools: [_tool]));

      final tools = (_bodyOf(http.requests.single)['tools'] as List).single
          as Map<String, dynamic>;
      expect(tools['name'], 'query_wrong_problems');
      expect(tools.containsKey('input_schema'), isTrue,
          reason: '写成 parameters 不会 400，而是模型收不到工具然后开始编');
      expect((tools['input_schema'] as Map)['type'], 'object');
    });

    test('工具往返：tool_use 块进 assistant，结果合并成一条 user 的 tool_result', () async {
      final http = _FakeHttp(sends: [anthropicResp]);
      await _client(http, provider: 'anthropic', model: 'claude-3-5-sonnet')
          .chat(ChatRequest(
        system: 's',
        user: '',
        messages: _toolRound(),
      ));

      final messages = _messagesOf(http.requests.single);
      expect(messages, hasLength(3), reason: 'assistant 与 tool 结果各占一条');

      final assistant = messages[1];
      final blocks = (assistant['content'] as List).cast<Map<String, dynamic>>();
      expect(assistant['role'], 'assistant');
      expect(blocks, hasLength(1),
          reason: '空正文不能发 text 块（Anthropic 拒绝空文本块）');
      expect(blocks.single['type'], 'tool_use');
      expect(blocks.single['id'], 't1');
      expect((blocks.single['input'] as Map)['kp'], '中值定理',
          reason: 'input 必须是对象，不是参数 JSON 字符串');

      final result = messages[2];
      expect(result['role'], 'user',
          reason: '工具结果不是独立角色，挂在下一条 user 消息里');
      final resultBlocks =
          (result['content'] as List).cast<Map<String, dynamic>>();
      expect(resultBlocks.single['type'], 'tool_result');
      expect(resultBlocks.single['tool_use_id'], 't1');
      expect(resultBlocks.single.containsKey('is_error'), isFalse,
          reason: '成功的结果不该带失败标记');
    });

    test('连续两条工具结果合并进同一条 user 消息', () async {
      final http = _FakeHttp(sends: [anthropicResp]);
      await _client(http, provider: 'anthropic', model: 'claude-3-5-sonnet')
          .chat(ChatRequest(
        system: 's',
        user: '',
        messages: [
          ..._toolRound(),
          const ChatMessage.tool(toolCallId: 't2', content: '{}'),
        ],
      ));

      final messages = _messagesOf(http.requests.single);
      expect(messages, hasLength(3), reason: '两条 tool 必须并成一条 user —— '
          'Anthropic 要求 user/assistant 交替，拆两条会 400');
      final blocks =
          (messages[2]['content'] as List).cast<Map<String, dynamic>>();
      expect(blocks, hasLength(2));
      expect(blocks.map((b) => b['tool_use_id']), ['t1', 't2']);
    });

    test('失败的工具结果带 is_error 标记', () async {
      final http = _FakeHttp(sends: [anthropicResp]);
      await _client(http, provider: 'anthropic', model: 'claude-3-5-sonnet')
          .chat(const ChatRequest(
        system: 's',
        user: '',
        messages: [
          ChatMessage.tool(
            toolCallId: 't9',
            content: '查询失败：本体未载入',
            toolError: true,
          ),
        ],
      ));

      final blocks = (_messagesOf(http.requests.single).first['content']
              as List)
          .cast<Map<String, dynamic>>();
      expect(blocks.single['is_error'], isTrue,
          reason: '模型看到 is_error 会解释失败，而不是把报错文本当查询结果继续编');
    });

    test('有正文 + 要调工具：text 块在前、tool_use 在后', () async {
      final http = _FakeHttp(sends: [anthropicResp]);
      await _client(http, provider: 'anthropic', model: 'claude-3-5-sonnet')
          .chat(ChatRequest(
        system: 's',
        user: '',
        messages: [
          ChatMessage.assistant('我先查一下', toolCalls: [
            ToolCall(id: 't1', name: 'q', arguments: '{}'),
          ]),
        ],
      ));

      final blocks = (_messagesOf(http.requests.single).first['content']
              as List)
          .cast<Map<String, dynamic>>();
      expect(blocks.map((b) => b['type']), ['text', 'tool_use']);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('Anthropic：流式分帧', () {
    const req = ChatRequest(system: 's', user: 'u');

    test('文本按事件逐段吐出；输入输出 token 各在两帧，合并后都记到', () async {
      final http = _FakeHttp(rounds: [
        [
          _chunk(_sse(jsonEncode({
            'type': 'message_start',
            'message': {'usage': {'input_tokens': 25, 'output_tokens': 1}},
          }))),
          _chunk(_sse(jsonEncode({
            'type': 'content_block_start',
            'index': 0,
            'content_block': {'type': 'text'},
          }))),
          _chunk(_sse(jsonEncode({
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'text_delta', 'text': '洛'},
          }))),
          _chunk(_sse(jsonEncode({
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'text_delta', 'text': '必达'},
          }))),
          _chunk(_sse(jsonEncode({'type': 'content_block_stop', 'index': 0}))),
          _chunk(_sse(jsonEncode({
            'type': 'message_delta',
            'delta': {'stop_reason': 'end_turn'},
            'usage': {'output_tokens': 15},
          }))),
          _chunk(_sse(jsonEncode({'type': 'message_stop'}))),
        ],
      ]);

      final events = await _collect(
        _client(http, provider: 'anthropic', model: 'claude-3-5-sonnet'),
        req,
      );

      expect(
        events.whereType<ChatDelta>().map((d) => d.text),
        ['洛', '必达'],
      );
      final done = events.whereType<ChatDone>().single;
      expect(done.response.text, '洛必达');
      expect(done.response.usage.inputTokens, 25,
          reason: '输入 token 在 message_start 里，覆盖式合并会把它丢掉');
      expect(done.response.usage.outputTokens, 15);
      expect(done.response.finishReason, 'end_turn');
      expect(done.response.truncated, isFalse);
    });

    test('工具调用：参数分片按内容块序号拼接成完整 JSON', () async {
      final http = _FakeHttp(rounds: [
        [
          _chunk(_sse(jsonEncode({
            'type': 'content_block_start',
            'index': 0,
            'content_block': {
              'type': 'tool_use',
              'id': 'toolu_1',
              'name': 'query_wrong_problems',
              'input': <String, dynamic>{},
            },
          }))),
          _chunk(_sse(jsonEncode({
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'input_json_delta', 'partial_json': '{"kp":'},
          }))),
          _chunk(_sse(jsonEncode({
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'input_json_delta', 'partial_json': '"中值定理"}'},
          }))),
          _chunk(_sse(jsonEncode({'type': 'content_block_stop', 'index': 0}))),
          _chunk(_sse(jsonEncode({
            'type': 'message_delta',
            'delta': {'stop_reason': 'tool_use'},
            'usage': {'output_tokens': 20},
          }))),
        ],
      ]);

      final events = await _collect(
        _client(http, provider: 'anthropic', model: 'claude-3-5-sonnet'),
        req,
      );

      final done = events.whereType<ChatDone>().single;
      expect(done.response.wantsTools, isTrue, reason: '决定调工具的那一轮没有正文');
      final call = done.response.toolCalls.single;
      expect(call.id, 'toolu_1');
      expect(call.name, 'query_wrong_problems');
      expect(call.arguments, '{"kp":"中值定理"}');
      expect(done.response.finishReason, 'tool_use');
    });

    test('流中途的 error 事件要抛出来，不能吞成"没有文本内容"', () async {
      final http = _FakeHttp(rounds: [
        [
          _chunk(_sse(jsonEncode({
            'type': 'error',
            'error': {'type': 'overloaded_error', 'message': 'Overloaded'},
          }))),
        ],
      ]);

      Object? err;
      try {
        await _collect(
          _client(http, provider: 'anthropic', model: 'claude-3-5-sonnet'),
          req,
        );
      } catch (e) {
        err = e;
      }

      expect(err, isA<LlmException>());
      expect((err! as LlmException).message, contains('Overloaded'),
          reason: '真正的原因（服务过载）必须留在报错里');
    });

    test('ping 与 thinking 增量不算正文', () async {
      final http = _FakeHttp(rounds: [
        [
          _chunk(_sse(jsonEncode({'type': 'ping'}))),
          _chunk(_sse(jsonEncode({
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'thinking_delta', 'thinking': '内心独白'},
          }))),
          _chunk(_sse(jsonEncode({
            'type': 'content_block_delta',
            'index': 1,
            'delta': {'type': 'text_delta', 'text': '正文'},
          }))),
          _chunk(_sse(jsonEncode({
            'type': 'message_delta',
            'delta': {'stop_reason': 'end_turn'},
            'usage': {'output_tokens': 3},
          }))),
        ],
      ]);

      final events = await _collect(
        _client(http, provider: 'anthropic', model: 'claude-3-5-sonnet'),
        req,
      );

      expect(events.whereType<ChatDelta>().map((d) => d.text), ['正文'],
          reason: '把 thinking 当正文吐出去，用户会看到模型的内心独白');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Gemini：请求编码
  // ─────────────────────────────────────────────────────────────────────────────

  final geminiResp = HttpResponse(
    statusCode: 200,
    body: jsonEncode({
      'candidates': [
        {
          'content': {
            'parts': [
              {'text': '答'},
            ],
            'role': 'model',
          },
          'finishReason': 'STOP',
        }
      ],
      'usageMetadata': {
        'promptTokenCount': 5,
        'candidatesTokenCount': 2,
        'totalTokenCount': 7,
      },
    }),
  );

  group('Gemini：请求编码', () {
    test('纯文本：助手角色是 model，非流式 URL 是 generateContent', () async {
      final http = _FakeHttp(sends: [geminiResp]);
      await _client(http, provider: 'gemini', model: 'gemini-1.5-flash')
          .chat(const ChatRequest(
        system: '你是助手',
        user: '你好',
        history: [ChatMessage.assistant('上次说到哪了')],
      ));

      final url = http.requests.single.url;
      expect(url, contains(':generateContent'));
      expect(url, contains('key='));
      expect(url.contains('alt=sse'), isFalse, reason: '非流式不要 alt=sse');

      final contents = _contentsOf(http.requests.single);
      expect(contents, [
        {
          'role': 'model',
          'parts': [
            {'text': '上次说到哪了'},
          ],
        },
        {
          'role': 'user',
          'parts': [
            {'text': '你好'},
          ],
        },
      ]);
    });

    test('流式 URL：streamGenerateContent 且带 alt=sse', () async {
      final http = _FakeHttp(rounds: [
        [
          _chunk(_sse(jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': '好'},
                  ],
                  'role': 'model',
                },
              }
            ],
          }))),
        ],
      ]);
      await _collect(
        _client(http, provider: 'gemini', model: 'gemini-1.5-flash'),
        const ChatRequest(system: 's', user: 'u'),
      );

      expect(http.requests.single.url, contains(':streamGenerateContent?alt=sse'));
    });

    test('工具声明包在 functionDeclarations 里', () async {
      final http = _FakeHttp(sends: [geminiResp]);
      await _client(http, provider: 'gemini', model: 'gemini-1.5-flash')
          .chat(const ChatRequest(system: 's', user: 'u', tools: [_tool]));

      final tools = (_bodyOf(http.requests.single)['tools'] as List).single
          as Map<String, dynamic>;
      final decls =
          (tools['functionDeclarations'] as List).single as Map;
      expect(decls['name'], 'query_wrong_problems');
      expect((decls['parameters'] as Map)['type'], 'object');
    });

    test('工具往返：functionCall 进 model，结果按名字回 functionResponse', () async {
      final http = _FakeHttp(sends: [geminiResp]);
      await _client(http, provider: 'gemini', model: 'gemini-1.5-flash')
          .chat(ChatRequest(
        system: 's',
        user: '',
        messages: _toolRound(),
      ));

      final contents = _contentsOf(http.requests.single);
      expect(contents, hasLength(3));

      final call = (contents[1]['parts'] as List).single as Map;
      expect(contents[1]['role'], 'model');
      expect((call['functionCall'] as Map)['name'], 'query_wrong_problems');
      expect((call['functionCall'] as Map)['args'], {'kp': '中值定理'});

      final response = (contents[2]['parts'] as List).single as Map;
      expect(contents[2]['role'], 'user',
          reason: 'functionResponse 挂在 role:user 的 content 里（官方 REST 示例）');
      final fr = response['functionResponse'] as Map;
      expect(fr['name'], 'query_wrong_problems',
          reason: 'Gemini 按名字配对，名字必须来自前面的 functionCall');
      expect(fr['response'], {'found': 1},
          reason: 'response 只收对象 —— 工具返回的 JSON 字符串必须解一层');
    });

    test('结果不是 JSON 对象时包一层 result，别丢原文', () async {
      final http = _FakeHttp(sends: [geminiResp]);
      await _client(http, provider: 'gemini', model: 'gemini-1.5-flash')
          .chat(ChatRequest(
        system: 's',
        user: '',
        messages: _toolRound(result: '查询失败：本体未载入'),
      ));

      final fr = ((_contentsOf(http.requests.single)[2]['parts'] as List)
              .single as Map)['functionResponse'] as Map;
      expect(fr['response'], {'result': '查询失败：本体未载入'});
    });

    test('工具链断裂（前面没有声明这次调用的 assistant）要炸得说清楚', () async {
      final http = _FakeHttp(sends: [geminiResp]);
      await expectLater(
        _client(http, provider: 'gemini', model: 'gemini-1.5-flash').chat(
          const ChatRequest(
            system: 's',
            user: '',
            messages: [
              // 故意不放在 assistant(toolCall) 之后 —— 名字无从解析
              ChatMessage.tool(toolCallId: 'ghost', content: '{}'),
            ],
          ),
        ),
        throwsA(
          isA<LlmException>().having(
            (e) => e.message,
            'message',
            contains('ghost'),
          ),
        ),
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('Gemini：流式分帧', () {
    const req = ChatRequest(system: 's', user: 'u');

    test('文本逐段吐出；usageMetadata 累计值取 max；MAX_TOKENS 判为截断', () async {
      final http = _FakeHttp(rounds: [
        [
          _chunk(_sse(jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': '洛'},
                  ],
                  'role': 'model',
                },
              }
            ],
          }))),
          _chunk(_sse(jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': '必达法则'},
                  ],
                  'role': 'model',
                },
                'finishReason': 'MAX_TOKENS',
              }
            ],
            'usageMetadata': {
              'promptTokenCount': 120,
              'candidatesTokenCount': 30,
              'totalTokenCount': 150,
            },
          }))),
        ],
      ]);

      final events = await _collect(
        _client(http, provider: 'gemini', model: 'gemini-1.5-flash'),
        req,
      );

      expect(
        events.whereType<ChatDelta>().map((d) => d.text),
        ['洛', '必达法则'],
      );
      final done = events.whereType<ChatDone>().single;
      expect(done.response.text, '洛必达法则');
      expect(done.response.finishReason, 'MAX_TOKENS');
      expect(done.response.truncated, isTrue);
      expect(done.response.usage.inputTokens, 120);
      expect(done.response.usage.outputTokens, 30);
    });

    test('functionCall 一帧拿完：args 编码回 JSON 串，id 按序合成', () async {
      final http = _FakeHttp(rounds: [
        [
          _chunk(_sse(jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {
                      'functionCall': {
                        'name': 'query_wrong_problems',
                        'args': {'kp': '中值定理', 'limit': 3},
                      },
                    },
                    {
                      'functionCall': {
                        'name': 'query_profile',
                        'args': <String, dynamic>{},
                      },
                    },
                  ],
                  'role': 'model',
                },
                'finishReason': 'STOP',
              }
            ],
          }))),
        ],
      ]);

      final events = await _collect(
        _client(http, provider: 'gemini', model: 'gemini-1.5-flash'),
        req,
      );

      final calls = events.whereType<ChatDone>().single.response.toolCalls;
      expect(calls, hasLength(2), reason: '一帧里的多个调用各占一个槽位');
      expect(calls[0].id, 'call_0', reason: 'Gemini 不给 id，按出现顺序合成');
      expect(calls[0].name, 'query_wrong_problems');
      expect(calls[0].arguments, '{"kp":"中值定理","limit":3}');
      expect(calls[1].id, 'call_1');
      expect(calls[1].name, 'query_profile');
      expect(calls[1].arguments, '{}');
    });

    test('流中途的 error 帧要抛出来', () async {
      final http = _FakeHttp(rounds: [
        [
          _chunk(_sse(jsonEncode({
            'error': {
              'code': 400,
              'message': 'API key not valid',
              'status': 'INVALID_ARGUMENT',
            },
          }))),
        ],
      ]);

      Object? err;
      try {
        await _collect(
          _client(http, provider: 'gemini', model: 'gemini-1.5-flash'),
          req,
        );
      } catch (e) {
        err = e;
      }

      expect(err, isA<LlmException>());
      expect((err! as LlmException).message, contains('API key not valid'));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('非流式响应里的工具调用（chat 路径）', () {
    test('Anthropic：content 里的 tool_use 块 → ToolCall', () async {
      final http = _FakeHttp(sends: [
        HttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'content': [
              {'type': 'text', 'text': '我查一下'},
              {
                'type': 'tool_use',
                'id': 'toolu_9',
                'name': 'query_wrong_problems',
                'input': {
                  'kp': '中值定理',
                },
              },
            ],
            'stop_reason': 'tool_use',
            'usage': {'input_tokens': 9, 'output_tokens': 4},
          }),
        ),
      ]);

      final resp = await _client(
        http,
        provider: 'anthropic',
        model: 'claude-3-5-sonnet',
      ).chat(const ChatRequest(system: 's', user: 'u', tools: [_tool]));

      expect(resp.text, '我查一下');
      final call = resp.toolCalls.single;
      expect(call.id, 'toolu_9');
      expect(call.arguments, '{"kp":"中值定理"}',
          reason: '协议给的是对象，ToolCall 的口径是 JSON 串 —— 这里转一道');
    });

    test('Gemini：parts 里的 functionCall → ToolCall（id 按序合成）', () async {
      final http = _FakeHttp(sends: [
        HttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {
                      'functionCall': {
                        'name': 'query_wrong_problems',
                        'args': {'kp': '中值定理'},
                      },
                    }
                  ],
                  'role': 'model',
                },
                'finishReason': 'STOP',
              }
            ],
          }),
        ),
      ]);

      final resp = await _client(
        http,
        provider: 'gemini',
        model: 'gemini-1.5-flash',
      ).chat(const ChatRequest(system: 's', user: 'u', tools: [_tool]));

      final call = resp.toolCalls.single;
      expect(call.id, 'call_0');
      expect(call.name, 'query_wrong_problems');
      expect(call.arguments, '{"kp":"中值定理"}');
    });
  });
}
