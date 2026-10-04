/// 自适应外壳的焦点隔离回归测试（P0-6）。
///
/// 为什么要有这个文件：`IndexedStack` 只是不绘制隐藏页，**primary focus
/// 原封不动地留在看不见的页面上**。曾据此真实存在的缺陷：复习页切走后
/// 按空格/1/2/3，看不见的页面照常揭晓、照常写库评分；对话输入框持有
/// 焦点时 Enter 会静默发出消息。修法是 `_LazyPage` 给隐藏页套
/// `ExcludeFocus(excluding: true)` —— 本文件钉住这个行为：
/// **已构建但被隐藏的页面，键盘事件必须进不去。**
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/core/widgets/adaptive_shell.dart';

void main() {
  testWidgets('切走后，隐藏页的快捷键不再触发；切回后键盘流程恢复', (tester) async {
    final fired = <String>[];
    final nodeA = FocusNode(debugLabel: 'page-a');
    final nodeB = FocusNode(debugLabel: 'page-b');
    addTearDown(() {
      nodeA.dispose();
      nodeB.dispose();
    });

    // 两个页面各监听一个**不同的**键：A 听 Z，B 听 X。
    // 这样"按键落进了隐藏页"和"按键落进了可见页"可以分开断言。
    Widget page(String tag, LogicalKeyboardKey key, FocusNode node) =>
        CallbackShortcuts(
          bindings: {
            SingleActivator(key): () => fired.add(tag),
          },
          child: Focus(
            focusNode: node,
            autofocus: true,
            child:
                Center(child: Text(tag, textDirection: TextDirection.ltr)),
          ),
        );

    await tester.pumpWidget(
      MaterialApp(
        home: AdaptiveShell(
          destinations: [
            NavDestination(
              label: '甲页',
              icon: Icons.looks_one,
              selectedIcon: Icons.looks_one,
              builder: () => page('A', LogicalKeyboardKey.keyZ, nodeA),
            ),
            NavDestination(
              label: '乙页',
              icon: Icons.looks_two,
              selectedIcon: Icons.looks_two,
              builder: () => page('B', LogicalKeyboardKey.keyX, nodeB),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1. 初始在 A（显式聚焦，等价于用户点进了页面）：A 的键生效。
    nodeA.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.pump();
    expect(fired, ['A'], reason: '可见页的快捷键必须正常工作');

    // 2. 切到 B：B 可见，它的键生效。
    await tester.tap(find.text('乙页'));
    await tester.pumpAndSettle();
    nodeB.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.pump();
    expect(fired, ['A', 'B'], reason: '切过去之后 B 的快捷键应当生效');

    // 3. 回到 A —— 此时 B 已构建但被隐藏。B 的键必须**不再**触发。
    //    （修复前：primary focus 留在 B 的节点上，X 会打到看不见的 B 上，
    //    fired 变成 ['A', 'B', 'B']。）
    await tester.tap(find.text('甲页'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.pump();
    expect(fired, ['A', 'B'],
        reason: '隐藏页的快捷键绝不能触发 —— '
            '这就是 IndexedStack 保活 + 无焦点隔离的缺陷本体');

    // 4. 再切回 B：键盘流程必须恢复（FocusScope 原位请回焦点），
    //    否则用户每次切页都要先点一下页面才能用键盘 —— 不可接受。
    await tester.tap(find.text('乙页'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.pump();
    expect(fired, ['A', 'B', 'B'],
        reason: '切回页面后键盘流程必须恢复，不能要用户先点一下');
  });
}
