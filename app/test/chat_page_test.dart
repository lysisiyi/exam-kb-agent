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
import 'package:kaoyan_math_agent/services/chat/chat_tools.dart';
import 'package:kaoyan_math_agent/services/chat/chat_writes.dart';
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

/// 只用来"让配置看起来是配好的"的客户端：这些用例一条请求都不发。
///
/// 脚本里给一轮正常的收尾，避免将来有人误触发请求时拿到一个
/// 空脚本导致的 RangeError（那种失败会指向脚手架，而不是真实 bug）。
LlmClient _idleClient() => _client(FakeStreamHttp([
      [
        _c(_sse(_delta('（未使用）'))),
        _c(_sse(_stop())),
      ],
    ]));

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

// ── 工具调用的 SSE 构造 ──────────────────────────────────────────────────────

/// 一帧工具调用分片。
///
/// ⚠️ 真实服务商是把参数 JSON **切成好几片**陆续发的（第一片带 id 与函数名，
/// 后面的片只有 `index` 和参数片段）。这里的 `args` 就是要故意分两次传，
/// 才能覆盖"分片拼接"那条路径 —— 一次性发完整 JSON 是测不到的。
String _toolChunk({
  required int index,
  String? id,
  String? name,
  String? args,
}) =>
    jsonEncode({
      'choices': [
        {
          'delta': {
            'tool_calls': [
              {
                'index': index,
                'type': 'function',
                if (id != null) 'id': id,
                'function': {
                  if (name != null) 'name': name,
                  if (args != null) 'arguments': args,
                },
              }
            ],
          }
        }
      ],
    });

String _finishReason(String reason) => jsonEncode({
      'choices': [
        {
          'delta': <String, dynamic>{},
          'finish_reason': reason,
        }
      ],
      'usage': {'prompt_tokens': 10, 'completion_tokens': 5},
    });

/// 一个只有名字的假工具，用来把整条链路跑通而不依赖真实数据。
class _StubTool extends ChatTool {
  final String toolName;
  final ToolOutcome outcome;

  /// 实际收到的参数（测试用它断言"模型传的值有没有原样送到"）。
  final List<Map<String, dynamic>> received = [];

  /// 每次执行前等这么久，用来制造"正在查…"的可见窗口。
  final Duration delay;

  _StubTool(this.toolName, this.outcome, {this.delay = Duration.zero});

  @override
  ToolSpec get spec => ToolSpec(name: toolName, description: '测试用假工具');

  @override
  Future<ToolOutcome> run(Map<String, dynamic> args) async {
    received.add(args);
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return outcome;
  }
}

/// 记录"被执行了几次"的假执行器。
///
/// ## 为什么必须换成假的
///
/// 真实执行器要题目仓库（真文件系统）与组卷仓库（真 asset）。
/// 在 widget 测试里它们**不是失败而是挂住** —— 假时钟不推进真实 IO。
/// 而这里要测的是"点击 → 执行 → 显示结论"这条界面链路，
/// 不是写库本身（那在 `chat_writes_test.dart` 里用真实依赖测过了）。
class _FakeExecutor extends ChatWriteExecutor {
  final List<ChatWriteProposal> applied = [];
  final WriteOutcome result;

  _FakeExecutor(this.result)
      : super(
          // 这三个加载器**一次都不该被调到**：apply 已经被覆盖了。
          // 真被调到说明有人绕过了假执行器去碰真实数据 —— 直接炸出来。
          loadService: () async => throw StateError('不该碰真实数据'),
          loadKnowledge: () async => null,
          loadPaper: () async => throw StateError('不该碰真实数据'),
        );

  @override
  Future<WriteOutcome> apply(ChatWriteProposal p) async {
    applied.add(p);
    return result;
  }
}

/// 一张提案，供界面用例使用。
ChatWriteProposal _proposal({bool destructive = false}) => ChatWriteProposal(
      id: 'prop-1',
      kind: destructive ? kWriteDeleteProblem : kWriteCreateProblem,
      title: destructive ? '删除这道题' : '录入这道题',
      summary: destructive ? '不可逆：连同复习进度一起清掉' : '把上面的内容存进错题本',
      destructive: destructive,
      fields: const [
        WriteField('题干', '证明存在 ξ 使 f\'(ξ)=0'),
        WriteField('错过次数', '4 次'),
      ],
      warning: '这道题现在还不能撤销，确认前请再认一遍。',
      payload: const {'stem': '证明存在 ξ 使 f\'(ξ)=0'},
    );

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
    ChatToolRegistry? tools,
    ChatWriteExecutor? executor,
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
          // ⚠️ 配置也要一起覆盖。之前只有 `chatClientProvider` 被换掉，
          // 而页面的能力说明读的是 `llmConfigProvider` —— 它一路走到
          // 真实的 `LlmSettingsStore`，在测试环境里永远是"没配置"。
          // 于是"配好了"这条分支根本没被测到。两者必须同源。
          llmConfigProvider.overrideWith((ref) => client?.config),
          // 不传就用**真实的**工具集合（只依赖被换成内存库的 database），
          // 这样"注册表能否装配起来"这件事也在页面上被覆盖到。
          // 传 `ChatToolRegistry.empty` 用来测"服务商不支持工具"那条路。
          if (tools != null) chatToolsProvider.overrideWith((ref) async => tools),
          // 不传就用**真实的**执行器（要碰文件系统与 asset，widget 测试里
          // 会挂住）。凡是会点确认的用例都必须传一个假的。
          if (executor != null)
            chatWriteExecutorProvider.overrideWith((ref) async => executor),
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

    testWidgets('能力边界在顶部常态显示，且说清"改动要经你确认"', (tester) async {
      // ⚠️ 必须给一个客户端：不给就等于"没配服务商"，
      // 页面会走"还没配置"那条分支（那是另一个用例的事）。
      await pumpChat(tester, client: _idleClient());

      // 这份配置是 openai —— 工具可用，所以说明应该是"能读"，
      // 而不是 P1 那句"看不到你的题库"（那句话接上工具后就过期了）。
      // P3 之后还要提"改动先确认"：说了能读、不提能改的话，
      // 用户会以为它仍然只能看；只说能改、不提确认的话，他会怕它乱动。
      expect(
        find.textContaining('能读你的错题本、知识点与画像；'),
        findsOneWidget,
      );
      expect(find.textContaining('都会先摆出改动让你确认'), findsOneWidget);
    });

    testWidgets('服务商用不了工具时，顶部要如实说"看不到题库"并给办法', (tester) async {
      await pumpChat(
        tester,
        client: _idleClient(),
        tools: ChatToolRegistry.empty,
      );

      expect(find.textContaining('看不到你的题库'), findsOneWidget);
      // 只说"不行"没有用，要告诉用户换服务商能解决
      expect(find.textContaining('DeepSeek'), findsOneWidget);
    });

    testWidgets('工具可用时空态就引导去问自己的数据（否则没人会去试）', (tester) async {
      await pumpChat(tester, client: _idleClient());

      expect(find.textContaining('我今天该复习什么'), findsOneWidget);
      expect(find.textContaining('它现在读不到你的题库'), findsNothing);
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

    testWidgets('新对话要连带清掉溯源，否则上一段的"查过什么"会跟过来', (tester) async {
      final tool = _StubTool(
        'query_wrong_problems',
        const ToolOutcome(content: '{"matched":1}', summary: '查到 1 道错题'),
      );
      await pumpChat(
        tester,
        client: _client(FakeStreamHttp([
          [
            _c(_sse(_toolChunk(index: 0, id: 'c1', name: tool.toolName, args: '{}'))),
            _c(_sse(_finishReason('tool_calls'))),
          ],
          [
            _c(_sse(_delta('答'))),
            _c(_sse(_stop())),
          ],
        ])),
        tools: ChatToolRegistry([tool]),
      );

      await sendText(tester, '问');
      expect(find.textContaining('查到 1 道错题'), findsOneWidget);

      await tester.tap(find.text('新对话'));
      await tester.pumpAndSettle();

      expect(find.textContaining('查到 1 道错题'), findsNothing,
          reason: '新对话里不该留着上一段的工具记录');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('工具调用（P2）', () {
    /// 两轮脚本：先要工具，拿到结果后再作答。
    FakeStreamHttp twoRound(_StubTool tool) => FakeStreamHttp([
          [
            _c(_sse(_toolChunk(index: 0, id: 'call_1', name: tool.toolName, args: '{"kp":'))),
            _c(_sse(_toolChunk(index: 0, args: '"中值定理"}'))),
            _c(_sse(_finishReason('tool_calls'))),
          ],
          [
            _c(_sse(_delta('根据你的错题本，'))),
            _c(_sse(_delta('中值定理是最薄弱的。'))),
            _c(_sse(_stop())),
          ],
        ]);

    testWidgets('模型先查工具再作答：正文显示，且标出查了什么', (tester) async {
      final tool = _StubTool(
        'query_wrong_problems',
        const ToolOutcome(content: '{"matched":12}', summary: '查到 12 道错题'),
      );
      await pumpChat(tester, client: _client(twoRound(tool)), tools: ChatToolRegistry([tool]));

      await sendText(tester, '我哪块最弱');

      expect(bubbleWith('根据你的错题本，中值定理是最薄弱的。'), findsOneWidget);
      // 溯源要看得见 —— 否则"查出来的"和"编出来的"在界面上长得一样
      expect(find.textContaining('查错题本'), findsOneWidget);
      expect(find.textContaining('查到 12 道错题'), findsOneWidget);
      // 参数分片必须拼对（少拼一片就会变成非法 JSON）
      expect(tool.received.single['kp'], '中值定理');
    });

    testWidgets('工具记录落库，重开会话还能看到溯源', (tester) async {
      final tool = _StubTool(
        'query_profile',
        const ToolOutcome(content: '{"totalProblems":30}', summary: '画像：30 题'),
      );
      await pumpChat(tester, client: _client(twoRound(tool)), tools: ChatToolRegistry([tool]));

      await sendText(tester, '我哪块最弱');
      await tester.pumpAndSettle();

      final store = ChatStore(db);
      final s = await store.load((await store.listSessions()).single.id);
      final last = s!.entries.last;
      expect(last.content, contains('中值定理是最薄弱的'));
      expect(last.interrupted, isFalse);
      expect(last.toolTrace.length, 1);
      expect(last.toolTrace.single.name, 'query_profile');
      expect(last.toolTrace.single.ok, isTrue);
      expect(last.toolTrace.single.summary, '画像：30 题');
    });

    testWidgets('第二轮请求要带上"要过什么"与"拿到了什么"', (tester) async {
      // 不带这两条消息，模型会不知道结果、甚至重复调用同一个工具
      final tool = _StubTool(
        'query_wrong_problems',
        const ToolOutcome(content: '{"matched":3}', summary: '查到 3 道错题'),
      );
      final http = twoRound(tool);
      await pumpChat(tester, client: _client(http), tools: ChatToolRegistry([tool]));

      await sendText(tester, '我哪块最弱');

      expect(http.requests.length, 2, reason: '两轮 = 两次真实调用，各记一次账');
      final second =
          jsonDecode(http.requests.last.body ?? '{}') as Map<String, dynamic>;
      final messages = (second['messages'] as List).cast<Map<String, dynamic>>();

      final assistant = messages.firstWhere((m) => m['role'] == 'assistant');
      expect(assistant['tool_calls'], isNotNull);
      final call = (assistant['tool_calls'] as List).single as Map;
      expect((call['function'] as Map)['name'], 'query_wrong_problems');

      final result = messages.firstWhere((m) => m['role'] == 'tool');
      expect(result['tool_call_id'], 'call_1');
      expect(result['content'], contains('matched'));
    });

    testWidgets('工具在跑的那几秒要显示"正在查…"，否则界面像卡住了', (tester) async {
      final tool = _StubTool(
        'query_due_reviews',
        const ToolOutcome(content: '{}', summary: '今天到期 5 张'),
        // 制造一个可见的执行窗口
        delay: const Duration(milliseconds: 300),
      );
      await pumpChat(tester, client: _client(twoRound(tool)), tools: ChatToolRegistry([tool]));

      await tester.enterText(find.byType(TextField), '今天该复习什么');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));

      expect(find.textContaining('正在查'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.textContaining('正在查'), findsNothing,
          reason: '查完了就该把"正在查"收掉');
      expect(find.textContaining('今天到期 5 张'), findsOneWidget);
    });

    testWidgets('工具执行失败也要标出来（与"查到 0 条"是两回事）', (tester) async {
      final tool = _StubTool(
        'query_wrong_problems',
        ToolOutcome.failure('查询执行失败：数据库锁住了', summary: '查错题本执行失败'),
      );
      await pumpChat(tester, client: _client(twoRound(tool)), tools: ChatToolRegistry([tool]));

      await sendText(tester, '问');

      // 失败照样要落库，否则用户以为那次查询根本没发生
      final store = ChatStore(db);
      final s = await store.load((await store.listSessions()).single.id);
      final trace = s!.entries.last.toolTrace.single;
      expect(trace.ok, isFalse);
      expect(trace.summary, contains('失败'));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('写操作确认（P3）', () {
    /// 一轮脚本：说一句话，然后调写工具。
    ///
    /// **故意不给第二轮** —— 摆出提案后循环就该停下。
    /// 脚本里多准备的那一轮留作证据：真被调用了，`requests.length` 就会是 2。
    FakeStreamHttp proposing(_StubTool tool) => FakeStreamHttp([
          [
            _c(_sse(_delta('我整理好了，你确认一下：'))),
            _c(_sse(_toolChunk(
                index: 0, id: 'w1', name: tool.toolName, args: '{}'))),
            _c(_sse(_finishReason('tool_calls'))),
          ],
          [
            _c(_sse(_delta('（不该出现）'))),
            _c(_sse(_stop())),
          ],
        ]);

    _StubTool writeTool({bool destructive = false}) => _StubTool(
          destructive ? 'delete_problem' : 'create_problem',
          ToolOutcome(
            content: '{"status":"pending_user_confirmation"}',
            summary: destructive ? '待确认：删除题目' : '待确认：录入一道题',
            proposal: _proposal(destructive: destructive),
          ),
        );

    testWidgets('摆出确认卡片，而不是谎称已经做完', (tester) async {
      final tool = writeTool();
      final http = proposing(tool);
      final executor = _FakeExecutor(const WriteOutcome(true, '已保存为「x」'));
      await pumpChat(
        tester,
        client: _client(http),
        tools: ChatToolRegistry([tool]),
        executor: executor,
      );

      await sendText(tester, '帮我把这道题记下来');

      expect(find.byType(ProposalCard), findsOneWidget);
      expect(bubbleWith('我整理好了，你确认一下：'), findsOneWidget);
      expect(find.textContaining('录入这道题'), findsWidgets);
      // 卡片必须逐项列出将要发生什么：改了哪一项、能碰到什么、
      // 以及"不可逆/不能撤销"这类用户不会主动想到的后果。
      expect(find.textContaining('证明存在 ξ'), findsWidgets);
      expect(find.textContaining('4 次'), findsOneWidget);
      expect(find.textContaining('确认前请再认一遍'), findsOneWidget);

      // ⚠️ 最要紧的一条：**没有第二次请求**。
      // 多问一次模型，它只会拿到"等用户确认"，而它能说出口的只有
      // "已经帮你改好了"（假话）或重复一遍（白花钱）。
      expect(http.requests.length, 1,
          reason: '摆出提案之后就该收尾，不能再问模型');

      // 而且什么都没执行
      expect(executor.applied, isEmpty);
    });

    testWidgets('卡片不挤进溯源条（那是给"查过什么"的位置）', (tester) async {
      final tool = writeTool();
      await pumpChat(
        tester,
        client: _client(proposing(tool)),
        tools: ChatToolRegistry([tool]),
      );

      await sendText(tester, '帮我记一下');

      // 溯源条里的写法是「中文短名 · 摘要」，卡片不参与
      expect(find.textContaining('提议录入题目 ·'), findsNothing);
      // 但"某道题没查到内容"这类普通调用照旧显示
      expect(find.byType(ProposalCard), findsOneWidget);
    });

    testWidgets('没有正文只有卡片时，不说"这条回复没有内容"', (tester) async {
      // 模型只调工具、一句正文都没写。显示"（这条回复没有内容）"
      // 会让用户以为坏了 —— 而下面那张卡片才是这一轮的全部内容。
      final tool = writeTool();
      await pumpChat(
        tester,
        client: _client(FakeStreamHttp([
          [
            _c(_sse(_toolChunk(
                index: 0, id: 'w1', name: tool.toolName, args: '{}'))),
            _c(_sse(_finishReason('tool_calls'))),
          ],
        ])),
        tools: ChatToolRegistry([tool]),
      );

      await sendText(tester, '记一下');

      expect(find.text('（这条回复没有内容）'), findsNothing);
      expect(find.textContaining('确认之后才会生效'), findsOneWidget);
      expect(find.byType(ProposalCard), findsOneWidget);
    });

    testWidgets('点确认才执行；结论与"已执行"都写在卡片上，并落库', (tester) async {
      final tool = writeTool();
      final executor = _FakeExecutor(
        const WriteOutcome(true, '已保存为「self-20260922-abc」，可以在错题本里找到它'),
      );
      await pumpChat(
        tester,
        client: _client(proposing(tool)),
        tools: ChatToolRegistry([tool]),
        executor: executor,
      );

      await sendText(tester, '帮我把这道题记下来');
      expect(executor.applied, isEmpty, reason: '确认之前必须一次都不执行');

      await tester.tap(find.widgetWithText(FilledButton, '确认'));
      await tester.pumpAndSettle();

      expect(executor.applied, hasLength(1));
      expect(executor.applied.single.id, 'prop-1');
      expect(find.text('已执行'), findsOneWidget);
      expect(find.textContaining('self-20260922-abc'), findsOneWidget);

      final store = ChatStore(db);
      final s = await store.load((await store.listSessions()).single.id);
      final trace = s!.entries.last.toolTrace.single;
      expect(trace.decision, ToolTraceItem.decisionConfirmed);
      expect(trace.result, contains('self-20260922-abc'));
      expect(trace.proposal!.payload['stem'], '证明存在 ξ 使 f\'(ξ)=0',
          reason: '提案要整份留着 —— 用户得能回看当初确认的是什么');
    });

    testWidgets('点取消：不执行，卡片标已取消，并说清没动数据', (tester) async {
      final tool = writeTool();
      final executor = _FakeExecutor(const WriteOutcome(true, '不该执行'));
      await pumpChat(
        tester,
        client: _client(proposing(tool)),
        tools: ChatToolRegistry([tool]),
        executor: executor,
      );

      await sendText(tester, '帮我把这道题记下来');
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();

      expect(executor.applied, isEmpty);
      expect(find.text('已取消'), findsOneWidget);
      expect(find.textContaining('没有改动任何数据'), findsOneWidget);

      final store = ChatStore(db);
      final s = await store.load((await store.listSessions()).single.id);
      expect(s!.entries.last.toolTrace.single.decision,
          ToolTraceItem.decisionCancelled);
    });

    testWidgets('确认过一次之后按钮就没了（否则手一抖就写两遍）', (tester) async {
      final tool = writeTool();
      final executor = _FakeExecutor(const WriteOutcome(true, '已保存'));
      await pumpChat(
        tester,
        client: _client(proposing(tool)),
        tools: ChatToolRegistry([tool]),
        executor: executor,
      );

      await sendText(tester, '记一下');
      await tester.tap(find.widgetWithText(FilledButton, '确认'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(FilledButton, '确认'), findsNothing);
      expect(find.widgetWithText(TextButton, '取消'), findsNothing);
      expect(executor.applied, hasLength(1));
    });

    testWidgets('执行失败要如实说"没能执行"并给出原因', (tester) async {
      final tool = writeTool();
      final executor = _FakeExecutor(
        const WriteOutcome(false, '这道题已经不在了，没有改动任何数据'),
      );
      await pumpChat(
        tester,
        client: _client(proposing(tool)),
        tools: ChatToolRegistry([tool]),
        executor: executor,
      );

      await sendText(tester, '记一下');
      await tester.tap(find.widgetWithText(FilledButton, '确认'));
      await tester.pumpAndSettle();

      expect(find.text('没能执行'), findsOneWidget);
      expect(find.textContaining('已经不在了'), findsWidgets);
      expect(find.text('已执行'), findsNothing);
    });

    testWidgets('删题的卡片标"不可逆"，按钮也不说"确认"而说"确认删除"', (tester) async {
      final tool = writeTool(destructive: true);
      await pumpChat(
        tester,
        client: _client(proposing(tool)),
        tools: ChatToolRegistry([tool]),
      );

      await sendText(tester, '把那道题删了');

      expect(find.text('不可逆'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '确认删除'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '确认'), findsNothing);
    });

    testWidgets('历史里那张卡片重新打开还在，且带着当初的决定', (tester) async {
      // 先手工造一条"已经确认过"的历史消息：卡片的两种状态
      // （形状来自 proposal，结论来自 decision）都必须从盘上还原出来。
      final store = ChatStore(db);
      final sid = await store.createSession(title: '上次那次改动');
      await store.appendUserMessage(sid, '帮我把这道题记下来');
      final turn = await store.beginAssistantTurn(sid);
      await store.updateTurn(
        turn,
        content: '我整理好了，你确认一下：',
        interrupted: false,
        toolTrace: [
          ToolTraceItem(
            name: 'create_problem',
            ok: true,
            summary: '待确认：录入一道题',
            proposal: _proposal(),
          ).decided(ToolTraceItem.decisionConfirmed, '已保存为「self-1」'),
        ],
        force: true,
      );

      await pumpChat(tester);
      await tester.tap(find.text('上次那次改动'));
      await tester.pumpAndSettle();

      expect(find.byType(ProposalCard), findsOneWidget);
      expect(find.text('已执行'), findsOneWidget);
      expect(find.textContaining('self-1'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '确认'), findsNothing);
    });
  });
}
