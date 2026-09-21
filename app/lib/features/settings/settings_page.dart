/// 设置页 —— 数据的存放位置、导出与备份。
///
/// ## 为什么导出放在这一页，而不是错题本的工具条里
///
/// 导出不是"看错题"的一部分，它是**数据归属**的表达：
/// "这些内容是你的，随时可以整包带走。" 放在设置里，用户想找的时候
/// 知道去哪儿找；放在列表工具条上，它会被当成一个偶尔用的按钮。
///
/// ## 这一页要如实回答三个问题
///
/// 1. **我的数据在哪** —— 路径直接给全，可复制。用户要能自己去那个文件夹看。
/// 2. **导出到底导出了什么** —— 说清是"只读快照"、图片会一起带走、
///    Obsidian 不需要插件。
/// 3. **哪些东西会丢** —— 复习进度只在本机的 SQLite 里。
///    不告诉用户这件事，等于让他以为"导出 = 完整备份"。
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart' as fs;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout/breakpoints.dart';
import '../../core/providers.dart';
import '../../core/theme/app_fonts.dart';
import '../../core/theme/app_theme.dart';
import '../../services/library/library_exporter.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  bool _exporting = false;
  ExportResult? _lastResult;
  String? _error;

  Future<void> _export() async {
    final target = await fs.getDirectoryPath(
      confirmButtonText: '导出到这里',
    );
    if (target == null || !mounted) return;

    setState(() {
      _exporting = true;
      _error = null;
      _lastResult = null;
    });

    try {
      final db = await ref.read(databaseProvider.future);
      final store = await ref.read(problemStoreProvider.future);
      final paths = await ref.read(libraryPathsProvider.future);

      final exporter = LibraryExporter(
        db: db,
        store: store,
        imagesDir: paths.images,
      );
      final result = await exporter.exportTo(Directory(target));
      if (!mounted) return;
      setState(() => _lastResult = result);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact = BreakpointScope.of(context) == LayoutBreakpoint.compact;
    final paths = ref.watch(libraryPathsProvider);

    return ListView(
      padding: EdgeInsets.fromLTRB(
        compact ? 16 : 28,
        20,
        compact ? 16 : 28,
        32,
      ),
      children: [
        Text('设置', style: Theme.of(context).textTheme.headlineSmall),        const SizedBox(height: 4),
        Text(
          '数据存在你自己的电脑上。这里可以把它整包带走。',
          style: TextStyle(
            fontSize: 13,
            height: 1.7,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),

        // ── 导出 ──────────────────────────────────────────────────────
        _Section(
          title: '导出题库',
          children: [
            const Text(
              '导出一个可以直接用 Obsidian 打开的文件夹：\n'
              '· 每道题一个 .md，格式与 App 内部完全一致\n'
              '· 引用到的图片一起复制过去，不会出现碎图\n'
              '· 公式是标准 \$...\$ 写法，Obsidian 自带渲染，**不需要装插件**\n'
              '· 附带一份「题库索引.md」按考点分组，和一份打开说明',
              style: TextStyle(fontSize: 12.5, height: 1.9),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: const BoxDecoration(
                color: AppColors.warningWeak,
                borderRadius: AppRadius.rSm,
              ),
              child: const Text(
                '导出的是**只读快照**，在这里的修改不会同步回 App。\n'
                '⚠️ 复习进度（错题次数、下次复习时间）只在本机数据库里，'
                '换电脑时它不会跟着 Markdown 走 —— 导出包里只能在 frontmatter '
                '看到一份 `my_` 开头的快照值。',
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.75,
                  color: AppColors.warningInk,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: _exporting ? null : _export,
                icon: _exporting
                    ? const SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.folder_open_outlined, size: 17),
                label: Text(_exporting ? '正在导出…' : '选择文件夹并导出'),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              SelectableText(
                '导出失败：$_error',
                style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
              ),
            ],
            if (_lastResult != null) ...[
              const SizedBox(height: 12),
              _ResultCard(result: _lastResult!),
            ],
          ],
        ),

        const SizedBox(height: 20),

        // ── 数据位置 ──────────────────────────────────────────────────
        _Section(
          title: '数据位置',
          children: [
            paths.when(
              loading: () => const Text('正在读取…',
                  style: TextStyle(fontSize: 12.5)),
              error: (e, _) => Text('读取失败：$e',
                  style: TextStyle(
                      fontSize: 12.5, color: theme.colorScheme.error)),
              data: (p) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '题目内容（Markdown，事实源）：',
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  _PathLine(path: p.problems.path),
                  const SizedBox(height: 10),
                  const Text('图片：', style: TextStyle(fontSize: 12)),
                  const SizedBox(height: 4),
                  _PathLine(path: p.images.path),
                  const SizedBox(height: 10),
                  const Text(
                    '复习进度与索引（SQLite，可重建）：',
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  _PathLine(path: p.indexFile.path),
                  const SizedBox(height: 10),
                  const Text('启动日志：', style: TextStyle(fontSize: 12)),
                  const SizedBox(height: 4),
                  _PathLine(
                    path: '${p.root.path}${Platform.pathSeparator}startup.log',
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Markdown 文件是你的数据，用记事本或 VS Code 直接改都行 —— '
                    '改完回 App 会重建索引。\n'
                    '索引库删掉只会丢复习进度；想保住进度，请连它一起备份。\n'
                    'App 起不来时，把启动日志发给开发者 —— 它记录了启动的每一步。',
                    style: TextStyle(fontSize: 11.5, height: 1.8),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ResultCard extends StatelessWidget {
  final ExportResult result;

  const _ResultCard({required this.result});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final clean = result.isClean;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: clean ? AppColors.successWeak : AppColors.warningWeak,
        borderRadius: AppRadius.rSm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                clean ? Icons.check_circle_outline : Icons.warning_amber_outlined,
                size: 17,
                color: clean ? AppColors.success : AppColors.warningInk,
              ),
              const SizedBox(width: 8),
              Text(
                clean ? '导出完成' : '导出完成，但有 ${result.failures.length} 条没成功',
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(result.summary, style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 6),
          SelectableText(
            result.targetDir,
            style: TextStyle(
              // ⚠️ 这里显示的是**文件路径**，完全可能是中文
              // （`D:\我的题库\导出`）。`'monospace'` 不是 Windows 上能解析
              // 的字体族名 —— 用哪个字体就交给平台默认了；显式给
              // Consolas + 中文回退，这条路径的字体才是确定的。
              fontFamily: AppFonts.mono,
              fontFamilyFallback: AppFonts.monoFallback,
              fontSize: 10.5,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (!clean) ...[
            const SizedBox(height: 10),
            const Text('失败明细：', style: TextStyle(fontSize: 12)),
            for (final e in result.failures.entries.take(10))
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text('· ${e.key} — ${e.value}',
                    style: const TextStyle(fontSize: 11, height: 1.5)),
              ),
            if (result.failures.length > 10)
              Text('…还有 ${result.failures.length - 10} 条',
                  style: const TextStyle(fontSize: 11)),
            if (result.renamedRootFiles.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text(
                '目标目录里已经有同名的、不是本 App 写的文件，'
                '所以下面这些改用了新名字（没有覆盖你的东西）：',
                style: TextStyle(fontSize: 11.5, height: 1.6),
              ),
              for (final r in result.renamedRootFiles)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text('· $r',
                      style: const TextStyle(fontSize: 11, height: 1.5)),
                ),
            ],
          ],
        ],
      ),
    );
  }
}

/// 一条可复制的路径。
class _PathLine extends StatelessWidget {
  final String path;

  const _PathLine({required this.path});

  @override
  Widget build(BuildContext context) {
    return SelectableText(
      path,
      style: TextStyle(
        // 同上：题库目录多半在用户自己的中文路径下
        fontFamily: AppFonts.mono,
        fontFamilyFallback: AppFonts.monoFallback,
        fontSize: 10.5,
        height: 1.6,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _Section({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.line),
        borderRadius: AppRadius.rMd,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}
