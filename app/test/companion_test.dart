/// 伴学管道的纯逻辑测试：课程/课时 Markdown 读写、笔记解析与去重、
/// 感知哈希与跳帧判定、结构化笔记解析。平台截屏本身不可测（见接口注释）。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:kaoyan_math_agent/services/companion/course_store.dart';
import 'package:kaoyan_math_agent/services/companion/note_llm.dart';
import 'package:kaoyan_math_agent/services/companion/screen_capture.dart';

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('companion-test');
  });
  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  group('CourseStore', () {
    test('建课 → 建课时 → 追加笔记 → 解析回读（roundtrip）', () async {
      final store = CourseStore(coursesDir: Directory('${tmp.path}/courses'));
      final course = await store.createCourse(title: '线性代数基础班', platform: 'bilibili');
      expect(course.id, startsWith('course-'));
      expect(course.dir.existsSync(), isTrue);

      final lesson = await store.createLesson(course, '第5讲 特征值与特征向量');
      expect(lesson.idx, 1);
      expect(lesson.file.existsSync(), isTrue);

      expect(await store.appendNote(
          lesson, const LessonNote(time: '12:31', point: '特征值的定义', formula: r'A\mathbf{x}=\lambda\mathbf{x}')),
          isTrue);
      expect(await store.appendNote(
          lesson, const LessonNote(point: '先写定义式再变形')),
          isTrue);

      final notes = CourseStore.parseNotes(lesson.file.readAsStringSync());
      expect(notes.length, 2);
      expect(notes[0].time, '12:31');
      expect(notes[0].point, '特征值的定义');
      expect(notes[0].formula, contains(r'\lambda'));
      expect(notes[1].time, isNull);
      expect(notes[1].point, '先写定义式再变形');
    });

    test('重复笔记按指纹去重（大小写/空白/标点不敏感）', () async {
      final store = CourseStore(coursesDir: Directory('${tmp.path}/courses'));
      final course = await store.createCourse(title: '测试课');
      final lesson = await store.createLesson(course, '第1讲');
      expect(await store.appendNote(lesson, const LessonNote(point: '相似对角化的条件')), isTrue);
      expect(await store.appendNote(lesson, const LessonNote(point: '相似对角化的条件。')), isFalse);
      expect(await store.appendNote(lesson, const LessonNote(point: '相似对角化 的条件')), isFalse);
      final notes = CourseStore.parseNotes(lesson.file.readAsStringSync());
      expect(notes.length, 1);
    });

    test('课时按 idx 排序、新建课时递增、capture_region 可写回', () async {
      final store = CourseStore(coursesDir: Directory('${tmp.path}/courses'));
      final course = await store.createCourse(title: '测试课');
      final l1 = await store.createLesson(course, '第一讲');
      final l2 = await store.createLesson(course, '第二讲');
      expect(l2.idx, 2);
      await store.setCaptureRegion(l1, '100,80,960,540');

      final lessons = await store.listLessons(course);
      expect(lessons.map((l) => l.idx), [1, 2]);
      expect(lessons.first.captureRegion, '100,80,960,540');
    });
  });

  group('CaptureRect', () {
    test('解析宽容：坏串/过小返回 null', () {
      expect(CaptureRect.tryParse('10,20,960,540'), isNotNull);
      expect(CaptureRect.tryParse(null), isNull);
      expect(CaptureRect.tryParse('a,b,c,d'), isNull);
      expect(CaptureRect.tryParse('10,20,10,10'), isNull, reason: '过小区域没有意义');
      expect(CaptureRect.tryParse('10,20,960,540').toString(), '10,20,960,540');
    });
  });

  group('感知哈希与跳帧', () {
    Uint8List jpegOf(int seed) {
      final image = img.Image(width: 200, height: 150);
      for (var y = 0; y < 150; y++) {
        for (var x = 0; x < 200; x++) {
          image.setPixel(x, y, img.ColorRgb8(
            (x * 2 + seed) % 256, (y + seed) % 256, (x + y + seed) % 256));
        }
      }
      return Uint8List.fromList(img.encodeJpg(image, quality: 90));
    }

    test('同一画面编码两次哈希相同；不同画面距离大', () {
      final a = jpegOf(7);
      expect(aHashOfJpeg(a), aHashOfJpeg(a));
      final d = hammingDistance(aHashOfJpeg(jpegOf(7)), aHashOfJpeg(jpegOf(180)));
      expect(d, greaterThan(6), reason: '两张差异明显的图不应被判成"画面没换"');
    });

    test('frameUnchanged：相同/近似跳过，首帧不跳（lastHash=0）', () {
      final h = aHashOfJpeg(jpegOf(3));
      expect(frameUnchanged(0, h), isFalse, reason: '首帧必须真的去调一次 AI');
      expect(frameUnchanged(h, h), isTrue);
    });

    test('cropFrame 按区域裁剪并返回新尺寸', () {
      final frame = CapturedFrame(jpegOf(1), 200, 150);
      final cropped = cropFrame(frame, const CaptureRect(10, 10, 100, 80));
      expect(cropped.width, 100);
      expect(cropped.height, 80);
      // 越界自动收缩
      final clipped = cropFrame(frame, const CaptureRect(150, 100, 200, 200));
      expect(clipped.width, lessThanOrEqualTo(50));
      expect(clipped.height, lessThanOrEqualTo(50));
    });
  });

  group('parseCompanionNotes', () {
    test('标准 JSON：notes 列表', () {
      final notes = parseCompanionNotes(
          '{"notes":[{"time":"12:31","point":"特征值的定义","formula":"Ax=λx"},{"point":"先写定义式再变形"}]}');
      expect(notes.length, 2);
      expect(notes[0].time, '12:31');
      expect(notes[0].formula, 'Ax=λx');
      expect(notes[1].time, isNull);
    });

    test('宽容：markdown 包裹 / 顶层数组 / 空列表 / 垃圾文本', () {
      expect(parseCompanionNotes('```json\n{"notes":[]}\n```'), isEmpty);
      expect(parseCompanionNotes('[{"point":"直接给数组也认"}]'), hasLength(1));
      expect(parseCompanionNotes('{"notes":[{"point":""}]}'), isEmpty,
          reason: '空要点丢弃');
      expect(parseCompanionNotes('模型抽风说了一堆人话'), isEmpty);
    });
  });
}
