/// Windows 图片 / 文件来源实现（基于 `file_selector`）。
///
/// ## PC 版的产品判断
/// **PC 上没有"对着屏幕拍错题"的场景。** 有摄像头，但没人会那么用。
///
/// 而 PC 上恰有你**全部的学习资料** —— 真题 PDF、教材扫描件、以前的笔记。
/// 所以 Windows 版的主入口不是拍照，而是：
///
/// ```
/// 选一个文件夹（或拖入 N 个 PDF/图片）
///   → 批量解析
///   → 逐题核对 + 打标
///   → 进题库
/// ```
///
/// 这就是 [pickDirectory] 存在的原因，也是 PC 版相对移动端的真正优势。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart' as fs;
import 'package:path/path.dart' as p;

import 'platform_services.dart';
/// 支持的图片扩展名。
const List<String> kImageExtensions = [
  '.png', '.jpg', '.jpeg', '.webp', '.bmp', '.gif', '.tif', '.tiff',
];

/// 支持的文档扩展名（题库批量导入用）。
const List<String> kDocumentExtensions = [
  '.pdf', '.md', '.txt', '.docx',
];

/// 基于 `file_selector` 的 Windows 实现。
class ImageSourceServiceWindows implements ImageSourceService {
  const ImageSourceServiceWindows();

  @override
  bool get supportsCamera => false; // PC 无拍照录入场景

  @override
  bool get supportsDirectoryPicker => true;

  @override
  Future<PickedFile?> pickFromCamera() async {
    // 明确不支持 —— 让 UI 隐藏入口，而不是弹一个坏掉的对话框。
    throw UnsupportedError(
      'Windows 版不支持拍照录入。请用「选择图片」或「选择文件夹」导入。',
    );
  }

  @override
  Future<PickedFile?> pickImage() async {
    const typeGroup = fs.XTypeGroup(
      label: '图片',
      extensions: kImageExtensions,
    );
    final file = await fs.openFile(acceptedTypeGroups: [typeGroup]);
    if (file == null) return null; // 用户取消
    return _toPicked(file.path);
  }

  @override
  Future<List<PickedFile>> pickMultipleImages() async {
    const typeGroup = fs.XTypeGroup(
      label: '图片',
      extensions: kImageExtensions,
    );
    final files = await fs.openFiles(acceptedTypeGroups: [typeGroup]);
    return _toPickedList(files.map((f) => f.path));
  }

  @override
  Future<List<PickedFile>> pickPdfs() async {
    const typeGroup = fs.XTypeGroup(
      label: '文档',
      extensions: kDocumentExtensions,
    );
    final files = await fs.openFiles(acceptedTypeGroups: [typeGroup]);
    return _toPickedList(files.map((f) => f.path));
  }

  @override
  Future<List<PickedFile>> pickDirectory() async {
    final dirPath = await fs.getDirectoryPath();
    if (dirPath == null) return const [];

    final dir = Directory(dirPath);
    if (!dir.existsSync()) return const [];

    // 递归扫描，但限制深度避免误选 C:\ 时把整盘扫一遍。
    const maxDepth = 6;
    final found = <String>[];

    void scan(Directory d, int depth) {
      if (depth > maxDepth) return;
      final List<FileSystemEntity> entries;
      try {
        entries = d.listSync(followLinks: false);
      } on FileSystemException {
        return; // 无权限的目录跳过
      }
      for (final e in entries) {
        if (e is Directory) {
          // 跳过明显的非资料目录
          final name = p.basename(e.path);
          if (name.startsWith('.') || name == 'node_modules') continue;
          scan(e, depth + 1);
        } else if (e is File) {
          final ext = p.extension(e.path).toLowerCase();
          if (kImageExtensions.contains(ext) ||
              kDocumentExtensions.contains(ext)) {
            found.add(e.path);
          }
        }
      }
    }

    scan(dir, 0);
    // 排序保证可预期的导入顺序
    found.sort();
    return _toPickedList(found);
  }

  // ───────────────────────────────────────────────────────────────────────

  /// 构造 [PickedFile]。**不读文件内容** —— 惰性读取，避免一次载入几百 MB。
  static PickedFile _toPicked(String path) {
    final f = File(path);
    var size = 0;
    try {
      size = f.statSync().size;
    } catch (_) {
      size = 0;
    }
    return PickedFile(
      path: path,
      name: p.basename(path),
      sizeBytes: size,
    );
  }

  static List<PickedFile> _toPickedList(Iterable<String> paths) =>
      paths.map(_toPicked).toList();
}

/// 读取 [PickedFile] 的字节内容。
///
/// 单独放在这里而不是放进 [PickedFile]，是因为：
/// 1. 批量导入时**不该**一次性把所有文件读进内存（100 个 PDF 可能是 GB 级）
/// 2. 让 `platform_services.dart` 保持纯抽象，不依赖 `dart:io`
extension PickedFileIo on PickedFile {
  /// 读取全部字节。
  Future<Uint8List> readBytes() async => File(path).readAsBytes();

  /// 按扩展名判断是否为图片。
  bool get isImage =>
      kImageExtensions.contains(p.extension(path).toLowerCase());

  /// 按扩展名判断是否为 PDF。
  bool get isPdf => p.extension(path).toLowerCase() == '.pdf';
}
