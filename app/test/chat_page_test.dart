/// 对话页：发消息、流式显示、落盘、出错与停止。
///
/// ## 这里要守的几条
///
/// - **流式回复要真的显示出来**，而不是等整段结束才出现（那样流式就白做了）。
/// - **回复要落库**，且正常收尾时 `interrupted = false`；
///   出错/停止时留内容但标记未完成 —— 半句话不能伪装成完整回答。
/// - **没配服务商时要说清去哪配**，而不是静默什么都不发生。
///
/// 数据库用内存库，模型用假适配器 —— 不起网络、不花 token。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/core/layout/breakpoints.dart';
import 'package:kaoyan_math_agent/core/providers.dart';
import 'package:kaoyan_math_agent/data/db/database.dart';
import 'package:kaoyan_math_agent/features/chat/chat_page.dart';
import 'package:kaoyan_math_agent/services/chat/chat_store.dart';
import 'package:kaoyan_math_agent/services/llm/llm_client.dart';
import 'package:kaoyan_math_agent/services/llm/provider_registry.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 脚手架
// ─────────────────────────────────────────────────────────────────────────────

/// 按轮次吐块的假适配器。
class FakeStreamHttp extends HttpAdapter {
  final List<List<Object>> rounds;
  final List<HttpRequest> requests = [];
  int _i = 0;

  FakeStreamHttp(this.rounds);

  @override
  Future<HttpResponse> send(HttpRequest request) =>
      throw StateError('对话只走流式，不该调 send');

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

/// 在 yield 之间真正等待的适配器，用来制造"流还在进行中"的窗口。
class SlowStreamHttp extends HttpAdapter {
  @override
  Future<HttpResponse> send(HttpRequest request) =>
      throw StateError('对话只走流式，不该调 send');

  @override
  Stream<HttpStreamChunk> sendStream(HttpRequest request) async* {
    yield _c(_sse(_delta('第一段')));
    await Future<void>.delayed(const Duration(seconds: 5));
    yield _c(_sse(_delta('第二段')));
  }
}

LlmClient _client(HttpAdapter http) => LlmClient(
      config: const LlmConfig(
        providerId: 'openai',
        apiKey: 'k',
        modelOverride: 'gpt-4o-mini',
      ),
      http: http,
      sleep: (_) async {},
    );

String _delta(String t) => jsonEncode({
      'choices': [
        {
          'delta': {'content': t},
        }
      ],
    });

String _stop() => jsonEncode({
      'choices': [
        {
          'delta': <String, dynamic>{},
          'finish_reason': 'stop',
        }
      ],
      'usage': {'prompt_tokens': 20, 'completion_tokens': 8},
    });

String _sse(String payload) => 'data: $payload\n\n';

HttpStreamChunk _c(String text) =>
    HttpStreamChunk(statusCode: 200, text: text);

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.memory();
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> pumpChat(
    WidgetTester tester, {
    LlmClient? client,
    Size size = const Size(1200, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWith((ref) async => db),
          // 直接给客户端，绕开真实的安全存储与网络
          chatClientProvider.overrideWith((ref) => client),
        ],
        child: MaterialApp(
          home: BreakpointScope.fromSize(
            size: size,
            child: const Scaffold(body: ChatPage()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 只在**消息气泡**里找这段文字。
  ///
  /// ⚠️ 不能用裸的 `find.text`：同一句话会同时出现在会话列表的标题、
  /// 页面顶部的标题和气泡里，一句 `findsOneWidget` 直接挂掉 ——
  /// 而失败信息里列三个控件，看起来很像"内容重复渲染了"的 bug。
  Finder bubbleWith(String text) => find.descendant(
        of: find.byType(ChatBubble),
        matching: find.text(text),
      );

  /// 输入并点发送。
  Future<void> sendText(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();
  }

  // ───────────────────────────────────────────────────────────────────────────
  group('空态与配置缺失', () {
    testWidgets('一条消息都没有时给出引导，而不是空白', (tester) async {
      await pumpChat(tester);

      expect(find.text('有什么想问的？'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('没配服务商：说清去哪配，不是静默无反应', (tester) async {
      await pumpChat(tester, client: null);

      await sendText(tester, '洛必达什么时候能用');

      expect(find.textContaining('还没有配置 AI 服务商'), findsOneWidget);
      expect(find.textContaining('设置'), findsWidgets);
    });

    testWidgets('能力边界在顶部常态显示（不能只写在提示词里）', (tester) async {
      await pumpChat(tester);

      expect(find.textContaining('看不到你的题库'), findsOneWidget);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('发消息', () {
    testWidgets('用户消息与流式回复都显示出来', (tester) async {
      await pumpChat(
        tester,
        client: _client(FakeStreamHttp([
          [
            _c(_sse(_delta('洛必达'))),
            _c(_sse(_delta('可以用'))),
            _c(_sse(_stop())),
          ],
        ])),
      );

      await sendText(tester, '洛必达什么时候能用');

      expect(bubbleWith('洛必达什么时候能用'), findsOneWidget);
      expect(bubbleWith('洛必达可以用'), findsOneWidget);
    });

    testWidgets('回复落库，且正常收尾时标记为已完成', (tester) async {
      await pumpChat(
        tester,
        client: _client(FakeStreamHttp([
          [
            _c(_sse(_delta('答'))),
            _c(_sse(_stop())),
          ],
        ])),
      );

      await sendText(tester, '问');

      final store = ChatStore(db);
      final sessions = await store.listSessions();
      expect(sessions.length, 1, reason: '发过消息就该有一条会话');

      final s = await store.load(sessions.single.id);
      expect(s!.entries.map((e) => e.content).toList(), ['问', '答']);
      expect(s.entries.last.interrupted, isFalse,
          reason: '正常收尾不能留着"未完成"的标记');
    });

    testWidgets('会话标题取首条消息（否则顶部一直显示"新对话"）', (tester) async {
      await pumpChat(
        tester,
        client: _client(FakeStreamHttp([
          [
            _c(_sse(_delta('嗯'))),
            _c(_sse(_stop())),
          ],
        ])),
      );

      await sendText(tester, '洛必达法则的适用条件');

      final store = ChatStore(db);
      final sessions = await store.listSessions();
      expect(sessions.single.title, '洛必达法则的适用条件');
    });

    testWidgets('历史轮次发进请求体（否则模型记不住上文）', (tester) async {
      final http = FakeStreamHttp([
        [
          _c(_sse(_delta('第一答'))),
          _c(_sse(_stop())),
        ],
        [
          _c(_sse(_delta('第二答'))),
          _c(_sse(_stop())),
        ],
      ]);
      await pumpChat(tester, client: _client(http));

      await sendText(tester, '第一个问题');
      await sendText(tester, '第二个问题');

      final second = jsonDecode(http.requests.last.body ?? '{}') as Map;
      final messages = (second['messages'] as List).cast<Map<String, dynamic>>();
      // system + 问1 + 答1 + 问2
      expect(messages.length, 4, reason: '第二轮必须带上第一轮，否则等于每次都在重新开始');
      expect(messages[2]['content'], '第一答');
      expect(messages[3]['content'], '第二个问题');
      expect(messages.last['role'], 'user');
    });

    testWidgets('用量写进这一条回复', (tester) async {
      await pumpChat(
        tester,
        client: _client(FakeStreamHttp([
          [
            _c(_sse(_delta('答'))),
            _c(_sse(_stop())),
          ],
        ])),
      );

      await sendText(tester, '问');

      final store = ChatStore(db);
      final s = await store.load((await store.listSessions()).single.id);
      expect(s!.entries.last.usage.totalTokens, 28);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('出错与停止', () {
    testWidgets('中途断了：已收到的内容留着，并标注这条没写完', (tester) async {
      await pumpChat(
        tester,
        client: _client(FakeStreamHttp([
          [
            _c(_sse(_delta('说到一半就'))),
            const HttpTransportException('连接被掐断'),
          ],
        ])),
      );

      await sendText(tester, '问');

      // 已经吐出来的字用户已经看见了，收不回来，就该留着
      expect(find.text('说到一半就'), findsOneWidget);
      expect(find.textContaining('这条回复被中断了'), findsOneWidget);
      expect(find.textContaining('这一轮没跑完'), findsOneWidget);

      final store = ChatStore(db);
      final s = await store.load((await store.listSessions()).single.id);
      expect(s!.entries.last.content, '说到一半就');
      expect(s.entries.last.interrupted, isTrue);
    });

    testWidgets('空回复（一个字都没吐）也标注为未完成', (tester) async {
      await pumpChat(
        tester,
        client: _client(FakeStreamHttp([
          [const HttpTransportException('断了')],
        ])),
      );

      await sendText(tester, '问');

      final store = ChatStore(db);
      final s = await store.load((await store.listSessions()).single.id);
      expect(s!.entries.last.interrupted, isTrue);
    });

    testWidgets('按停止：内容停在那里，并说清费用不会退', (tester) async {
      await pumpChat(tester, client: _client(SlowStreamHttp()));

      await tester.enterText(find.byType(TextField), '问');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pump(); // 发出
      await tester.pump(const Duration(milliseconds: 50)); // 收到第一段

      expect(find.text('第一段'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.stop));
      await tester.pump();
      // 让那个 5 秒的等待到期，循环会在下一个事件处退出
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();

      expect(find.text('第一段'), findsOneWidget);
      expect(find.text('第二段'), findsNothing,
          reason: '按了停止之后的内容不该再进来');
      // ⚠️ 说"停止接收"而不是"已取消"：服务端那一次生成还在跑，钱照花
      expect(find.textContaining('已停止接收'), findsOneWidget);
      expect(find.textContaining('不会退回'), findsOneWidget);

      final store = ChatStore(db);
      final s = await store.load((await store.listSessions()).single.id);
      expect(s!.entries.last.interrupted, isTrue);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('历史会话', () {
    testWidgets('宽屏显示历史列表，窄屏改成抽屉按钮', (tester) async {
      await pumpChat(tester);
      expect(find.text('历史对话'), findsOneWidget);
      // 宽屏是内嵌列表，没有抽屉按钮
      expect(find.byIcon(Icons.history), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();

      await pumpChat(tester, size: const Size(420, 860));
      expect(find.byIcon(Icons.history), findsOneWidget,
          reason: '窄屏放不下列表，但历史入口不能消失');
    });

    testWidgets('点历史会话能回到那段对话（含之前的消息）', (tester) async {
      // 先手工造一段历史
      final store = ChatStore(db);
      final sid = await store.createSession(title: '上次聊的');
      await store.appendUserMessage(sid, '上一次的问题');
      final turn = await store.beginAssistantTurn(sid);
      await store.updateTurn(turn, content: '上一次的回答',
          interrupted: false, force: true);

      await pumpChat(tester);

      expect(find.text('上次聊的'), findsOneWidget);
      await tester.tap(find.text('上次聊的'));
      await tester.pumpAndSettle();

      expect(find.text('上一次的问题'), findsOneWidget);
      expect(find.text('上一次的回答'), findsOneWidget);
    });

    testWidgets('删除历史会话后列表里就没有了', (tester) async {
      final store = ChatStore(db);
      final sid = await store.createSession(title: '要删掉的');
      await store.appendUserMessage(sid, '一句话');

      await pumpChat(tester);
      expect(find.text('要删掉的'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.delete_outline).first);
      await tester.pumpAndSettle();

      expect(find.text('要删掉的'), findsNothing);
      expect(await store.load(sid), isNull);
    });

    testWidgets('新对话按钮清空当前内容', (tester) async {
      await pumpChat(
        tester,
        client: _client(FakeStreamHttp([
          [
            _c(_sse(_delta('答'))),
            _c(_sse(_stop())),
          ],
        ])),
      );

      await sendText(tester, '第一段对话的内容');
      expect(bubbleWith('第一段对话的内容'), findsOneWidget);

      await tester.tap(find.text('新对话'));
      await tester.pumpAndSettle();

      // 会话列表里那条还在（它本来就该在），但气泡清空了
      expect(bubbleWith('第一段对话的内容'), findsNothing);
      expect(find.text('有什么想问的？'), findsOneWidget);
    });
  });
}
