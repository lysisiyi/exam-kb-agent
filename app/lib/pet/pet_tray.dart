/// 托盘 + 关窗策略：主窗口关到托盘，伴学不中断（V3_PLAN §5）。
///
/// 用户的肌肉记忆是点 ✕ 关窗口——桌面伴学应用关窗即退出会把伴学杀掉，
/// 所以 ✕ = 缩到托盘，退出入口在托盘菜单里。桌宠窗口不走这套（它有自己的
/// 关闭按钮，直接 destroy）。
library;


import 'package:window_manager/window_manager.dart';

/// 主窗口是否启用了"关到托盘"。测试环境（无窗口插件）返回 false。
Future<bool> setupTrayAndClosePolicy() async {
  try {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    return true;
  } catch (_) {
    return false;
  }
}


