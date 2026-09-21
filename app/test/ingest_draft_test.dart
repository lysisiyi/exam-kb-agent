/// 批量导入进度持久化（T49）测试。
///
/// ## 这条为什么值得单独一组测试
///
/// 它的失效方式**不会报错**：草稿写坏了、状态归一错了、
/// 恢复时把已完成的来源又跑了一遍 —— 三种情况界面都"看起来正常"，
/// 唯一的区别是用户的账单。所以这里断言的重点全是**钱**：
/// 请求发了几次、哪些来源被跳过了、用量有没有接上。
///
/// `--no-pub` 与假 HTTP 适配器意味着整组用例离线可跑、零费用。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/core/layout/breakpoints.dart';
import 'package:kaoyan_math_agent/core/providers.dart';
import 'package:kaoyan_math_agent/data/markdown/problem_markdown.dart';
import 'package:kaoyan_math_agent/domain/fingerprint.dart';
import 'package:kaoyan_math_agent/features/ingest/ingest_page.dart';
import 'package:kaoyan_math_agent/services/ingest/ingest_draft.dart';
import 'package:kaoyan_math_agent/services/ingest/ingest_models.dart';
import 'package:kaoyan_math_agent/services/ingest/ingest_session.dart';
import 'package:kaoyan_math_agent/services/llm/llm_client.dart';
import 'package:kaoyan_math_agent/services/llm/llm_settings.dart';
import 'package:kaoyan_math_agent/services/llm/provider_registry.dart';

import 'support/test_env.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 测试替身
// ─────────────────────────────────────────────────────────────────────────────

/// 可编排的假 HTTP 适配器（与 `ingest_test.dart` 同一套写法）。
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
}

final Uint8List _pngBytes = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]);

Future<ChatAttachment> _loader(IngestSource s) async => ChatAttachment(
      kind: s.isPdf ? ChatAttachmentKind.pdf : ChatAttachmentKind.image,
      mimeType: s.isPdf ? 'application/pdf' : 'image/png',
      bytes: _pngBytes,
      name: s.name,
    );

LlmClient _client(HttpAdapter http) => LlmClient(
      config: const LlmConfig(
        providerId: 'openai',
        apiKey: 'sk-test',
        modelOverride: 'gpt-4o-mini',
      ),
      http: http,
      sleep: (_) async {},
    );

IngestSource _src(String name) => IngestSource(
      path: '/tmp/$name',
      name: name,
      sizeBytes: 1024,
      kind: IngestSourceKind.image,
    );

String _payload(String stem) => jsonEncode({
      'problems': [
        {
          'stem': stem,
          'answer': r'$1$',
          'solution': '略。',
          'answer_from_source': true,
          'qtype': 'solve',
          'difficulty': 2,
          'confidence': 0.9,
        }
      ],
    });

IngestItem _doneItem(String name, String stem, {LlmUsage usage = const LlmUsage()}) =>
    IngestItem(
      source: _src(name),
      status: IngestStatus.done,
      problems: [ExtractedProblem(stem: stem, answer: r'$1$', sourceName: name)],
      usage: usage,
    );

IngestItem _failedItem(String name) => IngestItem(
      source: _src(name),
      status: IngestStatus.failed,
      error: '上次失败了',
    );

void main() {
  // ═══════════════════════════════════════════════════════════════════════════
  group('草稿的统计口径', () {
    test('remaining / parsed / isAllParsed 三者互不矛盾', () {
      final d = IngestDraft(items: [
        _doneItem('a.png', '题一'),
        _failedItem('b.png'),
        IngestItem(source: _src('c.png')),
      ]);

      expect(d.total, 3);
      expect(d.parsed, 1);
      expect(d.failed, 1);
      // 失败的要重试、没跑的更要跑 —— 两者都算"还会花钱"。
      // 口径若是 `!isFinished`（失败也算结束），这里会算成 1，
      // 而界面就会说"还剩 1 个"，把失败那一项藏起来。
      expect(d.remaining, 2);
      expect(d.isAllParsed, isFalse);
      expect(d.problemCount, 1);
      expect(d.summary, '3 个来源 · 已解析 1 · 失败 1 · 共 1 题');
    });

    test('只有失败、没有成功的草稿仍然"有活要干"', () {
      // 用户最需要这一条：整批都失败了，重来一次还是重新花钱，
      // 所以必须还能从草稿里恢复出"哪些已经放弃过"
      final d = IngestDraft(items: [_failedItem('a.png')]);
      expect(d.parsed, 0);
      expect(d.remaining, 1);
      expect(d.isAllParsed, isFalse);
    });

    test('全部解析成功时 isAllParsed 为真', () {
      final d = IngestDraft(items: [
        _doneItem('a.png', '题一'),
        _doneItem('b.png', '题二'),
      ]);
      expect(d.remaining, 0);
      expect(d.isAllParsed, isTrue);
    });

    test('一个来源都没跑完的草稿不值得留着', () {
      // 留着只会在下次打开时弹一条"上次没做完"，
      // 而点进去和重新开始完全一样 —— 纯噪声。
      expect(IngestDraft(items: [IngestItem(source: _src('a.png'))])
          .isWorthKeeping, isFalse);
      expect(IngestDraft(items: [_failedItem('a.png')]).isWorthKeeping, isTrue);
      expect(IngestDraft(items: [_doneItem('a.png', '题一')]).isWorthKeeping,
          isTrue);
    });

    test('来源集合一致就算同一批（不看顺序）', () {
      final d = IngestDraft(items: [
        _doneItem('a.png', '题一'),
        _doneItem('b.png', '题二'),
      ]);
      // 选文件夹时返回顺序不稳定，按顺序比会白白把可复用的结果丢掉
      expect(d.matchesSources([_src('b.png'), _src('a.png')]), isTrue);
      expect(d.matchesSources([_src('a.png')]), isFalse);
      expect(d.matchesSources([_src('a.png'), _src('c.png')]), isFalse);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  group('序列化', () {
    test('完整往返：状态、题目、错因外的字段、用量都不丢', () {
      final before = IngestDraft(
        items: [
          _doneItem('a.png', '题一', usage: const LlmUsage(inputTokens: 1200, outputTokens: 300, model: 'm')),
          _failedItem('b.png'),
          IngestItem(source: _src('c.png')),
        ],
        usage: const LlmUsage(
            inputTokens: 1200, outputTokens: 300, model: 'm', costYuan: 0.02),
        model: 'gpt-4o-mini',
        savedAt: DateTime(2026, 9, 21, 15, 4),
      );

      final back = IngestDraft.fromJson(
          jsonDecode(jsonEncode(before.toJson())) as Map<String, dynamic>);

      expect(back.total, 3);
      expect(back.items[0].status, IngestStatus.done);
      expect(back.items[1].status, IngestStatus.failed);
      expect(back.items[1].error, '上次失败了');
      expect(back.items[2].status, IngestStatus.pending);
      expect(back.items[0].problems.single.stem, '题一');
      expect(back.items[0].problems.single.answer, r'$1$');
      expect(back.usage.inputTokens, 1200);
      expect(back.usage.costYuan, 0.02);
      expect(back.model, 'gpt-4o-mini');
      expect(back.savedAt, DateTime(2026, 9, 21, 15, 4));
      // 顺序必须与来源清单一致，否则题会挂到别的来源下面
      expect([for (final i in back.items) i.source.name],
          ['a.png', 'b.png', 'c.png']);
    });

    test('指纹不落盘，读回来按当前算法现算', () {
      final d = IngestDraft(items: [_doneItem('a.png', '求极限')]);
      final j = d.toJson();
      final item = (j['items'] as List).single as Map;
      final problem = (item['problems'] as List).single as Map;

      // 存一份指纹 = 存一把可能过期的尺子（换版本后查重会失配）
      expect(problem.containsKey('fingerprint'), isFalse);

      final back = IngestDraft.fromJson(
          jsonDecode(jsonEncode(j)) as Map<String, dynamic>);
      expect(back.items.single.problems.single.fingerprint,
          ProblemFingerprint.compute('求极限'));
    });

    test('题型 / 来源类型这些枚举按 id 走，不会因为改名而错位', () {
      final p = ExtractedProblem(
        stem: 's',
        qtype: QuestionType.choice,
        sourceType: SourceType.realExam,
        options: const ['1', '2'],
        sourceYear: 2023,
      );
      final back =
          ExtractedProblem.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
      expect(back.qtype, QuestionType.choice);
      expect(back.sourceType, SourceType.realExam);
      expect(back.options, ['1', '2']);
      expect(back.sourceYear, 2023);
    });

    test('认不出的状态退回 pending —— 宁可重花一次钱，也不能假装跑完了', () {
      final back = IngestItem.fromJson({
        'source': {'path': '/tmp/a.png', 'name': 'a.png', 'size': 1, 'kind': 'image'},
        'status': 'something_from_the_future',
      });
      expect(back.status, IngestStatus.pending);
    });

    test('版本号不认识时明确拒绝，不猜', () {
      expect(
        () => IngestDraft.fromJson({
          'version': kIngestDraftVersion + 1,
          'items': <Object>[],
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  group('草稿读写', () {
    late Directory dir;
    late IngestDraftStore store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('dsh-draft-');
      store = IngestDraftStore.at(dir);
    });

    tearDown(() async {
      if (dir.existsSync()) {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }
    });

    test('写进去能读回来', () async {
      final d = IngestDraft(items: [_doneItem('a.png', '题一')]);
      expect(await store.save(d), isNull);

      final res = await store.load();
      expect(res.error, isNull);
      expect(res.draft, isNotNull);
      expect(res.draft!.items.single.problems.single.stem, '题一');
    });

    test('没有草稿是正常状态：不报错、也不算"读不出来"', () async {
      final res = await store.load();
      expect(res.draft, isNull);
      // 「没有草稿」与「草稿坏了」必须分得开
      expect(res.error, isNull);
    });

    test('草稿是垃圾时如实说出来 —— 不许静默丢掉一批花过钱的结果', () async {
      await File('${dir.path}/$kIngestDraftFileName')
          .writeAsString('{这不是 JSON');

      final res = await store.load();
      expect(res.draft, isNull);
      expect(res.error, isNotNull);
      expect(res.error, contains('读不出来'));
      // 用户需要知道"重新解析要重新花钱"，否则他不会意识到损失
      expect(res.error, contains('重新花钱'));
    });

    test('主文件丢了但 .tmp 完整时能救回来', () async {
      // 这是 atomicWriteString 在 Windows 上的真实窗口：写 tmp → 删目标 →
      // 改名，中间崩掉就会只剩一个 .tmp。对草稿来说多读一个文件就能
      // 救回一整批花过钱的结果，这个便宜值得占。
      final d = IngestDraft(items: [_doneItem('a.png', '题一')]);
      await File('${dir.path}/$kIngestDraftFileName.tmp')
          .writeAsString(jsonEncode(d.toJson()));

      final res = await store.load();
      expect(res.draft, isNotNull);
      expect(res.draft!.items.single.problems.single.stem, '题一');
      // 顺手补成正式文件，免得下次还在赌那个 .tmp
      expect(File('${dir.path}/$kIngestDraftFileName').existsSync(), isTrue);
    });

    test('clear 连 .tmp 一起删 —— 否则下次会从它那儿"救"回一份旧数据', () async {
      final d = IngestDraft(items: [_doneItem('a.png', '题一')]);
      await store.save(d);
      await File('${dir.path}/$kIngestDraftFileName.tmp')
          .writeAsString(jsonEncode(d.toJson()));

      await store.clear();

      expect(File('${dir.path}/$kIngestDraftFileName').existsSync(), isFalse);
      expect(File('${dir.path}/$kIngestDraftFileName.tmp').existsSync(), isFalse);
      expect((await store.load()).draft, isNull);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  group('断点续跑：已完成的来源不再花钱', () {
    test('三个来源里有一个已完成 → 只发两次请求，题一道不少', () async {
      final http = FakeHttp([
        FakeHttp.ok(_payload('新题一'), inTok: 1000, outTok: 200),
        FakeHttp.ok(_payload('新题二'), inTok: 1000, outTok: 200),
      ]);
      final session = IngestSession(
        client: _client(http),
        loadAttachment: _loader,
        sources: [_src('a.png'), _src('b.png'), _src('c.png')],
        initialItems: [
          _doneItem('a.png', '上次已解析的题',
              usage: const LlmUsage(inputTokens: 900, outputTokens: 100)),
        ],
      );

      final report = await session.run();

      // 这就是 T49 的全部意义
      expect(http.requests.length, 2, reason: '已完成的来源不该再发请求');
      expect(report.done, 3);
      expect(session.items[0].problems.single.stem, '上次已解析的题');
      expect(report.problemCount, 3);
    });

    test('累计用量把上半场算进去', () async {
      final http = FakeHttp([FakeHttp.ok(_payload('新题'), inTok: 1000, outTok: 200)]);
      final session = IngestSession(
        client: _client(http),
        loadAttachment: _loader,
        sources: [_src('a.png'), _src('b.png')],
        initialItems: [_doneItem('a.png', '题', usage: const LlmUsage(inputTokens: 900, outputTokens: 100))],
      );

      final report = await session.run();

      // 只报这一次的钱会让用户以为"续跑很便宜"
      expect(report.usage.inputTokens, 1900);
      expect(report.usage.outputTokens, 300);
    });

    test('上次失败的来源会被重试，已完成的仍然不动', () async {
      final http = FakeHttp([FakeHttp.ok(_payload('补上的题'))]);
      final session = IngestSession(
        client: _client(http),
        loadAttachment: _loader,
        sources: [_src('a.png'), _src('b.png')],
        initialItems: [_failedItem('a.png'), _doneItem('b.png', '上次成功那题')],
      );

      final report = await session.run();

      // 失败项没有结果，重试才有意义；而成功的那一项一次请求都不该发
      expect(http.requests.length, 1);
      expect(http.requests.single.body, contains('a.png'));
      expect(report.failed, 0);
      expect(session.items[0].isDone, isTrue);
      expect(session.items[0].problems.single.stem, '补上的题');
      expect(session.items[1].problems.single.stem, '上次成功那题');
    });

    test('结果条数与来源对不上时，缺的来源补成待处理而不是被漏掉', () async {
      // 静默漏来源是这条链路上最坏的失效方式：界面显示"解析完成"，
      // 只是题少了几道，用户没有任何线索。
      final http = FakeHttp([
        FakeHttp.ok(_payload('b 的题')),
        FakeHttp.ok(_payload('c 的题')),
      ]);
      final session = IngestSession(
        client: _client(http),
        loadAttachment: _loader,
        sources: [_src('a.png'), _src('b.png'), _src('c.png')],
        // 只给了一条结果
        initialItems: [_doneItem('a.png', 'a 的题')],
      );

      final report = await session.run();

      expect(session.items.length, 3);
      expect(http.requests.length, 2, reason: '缺的两个来源必须真的去跑');
      expect(report.done, 3);
    });

    test('进度条不会因为复用了旧结果而少一截', () async {
      final http = FakeHttp([FakeHttp.ok(_payload('新题'))]);
      final session = IngestSession(
        client: _client(http),
        loadAttachment: _loader,
        sources: [_src('a.png'), _src('b.png')],
        initialItems: [_doneItem('a.png', '题')],
      );

      final progress = <IngestProgress>[];
      await session.run(onProgress: progress.add);

      // 一开始就该是 1/2，而不是 0/2 —— 否则用户会以为白干了一半
      expect(progress.first.finished, 1);
      expect(progress.last.finished, 2);
      expect(progress.last.isComplete, isTrue);
    });

    test('中断时停在 running 的来源，快照里归为 pending；再跑会重做', () async {
      // 崩溃/断电时正在跑的那个来源**没有拿到结果**。
      // 记成 running 会让界面永远显示"解析中"；记成 done 会静默丢一个来源。
      final session = IngestSession(
        client: _client(FakeHttp([FakeHttp.ok(_payload('题'))])),
        loadAttachment: _loader,
        sources: [_src('a.png')],
        initialItems: [
          IngestItem(source: _src('a.png'), status: IngestStatus.running),
        ],
      );

      final snap = session.snapshot(model: 'm');
      expect(snap.items.single.status, IngestStatus.pending);
      expect(snap.isWorthKeeping, isFalse, reason: '没有任何结果，不值得留');

      // 带着 pending 快照恢复后，它会真的被处理
      final http2 = FakeHttp([FakeHttp.ok(_payload('题'))]);
      final resumed = IngestSession(
        client: _client(http2),
        loadAttachment: _loader,
        sources: [_src('a.png')],
        initialItems: snap.items,
      );
      final report = await resumed.run();
      expect(http2.requests.length, 1);
      expect(report.done, 1);
    });

    test('快照带着累计用量与模型名', () async {
      final session = IngestSession(
        client: _client(FakeHttp([FakeHttp.ok(_payload('题'), inTok: 700, outTok: 80)])),
        loadAttachment: _loader,
        sources: [_src('a.png')],
      );
      await session.run();

      final snap = session.snapshot(model: 'gpt-4o-mini');
      expect(snap.model, 'gpt-4o-mini');
      expect(snap.usage.inputTokens, 700);
      expect(snap.items.single.status, IngestStatus.done);
      expect(snap.isWorthKeeping, isTrue);
      // 落盘再读回来，用量还在
      final back = IngestDraft.fromJson(
          jsonDecode(jsonEncode(snap.toJson())) as Map<String, dynamic>);
      expect(back.usage.inputTokens, 700);
    });

    test('没有客户端时一个请求都不发，并说出来', () async {
      // 用户可能改完设置（甚至清空 Key）才回来接着看上次的结果。
      // 那时"看不到结果"是最不该发生的事，所以 client 可为 null。
      final session = IngestSession(
        client: null,
        loadAttachment: _loader,
        sources: [_src('a.png'), _src('b.png')],
        initialItems: [_doneItem('a.png', '旧结果')],
      );

      final report = await session.run();

      expect(report.done, 1);
      expect(session.items[0].problems.single.stem, '旧结果');
      expect(report.notes.single, contains('没有可用的 AI 服务商配置'));
      expect(report.usage.totalTokens, 0);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  //
  // 下面这组测的是**接线**：盘上真有一个草稿文件时，页面到底怎么表现。
  // 上面那些用例保证了零件是对的，这一组保证零件真的被装上了。
  group('页面接线：草稿在盘上时', () {
    late TempLibrary env;

    /// 往题库根目录写一份草稿，然后挂起导入页。
    Future<void> pumpWithDraft(
      WidgetTester tester,
      IngestDraft? draft, {
      String? rawContent,
    }) async {
      await tester.runAsync(() async {
        env = await TempLibrary.create();
        final store = IngestDraftStore.at(env.paths.root);
        if (rawContent != null) {
          await File('${env.paths.root.path}/$kIngestDraftFileName')
              .writeAsString(rawContent);
        } else if (draft != null) {
          await store.save(draft);
        }
      });
      addTearDown(() async {
        await tester.runAsync(env.dispose);
      });

      const size = Size(1100, 900);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWith((ref) async => env.db),
            problemStoreProvider.overrideWith((ref) async => env.store),
            libraryPathsProvider.overrideWith((ref) async => env.paths),
            llmSettingsProvider.overrideWith((ref) async => LlmSettings.none),
          ],
          child: BreakpointScope.fromSize(
            size: size,
            child: const MaterialApp(home: Scaffold(body: IngestPage())),
          ),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    /// 点一下按钮并等真实 IO 走完。
    ///
    /// `testWidgets` 用的是假异步时钟：`tester.tap` + `pumpAndSettle`
    /// **不会**推进 `File.delete()` / `readAsString()` 这类真实 IO，
    /// 于是 await 卡住、`setState` 永远不执行 —— 断言看到的还是旧界面。
    /// 见 `test_env.dart` 顶部关于 `runAsync` 的说明。
    Future<void> tapAndFlush(WidgetTester tester, Finder finder) async {
      await tester.tap(finder);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
    }

    testWidgets('有没做完的草稿：横幅说清"已解析的不会再花钱"', (tester) async {
      await pumpWithDraft(
        tester,
        IngestDraft(items: [
          _doneItem('a.png', '上次解析出来的题'),
          IngestItem(source: _src('b.png')),
        ]),
      );

      expect(tester.takeException(), isNull);
      expect(find.textContaining('上次有一批导入没做完'), findsOneWidget);
      expect(find.textContaining('已解析 1'), findsOneWidget);
      expect(find.textContaining('不会再花一次钱'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '继续上次'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, '丢弃这批进度'), findsOneWidget);
    });

    testWidgets('失败项要在横幅里被点名"会重试"', (tester) async {
      await pumpWithDraft(
        tester,
        IngestDraft(items: [
          _doneItem('a.png', '题'),
          _failedItem('b.png'),
        ]),
      );

      expect(find.textContaining('1 个上次失败，会重试'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '继续上次'), findsOneWidget);
    });

    testWidgets('全部解析成功时不给「继续上次」——点了也不会发生任何事', (tester) async {
      await pumpWithDraft(
        tester,
        IngestDraft(items: [
          _doneItem('a.png', '题一'),
          _doneItem('b.png', '题二'),
        ]),
      );

      expect(find.textContaining('已经全部跑完'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '继续上次'), findsNothing);
      // 入库确认完之后，用户唯一还需要做的事就是清掉它
      expect(find.widgetWithText(OutlinedButton, '丢弃这批进度'), findsOneWidget);
    });

    testWidgets('点「继续上次」把结果摆回界面，并且一次请求都不发', (tester) async {
      await pumpWithDraft(
        tester,
        IngestDraft(items: [
          _doneItem('a.png', '上次解析出来的题'),
          IngestItem(source: _src('b.png')),
        ]),
      );

      await tapAndFlush(tester, find.widgetWithText(FilledButton, '继续上次'));

      expect(tester.takeException(), isNull);
      // 横幅消失，结果列表出现（来源名就在列表里）
      expect(find.textContaining('上次有一批导入没做完'), findsNothing);
      expect(find.text('a.png'), findsWidgets);
      expect(find.text('b.png'), findsWidgets);
      // 状态栏要说清"这是恢复的"，别让用户以为刚跑过一遍
      expect(find.textContaining('已恢复上次的结果'), findsOneWidget);
      expect(find.textContaining('还有 1 个来源没跑完'), findsOneWidget);
    });

    testWidgets('点「丢弃这批进度」会真的把文件删掉', (tester) async {
      var existed = false;
      await pumpWithDraft(
        tester,
        IngestDraft(items: [_doneItem('a.png', '题')]),
      );
      await tester.runAsync(() async {
        existed = File('${env.paths.root.path}/$kIngestDraftFileName')
            .existsSync();
      });
      expect(existed, isTrue);

      await tapAndFlush(
          tester, find.widgetWithText(OutlinedButton, '丢弃这批进度'));

      expect(find.textContaining('上次有一批导入没做完'), findsNothing);
      var stillThere = true;
      await tester.runAsync(() async {
        stillThere = File('${env.paths.root.path}/$kIngestDraftFileName')
            .existsSync();
      });
      expect(stillThere, isFalse);
      // 说明：此时还没有结果列表，`_discardDraft` 写的那句状态栏文案
      // 渲染不出来（`_status` 挂在 `_ResultsHeader` 里），
      // 所以这件事的反馈就是"横幅消失 + 文件真的没了"。
    });

    testWidgets('草稿坏掉时如实说一句，而不是静默丢掉', (tester) async {
      // 静默的行为会让"丢了一批花过钱的结果"这件事永远没人发现
      await pumpWithDraft(tester, null, rawContent: '{这不是 JSON');

      expect(tester.takeException(), isNull);
      expect(find.textContaining('读不出来'), findsOneWidget);
      expect(find.textContaining('重新花钱'), findsOneWidget);
      expect(find.textContaining('上次有一批导入没做完'), findsNothing);
    });

    testWidgets('没有草稿时不该冒出任何相关提示', (tester) async {
      await pumpWithDraft(tester, null);

      expect(tester.takeException(), isNull);
      expect(find.textContaining('上次有一批导入没做完'), findsNothing);
      expect(find.textContaining('读不出来'), findsNothing);
    });
  });
}
