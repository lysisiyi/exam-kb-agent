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
import '../../data/index/index_builder.dart';
import '../../data/markdown/problem_markdown.dart';
import '../../data/markdown/problem_store.dart';
import '../../domain/fsrs/fsrs_scheduler.dart';
import '../../domain/knowledge/knowledge_point.dart';
import '../llm/llm_client.dart';
import '../profile/mastery_service.dart';
import '../review/review_repository.dart';

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

  const ToolOutcome({
    required this.content,
    this.ok = true,
    this.summary = '',
  });

  static ToolOutcome failure(String message, {String? summary}) => ToolOutcome(
        content: jsonEncode({'error': message}),
        ok: false,
        summary: summary ?? message,
      );
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

  const ToolTraceItem({
    required this.name,
    this.argsPreview = '',
    this.ok = true,
    this.summary = '',
    this.round = 1,
  });

  /// 中文短名，界面上用。
  String get label => toolLabel(name);

  Map<String, dynamic> toJson() => {
        'name': name,
        if (argsPreview.isNotEmpty) 'args': argsPreview,
        'ok': ok,
        if (summary.isNotEmpty) 'summary': summary,
        'round': round,
      };

  /// 反序列化。**坏数据退化成"未知的一次调用"，不抛异常** ——
  /// 这是一条历史备注，不值得为它让整个会话打不开。
  static ToolTraceItem fromJson(Map<dynamic, dynamic> j) => ToolTraceItem(
        name: j['name']?.toString() ?? '',
        argsPreview: j['args']?.toString() ?? '',
        ok: j['ok'] != false,
        summary: j['summary']?.toString() ?? '',
        round: (j['round'] as num?)?.toInt() ?? 1,
      );
}

/// 工具名的中文短名。界面上不显示 `query_wrong_problems` 这种东西。
const Map<String, String> kToolLabels = {
  'query_wrong_problems': '查错题本',
  'get_problem': '读题目',
  'query_knowledge_points': '查知识点',
  'query_profile': '查学习画像',
  'query_due_reviews': '查待复习',
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
