/// 来源文件的磁盘读写。
///
/// 与 `ingest_session.dart` 分开，是为了让**管道逻辑不依赖 `dart:io`**：
/// 测试可以注入一个假的附件加载器，整条流程离线跑，不用往临时目录写图片。
/// 真实的读盘只在生产路径上用这一份。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../llm/llm_client.dart';
import 'ingest_models.dart';

/// 把路径列表变成待处理来源。
///
/// - 扩展名不认识 → 跳过（不报错：用户选了一个文件夹，里面必然有杂七杂八的文件）
/// - 文件不存在 / 读不到大小 → 跳过
/// - 结果按路径排序，保证同样的输入得到同样的顺序（可复现、便于对账）
Future<List<IngestSource>> sourcesFromPaths(Iterable<String> paths) async {
  final out = <IngestSource>[];
  for (final path in paths) {
    final f = File(path);
    int size;
    try {
      if (!f.existsSync()) continue;
      size = f.statSync().size;
    } catch (_) {
      continue; // 无权限 / 被占用，跳过
    }
    final s = IngestSource.fromPath(path, sizeBytes: size);
    if (s == null) continue;
    out.add(s);
  }
  out.sort((a, b) => a.path.compareTo(b.path));
  return out;
}

/// 从磁盘读出一个来源的附件。
///
/// ## 为什么在这里做大小检查（而不是等 HTTP 报错）
///
/// 超限的文件发出去会得到 413 或一个语焉不详的 400，而且**那一趟已经计费**
/// （部分服务商按请求体计费）。提前拦下来不发，用户既省钱又能看到原因。
Future<ChatAttachment> loadAttachmentFromDisk(IngestSource source) async {
  final mime = mimeForPath(source.path);
  if (mime == null) {
    throw FileSystemException('无法识别的文件类型', source.path);
  }

  final limit = source.isPdf ? kMaxPdfBytes : kMaxImageBytes;
  if (source.sizeBytes > limit) {
    throw FileSystemException(
      '文件 ${formatBytes(source.sizeBytes)} 超过上限 ${formatBytes(limit)}',
      source.path,
    );
  }

  final bytes = await File(source.path).readAsBytes();
  return ChatAttachment(
    kind: source.isPdf ? ChatAttachmentKind.pdf : ChatAttachmentKind.image,
    mimeType: mime,
    bytes: bytes,
    name: p.basename(source.path),
  );
}
