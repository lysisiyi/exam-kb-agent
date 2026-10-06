/// 开发期导航外壳。
///
/// V3（P0）导航重组为**七个目的地**：学习台 | 网课 | 练习 | 知识库 | 复习 | 画像 | 设置。
/// 「错题本/录入/批量导入」不再是顶级导航，整体并入知识库宿主页（D17，
/// 见 `features/knowledge/knowledge_home_page.dart`）；「对话」移出导航，
/// 其能力随 P2 并入桌宠「课堂问答」（代码保留，P5 移除）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/providers.dart';
import 'core/widgets/adaptive_shell.dart';
import 'features/courses/courses_page.dart';
import 'features/dashboard/dashboard_page.dart';
import 'features/knowledge/knowledge_home_page.dart';
import 'features/paper/paper_page.dart';
import 'features/profile/profile_page.dart';
import 'features/review/review_page.dart';
import 'features/settings/settings_page.dart';

/// 导航目的地定义。
///
/// 抽成顶层函数（而不是写在 `build` 里）是为了**能被单测**：
/// "七个目的地全部指向真实页面"这句话如果只写在注释里，
/// 将来某次改动把一个页面换回占位组件，没有任何东西会响。
/// 见 `test/shell_navigation_test.dart`。
///
/// 快捷键由 [AdaptiveShell] 按顺序生成（Ctrl+1..9），
/// 所以新增目的地时只要保证 `shortcutHint` 与它在列表里的位置一致。
List<NavDestination> buildDevDestinations({
  /// 待复习张数。null 表示还没取到，此时不显示角标。
  int? dueCount,
}) =>
    [
      NavDestination(
        label: '学习台',
        icon: Icons.dashboard_outlined,
        selectedIcon: Icons.dashboard,
        shortcutHint: 'Ctrl+1',
        builder: () => const DashboardPage(),
      ),
      NavDestination(
        label: '网课',
        icon: Icons.smart_display_outlined,
        selectedIcon: Icons.smart_display,
        shortcutHint: 'Ctrl+2',
        builder: () => const CoursesPage(),
      ),
      NavDestination(
        label: '练习',
        icon: Icons.track_changes_outlined,
        selectedIcon: Icons.track_changes,
        shortcutHint: 'Ctrl+3',
        builder: () => const PaperPage(),
      ),
      NavDestination(
        label: '知识库',
        icon: Icons.account_tree_outlined,
        selectedIcon: Icons.account_tree,
        shortcutHint: 'Ctrl+4',
        builder: () => const KnowledgeHomePage(),
      ),
      NavDestination(
        label: '复习',
        icon: Icons.home_outlined,
        selectedIcon: Icons.home,
        shortcutHint: 'Ctrl+5',
        badgeCount: dueCount,
        builder: () => const ReviewPage(),
      ),
      NavDestination(
        label: '画像',
        icon: Icons.insights_outlined,
        selectedIcon: Icons.insights,
        shortcutHint: 'Ctrl+6',
        builder: () => const ProfilePage(),
      ),
      NavDestination(
        label: '设置',
        icon: Icons.settings_outlined,
        selectedIcon: Icons.settings,
        shortcutHint: 'Ctrl+7',
        builder: () => const SettingsPage(),
      ),
    ];

class DevShell extends ConsumerWidget {
  /// 启动时停在第几个 Tab。
  ///
  /// 默认 0（学习台）。**开发期可覆盖**：`main()` 会读环境变量
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

    // 启动索引同步：外部放进题库目录的 md（转换工具/手动添加）重启可见。
    // 结果不用于渲染；失败在 provider 内部记日志，不影响界面。
    ref.watch(startupIndexSyncProvider);

    return AdaptiveShell(
      initialIndex: initialIndex,
      destinations: buildDevDestinations(dueCount: dueCount),
      sidebarFooter: const _SidebarFooter(),
    );
  }
}

/// 侧边栏底部。
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
              colors: [Color(0xFFC05A17), Color(0xFFE8833A)],
            ),
          ),
          alignment: Alignment.center,
          child: const Text(
            '研',
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
                '研伴 · V3',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
              ),
              Text(
                'P0 · 骨架与设计语言',
                style: TextStyle(fontSize: 10.5, color: Color(0xFF8F887C)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
