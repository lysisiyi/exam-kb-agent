/// M7 批量导入：能力判定、多模态编码、提炼解析、导入管道。
///
/// ## 为什么这些全部能离线测
///
/// 整条管道只有两个外部接触点，都被做成了可注入的：
/// - `HttpAdapter` —— 假实现返回编排好的 JSON，于是**不花一分钱**
///   就能把"三家协议各自怎么编码图片"和"模型输出怎么解析"测到底
/// - `AttachmentLoader` —— 假实现直接给字节，于是不需要往磁盘写图片
///
/// 真实 API 的那部分（模型到底看不看得懂扫描件）只能由用户真机验证，
/// 这一点在 `docs/PROGRESS.md` 里记着，不假装测过了。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/data/markdown/problem_markdown.dart';
import 'package:kaoyan_math_agent/services/ingest/ingest_extractor.dart';
import 'package:kaoyan_math_agent/services/ingest/ingest_models.dart';
import 'package:kaoyan_math_agent/services/ingest/ingest_session.dart';
import 'package:kaoyan_math_agent/services/llm/llm_client.dart';
import 'package:kaoyan_math_agent/services/llm/provider_registry.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 测试替身
// ─────────────────────────────────────────────────────────────────────────────

/// 可编排的假 HTTP 适配器。与 `tagger_test.dart` 同一套写法。
class FakeHttp implements HttpAdapter {
  final List<Object> responses;
  final List<HttpRequest> requests = [];
  int _i = 0;

  FakeHttp(this.responses);

  @override
  Future<HttpResponse> send(HttpRequest request) async {
    requests.add(request);
    final r = responses[_i < responses.length ? _i : responses.length - 1];
    _i++;
    if (r is HttpResponse) return r;
    if (r is HttpTransportException) throw r;
    if (r is LlmException) throw r;
    throw StateError('不支持的假响应类型：${r.runtimeType}');
  }

  /// OpenAI 兼容的成功响应。
  static HttpResponse ok(String content, {int inTok = 100, int outTok = 50}) =>
      HttpResponse(
        statusCode: 200,
        body: jsonEncode({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': content},
            }
          ],
          'usage': {'prompt_tokens': inTok, 'completion_tokens': outTok},
        }),
      );

  /// Anthropic 的成功响应 —— **形状与 OpenAI 完全不同**：
  /// 文本在 `content` 数组的 text block 里，用量键名是
  /// `input_tokens` / `output_tokens`。
  ///
  /// 用错形状的假响应会让测试在"解析响应"那一步就失败，
  /// 于是断言根本走不到请求体 —— 等于什么都没测。
  static HttpResponse okAnthropic(String text, {int inTok = 100, int outTok = 50}) =>
      HttpResponse(
        statusCode: 200,
        body: jsonEncode({
          'content': [
            {'type': 'text', 'text': text},
          ],
          'usage': {'input_tokens': inTok, 'output_tokens': outTok},
        }),
      );

  /// Gemini 的成功响应：`candidates[].content.parts[].text` +
  /// `usageMetadata`。
  static HttpResponse okGemini(String text, {int inTok = 100, int outTok = 50}) =>
      HttpResponse(
        statusCode: 200,
        body: jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': text},
                ],
              },
            },
          ],
          'usageMetadata': {
            'promptTokenCount': inTok,
            'candidatesTokenCount': outTok,
          },
        }),
      );
}

Future<void> _noSleep(Duration _) async {}

LlmConfig _cfg({
  String provider = 'openai',
  String model = 'gpt-4o-mini',
  String? baseUrl,
}) =>
    LlmConfig(
      providerId: provider,
      apiKey: 'test-key',
      modelOverride: model,
      baseUrlOverride: baseUrl,
    );

LlmClient _client(HttpAdapter http, {String provider = 'openai', String model = 'gpt-4o-mini'}) =>
    LlmClient(config: _cfg(provider: provider, model: model), http: http, sleep: _noSleep);

final Uint8List _pngBytes = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]);

IngestSource _src(String name, {IngestSourceKind kind = IngestSourceKind.image, int size = 1024}) =>
    IngestSource(path: '/tmp/$name', name: name, sizeBytes: size, kind: kind);

/// 假附件加载器：记录调用次数，第 [failOn] 个抛异常。
class FakeLoader {
  final Set<String> failOn;
  final List<String> calls = [];

  FakeLoader({this.failOn = const {}});

  Future<ChatAttachment> call(IngestSource s) async {
    calls.add(s.name);
    if (failOn.contains(s.name)) {
      throw Exception('文件读不出来');
    }
    return ChatAttachment(
      kind: s.isPdf ? ChatAttachmentKind.pdf : ChatAttachmentKind.image,
      mimeType: s.isPdf ? 'application/pdf' : 'image/png',
      bytes: _pngBytes,
      name: s.name,
    );
  }
}

/// 一段合法的模型输出。
String _payload(List<Map<String, dynamic>> problems) =>
    jsonEncode({'problems': problems});

const Map<String, dynamic> _oneProblem = {
  'stem': r'求 $\lim_{x\to0}\frac{\sin x}{x}$。',
  'answer': r'$1$',
  'solution': r'用等价无穷小。',
  'answer_from_source': true,
  'qtype': 'solve',
  'difficulty': 2,
  'confidence': 0.93,
};

void main() {
  // ═══════════════════════════════════════════════════════════════════════════
  group('视觉能力判定', () {
    test('DeepSeek 是纯文本，直接拦住并给出替代方案', () {
      final cfg = _cfg(provider: 'deepseek', model: 'deepseek-chat');
      expect(cfg.visionSupport, VisionSupport.no);

      final reason = cfg.visionBlockReason();
      expect(reason, isNotNull);
      // 光说"不行"没用，必须告诉用户换什么
      expect(reason, contains('Claude'));
      expect(reason, contains('Gemini'));
    });

    test('OpenAI 的视觉模型判为支持', () {
      expect(
        _cfg(provider: 'openai', model: 'gpt-4o-mini').visionSupport,
        VisionSupport.yes,
      );
      expect(
        _cfg(provider: 'openai', model: 'gpt-4-turbo').visionSupport,
        VisionSupport.yes,
      );
    });

    test('认不出的模型判为"无法确认"，而不是"不支持"', () {
      // 自建网关的用户不应该被挡在门外 —— 我们只是不知道，
      // 所以允许继续但要提示
      final cfg = _cfg(
        provider: 'custom',
        model: 'my-internal-vl-model',
        baseUrl: 'https://gateway.example.com/v1',
      );
      expect(cfg.visionSupport, VisionSupport.unknown);
      expect(cfg.visionBlockReason(), isNull, reason: '不能硬拦');
      expect(cfg.visionWarning(), isNotNull, reason: '但必须提示');
    });

    test('PDF 支持是协议级的：只有 Claude 与 Gemini 可以', () {
      expect(_cfg(provider: 'anthropic', model: 'claude-3-5-sonnet-20241022').pdfSupport,
          VisionSupport.yes);
      expect(_cfg(provider: 'gemini', model: 'gemini-1.5-flash').pdfSupport,
          VisionSupport.yes);
      expect(_cfg(provider: 'openai', model: 'gpt-4o-mini').pdfSupport,
          VisionSupport.no);
    });

    test('来源里有 PDF 时，不支持 PDF 的服务商会被拦下并说明出路', () {
      final cfg = _cfg(provider: 'qwen', model: 'qwen-vl-max');
      expect(cfg.visionSupport, VisionSupport.yes);
      expect(cfg.visionBlockReason(), isNull);

      final reason = cfg.visionBlockReason(needPdf: true);
      expect(reason, isNotNull);
      expect(reason, contains('导出成图片'));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  group('多模态请求编码（三家协议互不相同）', () {
    test('OpenAI：图片走 image_url 的 data URI', () async {
      final http = FakeHttp([FakeHttp.ok(_payload([_oneProblem]))]);
      await _client(http).chat(ChatRequest(
        system: 's',
        user: 'u',
        attachments: [
          ChatAttachment(
            kind: ChatAttachmentKind.image,
            mimeType: 'image/png',
            bytes: _pngBytes,
          ),
        ],
      ));

      final body = jsonDecode(http.requests.single.body!) as Map<String, dynamic>;
      final messages = body['messages'] as List;
      final content = (messages[1] as Map)['content'];
      expect(content, isA<List<dynamic>>(), reason: '有附件时 content 必须是数组');
      expect((content as List<dynamic>).first['type'], 'text');
      final img = content[1];
      expect(img['type'], 'image_url');
      expect(
        img['image_url']['url'],
        startsWith('data:image/png;base64,'),
      );
    });

    test('OpenAI：没有附件时 content 保持纯字符串（兼容第三方端点）', () async {
      final http = FakeHttp([FakeHttp.ok(_payload([]))]);
      await _client(http).chat(const ChatRequest(system: 's', user: 'u'));

      final body = jsonDecode(http.requests.single.body!) as Map<String, dynamic>;
      final messages = body['messages'] as List;
      expect((messages[1] as Map)['content'], 'u');
    });

    test('Anthropic：图片是 image block，PDF 是 document block', () async {
      final http = FakeHttp([FakeHttp.okAnthropic('{}')]);
      await _client(http, provider: 'anthropic', model: 'claude-3-5-sonnet-20241022')
          .chat(ChatRequest(
        system: 's',
        user: 'u',
        attachments: [
          ChatAttachment(
            kind: ChatAttachmentKind.image,
            mimeType: 'image/jpeg',
            bytes: _pngBytes,
          ),
          ChatAttachment(
            kind: ChatAttachmentKind.pdf,
            mimeType: 'application/pdf',
            bytes: _pngBytes,
          ),
        ],
      ));

      final body = jsonDecode(http.requests.single.body!) as Map<String, dynamic>;
      final content = ((body['messages'] as List).first as Map)['content'] as List;
      expect(content[0]['type'], 'image');
      expect(content[0]['source']['media_type'], 'image/jpeg');
      expect(content[0]['source']['type'], 'base64');
      expect(content[1]['type'], 'document');
      expect(content[1]['source']['media_type'], 'application/pdf');
      expect(content.last['type'], 'text', reason: '文字说明必须在最后');
      // Anthropic 的 system 走顶层字段
      expect(body['system'], 's');
    });

    test('Gemini：图片与 PDF 都走 inline_data', () async {
      final http = FakeHttp([FakeHttp.okGemini('{}')]);
      await _client(http, provider: 'gemini', model: 'gemini-1.5-flash').chat(
        ChatRequest(
          system: 's',
          user: 'u',
          attachments: [
            ChatAttachment(
              kind: ChatAttachmentKind.pdf,
              mimeType: 'application/pdf',
              bytes: _pngBytes,
            ),
          ],
        ),
      );

      final body = jsonDecode(http.requests.single.body!) as Map<String, dynamic>;
      final parts = ((body['contents'] as List).first as Map)['parts'] as List;
      expect(parts[0]['inline_data']['mime_type'], 'application/pdf');
      expect(parts[0]['inline_data']['data'], isNotEmpty);
      expect(parts[1]['text'], 'u');
    });

    test('OpenAI 协议下带 PDF **报错**，绝不静默丢掉附件', () async {
      // 这是本轮的一条纪律：附件发不出去时必须失败得响亮。
      // 静默跳过附件会让用户拿到一份"只看了题干文字"的解析结果，
      // 而且**为它付了钱** —— 那种错误比直接失败难查得多。
      final http = FakeHttp([FakeHttp.ok('{}')]);
      await expectLater(
        _client(http).chat(ChatRequest(
          system: 's',
          user: 'u',
          attachments: [
            ChatAttachment(
              kind: ChatAttachmentKind.pdf,
              mimeType: 'application/pdf',
              bytes: _pngBytes,
            ),
          ],
        )),
        throwsA(isA<LlmException>()
            .having((e) => e.kind, 'kind', LlmErrorKind.badRequest)),
      );
      expect(http.requests, isEmpty, reason: '不该把注定失败的请求发出去');
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  group('提炼结果解析', () {
    ExtractionOutcome parse(String raw) =>
        IngestExtractor.parse(raw, sourceName: 'page-1.png');

    test('正常输出', () {
      final r = parse(_payload([_oneProblem]));
      expect(r.problems.length, 1);
      final p = r.problems.single;
      expect(p.stem, contains(r'\lim'));
      expect(p.answer, r'$1$');
      expect(p.qtype, QuestionType.solve);
      expect(p.difficulty, 2);
      expect(p.confidence, 0.93);
      expect(p.sourceName, 'page-1.png');
      expect(p.fingerprint, isNotEmpty);
    });

    test('包在代码块里也能解析', () {
      final r = parse('```json\n${_payload([_oneProblem])}\n```');
      expect(r.problems.length, 1);
    });

    test('空数组是正常结果（封面 / 目录 / 答案页）', () {
      final r = parse(_payload([]));
      expect(r.problems, isEmpty);
      expect(r.warnings, isEmpty, reason: '不是错误，不该记警告');
    });

    test('题目数组换了键名也认', () {
      final r = parse(jsonEncode({'questions': [_oneProblem]}));
      expect(r.problems.length, 1);
    });

    test('模型没用 problems 包一层时按单题处理', () {
      final r = parse(jsonEncode(_oneProblem));
      expect(r.problems.length, 1);
      expect(r.warnings, isNotEmpty);
    });

    test('没有题干的条目被丢弃并记账', () {
      final r = parse(_payload([
        {'stem': '', 'answer': '1'},
        _oneProblem,
      ]));
      expect(r.problems.length, 1);
      expect(r.warnings.any((w) => w.contains('没有题干')), isTrue);
    });

    test('答案不是原文来的 → 直接丢弃（防编造的核心）', () {
      // 模型很擅长解题。给它一张只有题干的照片，它会"顺手"把答案算出来，
      // 而且看起来完全合理。用户拿到一份**编造答案**的错题本，
      // 比拿到一份没答案的错题本糟得多 —— 前者会让他以为自己记错了。
      final r = parse(_payload([
        {
          'stem': '证明：存在 \$\\xi\$ 使 \$f(\\xi)=0\$。',
          'answer': r'$\xi=0.5$',
          'solution': '由介值定理……',
          'answer_from_source': false,
          'qtype': 'proof',
        },
      ]));
      expect(r.problems.single.answer, isNull);
      expect(r.problems.single.solution, isNull);
      expect(r.warnings.any((w) => w.contains('不是原文内容')), isTrue);
    });

    test('模型没声明答案来源 → 保留但提醒核对', () {
      final r = parse(_payload([
        {'stem': '题干', 'answer': r'$1$'},
      ]));
      expect(r.problems.single.answer, r'$1$');
      expect(r.warnings.any((w) => w.contains('没有说明答案是否来自原文')), isTrue);
    });

    test('题干读不全时压低置信度', () {
      final r = parse(_payload([
        {
          'stem': '设函数 \$f(x)\$ 在 \$[0,',
          'completeness': 'partial',
          'confidence': 0.98,
        },
      ]));
      expect(r.problems.single.confidence, lessThanOrEqualTo(0.5));
    });

    test('选择题选项剥掉 A. / A、/ （A）前缀', () {
      final r = parse(_payload([
        {
          'stem': '下列结论正确的是',
          'qtype': '选择题',
          'options': ['A. 收敛', 'B、发散', '（C）不确定', 'D. 以上都不对'],
        },
      ]));
      expect(r.problems.single.qtype, QuestionType.choice);
      expect(r.problems.single.options, ['收敛', '发散', '不确定', '以上都不对']);
    });

    test('difficulty 越界被夹住，中文档位也认', () {
      expect(parse(_payload([{'stem': 'a', 'difficulty': 9}])).problems.single.difficulty, 3);
      expect(parse(_payload([{'stem': 'a', 'difficulty': 0}])).problems.single.difficulty, 1);
      expect(parse(_payload([{'stem': 'a', 'difficulty': '拓展'}])).problems.single.difficulty, 3);
    });

    test('模型把"没有"写成字符串时归一成 null', () {
      final r = parse(_payload([
        {'stem': 'a', 'answer': 'null', 'solution': '无'},
      ]));
      expect(r.problems.single.answer, isNull);
      expect(r.problems.single.solution, isNull);
    });

    test('完全不是 JSON 时给出可读失败原因', () {
      final r = parse('对不起，我无法识别这张图片。');
      expect(r.problems, isEmpty);
      expect(r.warnings.single, contains('无法解析为 JSON'));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  group('导入管道', () {
    test('两个来源都成功：结果、用量、进度都对得上', () async {
      final http = FakeHttp([FakeHttp.ok(_payload([_oneProblem]), inTok: 1200, outTok: 300)]);
      final loader = FakeLoader();
      final session = IngestSession(
        client: _client(http),
        loadAttachment: loader.call,
        sources: [_src('a.png'), _src('b.png')],
      );

      final progress = <IngestProgress>[];
      final report = await session.run(onProgress: progress.add);

      expect(report.done, 2);
      expect(report.failed, 0);
      expect(report.problemCount, 2);
      expect(session.items.every((i) => i.isDone), isTrue);
      expect(http.requests.length, 2);
      // 用量要累加，用户才能看到这批花了多少
      expect(report.usage.inputTokens, 2400);
      expect(report.usage.outputTokens, 600);
      expect(progress.last.finished, 2);
      expect(progress.last.fraction, 1.0);
      expect(progress.last.isComplete, isTrue);
    });

    test('一个来源失败不影响其它来源', () async {
      final http = FakeHttp([
        FakeHttp.ok(_payload([_oneProblem])),
        const HttpResponse(statusCode: 401, body: '{"error":"bad key"}'),
      ]);
      final session = IngestSession(
        client: _client(http),
        loadAttachment: FakeLoader().call,
        sources: [_src('a.png'), _src('b.png')],
      );

      final report = await session.run();

      expect(report.total, 2);
      expect(report.failed, 1);
      expect(session.items[0].isDone, isTrue);
      expect(session.items[1].status, IngestStatus.failed);
      // 失败原因必须带可执行建议，不能只丢一句"调用失败"
      expect(session.items[1].error, contains('建议'));
    });

    test('读不出来的文件标记为失败，不发出请求', () async {
      final http = FakeHttp([FakeHttp.ok(_payload([]))]);
      final loader = FakeLoader(failOn: {'bad.png'});
      final session = IngestSession(
        client: _client(http),
        loadAttachment: loader.call,
        sources: [_src('bad.png')],
      );

      final report = await session.run();
      expect(report.failed, 1);
      expect(http.requests, isEmpty, reason: '连附件都没读到就不该调用 API');
      expect(loader.calls, ['bad.png']);
    });

    test('开始前取消：全部跳过，一次请求都不发', () async {
      // 这一条是给用户省钱的：按下取消就该一个 token 都不花。
      final http = FakeHttp([FakeHttp.ok(_payload([_oneProblem]))]);
      final loader = FakeLoader();
      final session = IngestSession(
        client: _client(http),
        loadAttachment: loader.call,
        sources: [_src('a.png'), _src('b.png'), _src('c.png')],
      )..cancel();

      final report = await session.run();

      expect(report.skipped, 3);
      expect(http.requests, isEmpty);
      expect(loader.calls, isEmpty);
      expect(report.cancelled, isTrue);
    });

    test('处理完第一条后取消：只发一次请求，剩下的跳过', () async {
      final http = FakeHttp([FakeHttp.ok(_payload([_oneProblem]))]);
      final session = IngestSession(
        client: _client(http),
        loadAttachment: FakeLoader().call,
        sources: [_src('a.png'), _src('b.png'), _src('c.png')],
      );

      final report = await session.run(onProgress: (p) {
        // 第一条一结束就取消
        if (p.finished >= 1) session.cancel();
      });

      expect(http.requests.length, 1);
      expect(report.done, 1);
      expect(report.skipped, 2);
      expect(report.problemCount, 1);
    });

    test('查重命中的题带上已有 id', () async {
      final http = FakeHttp([FakeHttp.ok(_payload([_oneProblem]))]);
      final session = IngestSession(
        client: _client(http),
        loadAttachment: FakeLoader().call,
        findDuplicates: (fp) async => ['2023-shu1-T18'],
        sources: [_src('a.png')],
      );

      final report = await session.run();
      expect(report.duplicateCount, 1);
      expect(session.items.single.problems.single.duplicateIds,
          ['2023-shu1-T18']);
    });

    test('查重本身出错不能让解析白做', () async {
      final http = FakeHttp([FakeHttp.ok(_payload([_oneProblem]))]);
      final session = IngestSession(
        client: _client(http),
        loadAttachment: FakeLoader().call,
        findDuplicates: (_) async => throw Exception('库锁住了'),
        sources: [_src('a.png')],
      );

      final report = await session.run();
      expect(report.done, 1);
      expect(report.problemCount, 1);
      expect(session.items.single.problems.single.isDuplicate, isFalse);
    });

    test('解析层的警告挂在对应来源上，不让整条失败', () async {
      final http = FakeHttp([
        FakeHttp.ok(_payload([
          {'stem': '', 'answer': '1'},
          _oneProblem,
        ])),
      ]);
      final session = IngestSession(
        client: _client(http),
        loadAttachment: FakeLoader().call,
        sources: [_src('a.png')],
      );

      await session.run();
      final item = session.items.single;
      expect(item.status, IngestStatus.done, reason: '丢弃一条不算整页失败');
      expect(item.problems.length, 1);
      expect(item.error, contains('没有题干'));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  group('导入前预估', () {
    test('按来源清单算页数、token 与费用', () {
      final e = estimateIngest(
        [
          _src('a.png', size: 500 * 1024),
          _src('b.png', size: 500 * 1024),
          _src('c.pdf', kind: IngestSourceKind.pdf, size: 600 * 1024),
        ],
        model: 'gpt-4o-mini',
      );
      expect(e.images, 2);
      expect(e.pdfs, 1);
      expect(e.sourceCount, 3);
      // 图片各 1 页；PDF 按 300KB/页 粗估 2 页
      expect(e.pages, 4);
      expect(e.estInputTokens, greaterThan(0));
      expect(e.estCostYuan, isNotNull);
      // PDF 整份发送这件事必须说出来
      expect(e.notes.any((n) => n.contains('整份')), isTrue);
    });

    test('超限的文件被点名，且说明不会计费', () {
      final e = estimateIngest(
        [_src('huge.png', size: kMaxImageBytes + 1)],
        model: 'gpt-4o-mini',
      );
      expect(e.notes.any((n) => n.contains('超过单文件上限')), isTrue);
      expect(e.notes.any((n) => n.contains('不会发送')), isTrue);
    });

    test('价目表里没有的模型：费用为未知而不是 0', () {
      // 显示 ¥0.00 会让用户以为免费 —— 那是个谎
      final e = estimateIngest([_src('a.png')], model: 'some-unknown-model');
      expect(e.estCostYuan, isNull);
      expect(e.costText, contains('未知'));
    });

    test('空清单不会崩', () {
      final e = estimateIngest(const [], model: 'gpt-4o-mini');
      expect(e.sourceCount, 0);
      expect(e.pages, 0);
      expect(e.estCostYuan, 0);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  group('来源模型', () {
    test('按扩展名判定类型与 MIME', () {
      expect(mimeForPath('a.PNG'), 'image/png');
      expect(mimeForPath('a.jpeg'), 'image/jpeg');
      expect(mimeForPath('a.pdf'), 'application/pdf');
      expect(mimeForPath('a.docx'), isNull, reason: '不支持的格式要能被认出来');
    });

    test('不支持的扩展名不生成来源', () {
      expect(IngestSource.fromPath('a.docx'), isNull);
      expect(IngestSource.fromPath('a.png'), isNotNull);
    });

    test('PDF 页数用体积粗估，图片恒为 1 页', () {
      expect(_src('a.png', size: 5 * 1024 * 1024).estimatedPages, 1);
      expect(
        _src('a.pdf', kind: IngestSourceKind.pdf, size: 900 * 1024).estimatedPages,
        3,
      );
    });

    test('草稿转换：导入的题一律先标记待人工确认', () {
      final p = ExtractedProblem(
        stem: '题干',
        answer: '答',
        qtype: QuestionType.fill,
        difficulty: 3,
      );
      final d = p.toDraft(subject: 'math1');
      expect(d.subject, 'math1');
      expect(d.qtype, QuestionType.fill);
      expect(d.difficulty, 3);
      expect(d.needsReview, isTrue, reason: '模型读图的结果，用户看过才算数');
      expect(d.aiTagged, isFalse, reason: '知识点还没打标');
    });

    test('指纹与 domain 层同一实现（同一道题重复导入能被认出）', () {
      final p = ExtractedProblem(stem: '求极限，当 \$x\\to0\$ 时。');
      expect(p.fingerprint, ExtractedProblem.fingerprintOf(p.stem));
      expect(p.fingerprint, isNotEmpty);
    });
  });
}
