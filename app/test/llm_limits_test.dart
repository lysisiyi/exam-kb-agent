/// 真实 API 踩出来的三个缺陷，钉在这里。
///
/// ## 背景（2026-09-18，用智谱真实 Key 跑批量导入）
///
/// 第一次真实导入**一秒不到就失败**，界面只有一句"请求不合法"。
/// 手写原始请求逐个试参数才查出原因：
///
/// ```
/// {max_tokens: 8192} → 400 {"error":{"code":"1210",
///   "message":"max_tokens参数非法：限制数值范围[1,1024]"}}
/// ```
///
/// 三个缺陷：
/// 1. **批量导入写死 8192**，而智谱视觉模型只收 1024 →
///    智谱上的批量导入一次都跑不通（同一家的文本模型收 8192 没问题）；
/// 2. **400 的原因被吞掉**，界面只显示"请求不合法" ——
///    服务商的原话（可操作的那部分）没传出来；
/// 3. **截断不报错**：`finish_reason` 此前全项目没有读过，
///    输出被上限砍断时会静默少导几道题，只剩解析层的误诊提示。
///
/// ⚠️ 注意区分：那次"一页只进来 1 道题"的真因**不是**截断，
/// 而是模型给了顶层数组、解析器只认对象（见 `ingest_test.dart`
/// 的"模型直接给题目数组"一组）。截断是另一条通道，同样要报。
///
/// 这一组测试守这三条，外加"输出上限偏低时要如实提示"。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/services/ingest/ingest_models.dart';
import 'package:kaoyan_math_agent/services/llm/llm_client.dart';
import 'package:kaoyan_math_agent/services/llm/provider_registry.dart';

/// 记录请求体、按脚本返回的假适配器。
class RecordHttp extends HttpAdapter {
  final List<HttpResponse> responses;
  final List<HttpRequest> requests = [];
  int _i = 0;

  RecordHttp(this.responses);

  @override
  Future<HttpResponse> send(HttpRequest request) async {
    requests.add(request);
    final r = responses[_i < responses.length ? _i : responses.length - 1];
    _i++;
    return r;
  }

  Map<String, dynamic> get lastBody =>
      jsonDecode(requests.last.body ?? '{}') as Map<String, dynamic>;
}

HttpResponse okOpenAi() => HttpResponse(
      statusCode: 200,
      body: jsonEncode({
        'choices': [
          {
            'message': {'role': 'assistant', 'content': '{}'},
          }
        ],
        'usage': {'prompt_tokens': 10, 'completion_tokens': 5},
      }),
    );

void main() {
  group('max_tokens 必须收进服务商允许的范围', () {
    test('智谱：请求体里的 max_tokens 被收到 1024（实测上限）', () async {
      final http = RecordHttp([okOpenAi()]);
      final client = LlmClient(
        config: const LlmConfig(
          providerId: 'zhipu',
          apiKey: 'k',
          modelOverride: 'glm-4v-flash',
        ),
        http: http,
        sleep: (_) async {},
      );

      // 批量导入就是这么发的
      await client.chat(const ChatRequest(
        system: 's',
        user: 'u',
        maxTokens: 8192,
        jsonMode: true,
      ));

      expect(http.lastBody['max_tokens'], 1024,
          reason: '智谱只接受 [1,1024]，发 8192 会 400 code 1210');
      // json mode 仍然保留（实测智谱支持 response_format）
      expect(http.lastBody['response_format'], {'type': 'json_object'});
    });

    test('不受限制的服务商：原样透传', () async {
      final http = RecordHttp([okOpenAi()]);
      final client = LlmClient(
        config: const LlmConfig(
          providerId: 'openai',
          apiKey: 'k',
          modelOverride: 'gpt-4o-mini',
        ),
        http: http,
        sleep: (_) async {},
      );
      await client.chat(const ChatRequest(system: 's', user: 'u', maxTokens: 8192));
      expect(http.lastBody['max_tokens'], 8192);
    });

    // 上限是**按模型**的，不是按服务商。早先写在服务商上，于是
    // 智谱整家被压到 1024 —— 把能收 8192 的模型也一起限死，
    // 而提示里还把这说成"服务商硬限制"。
    test('同一家的另一个模型不受 1024 牵连（实测 glm-4.6v-flash 收 8192）',
        () async {
      final http = RecordHttp([okOpenAi()]);
      final client = LlmClient(
        config: const LlmConfig(
          providerId: 'zhipu',
          apiKey: 'k',
          modelOverride: 'glm-4.6v-flash',
        ),
        http: http,
        sleep: (_) async {},
      );
      await client.chat(const ChatRequest(system: 's', user: 'u', maxTokens: 8192));
      expect(http.lastBody['max_tokens'], 8192,
          reason: '按服务商压到 1024 会凭空截断一页多题的输出');
    });

    test('智谱的文本模型也不受牵连（实测 glm-4-flash 收 8192）', () async {
      final http = RecordHttp([okOpenAi()]);
      final client = LlmClient(
        config: const LlmConfig(
          providerId: 'zhipu',
          apiKey: 'k',
          modelOverride: 'glm-4-flash',
        ),
        http: http,
        sleep: (_) async {},
      );
      await client.chat(const ChatRequest(system: 's', user: 'u', maxTokens: 8192));
      expect(http.lastBody['max_tokens'], 8192,
          reason: '打标走的是文本模型，被压到 1024 会让标注输出也截断');
    });

    test('模型名匹配不会串台：glm-4v-flash 仍被收到 1024', () {
      const cap = LlmConfig(
        providerId: 'zhipu',
        apiKey: 'k',
        modelOverride: 'glm-4v-flash',
      );
      const big = LlmConfig(
        providerId: 'zhipu',
        apiKey: 'k',
        modelOverride: 'glm-4.6v-flash',
      );
      expect(cap.maxOutputTokens, 1024);
      expect(big.maxOutputTokens, isNull, reason: 'glm-4.6v-flash 不含 glm-4v-flash');
    });

    test('没给 maxTokens 时不塞这个字段（OpenAI 兼容）', () async {
      final http = RecordHttp([okOpenAi()]);
      final client = LlmClient(
        config: const LlmConfig(
          providerId: 'zhipu',
          apiKey: 'k',
          modelOverride: 'glm-4-flash',
        ),
        http: http,
        sleep: (_) async {},
      );
      await client.chat(const ChatRequest(system: 's', user: 'u'));
      expect(http.lastBody.containsKey('max_tokens'), isFalse);
    });

    test('Anthropic 强制要 max_tokens：也要收进上限', () async {
      final http = RecordHttp([
        HttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'content': [
              {'type': 'text', 'text': '{}'}
            ],
            'usage': {'input_tokens': 1, 'output_tokens': 1},
          }),
        ),
      ]);
      // 用 zhipu 的能力表没意义（协议不同），这里直接验证 Anthropic 分支
      // 在"没有服务商上限"时的默认值仍是 4096
      final client = LlmClient(
        config: const LlmConfig(
          providerId: 'anthropic',
          apiKey: 'k',
          modelOverride: 'claude-3-5-sonnet-20241022',
        ),
        http: http,
        sleep: (_) async {},
      );
      await client.chat(const ChatRequest(system: 's', user: 'u'));
      expect(http.lastBody['max_tokens'], 4096);
    });
  });

  group('服务商的错误原因必须传出来', () {
    test('400 带上服务商原话（智谱 code 1210）', () async {
      final http = RecordHttp([
        HttpResponse(
          statusCode: 400,
          body: jsonEncode({
            'error': {
              'code': '1210',
              'message': 'max_tokens参数非法：限制数值范围[1,1024]',
            }
          }),
        ),
      ]);
      final client = LlmClient(
        config: const LlmConfig(
          providerId: 'zhipu',
          apiKey: 'k',
          modelOverride: 'glm-4v-flash',
        ),
        http: http,
        retry: const RetryPolicy(maxAttempts: 1),
        sleep: (_) async {},
      );

      try {
        await client.chat(const ChatRequest(system: 's', user: 'u'));
        fail('应当抛异常');
      } on LlmException catch (e) {
        expect(e.kind, LlmErrorKind.badRequest);
        expect(e.message, contains('max_tokens参数非法'),
            reason: '不把服务商的话带出来，用户（和开发者）只能靠手写原始请求猜');
        expect(e.message, contains('请求不合法'), reason: '自己的判断也要保留');
      }
    });

    test('余额不足也带原话', () async {
      final http = RecordHttp([
        HttpResponse(
          statusCode: 400,
          body: jsonEncode({
            'error': {'code': '1113', 'message': '余额不足或无可用资源包,请充值。'}
          }),
        ),
      ]);
      final client = LlmClient(
        config: const LlmConfig(
          providerId: 'zhipu',
          apiKey: 'k',
          modelOverride: 'glm-4v-plus',
        ),
        http: http,
        retry: const RetryPolicy(maxAttempts: 1),
        sleep: (_) async {},
      );
      try {
        await client.chat(const ChatRequest(system: 's', user: 'u'));
        fail('应当抛异常');
      } on LlmException catch (e) {
        expect(e.kind, LlmErrorKind.insufficientBalance);
        expect(e.message, contains('余额不足'));
      }
    });

    test('不是 JSON（网关 HTML）时不硬塞进消息里', () async {
      final http = RecordHttp([
        const HttpResponse(
            statusCode: 502, body: '<html><body>Bad Gateway</body>'),
      ]);
      final client = LlmClient(
        config: const LlmConfig(
          providerId: 'openai',
          apiKey: 'k',
          modelOverride: 'gpt-4o-mini',
        ),
        http: http,
        retry: const RetryPolicy(maxAttempts: 1),
        sleep: (_) async {},
      );
      try {
        await client.chat(const ChatRequest(system: 's', user: 'u'));
        fail('应当抛异常');
      } on LlmException catch (e) {
        expect(e.kind, LlmErrorKind.serverError);
        expect(e.message, isNot(contains('<html>')));
        expect(e.message, contains('502'));
      }
    });
  });

  group('输出上限偏低要如实提示', () {
    test('上限 1024 时给出一条"可能被截断"的提示', () {
      const sources = [
        IngestSource(
          path: r'C:\x\p1.jpg',
          name: 'p1.jpg',
          sizeBytes: 300 * 1024,
          kind: IngestSourceKind.image,
        ),
      ];
      final withCap =
          estimateIngest(sources, model: 'glm-4v-flash', maxOutputTokens: 1024);
      expect(withCap.notes.any((n) => n.contains('最多输出 1024 token')), isTrue,
          reason: '不提示的话，截断会表现成"解析失败"，用户会以为是软件坏了');

      final noCap = estimateIngest(sources, model: 'gpt-4o-mini');
      expect(noCap.notes.any((n) => n.contains('最多输出')), isFalse);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  group('截断必须能被识别（三家字段名各不相同）', () {
    /// 发一次请求，返回解析出来的响应。
    Future<ChatResponse> call({
      required String providerId,
      required String model,
      required Map<String, dynamic> body,
    }) async {
      final http = RecordHttp(
        [HttpResponse(statusCode: 200, body: jsonEncode(body))],
      );
      return LlmClient(
        config: LlmConfig(
          providerId: providerId,
          apiKey: 'k',
          modelOverride: model,
        ),
        http: http,
        sleep: (_) async {},
      ).chat(const ChatRequest(system: 's', user: 'u'));
    }

    Map<String, dynamic> openAi(String? finishReason) => {
          'choices': [
            {
              'message': {'role': 'assistant', 'content': '{}'},
              if (finishReason != null) 'finish_reason': finishReason,
            }
          ],
          'usage': {'prompt_tokens': 1, 'completion_tokens': 1},
        };

    test('OpenAI 兼容：finish_reason=length', () async {
      final t = await call(
        providerId: 'zhipu',
        model: 'glm-4v-flash',
        body: openAi('length'),
      );
      expect(t.finishReason, 'length');
      expect(t.truncated, isTrue);

      final s = await call(
        providerId: 'zhipu',
        model: 'glm-4v-flash',
        body: openAi('stop'),
      );
      expect(s.truncated, isFalse);
    });

    test('取不到 finish_reason 时不报警（宁可漏报也不误报）', () async {
      final t = await call(
        providerId: 'zhipu',
        model: 'glm-4v-flash',
        body: openAi(null),
      );
      expect(t.finishReason, isNull);
      expect(t.truncated, isFalse);
    });

    test('Anthropic：stop_reason=max_tokens', () async {
      final t = await call(
        providerId: 'anthropic',
        model: 'claude-3-5-sonnet-20241022',
        body: {
          'content': [
            {'type': 'text', 'text': '{}'}
          ],
          'stop_reason': 'max_tokens',
          'usage': {'input_tokens': 1, 'output_tokens': 1},
        },
      );
      expect(t.truncated, isTrue);

      final e = await call(
        providerId: 'anthropic',
        model: 'claude-3-5-sonnet-20241022',
        body: {
          'content': [
            {'type': 'text', 'text': '{}'}
          ],
          'stop_reason': 'end_turn',
          'usage': {'input_tokens': 1, 'output_tokens': 1},
        },
      );
      expect(e.truncated, isFalse);
    });

    test('Gemini：finishReason=MAX_TOKENS（大写也要认）', () async {
      final t = await call(
        providerId: 'gemini',
        model: 'gemini-1.5-flash',
        body: {
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': '{}'}
                ]
              },
              'finishReason': 'MAX_TOKENS',
            }
          ],
          'usageMetadata': {'promptTokenCount': 1, 'candidatesTokenCount': 1},
        },
      );
      expect(t.truncated, isTrue);

      final s = await call(
        providerId: 'gemini',
        model: 'gemini-1.5-flash',
        body: {
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': '{}'}
                ]
              },
              'finishReason': 'STOP',
            }
          ],
          'usageMetadata': {'promptTokenCount': 1, 'candidatesTokenCount': 1},
        },
      );
      expect(s.truncated, isFalse);
    });
  });
}
