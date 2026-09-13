/// M4 录入界面的 widget 层测试。
///
/// ## 测什么、不测什么
///
/// 测**纯逻辑部分**（插入策略、搜索排序），因为那才是会出错的地方；
/// 不测"按钮长什么样"—— 那种测试只会随样式改动不停变红，不提供保护。
///
/// 插入逻辑特意做成不依赖 Widget 树的顶层函数
/// （[insertFormulaSnippet] / [wrapSelection]），所以能直接断言光标位置。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/domain/knowledge/knowledge_point.dart';
import 'package:kaoyan_math_agent/features/entry/widgets/formula_keyboard.dart';
import 'package:kaoyan_math_agent/features/entry/widgets/kp_picker.dart';

KnowledgePoint _leaf(
  String id,
  String name, {
  List<String> aliases = const [],
  double? weight,
  int years = 0,
}) =>
    KnowledgePoint(
      id: id,
      name: name,
      level: 4,
      parentId: id.split('.').take(3).join('.'),
      isLeaf: true,
      aliases: aliases,
      examWeight: weight,
      definition: '关于$name的定义。',
      examYears: List.generate(years, (i) => 2000 + i),
    );

KnowledgeBase _kb() => KnowledgeBase(
      subject: 'math1',
      subjectName: '数学一',
      version: 't',
      nodes: [
        const KnowledgePoint(id: 'math1', name: '数学一', level: 1, isLeaf: false),
        const KnowledgePoint(
            id: 'math1.prob', name: '概率论', level: 2,
            parentId: 'math1', isLeaf: false),
        const KnowledgePoint(
            id: 'math1.prob.rv1', name: '随机变量', level: 3,
            parentId: 'math1.prob', isLeaf: false),
        _leaf('math1.prob.rv1.normal', '正态分布及其标准化计算',
            aliases: ['正态分布', r'X\sim N(\mu,\sigma^2)'],
            weight: 0.46, years: 8),
        _leaf('math1.prob.rv1.exp', '指数分布',
            aliases: ['EXP(λ)'], weight: 0.30),
        _leaf('math1.prob.rv1.uniform', '均匀分布', weight: 0.25),
      ],
    );

void main() {
  group('公式片段插入', () {
    test('无选区时追加到末尾，光标落在插入内容之后', () {
      final c = TextEditingController(text: 'abc');
      c.selection = const TextSelection.collapsed(offset: 3);
      insertFormulaSnippet(c, r'\alpha');
      expect(c.text, r'abc\alpha');
      expect(c.selection.baseOffset, r'abc\alpha'.length);
    });

    test('光标在中间时插到光标处，而不是末尾', () {
      final c = TextEditingController(text: 'ab');
      c.selection = const TextSelection.collapsed(offset: 1);
      insertFormulaSnippet(c, 'X');
      expect(c.text, 'aXb');
      expect(c.selection.baseOffset, 2);
    });

    test('有选区时替换选区', () {
      final c = TextEditingController(text: 'ab');
      c.selection = const TextSelection(baseOffset: 0, extentOffset: 2);
      insertFormulaSnippet(c, 'Z');
      expect(c.text, 'Z');
    });

    test('含占位符时插入后**选中占位符**，用户可直接打字替换', () {
      final c = TextEditingController(text: '求 ');
      c.selection = const TextSelection.collapsed(offset: 2);
      final at = insertFormulaSnippet(
        c,
        '\\frac{$kFormulaPlaceholder}{$kFormulaPlaceholder}',
      );
      expect(c.text, '求 \\frac{□}{□}');
      // 第一个 □ 在索引 2 + 6 = 8（\frac{ 是 6 个字符）
      expect(at, '求 \\frac{'.length);
      expect(c.selection.isCollapsed, isFalse,
          reason: '占位符必须处于被选中状态，否则用户还得自己挪光标');
      expect(c.selection.textInside(c.text), kFormulaPlaceholder);
    });

    test('selection 无效（输入框没获得过焦点）时退化为追加', () {
      final c = TextEditingController(text: 'ab');
      c.selection = const TextSelection.collapsed(offset: -1);
      insertFormulaSnippet(c, 'X');
      expect(c.text, 'abX');
    });

    test('wrapSelection 用定界符包住选区并保持选中', () {
      final c = TextEditingController(text: 'x^2+1 的值');
      c.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
      wrapSelection(c, r'$', r'$');
      expect(c.text, r'$x^2+1$ 的值');
      expect(c.selection.textInside(c.text), 'x^2+1');
    });

    test('wrapSelection 在无选区时不插入半截符号', () {
      final c = TextEditingController(text: 'abc');
      c.selection = const TextSelection.collapsed(offset: 1);
      wrapSelection(c, r'$', r'$');
      expect(c.text, 'abc');
    });

    test('默认片段表里的占位符都能被解析（不会出现落单的 □）', () {
      for (final g in kDefaultFormulaGroups) {
        for (final s in g.snippets) {
          expect(s.label, isNotEmpty);
          expect(s.insert, isNotEmpty);
          // 插入内容里的花括号必须配对，否则 LaTeX 直接是坏的
          final open = '{'.allMatches(s.insert).length;
          final close = '}'.allMatches(s.insert).length;
          expect(open, close,
              reason: '${g.title} / ${s.label} 的花括号不配对：${s.insert}');
        }
      }
    });

    test('片段分组标题唯一（Tab 切换依赖它）', () {
      final titles = kDefaultFormulaGroups.map((g) => g.title).toList();
      expect(titles.toSet().length, titles.length);
    });
  });

  group('知识点搜索', () {
    test('空查询返回考频最高的若干个', () {
      final r = searchKnowledgePoints(_kb(), '');
      expect(r.map((m) => m.point.id).toList(),
          ['math1.prob.rv1.normal', 'math1.prob.rv1.exp', 'math1.prob.rv1.uniform']);
      expect(r.every((m) => m.hitField == 'weight'), isTrue);
    });

    test('按名称精确匹配排第一', () {
      final r = searchKnowledgePoints(_kb(), '指数分布');
      expect(r.first.point.id, 'math1.prob.rv1.exp');
      expect(r.first.score, 100);
      expect(r.first.hitField, 'name');
    });

    test('名称片段也能命中', () {
      final r = searchKnowledgePoints(_kb(), '正态');
      expect(r.map((m) => m.point.id), contains('math1.prob.rv1.normal'));
    });

    test('**按别名搜索**能命中 —— 这是别名机制的第二份收益', () {
      final r = searchKnowledgePoints(_kb(), '正态分布');
      // 「正态分布及其标准化计算」的名字里确实含「正态分布」，
      // 所以这里换个测法：直接搜一个名字里绝对没有的别名。
      expect(r, isNotEmpty);

      final byAlias = searchKnowledgePoints(_kb(), r'X\sim N(\mu,\sigma^2)');
      expect(byAlias.map((m) => m.point.id), contains('math1.prob.rv1.normal'));
      expect(byAlias.first.hitField, 'alias');
      expect(byAlias.first.hitAlias, isNotNull);
    });

    test('搜不到时返回空列表（而不是报错或返回全部）', () {
      expect(searchKnowledgePoints(_kb(), 'zzz不存在zzz'), isEmpty);
    });

    test('大小写不敏感（别名里的英文大写小写等价）', () {
      final lower = searchKnowledgePoints(_kb(), 'exp');
      final upper = searchKnowledgePoints(_kb(), 'EXP');
      expect(lower.map((m) => m.point.id), contains('math1.prob.rv1.exp'));
      expect(upper.map((m) => m.point.id), lower.map((m) => m.point.id));
    });

    test('别名里的 LaTeX 反斜杠也能搜（会被归一化掉）', () {
      final r = searchKnowledgePoints(_kb(), r'X\sim N(\mu,\sigma^2)');
      expect(r.map((m) => m.point.id), contains('math1.prob.rv1.normal'));
    });

    test('limit 生效', () {
      expect(searchKnowledgePoints(_kb(), '', limit: 2), hasLength(2));
    });

    test('同分时考频高的优先', () {
      // 「分布」同时命中三个叶子的名字，考的应是权重排序
      final r = searchKnowledgePoints(_kb(), '分布');
      expect(r.length, 3);
      expect(r.first.point.id, 'math1.prob.rv1.normal'); // weight 0.46 最高
    });
  });

  group('KpSelection', () {
    test('空选择判定', () {
      expect(const KpSelection().isEmpty, isTrue);
      expect(const KpSelection(primaryId: 'a').isEmpty, isFalse);
      expect(const KpSelection(secondaryIds: ['a']).isEmpty, isFalse);
    });
  });

  group('FormulaKeyboard 渲染', () {
    testWidgets('切换分组会换掉按钮集合', (tester) async {
      final c = TextEditingController();
      addTearDown(c.dispose);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: FormulaKeyboard(controller: c)),
      ));

      // 默认在「常用结构」组
      expect(find.text('分式'), findsOneWidget);
      expect(find.text('极限'), findsNothing);

      await tester.tap(find.text('微积分'));
      await tester.pumpAndSettle();

      expect(find.text('极限'), findsOneWidget);
      expect(find.text('分式'), findsNothing);
    });

    testWidgets('点按钮会把片段插进绑定的 controller', (tester) async {
      final c = TextEditingController();
      addTearDown(c.dispose);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: FormulaKeyboard(controller: c)),
      ));

      await tester.tap(find.text('上标'));
      await tester.pumpAndSettle();

      expect(c.text, '^{□}');
      // 占位符被选中
      expect(c.selection.textInside(c.text), kFormulaPlaceholder);
    });
  });
}
