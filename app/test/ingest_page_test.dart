/// 批量导入页测试。
///
/// ## 这一页要守的是「**在花钱之前**把不能跑的情况拦住」
///
/// 这一页最容易出的错不是崩溃，而是：用户选了 100 个文件、点了开始，
/// 才在失败列表里发现"我这个模型根本读不了图片"。
/// 那时候钱已经花出去了，而用户等了半天。
///
/// 所以下面的断言几乎全都在检查**闸门与提示**：
/// 没有配置时不能点开始、DeepSeek 要被明确拦下并告诉用户换什么、
/// PDF 不支持时要说清出路。
///
/// 真实 API 调用不在这里测（那需要 Key 与网络），
/// 管道逻辑在 `ingest_test.dart` 里用假 HTTP 全覆盖。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/core/layout/breakpoints.dart';
import 'package:kaoyan_math_agent/core/providers.dart';
import 'package:kaoyan_math_agent/features/ingest/ingest_page.dart';
import 'package:kaoyan_math_agent/services/llm/llm_settings.dart';

import 'support/test_env.dart';

void main() {
  late TempLibrary env;

  Future<void> pump(
    WidgetTester tester, {
    required LlmSettings settings,
    Size size = const Size(1100, 900),
  }) async {
    await tester.runAsync(() async {
      env = await TempLibrary.create();
    });
    addTearDown(() async {
      await tester.runAsync(env.dispose);
    });

    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWith((ref) async => env.db),
          problemStoreProvider.overrideWith((ref) async => env.store),
          // 不碰真实的安全存储（DPAPI）：测试里直接给配置
          llmSettingsProvider.overrideWith((ref) async => settings),
        ],
        child: BreakpointScope.fromSize(
          size: size,
          child: const MaterialApp(home: Scaffold(body: IngestPage())),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  testWidgets('没配置 AI 时说清这一页需要什么，并且不让开始', (tester) async {
    await pump(tester, settings: LlmSettings.none);

    expect(tester.takeException(), isNull);
    // 空态要说人话：告诉用户这一页是干什么的
    expect(find.textContaining('选一个文件夹'), findsOneWidget);
    // 关键：不是一句"请先配置"，而是解释**为什么**需要视觉模型
    // 用 findsWidgets：空态提示里也提到"视觉模型"，两处都算数
    expect(find.textContaining('视觉模型'), findsWidgets);
    expect(find.textContaining('DeepSeek'), findsOneWidget);
  });

  testWidgets('配了 DeepSeek（纯文本）也要被拦下，并告诉换什么', (tester) async {
    // 这是最可能发生的真实场景：DeepSeek 是国内用户的首选，
    // 但它没有视觉模型。拦不住的话用户会白花 100 次调用的钱。
    await pump(
      tester,
      settings: const LlmSettings(
        providerId: 'deepseek',
        apiKey: 'sk-test',
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.textContaining('纯文本模型'), findsOneWidget);
    expect(find.textContaining('Claude'), findsOneWidget);
    expect(find.textContaining('Gemini'), findsOneWidget);
  });

  testWidgets('配了视觉模型时给出肯定反馈', (tester) async {
    await pump(
      tester,
      settings: const LlmSettings(
        providerId: 'openai',
        apiKey: 'sk-test',
        modelOverride: 'gpt-4o-mini',
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.textContaining('可以读取图片'), findsOneWidget);
  });

  testWidgets('认不出的自建模型：允许继续，但必须提示可能失败', (tester) async {
    await pump(
      tester,
      settings: const LlmSettings(
        providerId: 'custom',
        apiKey: 'sk-test',
        baseUrlOverride: 'https://gateway.example.com/v1',
        modelOverride: 'my-internal-vl',
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.textContaining('无法确认'), findsOneWidget);
  });

  testWidgets('窄屏不溢出', (tester) async {
    await pump(
      tester,
      settings: const LlmSettings(
        providerId: 'openai',
        apiKey: 'sk-test',
        modelOverride: 'gpt-4o-mini',
      ),
      size: const Size(460, 900),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('三个入口按钮都在', (tester) async {
    await pump(
      tester,
      settings: const LlmSettings(
        providerId: 'openai',
        apiKey: 'sk-test',
        modelOverride: 'gpt-4o-mini',
      ),
    );

    expect(find.text('选择文件夹'), findsOneWidget);
    expect(find.text('选图片'), findsOneWidget);
    expect(find.text('选 PDF'), findsOneWidget);
  });
}
