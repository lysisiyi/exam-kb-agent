/// 知识库页（V3 严格按参考图 `docs/design/ui/ui_knowledge.png` 重构）。
///
/// ## 版式（与参考图逐块对应）
///
/// ```
/// [知识库 · 学科chip · 骨架/已填 chips · AI梳理/导入题目/新建学科]   ← 页头
/// [▸ 下一步建议：xx —— 尚未填内容（骨架）   去看]                    ← 建议横幅
/// ┌── 左：知识树（拖拽整理，id 不变）──┬── 右：节点详情 ──────────┐
/// │ ⋮⋮ ● 01 绪论 已填                │ 面包屑 · md 路径           │
/// │   ⋮⋮ ● 01-1 什么是数据结构 已填  │ 标题 [已填] ★★  [AI 补全] │
/// │   ● 02 线性表 ★★ 已填            │ 别名 chips / 前置 chips     │
/// │ ...                              │ 定义 / 公式 / 陷阱 / 草稿   │
/// │                                  │ 本节点题目（图像题面）      │
/// └──────────────────────────────────┴───────────────────────────┘
/// ```
///
/// 旧版是「图谱/大纲」双模式切换 + 叶子行内联展开详情 —— 与参考图的
/// "左树右详情"两栏结构不符，已整体替换（图谱视图代码保留但不再挂载）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../domain/knowledge/knowledge_point.dart';
import '../../services/profile/mastery_service.dart';
import 'knowledge_leaf_detail.dart';
import 'knowledge_node_style.dart';
import 'knowledge_outline_view.dart';
import 'knowledge_sizes.dart';

class KnowledgePage extends ConsumerStatefulWidget {
  const KnowledgePage({super.key});

  @override
  ConsumerState<KnowledgePage> createState() => _KnowledgePageState();
}

class _KnowledgePageState extends ConsumerState<KnowledgePage> {
  /// 右栏当前展示的节点。null = 还没选（默认落到第一个骨架叶子）。
  String? _selectedId;

  @override
  Widget build(BuildContext context) {
    final kbAsync = ref.watch(knowledgeBaseProvider);
    final mastery = ref.watch(masteryReportProvider).valueOrNull;
    final masteryByKpId = <String, KpMastery>{
      for (final m in mastery?.kps ?? const <KpMastery>[]) m.kpId: m,
    };

    return kbAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, st) => _ErrorView(error: e),
      data: (kb) {
        final selected = kb.byId[_selectedId] ?? _defaultPick(kb);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _EditorHeader(kb: kb),
            _NextStepBanner(
              kb: kb,
              onGo: (node) => setState(() => _selectedId = node.id),
            ),
            const Divider(height: 1, color: AppColors.line),
            Expanded(
              child: LayoutBuilder(builder: (context, cons) {
                // 参考图是 430 定宽左树；窄窗（<900）按 45% 收窄，
                // 否则右栏只剩几十像素、公式全在横滑。
                final treeWidth =
                    cons.maxWidth >= 900 ? 430.0 : cons.maxWidth * 0.45;
                return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 左：树（白卡，参考图左栏是独立卡片）
                  SizedBox(
                    width: treeWidth,
                    child: _PaneCard(
                    child: KnowledgeOutlineView(
                      kb: kb,
                      masteryByKpId: masteryByKpId,
                      selectedId: selected?.id,
                      onSelect: (n) => setState(() => _selectedId = n.id),
                      onCreateChild: (n) => _createChild(kb, n),
                      onRename: (n) => _rename(kb, n),
                      onDelete: (n) => _delete(kb, n),
                      onMoveNode: (child, parent) =>
                          _moveNode(kb, child, parent),
                    ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 右：详情（叶子 = 完整详情卡；分支 = 分支摘要）
                  Expanded(
                    child: _PaneCard(
                      child: selected == null
                          ? const Center(child: Text('从左边选一个知识点'))
                          : _NodeDetailPane(kb: kb, node: selected),
                    ),
                  ),
                ],
                );
              }),
            ),
          ],
        );
      },
    );
  }

  // ── K2 编辑动作（写 md 文件；id 永不变） ──────────────────────────────

  Future<String?> _askName(BuildContext context, String title,
      {String? initial}) async {
    final controller = TextEditingController(text: initial ?? '');
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('确定')),
        ],
      ),
    );
  }

  Future<void> _createChild(KnowledgeBase kb, KnowledgePoint parent) async {
    final name = await _askName(context, '在「${parent.name}」下新建节点');
    if (name == null || name.isEmpty || !mounted) return;
    try {
      final store = await ref.read(knowledgeMdStoreProvider.future);
      final f = store.createChildNode(kb.subject, parent.id, name);
      ref.invalidate(knowledgeBaseProvider);
      // 新建后不强制选中（下轮重建 KB 时按 id 找得到）；保持当前选择
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('已创建 ${f.path.split(RegExp(r'[\/]')).last}')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('创建失败：$e')));
      }
    }
  }

  Future<void> _rename(KnowledgeBase kb, KnowledgePoint node) async {
    final name = await _askName(context, '重命名「${node.name}」', initial: node.name);
    if (name == null || name.isEmpty || name == node.name || !mounted) return;
    final store = await ref.read(knowledgeMdStoreProvider.future);
    final file = store.fileOf(kb.subject, node.id);
    if (file == null) return;
    store.renameNode(file, name);
    ref.invalidate(knowledgeBaseProvider);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已改名为「$name」（id 不变）')));
    }
  }

  /// 拖拽整理：把 [child] 挂到 [newParent] 下（id 不变，文件移动）。
  Future<void> _moveNode(
      KnowledgeBase kb, KnowledgePoint child, KnowledgePoint newParent) async {
    final store = await ref.read(knowledgeMdStoreProvider.future);
    final file = store.fileOf(kb.subject, child.id);
    if (file == null) return;
    try {
      store.moveNode(file, newParent.id);
      ref.invalidate(knowledgeBaseProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('已把「${child.name}」移到「${newParent.name}」下（id 不变）')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('移动失败：$e')));
      }
    }
  }

  Future<void> _delete(KnowledgeBase kb, KnowledgePoint node) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除「${node.name}」？'),
        content: const Text('连同其子树一起删除，md 文件会从 knowledge/ 目录移除。此操作不可撤销。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final store = await ref.read(knowledgeMdStoreProvider.future);
    final file = store.fileOf(kb.subject, node.id);
    if (file == null) return;
    final removed = store.deleteNode(file, recursive: true);
    ref.invalidate(knowledgeBaseProvider);
    if (mounted) {
      setState(() => _selectedId = null);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('已删除（含子树共 $removed 个文件）')));
    }
  }

  /// 默认落点：树序里第一个没填定义的叶子（= 与"下一步建议"同源）；全填了用第一个叶子。
  KnowledgePoint? _defaultPick(KnowledgeBase kb) {
    final leaves = kb.leaves;
    if (leaves.isEmpty) return null;
    for (final l in leaves) {
      if ((l.definition ?? '').trim().isEmpty) return l;
    }
    return leaves.first;
  }
}

/// 两栏的通用白卡（参考图的左右面板）：白底 + 暖边 + 大圆角 + 轻阴影。
class _PaneCard extends StatelessWidget {
  final Widget child;
  const _PaneCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.rLg,
        border: Border.all(color: AppColors.line),
        boxShadow: AppShadows.s1,
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// 知识库切换器：学科 chip + 下拉（列出 knowledge/ 下全部库）。
class _KbSwitcher extends ConsumerWidget {
  final String currentName;
  const _KbSwitcher({required this.currentName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentId = ref.watch(currentKnowledgeBaseIdProvider);
    final bases = ref.watch(knowledgeBasesProvider).valueOrNull ?? const [];
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.primaryWeak,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        // 文本可省略：chip 处在可压缩的 Flexible 里时必须能收敛宽度
        Flexible(
          child: Text(currentName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: KnowledgeSizes.secondary,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primaryStrong)),
        ),
        const Icon(Icons.arrow_drop_down,
            size: 16, color: AppColors.primaryStrong),
      ]),
    );
    if (bases.length <= 1) return chip; // 只有一个库时不做假入口
    return PopupMenuButton<String>(
      tooltip: '切换知识库',
      onSelected: (id) =>
          ref.read(currentKnowledgeBaseIdProvider.notifier).state = id,
      itemBuilder: (_) => [
        for (final b in bases)
          CheckedPopupMenuItem(
            value: b.id,
            checked: b.id == currentId,
            child: Text(b.label, style: const TextStyle(fontSize: 13)),
          ),
      ],
      child: chip,
    );
  }
}

/// 页头：知识库 + 学科 chip + 状态 chips + 动作按钮（参考图第一行）。
class _EditorHeader extends StatelessWidget {
  final KnowledgeBase kb;
  const _EditorHeader({required this.kb});

  @override
  Widget build(BuildContext context) {
    final leaves = kb.leaves;
    final filled =
        leaves.where((l) => (l.definition ?? '').trim().isNotEmpty).length;
    final skeleton = leaves.length - filled;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Flexible(
                    child: Text('知识库',
                        style: AppTypography.pageTitle,
                        overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(width: 8),
                  // 知识库切换（多课程 → 多知识库）：点学科 chip 换一棵树。
                  // Flexible：学科名可长（"武忠祥高等数学基础班（金榜时代…）"），
                  // 窄栏（560）下让 chip 先压缩而不是顶穿标题行（9.2px 溢出）。
                  Flexible(child: _KbSwitcher(currentName: kb.subjectName)),
                ]),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 14,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _StatusChip(
                        text: '骨架 $skeleton',
                        color: AppColors.ink3,
                        hollow: true),
                    _StatusChip(
                        text: '已填 $filled',
                        color: AppColors.success,
                        hollow: false),
                    _Stat(label: '章节', value: '${kb.chapters.length}'),
                    _Stat(label: '知识点', value: '${leaves.length}'),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // 参考图右上三个动作。未接线的按钮点击后如实说明去向，
          // 不做"点了没反应"的假按钮。
          _HeaderAction(
            icon: Icons.cleaning_services_outlined,
            label: 'AI 梳理本章',
            onTap: () => _notYet(context, 'AI 梳理（重复/缺失检测）随 K3 上线'),
          ),
          const SizedBox(width: 8),
          _HeaderAction(
            icon: Icons.download_outlined,
            label: '导入题目',
            onTap: () {
              // 真动作：切到知识库宿主页的「图像录入」标签（索引 2）
              final controller = DefaultTabController.maybeOf(context);
              if (controller != null) {
                controller.animateTo(2);
              } else {
                _notYet(context, '入口在「知识库 › 图像录入」标签');
              }
            },
          ),
          const SizedBox(width: 8),
          _HeaderAction(
            icon: Icons.add,
            label: '新建学科（向导）',
            primary: true,
            onTap: () =>
                _notYet(context, '建库向导随 K2 上线（当前可手动建 knowledge/ 文件夹）'),
          ),
        ],
      ),
    );
  }

  void _notYet(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

class _HeaderAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;
  const _HeaderAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    return primary
        ? FilledButton.icon(
            onPressed: onTap,
            icon: Icon(icon, size: 16),
            label: Text(label, style: const TextStyle(fontSize: 12.5)),
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 34),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
          )
        : OutlinedButton.icon(
            onPressed: onTap,
            icon: Icon(icon, size: 16),
            label: Text(label, style: const TextStyle(fontSize: 12.5)),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.ink2,
              side: const BorderSide(color: AppColors.line),
              minimumSize: const Size(0, 34),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
          );
  }
}

/// 「下一步建议」横幅（参考图第二行）。诚实版：给出树序里第一个骨架叶子。
class _NextStepBanner extends StatelessWidget {
  final KnowledgeBase kb;
  final ValueChanged<KnowledgePoint> onGo;
  const _NextStepBanner({required this.kb, required this.onGo});

  @override
  Widget build(BuildContext context) {
    KnowledgePoint? suggestion;
    for (final l in kb.leaves) {
      if ((l.definition ?? '').trim().isEmpty) {
        suggestion = l;
        break;
      }
    }
    if (suggestion == null) return const SizedBox.shrink();
    final s = suggestion;
    final stars = starsOf(s.examWeight);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.rMd,
        border: Border(left: BorderSide(color: AppColors.primary, width: 4)),
      ),
      child: Row(children: [
        const Icon(Icons.play_arrow_rounded, size: 16, color: AppColors.primary),
        const SizedBox(width: 6),
        Flexible(
          child: Text.rich(
            TextSpan(children: [
              const TextSpan(
                  text: '下一步建议：',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              TextSpan(text: s.name),
              const TextSpan(text: ' —— 尚未填内容（骨架）'),
              if (stars.isNotEmpty)
                TextSpan(
                    text: ' · 优先级 $stars',
                    style: const TextStyle(color: AppColors.warningInk)),
            ]),
            style: const TextStyle(fontSize: 12.5, height: 1.6),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const Spacer(),
        FilledButton(
          onPressed: () => onGo(s),
          style: FilledButton.styleFrom(
              minimumSize: const Size(0, 30),
              padding: const EdgeInsets.symmetric(horizontal: 14)),
          child: const Text('去看', style: TextStyle(fontSize: 12)),
        ),
      ]),
    );
  }
}

/// 右栏：叶子 → 完整详情卡；分支 → 分支摘要（子节点清单，可继续下钻）。
class _NodeDetailPane extends StatelessWidget {
  final KnowledgeBase kb;
  final KnowledgePoint node;
  const _NodeDetailPane({required this.kb, required this.node});

  @override
  Widget build(BuildContext context) {
    if (node.isLeaf) {
      final crumb = detailBreadcrumb(kb, node.id);
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
        child: KnowledgeLeafDetail(
          key: ValueKey('detail-${node.id}'),
          leaf: node,
          sectionName: crumb.section,
          chapterName: crumb.chapter,
        ),
      );
    }
    final leaves = _leavesUnder(node);
    final filled =
        leaves.where((l) => (l.definition ?? '').trim().isNotEmpty).length;
    final children = kb.childrenOf[node.id] ?? const <KnowledgePoint>[];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
      children: [
        Text(node.name,
            style: const TextStyle(
                fontSize: KnowledgeSizes.heading,
                fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(
            '这一支共 ${leaves.length} 个考点 · 已填 $filled · 骨架 ${leaves.length - filled}',
            style: const TextStyle(
                fontSize: KnowledgeSizes.secondary, color: kSecondaryInk)),
        const SizedBox(height: 12),
        for (final c in children)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: AppRadius.rMd,
              border: Border.all(color: AppColors.line),
            ),
            child: ListTile(
              dense: true,
              leading: _StatusDot(
                  filled: (c.definition ?? '').trim().isNotEmpty || !c.isLeaf),
              title: Text(c.name,
                  style: const TextStyle(fontSize: KnowledgeSizes.body)),
              subtitle: c.isLeaf
                  ? null
                  : Text('${(kb.childrenOf[c.id] ?? const []).length} 个子节点',
                      style: const TextStyle(
                          fontSize: KnowledgeSizes.secondary,
                          color: kSecondaryInk)),
            ),
          ),
      ],
    );
  }

  List<KnowledgePoint> _leavesUnder(KnowledgePoint n) {
    final out = <KnowledgePoint>[];
    void walk(KnowledgePoint x) {
      if (x.isLeaf) {
        out.add(x);
        return;
      }
      for (final c in kb.childrenOf[x.id] ?? const <KnowledgePoint>[]) {
        walk(c);
      }
    }

    walk(n);
    return out;
  }
}

/// 状态点（复用于分支清单）。
class _StatusDot extends StatelessWidget {
  final bool filled;
  const _StatusDot({required this.filled});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: filled ? AppColors.success : null,
        border: filled ? null : Border.all(color: AppColors.ink4, width: 1.5),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String text;
  final Color color;
  final bool hollow;
  const _StatusChip({
    required this.text,
    required this.color,
    required this.hollow,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: hollow ? null : color,
            border: hollow ? Border.all(color: color, width: 1.5) : null,
          ),
        ),
        const SizedBox(width: 5),
        Text(text,
            style: const TextStyle(
                fontSize: KnowledgeSizes.secondary, color: kSecondaryInk)),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  const _Stat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      key: ValueKey('stat-$label'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: KnowledgeSizes.heading,
            fontWeight: FontWeight.w700,
            color: AppColors.ink1,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 4),
        Text(label,
            style: const TextStyle(
                fontSize: KnowledgeSizes.secondary, color: kSecondaryInk)),
      ],
    );
  }
}

class _ErrorView extends ConsumerWidget {
  final Object error;
  const _ErrorView({required this.error});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: AppColors.danger, size: 32),
          const SizedBox(height: 10),
          Text('知识本体载入失败：$error',
              style: const TextStyle(fontSize: 13),
              textAlign: TextAlign.center),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () => ref.invalidate(knowledgeBaseProvider),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
