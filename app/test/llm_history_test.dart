/// 多轮对话：历史轮次要被正确编进三家协议的请求体。
///
/// ## 这个文件最重要的两条
///
/// 1. **`history` 为空时，请求体必须与改动前完全一致。**
///    这条不是洁癖 —— [ChatRequest] 有十来个既有调用点
///    （录入的 AI 提炼、批量导入、标注、组题），它们全都不会传 history。
///    如果展开逻辑写歪了（比如塞一个空的 system 消息、或者把 user
///    从 `messages` 挪到别处），那十来个功能会一起出现难以归因的退化 ——
///    而它们的测试都不会响，因为它们**本来就不该受影响**。
///
/// 2. **Gemini 的助手角色必须叫 `model`。**
///    写成 `assistant` 不会报参数错，而是被当成未知角色处理 ——
///    表现为"模型完全不记得上一轮说过什么"，一个只在多轮时才出现的怪病。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/services/llm/llm_client.dart';
import 'package:kaoyan_math_agent/services/llm/provider_registry.dart';

/// 记下请求体、按协议回一个能解析的假适配器。
class CaptureHttp extends HttpAdapter {
  final List<HttpRequest> requests = [];
  final String provider;

  CaptureHttp(this.provider);

  @override
  Future<HttpResponse> send(HttpRequest request) async {
    requests.add(request);
    return HttpResponse(statusCode: 200, body: _okBody(provider));
  }

  Map<String, dynamic> get body =>
      jsonDecode(requests.last.body ?? '{}') as Map<String, dynamic>;
}

String _okBody(String provider) => switch (provider) {
      'anthropic' => jsonEncode({
          'content': [
            {'type': 'text', 'text': '好'},
          ],
          'stop_reason': 'end_turn',
        }),
      'gemini' => jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': '好'},
                ],
              },
              'finishReason': 'STOP',
            }
          ],
        }),
      _ => jsonEncode({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': '好'},
            }
          ],
        }),
    };

LlmClient _client(HttpAdapter http, String provider) => LlmClient(
      config: LlmConfig(providerId: provider, apiKey: 'k', modelOverride: 'm'),
      http: http,
      sleep: (_) async {},
    );

const _history = [
  ChatMessage.user('洛必达法则什么时候能用？'),
  ChatMessage.assistant('当分子分母同时趋于 0 或无穷时。'),
];

void main() {
  group('history 为空：请求体保持原样', () {
    test('OpenAI：仍然只有 system + user 两条', () async {
      final http = CaptureHttp('openai');

      await _client(http, 'openai')
          .chat(const ChatRequest(system: 'S', user: 'U'));

      final messages = http.body['messages'] as List;
      expect(messages.length, 2);
      expect(messages[0], {'role': 'system', 'content': 'S'});
      expect(messages[1], {'role': 'user', 'content': 'U'});
    });

    test('Anthropic：system 仍在顶层，messages 只有 user 一条', () async {
      final http = CaptureHttp('anthropic');

      await _client(http, 'anthropic')
          .chat(const ChatRequest(system: 'S', user: 'U'));

      expect(http.body['system'], 'S');
      expect((http.body['messages'] as List).length, 1);
    });

    test('Gemini：contents 只有 user 一条，systemInstruction 在顶层', () async {
      final http = CaptureHttp('gemini');

      await _client(http, 'gemini')
          .chat(const ChatRequest(system: 'S', user: 'U'));

      final contents = http.body['contents'] as List;
      expect(contents.length, 1);
      expect(http.body['systemInstruction'], isNotNull);
    });
  });

  group('history 非空：按顺序展开在本次 user 之前', () {
    test('OpenAI：system → u1 → a1 → u2', () async {
      final http = CaptureHttp('openai');

      await _client(http, 'openai').chat(
        const ChatRequest(system: 'S', user: '那洛必达不行的时候呢？',
            history: _history),
      );

      final messages = (http.body['messages'] as List)
          .cast<Map<String, dynamic>>();
      expect(messages.map((m) => m['role']).toList(),
          ['system', 'user', 'assistant', 'user']);
      expect(messages[1]['content'], '洛必达法则什么时候能用？');
      expect(messages[2]['content'], '当分子分母同时趋于 0 或无穷时。');
      expect(messages[3]['content'], '那洛必达不行的时候呢？');
    });

    test('Anthropic：system 留在顶层，历史展开进 messages', () async {
      final http = CaptureHttp('anthropic');

      await _client(http, 'anthropic').chat(
        const ChatRequest(system: 'S', user: 'U2', history: _history),
      );

      // ⚠️ 这条守的是 Anthropic 的一个硬限制：`messages` 里出现
      // system 角色会直接 400。历史里当然不该有 system —— 但更关键的是
      // 别把顶层的 system 顺手也塞进 messages。
      expect(http.body['system'], 'S');
      final roles = (http.body['messages'] as List)
          .cast<Map<String, dynamic>>()
          .map((m) => m['role'])
          .toList();
      expect(roles, ['user', 'assistant', 'user']);
      expect(roles.contains('system'), isFalse);
    });

    test('Gemini：助手角色写成 model（不是 assistant）', () async {
      final http = CaptureHttp('gemini');

      await _client(http, 'gemini').chat(
        const ChatRequest(system: 'S', user: 'U2', history: _history),
      );

      final contents =
          (http.body['contents'] as List).cast<Map<String, dynamic>>();
      expect(contents.map((c) => c['role']).toList(),
          ['user', 'model', 'user']);
    });

    test('Gemini：历史文本埋在 parts 里', () async {
      final http = CaptureHttp('gemini');

      await _client(http, 'gemini').chat(
        const ChatRequest(system: 'S', user: 'U2', history: _history),
      );

      final contents =
          (http.body['contents'] as List).cast<Map<String, dynamic>>();
      final firstParts = contents.first['parts'] as List;
      expect((firstParts.first as Map)['text'], '洛必达法则什么时候能用？');
    });
  });

  group('角色命名', () {
    test('geminiName：assistant → model，user 不变', () {
      expect(ChatRole.assistant.geminiName, 'model');
      expect(ChatRole.user.geminiName, 'user');
    });

    test('OpenAI / Anthropic 用的是 enum 自身的名字', () {
      expect(ChatRole.assistant.name, 'assistant');
      expect(ChatRole.user.name, 'user');
    });

    test('ChatMessage 的便捷构造', () {
      expect(const ChatMessage.user('x').role, ChatRole.user);
      expect(const ChatMessage.assistant('y').role, ChatRole.assistant);
    });
  });
}
