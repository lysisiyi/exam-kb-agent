/// 开发期导航外壳。
///
/// 只挂载**已经实现**的页面，其余 Tab 用占位页，避免点进去白屏。
/// 随着 M2–M6 推进，这里的占位会逐个换成真实页面。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/providers.dart';
import 'core/widgets/adaptive_shell.dart';
import 'features/entry/entry_page.dart';
import 'features/knowledge/knowledge_page.dart';
import 'features/problems/problems_page.dart';
import 'features/review/review_page.dart';
import 'features/settings/settings_page.dart';

class DevShell extends ConsumerWidget {
  /// 启动时停在第几个 Tab。
  ///
  /// 默认 0（知识库）。**开发期可覆盖**：`main()` 会读环境变量
  /// `DSH_INITIAL_TAB`，让 App 直接开在某个页面上。
  ///
  /// 为什么需要这个：这个项目的界面在自动化环境里无法交互
  /// （沙箱会回收 GUI 进程），于是"某个页面一打开就崩"这类问题
  /// 只能靠人去点。有了这个开关，直接开在目标页面即可抓到真实报错。
  final int initialIndex;

  const DevShell({super.key, this.initialIndex = 0});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 复习角标：待复习张数。拿不到就先不显示，不阻塞导航。
    final dueCount = ref.watch(reviewStatsProvider).valueOrNull?.dueNow;

    return AdaptiveShell(
      initialIndex: initialIndex,
      destinations: [
        NavDestination(
          label: '知识库',
          icon: Icons.account_tree_outlined,
          selectedIcon: Icons.account_tree,
          shortcutHint: 'Ctrl+1',
          builder: () => const KnowledgePage(),
        ),
        NavDestination(
          label: '今日复习',
          icon: Icons.home_outlined,
          selectedIcon: Icons.home,
          shortcutHint: 'Ctrl+2',
          badgeCount: dueCount,
          builder: () => const ReviewPage(),
        ),
        NavDestination(
          label: '错题本',
          icon: Icons.menu_book_outlined,
          selectedIcon: Icons.menu_book,
          shortcutHint: 'Ctrl+3',
          builder: () => const ProblemsPage(),
        ),
        NavDestination(
          label: '录入',
          icon: Icons.add_box_outlined,
          selectedIcon: Icons.add_box,
          shortcutHint: 'Ctrl+4',
          builder: () => const EntryPage(),
        ),
        NavDestination(
          label: '组卷',
          icon: Icons.description_outlined,
          selectedIcon: Icons.description,
          shortcutHint: 'Ctrl+5',
          builder: () => const _Placeholder(
            title: '智能组卷',
            milestone: 'M6',
            plan: '贪心组卷 + 真题结构模板 + 三版式 PDF 导出',
            done: [
              '考频数据已就绪（19 章 / 86 个热点）',
              '数据导出（Markdown + 图片包）已在「设置」页可用',
            ],
            todo: [
              '组卷引擎（贪心 + 回溯）',
              'PDF 导出（pdf 包已就绪；预览需引回 printing 并预置 pdfium）',
              '试卷预览页',
            ],
          ),
        ),
        NavDestination(
          label: '设置',
          icon: Icons.settings_outlined,
          selectedIcon: Icons.settings,
          shortcutHint: 'Ctrl+6',
          builder: () => const SettingsPage(),
        ),
      ],
      sidebarFooter: const _SidebarFooter(),
    );
  }
}

class _SidebarFooter extends StatelessWidget {
  const _SidebarFooter();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(15),
            gradient: const LinearGradient(
              colors: [Color(0xFF4A66E0), Color(0xFF7048E8)],
            ),
          ),
          alignment: Alignment.center,
          child: const Text(
            '李',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ),
        const SizedBox(width: 9),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '开发版',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
              ),
              Text(
                'M1 · 地基验收',
                style: TextStyle(fontSize: 10.5, color: Color(0xFF8A909E)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 占位页：显示该功能的里程碑、已完成项、待办项。
///
/// 这比"敬请期待"有用得多 —— 它同时是**开发进度看板**。
class _Placeholder extends StatelessWidget {
  final String title;
  final String milestone;
  final String plan;
  final List<String> done;
  final List<String> todo;

  const _Placeholder({
    required this.title,
    required this.milestone,
    required this.plan,
    required this.done,
    required this.todo,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(title, style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(width: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEDF0FF),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      milestone,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF2F49AF),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(plan, style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 24),
              _Checklist(title: '已完成', items: done, checked: true),
              const SizedBox(height: 18),
              _Checklist(title: '待办', items: todo, checked: false),
            ],
          ),
        ),
      ),
    );
  }
}

class _Checklist extends StatelessWidget {
  final String title;
  final List<String> items;
  final bool checked;

  const _Checklist({
    required this.title,
    required this.items,
    required this.checked,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
            color: Color(0xFF8A909E),
          ),
        ),
        const SizedBox(height: 10),
        for (final it in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  checked
                      ? Icons.check_circle_outline
                      : Icons.radio_button_unchecked,
                  size: 16,
                  color: checked
                      ? const Color(0xFF0CA678)
                      : const Color(0xFFB4BAC6),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    it,
                    style: const TextStyle(fontSize: 13, height: 1.6),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
