/// 知识库字号刻度 + "量的必须装得下排的" 两组不变量。
///
/// ## 为什么这两件事要单独守
///
/// ### 1. 字号刻度
///
/// 用户反馈「知识库图谱的字尺寸深浅不一且公式过小」。根因不是某一处写错，
/// 而是**同一屏里混了 4 种字号、全是散落的字面量**，且没有一个是按可读性
/// 定的。把刻度收口到 `KnowledgeSizes` 之后，需要测试钉住"这几档不再被
/// 调回去"—— 否则下一次有人在某个 widget 里写 `fontSize: 11`，
/// 同样的反馈会再来一遍。
///
/// ### 2. 量排同源
///
/// 图谱的列宽是**量出来的**（布局阶段），节点文字是**排出来的**（渲染阶段）。
/// 两边只要有任何一处不同源（字号、字重、字体链、内边距、是否计入徽标），
/// 症状都是同一个：**名字被省略号吃掉一截**，而用户看不到原因。
///
/// 所以这里不做"渲染截图对比"（测试字体是 Ahem，截图没有意义），
/// 而是直接断言**几何关系**：布局给出的宽度必须装得下渲染要放的内容。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/core/math/katex_renderer.dart';
import 'package:kaoyan_math_agent/core/math/math_renderer.dart';
import 'package:kaoyan_math_agent/core/theme/app_theme.dart';
import 'package:kaoyan_math_agent/domain/knowledge/knowledge_point.dart';
import 'package:kaoyan_math_agent/features/knowledge/knowledge_formula_row.dart';
import 'package:kaoyan_math_agent/features/knowledge/knowledge_graph_layout.dart';
import 'package:kaoyan_math_agent/features/knowledge/knowledge_graph_view.dart';
import 'package:kaoyan_math_agent/features/knowledge/knowledge_leaf_detail.dart';
import 'package:kaoyan_math_agent/features/knowledge/knowledge_sizes.dart';

import 'support/knowledge_fixture.dart';

/// 确定性测量：中文算 1em、其余算 0.58em，按 [TextStyle.fontSize] 缩放。
double measure(String text, TextStyle style) {
  final size = style.fontSize ?? KnowledgeSizes.title;
  var w = 0.0;
  for (final r in text.runes) {
    w += r > 0x2E80 ? size : size * 0.58;
  }
  return w;
}

KnowledgeGraph layout(KnowledgeBase kb, {GraphStyle style = const GraphStyle()}) =>
    buildKnowledgeGraph(kb, measure: measure, style: style);

/// 载入真实本体。文件不存在时返回 null（用例自行 skip）。
KnowledgeBase? loadRealKb(String subject) {
  final f = File('../data/knowledge_points/$subject.json');
  if (!f.existsSync()) return null;
  return KnowledgeBase.fromJson(
    (jsonDecode(f.readAsStringSync()) as Map).cast<String, dynamic>(),
  );
}

void main() {
  // ── 1. 刻度本身 ────────────────────────────────────────────────────────
  group('字号刻度', () {
    test('四档从大到小有序，不多不少', () {
      expect(KnowledgeSizes.heading, greaterThan(KnowledgeSizes.title));
      expect(KnowledgeSizes.title, greaterThan(KnowledgeSizes.body));
      expect(KnowledgeSizes.body, greaterThan(KnowledgeSizes.secondary));
    });

    test('图谱节点名不得小于应用正文（这是"图谱字太小"的直接防线）', () {
      // 图谱节点是"要读的目录文字"，比应用正文还小是说不通的
      expect(KnowledgeSizes.title,
          greaterThanOrEqualTo(AppTypography.body.fontSize!),
          reason: '图谱节点名 ${KnowledgeSizes.title}px'
              ' < 应用正文 ${AppTypography.body.fontSize}px');
    });

    test('详情正文不低于中文长文可读下限 13', () {
      expect(KnowledgeSizes.body, greaterThanOrEqualTo(13));
    });

    test('次要信息不低于 12（改前是 10.5/11，那才是"过小"）', () {
      expect(KnowledgeSizes.secondary, greaterThanOrEqualTo(12));
    });

    test('公式的逐字阅读档不低于 16', () {
      // KaTeX 上下标只有主字号的 70%：16px → 11.2px（能读）
      expect(AppMathSizes.reading, greaterThanOrEqualTo(16),
          reason: '上下标会缩到 ${(AppMathSizes.reading * 0.7).toStringAsFixed(1)}px');
      expect(AppMathSizes.display, greaterThan(AppMathSizes.reading));
    });
  });

  // ── 2. 图谱：层级不靠字号 ──────────────────────────────────────────────
  group('图谱：层级靠字重表达，不靠字号', () {
    const style = GraphStyle();

    test('所有节点角色共用同一个字号', () {
      final sizes = {
        for (final k in GraphNodeKind.values) style.textStyleOf(k).fontSize
      };
      expect(sizes.length, 1,
          reason: '图谱里出现了多种节点字号 $sizes —— '
              '这就是用户说的"字尺寸深浅不一"。层级请用字重/颜色表达');
    });

    test('叶子与分支的字重必须不同（层级仍然看得出来）', () {
      expect(style.fontWeightOf(GraphNodeKind.leaf),
          isNot(style.fontWeightOf(GraphNodeKind.chapter)));
    });

    test('节点文字必须带字体链（否则量与排不同源）', () {
      for (final k in GraphNodeKind.values) {
        final s = style.textStyleOf(k);
        expect(s.fontFamily, isNotNull,
            reason: '$k 的节点样式没有 fontFamily —— '
                '量宽用的 TextPainter 没得继承，会落到平台默认字体上');
        expect(s.fontFamilyFallback, isNotEmpty);
      }
      expect(style.weightStyle.fontFamily, isNotNull);
    });

    test('只请求字体族里真实存在的字重（Regular / Bold）', () {
      // 依据：解析 `msyh.ttc` / `msyhbd.ttc` 的名字表得到 ——
      // `Microsoft YaHei UI` 这个族**只有 Regular(400) 与 Bold(700)**，
      // 没有 500、没有 600（Light 是独立族名）。
      // 写 w500 会被引擎静默近似成 Regular、写 w600 近似成 Bold，
      // 于是"代码写的"和"实际渲染的"不是一回事。
      // 用字重的数值比较：`FontWeight` 没有原始相等性，没法放进 const Set
      const allowed = {400, 700};
      for (final k in GraphNodeKind.values) {
        expect(allowed, contains(style.fontWeightOf(k).value),
            reason: '$k 请求了 w${style.fontWeightOf(k).value} —— 这个字重不存在');
      }
      expect(allowed, contains(style.weightStyle.fontWeight!.value));
    });

    test('同一行里名字与考频徽标必须同字重（不许"名字轻、徽标重"）', () {
      // 实测依据：用户给的截图上，考频数字（0.76 / 0.96）比它左边的名字
      // 更"实" —— 一行之内一小一大、一轻一重，是"深浅不一"的另一种形态。
      // 考频的强调交给颜色（weightInk），不交给字重。
      expect(style.weightStyle.fontWeight,
          style.textStyleOf(GraphNodeKind.leaf).fontWeight,
          reason: '叶子行里名字 ${style.textStyleOf(GraphNodeKind.leaf).fontWeight} '
              '而徽标 ${style.weightStyle.fontWeight} —— 同一行两种字重');
    });
  });

  // ── 2b. 源码级护栏：知识库视图不得再写不存在的字重 ─────────────────────
  group('字重：知识库视图只允许 w400 / w700', () {
    test('源码里不得出现 w500 / w600 之类的字重', () {
      // 为什么用"扫源码"这种办法：字重是写在各 widget 里的散落字面量，
      // 运行时枚举不到。而这条约束是**关于代码怎么写**的，
      // 所以扫源码正是对的工具 —— 否则下一次有人在某个新 widget 里
      // 写一句 `fontWeight: FontWeight.w600`，字体就会静默变成 Bold。
      final dir = Directory('lib/features/knowledge');
      expect(dir.existsSync(), isTrue,
          reason: '找不到 ${dir.path} —— 测试的工作目录应当是 app/');

      final bad = <String>[];
      final re = RegExp(r'FontWeight\.w(\d{3})');
      for (final f in dir.listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final lines = f.readAsStringSync().split('\n');
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          // 注释里提到某个字重不算违规 —— 只在代码行上判
          if (line.trimLeft().startsWith('//')) continue;
          for (final m in re.allMatches(line)) {
            final v = m.group(1);
            if (v != '400' && v != '700') {
              bad.add('${f.path}:${i + 1}  FontWeight.w$v');
            }
          }
        }
      }
      expect(bad, isEmpty,
          reason: '这些位置请求了字体族里不存在的字重：\n${bad.join('\n')}\n'
              'Microsoft YaHei UI 只有 Regular(w400) 与 Bold(w700)。'
              '要"半粗"必须换字体族，本项目的原则是只用系统自带字体。');
    });
  });

  // ── 3. 图谱：行高必须跟住节点高 ────────────────────────────────────────
  group('图谱：行高不得与字号脱钩', () {
    test('任意字号下，行高都大于节点高（否则同列相邻节点会重叠）', () {
      for (final fs in [10.0, 12.0, 14.0, 18.0, 24.0]) {
        final s = GraphStyle(fontSize: fs);
        expect(s.rowHeight, greaterThan(s.nodeHeight),
            reason: '字号 $fs 时 rowHeight=${s.rowHeight} '
                '<= nodeHeight=${s.nodeHeight} —— 文字会压在一起');
      }
    });

    test('改字号不必改行高：行高自动跟着走', () {
      const small = GraphStyle(fontSize: 12);
      const big = GraphStyle(fontSize: 18);
      expect(big.rowHeight, greaterThan(small.rowHeight));
    });

    test('画布高度随字号增长（缩放的量纲正确）', () {
      final kb = math1LikeKb();
      final small = layout(kb, style: const GraphStyle(fontSize: 12));
      final big = layout(kb, style: const GraphStyle(fontSize: 18));
      expect(big.size.height, greaterThan(small.size.height));
    });
  });

  // ── 4. 图谱：量的必须装得下排的 ────────────────────────────────────────
  group('图谱：布局宽度必须装得下渲染内容', () {
    test('节点宽装得下「名字 + 考频徽标」（早先漏算徽标 → 名字被截断）', () {
      const style = GraphStyle();
      final kb = math1LikeKb();
      final g = buildKnowledgeGraph(kb, measure: measure, style: style);

      var checkedWithWeight = 0;
      for (final n in g.nodes) {
        var need =
            measure(n.point.name, style.textStyleOf(n.kind)) + style.paddingH * 2;

        final w = n.point.examWeight;
        final isLeaf = n.kind == GraphNodeKind.leaf;
        if (isLeaf && w != null) {
          need += style.weightGap +
              measure(w.toStringAsFixed(2), style.weightStyle);
          checkedWithWeight++;
        }

        // 要么装得下，要么已经顶到宽度上限（此时是刻意的省略号 + 悬停提示）
        final hitCap = n.rect.width >= style.maxNodeWidth - 0.001;
        expect(n.rect.width + 0.001 >= need || hitCap, isTrue,
            reason: '${n.id}：节点宽 ${n.rect.width} 装不下所需 $need'
                '（含考频徽标）—— 名字会被省略号吃掉一截');
      }
      expect(checkedWithWeight, greaterThan(0),
          reason: '样本里没有"带考频的叶子"，这条用例等于没测');
    });

    testWidgets('图谱节点**渲染出来**的字号就是刻度值（不是另一处字面量）',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: KnowledgeGraphView(kb: math1LikeKb())),
      ));
      await tester.pumpAndSettle();

      // 布局用 measure 量的是 GraphStyle.textStyleOf，渲染必须也是它。
      // 两边一旦不同源（改前是 12 对 12.5），名字就会被省略号吃掉一截。
      for (final name in ['泰勒公式求极限', '极限与连续', '等价无穷小替换']) {
        final found = find.byWidgetPredicate((w) => w is Text && w.data == name);
        expect(found, findsOneWidget, reason: '图谱里找不到节点「$name」');
        final t = tester.widget<Text>(found);
        expect(t.style?.fontSize, KnowledgeSizes.title,
            reason: '节点「$name」渲染字号 ${t.style?.fontSize} '
                '≠ 布局使用的 ${KnowledgeSizes.title}');
      }
    });

    test('节点宽度不超过上限，也不小于下限', () {
      const style = GraphStyle();
      final g = layout(math1LikeKb(), style: style);
      for (final n in g.nodes) {
        expect(n.rect.width, greaterThanOrEqualTo(style.minNodeWidth - 0.001));
        expect(n.rect.width, lessThanOrEqualTo(style.maxNodeWidth + 0.001));
      }
    });

    test('顶到宽度上限（名字被截断）的节点占比不得失控', () {
      final kb = loadRealKb('math1');
      if (kb == null) {
        markTestSkipped('数据文件不存在');
        return;
      }
      const style = GraphStyle();
      final g = buildKnowledgeGraph(kb, measure: measure, style: style);

      var capped = 0;
      for (final n in g.nodes) {
        var need =
            measure(n.point.name, style.textStyleOf(n.kind)) + style.paddingH * 2;
        final w = n.point.examWeight;
        if (n.kind == GraphNodeKind.leaf && w != null) {
          need += style.weightGap +
              measure(w.toStringAsFixed(2), style.weightStyle);
        }
        if (need > style.maxNodeWidth) capped++;
      }

      // 这条断言是**给未来改字号的人**的护栏：
      // 字号一旦往上调、`maxNodeWidth` 没跟上，被省略号吃掉的名字就会
      // 成倍增加。实测（math1 真实数据）：
      //
      //   12px / 上限 210（改前）  → 11/164 = 6.7%
      //   14px / 上限 210          → 40/164 = 24.4%   ← 只改字号不加上限的后果
      //   14px / 上限 240（现状）  → 11/164 = 6.7%   ← 与改前持平
      //
      // 阈值取 10%：能放过现状、能拦住"忘了调上限"。
      final ratio = capped / g.nodes.length;
      expect(ratio, lessThan(0.10),
          reason: '${(ratio * 100).toStringAsFixed(1)}%（$capped/${g.nodes.length}）'
              '的节点名超出宽度上限会被截断 —— '
              '调大字号时请同步调大 maxNodeWidth（${style.maxNodeWidth}）');
    });
  });

  // ── 5. 详情卡：调用点不得覆盖公式字号 ──────────────────────────────────
  group('详情卡：公式字号只有一个来源', () {
    testWidgets('同一张卡里，核心公式与别名公式的字号必须一致', (tester) async {
      final kb = loadRealKb('math1');
      if (kb == null) {
        markTestSkipped('数据文件不存在');
        return;
      }
      MathRendering.install(const KatexRenderer());
      addTearDown(MathRendering.reset);

      // 挑一个既有核心公式、又有 LaTeX 符号别名的知识点 ——
      // 「一大一小」这个缺陷正是发生在这两种公式同框的时候
      final leaf = kb.byId['math1.calc.limit.seq']!;

      tester.view.physicalSize = const Size(900, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: KnowledgeLeafDetail(leaf: leaf)),
        ),
      ));
      await tester.pumpAndSettle();

      final rows = find
          .byType(KnowledgeFormulaRow)
          .evaluate()
          .map((e) => e.widget as KnowledgeFormulaRow)
          .toList();

      expect(rows.length, greaterThan(1),
          reason: '需要"核心公式 + 别名公式"同时存在才能测出不一致');

      final sizes = rows.map((r) => r.fontSize).toSet();
      expect(sizes, {kFormulaFontSize},
          reason: '同一张卡里出现了 ${sizes.length} 种公式字号 $sizes —— '
              '调用点又覆盖了 `kFormulaFontSize`($kFormulaFontSize)');

      // 顺带钉住常识：公式不该比卡片里的正文（body=13）还小
      expect(sizes.single, greaterThan(KnowledgeSizes.body));
    });
  });
}
