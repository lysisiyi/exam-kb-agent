/// 启动日志。
///
/// ## 为什么需要它
///
/// Windows 上的 release 版 GUI 应用**没有 stdout** —— `debugPrint`、异常、
/// 崩溃原因全都看不见。用户说"点了没反应"或"闪一下就没了"时，
/// 排查只能靠猜。这不是理论问题：实测 `kaoyan_math_agent.exe` 直接双击后
/// **立刻退出、退出码 0**，而没有任何地方能看到它为什么退出。
///
/// 所以启动过程中每一步都往文件里记一行。这个文件是排查启动类问题的
/// 唯一线索，也是用户报障时唯一能提供的东西。
///
/// ## 为什么不引日志库
///
/// 需要的能力只有三条：**追加**、**带时间戳**、**失败不许影响启动**。
/// 一个库为这三条引入依赖、配置、初始化顺序，不划算。
///
/// ## 往哪写
///
/// 与题库同级的 `startup.log`（`<support>/library/startup.log`）。
/// 放在题库旁边而不是系统临时目录，是因为用户报障时能找得到它 ——
/// "设置"页已经把题库路径显示出来了。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// 启动日志。所有方法都不抛异常。
class StartupLog {
  const StartupLog._();

  static File? _file;

  /// 日志文件路径（未初始化时为 null）。
  static String? get path => _file?.path;

  /// 攒在内存里、还没落盘的消息（**原始消息**，不含时间戳）。
  static final List<String> _pending = [];

  /// 绑定到某个目录下的 `startup.log`。
  ///
  /// 目录不存在时会尝试创建；**创建失败则回退到系统临时目录**。
  ///
  /// ## 为什么必须有回退
  ///
  /// 类的文档说失败时"静默降级为内存里攒着"，但 `_pending` 只在 [bindTo]
  /// 里被清空，而 `main()` 只调用它一次 —— 没有重试、也没有第二个刷盘点。
  /// 于是"题库目录建不出来"（这个仓库真实记录过的 errno 5 场景）发生时，
  /// **包括那句解释它为什么建不出来在内的所有诊断信息，全都留在一个
  /// 没人读的列表里**。诊断通道恰好在最需要它的故障下失效。
  ///
  /// 临时目录几乎总是可写的，把它当第二选择比什么都不留强得多。
  static void bindTo(Directory dir) {
    if (_tryBind(dir)) return;
    _tryBind(Directory(p.join(Directory.systemTemp.path, 'kaoyan_math_agent_log')));
  }

  /// 尝试绑定到 [dir]。成功返回 true。
  static bool _tryBind(Directory dir) {
    try {
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final f = File('${dir.path}${Platform.pathSeparator}startup.log');
      _file = f;
      // 每次启动都另起一段，但**不删历史** —— 用户来回试几次时的
      // 前后对比往往比单次日志更有用
      _write('──────── 启动 ────────');
      // 把绑定之前攒下的消息补进去。
      // ⚠️ 补的是**原始消息**，不是已经带过时间戳的行 ——
      // 否则那几行会有两个时间戳（实测踩过）。
      final queued = List<String>.from(_pending);
      _pending.clear();
      for (final msg in queued) {
        _write(msg);
      }
      return true;
    } catch (_) {
      // 日志不可用不影响启动；交给调用方决定是否换一个目录再试
      return false;
    }
  }

  /// 记一行。
  static void log(String message) {
    _write(message);
  }

  /// 记一行，带异常与堆栈。
  static void error(String message, Object e, [StackTrace? st]) {
    _write('$message：$e');
    if (st != null) {
      for (final line in st.toString().split('\n').take(12)) {
        _write('    $line');
      }
    }
  }

  static void _write(String message) {
    final line = '[${_ts()}] $message';

    // 先落文件，再尽力往 stdout 写一份。
    //
    // ⚠️ 顺序很关键，而且 `print` **必须**包在 try 里：
    // Windows 的 release 版 GUI 应用没有真正的 stdout，`print` 在那种环境下
    // 可能抛异常。那会让"写日志"这件事本身把启动搞死 ——
    // 一个诊断工具绝不该成为故障源。实测踩过这个坑。
    final f = _file;
    if (f == null) {
      // 存**原始消息**，时间戳留到真正落盘时再加。
      // 存已格式化的行会导致补写时出现两个时间戳。
      _pending.add(message);
    } else {
      try {
        f.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
      } catch (_) {
        // 写不进去就算了，绝不向上抛
      }
    }

    try {
      // ignore: avoid_print
      print(line);
    } catch (_) {
      // 见上：没有 stdout 就安静地跳过
    }
  }

  static String _ts() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    String three(int v) => v.toString().padLeft(3, '0');
    return '${two(n.hour)}:${two(n.minute)}:${two(n.second)}.'
        '${three(n.millisecond)}';
  }
}
