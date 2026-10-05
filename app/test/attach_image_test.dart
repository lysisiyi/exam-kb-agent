/// 来源原图随题入库（V2）的服务层测试。
///
/// 验收口径：图像识别/批量导入的扫描题入库后，`images` 非空且
/// `images_primary: true` 写进 frontmatter、图片文件真实存在于
/// `images/` —— 否则复习与详情页的「图当题面」分支永远没有数据。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/data/problem_file.dart';
import 'package:kaoyan_math_agent/domain/problem_draft.dart';
import 'package:kaoyan_math_agent/services/library/problem_service.dart';

import 'support/test_env.dart';

ProblemDraft _draft(String id, String stem) {
  final d = ProblemDraft(id: id, subject: 'math1', stem: stem);
  return d;
}

void main() {
  late TempLibrary env;
  late ProblemService service;

  setUp(() async {
    env = await TempLibrary.create();
    service = ProblemService(db: env.db, store: env.store, knowledge: null);
  });

  tearDown(() => env.dispose());

  test('保存时附带来源原图：文件落盘 + frontmatter 写入 images/images_primary',
      () async {
    final bytes = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]);

    final outcome = await service.save(
      _draft('p-1', '一道扫描题'),
      attachImages: [bytes],
      attachImagesPrimary: true,
      attachImageExt: 'png',
    );

    expect(outcome.ok, isTrue, reason: outcome.error);
    final img = File('${env.paths.images.path}/p-1-0.png');
    expect(img.existsSync(), isTrue, reason: '图片必须真实落盘');
    expect(img.readAsBytesSync(), bytes);

    final read = await readIndexedProblem(
      db: env.db,
      store: env.store,
      problemId: 'p-1',
    );
    expect(read.problem!.images, ['images/p-1-0.png']);
    expect(read.problem!.imagesPrimary, isTrue,
        reason: '扫描题默认"图当题面"——复习与详情的图主分支靠它');
  });

  test('草稿自带图片时附带参数被忽略（手插图优先）', () async {
    final outcome = await service.save(
      _draft('p-2', '手插图题')..images.add('images/manual.png'),
      attachImages: [Uint8List.fromList([1, 2, 3])],
      attachImagesPrimary: true,
    );
    expect(outcome.ok, isTrue);
    expect(
      File('${env.paths.images.path}/p-2-0.png').existsSync(),
      isFalse,
      reason: '不该写 attach 的图',
    );
  });

  test('不传附带参数：行为与之前完全一致（不写 images frontmatter）', () async {
    final outcome = await service.save(_draft('p-3', '纯文字题'));
    expect(outcome.ok, isTrue);
    final read = await readIndexedProblem(
      db: env.db,
      store: env.store,
      problemId: 'p-3',
    );
    expect(read.problem!.images, isEmpty);
    expect(read.problem!.imagesPrimary, isFalse);
  });
}
