/// 手写答案核对（3.2）的服务层测试。
///
/// 契约钉在三条：**提示词里写死"绝不打分"**（FSRS 的输入必须是人类判断）、
/// 解析宽容度与批量导入一致（{"points":[...]} 与顶层裸数组都认）、
/// 全军覆没时如实抛而不是显示"0 个要点"。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/services/llm/llm_client.dart';
import 'package:kaoyan_math_agent/services/llm/llm_settings.dart';
import 'package:kaoyan_math_agent/services/review/handwrite_check.dart';

import 'ingest_test.dart' show FakeHttp;

LlmClient _client(FakeHttp http) => LlmClient(
      config: const LlmSettings(
        providerId: 'zhipu',
        apiKey: 'sk-test',
        modelOverride: 'glm-4.6v-flash',
      ).toConfig(),
      http: http,
    );

final ChatAttachment _img = ChatAttachment(
  kind: ChatAttachmentKind.image,
  mimeType: 'image/png',
  bytes: Uint8List.fromList([137, 80, 78, 71]),
  name: 'hw.png',
);

void main() {
  test('提示词契约：只对照不打分 + JSON 形状写死', () {
    final sys = handwriteCheckSystemPrompt();
    expect(sys, contains('绝不打分'));
    expect(sys, contains('"points"'));
    expect(sys, contains('不要猜'), reason: '看不清就如实说，不许编');
  });

  test('题库没存答案/解析时，用户提示词如实说明', () {
    final u = handwriteCheckUserPrompt();
    expect(u, contains('没有存标准答案'));
  });

  test('解析 {"points":[...]}，用量透传', () async {
    final body = jsonEncode({
      'points': [
        {'name': '建系', 'hit': true, 'note': '第一行可见坐标系'},
        {'name': '求导', 'hit': false, 'note': '未见导数步骤'},
      ],
    });
    final http = FakeHttp([FakeHttp.ok(body, inTok: 300, outTok: 80)]);

    final r = await checkHandwrittenAnswer(
      client: _client(http),
      attachment: _img,
      answer: r'$1$',
      solution: '用等价无穷小。',
    );

    expect(r.points, hasLength(2));
    expect(r.points.first.hit, isTrue);
    expect(r.points.last.hit, isFalse);
    expect(r.usage.totalTokens, greaterThan(0));
    // 图与标准参照都进了请求
    expect(http.requests.single.body, contains('image/png'));
    expect(http.requests.single.body, contains('标准解析'));
  });

  test('顶层裸数组也认（模型不包壳是常态）', () async {
    final body = jsonEncode([
      {'name': '建系', 'hit': true, 'note': '可见'},
    ]);
    final r = await checkHandwrittenAnswer(
      client: _client(FakeHttp([FakeHttp.ok(body)])),
      attachment: _img,
    );
    expect(r.points, hasLength(1));
  });

  test('有输出但没有 points → 如实抛 badResponse，不显示"0 个要点"', () async {
    final http = FakeHttp([
      FakeHttp.ok('我只能看到一张写满字的纸。'),
    ]);
    await expectLater(
      checkHandwrittenAnswer(
        client: _client(http),
        attachment: _img,
        answer: r'$1$',
      ),
      throwsA(isA<LlmException>()),
    );
  });

  test('Uint8List 附件链路：bytes 原样进请求体（base64）', () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final http = FakeHttp([
      FakeHttp.ok(jsonEncode({
        'points': [
          {'name': 'x', 'hit': true, 'note': 'y'},
        ],
      })),
    ]);
    await checkHandwrittenAnswer(
      client: _client(http),
      attachment: ChatAttachment(
        kind: ChatAttachmentKind.image,
        mimeType: 'image/png',
        bytes: bytes,
        name: 'a.png',
      ),
    );
    expect(http.requests.single.body, contains('image/png'));
  });
}
