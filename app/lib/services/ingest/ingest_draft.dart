/// 批量导入的**进度草稿**（T49）。
///
/// ## 它值这笔代码的原因是"重新解析要重新花钱"
///
/// 批量导入是 BYOK 模式下**单次花费最大**的操作：一册真题集上百个来源，
/// 每个来源一次视觉模型调用。而解析结果原先只活在页面的内存里 ——
/// 关掉窗口、切走再回来、程序崩一次，全部结果蒸发，重来一遍就是再付一次钱。
///
/// T39（复习会话不持久化）不做，是因为重开的成本只是"重新抽一轮题"；
/// 这条不一样，**成本是钱**。
///
/// ## 为什么落成题库目录下的一个 JSON 文件，而不是进 SQLite
///
/// 项目的一贯约定是「Markdown 是事实源，SQLite 只存用户状态与派生索引，
/// 整删不丢数据」。而这份草稿是**未完成的工作**，两者都不算：
/// - 它不是事实 —— 没入库的题还不是用户的题
/// - 它也不是长期状态 —— 用完即弃
///
/// 放在题库目录里，用户把整个题库删掉时它会一起消失，不留孤儿行；
/// 也不会因为一次导入草稿写坏而污染索引库。
///
/// ## 恢复时的两条纪律
///
/// 1. **已完成的不再重跑** —— 这正是这个文件存在的全部意义
/// 2. **`running` 归一成 `pending`** —— 崩溃时停在 `running` 的那个来源
///    *没有拿到结果*，它就是没完成。带着 `running` 落盘会让界面永远
///    显示"解析中"，而按"已完成"跳过它则会静默丢掉一个来源的题
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../data/markdown/problem_store.dart';
import '../llm/llm_client.dart';
import 'ingest_models.dart';

/// 草稿文件名（题库根目录下）。
const String kIngestDraftFileName = 'ingest_draft.json';

/// 草稿的格式版本。
///
/// 读到不认识的版本号时**不猜**：宁可让用户重新解析一轮，
/// 也不要把一个字段对不上的草稿当成好数据用 —— 后者会以
/// "题少了 / 答案串到别的题上"的形式出现，很难查。
const int kIngestDraftVersion = 1;

/// 一次批量导入的进度快照。
class IngestDraft {
  /// 与来源清单一一对应。
  final List<IngestItem> items;

  /// 已经累计花掉的用量。
  final LlmUsage usage;

  /// 跑这批用的模型名（换模型后旧结果仍然可用，只是留个痕）。
  final String model;

  final DateTime savedAt;

  IngestDraft({
    required this.items,
    this.usage = const LlmUsage(),
    this.model = '',
    DateTime? savedAt,
  }) : savedAt = savedAt ?? DateTime.now();

  int get total => items.length;

  /// 已解析成功的来源数。
  int get parsed => items.where((i) => i.isDone).length;

  /// 上次失败的来源数（恢复后会重试）。
  int get failed =>
      items.where((i) => i.status == IngestStatus.failed).length;

  /// 还没**拿到结果**的来源数 —— 也就是恢复后还会花钱的那部分。
  ///
  /// 口径是 `!isDone` 而不是 `!isFinished`：失败与跳过的来源都算
  /// "还会再跑一次"。用后者会把失败项算成"已完成"，
  /// 而它恰恰是最该重试的那一类。
  int get remaining => items.where((i) => !i.isDone).length;

  int get problemCount => items.fold(0, (n, i) => n + i.problems.length);

  /// 每个来源都解析成功了（失败的还没补上）。
  bool get isAllParsed => items.isNotEmpty && remaining == 0;

  /// 值不值得留着。
  ///
  /// 一个来源都没跑完的草稿没有任何恢复价值 —— 留着只会在下次打开时
  /// 弹一条"上次没做完"，而点进去和重新开始完全一样。
  bool get isWorthKeeping => parsed > 0 || failed > 0;

  /// 来源清单（恢复时要用它把页面状态补回来）。
  List<IngestSource> get sources =>
      [for (final i in items) i.source];

  /// 这批来源是否就是 [other] 那批。
  ///
  /// 用于"用户重新选了一遍同一个文件夹，又点了开始解析"——
  /// 那种情况下应当自动接上，而不是再花一遍钱。
  /// 按路径**集合**比较，不比较顺序：选文件夹的返回顺序不稳定。
  bool matchesSources(List<IngestSource> other) {
    if (other.length != items.length) return false;
    final mine = {for (final i in items) i.source.path};
    return other.every((s) => mine.contains(s.path));
  }

  /// 可读的一句话摘要（横幅与状态栏共用）。
  String get summary {
    final parts = <String>[
      '$total 个来源',
      '已解析 $parsed',
      if (failed > 0) '失败 $failed',
      '共 $problemCount 题',
    ];
    return parts.join(' · ');
  }

  Map<String, dynamic> toJson() => {
        'version': kIngestDraftVersion,
        'saved_at': savedAt.toIso8601String(),
        if (model.isNotEmpty) 'model': model,
        'usage': usage.toJson(),
        'items': [for (final i in items) i.toJson()],
      };

  /// 反序列化。结构不对时抛 [FormatException]，由 [IngestDraftStore] 兜住。
  factory IngestDraft.fromJson(Map<String, dynamic> j) {
    final v = (j['version'] as num?)?.toInt();
    if (v != kIngestDraftVersion) {
      throw FormatException('草稿版本是 $v，本版本只认 $kIngestDraftVersion');
    }
    final rawItems = j['items'];
    if (rawItems is! List) throw const FormatException('items 不是列表');

    return IngestDraft(
      items: [
        for (final i in rawItems)
          IngestItem.fromJson((i as Map).cast<String, dynamic>()),
      ],
      usage: j['usage'] is Map
          ? LlmUsage.fromJson((j['usage'] as Map).cast<String, dynamic>())
          : const LlmUsage(),
      model: j['model']?.toString() ?? '',
      savedAt:
          DateTime.tryParse(j['saved_at']?.toString() ?? '') ?? DateTime.now(),
    );
  }
}

/// 读盘结果。
///
/// 「没有草稿」与「草稿读不出来」必须分得开：前者是正常状态，
/// 后者要让用户知道（他可能刚丢了一批花过钱的解析结果，
/// 而"什么都不显示"会让这件事永远没人发现）。
class IngestDraftLoad {
  final IngestDraft? draft;
  final String? error;

  const IngestDraftLoad(this.draft, [this.error]);
}

/// 草稿的读写。
class IngestDraftStore {
  final File file;

  const IngestDraftStore(this.file);

  /// 题库根目录下的默认位置。
  static IngestDraftStore at(Directory libraryRoot) =>
      IngestDraftStore(File(p.join(libraryRoot.path, kIngestDraftFileName)));

  /// 原子写留下的临时文件。
  File get _tmp => File('${file.path}.tmp');

  /// 读取。任何异常都退化成"没有草稿 + 一句原因"，绝不抛。
  ///
  /// ## 为什么还要看 `.tmp`
  ///
  /// `ProblemStore.atomicWriteString` 在 Windows 上是"写 tmp → 删目标 →
  /// 改名"（见 T51）。删掉与改名之间崩溃，目标文件就没了，而**完整的
  /// 新内容正躺在 `.tmp` 里**。对题目正文（Markdown）来说那是个小概率
  /// 取舍，但对草稿来说"多读一个文件"就能救回一整批花了钱的结果 ——
  /// 这个便宜值得占。
  Future<IngestDraftLoad> load() async {
    final errors = <String>[];

    for (final f in [file, _tmp]) {
      if (!f.existsSync()) continue;
      try {
        final raw = await f.readAsString();
        if (raw.trim().isEmpty) {
          errors.add('${p.basename(f.path)} 是空文件');
          continue;
        }
        final j = jsonDecode(raw);
        if (j is! Map) {
          errors.add('${p.basename(f.path)} 不是 JSON 对象');
          continue;
        }
        final draft = IngestDraft.fromJson(j.cast<String, dynamic>());
        if (f.path != file.path) {
          // 从 .tmp 里救回来的，顺手把它补成正式文件
          await save(draft);
        }
        return IngestDraftLoad(draft, errors.isEmpty ? null : errors.join('；'));
      } catch (e) {
        errors.add('${p.basename(f.path)}：$e');
      }
    }

    // 目标文件不存在时，errors 里可能只有 .tmp 的抱怨；没有草稿就是没有草稿
    if (errors.isEmpty) return const IngestDraftLoad(null);
    return IngestDraftLoad(
      null,
      '上次的导入进度读不出来（${errors.join('；')}），已忽略。'
      '重新解析要重新花钱，所以这里如实告诉你。',
    );
  }

  /// 写入。返回错误文本（成功为 null）—— 调用方要能把失败显示出来。
  Future<String?> save(IngestDraft draft) async {
    try {
      await ProblemStore.atomicWriteString(
          file, const JsonEncoder.withIndent(' ').convert(draft.toJson()));
      return null;
    } catch (e) {
      return '$e';
    }
  }

  /// 删除草稿（连 `.tmp` 一起，否则下次会从它那儿"救"回来一份旧数据）。
  Future<void> clear() async {
    for (final f in [file, _tmp]) {
      try {
        if (f.existsSync()) await f.delete();
      } catch (_) {
        // 删不掉不是用户能处理的事，而且下次覆盖写会顶掉它
      }
    }
  }
}
