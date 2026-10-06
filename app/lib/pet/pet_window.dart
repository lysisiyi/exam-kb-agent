/// 桌宠悬浮窗（P2，V3_PLAN §5）：第二个进程窗口，只负责"脸"。
///
/// 架构纪律：**主窗口是大脑，宠物窗口只是脸**——截图、LLM、落盘全在主窗口；
/// 本窗口只渲染状态与气泡，崩溃不连坐主窗口（独立引擎）。
///
/// P2b 骨架：无边框/置顶/跳过任务栏、整身拖拽（window_manager.startDragging）、
/// 自关闭；六状态 Rive 动画、主窗口→气泡的数据通道、托盘在后续增量。
library;

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../core/theme/app_theme.dart';

/// 桌宠窗口根。引擎侧已确认 `arguments == 'pet'`（见 main 的分流）。
class PetWindow extends StatefulWidget {
  const PetWindow({super.key});

  @override
  State<PetWindow> createState() => _PetWindowState();
}

class _PetWindowState extends State<PetWindow> with WindowListener {
  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _setupWindow();
  }

  Future<void> _setupWindow() async {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(190, 240),
        minimumSize: Size(190, 240),
        maximumSize: Size(190, 240),
        titleBarStyle: TitleBarStyle.hidden,
        windowButtonVisibility: false,
        alwaysOnTop: true,
        skipTaskbar: true,
        backgroundColor: Colors.transparent,
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: Scaffold(
        backgroundColor: Colors.transparent,
        floatingActionButton: FloatingActionButton.small(
          backgroundColor: AppColors.surface,
          foregroundColor: AppColors.ink2,
          onPressed: windowManager.destroy,
          child: const Icon(Icons.close, size: 16),
        ),
        body: GestureDetector(
          // 整个身体都是拖拽区：桌宠必须能被拖到屏幕任意角落
          onPanStart: (d) { windowManager.startDragging(); },
          child: ColoredBox(
            color: Colors.transparent,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 气泡（P2b 静态示例文案；数据通道接入后由主窗口推送）
                Container(
                  margin: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(11),
                    border: Border.all(color: AppColors.line),
                    boxShadow: AppShadows.s2,
                  ),
                  child: const Text('我在陪你上网课 ✍',
                      style: TextStyle(fontSize: 11.5, height: 1.4)),
                ),
                Image.asset('assets/pets/zhipu.png',
                    width: 130, fit: BoxFit.contain),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
