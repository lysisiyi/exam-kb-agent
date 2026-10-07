# -*- coding: utf-8 -*-
"""知识库手账风重排：公式卡（圆章编号+白卡+居中留白）+ 和纸胶带 + 便签陷阱 + 虚线分节。

原则（调研）：Morandi 柔和色、留白、和纸胶带点缀（小面积、微旋转）；
公式按 LaTeX 惯例做"显示式"处理（独立成块、四周留白、编号）。
安全性不变量全部保留：FittedFormula 三分支、formula-copy-<tex>、
formula-scroll-hint-<tex>、Text('$index') 原样。
"""
from pathlib import Path

# ── 1) 公式行 → 手账公式卡 ────────────────────────────────────────────
p1 = Path("D:/agent/workspaces/kaoyan-math-agent/app/lib/features/knowledge/knowledge_formula_row.dart")
s = p1.read_text(encoding="utf-8")

old = """  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 序号列：拆出来的续行留空，读者一眼看出"这几行是同一组"
          SizedBox(
            width: 20,
            child: index == null
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(
                      '$index',
                      style: const TextStyle(
                        fontSize: KnowledgeSizes.secondary,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primaryStrong,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
          ),
          Expanded(
            child: FittedFormula(tex: tex, fontSize: fontSize),
          ),
          _CopyButton(tex: tex),
        ],
      ),
    );
  }
}"""
new = """  @override
  Widget build(BuildContext context) {
    final numbered = index != null;

    final body = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // 手账「编号圆章」：圆形底 + 序号；续行/别名公式留空位，读者一眼
        // 看出"这几行是同一组"。
        SizedBox(
          width: 28,
          child: numbered
              ? Center(
                  child: Container(
                    width: 21,
                    height: 21,
                    decoration: const BoxDecoration(
                      color: AppColors.primaryWeak,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '$index',
                      style: const TextStyle(
                        fontSize: KnowledgeSizes.secondary,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primaryStrong,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
        const SizedBox(width: 6),
        Expanded(child: FittedFormula(tex: tex, fontSize: fontSize)),
        _CopyButton(tex: tex),
      ],
    );

    // 别名公式（无编号）：轻量排，不套卡 —— 别名是一组小标签，
    // 每条都套卡会变成十几张白卡铺满屏。
    if (!numbered) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 7, left: 4),
        child: body,
      );
    }

    // 核心公式：手账公式卡（白底 + 暖边 + 圆角 + 轻阴影）。
    // 按 LaTeX 显示式惯例：独立成块、四周留白（8/8），比行内版更"重"。
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(6, 9, 6, 9),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.line),
          boxShadow: AppShadows.s1,
        ),
        child: body,
      ),
    );
  }
}"""
assert old in s, "formula row"
s = s.replace(old, new)
p1.write_text(s, encoding="utf-8")
print("formula row ok")

# ── 2) 详情卡：胶带 + 边注线 + 便签陷阱 + 虚线分节 ─────────────────────
p2 = Path("D:/agent/workspaces/kaoyan-math-agent/app/lib/features/knowledge/knowledge_leaf_detail.dart")
s2 = p2.read_text(encoding="utf-8")

# 2a) 顶部加和纸胶带：把 Column 包进 Stack
old_a = """    return Container(
      // 外层白卡（_PaneCard）已提供纸面，这里用极浅暖底分区块，
      // 与参考图"卡内分区"的层次一致
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: AppRadius.rMd,
        border: Border.all(color: AppColors.line.withValues(alpha: 0.6)),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: ["""
new_a = """    return Container(
      // 外层白卡（_PaneCard）已提供纸面，这里用极浅暖底分区块，
      // 与参考图"卡内分区"的层次一致
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: AppRadius.rMd,
        border: Border.all(color: AppColors.line.withValues(alpha: 0.6)),
      ),
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 13),
      child: Stack(
        // 和纸胶带只作为小面积点缀（露出卡缘一点点被裁掉，像真贴上去）
        clipBehavior: Clip.hardEdge,
        children: [
          Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: ["""
assert old_a in s2, "container head"
s2 = s2.replace(old_a, new_a)

# 2b) 结尾闭合：Column 之后补胶带与 Stack 收尾
old_b = """        ],
      ),
    );
  }
}

String _qtypeLabel(String q) => switch (q) {"""
new_b = """        ],
      ),
          // 两张和纸胶带（微旋转、半透明、柔和色）——手账的"贴纸感"来源
          Positioned(
            left: 22,
            top: -4,
            child: Transform.rotate(
              angle: 0.06,
              child: Container(
                width: 64,
                height: 16,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
          Positioned(
            right: 30,
            top: -5,
            child: Transform.rotate(
              angle: -0.05,
              child: Container(
                width: 52,
                height: 15,
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _qtypeLabel(String q) => switch (q) {"""
assert old_b in s2, "container tail"
s2 = s2.replace(old_b, new_b)

# 2c) 定义块：加"边注线"（笔记本左缘竖线）
old_c = """            DefaultTextStyle.merge(
              style: const TextStyle(
                  fontSize: KnowledgeSizes.body, height: 1.85),
              child: MathRendering.renderer.renderMarkdown(
                leaf.definition!,
                // 与下面的「核心公式」同档（`AppMathSizes.reading`）——
                // 一段话里的行内公式和下面成行的公式应当一样大
                options:
                    const MathRenderOptions(fontSize: AppMathSizes.reading),
              ),
            ),"""
new_c = """            // 手账"边注线"：定义块左缘一条暖色竖线 + 内缩，
            // 像笔记本上的页边线，把定义与普通段落区分开。
            Container(
              padding: const EdgeInsets.only(left: 10),
              decoration: const BoxDecoration(
                border: Border(
                  left: BorderSide(color: AppColors.primarySoft, width: 3),
                ),
              ),
              child: DefaultTextStyle.merge(
                style: const TextStyle(
                    fontSize: KnowledgeSizes.body, height: 1.85),
                child: MathRendering.renderer.renderMarkdown(
                  leaf.definition!,
                  // 与下面的「核心公式」同档（`AppMathSizes.reading`）——
                  // 一段话里的行内公式和下面成行的公式应当一样大
                  options:
                      const MathRenderOptions(fontSize: AppMathSizes.reading),
                ),
              ),
            ),"""
assert old_c in s2, "definition block"
s2 = s2.replace(old_c, new_c)

# 2d) 陷阱 → 便签块
old_d = """/// 陷阱一条。
class _TrapItem extends StatelessWidget {
  final int index;
  final String text;

  const _TrapItem({required this.index, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row("""
new_d = """/// 陷阱一条：手账"便签条"（琥珀底 + 左粗边），一条一贴。
class _TrapItem extends StatelessWidget {
  final int index;
  final String text;

  const _TrapItem({required this.index, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 7),
      padding: const EdgeInsets.fromLTRB(9, 7, 10, 7),
      decoration: BoxDecoration(
        color: AppColors.warningWeak,
        borderRadius: BorderRadius.circular(8),
        border: const Border(
          left: BorderSide(color: AppColors.warning, width: 3),
        ),
      ),
      child: Row("""
assert old_d in s2, "trap head"
s2 = s2.replace(old_d, new_d)

# 陷阱内部收尾：原来 Padding 的收尾要去掉一层
old_e = """          Expanded(
            child: Text(
              text.replaceAll('★ ', ''),
              style: const TextStyle(
                fontSize: KnowledgeSizes.body,
                height: 1.65,
                color: AppColors.warningInk,
              ),
            ),
          ),
        ],
      ),
    );
  }
}"""
new_e = """          Expanded(
            child: Text(
              text.replaceAll('★ ', ''),
              style: const TextStyle(
                fontSize: KnowledgeSizes.body,
                height: 1.65,
                color: AppColors.warningInk,
              ),
            ),
          ),
        ],
      ),
    );
  }
}"""
assert old_e in s2
# 该收尾不用改（结构层数一致：Row 的收尾）——只是 Padding→Container 一层

# 2e) 分节标题：实线 → 手账虚线
old_f = """          const SizedBox(width: 8),
          const Expanded(child: Divider(height: 1, thickness: 1)),"""
new_f = """          const SizedBox(width: 8),
          // 手账风虚线（替代实线 Divider）：更像方格本上的分隔
          const Expanded(
            child: CustomPaint(
              painter: _DashPainter(),
              child: SizedBox(height: 1, width: double.infinity),
            ),
          ),"""
assert old_f in s2, "section line"
s2 = s2.replace(old_f, new_f)

# 2f) 追加虚线 painter（文件尾）
s2 += """

/// 手账虚线：5px 划、4px 空，暖灰。
class _DashPainter extends CustomPainter {
  const _DashPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.ink4.withValues(alpha: 0.55)
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round;
    var x = 0.0;
    while (x < size.width) {
      canvas.drawLine(Offset(x, 0.5),
          Offset((x + 5).clamp(0, size.width), 0.5), paint);
      x += 9;
    }
  }

  @override
  bool shouldRepaint(covariant _DashPainter oldDelegate) => false;
}
"""
p2.write_text(s2, encoding="utf-8")
print("detail ok")
