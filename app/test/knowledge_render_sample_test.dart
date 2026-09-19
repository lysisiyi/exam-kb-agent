/// 知识点卡片的**渲染样张**（默认不跑，`DSH_UI_SAMPLE=1` 时才生成）。
///
/// ## 为什么要有这一条
///
/// 排版观感只有人眼能判，而 `flutter test` 用的是 Ahem 占位字体 ——
/// 中文全是实心方框。所以这里做的是：**显式加载 KaTeX 字体**（公式就能
/// 正常显示），把真实知识点的卡片渲染成 PNG 写到工作区根目录
/// （`Project/formula-check/`，不在仓库里、不会被提交），供人眼确认。
///
/// ```powershell
/// $env:DSH_UI_SAMPLE = "1"; flutter test test/knowledge_render_sample_test.dart
/// ```
///
/// 中文仍是方框 —— 那是测试环境的字体问题，不是产品缺陷。这份样张用来
/// 判断的是：**公式有没有被裁、一行公式排得对不对、各小节分得清不清**。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/core/math/katex_renderer.dart';
import 'package:kaoyan_math_agent/core/math/math_renderer.dart';
import 'package:kaoyan_math_agent/domain/knowledge/knowledge_point.dart';
import 'package:kaoyan_math_agent/features/knowledge/knowledge_leaf_detail.dart';

import 'support/test_fonts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('生成知识点卡片样张（DSH_UI_SAMPLE=1 时才跑）', (tester) async {
    if (Platform.environment['DSH_UI_SAMPLE'] != '1') return;

    final f = File('../data/knowledge_points/math1.json');
    if (!f.existsSync()) {
      // ignore: avoid_print
      print('[样张] 找不到 data/knowledge_points/math1.json');
      return;
    }
    final kb = KnowledgeBase.fromJson(
      (jsonDecode(f.readAsStringSync()) as Map).cast<String, dynamic>(),
    );

    // 公式必须用真字体，否则样张里全是黑块
    final loaded = await loadBundledFonts();
    expect(loaded, greaterThan(0), reason: '一个字体包都没装上');
    MathRendering.install(const KatexRenderer());
    addTearDown(MathRendering.reset);

    final out = Directory(
      '${Directory.current.parent.parent.path}${Platform.pathSeparator}formula-check',
    );
    if (!out.existsSync()) out.createSync(recursive: true);

    // 覆盖四种典型情况：最长的极限定义 / 多条并列（会被 \quad 拆行）/
    // 长公式 / 公式最长且没有分隔符可拆
    const cases = <String, List<double>>{
      'math1.calc.limit.func': [900, 560],
      'math1.calc.limit.eq_infinitesimal': [900],
      'math1.calc.limit.taylor': [560],
      'math1.prob.rv2.normal2d': [900],
    };

    for (final entry in cases.entries) {
      final leaf = kb.byId[entry.key];
      if (leaf == null) continue;
      for (final width in entry.value) {
        tester.view.physicalSize = Size(width, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              backgroundColor: const Color(0xFFFFFFFF),
              body: Align(
                alignment: Alignment.topLeft,
                child: RepaintBoundary(
                  key: key,
                  child: SizedBox(
                    width: width,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Builder(
                        builder: (ctx) {
                          final crumb = detailBreadcrumb(kb, leaf.id);
                          return KnowledgeLeafDetail(
                            leaf: leaf,
                            sectionName: crumb.section,
                            chapterName: crumb.chapter,
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final bytes = await tester.runAsync(() async {
          final img = await boundary.toImage(pixelRatio: 2.0);
          final bd = await img.toByteData(format: ui.ImageByteFormat.png);
          img.dispose();
          return bd!.buffer.asUint8List();
        });

        final name = '${entry.key.split('.').last}-${width.toInt()}';
        File('${out.path}${Platform.pathSeparator}$name.png')
            .writeAsBytesSync(bytes!);
        // ignore: avoid_print
        print('[样张] ${out.path}\\$name.png  （${leaf.name}）');
      }
    }
  });
}
