/// 题目以图当题面（cover_image）：索引填充 + 列表/预览展示的接线。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/data/index/index_builder.dart';

import 'support/test_env.dart';

void main() {
  test('index_builder：images_primary 的题写入 cover_image；文字题不写', () async {
    final env = await TempLibrary.create();
    addTearDown(env.dispose);
    await seedProblems(env, [
      const SeedProblem(
          id: 'scan-1',
          stem: '扫描题（OCR 文本）',
          images: ['scan-1-1.png'],
          imagesPrimary: true),
      const SeedProblem(
          id: 'text-1',
          stem: '文字题',
          images: ['text-1-fig.png'],
          imagesPrimary: false),
    ]);
    await IndexBuilder(db: env.db, store: env.store).rebuild();

    final rows = await env.db.select(env.db.problemsIndex).get();
    final byId = {for (final r in rows) r.id: r};
    expect(byId['scan-1']!.coverImage, 'scan-1-1.png');
    expect(byId['text-1']!.coverImage, isNull,
        reason: '文字题即使配示意图也不当题面（免得列表被示意图占领）');
  });
}
