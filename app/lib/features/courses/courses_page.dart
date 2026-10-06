/// 网课页 —— 课程 / 课时 / 课时笔记 / 伴学会话（P1 主体）。
///
/// 管线（V3_PLAN §4.1）：框选区域（每课时一次）→ 定时截屏 → 感知哈希去重
/// （画面没换不烧调用）→ glm-4.6v-flash 结构化笔记 → 追加课时 Markdown。
/// 截屏失败/解析失败都如实提示，不静默；笔记落盘前按指纹去重。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../services/companion/course_store.dart';
import '../../services/companion/note_llm.dart';
import '../../services/companion/screen_capture.dart';

final courseStoreProvider = FutureProvider<CourseStore>((ref) async {
  final paths = await ref.watch(libraryPathsProvider.future);
  return CourseStore(coursesDir: Directory('${paths.root.path}/courses'));
});

/// 截屏服务（测试可 override）。
final screenCaptureProvider =
    Provider<ScreenCaptureService>((ref) => ScreenCaptureServiceImpl());

class CoursesPage extends ConsumerWidget {
  const CoursesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref.watch(courseStoreProvider).when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('课程目录读不了：$e')),
      data: (store) => FutureBuilder<List<CourseRecord>>(
        future: store.listCourses(),
        builder: (context, snap) {
          final courses = snap.data ?? const <CourseRecord>[];
          return Scaffold(
            backgroundColor: Colors.transparent,
            floatingActionButton: FloatingActionButton.extended(
              onPressed: () async {
                final title = await _askTitle(context, '课程名称（如：线性代数基础班）');
                if (title == null || title.trim().isEmpty) return;
                final store = await ref.read(courseStoreProvider.future);
                await store.createCourse(title: title.trim());
                ref.invalidate(courseStoreProvider);
              },
              label: const Text('新建课程'),
              icon: const Icon(Icons.add),
            ),
            body: courses.isEmpty
                ? Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Text('📺', style: TextStyle(fontSize: 40)),
                    const SizedBox(height: 10),
                    const Text('还没有课程',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    Text('右下角新建一门课，再为它添加课时，就能开始伴学。',
                        style: TextStyle(
                            fontSize: 12.5,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant)),
                  ]))
                : ListView.builder(
                    padding: const EdgeInsets.all(24),
                    itemCount: courses.length,
                    itemBuilder: (context, i) => Card(
                      child: ListTile(
                        leading: const Icon(Icons.smart_display_outlined),
                        title: Text(courses[i].title),
                        subtitle: Text('平台：${courses[i].platform}'),
                        onTap: () => Navigator.of(context).push<Never>(
                            MaterialPageRoute(
                                builder: (_) =>
                                    _CourseDetailPage(course: courses[i]))),
                      ),
                    ),
                  ),
          );
        },
      ),
    );
  }
}

Future<String?> _askTitle(BuildContext context, String label) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(label),
      content: TextField(controller: controller, autofocus: true),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('确定')),
      ],
    ),
  );
}

class _CourseDetailPage extends ConsumerWidget {
  final CourseRecord course;
  const _CourseDetailPage({required this.course});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: Text(course.title)),
      body: FutureBuilder<List<LessonRecord>>(
        future: ref
            .watch(courseStoreProvider.future)
            .then((s) => s.listLessons(course)),
        builder: (context, snap) {
          final lessons = snap.data ?? const <LessonRecord>[];
          if (lessons.isEmpty) {
            return const Center(child: Text('还没有课时，右下角添加一节。'));
          }
          return ListView.builder(
            padding: const EdgeInsets.all(24),
            itemCount: lessons.length,
            itemBuilder: (context, i) => Card(
              child: ListTile(
                leading: Text('${lessons[i].idx}',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                title: Text(lessons[i].title),
                subtitle: Text(lessons[i].captureRegion == null
                    ? '还没框选截图区域'
                    : '已框选截图区域'),
                onTap: () => Navigator.of(context).push<Never>(MaterialPageRoute(
                    builder: (_) => _LessonPage(course: course, lesson: lessons[i]))),
              ),
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final title = await _askTitle(context, '课时名称（如：第1讲 特征值）');
          if (title == null || title.trim().isEmpty) return;
          final store = await ref.read(courseStoreProvider.future);
          await store.createLesson(course, title.trim());
          ref.invalidate(courseStoreProvider);
        },
        label: const Text('添加课时'),
        icon: const Icon(Icons.add),
      ),
    );
  }
}

/// 课时页：笔记时间戳流 + 伴学控制（框选区域 / 开始 / 暂停 / 记一下）。
class _LessonPage extends ConsumerStatefulWidget {
  final CourseRecord course;
  final LessonRecord lesson;
  const _LessonPage({required this.course, required this.lesson});

  @override
  ConsumerState<_LessonPage> createState() => _LessonPageState();
}

class _LessonPageState extends ConsumerState<_LessonPage> {
  List<LessonNote> _notes = const [];
  bool _running = false;
  bool _busy = false;
  String? _status;
  int? _lastHash;
  Timer? _timer;
  late LessonRecord _lesson;

  @override
  void initState() {
    super.initState();
    _lesson = widget.lesson;
    _reload();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    if (!_lesson.file.existsSync()) return;
    setState(() => _notes = CourseStore.parseNotes(_lesson.file.readAsStringSync()));
  }

  Future<void> _pickRegion() async {
    final capture = ref.read(screenCaptureProvider);
    setState(() => _status = '正在截取全屏（用于框选区域）…');
    final frame = await capture.captureFullScreen();
    if (!mounted) return;
    if (frame == null) {
      setState(() => _status = '截屏失败：系统没有授权或没有屏幕。');
      return;
    }
    final rect = await Navigator.of(context).push<CaptureRect>(
      MaterialPageRoute(builder: (_) => _RegionPickerPage(frame: frame)),
    );
    if (rect == null) {
      setState(() => _status = null);
      return;
    }
    final store = await ref.read(courseStoreProvider.future);
    await store.setCaptureRegion(_lesson, rect.toString());
    setState(() {
      _lesson = LessonRecord(
          id: _lesson.id,
          courseId: _lesson.courseId,
          idx: _lesson.idx,
          title: _lesson.title,
          file: _lesson.file,
          captureRegion: rect.toString());
      _status = '截图区域已保存：${rect.w}×${rect.h}';
    });
  }

  Future<void> _captureOnce() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = '正在截屏…';
    });
    try {
      final capture = ref.read(screenCaptureProvider);
      final full = await capture.captureFullScreen();
      if (full == null) {
        setState(() => _status = '截屏失败：系统没有授权或没有屏幕。');
        return;
      }
      final rect = CaptureRect.tryParse(_lesson.captureRegion) ??
          uiEdgeInsets.inset(CaptureRect(0, 0, full.width, full.height));
      final frame = cropFrame(full, rect);
      final hash = aHashOfJpeg(frame.jpegBytes);
      if (_lastHash != null && frameUnchanged(_lastHash!, hash)) {
        _lastHash = hash;
        setState(() => _status = '画面没变，跳过这一帧。');
        return;
      }
      _lastHash = hash;
      setState(() => _status = '正在让小研读画面…');
      final llm = ref.read(ingestClientProvider);
      if (llm == null) {
        setState(() => _status = '先到「设置」里配好 AI 服务商（建议智谱 glm-4.6v-flash，免费视觉档）。');
        return;
      }
      final (rawNotes, rawText) =
          await CompanionNoteClient(llm).extractNotes(frame.jpegBytes);
      if (rawNotes.isEmpty) {
        setState(() => _status = rawText.trim().isEmpty
            ? '没有可记的内容。'
            : '画面里没有新知识点（或解析不出）。');
        return;
      }
      final store = await ref.read(courseStoreProvider.future);
      var added = 0;
      for (final n in rawNotes) {
        final ok = await store.appendNote(
            _lesson, LessonNote(time: n.time, point: n.point, formula: n.formula));
        if (ok) added++;
      }
      await _reload();
      setState(() => _status = added == 0
          ? '内容与已有笔记重复，没有新条目。'
          : '记下 $added 条笔记（共 ${_notes.length} 条）。');
    } catch (e) {
      setState(() => _status = '记笔记失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toggleAuto() {
    if (_running) {
      _timer?.cancel();
      setState(() {
        _running = false;
        _status = '伴学已暂停。';
      });
      return;
    }
    if (_lesson.captureRegion == null) {
      setState(() => _status = '先框选一次截图区域（播放器位置），再开始伴学。');
      return;
    }
    _timer = Timer.periodic(const Duration(minutes: 5), (_) => _captureOnce());
    setState(() {
      _running = true;
      _status = '伴学中：每 5 分钟自动记一次（画面没变不调用 AI）。';
    });
  }

  @override
  Widget build(BuildContext context) {
    final canCompanion = _lesson.captureRegion != null;
    return Scaffold(
      appBar: AppBar(title: Text(_lesson.title)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
            child: Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                    onPressed: _busy ? null : _pickRegion,
                    icon: const Icon(Icons.crop_free),
                    label: Text(_lesson.captureRegion == null
                        ? '框选截图区域'
                        : '重新框选区域')),
                FilledButton.icon(
                    onPressed: (_busy || !canCompanion) ? null : _toggleAuto,
                    icon: Icon(_running ? Icons.pause : Icons.play_arrow),
                    label: const Text('开始伴学（每 5 分钟）')),
                OutlinedButton.icon(
                    onPressed: (_busy || !canCompanion) ? null : _captureOnce,
                    icon: const Icon(Icons.camera_alt),
                    label: const Text('记一下')),
                if (_running)
                  const Chip(label: Text('伴学中'), backgroundColor: AppColors.primaryWeak),
                if (_busy)
                  const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
          ),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(_status!,
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.primaryStrong))),
            ),
          const Divider(height: 20),
          Expanded(
            child: _notes.isEmpty
                ? Center(
                    child: Text('还没有笔记。框选区域后开始伴学，或点「记一下」立即截一帧。',
                        style: TextStyle(
                            fontSize: 12.5,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant)))
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                    itemCount: _notes.length,
                    itemBuilder: (context, i) {
                      final n = _notes[i];
                      return Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  if (n.time != null)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                          color: AppColors.primaryWeak,
                                          borderRadius:
                                              BorderRadius.circular(7)),
                                      child: Text(n.time!,
                                          style: const TextStyle(
                                              fontSize: 11.5,
                                              fontWeight: FontWeight.w700,
                                              color: AppColors.primaryStrong)),
                                    ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                      child: Text(n.point,
                                          style: const TextStyle(
                                              fontSize: 13.5,
                                              fontWeight: FontWeight.w700))),
                                ]),
                                if (n.formula != null) ...[
                                  const SizedBox(height: 6),
                                  Text('- 公式：${n.formula}',
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant)),
                                ],
                              ]),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// 区域框选：把全屏截图铺开，用户拖一个矩形，返回原始像素坐标。
class _RegionPickerPage extends StatefulWidget {
  final CapturedFrame frame;
  const _RegionPickerPage({required this.frame});

  @override
  State<_RegionPickerPage> createState() => _RegionPickerPageState();
}

class _RegionPickerPageState extends State<_RegionPickerPage> {
  Rect? _rect;
  Offset? _start;
  late final Uint8List _preview;
  double _scale = 1.0;

  @override
  void initState() {
    super.initState();
    final decoded = img.decodeImage(widget.frame.jpegBytes)!;
    _preview = Uint8List.fromList(img.encodePng(decoded));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: const Text('框选播放器区域（拖一个矩形）'),
          actions: [
            TextButton(
                onPressed: _rect == null
                    ? null
                    : () {
                        // 显示坐标 ÷ scale = 原始截屏像素（AspectRatio+fill 下两轴同 scale）
                        Navigator.pop(context, CaptureRect(
                            (_rect!.left / _scale).round(), (_rect!.top / _scale).round(),
                            (_rect!.width / _scale).round(), (_rect!.height / _scale).round()));
                      },
                child: const Text('确定')),
          ]),
      body: LayoutBuilder(builder: (context, cons) {
        _scale = cons.maxWidth / widget.frame.width;
        return GestureDetector(
          onPanStart: (d) => setState(() => _start = d.localPosition),
          onPanUpdate: (d) => setState(() {
            _rect = Rect.fromPoints(_start ?? d.localPosition, d.localPosition);
          }),
          child: Stack(children: [
            // AspectRatio + fill：让显示坐标与原始像素严格线性对应，
            // 拖出来的矩形除以 scale 就是真实截屏坐标（letterbox 会错位）。
            Center(
              child: AspectRatio(
                aspectRatio: widget.frame.width / widget.frame.height,
                child: Image.memory(_preview, fit: BoxFit.fill),
              ),
            ),
            if (_rect != null)
              Positioned(
                left: _rect!.left,
                top: _rect!.top,
                width: _rect!.width,
                height: _rect!.height,
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: AppColors.primary, width: 2),
                    color: AppColors.primary.withValues(alpha: 0.08),
                  ),
                ),
              ),
          ]),
        );
      }),
    );
  }
}
