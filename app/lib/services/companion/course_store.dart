/// 课时笔记事实源：课程与课时的 Markdown 读写。
///
/// ## 结构（V3_PLAN §3.1）
///
/// ```
/// <库根>/courses/<课程目录>/course.md            （课程元信息）
/// <库根>/courses/<课程目录>/lessons/01-<题名>.md  （一课时一文件）
/// ```
///
/// 约定：课时正文里**一条 `## <mm:ss> <要点>` 就是一条笔记**。
/// 这让笔记文件天然可解析、可手改——与 `problems/*.md` 同一哲学。
/// 本文件只管事实源；SQLite 派生索引随 K1/P4 再补（当前规模直接扫目录足够）。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// 一门课。
class CourseRecord {
  final String id;
  final String title;
  final String platform;

  /// 课程目录（绝对路径）。
  final Directory dir;

  const CourseRecord({
    required this.id,
    required this.title,
    required this.platform,
    required this.dir,
  });
}

/// 一节课（课时）。
class LessonRecord {
  final String id;
  final String courseId;
  final int idx;
  final String title;

  /// 截图区域 `"x,y,w,h"`（相对全屏）。null = 还没框选。
  final String? captureRegion;
  final File file;

  const LessonRecord({
    required this.id,
    required this.courseId,
    required this.idx,
    required this.title,
    required this.file,
    this.captureRegion,
  });
}

/// 一条课时笔记。
class LessonNote {
  /// 画面时间戳 `mm:ss`；读不到就是 null（界面退化为"已记 N 条"）。
  final String? time;

  /// 一句话要点（去重键）。
  final String point;

  /// 画面里的公式（LaTeX 或原样文本），可空。
  final String? formula;

  const LessonNote({this.time, required this.point, this.formula});

  /// 去重指纹：全角转半角、去空白与标点后比较——同义改写不管，
  /// 只挡"同一帧重复解析出同一条"。
  String get fingerprint {
    final t = point.replaceAll(RegExp(r'[\s，。、；：！？（）()「」·,.;:!?"'']'), '');
    return t.toLowerCase();
  }
}

/// 课程/课时 Markdown 仓库。
class CourseStore {
  final Directory coursesDir;
  CourseStore({required this.coursesDir});

  Future<void> ensureDir() async {
    if (!coursesDir.existsSync()) coursesDir.createSync(recursive: true);
  }

  // ── 课程 ────────────────────────────────────────────────────────────────

  Future<List<CourseRecord>> listCourses() async {
    await ensureDir();
    final out = <CourseRecord>[];
    for (final d in coursesDir.listSync()..sort((a, b) => a.path.compareTo(b.path))) {
      if (d is! Directory) continue;
      final f = File(p.join(d.path, 'course.md'));
      if (!f.existsSync()) continue;
      final fm = _Frontmatter.parse(f.readAsStringSync());
      out.add(CourseRecord(
        id: fm['id'] ?? p.basename(d.path),
        title: fm['title'] ?? p.basename(d.path),
        platform: fm['platform'] ?? 'other',
        dir: d,
      ));
    }
    return out;
  }

  Future<CourseRecord> createCourse({
    required String title,
    String platform = 'other',
    String? sourceUrl,
  }) async {
    await ensureDir();
    final id = 'course-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    final dir = Directory(p.join(coursesDir.path, id));
    dir.createSync(recursive: true);
    Directory(p.join(dir.path, 'lessons')).createSync();
    final buf = StringBuffer('---\n')
      ..writeln('id: $id')
      ..writeln('title: $title')
      ..writeln('platform: $platform')
      ..writeln('created_at: ${DateTime.now().toIso8601String().substring(0, 10)}');
    if (sourceUrl != null && sourceUrl.isNotEmpty) {
      buf.writeln('source_url: $sourceUrl');
    }
    buf..writeln('---')..writeln()..writeln('# $title')..writeln();
    File(p.join(dir.path, 'course.md')).writeAsStringSync(buf.toString());
    return CourseRecord(id: id, title: title, platform: platform, dir: dir);
  }

  // ── 课时 ────────────────────────────────────────────────────────────────

  Future<List<LessonRecord>> listLessons(CourseRecord course) async {
    final dir = Directory(p.join(course.dir.path, 'lessons'));
    if (!dir.existsSync()) return const [];
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.md'))
        .toList()
      ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    final out = <LessonRecord>[];
    for (final f in files) {
      final fm = _Frontmatter.parse(f.readAsStringSync());
      out.add(LessonRecord(
        id: fm['id'] ?? p.basenameWithoutExtension(f.path),
        courseId: fm['course_id'] ?? course.id,
        idx: int.tryParse(fm['idx'] ?? '') ?? out.length + 1,
        title: fm['title'] ?? p.basenameWithoutExtension(f.path),
        captureRegion: fm['capture_region'],
        file: f,
      ));
    }
    return out;
  }

  Future<LessonRecord> createLesson(CourseRecord course, String title) async {
    final lessons = await listLessons(course);
    final idx = lessons.isEmpty ? 1 : (lessons.map((l) => l.idx).reduce((a, b) => a > b ? a : b) + 1);
    final safeTitle = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final id = '${course.id}-l$idx';
    final file = File(p.join(
        course.dir.path, 'lessons', '${idx.toString().padLeft(2, '0')}-$safeTitle.md'));
    file.writeAsStringSync('---\n'
        'id: $id\n'
        'course_id: ${course.id}\n'
        'idx: $idx\n'
        'title: $title\n'
        'status: watching\n'
        '---\n\n# $title\n');
    return LessonRecord(
      id: id,
      courseId: course.id,
      idx: idx,
      title: title,
      file: file,
      captureRegion: null,
    );
  }

  Future<void> setCaptureRegion(LessonRecord lesson, String region) async {
    final text = lesson.file.readAsStringSync();
    final updated = text.contains('capture_region:')
        ? text.replaceFirst(RegExp(r'capture_region:.*'), 'capture_region: "$region"')
        : text.replaceFirst('status:', 'capture_region: "$region"\nstatus:');
    lesson.file.writeAsStringSync(updated);
  }

  // ── 笔记 ────────────────────────────────────────────────────────────────

  /// 解析课时正文里的 `## <mm:ss> <要点>` 小节为笔记列表。
  static List<LessonNote> parseNotes(String body) {
    final notes = <LessonNote>[];
    final re = RegExp(r'^##\s+(?:(\d{1,2}:\d{2})\s+)?(.+)$', multiLine: true);
    for (final m in re.allMatches(body)) {
      final time = m.group(1);
      var point = m.group(2)?.trim() ?? '';
      if (point.isEmpty || point.startsWith('AI 草稿')) continue;
      // 小节体里的公式行 `- 公式：...` 归进该条笔记
      String? formula;
      final tail = body.substring(m.end);
      final next = re.allMatches(body).where((x) => x.start >= m.end).toList();
      final sectionBody = tail.substring(0, next.isEmpty ? tail.length : next.first.start - m.end);
      final fm2 = RegExp(r'公式[:：]\s*(.+)').firstMatch(sectionBody);
      if (fm2 != null) formula = fm2.group(1)?.trim();
      if (point.endsWith('：') || point.endsWith(':')) {
        point = point.substring(0, point.length - 1);
      }
      notes.add(LessonNote(time: time, point: point, formula: formula));
    }
    return notes;
  }

  /// 追加一条笔记；与已有笔记指纹重复则跳过。返回是否真的写入了。
  Future<bool> appendNote(LessonRecord lesson, LessonNote note) async {
    final text = lesson.file.existsSync()
        ? lesson.file.readAsStringSync()
        : '---\nid: ${lesson.id}\ncourse_id: ${lesson.courseId}\n---\n\n';
    final existing = parseNotes(text);
    if (existing.any((n) => n.fingerprint == note.fingerprint)) return false;
    final buf = StringBuffer(text);
    if (!text.endsWith('\n')) buf.writeln();
    buf.writeln();
    if (note.time != null) {
      buf.writeln('## ${note.time} ${note.point}');
    } else {
      buf.writeln('## ${note.point}');
    }
    if (note.formula != null && note.formula!.isNotEmpty) {
      buf.writeln('- 公式：${note.formula}');
    }
    lesson.file.writeAsStringSync(buf.toString());
    return true;
  }
}

/// 极简宽容 frontmatter 解析：`key: value` 行；值可带引号。
class _Frontmatter {
  static Map<String, String> parse(String text) {
    final out = <String, String>{};
    if (!text.startsWith('---')) return out;
    final end = text.indexOf('\n---', 3);
    if (end < 0) return out;
    for (final line in text.substring(3, end).split('\n')) {
      final i = line.indexOf(':');
      if (i <= 0) continue;
      var v = line.substring(i + 1).trim();
      if (v.length >= 2 && (v.startsWith('"') && v.endsWith('"'))) {
        v = v.substring(1, v.length - 1);
      }
      out[line.substring(0, i).trim()] = v;
    }
    return out;
  }
}
