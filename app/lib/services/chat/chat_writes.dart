/// 对话助手的**写操作**（P3）：提议、以及"用户点确认之后"才发生的执行。
///
/// ## 这一层的核心纪律：助手自己**没有**写的能力
///
/// P2 我们让工具"按构造只读"—— 每个工具只调数据层里本身不写库的方法。
/// P3 要能改题库，那条纪律就不能靠"小心点别写"来维持了，于是换个方向：
///
/// > **工具只产出 [ChatWriteProposal]（一份"将要发生什么"的说明），
/// > 真正的写只发生在 [ChatWriteExecutor.apply]，而它只被界面上那个
/// > 「确认」按钮调用。**
///
/// 也就是说模型能做的极限是"把改动整理好摆到用户面前"。它没有
/// 绕开确认的路径 —— 不是"我们约定它不该绕"，是**代码里就没有那条路**。
///
/// 为什么值得这么设计：模型会自己决定调什么、传什么参数。一次"顺手写一下"
/// 在界面上**没有任何提示** —— 用户看到的是聊天记录里一句"好了，我已经
/// 帮你改好了"，而数据库里到底改了什么没人知道。写操作必须**先摆出来**。
///
/// ## 为什么提案是"一个类 + payload 字典"而不是一堆子类
///
/// 提案要能落盘（用户可能翻回三天前那段对话），所以必须可序列化。
/// sealed class 的子类做 JSON 往返要写一堆判别与工厂，而收益（执行器里的
/// 类型收窄）在这里并不划算：payload 是**我们自己**写进去的（不是模型给的），
/// 键名与类型都在本文件里定义，执行器是唯一的解读者。
/// 于是取一个折中：结构固定在一个类上，[ChatWriteProposal.kind] 做判别，
/// payload 的键在下面每个 `_exec` 方法里就地说明。
///
/// ## 卡片的"显示"与"执行"是两份数据，这是刻意的
///
/// [ChatWriteProposal.fields] 是**给人看的**（长文本截断、错因翻成中文名），
/// [ChatWriteProposal.payload] 是**用来执行的**（完整、结构化）。
/// 合成一份的话，"界面上显示得清楚"和"执行时不丢内容"会互相牵制 ——
/// 最后必然有一边妥协，而妥协的方式往往是**静默写入用户没看全的内容**。
library;

import 'dart:convert';

import '../../data/error_causes.dart';
import '../../data/markdown/problem_markdown.dart';
import '../../domain/knowledge/knowledge_point.dart';
import '../../domain/paper/paper_models.dart';
import '../../domain/problem_draft.dart';
import '../library/problem_service.dart';
import '../paper/paper_composer.dart';
import '../paper/paper_repository.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 种类
// ─────────────────────────────────────────────────────────────────────────────

/// 新增一道题。
const String kWriteCreateProblem = 'create_problem';

/// 修改一道题（只改传上来的字段）。
const String kWriteUpdateProblem = 'update_problem';

/// 删除一道题。
const String kWriteDeleteProblem = 'delete_problem';

/// 组一份卷并保存到历史。
const String kWriteComposePaper = 'compose_paper';

/// 承认的写操作种类。**不在这个集合里的 kind 一律拒绝执行** ——
/// 盘上的旧记录被改坏时，宁可什么都不做，也不要拿一个半懂的 kind 去写库。
const Set<String> kWriteKinds = {
  kWriteCreateProblem,
  kWriteUpdateProblem,
  kWriteDeleteProblem,
  kWriteComposePaper,
};

// ─────────────────────────────────────────────────────────────────────────────
// 提案
// ─────────────────────────────────────────────────────────────────────────────

/// 卡片上的一行"将要发生什么"。
class WriteField {
  final String label;

  /// 执行完之后的值。
  final String value;

  /// 执行之前的取值。非 null 时卡片上显示成 `before → value`
  /// （修改类提案的核心信息就是这个箭头）。
  final String? before;

  const WriteField(this.label, this.value, {this.before});

  Map<String, dynamic> toJson() => {
        'label': label,
        'value': value,
        if (before != null) 'before': before,
      };

  static WriteField fromJson(Map<dynamic, dynamic> j) => WriteField(
        j['label']?.toString() ?? '',
        j['value']?.toString() ?? '',
        before: j['before']?.toString(),
      );
}

/// 一次"待确认的写操作"。
///
/// 它是**不可变的**：用户处置完之后我们不修改它，而是把结论记在旁边
/// （见 `ToolTraceItem.decision`）—— 提案本身要原样留着，
/// 否则"我当初确认的是什么"就无从查证了。
class ChatWriteProposal {
  /// 提案 id。用于界面上的"正在执行哪个"与按 id 定位。
  final String id;

  /// 见 [kWriteKinds]。
  final String kind;

  /// 卡片标题，如「新增题目」。
  final String title;

  /// 一句话说明，如「把这道题存进错题本」。
  final String summary;

  /// 是否**不可逆**（目前只有删题）。界面据此换配色与按钮文案。
  final bool destructive;

  /// 逐行列出将要发生什么。给人看，长文本已截断。
  final List<WriteField> fields;

  /// 执行用的结构化数据。键名按 [kind] 各自约定，见执行器里的 `_exec*`。
  final Map<String, dynamic> payload;

  /// 要在卡片上额外提醒的一句话。null 表示没什么特别要说的。
  ///
  /// 目前用于两种情况：**这题已经录过（确认后将覆盖）**、
  /// **没有主考点（保存后会被标为待复核）**。两条都属于
  /// "用户不知道就会做错决定"的信息。
  final String? warning;

  const ChatWriteProposal({
    required this.id,
    required this.kind,
    required this.title,
    required this.summary,
    this.destructive = false,
    this.fields = const [],
    this.payload = const {},
    this.warning,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'title': title,
        'summary': summary,
        if (destructive) 'destructive': true,
        if (fields.isNotEmpty) 'fields': [for (final f in fields) f.toJson()],
        if (payload.isNotEmpty) 'payload': payload,
        if (warning != null) 'warning': warning,
      };

  /// 反序列化。**坏数据返回 null**，由调用方丢掉这一条。
  ///
  /// 与 `ToolTraceItem.fromJson` 的宽厚不同，这里必须严格：一条认不出来的
  /// 提案如果被拼成一个"空提案"，界面上就会出现一张**看起来能点、
  /// 实际什么也不会发生**的确认卡片。宁可什么都不显示。
  static ChatWriteProposal? fromJson(Map<dynamic, dynamic> j) {
    final kind = j['kind']?.toString() ?? '';
    final id = j['id']?.toString() ?? '';
    if (id.isEmpty || !kWriteKinds.contains(kind)) return null;

    final rawFields = j['fields'];
    final rawPayload = j['payload'];

    return ChatWriteProposal(
      id: id,
      kind: kind,
      title: j['title']?.toString() ?? kind,
      summary: j['summary']?.toString() ?? '',
      destructive: j['destructive'] == true,
      fields: [
        if (rawFields is List)
          for (final f in rawFields)
            if (f is Map) WriteField.fromJson(f),
      ],
      payload: rawPayload is Map
          ? {for (final e in rawPayload.entries) e.key.toString(): e.value}
          : const {},
      warning: j['warning']?.toString(),
    );
  }

  /// 生成一个提案 id。
  ///
  /// 断言唯一性靠时间戳（微秒）。加前缀是为了在日志/盘上能一眼看出是哪种。
  static String newId(String kind, {DateTime? now}) =>
      '$kind-${(now ?? DateTime.now()).microsecondsSinceEpoch}';
}

/// 一次写操作执行后的结果。
class WriteOutcome {
  final bool ok;

  /// 给用户的一句结论。失败时要说清**为什么**没成。
  final String message;

  const WriteOutcome(this.ok, this.message);

  static WriteOutcome failure(String message) => WriteOutcome(false, message);

  @override
  String toString() => 'WriteOutcome(ok=$ok, $message)';
}

// ─────────────────────────────────────────────────────────────────────────────
// 执行器
// ─────────────────────────────────────────────────────────────────────────────

/// 依赖加载器。与工具层同一条纪律：**按需取**，不在构造时准备好。
typedef ProblemServiceLoader = Future<ProblemService> Function();
typedef PaperRepositoryLoader = Future<PaperRepository> Function();
typedef WriteCauseLoader = Future<ErrorCauseCatalog?> Function();

/// 把提案变成真正的改动。
///
/// ## 唯一被允许写库的地方
///
/// 上层只有界面上的「确认」按钮会调它。模型碰不到它 ——
/// 写工具拿到的是提案构造能力，不是这个对象。
///
/// ## 执行前必须**重新校验**
///
/// 提案可能已经在盘上躺了几天（用户翻旧对话），这期间题库会变。
/// 所以每一条路径都先确认"要改的东西还在、要用的模板还在"，
/// 不在就如实失败，而不是拿着一份过期的参照去写。
class ChatWriteExecutor {
  final ProblemServiceLoader loadService;

  /// 本体。**允许返回 null**：没有本体时跳过"考点 id 是否存在"的校验，
  /// 而不是让整次写入失败（见 `ProblemDraft.validate`）。
  final Future<KnowledgeBase?> Function() loadKnowledge;

  final PaperRepositoryLoader loadPaper;

  /// 错因词表（用于把 `calc` 显示成"计算粗心"）。可选。
  final WriteCauseLoader? loadCauses;

  final DateTime Function() _now;

  ChatWriteExecutor({
    required this.loadService,
    required this.loadKnowledge,
    required this.loadPaper,
    this.loadCauses,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// 执行一个提案。
  ///
  /// **不往外抛异常**：抛出去的结果是界面上那张卡片停在"正在执行"，
  /// 用户永远等不到结论。任何异常都转成 [WriteOutcome.failure]，
  /// 并且把异常文本带进去 —— 那是排查的唯一线索。
  Future<WriteOutcome> apply(ChatWriteProposal p) async {
    if (!kWriteKinds.contains(p.kind)) {
      return WriteOutcome.failure('认不出这个操作（${p.kind}），没有改动任何数据');
    }
    try {
      switch (p.kind) {
        case kWriteCreateProblem:
          return await _execCreate(p);
        case kWriteUpdateProblem:
          return await _execUpdate(p);
        case kWriteDeleteProblem:
          return await _execDelete(p);
        case kWriteComposePaper:
          return await _execCompose(p);
      }
    } catch (e) {
      return WriteOutcome.failure('执行失败：$e');
    }
    // switch 覆盖了全部 kind，走到这里说明 kWriteKinds 与上面不同步。
    return WriteOutcome.failure('这个操作还没有实现（${p.kind}）');
  }

  // ───────────────────────────────────────────────────────────────────────
  // 新增题目
  // ───────────────────────────────────────────────────────────────────────
  //
  // payload:
  //   target_id      String?  非空 ⇒ 覆盖这道已有的题（沿用它的 id，
  //                           于是它的复习进度不会被清零）
  //   stem           String   题干（Markdown + LaTeX）
  //   qtype          String   'choice' / 'fill' / 'solve' / 'proof'
  //   difficulty     int      1 / 2 / 3
  //   options        List<String>
  //   answer         String?
  //   solution       String?
  //   note           String?
  //   source         String?
  //   source_type    String   'real_exam' / 'mock' / 'textbook' / 'self_made' / 'unknown'
  //   source_year    int?
  //   kp_id          String?  主考点
  //   error_causes   List<String>
  //   tags           List<String>

  Future<WriteOutcome> _execCreate(ChatWriteProposal p) async {
    final d = p.payload;
    final stem = _s(d['stem']);
    if (stem.isEmpty) {
      return WriteOutcome.failure('题干是空的，这道题不会被保存');
    }

    final targetId = _s(d['target_id']);
    final draft = ProblemDraft(
      // 覆盖已有题目时**必须**带着它的 id：`ProblemService.save` 会因此
      // 沿用这个 id，而不是按指纹新生成一个 —— 否则同一道题会出现两个
      // 文件，而错题次数与 FSRS 进度是挂在 id 上的，等于进度凭空消失。
      id: targetId.isEmpty ? null : targetId,
      stem: stem,
      qtype: QuestionType.fromId(_s(d['qtype'])),
      difficulty: _difficulty(d['difficulty']),
      options: _strings(d['options']),
      answer: _s(d['answer']),
      solution: _s(d['solution']),
      note: _s(d['note']),
      source: _s(d['source']),
      sourceType: SourceType.fromId(_s(d['source_type'])),
      sourceYear: _int(d['source_year']),
      primaryKpId: _s(d['kp_id']),
      errorCauses: _strings(d['error_causes']),
      tags: _strings(d['tags']),
    );

    final kb = await loadKnowledge();
    final blocking = draft
        .validate(knowledge: kb)
        .where((i) => i.level == DraftIssueLevel.blocking)
        .toList();
    if (blocking.isNotEmpty) {
      // 走到这里说明"提议时校验过、执行时又不合规了"——只可能是
      // 本体变了（比如主考点被删）。照实说，别硬写进去。
      return WriteOutcome.failure(
        '这道题现在还不能保存：${blocking.map((i) => i.message).join('；')}',
      );
    }

    final service = await loadService();
    final out = await service.save(
      draft,
      overwriteExisting: targetId.isNotEmpty,
    );
    if (!out.ok || out.problem == null) {
      return WriteOutcome.failure(out.error ?? '保存失败（没有返回原因）');
    }

    final id = out.problem!.id;
    final warn = out.error == null ? '' : '（${out.error}）';
    return WriteOutcome(
      true,
      out.overwrote
          ? '已更新「$id」：题干相同的题已存在，按你的确认沿用了它，'
              '复习进度没有丢$warn'
          : '已保存为「$id」，可以在「错题本」里找到它$warn',
    );
  }

  // ───────────────────────────────────────────────────────────────────────
  // 修改题目
  // ───────────────────────────────────────────────────────────────────────
  //
  // payload:
  //   id       String
  //   changes  Map<String, dynamic>  只含**要改的键**，其余一律不碰。
  //
  // changes 的键与取值：
  //   stem            String   不能为空
  //   answer/solution/note/source   String?  空串表示**清空**
  //   difficulty      int
  //   qtype           String
  //   options         List<String>
  //   kp_id           String?  空串表示取消主考点
  //   error_causes    List<String>
  //   tags            List<String>

  Future<WriteOutcome> _execUpdate(ChatWriteProposal p) async {
    final id = _s(p.payload['id']);
    final changes = p.payload['changes'];
    if (id.isEmpty) return WriteOutcome.failure('没给题目 id，没有改动任何数据');
    if (changes is! Map || changes.isEmpty) {
      return WriteOutcome.failure('没有给出要修改的字段，没有改动任何数据');
    }

    final service = await loadService();
    final read = await service.store.read(id);
    final existing = read.problem;
    if (existing == null) {
      // 提案在盘上躺过一段时间，这道题可能已经被删了。
      return WriteOutcome.failure(
        '这道题已经不在了（${read.error ?? '读不到内容'}），没有改动任何数据',
      );
    }

    final draft = ProblemDraft.fromProblem(existing);
    for (final e in changes.entries) {
      switch (e.key) {
        case 'stem':
          draft.stem = _s(e.value);
        case 'answer':
          draft.answer = _s(e.value);
        case 'solution':
          draft.solution = _s(e.value);
        case 'note':
          draft.note = _s(e.value);
        case 'source':
          draft.source = _s(e.value);
        case 'difficulty':
          draft.difficulty = _difficulty(e.value);
        case 'qtype':
          draft.qtype = QuestionType.fromId(_s(e.value));
        case 'options':
          draft.options = _strings(e.value);
        case 'kp_id':
          draft.primaryKpId = _s(e.value);
        case 'error_causes':
          draft.errorCauses = _strings(e.value);
        case 'tags':
          draft.tags = _strings(e.value);
        default:
          // 不认识的键**跳过**而不是报错：多认一个键的代价是静默写错内容，
          // 跳过它的代价只是这次改动少了一项（用户看得出来）。
          continue;
      }
    }

    final kb = await loadKnowledge();
    final blocking = draft
        .validate(knowledge: kb)
        .where((i) => i.level == DraftIssueLevel.blocking)
        .toList();
    if (blocking.isNotEmpty) {
      return WriteOutcome.failure(
        '改完之后还是不合规：${blocking.map((i) => i.message).join('；')}，'
        '没有改动任何数据',
      );
    }

    // `draft.id` 非空 ⇒ `save` 走"编辑已有题目"那条路：直接覆盖，
    // 且**不会**碰 user_problem_state（错题次数与复习进度）。
    final out = await service.save(draft);
    if (!out.ok) return WriteOutcome.failure(out.error ?? '更新失败（没有返回原因）');

    final n = changes.length;
    return WriteOutcome(true, '已更新「$id」的 $n 处内容（复习进度没有动）');
  }

  // ───────────────────────────────────────────────────────────────────────
  // 删除题目
  // ───────────────────────────────────────────────────────────────────────
  //
  // payload: id String

  Future<WriteOutcome> _execDelete(ChatWriteProposal p) async {
    final id = _s(p.payload['id']);
    if (id.isEmpty) return WriteOutcome.failure('没给题目 id，没有删任何东西');

    final service = await loadService();
    final read = await service.store.read(id);
    if (read.problem == null) {
      return WriteOutcome.failure('这道题已经不在了，没有删任何东西');
    }

    final fileGone = await service.delete(id);
    if (!fileGone) {
      // ⚠️ 半完成的删除必须说清楚。索引与状态行都已经删了，但 Markdown
      // 文件还在 —— 而 Markdown 是内容的**事实源**，下一次重建索引
      // 它会带着这道题一起回来。说成"已删除"就是骗人。
      return WriteOutcome.failure(
        '已从索引、复习计划里移除「$id」，但题目文件删不掉（可能被别的程序占用）。'
        '下次重建索引它会重新出现 —— 请关掉占用它的程序后手动删除那个文件。',
      );
    }
    return WriteOutcome(true, '已删除「$id」：题目文件、复习进度与错因记录都清掉了');
  }

  // ───────────────────────────────────────────────────────────────────────
  // 组卷
  // ───────────────────────────────────────────────────────────────────────
  //
  // payload:
  //   subject              String  'math1' / 'math2' / 'math3'
  //   template_id          String
  //   title                String?
  //   difficulty_tolerance int     0 / 1 / 2
  //   prefer_wrong         bool
  //   prefer_weak          bool
  //   diversify            bool
  //
  // ## 这里为什么"重新组一次"而不是把预览的结果存下来
  //
  // 组卷是**纯函数**（同样的题库 + 同样的参数 ⇒ 同一份卷子），所以
  // 重组的开销只是几毫秒的算分，不碰网络。存预览结果反而要连题目摘要、
  // 题位、降级说明一起序列化进提案里（几十 KB），而且那份数据一旦
  // 与实际题库脱节，写出来的就是一份**基于过期快照**的卷子。
  // 重组只会得到"按现在的题库最合适的那一份"——这正是用户想要的。

  Future<WriteOutcome> _execCompose(ChatWriteProposal p) async {
    final d = p.payload;
    final subject = _s(d['subject']).isEmpty ? 'math1' : _s(d['subject']);
    final templateId = _s(d['template_id']);
    if (templateId.isEmpty) {
      return WriteOutcome.failure('没给组卷模板，没有生成任何卷子');
    }

    final repo = await loadPaper();
    final loaded = await repo.templates(subject: subject);
    final template = loaded[templateId];
    if (template == null) {
      return WriteOutcome.failure(
        loaded.error ?? '这个科目没有「$templateId」模板，没有生成任何卷子',
      );
    }

    final pool = await repo.candidates(
      subject: subject,
      // 与组卷页同一条规则：错题专练只从做错过的题里抽。
      onlyWrong: templateId == 'wrong_only',
    );
    final result = const PaperComposer().compose(
      request: PaperRequest(
        template: template,
        subject: subject,
        difficultyTolerance: _tolerance(d['difficulty_tolerance']),
        preferWrong: d['prefer_wrong'] != false,
        preferWeak: d['prefer_weak'] != false,
        diversify: d['diversify'] != false,
        drillCauseIds: repo.drillCauseIds,
      ),
      pool: pool,
    );

    if (result.items.isEmpty) {
      return WriteOutcome.failure(
        '按这个条件一道题都选不出来（题库里缺少符合条件的题目），没有生成卷子',
      );
    }

    final title = _s(d['title']);
    await repo.save(
      result,
      title: title.isEmpty ? null : title,
      now: _now(),
    );
    final gap = result.emptySeats.isEmpty
        ? ''
        : '；${result.emptySeats.length} 个题位没题可填';
    return WriteOutcome(
      true,
      '已生成并保存一份卷子（${result.items.length} 题 · ${result.totalScore} 分'
      '$gap）。到「组卷」页的历史里能看到它',
    );
  }

  // ───────────────────────────────────────────────────────────────────────
  // payload 取值：写进去的是我们自己，但仍当成不可信输入处理
  // ───────────────────────────────────────────────────────────────────────
  //
  // 为什么还要夹紧：payload 会在 JSON 里往返一次（落盘 → 读回），
  // 而"落盘的东西一定是自己写的"这个前提，在盘被外力改过时不成立。

  static String _s(Object? v) {
    if (v == null) return '';
    return (v is String ? v : v.toString()).trim();
  }

  static int? _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.round();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  static int _difficulty(Object? v) => (_int(v) ?? 2).clamp(1, 3).toInt();

  static int _tolerance(Object? v) => (_int(v) ?? 1).clamp(0, 2).toInt();

  static List<String> _strings(Object? v) {
    if (v is List) {
      return [
        for (final e in v)
          if (_s(e).isNotEmpty) _s(e),
      ];
    }
    // 单个字符串也收：模型偶尔把数组写成 `"calc"` 而不是 `["calc"]`。
    return _s(v).isEmpty ? const [] : [_s(v)];
  }
}

/// 把错因 id 列表翻成人看得懂的名字。
///
/// 词表拿不到时**原样显示 id**，不显示空串 —— 确认卡片上少一项，
/// 用户就没法判断自己要保存的是什么（见 `ErrorCauseCatalog.nameOf`）。
String writeCauseLabel(ErrorCauseCatalog? catalog, List<String> ids) {
  if (ids.isEmpty) return '（未选）';
  if (catalog == null) return ids.join('、');
  return ids.map(catalog.nameOf).join('、');
}

/// 长文本的卡片预览。
///
/// 与工具结果里的截断同一个理由，但**多给一个字数和"已省略"**：
/// 用户是在确认"要不要把这段写进去"，只看到开头却不被告知后面还有，
/// 会以为要写的就是这么点。
String writePreview(String s, int max) {
  final t = s.trim();
  if (t.isEmpty) return '（空）';
  if (t.length <= max) return t;
  return '${t.substring(0, max)}…（共 ${t.length} 字，此处省略）';
}

/// 把一份提案里"与人无关"的那部分压成一行摘要，供列表/日志使用。
String writeProposalDigest(ChatWriteProposal p) =>
    jsonEncode({'kind': p.kind, 'summary': p.summary});
