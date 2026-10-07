/// 托盘 + 关窗策略（P2c spike 结论，2026-10-05）。
///
/// ## spike 结果：降版本，不碰 nativeapi
///
/// `tray_manager` 0.7 的 barrel 同时导出自己的 `TrayManager` 与
/// `nativeapi` 的同名类，名字冲突导致 `setIcon/addListener` 全部解析失败
/// （0.7 内部换成了 nativeapi 0.3 的底层 C-API 包装，也不适合直接用）。
/// 结论：**钉在 0.5.0 的经典 API**（`trayManager` 单例 + `TrayListener` +
/// menu_base 的 Menu/MenuItem）——这正是全网教程那套签名。
/// 附赠一个细节：0.5.0 的 `setIcon` 收**资产相对路径**，库内部自动拼
/// `dirname(exe)/data/flutter_assets/`，所以直接传 `assets/pets/pet.ico`。
///
/// ## 关窗纪律（引以为戒的那次翻车）
///
/// P2c 曾无条件 `setPreventClose(true)` 把 ✕ 改成"隐藏"，而托盘没装成 →
/// App 成了关不掉也找不回的幽灵进程（用户实测报告）。现在的规则：
/// **仅当托盘安装成功、两个出口（点图标显示 / 菜单退出）都真实可用时，
/// 才把 ✕ 改成隐藏**；安装失败就维持系统默认的 ✕ = 退出。
library;

import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../core/platform/startup_log.dart';

/// 安装托盘并决定关窗策略。返回"关窗是否被改成隐藏"。
Future<bool> setupTrayAndClosePolicy() async {
  try {
    await windowManager.ensureInitialized();
    await trayManager.setIcon('assets/pets/pet.ico');
    await trayManager.setToolTip('研伴 · 网课学习伴侣');
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'show', label: '显示研伴'),
      MenuItem.separator(),
      MenuItem(key: 'exit', label: '退出（伴学会停止）'),
    ]));
    trayManager.addListener(_TrayHandler());
    // 托盘可用 → ✕ = 隐藏（两个出口都在：点托盘图标显示 / 菜单退出）
    await windowManager.setPreventClose(true);
    StartupLog.log('托盘：安装成功（✕ = 缩到托盘，退出走托盘菜单）');
    return true;
  } catch (e) {
    // 装不上就维持 ✕ = 退出 —— 见文件头的关窗纪律
    StartupLog.log('托盘：安装失败（$e）—— ✕ 维持为正常退出');
    return false;
  }
}

class _TrayHandler with TrayListener, WindowListener {
  bool _windowListenerAdded = false;

  void _ensureWindowListener() {
    if (!_windowListenerAdded) {
      windowManager.addListener(this);
      _windowListenerAdded = true;
    }
  }

  @override
  void onTrayIconMouseDown() {
    _ensureWindowListener();
    windowManager.show();
    windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() {
    _ensureWindowListener();
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem item) {
    _ensureWindowListener();
    if (item.key == 'show') {
      windowManager.show();
      windowManager.focus();
    } else if (item.key == 'exit') {
      // 退出 = 解除拦截后真关（伴学随之停止，与菜单文案一致）
      windowManager.setPreventClose(false);
      windowManager.destroy();
    }
  }

  @override
  void onWindowClose() async {
    // ✕ = 缩到托盘，伴学不中断（setPreventClose(true) 之后才会走到这里）
    await windowManager.hide();
  }
}
