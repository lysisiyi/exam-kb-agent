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
import 'features/paper/paper_page.dart';
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
          builder: () => const PaperPage(),
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

/// 占位页与检查清单组件已移除。
///
/// 它们曾用来在导航里展示"这个功能做到哪了"（比"敬请期待"有用）。
/// 随着 M6 完成，**六个导航目的地全部指向真实页面**，已经没有占位页，
/// 所以这两个组件（以及 import 的 `AppColors`）一并删掉 ——
/// 留着就是永远不会被执行、但每次读代码都要跳过的死代码。
///
/// 进度看板搬到 `docs/PROGRESS.md`（它本来就是唯一可信的进度来源）。
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

