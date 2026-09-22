/// 对话助手能调用的工具（P2：**只读**）。
///
/// ## 这一层的纪律：只读，而且按构造只读
///
/// 这一期的五个工具**全部只读**。不是"我们小心点别写"，
/// 而是每个工具只调用数据层里那些**本身就不写库**的方法：
/// `select*` / `ProblemSearch.search` / `ProblemStore.read` /
/// `ReviewRepository.dueQueue` / `MasteryService.build`。
///
/// ⚠️ 有两个陷阱，写新工具时必须绕开：
/// - `dueQueueProvider` 会先 `ensureCards()`（**写**）再取队列。
///   工具里必须直接调 `ReviewRepository.dueQueue()`，不能复用那个 provider。
/// - `ProblemService.save` / `delete` / `ReviewRepository.grade` 都会写库。
///   它们属于 P3。
///
/// 为什么这么较真：模型会自己决定调什么、传什么参数。一次"顺手写一下"
/// 在界面上**没有任何提示** —— 用户看到的是聊天记录里一句
/// "好的，我已经帮你更新了"，而数据库里到底改了什么没人知道。
/// 写操作要等 P3 的确认流程，那时每一次改动都会先摆到用户面前。
///
/// ## 为什么结果一律是 JSON 而不是自然语言
///
/// 模型要把这些数字/条目**组织成人话**再讲给用户听。给它一段已经写好的
/// 中文散文，它会照抄甚至添油加醋（"你的薄弱点是……"变成"你一定很苦恼吧"）。
/// 给结构化数据，它就只能做"转述"。
///
/// ## 为什么每个工具都要限条数
///
/// 一次把 5000 道错题灌进上下文，结果是：费用爆炸、模型被淹没、
/// 而且真正有用的那几条被稀释。所以每个查询都**必须**有上界，
/// 并且当结果被截断时，返回里要**明说**截断了 —— 见 [kMaxToolRows]。
///
/// ## 依赖一律"按需取"，不在构造时准备好
///
/// 除了数据库句柄，每个工具拿到手的是**加载函数**而不是现成的对象：
/// `loadStore` / `loadRepo` / `loadService` / `loadKnowledge`。
///
/// 原因是这些依赖都不便宜，而**大部分对话用不到它们**：
///
/// - 题目仓库要先去解析题库目录（不存在还会创建），
/// - 画像服务要载入错因词表，
/// - 知识点本体要解析 100KB 的 JSON。
///
/// 构造时全备齐，"打开对话页"就要付这三笔开销 —— 而用户可能
/// 只是来问一道贴过来的题。更糟的是这会让页面测试**必须**把
/// 一整套文件系统依赖搭起来，否则真实 IO 在假时钟下永远不返回，
/// 测试会挂住而不是失败（这个坑真踩过）。
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import '../../data/db/database.dart';
import '../../data/error_causes.dart';
import '../../data/index/index_builder.dart';
import '../../data/markdown/problem_markdown.dart';
import '../../data/markdown/problem_store.dart';
import '../../domain/fsrs/fsrs_scheduler.dart';
import '../../domain/knowledge/knowledge_point.dart';
import '../../domain/paper/paper_models.dart';
import '../../domain/problem_draft.dart';
import '../library/problem_service.dart';
import '../llm/llm_client.dart';
import '../paper/paper_composer.dart';
import '../paper/paper_repository.dart';
import '../profile/mastery_service.dart';
import '../review/review_repository.dart';
import 'chat_writes.dart';

/// 单个工具一次最多返回多少行。
///
/// 30 是个折中：够模型看出"主要问题集中在哪里"，又不至于让一次回答
/// 的输入 token 失控。上限写死在**这里**而不是让每个工具自己定，
/// 是为了让"上下文不会爆"这件事只有一个地方能改。
const int kMaxToolRows = 30;

/// 题干摘要的长度上限。完整题干可能很长（带图、带多问）。
const int kToolStemMax = 120;

/// 工具结果里"一道题的题面"这一项最多给多少字。
///
/// 比 [kToolStemMax] 宽松得多：`get_problem` 的用途就是让模型
/// **读懂这道题**，截得太狠就没法讲了。4000 字对一道考研题足够。
const int kToolProblemBodyMax = 4000;

// ─────────────────────────────────────────────────────────────────────────────
// 契约
// ─────────────────────────────────────────────────────────────────────────────

/// 知识点本体的异步加载器。
///
/// 返回 **null 表示载入失败**，而不是抛异常：知识点文件坏了的时候，
/// 工具仍应能用 —— 只是考点名退化成 id。让一次画像查询因为
/// "assets 里那个 json 有问题"而整个失败，代价不成比例。
typedef KnowledgeLoader = Future<KnowledgeBase?> Function();

/// 知识点 id → 名字。
///
/// ⚠️ 题目 Markdown 里存的关联**只有 id**（`KnowledgeRef` 没有名字字段），
/// 所以想要人看得懂的考点名，必须回本体查一次。查不到就用 id 兜底 ——
/// 给模型一个 `3.2.1` 远好过给一个 null（它会以为"这题没有考点"）。
String? _kpName(KnowledgeBase? kb, String? id) {
  if (id == null || id.isEmpty) return null;
  return kb?.byId[id]?.name ?? id;
}

/// 取主考点的知识点 id。
///
/// 写成"接收 Problem"而不是"接收 List<KnowledgeRef>"，是为了让调用处的
/// `problem?.knowledge` 保持明确类型 —— 用 `?? const []` 兜底会退化成
/// `List<dynamic>`，于是 `k.isPrimary` 变成一次 dynamic 调用
/// （编译能过，写错了要到运行时才发现）。
String? _primaryKpId(Problem? p) {
  if (p == null) return null;
  for (final k in p.knowledge) {
    if (k.isPrimary) return k.id;
  }
  return null;
}

/// 一次工具执行的结果。
class ToolOutcome {
  /// 回灌给模型的正文。约定是 JSON 字符串。
  ///
  /// 它必须是**自解释**的：模型看不到我们怎么算的、也看不到被截掉的部分。
  /// 所以"共 37 条，只列了 10 条"这种话要写进结果里，
  /// 而不是留在代码注释里。
  final String content;

  /// 这次调用本身是否成功。
  ///
  /// ⚠️ "成功"指的是**查询执行成功**，不是"查到了东西"。
  /// 查到 0 条是成功（结果里明说 0 条）；数据库打不开才是失败。
  /// 把"空结果"当失败会诱导模型反复重试同一个查询。
  final bool ok;

  /// 界面上那一行短说明，如"查到 12 条错题"。
  ///
  /// 它给**用户**看，所以要说人话；[content] 给模型看，所以是 JSON。
  final String summary;

  /// 这次调用**没有写库**，只是提议了一次改动。
  ///
  /// 非 null 时：调用方（对话循环 + 界面）会把这张确认卡片摆给用户，
  /// 并且**就此结束本轮** —— 见 `ChatAgent`。为 null 表示这是一次普通调用。
  final ChatWriteProposal? proposal;

  const ToolOutcome({
    required this.content,
    this.ok = true,
    this.summary = '',
    this.proposal,
  });

  static ToolOutcome failure(String message, {String? summary}) => ToolOutcome(
        content: jsonEncode({'error': message}),
        ok: false,
        summary: summary ?? message,
      );

  /// 这次调用是否只是"提议了一次改动"。
  bool get isProposal => proposal != null;
}

/// 一个可被模型调用的只读工具。
abstract class ChatTool {
  /// 给模型看的规格（名字 / 说明 / 参数 schema）。
  ToolSpec get spec;

  /// 执行一次查询。
  ///
  /// 参数由模型生成，**一律当作不可信输入**：类型可能不对、
  /// 数值可能越界、可能多给没定义的键。每个实现自己负责取值与夹紧，
  /// 见 [_asInt] / [_asString] / [_asBool]。
  Future<ToolOutcome> run(Map<String, dynamic> args);
}

// ─────────────────────────────────────────────────────────────────────────────
// 调用记录（界面显示 + 落盘溯源）
// ─────────────────────────────────────────────────────────────────────────────

/// 一次工具调用在界面与盘上的记录。
///
/// ⚠️ **只存摘要，不存工具返回的正文**。正文动辄几 KB，几十轮下来
/// 聊天记录会被这些永远不会再被显示的内容撑爆；而用户真正想回看的
/// 是"这次回答到底查了什么"，那是 [summary] 与 [name]。
///
/// （唯一的例外是 [proposal]：写操作的提案必须整份留着 —— 用户要能
/// 在三天后回看"我当初确认的是什么"。它是有上界的，见 `chat_writes.dart`。）
///
/// 放在工具层而不是 agent 层，是因为 **`ChatStore` 要写它** ——
/// "记录仓依赖对话循环"是个说不通的依赖方向。
class ToolTraceItem {
  /// 工具名，如 `query_wrong_problems`。
  final String name;

  /// 参数的紧凑预览，如 `kp=中值定理, limit=5`。
  final String argsPreview;

  /// 查询是否成功（注意：查到 0 条也算成功）。
  final bool ok;

  /// 给用户看的一行结论，如"查到 12 道错题"。
  final String summary;

  /// 第几轮（从 1 开始）。用于界面上把同一轮的多次调用归到一起。
  final int round;

  /// 这条记录对应的调用**提议**了一次改动。null 表示它是一次普通调用。
  ///
  /// ## 为什么决定记在记录上、而不是记在提案里
  ///
  /// 提案是"我提议了什么"（不可变，落盘时原样保留），决定是"用户怎么处置的"
  /// （会变）。拆开之后，回看时能同时看到"当初让你确认的是什么"和
  /// "你选了什么" —— 合成一个对象的话，改一下决定就把原始提案覆盖了。
  final String? decision;

  /// 用户处置之后的一句话结果（成功说了什么、失败为什么）。
  /// [decision] 为 null 时它也是 null。
  final String? result;

  /// 这次调用提议的改动。见 [ChatWriteProposal]。
  final ChatWriteProposal? proposal;

  const ToolTraceItem({
    required this.name,
    this.argsPreview = '',
    this.ok = true,
    this.summary = '',
    this.round = 1,
    this.decision,
    this.result,
    this.proposal,
  });

  /// 用户**确认并已执行**。
  static const String decisionConfirmed = 'confirmed';

  /// 用户点了取消。
  static const String decisionCancelled = 'cancelled';

  /// 用户确认了，但执行失败。
  static const String decisionFailed = 'failed';

  /// 还等着用户点。
  bool get isPending => proposal != null && decision == null;

  /// 这次调用是不是"提议了一次改动"。
  bool get isProposal => proposal != null;

  /// 中文短名，界面上用。
  String get label => toolLabel(name);

  /// 换一个决定后的副本。提案本身原样保留。
  ToolTraceItem decided(String decision, String result) => ToolTraceItem(
        name: name,
        argsPreview: argsPreview,
        ok: ok,
        summary: summary,
        round: round,
        decision: decision,
        result: result,
        proposal: proposal,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        if (argsPreview.isNotEmpty) 'args': argsPreview,
        'ok': ok,
        if (summary.isNotEmpty) 'summary': summary,
        'round': round,
        if (decision != null) 'decision': decision,
        if (result != null) 'result': result,
        if (proposal != null) 'proposal': proposal!.toJson(),
      };

  /// 反序列化。**坏数据退化成"未知的一次调用"，不抛异常** ——
  /// 这是一条历史备注，不值得为它让整个会话打不开。
  ///
  /// 唯一的例外是 [proposal]：认不出来的提案会被丢掉（返回 null），
  /// 于是这条变成一次普通记录。理由见 `ChatWriteProposal.fromJson` ——
  /// 一张"看起来能点、实际什么也不会发生"的确认卡片比不显示更糟。
  static ToolTraceItem fromJson(Map<dynamic, dynamic> j) {
    final raw = j['proposal'];
    return ToolTraceItem(
      name: j['name']?.toString() ?? '',
      argsPreview: j['args']?.toString() ?? '',
      ok: j['ok'] != false,
      summary: j['summary']?.toString() ?? '',
      round: (j['round'] as num?)?.toInt() ?? 1,
      decision: j['decision']?.toString(),
      result: j['result']?.toString(),
      proposal: raw is Map ? ChatWriteProposal.fromJson(raw) : null,
    );
  }
}

/// 工具名的中文短名。界面上不显示 `query_wrong_problems` 这种东西。
const Map<String, String> kToolLabels = {
  'query_wrong_problems': '查错题本',
  'get_problem': '读题目',
  'query_knowledge_points': '查知识点',
  'query_profile': '查学习画像',
  'query_due_reviews': '查待复习',
  // P3：这四个是"提议改动"，不是"已经改了"。界面上那一行也按这个口径写。
  'create_problem': '提议录入题目',
  'update_problem': '提议修改题目',
  'delete_problem': '提议删除题目',
  'compose_paper': '提议组卷',
};

/// 这些工具**不改数据**，只提议。界面据此走确认流程。
const Set<String> kWriteToolNames = {
  'create_problem',
  'update_problem',
  'delete_problem',
  'compose_paper',
};

/// 取工具的中文短名。认不出来就原样返回 —— 那多半是新加的工具
/// 忘了在这里登记，原样显示起码能让人看出是哪个。
String toolLabel(String name) => kToolLabels[name] ?? name;

/// 把工具记录序列化成盘上那一列。
String encodeToolTrace(List<ToolTraceItem> trace) =>
    jsonEncode([for (final t in trace) t.toJson()]);

/// 从盘上那一列还原。**任何异常都退化成空列表** ——
/// 见 [ToolTraceItem.fromJson] 的说明。
List<ToolTraceItem> decodeToolTrace(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const [];
  try {
    final j = jsonDecode(raw);
    if (j is! List) return const [];
    return [
      for (final e in j)
        if (e is Map) ToolTraceItem.fromJson(e),
    ];
  } catch (_) {
    return const [];
  }
}

/// 工具集合。负责"按名字找工具"与"统一把异常变成结果"。
class ChatToolRegistry {
  final List<ChatTool> tools;

  const ChatToolRegistry(this.tools);

  /// 没有工具的空集合。用于"服务商不支持工具"时保持代码路径一致。
  static const ChatToolRegistry empty = ChatToolRegistry([]);

  bool get isEmpty => tools.isEmpty;

  bool get isNotEmpty => tools.isNotEmpty;

  List<ToolSpec> get specs => [for (final t in tools) t.spec];

  ChatTool? byName(String name) {
    for (final t in tools) {
      if (t.spec.name == name) return t;
    }
    return null;
  }

  /// 执行一次模型请求的调用。
  ///
  /// ## 为什么异常在这里被吃掉
  ///
  /// 工具内部抛异常（数据库锁住、文件读不到）如果直接冒到对话循环，
  /// 用户看到的是"这一轮没跑完" —— 而实际上模型完全有能力
  /// 换一种方式回答（或者如实说"我查不到，可能是索引坏了"）。
  /// 所以这里把异常转成一条 `is_error` 的工具结果**回灌给模型**，
  /// 让它自己决定怎么处理。这比替用户决定"整轮作废"更接近真实。
  Future<ToolOutcome> invoke(ToolCall call) async {
    final tool = byName(call.name);
    if (tool == null) {
      // 名字对不上通常意味着模型在编工具名。如实告诉它，别假装成功。
      return ToolOutcome(
        content: jsonEncode({
          'error': '没有名为「${call.name}」的工具',
          'available': specs.map((s) => s.name).toList(),
        }),
        ok: false,
        summary: '未知工具：${call.name}',
      );
    }
    if (!call.isParsed) {
      return ToolOutcome(
        content: jsonEncode({
          'error': '参数不是合法的 JSON 对象',
          'raw': _clip(call.arguments, 300),
        }),
        ok: false,
        summary: '${call.name} 的参数格式不对',
      );
    }

    try {
      return await tool.run(call.args);
    } catch (e) {
      return ToolOutcome.failure(
        '查询执行失败：$e',
        summary: '${tool.spec.name} 执行失败',
      );
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. 查错题
// ─────────────────────────────────────────────────────────────────────────────

/// 按考点 / 关键词 / 错次筛错题。
class WrongProblemsTool extends ChatTool {
  final AppDatabase db;

  WrongProblemsTool(this.db);

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'query_wrong_problems',
        description: '查询用户的错题本。可以按知识点名、题干关键词、最少错误次数筛选，'
            '结果按错误次数从多到少排列，并附上每道题当前的掌握度。'
            '当用户问"我哪些题错得最多""我在某个考点上有哪些错题"时用它。'
            '注意：它只给题干摘要；要看某道题的完整内容（含答案解析）用 get_problem。',
        parameters: {
          'type': 'object',
          'properties': {
            'keyword': {
              'type': 'string',
              'description': '在题干里做全文检索的关键词，如"洛必达"。留空表示不按题干筛。',
            },
            'kp': {
              'type': 'string',
              'description': '主考点名称的一部分，如"中值定理"。留空表示不限考点。',
            },
            'min_wrong': {
              'type': 'integer',
              'description': '最少做错几次。默认 1（即所有错题）；想找顽固错题可以传 3。',
            },
            'limit': {
              'type': 'integer',
              'description': '最多返回几道题，默认 10，上限 30。',
            },
          },
          'required': <String>[],
        },
      );

  @override
  Future<ToolOutcome> run(Map<String, dynamic> args) async {
    final keyword = _asString(args, 'keyword');
    final kp = _asString(args, 'kp');
    final minWrong = _asInt(args, 'min_wrong', 1, min: 0);
    final limit = _asInt(args, 'limit', 10);

    // 有关键词时先用 FTS 把候选缩到一小撮。
    // 直接用 `LIKE '%kw%'` 扫 stem_text 在中文上是**能用但很慢**的
    // （无索引、逐行 contains）；FTS 那条路已经处理过 CJK 逐字分词，
    // 中文检索的正确性也在别处验证过，没理由在工具里另走一套。
    Set<String>? candidateIds;
    if (keyword.isNotEmpty) {
      final hits = await ProblemSearch(db).search(keyword, limit: 200);
      if (hits.isEmpty) {
        return ToolOutcome(
          content: jsonEncode({
            'matched': 0,
            'returned': 0,
            'problems': <Object>[],
            'note': '题库里没有题干含「$keyword」的题。'
                '这不代表用户没在那方面错 —— 换个说法再试，或改用 kp 参数按考点查。',
          }),
          summary: '题干含「$keyword」的题：0 道',
        );
      }
      candidateIds = {for (final h in hits) h.problemId};
    }

    final t = db.problemsIndex;
    final q = db.selectOnly(t)
      ..addColumns([
        t.id,
        t.stemText,
        t.primaryKpName,
        t.difficulty,
        t.source,
        t.createdAt,
      ]);
    if (candidateIds != null) q.where(t.id.isIn(candidateIds));
    if (kp.isNotEmpty) q.where(t.primaryKpName.like('%$kp%'));
    final rows = await q.get();

    final states = await db.select(db.userProblemState).get();
    final byId = {for (final s in states) s.problemId: s};

    final now = DateTime.now();
    // 关掉 fuzzing：同一个问题问两次要给出同一份数字，
    // 否则用户会以为"掌握度怎么掉下去了"。
    final scheduler = FsrsScheduler(enableFuzzing: false);

    final items = <Map<String, dynamic>>[];
    for (final r in rows) {
      final id = r.read(t.id) ?? '';
      final state = byId[id];
      final wrong = state?.wrongCount ?? 0;
      if (wrong < minWrong) continue;
      final mastery = masteryNowOf(state, scheduler, now);
      items.add({
        'id': id,
        'kp': r.read(t.primaryKpName),
        'difficulty': r.read(t.difficulty),
        'source': r.read(t.source),
        'stem': _clip(r.read(t.stemText) ?? '', kToolStemMax),
        'wrongCount': wrong,
        // null 与 0 意义完全不同：0 是"完全不会"，null 是"还没复习过，
        // 无从谈起"。压成同一个数会让模型把新题说成"掌握度 0%"。
        'masteryPercent': mastery == null ? null : (mastery * 100).round(),
        'reviewed': state != null && mastery != null,
        'starred': state?.starred ?? false,
        'lastWrong': _date(state?.lastWrong),
      });
    }

    items.sort((a, b) {
      final byWrong =
          (b['wrongCount'] as int).compareTo(a['wrongCount'] as int);
      if (byWrong != 0) return byWrong;
      return (a['id'] as String).compareTo(b['id'] as String);
    });

    final out = items.take(limit).toList();
    return ToolOutcome(
      content: jsonEncode({
        'matched': items.length,
        'returned': out.length,
        'truncated': items.length > out.length,
        'filter': {
          if (keyword.isNotEmpty) 'keyword': keyword,
          if (kp.isNotEmpty) 'kp': kp,
          'min_wrong': minWrong,
        },
        'problems': out,
        'note': items.isEmpty
            ? '没有满足条件的错题。若用户本来题就不多，这是正常的。'
            : 'masteryPercent 为 null 表示这道题还没复习过（不是掌握度 0）。',
      }),
      summary: items.isEmpty
          ? '没有符合条件的错题'
          : '查到 ${items.length} 道错题'
              '${items.length > out.length ? '（显示前 ${out.length} 道）' : ''}',
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. 取一道题的完整内容
// ─────────────────────────────────────────────────────────────────────────────

/// 按 id 读一道题的完整内容（题干 / 答案 / 解析 / 笔记）。
class GetProblemTool extends ChatTool {
  final AppDatabase db;

  /// 题目文件仓库（**按需**取，见文件头的"只做用到的事"）。
  final Future<ProblemStore> Function() loadStore;

  /// 用于把 Markdown 里的知识点 id 翻成名字。
  final KnowledgeLoader loadKnowledge;

  GetProblemTool({
    required this.db,
    required this.loadStore,
    required this.loadKnowledge,
  });

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'get_problem',
        description: '按题目 id 取出这道题的完整内容：题干、答案、解析、用户笔记。'
            '当用户说"讲讲我那道 XX 题""这道题我为什么错了"时，'
            '先用 query_wrong_problems 或 query_due_reviews 拿到 id，再用它取全文。'
            '不要凭空猜 id —— id 形如 2023-shu1-T18，必须来自别的查询结果。',
        parameters: {
          'type': 'object',
          'properties': {
            'id': {
              'type': 'string',
              'description': '题目 id，必须来自 query_wrong_problems / '
                  'query_due_reviews 的返回结果。',
            },
          },
          'required': ['id'],
        },
      );

  @override
  Future<ToolOutcome> run(Map<String, dynamic> args) async {
    final id = _asString(args, 'id');
    if (id.isEmpty) {
      return ToolOutcome(
        content: jsonEncode({'error': '缺少 id 参数'}),
        ok: false,
        summary: '没给题目 id',
      );
    }

    final read = await (await loadStore()).read(id);
    final p = read.problem;
    if (p == null) {
      return ToolOutcome(
        content: jsonEncode({
          'error': '读不到题目「$id」',
          'reason': read.error,
          'hint': 'id 可能不存在或写错了。先用 query_wrong_problems 拿一个真实 id。',
        }),
        ok: false,
        summary: '读不到题目 $id',
      );
    }

    final state = await (db.select(db.userProblemState)
          ..where((t) => t.problemId.equals(id)))
        .getSingleOrNull();
    final now = DateTime.now();
    final mastery = masteryNowOf(
      state,
      FsrsScheduler(enableFuzzing: false),
      now,
    );

    // 本体只加载一次。写在上面的 collection-for 里会让每个关联项
    // 各查一次（虽然本体有缓存，但那是实现细节，不该依赖）。
    final kb = await loadKnowledge();
    final kpPrimary = [
      for (final k in p.knowledge.where((k) => k.isPrimary))
        _kpName(kb, k.id) ?? k.id,
    ];

    return ToolOutcome(
      content: jsonEncode({
        'id': p.id,
        'subject': p.subject,
        // 用 `label`（"解答"）而不是 `name`（"solve"）—— 后者是代码里的
        // 枚举名，模型会把它当术语讲给用户听。
        'qtype': p.qtype.label,
        'difficulty': p.difficulty,
        'source': p.source,
        'sourceYear': p.sourceYear,
        'knowledge': kpPrimary,
        'userState': {
          'wrongCount': state?.wrongCount ?? 0,
          'masteryPercent': mastery == null ? null : (mastery * 100).round(),
          'starred': state?.starred ?? false,
          'wrongCauses': _decodeList(state?.errorCauses),
        },
        'stem': _clip(p.stem, kToolProblemBodyMax),
        'options': p.options,
        'answer': _clip(p.answer ?? '', kToolProblemBodyMax),
        'solution': _clip(p.solution ?? '', kToolProblemBodyMax),
        // 用户自己的笔记是**他的原话**，模型引用时要标明来源，
        // 不能把自己的推断混进去当成用户写的。
        'userNote': _clip(p.note ?? '', kToolProblemBodyMax),
        'note': '题干/答案/解析超过 $kToolProblemBodyMax 字会被截断。'
            'userNote 是用户自己写的笔记，回答时若引用请说明"你笔记里写着"。',
      }),
      summary: '读到题目 $id',
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. 查知识点
// ─────────────────────────────────────────────────────────────────────────────

/// 查知识点本体：名称 / 章节路径 / 考频 / 定义 / 常见陷阱。
class KnowledgePointsTool extends ChatTool {
  /// 知识点本体是异步载入的，所以传一个加载函数而不是本体本身 ——
  /// 工具是**长驻**的（注册一次用整个会话），而本体可能还没载入好。
  final Future<KnowledgeBase> Function() load;

  KnowledgePointsTool(this.load);

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'query_knowledge_points',
        description: '查询考研数学知识点大纲：按名称或别名搜索考点，'
            '返回它的章节路径、考频权重、定义与常见陷阱。'
            '当用户问"XX 考点考频高不高""XX 属于哪一章""XX 的定义是什么"时用它。'
            '留空 query 则返回考频最高的考点，可用于回答"哪些是重点"。',
        parameters: {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description': '知识点名称或别名的一部分，如"罗尔""洛必达"。留空表示按考频取前列。',
            },
            'only_leaves': {
              'type': 'boolean',
              'description': '是否只返回最末级考点（可挂题的）。默认 true。',
            },
            'limit': {
              'type': 'integer',
              'description': '最多返回几个，默认 15，上限 30。',
            },
          },
          'required': <String>[],
        },
      );

  @override
  Future<ToolOutcome> run(Map<String, dynamic> args) async {
    final query = _asString(args, 'query');
    final onlyLeaves = _asBool(args, 'only_leaves', true);
    final limit = _asInt(args, 'limit', 15);

    final kb = await load();

    List<KnowledgePoint> pool;
    if (query.isEmpty) {
      pool = kb
          .leavesByWeight()
          .where((k) => onlyLeaves ? k.isLeaf : true)
          .toList();
    } else {
      final q = query.toLowerCase();
      pool = kb.nodes.where((k) {
        if (onlyLeaves && !k.isLeaf) return false;
        if (k.name.toLowerCase().contains(q)) return true;
        if (k.id.toLowerCase().contains(q)) return true;
        for (final a in k.aliases) {
          if (a.toLowerCase().contains(q)) return true;
        }
        return false;
      }).toList();
    }

    final items = <Map<String, dynamic>>[];
    for (final k in pool.take(limit)) {
      final path = kb.pathTo(k.id).map((p) => p.name).join(' > ');
      items.add({
        'id': k.id,
        'name': k.name,
        'path': path,
        'isLeaf': k.isLeaf,
        'examWeight': k.examWeight,
        'examYears': k.examYears,
        'definition': _clip(k.definition ?? '', 200),
        'commonTraps': k.commonTraps.take(3).toList(),
        'aliases': k.aliases.take(5).toList(),
      });
    }

    return ToolOutcome(
      content: jsonEncode({
        'subject': kb.subjectName,
        'matched': pool.length,
        'returned': items.length,
        'truncated': pool.length > items.length,
        'knowledgePoints': items,
        'note': query.isEmpty
            ? '没有给 query，这里按考频权重从高到低列出。examWeight 越大越常考。'
            : '名称/别名/id 任一命中即算匹配。matched 是命中总数。',
      }),
      summary: query.isEmpty
          ? '按考频列出 ${items.length} 个考点'
          : '「$query」命中 ${pool.length} 个考点',
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. 查学习画像
// ─────────────────────────────────────────────────────────────────────────────

/// 学习画像：总量、薄弱考点、错因分布、章节掌握、最近趋势。
class ProfileTool extends ChatTool {
  /// 画像服务（按需取 —— 它会载入错因词表，金额不小）。
  final Future<MasteryService> Function() loadService;

  final Future<KnowledgeBase> Function() loadKnowledge;

  ProfileTool({required this.loadService, required this.loadKnowledge});

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'query_profile',
        description: '查询用户的学习画像：错题总量、平均掌握度、'
            '**最薄弱的考点**（按掌握度与错误次数综合排序）、错因分布、'
            '各章节掌握情况、最近两周的复习趋势。'
            '当用户问"我哪块最弱""我最该补什么""我最近复习得怎么样"时用它。'
            '这是唯一能回答"最弱"类问题的工具 —— 不要凭错题数量自己排序。',
        parameters: {
          'type': 'object',
          'properties': {
            'top_kp': {
              'type': 'integer',
              'description': '返回多少个最薄弱考点，默认 8，上限 20。',
            },
          },
          'required': <String>[],
        },
      );

  @override
  Future<ToolOutcome> run(Map<String, dynamic> args) async {
    final topKp = _asInt(args, 'top_kp', 8, max: 20);
    final kb = await loadKnowledge();
    final service = await loadService();
    final report = await service.build(knowledge: kb, topKp: topKp);

    if (report.isEmpty) {
      return ToolOutcome(
        content: jsonEncode({
          'totalProblems': 0,
          'note': '题库里一道题都没有，画像无从谈起。'
              '这时应该建议用户先去录入错题，而不是分析"薄弱点"。',
        }),
        summary: '题库是空的',
      );
    }

    return ToolOutcome(
      content: jsonEncode({
        'totalProblems': report.totalProblems,
        'reviewedProblems': report.reviewedProblems,
        'newProblems': report.newProblems,
        'stubbornProblems': report.stubbornProblems,
        'overallMasteryPercent': report.overallMastery == null
            ? null
            : (report.overallMastery! * 100).round(),
        'hasReviewData': report.hasReviewData,
        'weakestKnowledgePoints': [
          for (final k in report.weakest)
            {
              'kpId': k.kpId,
              'name': k.kpName,
              'chapter': k.chapterName,
              'masteryPercent':
                  k.mastery == null ? null : (k.mastery! * 100).round(),
              'wrongCount': k.wrongCount,
              'problemCount': k.problemCount,
              // 一起报出来是刻意的：只给一个平均掌握度，用户会以为
              // 那是 10 道题的结论，而可能只有 1 道复习过。
              'reviewedCount': k.reviewedCount,
              'stubbornCount': k.stubbornCount,
              'examWeight': k.examWeight,
            },
        ],
        'chapters': [
          for (final c in report.chapters.take(15))
            {
              'chapterId': c.chapterId,
              'name': c.chapterName,
              'masteryPercent':
                  c.mastery == null ? null : (c.mastery! * 100).round(),
              'problemCount': c.problemCount,
              'reviewedCount': c.reviewedCount,
              'wrongCount': c.wrongCount,
            },
        ],
        'errorCauses': [
          for (final c in report.causes.take(10))
            {'cause': c.causeName, 'count': c.problemCount},
        ],
        'trend': [
          for (final p in report.trend)
            {
              'date': _date(p.day),
              'reviews': p.reviews,
              'passRatePercent':
                  p.reviews == 0 ? null : (p.passRate * 100).round(),
            },
        ],
        // ⚠️ 缺数据必须说出来。一份只统计了新题的错因分布**看起来有数据**，
        // 而它是错的 —— 不提示的话模型会把这份分布当成全部事实讲出去。
        if (report.missingCauseData > 0)
          'dataWarning': '有 ${report.missingCauseData} 道题缺少错因数据'
              '（多半是旧版本录入的），所以错因分布不完整，'
              '不要据此下"某类错误占了大多数"的结论。',
        'note': report.hasReviewData
            ? 'weakestKnowledgePoints 已按薄弱度排序。masteryPercent 为 null '
                '表示该考点下一道题都没复习过 —— 那不是"掌握度 0"，'
                '而是"还没有数据"。'
            : '用户还没有任何复习记录，所以掌握度全部为空。'
                '此时**不要**说"你很薄弱"，只能说"还没有数据可供判断"。',
      }),
      summary: report.hasReviewData
          ? '画像：${report.totalProblems} 题，'
              '${report.weakest.length} 个薄弱考点'
          : '画像：${report.totalProblems} 题，尚无复习记录',
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. 查待复习
// ─────────────────────────────────────────────────────────────────────────────

/// 待复习：今天的到期统计 + 到期清单（含逾期天数）。
class DueReviewTool extends ChatTool {
  /// 复习仓库（按需取 —— 它需要题目仓库，会碰磁盘）。
  final Future<ReviewRepository> Function() loadRepo;

  /// 用于把 Markdown 里的知识点 id 翻成名字。
  final KnowledgeLoader loadKnowledge;

  DueReviewTool({required this.loadRepo, required this.loadKnowledge});

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'query_due_reviews',
        description: '查询复习计划：今天有多少张卡到期、其中多少是新卡、'
            '今天已经复习了几张、以及一张按优先级排好的到期清单。'
            '队列的次序已经考虑过"重做这道题是否有用"（计算粗心、'
            '审题失误这类错因会被排到后面）。'
            '当用户问"今天该复习什么""我还有多少没复习"时用它。',
        parameters: {
          'type': 'object',
          'properties': {
            'limit': {
              'type': 'integer',
              'description': '到期清单最多列出几条，默认 10，上限 30。',
            },
          },
          'required': <String>[],
        },
      );

  @override
  Future<ToolOutcome> run(Map<String, dynamic> args) async {
    final limit = _asInt(args, 'limit', 10);

    // ⚠️ 这里**不能**走 `dueQueueProvider` —— 它会先 `ensureCards()`
    // 补建缺失的卡片，那是写库。工具必须是只读的。
    // 代价是：如果索引里有题而状态表里没有，这里看不到它们。
    // 那属于"卡片还没对账"，用户打开一次复习页就会补上。
    final repo = await loadRepo();
    final stats = await repo.stats();
    final queue = await repo.dueQueue(limit: limit);
    final now = DateTime.now();
    final kb = await loadKnowledge();

    return ToolOutcome(
      content: jsonEncode({
        'totalCards': stats.totalCards,
        'dueNow': stats.dueNow,
        'newCards': stats.newCards,
        'reviewedToday': stats.reviewedToday,
        'upcoming7Days': stats.upcoming,
        'nextDueAt': _date(stats.nextDue),
        'dueList': [
          for (final c in queue)
            {
              'id': c.problemId,
              'isNew': c.isNew,
              'overdueDays': c.overdueDays(now),
              'wrongCount': c.state.wrongCount,
              'kp': _kpName(kb, _primaryKpId(c.problem)),
              'stem': _clip(c.problem?.stem ?? '', kToolStemMax),
              // 卡片在但内容读不到：如实说，而不是给一个空题干
              // 让模型以为那是"一道没题干的题"。
              if (c.problem == null) 'loadError': c.loadError ?? '题目内容读取失败',
            },
        ],
        'note': stats.isEmpty
            ? '一张卡都没有 —— 用户还没录过错题，或者尚未对账建卡。'
            : 'dueNow 包含新卡（新卡随时可复习）。upcoming7Days 下标 0 是今天。'
                '要讲某道题的细节，用它的 id 调 get_problem。',
      }),
      summary: stats.isEmpty
          ? '还没有复习卡片'
          : '今天到期 ${stats.dueNow} 张'
              '${stats.reviewedToday > 0 ? '，已复习 ${stats.reviewedToday} 张' : ''}',
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 6. 提议：录入一道题
// ─────────────────────────────────────────────────────────────────────────────

/// 把一道题整理成"待确认的录入"。
///
/// ## 它为什么要把查重也做了
///
/// 用户在错题本上**再碰到同一道题**是高频事件。等到用户点确认才发现
/// "这题已经录过了"，那张卡片就白摆了；更糟的是如果不查重直接写，
/// 就会按指纹生成第二个 id，而错题次数与 FSRS 进度是挂在 id 上的 ——
/// 用户的复习进度凭空消失。
///
/// 所以查重放在**提议时**，结果直接写进卡片：已有的话明说
/// "确认后将沿用那道题"，用户点下去的每一刻都知道自己在做什么。
class CreateProblemTool extends ChatTool {
  final Future<ProblemService> Function() loadService;

  final KnowledgeLoader loadKnowledge;

  /// 错因词表。可选 —— 拿不到就把 id 原样显示（见 [writeCauseLabel]）。
  final Future<ErrorCauseCatalog?> Function()? loadCauses;

  CreateProblemTool({
    required this.loadService,
    required this.loadKnowledge,
    this.loadCauses,
  });

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'create_problem',
        description: '把一道题**录入用户的错题本**。当用户贴来一道题并说'
            '"帮我记下来""加进错题本"，或者口述了一道自己的错题时用它。'
            '⚠️ 调用它**不会**立刻保存 —— 它只是把这道题整理成一张确认卡片，'
            '用户点了确认才会真正写进题库。所以调用之后**不要**说已经存好了。'
            '题干必须是用户给出的内容，**不要自己编题**。'
            '公式用 LaTeX（行内 \$...\$，独立成行 \$\$...\$\$）。'
            '如果用户没给答案或解析，就不要填 —— 空着比编一个强。',
        parameters: {
          'type': 'object',
          'properties': {
            'stem': {
              'type': 'string',
              'description': '题干，用户给的原话。公式用 LaTeX。必填。',
            },
            'qtype': {
              'type': 'string',
              'enum': ['choice', 'fill', 'solve', 'proof'],
              'description': '题型：选择 / 填空 / 解答 / 证明。默认 solve。',
            },
            'difficulty': {
              'type': 'integer',
              'description': '难度：1 基础、2 综合、3 拓展。默认 2。',
            },
            'options': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': '选择题的选项（qtype=choice 时才需要）。',
            },
            'answer': {'type': 'string', 'description': '答案。用户没给就留空。'},
            'solution': {
              'type': 'string',
              'description': '解题过程。用户给的解析放这里；'
                  '你自己写的思路要说明是 AI 补充的，或者干脆放正文里讲、不要写进来。',
            },
            'note': {
              'type': 'string',
              'description': '用户自己的笔记（"我当时错在……"这类原话）。',
            },
            'source': {
              'type': 'string',
              'description': '题目的出处，如"2023 数学一第 18 题"。',
            },
            'source_type': {
              'type': 'string',
              'enum': ['real_exam', 'mock', 'textbook', 'self_made', 'unknown'],
              'description': '来源类型：真题 / 模拟 / 教辅 / 自编 / 未知。不确定留空。',
            },
            'source_year': {'type': 'integer', 'description': '真题年份，如 2023。'},
            'knowledge_point': {
              'type': 'string',
              'description': '主考点的**名称**，如"罗尔定理"。'
                  '不确定就留空 —— 留空只会让这道题被标为待复核，'
                  '填错会让它归到错的章节里。',
            },
            'error_causes': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': '错因。用户说了为什么错就填，如"计算粗心"。',
            },
            'tags': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': '自定义标签。',
            },
          },
          'required': ['stem'],
        },
      );

  @override
  Future<ToolOutcome> run(Map<String, dynamic> args) async {
    final stem = _asString(args, 'stem');
    final kb = await loadKnowledge();

    final draft = ProblemDraft(
      stem: stem,
      qtype: QuestionType.fromId(_asString(args, 'qtype')),
      difficulty: _asInt(args, 'difficulty', 2, min: 1, max: 3),
      options: _asStringList(args, 'options'),
      answer: _asString(args, 'answer'),
      solution: _asString(args, 'solution'),
      note: _asString(args, 'note'),
      source: _asString(args, 'source'),
      sourceType: SourceType.fromId(_asString(args, 'source_type')),
      sourceYear: _asIntOrNull(args['source_year']),
      tags: _asStringList(args, 'tags'),
    );

    // 校验拦在**提议之前**：一道题干为空的题摆到用户面前去确认，
    // 只会让他怀疑这个助手到底在干什么。
    final issues = draft.validate(knowledge: kb);
    final blocking =
        issues.where((i) => i.level == DraftIssueLevel.blocking).toList();
    if (blocking.isNotEmpty) {
      return ToolOutcome(
        content: jsonEncode({
          'error': '这道题还不能录入',
          'problems': [for (final i in blocking) i.message],
          'hint': '把上面这些问题解决后再调用一次。题干不能为空，'
              '选择题至少要有 2 个选项。',
        }),
        ok: false,
        summary: '题目不完整：${blocking.first.message}',
      );
    }

    // 主考点：用户/模型给的是**名字**，这里翻成 id。翻不到就留空 + 警告。
    final kpQuery = _asString(args, 'knowledge_point');
    final kp = _matchKnowledge(kb, kpQuery);

    // 错因：给的可能是 id，也可能是"计算粗心"这种名字。
    final causeQuery = _asStringList(args, 'error_causes');
    final causes = await loadCauses?.call();
    final causeIds = _matchCauses(causes, causeQuery);

    draft
      ..primaryKpId = kp?.id
      ..errorCauses = causeIds;

    final service = await loadService();
    final dups = await service.findByFingerprint(draft.fingerprint());

    final fields = <WriteField>[
      WriteField('题干', writePreview(stem, 120)),
      WriteField('题型', draft.qtype.label),
      WriteField('难度', _difficultyLabel(draft.difficulty)),
      if (draft.options.isNotEmpty)
        WriteField('选项', writePreview(draft.options.join(' / '), 120)),
      WriteField('答案', _presence(draft.answer)),
      WriteField('解析', _presence(draft.solution)),
      WriteField(
        '主考点',
        kp == null ? '（未标注）' : '${kp.name}（${kp.id}）',
      ),
      if (draft.source != null || draft.sourceType != SourceType.unknown)
        WriteField(
          '来源',
          [
            if (draft.source != null) draft.source!,
            draft.sourceType.label,
            if (draft.sourceYear != null) '${draft.sourceYear} 年',
          ].join(' · '),
        ),
      if (causeIds.isNotEmpty)
        WriteField('错因', writeCauseLabel(causes, causeIds)),
      if (draft.note != null) WriteField('我的笔记', writePreview(draft.note!, 120)),
      if (draft.tags.isNotEmpty) WriteField('标签', draft.tags.join('、')),
    ];

    // 警告：按"用户不知道就会做错决定"排序，一次只说最要紧的那条。
    final String? warning;
    if (dups.isNotEmpty) {
      warning = '题库里已有一道题干相同的题（${dups.first.id}）。'
          '确认后会用它做覆盖，**它已有的复习进度会保留**。'
          '如果这其实是另一道题，请先取消，再让我改题干。';
    } else if (kp == null) {
      warning = kpQuery.isEmpty
          ? '这道题没有主考点，保存后会被标为「待复核」，需要你之后在错题本里补。'
          : '考点「$kpQuery」在本体里找不到，所以没有标注 —— '
              '保存后会被标为「待复核」。';
    } else {
      warning = null;
    }

    final proposal = ChatWriteProposal(
      id: ChatWriteProposal.newId(kWriteCreateProblem),
      kind: kWriteCreateProblem,
      title: '录入这道题',
      summary: dups.isEmpty
          ? '把上面的内容存进错题本'
          : '用上面的内容覆盖已有的「${dups.first.id}」',
      fields: fields,
      warning: warning,
      payload: {
        // 有重题时带上它的 id：`save` 会因此沿用这个 id 而不是新生成一个。
        'target_id': dups.isEmpty ? null : dups.first.id,
        'stem': stem,
        'qtype': draft.qtype.id,
        'difficulty': draft.difficulty,
        'options': draft.options,
        'answer': draft.answer,
        'solution': draft.solution,
        'note': draft.note,
        'source': draft.source,
        'source_type': draft.sourceType.id,
        'source_year': draft.sourceYear,
        'kp_id': draft.primaryKpId,
        'error_causes': causeIds,
        'tags': draft.tags,
      },
    );

    return ToolOutcome(
      content: jsonEncode({
        'status': 'pending_user_confirmation',
        'proposal': proposal.title,
        'prepared': '已经把这道题整理成一张确认卡片摆给用户了。'
            '用户点确认之后才会真正写入题库。',
        'instruction': '**现在什么都还没有发生。** 不要对用户说"已经录入/已经保存"，'
            '也不要说"正在保存"。可以简短说明你整理了哪些内容，'
            '然后请他确认。**不要重复调用本工具**。',
        'duplicateOf': dups.isEmpty ? null : dups.first.id,
      }),
      summary: dups.isEmpty ? '待确认：录入一道题' : '待确认：覆盖已有题目',
      proposal: proposal,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 7. 提议：修改一道题
// ─────────────────────────────────────────────────────────────────────────────

/// 把"要改哪几处"整理成一张带新旧对照的确认卡片。
class UpdateProblemTool extends ChatTool {
  final Future<ProblemService> Function() loadService;

  final KnowledgeLoader loadKnowledge;

  final Future<ErrorCauseCatalog?> Function()? loadCauses;

  UpdateProblemTool({
    required this.loadService,
    required this.loadKnowledge,
    this.loadCauses,
  });

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'update_problem',
        description: '修改一道已录入的题目的内容（题干、答案、解析、笔记、'
            '主考点、错因、标签等）。'
            '⚠️ **只传要改的字段** —— 没传的字段保持原样；传了就等于把它覆盖掉。'
            '⚠️ 调用它不会立刻改动：它只会生成一张新旧对照的确认卡片，'
            '用户点确认才生效。所以调用之后不要说已经改好了。'
            'id 必须来自 query_wrong_problems / get_problem / query_due_reviews '
            '的返回结果，不要自己编。'
            '这条工具**改不了**错题次数与复习进度 —— 那是复习页的职责。',
        parameters: {
          'type': 'object',
          'properties': {
            'id': {'type': 'string', 'description': '题目 id。必填。'},
            'stem': {'type': 'string', 'description': '新的题干（整段替换）。'},
            'answer': {
              'type': 'string',
              'description': '新的答案。传空字符串表示**清空**它。',
            },
            'solution': {'type': 'string', 'description': '新的解析。空串表示清空。'},
            'note': {'type': 'string', 'description': '新的笔记。空串表示清空。'},
            'difficulty': {
              'type': 'integer',
              'description': '新的难度：1 基础、2 综合、3 拓展。',
            },
            'qtype': {
              'type': 'string',
              'enum': ['choice', 'fill', 'solve', 'proof'],
              'description': '新的题型。',
            },
            'options': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': '新的选项列表（整组替换）。',
            },
            'source': {'type': 'string', 'description': '新的出处。空串表示清空。'},
            'knowledge_point': {
              'type': 'string',
              'description': '新的主考点**名称**，如"罗尔定理"。'
                  '传空字符串表示取消主考点标注。',
            },
            'error_causes': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': '新的错因列表（整组替换）。',
            },
            'tags': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': '新的标签列表（整组替换）。',
            },
          },
          'required': ['id'],
        },
      );

  @override
  Future<ToolOutcome> run(Map<String, dynamic> args) async {
    final id = _asString(args, 'id');
    if (id.isEmpty) {
      return ToolOutcome(
        content: jsonEncode({
          'error': '缺少 id 参数',
          'hint': 'id 只能来自查询结果。先用 query_wrong_problems 拿一个真实 id。',
        }),
        ok: false,
        summary: '没给题目 id',
      );
    }

    final service = await loadService();
    final read = await service.store.read(id);
    final existing = read.problem;
    if (existing == null) {
      return ToolOutcome(
        content: jsonEncode({
          'error': '读不到题目「$id」',
          'reason': read.error,
          'hint': 'id 可能不存在或写错了。先用 query_wrong_problems 拿一个真实 id。',
        }),
        ok: false,
        summary: '读不到题目 $id',
      );
    }

    final kb = await loadKnowledge();
    final causes = await loadCauses?.call();

    // changes 里只放**真的要改**的键。判据是"模型给了这个键"，
    // 不是"这个键的值非空" —— 后者会把"请把解析清空"当成"没打算改解析"。
    final changes = <String, dynamic>{};
    final fields = <WriteField>[];

    void diff(String key, String label, String? before, String after) {
      changes[key] = after;
      fields.add(WriteField(label, writePreview(after, 160), before: before ?? '（空）'));
    }

    if (args.containsKey('stem')) {
      diff('stem', '题干', existing.stem, _asString(args, 'stem'));
    }
    if (args.containsKey('answer')) {
      diff('answer', '答案', existing.answer, _asString(args, 'answer'));
    }
    if (args.containsKey('solution')) {
      diff('solution', '解析', existing.solution, _asString(args, 'solution'));
    }
    if (args.containsKey('note')) {
      diff('note', '我的笔记', existing.note, _asString(args, 'note'));
    }
    if (args.containsKey('source')) {
      diff('source', '来源', existing.source, _asString(args, 'source'));
    }
    if (args.containsKey('difficulty')) {
      final v = _asInt(args, 'difficulty', existing.difficulty, min: 1, max: 3);
      changes['difficulty'] = v;
      fields.add(WriteField(
        '难度',
        _difficultyLabel(v),
        before: _difficultyLabel(existing.difficulty),
      ));
    }
    if (args.containsKey('qtype')) {
      final v = QuestionType.fromId(_asString(args, 'qtype'));
      changes['qtype'] = v.id;
      fields.add(WriteField('题型', v.label, before: existing.qtype.label));
    }
    if (args.containsKey('options')) {
      final v = _asStringList(args, 'options');
      changes['options'] = v;
      fields.add(WriteField(
        '选项',
        writePreview(v.join(' / '), 160),
        before: existing.options.isEmpty ? '（空）' : existing.options.join(' / '),
      ));
    }
    if (args.containsKey('knowledge_point')) {
      final q = _asString(args, 'knowledge_point');
      final kp = _matchKnowledge(kb, q);
      if (q.isNotEmpty && kp == null) {
        return ToolOutcome(
          content: jsonEncode({
            'error': '本体里找不到考点「$q」',
            'hint': '先用 query_knowledge_points 确认它的准确名称；'
                '或者不传 knowledge_point（保持原来的主考点）。',
          }),
          ok: false,
          summary: '考点「$q」不存在',
        );
      }
      changes['kp_id'] = kp?.id ?? '';
      fields.add(WriteField(
        '主考点',
        kp == null ? '（取消标注）' : '${kp.name}（${kp.id}）',
        before: _kpName(kb, _primaryKpId(existing)) ?? '（未标注）',
      ));
    }
    if (args.containsKey('error_causes')) {
      final v = _matchCauses(causes, _asStringList(args, 'error_causes'));
      changes['error_causes'] = v;
      fields.add(WriteField(
        '错因',
        writeCauseLabel(causes, v),
        before: writeCauseLabel(causes, existing.errorCauses),
      ));
    }
    if (args.containsKey('tags')) {
      final v = _asStringList(args, 'tags');
      changes['tags'] = v;
      fields.add(WriteField(
        '标签',
        v.isEmpty ? '（清空）' : v.join('、'),
        before: existing.tags.isEmpty ? '（空）' : existing.tags.join('、'),
      ));
    }

    if (changes.isEmpty) {
      return ToolOutcome(
        content: jsonEncode({
          'error': '没有给出任何要修改的字段',
          'hint': '这次调用什么也不会发生。请说明要改哪一项，或者先问用户想改什么。',
        }),
        ok: false,
        summary: '没说要改什么',
      );
    }

    final proposal = ChatWriteProposal(
      id: ChatWriteProposal.newId(kWriteUpdateProblem),
      kind: kWriteUpdateProblem,
      title: '修改这道题',
      summary: '改动 ${changes.length} 处（其他内容不动）',
      fields: [
        WriteField('题目', '$id · ${_clip(existing.stem, 60)}'),
        ...fields,
      ],
      warning: '只会改上面列出的这几项；题目已有的复习进度、错题次数一律不动。',
      payload: {'id': id, 'changes': changes},
    );

    return ToolOutcome(
      content: jsonEncode({
        'status': 'pending_user_confirmation',
        'proposal': proposal.title,
        'willChange': changes.keys.toList(),
        'instruction': '**现在什么都还没有发生。** 不要对用户说"已经改好/已经更新"，'
            '把改动讲清楚然后请他确认。**不要重复调用本工具**。',
      }),
      summary: '待确认：改 ${changes.length} 处',
      proposal: proposal,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 8. 提议：删除一道题
// ─────────────────────────────────────────────────────────────────────────────

/// 提议删掉一道题。
///
/// 这是唯一**不可逆**的写操作，所以它把"要被删掉的是什么"摆得最全：
/// 题干、考点、错过几次。用户在确认前必须能认出这道题。
class DeleteProblemTool extends ChatTool {
  final Future<ProblemService> Function() loadService;

  final KnowledgeLoader loadKnowledge;

  DeleteProblemTool({required this.loadService, required this.loadKnowledge});

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'delete_problem',
        description: '删除一道题，连同它的复习进度与复习历史。'
            '⚠️ 这是不可逆的操作，**只有用户明确说"删掉某道题"时才能调用** —— '
            '不要因为你自己觉得某道题太简单、重复、或者不重要就提议删除。'
            '⚠️ 调用它不会立刻删除，它会生成一张确认卡片，用户点确认才生效。'
            'id 必须来自查询结果。',
        parameters: {
          'type': 'object',
          'properties': {
            'id': {'type': 'string', 'description': '题目 id。必填。'},
            'reason': {
              'type': 'string',
              'description': '用户为什么要删（可选，会显示在卡片上）。',
            },
          },
          'required': ['id'],
        },
      );

  @override
  Future<ToolOutcome> run(Map<String, dynamic> args) async {
    final id = _asString(args, 'id');
    if (id.isEmpty) {
      return ToolOutcome(
        content: jsonEncode({
          'error': '缺少 id 参数',
          'hint': 'id 只能来自查询结果。',
        }),
        ok: false,
        summary: '没给题目 id',
      );
    }

    final service = await loadService();
    final read = await service.store.read(id);
    final existing = read.problem;
    if (existing == null) {
      return ToolOutcome(
        content: jsonEncode({
          'error': '读不到题目「$id」',
          'reason': read.error,
          'hint': '它可能已经被删掉了。',
        }),
        ok: false,
        summary: '读不到题目 $id',
      );
    }

    final kb = await loadKnowledge();
    final state = await (service.db.select(service.db.userProblemState)
          ..where((t) => t.problemId.equals(id)))
        .getSingleOrNull();

    final proposal = ChatWriteProposal(
      id: ChatWriteProposal.newId(kWriteDeleteProblem),
      kind: kWriteDeleteProblem,
      title: '删除这道题',
      summary: '不可逆：连同复习进度一起清掉',
      destructive: true,
      fields: [
        WriteField('题干', _clip(existing.stem, 120)),
        WriteField('题目 id', id),
        WriteField('主考点', _kpName(kb, _primaryKpId(existing)) ?? '（未标注）'),
        WriteField('错过次数', '${state?.wrongCount ?? 0} 次'),
        if (_asString(args, 'reason').isNotEmpty)
          WriteField('你说的原因', _asString(args, 'reason')),
      ],
      warning: '会一起删掉：题目文件、复习进度、复习历史、'
          '知识点关联。**这个操作不能撤销**。'
          '如果只是想让它别再出现，取消即可 —— 可以改用「不再复习」的功能。',
      payload: {'id': id},
    );

    return ToolOutcome(
      content: jsonEncode({
        'status': 'pending_user_confirmation',
        'proposal': proposal.title,
        'stem': _clip(existing.stem, 120),
        'instruction': '**这道题现在还在，什么都还没有删。** 不要对用户说"已经删掉了"。'
            '请让用户确认卡片上那道题确实是他要删的。**不要重复调用本工具**。',
      }),
      summary: '待确认：删除「${_clip(existing.stem, 24)}」',
      proposal: proposal,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 9. 提议：组一份卷
// ─────────────────────────────────────────────────────────────────────────────

/// 组一份卷，把结果摆出来让用户确认后再保存。
///
/// 组卷本身是**纯计算**（不写库），所以这里可以在提议阶段就把卷子算出来，
/// 卡片上显示的是"真的会得到什么"（题量、总分、缺哪几个题位、有哪些降级），
/// 而不是"我打算按什么参数组"。用户确认之后再算一遍并保存 ——
/// 见 `ChatWriteExecutor._execCompose` 里关于"为什么重组"的说明。
class ComposePaperTool extends ChatTool {
  final Future<ProblemService> Function() loadService;

  final Future<PaperRepository> Function() loadPaper;

  ComposePaperTool({required this.loadService, required this.loadPaper});

  @override
  ToolSpec get spec => const ToolSpec(
        name: 'compose_paper',
        description: '按模板组一份试卷并**保存到组卷历史**。'
            '当用户说"给我出一份卷子""组一套模拟卷""把我的错题组一份专练"时用它。'
            '⚠️ 调用它不会立刻保存：它会把组好的卷子摆出来让你确认，'
            '用户点确认才写进历史。所以调用之后不要说已经存好了。'
            '模板名必须来自 templates 参数列出的那些，不要自己编。',
        parameters: {
          'type': 'object',
          'properties': {
            'template': {
              'type': 'string',
              'description': '模板名。可用的有 real_full（真题全卷）、'
                  'mock（限时模考）、wrong_only（错题专练）等；'
                  '传错会返回该科目实际可用的模板列表。',
            },
            'subject': {
              'type': 'string',
              'enum': ['math1', 'math2', 'math3'],
              'description': '科目。默认数学一。',
            },
            'title': {'type': 'string', 'description': '这份卷子的标题（可选）。'},
            'difficulty_tolerance': {
              'type': 'integer',
              'description': '难度匹配的宽容度：0 必须精确、1 允许相邻一档（默认）、'
                  '2 不管难度。',
            },
            'prefer_wrong': {
              'type': 'boolean',
              'description': '是否优先抽用户做错过的题。默认 true。',
            },
            'prefer_weak': {
              'type': 'boolean',
              'description': '是否优先抽薄弱考点的题。默认 true。',
            },
            'diversify': {
              'type': 'boolean',
              'description': '是否避免同一考点在一份卷子里重复出现。默认 true。',
            },
          },
          'required': ['template'],
        },
      );

  @override
  Future<ToolOutcome> run(Map<String, dynamic> args) async {
    final repo = await loadPaper();
    final subject = _asString(args, 'subject').isEmpty
        ? 'math1'
        : _asString(args, 'subject');
    final templateId = _asString(args, 'template');

    final loaded = await repo.templates(subject: subject);
    final template = loaded[templateId];
    if (template == null) {
      // 列出手上真有的，让模型改一个名字再来 —— 比让它猜一圈省事得多。
      return ToolOutcome(
        content: jsonEncode({
          'error': '没有「$templateId」这个模板',
          'reason': loaded.error,
          'available': [
            for (final t in loaded.templates.values)
              {'id': t.id, 'name': t.name, 'description': t.description},
          ],
          'hint': '用上面 available 里的 id 再调用一次。'
              '如果 available 是空的，说明模板文件读不出来，'
              '如实告诉用户组卷暂时不可用。',
        }),
        ok: false,
        summary: '没有「$templateId」模板',
      );
    }

    final tolerance = _asInt(args, 'difficulty_tolerance', 1, min: 0, max: 2);
    final preferWrong = _asBool(args, 'prefer_wrong', true);
    final preferWeak = _asBool(args, 'prefer_weak', true);
    final diversify = _asBool(args, 'diversify', true);

    final pool = await repo.candidates(
      subject: subject,
      onlyWrong: templateId == 'wrong_only',
    );
    final result = const PaperComposer().compose(
      request: PaperRequest(
        template: template,
        subject: subject,
        difficultyTolerance: tolerance,
        preferWrong: preferWrong,
        preferWeak: preferWeak,
        diversify: diversify,
        drillCauseIds: repo.drillCauseIds,
      ),
      pool: pool,
    );

    if (result.items.isEmpty) {
      return ToolOutcome(
        content: jsonEncode({
          'error': '按这个条件一道题都选不出来',
          'poolSize': pool.length,
          'hint': '题库太小或者题型对不上。如实告诉用户"现在组不出来"，'
              '可以说还差哪些题型的题（见模板的 countsByQtype）。'
              '**不要**改成别的模板再偷偷试一遍。',
        }),
        ok: false,
        summary: '组不出来：题库缺少合适的题',
      );
    }

    final bySection = <String, int>{};
    for (final it in result.items) {
      bySection[it.seat.sectionName] =
          (bySection[it.seat.sectionName] ?? 0) + 1;
    }

    final proposal = ChatWriteProposal(
      id: ChatWriteProposal.newId(kWriteComposePaper),
      kind: kWriteComposePaper,
      title: '生成一份试卷',
      summary: '${template.name} · ${result.items.length} 题 · '
          '${result.totalScore} 分',
      fields: [
        WriteField('模板', '${template.name}（${template.id}）'),
        WriteField('科目', subject),
        WriteField(
          '题量',
          '${result.items.length} / ${template.questionCount} 题',
        ),
        WriteField(
          '总分',
          '${result.totalScore} 分'
              '${result.hasEstimatedScores ? '（含估算分值）' : ''}',
        ),
        if (bySection.isNotEmpty)
          WriteField(
            '构成',
            bySection.entries.map((e) => '${e.key} ${e.value}').join(' · '),
          ),
        if (result.emptySeats.isNotEmpty)
          WriteField(
            '缺的题位',
            result.emptySeats
                .take(6)
                .map((s) => '第 ${s.no} 题（${s.sectionName}）')
                .join('、'),
          ),
        WriteField(
          '抽题偏好',
          [
            preferWrong ? '优先做错过的题' : '不看错题',
            preferWeak ? '优先薄弱考点' : '不看掌握度',
            diversify ? '同考点不重复' : '允许重复考点',
          ].join(' · '),
        ),
        if (result.warnings.isNotEmpty)
          WriteField('调整说明', '${result.warnings.length} 条（见组卷页）'),
      ],
      warning: result.isComplete
          ? '确认后会立即按当前题库生成并保存，之后能在「组卷」页的历史里看到。'
          : '有 ${result.emptySeats.length} 个题位没题可填 —— '
              '这份卷子会比模板少几道题。确认后会照这样保存。',
      payload: {
        'subject': subject,
        'template_id': templateId,
        'title': _asString(args, 'title'),
        'difficulty_tolerance': tolerance,
        'prefer_wrong': preferWrong,
        'prefer_weak': preferWeak,
        'diversify': diversify,
      },
    );

    return ToolOutcome(
      content: jsonEncode({
        'status': 'pending_user_confirmation',
        'proposal': proposal.title,
        'preview': {
          'template': template.name,
          'items': result.items.length,
          'totalScore': result.totalScore,
          'emptySeats': result.emptySeats.length,
          'warnings': result.warnings,
          'firstProblems': [
            for (final it in result.items.take(5))
              {
                'no': it.seat.no,
                'id': it.problemId,
                'kp': it.primaryKpName,
                'difficulty': it.actualDifficulty,
              },
          ],
        },
        'instruction': '**这份卷子还没有保存。** 不要对用户说"已经生成好了"。'
            '把预览讲给他听（题量、总分、缺了哪几道），然后请他确认。'
            '**不要重复调用本工具**。',
      }),
      summary: '待确认：${template.name} ${result.items.length} 题',
      proposal: proposal,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 参数取值：模型给的东西一律当作不可信输入
// ─────────────────────────────────────────────────────────────────────────────

/// 取一个整数参数并夹紧到 `[min, max]`。
///
/// 三种输入都要认：正确类型（int）、`double`（有些模型发 `10.0`）、
/// 字符串（有些发 `"10"`）。认不出来就用默认值 ——
/// 报错会让一次本来能成的查询白跑，而默认值只影响"查得多宽"。
int _asInt(
  Map<String, dynamic> args,
  String key,
  int fallback, {
  int min = 1,
  int max = kMaxToolRows,
}) {
  final v = args[key];
  int? n;
  if (v is int) {
    n = v;
  } else if (v is num) {
    n = v.round();
  } else if (v is String) {
    n = int.tryParse(v.trim());
  }
  if (n == null) return fallback.clamp(min, max).toInt();
  return n.clamp(min, max).toInt();
}

String _asString(Map<String, dynamic> args, String key) {
  final v = args[key];
  if (v == null) return '';
  final s = v is String ? v : v.toString();
  return s.trim();
}

bool _asBool(Map<String, dynamic> args, String key, bool fallback) {
  final v = args[key];
  if (v is bool) return v;
  if (v is String) {
    final s = v.trim().toLowerCase();
    if (s == 'true' || s == '1' || s == 'yes') return true;
    if (s == 'false' || s == '0' || s == 'no') return false;
  }
  return fallback;
}

/// 截断长文本，并在末尾**留一个记号**。
///
/// 记号不能省：模型看到一段突然中断的文字，可能会把
/// "截断"理解成"这就是全部"。加个 `…（已截断）` 它才知道后面还有。
String _clip(String s, int max) {
  final t = s.trim();
  if (t.length <= max) return t;
  return '${t.substring(0, max)}…（已截断）';
}

/// 日期 → `YYYY-MM-DD`。null 原样返回 null（不编一个假日期）。
String? _date(DateTime? t) {
  if (t == null) return null;
  return '${t.year.toString().padLeft(4, '0')}-'
      '${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';
}

/// 解一个 JSON 字符串数组。
///
/// 坏数据退化成空列表而不是抛 —— 用户状态表里的这一列是历史遗留的
/// 自由格式，为了它在一次查询里炸掉整轮对话不值得。
List<String> _decodeList(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const [];
  try {
    final j = jsonDecode(raw);
    if (j is List) return [for (final e in j) e.toString()];
    return const [];
  } catch (_) {
    return const [];
  }
}

/// 取一个字符串数组参数。
///
/// 单个字符串也收：模型偶尔把 `["calc"]` 写成 `"calc"`，
/// 为这个报错会让一次本来能成的调用白跑。
List<String> _asStringList(Map<String, dynamic> args, String key) {
  final v = args[key];
  if (v is List) {
    final out = <String>[];
    for (final e in v) {
      final s = _one(e);
      if (s.isNotEmpty) out.add(s);
    }
    return out;
  }
  final s = _one(v);
  return s.isEmpty ? const [] : [s];
}

/// 单个值 → 去空白的字符串。
String _one(Object? v) {
  if (v == null) return '';
  return (v is String ? v : v.toString()).trim();
}

/// 取一个可空整数。认不出来返回 null（**不回落到 0**）——
/// 年份的 0 会变成一个看起来像真数据的 `0 年`。
int? _asIntOrNull(Object? v) {
  if (v is int) return v;
  if (v is num) return v.round();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

/// 难度 → 卡片上的说法。
String _difficultyLabel(int d) => switch (d) {
      1 => '1 · 基础',
      3 => '3 · 拓展',
      _ => '2 · 综合',
    };

/// 卡片上的"这一项有没有内容"。
///
/// **不把长文本原样塞进卡片**：用户要确认的是"要不要写进去"，
/// 而不是重读一遍解析。给长度比给全文更有用。
String _presence(String? s) {
  final t = s?.trim() ?? '';
  if (t.isEmpty) return '（没有填）';
  return '已填 · ${t.length} 字';
}

/// 把"考点名称"翻成本体里的节点。
///
/// ## 为什么优先找叶子
///
/// 只有叶子（最末级考点）才是能挂题的那一层。用户说"中值定理"时，
/// 如果本体里它是一个**章节**，直接把章节 id 写成主考点会让这道题
/// 归到一个永远不会出现在错题本筛选里的层级。
///
/// ## 为什么最后还要退一步认非叶子
///
/// 因为返回 null 的后果是"这道题被标为待复核"，而**章节级也总好过没有**：
/// 用户之后补标注比从头想一遍容易。措辞上只是"未标注"与"标到了章"的差别，
/// 而 null 会让 `query_wrong_problems` 按考点查不到它。
KnowledgePoint? _matchKnowledge(KnowledgeBase? kb, String query) {
  final q = query.trim();
  if (q.isEmpty || kb == null) return null;

  // 直接给 id。模型可能从上一次查询结果里拿到了 id 而不是名字。
  final byId = kb.byId[q];
  if (byId != null) return byId;

  final lower = q.toLowerCase();
  final leaves = kb.nodes.where((k) => k.isLeaf).toList();

  for (final k in leaves) {
    if (k.name.toLowerCase() == lower) return k;
  }
  for (final k in leaves) {
    for (final a in k.aliases) {
      if (a.toLowerCase() == lower) return k;
    }
  }

  // 包含匹配取**名字最短**的那个：越短越具体。
  KnowledgePoint? best;
  for (final k in leaves) {
    if (!k.name.toLowerCase().contains(lower)) continue;
    if (best == null || k.name.length < best.name.length) best = k;
  }
  if (best != null) return best;

  for (final k in kb.nodes) {
    if (k.name.toLowerCase() == lower) return k;
  }
  for (final k in kb.nodes) {
    for (final a in k.aliases) {
      if (a.toLowerCase() == lower) return k;
    }
  }
  return null;
}

/// 把错因的"说法"翻成词表里的 id。
///
/// 模型给的很可能是"计算粗心"而不是 `calc`，两种都认。
/// **认不出来就丢掉**（不猜一个相近的）：错因会进组卷的"错因对症"那一维，
/// 猜错会让这份卷子的构成悄悄偏掉，而用户看不出为什么。
List<String> _matchCauses(ErrorCauseCatalog? catalog, List<String> queries) {
  if (queries.isEmpty) return const [];
  if (catalog == null) return queries;

  final out = <String>[];
  for (final raw in queries) {
    final q = raw.trim();
    if (q.isEmpty) continue;

    String? hit;
    for (final c in catalog.causes) {
      if (c.id == q) {
        hit = c.id;
        break;
      }
    }
    if (hit == null) {
      for (final c in catalog.causes) {
        if (c.name == q) {
          hit = c.id;
          break;
        }
      }
    }
    if (hit == null) {
      for (final c in catalog.causes) {
        if (c.name.contains(q) || q.contains(c.name)) {
          hit = c.id;
          break;
        }
      }
    }
    if (hit != null && !out.contains(hit)) out.add(hit);
  }
  return out;
}
