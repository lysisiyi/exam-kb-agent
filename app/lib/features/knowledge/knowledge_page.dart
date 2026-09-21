/// 知识库页面：**图谱**与**大纲**两种查看方式。
///
/// ## 两种视图各自回答什么
///
/// | 视图 | 回答的问题 | 交互 |
/// |---|---|---|
/// | 图谱 | 「这一科长什么样」—— 层级、分布、哪些考点考频高 | 滚轮缩放、拖动平移、点节点看详情 |
/// | 大纲 | 「第几章第几节讲了什么」—— 按考纲顺序逐行读 | 逐级展开、点考点看定义与公式 |
///
/// 数据是同一份本体，两种视图都**从树结构出发**（`KnowledgeBase.childrenOf`），
/// 不依赖 `level` 字段 —— 那个字段历史上与树深不一致，曾让这里显示「章节 0」。
///
/// ## 为什么页头不再放大卡片
///
/// 图谱要占满剩余高度（它的平移手势不能与页面滚动打架），所以页头压成
/// 一行统计 + 视图切换；「高频考点 Top 10」搬到大纲视图里 —— 它本来就是
/// "读目录"这件事的一部分。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme/app_fonts.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/state_views.dart';
import '../../domain/knowledge/knowledge_point.dart';
import 'knowledge_graph_view.dart';
import 'knowledge_node_style.dart' show kSecondaryInk;
import 'knowledge_outline_view.dart';
import 'knowledge_sizes.dart';

/// 查看方式。
enum KnowledgeViewMode {
  graph('图谱', Icons.account_tree_outlined),
  outline('大纲', Icons.format_list_bulleted);

  const KnowledgeViewMode(this.label, this.icon);
  final String label;
  final IconData icon;
}

class KnowledgePage extends ConsumerStatefulWidget {
  const KnowledgePage({super.key});

  @override
  ConsumerState<KnowledgePage> createState() => _KnowledgePageState();
}

class _KnowledgePageState extends ConsumerState<KnowledgePage> {
  KnowledgeViewMode _mode = KnowledgeViewMode.graph;

  @override
  Widget build(BuildContext context) {
    final kbAsync = ref.watch(knowledgeBaseProvider);

    return kbAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, st) => _ErrorView(error: e),
      data: (kb) => _LoadedView(
        kb: kb,
        mode: _mode,
        onModeChanged: (m) => setState(() => _mode = m),
      ),
    );
  }
}

class _ErrorView extends ConsumerWidget {
  final Object error;
  const _ErrorView({required this.error});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 复用统一的错误态，但重试要**多做一步**：清掉 `KnowledgeRepository`
    // 的内部缓存。只 invalidate provider 不够 —— 单例仓库会把上次的失败
    // 结果一直留在 `_cache` 里，重试永远拿到同一个错误。
    return AppErrorView(
      title: '知识点本体载入失败',
      error: error,
      onRetry: () {
        ref.read(knowledgeRepositoryProvider).clear();
        ref.invalidate(knowledgeBaseProvider);
      },
      retryLabel: '重新载入',
    );
  }
}

class _LoadedView extends StatelessWidget {
  final KnowledgeBase kb;
  final KnowledgeViewMode mode;
  final ValueChanged<KnowledgeViewMode> onModeChanged;

  const _LoadedView({
    required this.kb,
    required this.mode,
    required this.onModeChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Header(kb: kb, mode: mode, onModeChanged: onModeChanged),
        const Divider(height: 1),
        Expanded(
          child: switch (mode) {
            KnowledgeViewMode.graph => KnowledgeGraphView(kb: kb),
            KnowledgeViewMode.outline => KnowledgeOutlineView(kb: kb),
          },
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  final KnowledgeBase kb;
  final KnowledgeViewMode mode;
  final ValueChanged<KnowledgeViewMode> onModeChanged;

  const _Header({
    required this.kb,
    required this.mode,
    required this.onModeChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        kb.subjectName,
                        style: AppTypography.pageTitle,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('本体 v${kb.version}',
                        style: const TextStyle(
                            fontSize: KnowledgeSizes.secondary,
                            color: kSecondaryInk)),
                  ],
                ),
                const SizedBox(height: 5),
                Wrap(
                  spacing: 14,
                  runSpacing: 4,
                  children: [
                    _Stat(label: '章节', value: '${kb.chapters.length}'),
                    _Stat(label: '知识点', value: '${kb.leaves.length}'),
                    _Stat(
                      label: '含公式',
                      value:
                          '${kb.leaves.where((l) => l.formulas.isNotEmpty).length}',
                    ),
                    _Stat(
                      label: '有考频数据',
                      value:
                          '${kb.leaves.where((l) => l.examYears.isNotEmpty).length}',
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _ModeSwitch(mode: mode, onChanged: onModeChanged),
        ],
      ),
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
      // key 是给测试用的：页面上"3"和"章节"都可能在别处出现（图例里也有
      // "章节"两个字），断言必须能定位到这一格
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

class _ModeSwitch extends StatelessWidget {
  final KnowledgeViewMode mode;
  final ValueChanged<KnowledgeViewMode> onChanged;

  const _ModeSwitch({required this.mode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface2,
        borderRadius: AppRadius.rMd,
      ),
      padding: const EdgeInsets.all(3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final m in KnowledgeViewMode.values)
            Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: () => onChanged(m),
                borderRadius: AppRadius.rSm,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: m == mode ? AppColors.surface : null,
                    borderRadius: AppRadius.rSm,
                    boxShadow: m == mode ? AppShadows.s1 : null,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        m.icon,
                        size: 16,
                        color: m == mode ? AppColors.primaryStrong : AppColors.ink3,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        m.label,
                        style: TextStyle(
                          fontSize: KnowledgeSizes.title,
                          // 选中态只差"粗一档"：族里只有 Regular/Bold，
                          // 用 w500 会被静默近似成 Regular（等于没变）——
                          // 见 `app_fonts.dart` 里字重的说明
                          fontWeight:
                              m == mode ? AppFonts.bold : AppFonts.regular,
                          color:
                              m == mode ? AppColors.primaryStrong : AppColors.ink2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
