/// 桌宠服务：召唤悬浮窗 + 主窗口→宠物气泡的单向通道（P2c）。
///
/// 主窗口是大脑：伴学记下笔记后，把一句话摘要推给宠物"说出来"。
/// 通道用 desktop_multi_window 的 `invokeMethod`（主→宠）+ 宠物侧
/// `setWindowMethodHandler`（见 pet_window.dart 的处理）。
library;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class PetService {
  WindowController? _controller;

  /// 召唤（已存在则只 show）。0.3.x 没有 close-from-outside，
  /// 重复 create 会叠窗口——先查 getAll 里有没有 pet 窗口。
  Future<void> summon() async {
    for (final c in await WindowController.getAll()) {
      if (c.arguments == 'pet') {
        _controller = c;
        await c.show();
        return;
      }
    }
    final c = await WindowController.create(
        const WindowConfiguration(arguments: 'pet', hiddenAtLaunch: false));
    await c.show();
    _controller = c;
  }

  /// 推一条气泡文案。宠物窗口不在/通道失败时静默——气泡是锦上添花，
  /// 绝不能让它把伴学主流程带崩。
  Future<void> sendBubble(String text) async {
    try {
      final c = _controller ?? await _findPet();
      if (c != null) {
        _controller = c;
        await c.invokeMethod('bubble', {'text': text});
      }
    } catch (_) {}
  }

  Future<WindowController?> _findPet() async {
    for (final c in await WindowController.getAll()) {
      if (c.arguments == 'pet') return c;
    }
    return null;
  }
}

final petServiceProvider = Provider<PetService>((ref) => PetService());
