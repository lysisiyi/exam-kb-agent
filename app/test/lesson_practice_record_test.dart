/// 课时练习记录落 papers（P3）：仓库往返 + 历史判别键。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/services/paper/paper_repository.dart';

import 'support/test_env.dart';

void main() {
  test('savePractice：落库、历史可见、config 带判别键与对错', () async {
    final env = await TempLibrary.create();
    addTearDown(env.dispose);

    final repo = PaperRepository(db: env.db);
    await repo.savePractice(
      title: '课时练习 · 第5讲 特征值',
      subject: 'math1',
      problemIds: const ['p-1', 'p-2', 'p-3'],
      rightCount: 2,
      wrongCount: 1,
      now: DateTime(2026, 10, 5, 10),
    );

    final rows = await repo.history();
    expect(rows.length, 1);
    final r = rows.first;
    expect(r.title, contains('第5讲'));
    expect(r.config, contains('"kind":"lesson_practice"'));
    expect(r.config, contains('"right":2'));
    expect(r.config, contains('"wrong":1'));
    expect(r.items, contains('p-2'));
    expect(r.totalScore, isNull, reason: '练习没有满分概念');
  });

  test('微秒精度：相差 1µs 的两条记录也不撞主键', () async {
    final env = await TempLibrary.create();
    addTearDown(env.dispose);
    final repo = PaperRepository(db: env.db);
    final t0 = DateTime(2026, 10, 5, 10);
    await repo.savePractice(
        title: 'a', subject: 'math1', problemIds: const [],
        rightCount: 0, wrongCount: 0, now: t0);
    // ⚠️ 同一毫秒内的两次保存是真实场景（连点/快速连续）；id 用微秒正是
    // 为此。相差 1µs 就必须落成两条 —— 撞主键会让用户看到 SQL 报错。
    await repo.savePractice(
        title: 'b', subject: 'math1', problemIds: const [],
        rightCount: 0, wrongCount: 0,
        now: t0.add(const Duration(microseconds: 1)));
    expect((await repo.history()).length, 2);
  });
}
