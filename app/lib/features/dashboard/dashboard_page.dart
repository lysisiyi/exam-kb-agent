/// 学习台 —— V3 的新首页。
///
/// P0 是**静态骨架**：版式与 `docs/design/ui/ui_dashboard.png` 对齐，
/// 数据只接了现成的「到期复习」计数；看课/笔记/练习三张卡标注了
/// 各自的上线阶段（P1/P3），不放假数字 —— 假数字是台账纪律里的"假账"。
/// P1（截图笔记管道）与 P3（练习生成）上线后逐卡接线。
library;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';

class DashboardPage extends ConsumerWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dueCount = ref.watch(reviewStatsProvider).valueOrNull?.dueNow;
    final now = DateTime.now();
    final hour = now.hour;
    final greeting = hour < 11
        ? '早上好'
        : hour < 14
            ? '中午好'
            : hour < 18
                ? '下午好'
                : '晚上好';
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    final dateText = '${now.month}月${now.day}日 周${weekdays[now.weekday - 1]}';

    return Stack(children: [
      SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 96),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 980),
            child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('$greeting，今天也要加油 🌱',
                      style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(width: 12),
                  // 窄窗（compact 断点）下问候语已经很长，日期必须可压缩，
                  // 否则这一行直接 RenderFlex overflow（真撞过，见测试）。
                  Flexible(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(dateText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12.5,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: _ContinueCourseCard(filled: false),
                  ),
                  SizedBox(width: 14),
                  Expanded(child: _StatCard(
                    tag: '✍ 今日笔记',
                    value: '—',
                    hint: '随 P1 伴学管道上线',
                  )),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Expanded(child: _StatCard(
                    tag: '🎯 课时练习',
                    value: '—',
                    hint: '随 P3 练习生成上线',
                  )),
                  const SizedBox(width: 14),
                  Expanded(child: _StatCard(
                    tag: '🔁 到期复习',
                    value: dueCount == null ? '—' : '$dueCount',
                    unit: '张',
                    hint: '在「复习」页开始今天的学习',
                  )),
                ],
              ),
              const SizedBox(height: 14),
              const _RhythmCard(filled: false),
              const SizedBox(height: 14),
              const _WeekCard(),
            ],
          ),
        ),
      ),
      ),
      // 桌宠角标：默认「小研」（智谱皮肤）。点击召唤真悬浮窗（P2）。
      Positioned(
        right: 10,
        bottom: 4,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.line),
                boxShadow: AppShadows.s2,
              ),
              child: const Text('本节「施密特正交化」还没出现，出现了我会马上记 ✍',
                  style: TextStyle(fontSize: 11, height: 1.5)),
            ),
            GestureDetector(
              onTap: () async {
                // 0.3.x 契约：create 传 WindowConfiguration，新引擎跑同一份
                // main，由 fromCurrentEngine().arguments == 'pet' 分流。
                final controller = await WindowController.create(
                    const WindowConfiguration(
                        arguments: 'pet', hiddenAtLaunch: false));
                await controller.show();
              },
              child: Image.asset('assets/pets/zhipu.png',
                  width: 92, fit: BoxFit.contain),
            ),
          ],
        ),
      ),
    ]);
  }
}

/// 「继续看课」大卡。P0 显示空态；P1 接入最近课时后变为可点继续伴学。
class _ContinueCourseCard extends StatelessWidget {
  final bool filled;
  const _ContinueCourseCard({required this.filled});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.rLg,
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('▶ 继续看课',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                  color: AppColors.ink3)),
          const SizedBox(height: 8),
          const Text('还没有正在学的课程',
              style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('P1 上线后：贴一节网课，小研陪你边看边记',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

/// 数字卡（笔记 / 练习 / 复习）。
class _StatCard extends StatelessWidget {
  final String tag;
  final String value;
  final String? unit;
  final String hint;

  const _StatCard({
    required this.tag,
    required this.value,
    this.unit,
    required this.hint,
  });

  @override
  Widget build(BuildContext context) {
    // 不定高：compact 断点下 hint 会折成两行，定高必然 overflow。
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.rLg,
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tag,
              style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                  color: AppColors.ink3)),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(value,
                  style: const TextStyle(
                      fontSize: 26, fontWeight: FontWeight.w700)),
              if (unit != null) ...[
                const SizedBox(width: 4),
                Text(unit!,
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.ink3)),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(hint,
              style: TextStyle(
                  fontSize: 11.5, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

/// 今天的节奏。P0 空态；P1 接课时会话后逐行填充。
class _RhythmCard extends StatelessWidget {
  final bool filled;
  const _RhythmCard({required this.filled});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.rLg,
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('── 今天的节奏 ──',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                  color: AppColors.ink3)),
          const SizedBox(height: 10),
          Text('开始伴学后，这里会出现今天看过哪些课、记了几条笔记、练了几道题。',
              style: TextStyle(
                  fontSize: 12.5,
                  height: 1.7,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

/// 本周统计条。P0 空态。
class _WeekCard extends StatelessWidget {
  const _WeekCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.rLg,
        border: Border.all(color: AppColors.line),
      ),
      child: Text('本周 —— 还没有记录，数据会随伴学与练习慢慢长出来。',
          style: TextStyle(
              fontSize: 12.5, color: Theme.of(context).colorScheme.onSurfaceVariant)),
    );
  }
}
