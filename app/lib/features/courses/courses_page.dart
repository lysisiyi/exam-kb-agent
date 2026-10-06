/// 网课页 —— V3 的课程/课时/课时笔记入口。
///
/// P0 是占位空态：伴学管道（区域框选、定时截图、GLM 笔记）随 P1 上线，
/// B 站字幕轨随 P4 上线。空态把"接下来这里会有什么"说清楚，而不是白屏。
library;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

class CoursesPage extends StatelessWidget {
  const CoursesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: const BoxDecoration(
                color: AppColors.primaryWeak,
                borderRadius: AppRadius.rLg,
              ),
              alignment: Alignment.center,
              child: const Text('📺', style: TextStyle(fontSize: 28)),
            ),
            const SizedBox(height: 14),
            const Text('还没有课程',
                style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(
              'P1 上线后，在这里贴一节网课：框选一次播放器区域，'
              '小研会定时截屏、自动记知识点笔记，学完一键生成课时练习。',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 12.5,
                  height: 1.8,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            const OutlinedButton(
              onPressed: null,
              child: Text('添加课程（随 P1 上线）'),
            ),
          ],
        ),
      ),
    );
  }
}
