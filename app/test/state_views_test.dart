/// 统一的空态 / 错误态。
///
/// ## 这一条要守的是什么
///
/// 打磨之前，各页面的错误态是各写各的：知识库有图标 + 重试按钮，
/// 错题本是**一行灰字、没有任何出路**。用户看到"载入失败"，
/// 唯一能做的是关掉再打开应用 —— 而绝大多数失败重试一下就好了。
///
/// 所以这个文件的重点不是"文字对不对"，而是：
/// **错误态必须给出下一步**，并且原始错误要能复制出来报障。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/core/widgets/state_views.dart';

Future<void> pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
}

void main() {
  group('AppErrorView', () {
    testWidgets('给出标题、原始错误与重试按钮，点了会回调', (tester) async {
      var retried = 0;
      await pump(
        tester,
        AppErrorView(
          title: '错题本载入失败',
          error: 'SqliteException: database is locked',
          onRetry: () => retried++,
        ),
      );

      expect(find.text('错题本载入失败'), findsOneWidget);
      expect(find.textContaining('database is locked'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);

      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(retried, 1);
    });

    testWidgets('原始错误可选中复制（报障时要能贴出来）', (tester) async {
      await pump(
        tester,
        const AppErrorView(title: '出错了', error: 'Errno 5: 拒绝访问'),
      );
      expect(
        find.byType(SelectableText),
        findsOneWidget,
        reason: '不能用普通 Text —— 用户没法复制，只能照着敲',
      );
    });

    testWidgets('不能重试时不给按钮，但必须说清下一步', (tester) async {
      // 没有按钮又没有说明 = 死胡同。这条测试禁止那种组合。
      await pump(
        tester,
        const AppErrorView(
          title: 'AI 配置不完整',
          hint: '请到「设置」里选一个服务商并填 API Key。',
        ),
      );
      expect(find.byType(FilledButton), findsNothing);
      expect(find.textContaining('「设置」'), findsOneWidget);
    });

    testWidgets('没有原始错误时不会留空白区块', (tester) async {
      await pump(tester, const AppErrorView(title: '出错了'));
      expect(find.text('出错了'), findsOneWidget);
      expect(find.byType(SelectableText), findsNothing);
    });
  });

  group('AppEmptyView', () {
    testWidgets('标题 + 下一步说明', (tester) async {
      await pump(
        tester,
        const AppEmptyView(
          title: '错题本还是空的',
          hint: '去「录入」页记下第一道题。',
        ),
      );
      expect(find.text('错题本还是空的'), findsOneWidget);
      expect(find.textContaining('「录入」'), findsOneWidget);
    });

    testWidgets('可以带一个下一步按钮', (tester) async {
      var tapped = 0;
      await pump(
        tester,
        AppEmptyView(
          title: '没有模板',
          action: FilledButton(
            onPressed: () => tapped++,
            child: const Text('去设置'),
          ),
        ),
      );
      await tester.tap(find.text('去设置'));
      await tester.pump();
      expect(tapped, 1);
    });
  });
}
