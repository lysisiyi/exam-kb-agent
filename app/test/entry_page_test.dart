/// 录入页的 widget 测试。
///
/// ## 为什么值得单独测一个"页面"
///
/// 我在开发环境里**看不到**这个页面跑起来的样子（沙箱会回收 GUI 进程），
/// 所以"它能不能正常渲染"这件事必须有自动化兜底。这里覆盖的正是
/// 只有真渲染才会暴露的问题：
///
/// - 布局在窄/宽断点下是否都成立（宽屏才挂右侧预览）
/// - 校验状态改变时按钮是否跟着变（该禁就禁）
/// - 切题型后选项区是否真的出现
/// - 选错因后详情面板是否展开
///
/// 依赖用 Riverpod `overrideWith` 替换成本体内存数据 ——
/// 不碰 `rootBundle`（`flutter test` 里 assets 可用但不该依赖），
/// 也不碰 sqlite（保存路径不在本次断言范围内）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/core/layout/breakpoints.dart';
import 'package:kaoyan_math_agent/core/math/math_renderer.dart';
import 'package:kaoyan_math_agent/core/providers.dart';
import 'package:kaoyan_math_agent/data/error_causes.dart';
import 'package:kaoyan_math_agent/domain/knowledge/knowledge_point.dart';
import 'package:kaoyan_math_agent/features/entry/entry_page.dart';

KnowledgeBase _kb() => KnowledgeBase(
      subject: 'math1',
      subjectName: '数学一',
      version: 't',
      nodes: const [
        KnowledgePoint(id: 'math1', name: '数学一', level: 1, isLeaf: false),
        KnowledgePoint(
            id: 'math1.calc', name: '高等数学', level: 2,
            parentId: 'math1', isLeaf: false),
        KnowledgePoint(
            id: 'math1.calc.limit', name: '极限', level: 3,
            parentId: 'math1.calc', isLeaf: false),
        KnowledgePoint(
          id: 'math1.calc.limit.lhopital',
          name: '洛必达法则',
          level: 4,
          parentId: 'math1.calc.limit',
          isLeaf: true,
          examWeight: 0.8,
          definition: '求未定式极限的法则。',
          formulas: ['x'],
        ),
      ],
    );

const _catalog = ErrorCauseCatalog(
  version: 'test',
  uiOrder: ['concept', 'calc'],
  causes: [
    ErrorCause(
      id: 'concept',
      name: '概念不清',
      short: '概念不清',
      definition: '对定义、定理、公式的适用条件理解错误。',
      counterExamples: ['只是算错了 → 应归为计算失误'],
      prescription: ErrorPrescription(
        action: '回到教材重讲定义',
        notAction: '不要靠刷综合题硬补',
      ),
    ),
    ErrorCause(
      id: 'calc',
      name: '计算失误',
      short: '计算失误',
      definition: '思路正确但中间步骤算错。',
      counterExamples: ['公式记错 → 应归为概念不清'],
    ),
  ],
);

/// 把页面挂到测试环境里。
///
/// ⚠️ 必须包一层 [BreakpointScope]：页面用
/// `BreakpointScope.of(context)` 读断点，而那个方法带 assert，
/// 找不到 scope 会直接让整棵树构建失败（12 个用例一起红，且看不出原因）。
/// 生产环境里这层由 `main()` 的 `ResponsiveScope` 提供。
Future<void> _pumpEntry(
  WidgetTester tester, {
  Size surface = const Size(800, 900),
}) async {
  tester.view.physicalSize = surface;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    BreakpointScope.fromSize(
      size: surface,
      child: ProviderScope(
        overrides: [
          knowledgeBaseProvider.overrideWith((ref) async => _kb()),
          errorCauseCatalogProvider.overrideWith((ref) async => _catalog),
        ],
        child: const MaterialApp(home: Scaffold(body: EntryPage())),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(MathRendering.reset);
  tearDown(MathRendering.reset);

  testWidgets('空题干时给出阻断提示，保存按钮禁用', (tester) async {
    await _pumpEntry(tester);

    expect(find.text('题干不能为空'), findsOneWidget);
    final btn = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '保存并继续录下一题'),
    );
    expect(btn.onPressed, isNull, reason: '阻断性问题未解决时不该能点保存');
  });

  testWidgets('填了题干后保存按钮可用，阻断提示消失', (tester) async {
    await _pumpEntry(tester);

    await tester.enterText(find.byType(TextField).first, r'求 $\lim_{x\to0}x$');
    await tester.pumpAndSettle();

    expect(find.text('题干不能为空'), findsNothing);
    final btn = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '保存并继续录下一题'),
    );
    expect(btn.onPressed, isNotNull);
  });

  testWidgets('没选主考点只给提示，不阻断保存（60 秒目标的关键）', (tester) async {
    await _pumpEntry(tester);
    await tester.enterText(find.byType(TextField).first, '求极限');
    await tester.pumpAndSettle();

    // 保存栏给出提示，且明确告诉用户"可以稍后补"
    expect(find.textContaining('还没有选主考点'), findsOneWidget);
    expect(find.textContaining('可以保存'), findsOneWidget);
    // 考点区也有一句更简短的引导
    expect(find.textContaining('可以先保存'), findsOneWidget);
    final btn = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '保存并继续录下一题'),
    );
    expect(btn.onPressed, isNotNull, reason: '缺考点不能阻断 —— 否则 60 秒必崩');
  });

  testWidgets('切成选择题后出现选项输入框', (tester) async {
    await _pumpEntry(tester);
    await tester.enterText(find.byType(TextField).first, '下列正确的是');
    await tester.pumpAndSettle();

    expect(find.text('加一个选项'), findsNothing);

    await tester.tap(find.widgetWithText(ChoiceChip, '选择'));
    await tester.pumpAndSettle();

    expect(find.text('加一个选项'), findsOneWidget);
    // 默认两个选项，此时都是空的 → 阻断
    expect(find.textContaining('至少要有 2 个选项'), findsOneWidget);
  });

  testWidgets('勾选错因后展开定义、反例与处方', (tester) async {
    await _pumpEntry(tester);

    expect(find.text('不算这一类的情况'), findsNothing);

    await tester.tap(find.widgetWithText(FilterChip, '概念不清'));
    await tester.pumpAndSettle();

    expect(find.text('不算这一类的情况'), findsOneWidget);
    expect(find.textContaining('只是算错了'), findsOneWidget);
    expect(find.textContaining('不要靠刷综合题硬补'), findsOneWidget);

    // 取消勾选后收起
    await tester.tap(find.widgetWithText(FilterChip, '概念不清'));
    await tester.pumpAndSettle();
    expect(find.text('不算这一类的情况'), findsNothing);
  });

  testWidgets('宽屏才挂右侧预览；窄屏不渲染它', (tester) async {
    // 窄（medium 断点）
    await _pumpEntry(tester, surface: const Size(800, 900));
    expect(find.textContaining('渲染器：'), findsNothing);

    // 宽（large 断点）
    await _pumpEntry(tester, surface: const Size(1440, 900));
    expect(find.textContaining('渲染器：'), findsOneWidget);
    expect(find.text('预览'), findsOneWidget);
  });

  testWidgets('预览面板会跟着题干更新', (tester) async {
    await _pumpEntry(tester, surface: const Size(1440, 900));

    expect(find.textContaining('开始输入后这里会实时渲染'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'abc题干');
    await tester.pumpAndSettle();

    expect(find.textContaining('开始输入后这里会实时渲染'), findsNothing);
    // PlainTextMathRenderer 会把 Markdown 原样显示
    expect(find.textContaining('abc题干'), findsWidgets);
  });

  testWidgets('公式键盘插进题干框后，文字真的进去了', (tester) async {
    await _pumpEntry(tester);

    await tester.tap(find.widgetWithText(InkWell, '分式'));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField).first);
    expect(field.controller!.text, contains(r'\frac'));
    expect(field.controller!.text, contains('□'));
  });

  testWidgets('「更多」默认折叠，点开后出现难度/来源/笔记', (tester) async {
    await _pumpEntry(tester);

    expect(find.text('难度'), findsNothing);

    await tester.tap(find.textContaining('更多（'));
    await tester.pumpAndSettle();

    expect(find.text('难度'), findsOneWidget);
    expect(find.text('来源类型'), findsOneWidget);
    expect(find.text('我的笔记'), findsOneWidget);
  });

  testWidgets('清空按钮把表单恢复成初始状态', (tester) async {
    await _pumpEntry(tester);

    await tester.enterText(find.byType(TextField).first, '会被清掉');
    await tester.pumpAndSettle();
    expect(find.text('题干不能为空'), findsNothing);

    await tester.tap(find.widgetWithText(TextButton, '清空'));
    await tester.pumpAndSettle();

    expect(find.text('题干不能为空'), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField).first);
    expect(field.controller!.text, isEmpty);
  });

  testWidgets('未配置 API Key 时，AI 按钮明确说"需配置"', (tester) async {
    await _pumpEntry(tester);

    // PlatformServices 未安装 → 读取配置失败 → 走"未配置"分支
    expect(find.textContaining('需配置 Key'), findsOneWidget);
  });

  testWidgets('知识点本体载入失败时给出可读错误，而不是白屏', (tester) async {
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      BreakpointScope.fromSize(
        size: const Size(800, 900),
        child: ProviderScope(
          overrides: [
            knowledgeBaseProvider
                .overrideWith((ref) async => throw StateError('本体文件缺失')),
            errorCauseCatalogProvider.overrideWith((ref) async => _catalog),
          ],
          child: const MaterialApp(home: Scaffold(body: EntryPage())),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('知识点本体载入失败'), findsOneWidget);
  });
}
