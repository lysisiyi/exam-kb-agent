/// 关窗策略：**✕ = 正常退出**。
///
/// ## 一次真实的翻车（2026-10-05，用户实测"为什么无法关闭"）
///
/// P2c 时在这里无条件 `setPreventClose(true)`，把 ✕ 改成"隐藏窗口"——
/// 设计意图是"关窗不杀伴学，缩到托盘"。但**托盘图标没装成**（tray_manager
/// 0.7 的 TrayManager 与 nativeapi 导出冲突，setIcon/addListener 全部
/// 编译不过，spike 被推迟），而托盘正是唯一的"找回窗口 / 退出应用"入口。
/// 结果：点 ✕ 后窗口消失、任务栏没有图标、没有任何恢复路径 ——
/// App 变成一个关不掉也找不回的幽灵进程，只能从任务管理器强杀。
///
/// ## 由此立下的纪律
///
/// **凡是"夺走用户既有退出路径"的行为（拦截关闭、隐藏窗口），
/// 只有在替代路径真的可用时才能开启**；替代路径不可用就老老实实
/// 保留系统默认行为（✕ = 退出）。宁可少一个功能，不可让用户被自己的
/// 应用困住。
///
/// 托盘 spike 完成、图标确能装上之后，恢复"✕ = 缩后台"的正确写法是：
/// 仅在托盘安装成功时 setPreventClose(true)，并在托盘菜单提供
/// 「显示」与「退出」两项。
library;

import 'package:window_manager/window_manager.dart';

/// 目前**不拦截关闭**：托盘尚未可用（见文件头），✕ 就是正常退出。
///
/// 返回"关窗是否被改成隐藏"——恒 false，直到托盘可用。
Future<bool> setupTrayAndClosePolicy() async {
  try {
    await windowManager.ensureInitialized();
    return false;
  } catch (_) {
    return false;
  }
}
