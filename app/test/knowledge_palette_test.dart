/// 知识点功能的**配色契约**：对比度必须过 WCAG AA（4.5:1）。
///
/// ## 为什么把颜色写进测试
///
/// 用户反馈"图谱和大纲的字体颜色深浅不一"。查下来是两处各写各的：
/// 同一个"叶子"，图谱用 `ink1`（17.8:1），大纲用 `ink2`（8.2:1）；
/// 大纲的叶子**编号**用 `ink3`，只有 **3.2:1** —— 低于 AA 对正文的要求。
///
/// 现在颜色收进 `nodeThemeOf()` 一份，但"收进一份"本身不会阻止以后有人
/// 把某个色值调浅。所以这里把对比度变成断言：**改浅就红**。
///
/// ## 阈值怎么定
///
/// WCAG AA：正文 4.5:1，大号字（≥18pt 或 ≥14pt 粗体）3:1。
/// 这里一律按 4.5 卡 —— 知识点卡片与大纲里的字最大也就 15px，都属于"正文"。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/core/theme/app_theme.dart';
import 'package:kaoyan_math_agent/features/knowledge/knowledge_graph_layout.dart'
    show GraphNodeKind;
import 'package:kaoyan_math_agent/features/knowledge/knowledge_node_style.dart';

import 'support/contrast.dart';

const double _aa = wcagAa;

void main() {
  const kinds = GraphNodeKind.values;

  group('节点色板', () {
    test('节点卡片上的文字 vs 自己的底色 ≥ 4.5:1', () {
      for (final k in kinds) {
        final t = nodeThemeOf(k);
        expect(contrast(t.onFillInk, t.fill), greaterThanOrEqualTo(_aa),
            reason: '$k：${t.onFillInk} on ${t.fill} '
                '只有 ${contrast(t.onFillInk, t.fill).toStringAsFixed(2)}:1');
      }
    });

    test('大纲行的名字 vs 白底 ≥ 4.5:1', () {
      for (final k in kinds) {
        final t = nodeThemeOf(k);
        expect(contrast(t.textInk, AppColors.surface), greaterThanOrEqualTo(_aa),
            reason: '$k：名字色 ${t.textInk} 在白底上只有 '
                '${contrast(t.textInk, AppColors.surface).toStringAsFixed(2)}:1');
      }
    });

    test('编号 / 圆点（accent）vs 白底 ≥ 4.5:1（叶子编号曾经只有 3.2:1）', () {
      for (final k in kinds) {
        final t = nodeThemeOf(k);
        expect(contrast(t.accent, AppColors.surface), greaterThanOrEqualTo(_aa),
            reason: '$k：accent ${t.accent} 在白底上只有 '
                '${contrast(t.accent, AppColors.surface).toStringAsFixed(2)}:1');
      }
    });

    test('图谱与大纲共用同一份墨色（防止两处再次分叉）', () {
      // 大原则：叶子是用户真正要读的东西，它的墨色必须是最深的，
      // 不能因为"层级低"就被调浅
      final leaf = nodeThemeOf(GraphNodeKind.leaf);
      expect(contrast(leaf.textInk, AppColors.surface),
          greaterThanOrEqualTo(contrast(AppColors.ink2, AppColors.surface)),
          reason: '叶子名字不该比 ink2 还浅');
      // 分支的 accent 与它的 textInk 同源，两个视图才不会一蓝一黑
      for (final k in [GraphNodeKind.chapter, GraphNodeKind.unit]) {
        expect(nodeThemeOf(k).accent, nodeThemeOf(k).textInk);
      }
    });
  });

  group('知识点卡片里的次要文字', () {
    test('kSecondaryInk（面包屑/说明/计数）在卡片底色上 ≥ 4.5:1', () {
      final r = contrast(kSecondaryInk, AppColors.bg);
      expect(r, greaterThanOrEqualTo(_aa),
          reason: 'ink2 在卡片底色上只有 ${r.toStringAsFixed(2)}:1');
    });

    test('说明为什么不能用 ink3：它在这套底色上确实不达标', () {
      // 这条不是"要求 ink3 达标"，而是把"当初为什么换掉它"钉在测试里，
      // 免得有人觉得 ink3 更雅致又改回去
      final r = contrast(AppColors.ink3, AppColors.bg);
      expect(r, lessThan(_aa),
          reason: 'ink3 现在 ${r.toStringAsFixed(2)}:1 —— 若它已达标，'
              '这两条断言该重写（说明主题色变了）');
    });

    test('陷阱文字（warningInk）在卡片底色上 ≥ 4.5:1', () {
      final r = contrast(AppColors.warningInk, AppColors.bg);
      expect(r, greaterThanOrEqualTo(_aa),
          reason: 'warningInk 在 ${AppColors.bg} 上只有 '
              '${r.toStringAsFixed(2)}:1 —— 陷阱是要读的内容，不是装饰');
    });

    test('考频数字的三档颜色都达标', () {
      for (final w in [0.0, 0.5, 0.7, 0.9, 1.0, null]) {
        final c = weightInk(w);
        final r = contrast(c, AppColors.surface);
        expect(r, greaterThanOrEqualTo(_aa),
            reason: '考频 $w 的颜色 $c 只有 ${r.toStringAsFixed(2)}:1');
      }
    });
  });
}
