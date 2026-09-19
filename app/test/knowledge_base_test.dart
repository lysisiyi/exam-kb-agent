/// 知识点本体的结构语义 + **真实数据契约**。
///
/// ## 这一组守的是"章节 0"那类事故
///
/// 缺陷长这样：`KnowledgeBase.chapters` 用 `level == 3` 找章节，而数一的
/// 章节在数据里标的是 level 2 → 页面显示「章节 0」，标注引擎的「章节保底」
/// 也**静默失效**（它遍历的正是这个列表）。
///
/// 621 个测试全绿却没发现它 —— 因为夹具按"文档里的约定"造（章节 level 3），
/// 与真实数据不一致。所以这里有两层：
///
/// 1. **合成夹具**：形状与 level 都刻意偏离，钉住"判据只看 id 结构"
/// 2. **真实数据**：直接读 `data/knowledge_points/*.json`，三科逐一校验
///    （数据不全时跳过，不把"环境不全"误报成"功能坏了"）
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/domain/knowledge/knowledge_point.dart';

import 'support/knowledge_fixture.dart';

/// 从仓库根目录定位数据文件（`flutter test` 的 cwd 是 `app/`）。
File? _findDataFile(String relative) {
  for (final base in ['..', '.']) {
    final f = File('$base/$relative');
    if (f.existsSync()) return f;
  }
  return null;
}

KnowledgeBase _loadReal(String subject) => KnowledgeBase.fromJson(
      (jsonDecode(
        _findDataFile('data/knowledge_points/$subject.json')!
            .readAsStringSync(),
      ) as Map)
          .cast<String, dynamic>(),
    );

void main() {
  group('结构判据：只看 id 段数，不看 level', () {
    test('章节 = id 第 3 段的非叶节点（level 写错也认得）', () {
      final kb = math1LikeKb();

      // 夹具里 math1.calc.limit 的 level 是 2（历史数据就是这样）
      expect(kb.byId['math1.calc.limit']!.level, 2);
      expect(
        kb.chapters.map((c) => c.id).toList(),
        ['math1.calc.diff', 'math1.calc.limit', 'math1.linalg.eigen'],
        reason: '按 level==3 判会得到 2 个，按 id 段数判是 3 个 —— '
            '而后者才是画像聚合用的口径（chapterId）',
      );
      expect(kb.chapters.length, 3);
    });

    test('isChapter / isSection / idDepth 与 id 一致', () {
      final kb = math1LikeKb();
      final limit = kb.byId['math1.calc.limit']!;
      final calc = kb.byId['math1.calc']!;
      final leaf = kb.byId['math1.calc.limit.taylor']!;

      expect(calc.isSection, isTrue);
      expect(limit.isSection, isFalse);
      expect(limit.isChapter, isTrue);
      expect(leaf.isChapter, isFalse);
      expect(leaf.isLeaf, isTrue);
      expect(limit.idDepth, 3);
      expect(leaf.idDepth, 4);
      // 每个章节的 chapterId 就是它自己 —— 画像按 chapterId 聚合才落得回目录
      for (final c in kb.chapters) {
        expect(c.id, c.chapterId);
      }
    });

    test('数三那种 5 层树：章节仍是第 3 段，「节」不算章节', () {
      final kb = math3LikeKb();
      expect(kb.chapters.map((c) => c.id).toList(), ['math3.calc.limit']);
      // 「节」是第 4 段的非叶节点：不是章节，但也不该被当成叶子
      final unit = kb.byId['math3.calc.limit.seq']!;
      expect(unit.isLeaf, isFalse);
      expect(unit.isChapter, isFalse);
      expect(unit.idDepth, 4);
      expect(kb.maxDepth, 5);
      expect(kb.leaves.length, 2);
    });

    test('topLevel 正常取科目根的直接子节点', () {
      final kb = math1LikeKb();
      expect(kb.topLevel.map((n) => n.id).toList(),
          ['math1.calc', 'math1.linalg']);
    });

    test('没有挂到根上的分段也能画出来（兜底）', () {
      final kb = orphanKb();
      expect(kb.root, isNotNull, reason: '空壳根节点本身是存在的');
      expect(kb.childrenOf['math2'], isNull);
      // 兜底：退到"没有父节点的节点"
      expect(kb.topLevel.map((n) => n.id).toList(),
          ['math2.calc', 'math2.linalg']);
      // 关键是叶子仍然能被找出来，而不是整棵树消失
      expect(kb.leafCountUnder('math2.calc'), 1);
    });

    test('leafCountUnder 递归数到底', () {
      final kb = math1LikeKb();
      expect(kb.leafCountUnder('math1'), 5);
      expect(kb.leafCountUnder('math1.calc'), 4);
      expect(kb.leafCountUnder('math1.calc.limit'), 3);
      expect(kb.leafCountUnder('math1.calc.limit.taylor'), 1);
      expect(kb.leafCountUnder('不存在'), 0);
    });
  });

  group('真实本体：三科的数据契约', () {
    final missing = _findDataFile('data/knowledge_points/math1.json') == null;

    for (final subject in ['math1', 'math2', 'math3']) {
      test('$subject：层级、父子、章节数与 level 约定', () {
        if (missing) {
          markTestSkipped('数据文件不存在（请在仓库根或 app/ 下运行测试）');
          return;
        }
        final kb = _loadReal(subject);
        expect(kb.nodes, isNotEmpty);

        // ① 只有一个根，且就是科目自己
        final roots =
            kb.nodes.where((n) => n.parentId == null).map((n) => n.id).toList();
        expect(roots, [subject],
            reason: '科目根应当唯一。多个根 = 有分段没挂上去（math3 曾如此），'
                '会让 App 的树遍历直接空掉');

        // ② 父节点必须存在；非叶必须有子；叶子不能有子
        final ids = kb.byId.keys.toSet();
        for (final n in kb.nodes) {
          if (n.parentId != null) {
            expect(ids.contains(n.parentId), isTrue,
                reason: '${n.id} 的 parent_id=${n.parentId} 不存在');
          }
          final kids = kb.childrenOf[n.id] ?? const <KnowledgePoint>[];
          if (n.isLeaf) {
            expect(kids, isEmpty, reason: '${n.id} 标成叶子却有子节点');
          } else {
            expect(kids, isNotEmpty, reason: '${n.id} 是非叶节点却没有任何子节点');
          }
          // ③ level 必须等于 id 段数（tools/data/normalize_ontology.py 维护）
          expect(n.level, n.idDepth,
              reason: '${n.id} 的 level=${n.level} 与 id 段数 ${n.idDepth} 不一致');
        }

        // ④ 章节数与叶子数 —— 这条就是"章节 0"的回归守卫
        expect(kb.chapters, isNotEmpty, reason: '$subject 一个章节都没有');
        expect(kb.leaves, isNotEmpty);

        // ⑤ 每个叶子都能从根走到（没有游离的叶子）
        final reachable = kb.leafIdsUnder(subject).toSet();
        expect(reachable.length, kb.leaves.length,
            reason: '$subject 有 ${kb.leaves.length - reachable.length} 个叶子'
                '从科目根走不到');

        // ⑥ 章节的 chapterId 就是它自己（画像聚合与目录导航同义）
        for (final c in kb.chapters) {
          expect(c.id, c.chapterId);
        }
      });
    }

    test('三科的章节数与考频层数符合实测（19 / 11 / 20）', () {
      if (missing) {
        markTestSkipped('数据文件不存在');
        return;
      }
      final counts = {
        for (final s in ['math1', 'math2', 'math3'])
          s: _loadReal(s).chapters.length,
      };
      expect(counts, {'math1': 19, 'math2': 11, 'math3': 20},
          reason: '数与 data/exam_frequency.json 的覆盖率一致；'
              '变化时请确认是有意调整本体，而不是又踩了 level 的坑');
    });
  });
}
