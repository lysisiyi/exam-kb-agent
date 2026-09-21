/// 对话记录落盘：会话 / 消息 / 节流 / "未完成"标记。
///
/// ## 这里守的几条都关于**数据不丢**
///
/// - **先插空行**：流式回复在开始时就落一行 `interrupted = true`。
///   这样进程被杀也留下痕迹，用户看到的是"这条回复被中断了"，
///   而不是"我明明问过、记录里却没有"。
/// - **节流不能在最后一份内容上生效**：流结束时传 `force: true`。
///   漏了它，表现是"回复最后几十个字没存上"，且只在回复较快时出现。
/// - **消息按自增 id 排，不按时间**：一轮问答往往在同一毫秒内写完，
///   按时间排序结果不确定，会让一问一答偶尔对调。
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/data/db/database.dart';
import 'package:kaoyan_math_agent/services/chat/chat_store.dart';
import 'package:kaoyan_math_agent/services/llm/llm_client.dart';

/// 读一个**必然存在**的会话。
///
/// 用它的理由不只是省一个 `!`：Dart 在变量被重新赋值后不再做类型提升，
/// 所以"读一次、断言、再读一次"的写法会一路编译不过。
/// 这个辅助把"应当存在"变成一次明确的断言。
Future<ChatSession> _load(ChatStore store, String id) async {
  final s = await store.load(id);
  expect(s, isNotNull, reason: '这个会话应该存在（id=$id）');
  return s!;
}

void main() {
  late AppDatabase db;
  late DateTime clock;

  /// 每个用例一个干净库 + 可控时钟。
  ChatStore newStore() => ChatStore(
        db,
        now: () => clock,
        random: Random(7),
      );

  setUp(() {
    db = AppDatabase.memory();
    clock = DateTime(2026, 9, 22, 1, 0, 0);
  });

  tearDown(() async {
    await db.close();
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('会话', () {
    test('建会话后能在列表里看到', () async {
      final store = newStore();

      final id = await store.createSession(model: 'deepseek-chat');
      final list = await store.listSessions();

      expect(list.length, 1);
      expect(list.single.id, id);
      expect(list.single.model, 'deepseek-chat');
      expect(list.single.displayTitle, '（新对话）',
          reason: '还没发过消息的会话要有占位标题，不能留空白让人以为坏了');
    });

    test('列表按最后更新时间倒序', () async {
      final store = newStore();

      final older = await store.createSession();
      clock = clock.add(const Duration(minutes: 1));
      final newer = await store.createSession();
      // 让 older 重新活跃：它应该被顶到前面
      clock = clock.add(const Duration(minutes: 1));
      await store.appendUserMessage(older, '我又想起来一件事');

      final list = await store.listSessions();

      expect(list.map((s) => s.id).toList(), [older, newer],
          reason: '接着聊旧会话就该把它顶上去 —— 用 createdAt 排序做不到这点');
    });

    test('会话 id 不重复（即使时钟停着）', () async {
      final store = newStore();

      // 时钟完全不前进：只靠时间戳会连续撞 id，
      // 而撞 id 的表现是"新会话悄悄覆盖了旧的"
      final a = await store.createSession();
      final b = await store.createSession();
      final c = await store.createSession();

      expect({a, b, c}.length, 3);
    });

    test('删会话会连消息一起删（手写级联）', () async {
      final store = newStore();
      final id = await store.createSession();
      await store.appendUserMessage(id, '问题');
      final turn = await store.beginAssistantTurn(id);
      await store.updateTurn(turn, content: '回答', interrupted: false, force: true);

      await store.deleteSession(id);

      expect(await store.load(id), isNull);
      final rows = await db.select(db.chatMessages).get();
      expect(rows, isEmpty, reason: 'schema 里没有外键声明，级联必须自己写');
    });

    test('load 不存在的会话返回 null，不抛异常', () async {
      final store = newStore();
      expect(await store.load('does-not-exist'), isNull);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('标题', () {
    test('取首条用户消息，超长截断', () {
      expect(ChatStore.titleOf('洛必达法则什么时候能用？'), '洛必达法则什么时候能用？');

      final long = '为' * (kChatTitleMax + 10);
      final t = ChatStore.titleOf(long);
      expect(t.length, kChatTitleMax + 1, reason: '截断处还有一个省略号');
      expect(t.endsWith('…'), isTrue);
    });

    test('换行被压平（否则历史列表里标题会占好几行）', () {
      expect(ChatStore.titleOf('第一行\n第二行\t第三行'), '第一行 第二行 第三行');
    });

    test('纯空白得到空标题，而不是一堆空格', () {
      expect(ChatStore.titleOf('   \n  '), '');
    });

    test('首条消息之后，标题不再被改写', () async {
      final store = newStore();
      final id = await store.createSession();
      await store.appendUserMessage(id, '第一个问题');
      await store.appendUserMessage(id, '第二个问题');

      final s = await store.load(id);
      expect(s!.title, '第一个问题',
          reason: '标题跟着最新消息变的话，用户会找不到"我记得那个会话"');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('流式落盘', () {
    test('回复一开始就先落一行空内容、标记未完成', () async {
      final store = newStore();
      final id = await store.createSession();

      await store.beginAssistantTurn(id);

      final last = (await _load(store, id)).entries.last;
      expect(last.role, ChatRole.assistant);
      expect(last.content, '');
      expect(last.hasContent, isFalse, reason: '空气泡要显示成"正在思考"');
      expect(last.interrupted, isTrue,
          reason: '此刻进程若被杀，盘上这条就是唯一的痕迹 —— '
              '它必须是"未完成"，不能是一条看起来正常却空着的回复');
    });

    test('正常收尾后未完成标记被清掉', () async {
      final store = newStore();
      final id = await store.createSession();
      final turn = await store.beginAssistantTurn(id);

      await store.updateTurn(turn, content: '答完了',
          interrupted: false, force: true);

      final s = await _load(store, id);
      expect(s.entries.last.interrupted, isFalse);
      expect(s.entries.last.content, '答完了');
    });

    test('流中断：已落盘的内容留着，标记仍是未完成', () async {
      final store = newStore();
      final id = await store.createSession();
      final turn = await store.beginAssistantTurn(id);

      await store.updateTurn(turn, content: '说到一半就', force: true);

      final s = await _load(store, id);
      expect(s.entries.last.content, '说到一半就');
      expect(s.entries.last.interrupted, isTrue,
          reason: '不能把半句话伪装成完整回答 —— '
              '用户会以为"模型怎么变笨了"，而真相是我们丢了后半段');
    });

    test('节流窗口内的更新不写盘', () async {
      final store = newStore();
      final id = await store.createSession();
      final turn = await store.beginAssistantTurn(id);

      await store.updateTurn(turn, content: 'A', force: true);

      clock = clock.add(const Duration(milliseconds: 100));
      await store.updateTurn(turn, content: 'AB'); // 窗口内 → 跳过

      var s = await _load(store, id);
      expect(s.entries.last.content, 'A', reason: '100ms 就写一次太频了');

      clock = clock.add(kChatFlushInterval);
      await store.updateTurn(turn, content: 'ABC'); // 超过窗口 → 真的写

      s = await _load(store, id);
      expect(s.entries.last.content, 'ABC');
    });

    test('force 无视节流窗口 —— 最后一份内容必须落盘', () async {
      final store = newStore();
      final id = await store.createSession();
      final turn = await store.beginAssistantTurn(id);

      await store.updateTurn(turn, content: 'A', force: true);
      clock = clock.add(const Duration(milliseconds: 10));
      // 紧接着的收尾。漏了 force 的话，最后这份内容会被节流吃掉，
      // 表现是"回复最后几十个字没存上"，而且只在回复快时出现
      await store.updateTurn(turn, content: 'AB完整', interrupted: false,
          force: true);

      final s = await _load(store, id);
      expect(s.entries.last.content, 'AB完整');
      expect(s.entries.last.interrupted, isFalse);
    });

    test('第一次更新不受节流影响（没有"上次写入"可比）', () async {
      final store = newStore();
      final id = await store.createSession();
      final turn = await store.beginAssistantTurn(id);

      await store.updateTurn(turn, content: '立刻就要写进去');

      final s = await _load(store, id);
      expect(s.entries.last.content, '立刻就要写进去');
    });

    test('更新时间也会被推上去（否则接着聊不会把会话顶到前面）', () async {
      final store = newStore();
      final id = await store.createSession();
      final before = (await store.load(id))!.updatedAt;

      clock = clock.add(const Duration(minutes: 5));
      final turn = await store.beginAssistantTurn(id);
      await store.updateTurn(turn, content: '答', interrupted: false, force: true);

      final after = (await store.load(id))!.updatedAt;
      expect(after.isAfter(before), isTrue);
    });

    test('用量写到这条消息上', () async {
      final store = newStore();
      final id = await store.createSession();
      final turn = await store.beginAssistantTurn(id);

      await store.updateTurn(
        turn,
        content: '答',
        interrupted: false,
        force: true,
        usage: const LlmUsage(
          inputTokens: 120,
          outputTokens: 30,
          costYuan: 0.0021,
        ),
      );

      final e = (await store.load(id))!.entries.last;
      expect(e.usage.totalTokens, 150);
      expect(e.usage.costYuan, closeTo(0.0021, 1e-9));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('消息顺序', () {
    test('同一毫秒内插入的多条消息，按写入次序排列', () async {
      final store = newStore();
      final id = await store.createSession();

      // 时钟**故意不前进**：一轮问答本来就在同一毫秒内写完。
      // 如果实现按时间排序，这里的结果会是不确定的
      await store.appendUserMessage(id, '问一');
      final t1 = await store.beginAssistantTurn(id);
      await store.updateTurn(t1, content: '答一', interrupted: false, force: true);
      await store.appendUserMessage(id, '问二');
      final t2 = await store.beginAssistantTurn(id);
      await store.updateTurn(t2, content: '答二', interrupted: false, force: true);

      final s = await store.load(id);

      expect(s!.entries.map((e) => e.role).toList(), [
        ChatRole.user,
        ChatRole.assistant,
        ChatRole.user,
        ChatRole.assistant,
      ]);
      expect(s.entries.map((e) => e.content).toList(),
          ['问一', '答一', '问二', '答二']);
    });

    test('用户消息与助手消息能分辨', () async {
      final store = newStore();
      final id = await store.createSession();
      await store.appendUserMessage(id, '问');

      final s = await store.load(id);
      expect(s!.entries.single.isUser, isTrue);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('从存储还原角色', () {
    test('正常值原样还原', () {
      expect(ChatRole.parseStored('user'), ChatRole.user);
      expect(ChatRole.parseStored('assistant'), ChatRole.assistant);
      // P2 起 `tool` 也是一个真角色（工具结果）。它不该再落到"陌生值"分支 ——
      // 否则一条工具消息回看时会被当成模型说的话。
      expect(ChatRole.parseStored('tool'), ChatRole.tool);
    });

    test('陌生值退化为 assistant，而不是抛异常', () {
      // 抛异常会让整个会话打不开 —— 用户直接看不到自己的聊天记录。
      // 退化方向选 assistant 也是刻意的：把模型的话当成模型的话，
      // 好过把它伪装成"用户说过的话"
      expect(ChatRole.parseStored('function'), ChatRole.assistant);
      expect(ChatRole.parseStored('USER'), ChatRole.assistant);
      expect(ChatRole.parseStored(''), ChatRole.assistant);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('最近会话', () {
    test('latest 返回最近聊过的那个（不含消息时的场景）', () async {
      final store = newStore();
      expect(await store.latest(), isNull, reason: '空库不该抛异常');

      final a = await store.createSession();
      clock = clock.add(const Duration(minutes: 1));
      final b = await store.createSession();

      expect((await store.latest())!.id, b);

      // 旧会话重新活跃后应该变成"最近"
      clock = clock.add(const Duration(minutes: 1));
      await store.appendUserMessage(a, '继续聊');
      expect((await store.latest())!.id, a);
    });

    test('latest 会带上消息（打开就能接着看）', () async {
      final store = newStore();
      final id = await store.createSession();
      await store.appendUserMessage(id, '上次聊到哪了');

      final s = await store.latest();
      expect(s!.entries.length, 1);
      expect(s.entries.single.content, '上次聊到哪了');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('读不出历史时不能把页面拖垮', () {
    test('库被关掉后 listSessions 返回空列表而不是抛异常', () async {
      final store = newStore();
      await db.close();

      // 页面在构建时会读历史列表。这里抛异常 = 整个对话页打不开，
      // 而"历史读不到"远不该有这种后果
      expect(await store.listSessions(), isEmpty);
    });

    test('库被关掉后 load 返回 null', () async {
      final store = newStore();
      await db.close();

      expect(await store.load('anything'), isNull);
    });
  });
}
