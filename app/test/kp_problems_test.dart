/// `MasteryService.problemsForKp` 的行为测试（P1-1「你的题目」的数据层）。
///
/// ## 口径钉在这里
///
/// 主考点命中的题进 [KpProblems.primary]；仅次考点关联的进
/// [KpProblems.secondary]（UI 折叠）；悬空关联（题已删、索引行已没、
/// 关联行还在）跳过而不是让清单挂掉；掌握度与画像同一函数**现算**
/// （没复习过是 null，不是 0）；排序 = 错次多在前 → 掌握度低在前 → id。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/domain/fsrs/fsrs_scheduler.dart';
import 'package:kaoyan_math_agent/services/library/problem_service.dart';
import 'package:kaoyan_math_agent/services/profile/mastery_service.dart';
import 'package:kaoyan_math_agent/services/review/review_repository.dart';

import 'support/test_env.dart';

/// 主考点 math1.calc.limit + 次考点 math1.calc.deriv，带错因。
const _mdA = '''
---
id: p-a
fingerprint: fp-a
subject: math1
qtype: solve
difficulty: 2
error_causes: [concept, calc]
created_at: 2026-01-01
knowledge:
  - id: math1.calc.limit
    role: primary
    relevance: 1.0
  - id: math1.calc.deriv
    role: secondary
    relevance: 1.0
---

## 题干

求极限。
''';

/// 只有主考点 math1.calc.limit。
const _mdB = '''
---
id: p-b
fingerprint: fp-b
subject: math1
qtype: fill
difficulty: 1
created_at: 2026-01-02
knowledge:
  - id: math1.calc.limit
    role: primary
    relevance: 1.0
---

## 题干

求导数。
''';

void main() {
  late TempLibrary env;
  late MasteryService svc;

  setUp(() async {
    env = await TempLibrary.create();
    for (final (name, md) in [('a.md', _mdA), ('b.md', _mdB)]) {
      File('${env.paths.problems.path}/$name')
        ..createSync(recursive: true)
        ..writeAsStringSync(md, flush: true);
    }
    await env.reindex();
    svc = MasteryService(db: env.db, scheduler: FsrsScheduler(enableFuzzing: false));
  });

  tearDown(() => env.dispose());

  test('主考点命中进 primary，错因从索引列解出', () async {
    final r = await svc.problemsForKp('math1.calc.limit');
    expect(r.primary.map((e) => e.id).toSet(), {'p-a', 'p-b'});
    expect(r.secondary, isEmpty, reason: '两题的主考点都是 limit');
    // 错因来自 problems_index.error_causes（题目属性，不是状态）
    final a = r.primary.firstWhere((e) => e.id == 'p-a');
    expect(a.errorCauses, ['concept', 'calc']);
    expect(a.errorCauses.contains('calc'), isTrue);
  });

  test('仅次考点关联的题进 secondary，不进 primary', () async {
    final r = await svc.problemsForKp('math1.calc.deriv');
    expect(r.primary, isEmpty);
    expect(r.secondary.map((e) => e.id), ['p-a']);
  });

  test('没复习过的题 mastery 是 null（"未复习"），不是 0', () async {
    final r = await svc.problemsForKp('math1.calc.limit');
    expect(r.primary.every((e) => e.mastery == null), isTrue,
        reason: 'null = 没有可谈的掌握度；0 = 完全不会，两者不能压成一个数');
  });

  test('评分后：错次与掌握度现算，且错次多的排前面', () async {
    final repo = ReviewRepository(db: env.db, store: env.store);
    final t0 = DateTime(2026, 6, 1, 9);
    await repo.grade(problemId: 'p-a', rating: Rating.forgot, now: t0);
    await repo.grade(problemId: 'p-a', rating: Rating.forgot, now: t0);

    final r = await svc.problemsForKp('math1.calc.limit', now: t0);
    expect(r.primary.first.id, 'p-a', reason: '错 2 次的排最前');
    expect(r.primary.first.wrongCount, 2);
    expect(r.primary.first.mastery, isNotNull);
    // 同一时点现算的掌握度低于没复习的默认排序值 —— p-b 在后
    expect(r.primary.last.id, 'p-b');
  });

  test('悬空关联跳过：题删了、关联行还在时清单不挂也不显示', () async {
    final service = ProblemService(db: env.db, store: env.store, knowledge: null);
    final gone = await service.delete('p-b');
    expect(gone, isTrue);

    // 不重建索引 —— problem_knowledge 里 p-b 的关联行还在。
    // _loadKpProblemEntries 查不到索引行，必须跳过而不是崩。
    final r = await svc.problemsForKp('math1.calc.limit');
    expect(r.primary.map((e) => e.id), ['p-a']);
  });

  test('两个考点都没有题时空结果', () async {
    final r = await svc.problemsForKp('math1.prob.rv');
    expect(r.isEmpty, isTrue);
  });

  test('同一题把同一个考点同时挂成主+次时只出现一次', () async {
    // 手改过 frontmatter 的题库什么都有可能造出这种双行 ——
    // 口径必须稳定：primary 优先，折叠区**不放**已经出现在主清单里的题，
    // 否则同一道题在同一个考点下显示两遍。
    final md = _mdB
        .replaceFirst('fingerprint: fp-b', 'fingerprint: fp-c')
        .replaceFirst('id: p-b', 'id: p-c')
        .replaceFirst(
            '    relevance: 1.0\n---',
            '    relevance: 1.0\n'
                '  - id: math1.calc.limit\n'
                '    role: secondary\n'
                '    relevance: 1.0\n---');
    File('${env.paths.problems.path}/c.md')
      ..createSync(recursive: true)
      ..writeAsStringSync(md, flush: true);
    await env.reindex();

    final limit = await svc.problemsForKp('math1.calc.limit');
    expect(limit.primary.map((e) => e.id).toSet(), {'p-a', 'p-b', 'p-c'});
    expect(limit.secondary, isEmpty,
        reason: 'p-c 对 limit 既是主又是次 —— 主清单已在，折叠区不得重复');
  });
}