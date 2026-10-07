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
/// ## 关窗纪律（两次翻车后的最终定案）
///
/// 第一次：无条件把 ✕ 改成"隐藏"，托盘没装成 → 关不掉也找不回。
/// 第二次：托盘装成后仍把 ✕ 改成"隐藏" → 用户仍报"关闭键失效"
/// （托盘图标在，但用户的预期是 ✕＝关）。
/// **最终定案：✕ 永远是正常退出，任何情况下都不拦截。**
/// "缩到托盘"只作为托盘菜单里的一个**显式选项**存在（点了才隐藏），
/// 退出仍是托盘菜单/✕ 两条路。替代路径齐备也不够 —— 用户的预期才算数。
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
      MenuItem(key: 'hide', label: '隐藏到托盘（伴学继续）'),
      MenuItem.separator(),
      MenuItem(key: 'exit', label: '退出（伴学会停止）'),
    ]));
    trayManager.addListener(_TrayHandler());
    // ✕ 永远是正常退出（不调 setPreventClose）——见文件头"最终定案"。
    StartupLog.log('托盘：安装成功（✕ = 正常退出；隐藏到托盘走托盘菜单）');
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
    } else if (item.key == 'hide') {
      // 显式选择才隐藏（✕ 不再承担这个语义）
      windowManager.hide();
    } else if (item.key == 'exit') {
      // 退出 = 解除拦截后真关（伴学随之停止，与菜单文案一致）
      windowManager.setPreventClose(false);
      windowManager.destroy();
    }
  }

}
