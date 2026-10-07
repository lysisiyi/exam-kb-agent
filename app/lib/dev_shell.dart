/// 开发期导航外壳。
///
/// V3 当前阶段（2026-10-05）：复习优化后回到导航（带到期角标）；
/// 知识库恢复四标签宿主（知识树/题目/**图像录入**/批量导入——录入按
/// 用户口径明确叫「图像」，题目 K2 起演进为节点下图像题卡）。
/// 练习页暂离导航（组卷能力在 P3 并入练习时一起回来）；
/// 「对话」保持移出（P2 并入宠物课堂问答）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/providers.dart';
import 'core/widgets/adaptive_shell.dart';
import 'features/courses/courses_page.dart';
import 'features/dashboard/dashboard_page.dart';
import 'features/knowledge/knowledge_home_page.dart';
import 'features/profile/profile_page.dart';
import 'features/review/review_page.dart';
import 'features/settings/settings_page.dart';

/// 导航目的地定义。
///
/// 抽成顶层函数（而不是写在 `build` 里）是为了**能被单测**。
/// 见 `test/shell_navigation_test.dart`。
///
/// 快捷键由 [AdaptiveShell] 按顺序生成（Ctrl+1..9），
/// 所以新增目的地时只要保证 `shortcutHint` 与它在列表里的位置一致。
List<NavDestination> buildDevDestinations({
  /// 待复习张数。保留参数：复习回到导航时角标立即可用。
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
        label: '复习',
        icon: Icons.home_outlined,
        selectedIcon: Icons.home,
        shortcutHint: 'Ctrl+3',
        badgeCount: dueCount,
        builder: () => const ReviewPage(),
      ),
      NavDestination(
        label: '知识库',
        icon: Icons.account_tree_outlined,
        selectedIcon: Icons.account_tree,
        shortcutHint: 'Ctrl+4',
        builder: () => const KnowledgeHomePage(),
      ),
      NavDestination(
        label: '画像',
        icon: Icons.insights_outlined,
        selectedIcon: Icons.insights,
        shortcutHint: 'Ctrl+5',
        builder: () => const ProfilePage(),
      ),
      NavDestination(
        label: '设置',
        icon: Icons.settings_outlined,
        selectedIcon: Icons.settings,
        shortcutHint: 'Ctrl+6',
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
        ClipRRect(
          borderRadius: BorderRadius.circular(15),
          child: Consumer(builder: (context, ref, _) {
            final skin =
                ref.watch(petSkinProvider).valueOrNull ?? 'zhipu.png';
            return Image.asset('assets/pets/$skin',
                width: 30, height: 30, fit: BoxFit.cover);
          }),
        ),
        const SizedBox(width: 9),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '小研 · 待命',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
              ),
              Text(
                '研伴 V3 · 随时开始伴学',
                style: TextStyle(fontSize: 10.5, color: Color(0xFF8F887C)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
