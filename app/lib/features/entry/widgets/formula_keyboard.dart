/// 公式快捷键盘。
///
/// ## 为什么必须有它（而不是让用户手打 LaTeX）
///
/// 录入指标的硬要求是"掐表 ≤ 60 秒"。手打 `\displaystyle\lim_{x\to0}`
/// 这类命令，一道题就要一两分钟，指标直接没戏。
///
/// 但**移动端那套"分类面板点符号"的做法在 PC 上不够**：
/// PC 用户会粘贴、会用键盘。所以这里做的是**混合输入**：
///
/// | 入口 | 适合 |
/// |---|---|
/// | 快捷键盘（本文件） | 高频符号：`\frac`、`\int`、上下标、希腊字母 |
/// | 直接粘贴 | 从 PDF / 网页 / 其他工具里拿到的整段 LaTeX |
/// | 手打 + 补全 | 少见命令 |
///
/// ## 插入位置怎么定
///
/// 不能简单"追加到末尾"——用户是在光标处思考的。所以需要把
/// `TextEditingController` 的 selection 当作插入点，并在插入后
/// **把光标移到占位符位置**：
///
/// - 无占位符：`\alpha` → 插完光标在末尾
/// - 有占位符 `□`：`\frac{□}{□}` → 插完选中第一个 `□`
///
/// 这样用户点一下 `\frac` 就能直接打分母，不用再按三次方向键。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 一个可插入的公式片段。
class FormulaSnippet {
  /// 按钮上显示的文字。
  final String label;

  /// 插入到编辑器里的内容。
  ///
  /// `□` 是占位符，插入后会被选中，用户直接输入即可替换。
  final String insert;

  /// 悬浮提示（说明用途 + 插入内容）。
  final String? tooltip;

  const FormulaSnippet(this.label, this.insert, {this.tooltip});
}

/// 一组相关片段。
class FormulaGroup {
  final String title;
  final List<FormulaSnippet> snippets;

  const FormulaGroup(this.title, this.snippets);
}

/// 占位符字符。
///
/// 选 `□` 而不是 `{}`：`{}` 在 LaTeX 里是分组符，用户分不清哪个是占位符；
/// 而 `□` 一旦忘了替换，肉眼立刻能看出来（编译出来也是错的）。
const String kFormulaPlaceholder = '□';

/// 默认片段表。
///
/// 顺序按**考研数学的出现频率**排，不是按字母序 ——
/// 高频的放前面，用户能少滚动一次是一次。
const List<FormulaGroup> kDefaultFormulaGroups = [
  FormulaGroup('常用结构', [
    FormulaSnippet('分式', '\\frac{$kFormulaPlaceholder}{$kFormulaPlaceholder}',
        tooltip: r'\frac{a}{b}'),
    FormulaSnippet('根号', '\\sqrt{$kFormulaPlaceholder}', tooltip: r'\sqrt{x}'),
    FormulaSnippet('n 次根', '\\sqrt[$kFormulaPlaceholder]{$kFormulaPlaceholder}',
        tooltip: r'\sqrt[n]{x}'),
    FormulaSnippet('上标', '^{$kFormulaPlaceholder}', tooltip: 'x^{2}'),
    FormulaSnippet('下标', '_{$kFormulaPlaceholder}', tooltip: 'a_{n}'),
    FormulaSnippet('绝对值', '|$kFormulaPlaceholder|', tooltip: r'|x|'),
    FormulaSnippet('括号', '\\left($kFormulaPlaceholder\\right)'),
    FormulaSnippet('分段函数',
        '\\begin{cases}$kFormulaPlaceholder\\\\$kFormulaPlaceholder\\end{cases}'),
  ]),
  FormulaGroup('微积分', [
    FormulaSnippet('极限', '\\lim_{$kFormulaPlaceholder\\to$kFormulaPlaceholder}',
        tooltip: r'\lim_{x\to0}'),
    FormulaSnippet('导数', "f'($kFormulaPlaceholder)"),
    FormulaSnippet('二阶导', "f''($kFormulaPlaceholder)"),
    FormulaSnippet('偏导', '\\frac{\\partial $kFormulaPlaceholder}{\\partial $kFormulaPlaceholder}',
        tooltip: r'\frac{\partial z}{\partial x}'),
    FormulaSnippet('不定积分', '\\int $kFormulaPlaceholder\\,\\mathrm{d}$kFormulaPlaceholder',
        tooltip: r'\int f(x)\,\mathrm{d}x'),
    FormulaSnippet('定积分',
        '\\int_{$kFormulaPlaceholder}^{$kFormulaPlaceholder} $kFormulaPlaceholder\\,\\mathrm{d}$kFormulaPlaceholder',
        tooltip: r'\int_a^b f(x)\,\mathrm{d}x'),
    FormulaSnippet('二重积分', '\\iint_{$kFormulaPlaceholder}'),
    FormulaSnippet('三重积分', '\\iiint_{$kFormulaPlaceholder}'),
    FormulaSnippet('曲线积分', '\\oint_{$kFormulaPlaceholder}'),
    FormulaSnippet('求和', '\\sum_{$kFormulaPlaceholder}^{$kFormulaPlaceholder}'),
    FormulaSnippet('连乘', '\\prod_{$kFormulaPlaceholder}^{$kFormulaPlaceholder}'),
    FormulaSnippet('无穷', '\\infty'),
    FormulaSnippet('趋于', '\\to'),
    FormulaSnippet('等价', '\\sim'),
  ]),
  FormulaGroup('关系与逻辑', [
    FormulaSnippet('≤', '\\le'),
    FormulaSnippet('≥', '\\ge'),
    FormulaSnippet('≠', '\\neq'),
    FormulaSnippet('约等于', '\\approx'),
    FormulaSnippet('属于', '\\in'),
    FormulaSnippet('任意', '\\forall'),
    FormulaSnippet('存在', '\\exists'),
    FormulaSnippet('推出', '\\Rightarrow'),
    FormulaSnippet('等价于', '\\Leftrightarrow'),
    FormulaSnippet('向量', '\\vec{$kFormulaPlaceholder}'),
    FormulaSnippet('千分', '\\cdots'),
  ]),
  FormulaGroup('希腊字母', [
    FormulaSnippet('α', '\\alpha'),
    FormulaSnippet('β', '\\beta'),
    FormulaSnippet('γ', '\\gamma'),
    FormulaSnippet('θ', '\\theta'),
    FormulaSnippet('λ', '\\lambda'),
    FormulaSnippet('μ', '\\mu'),
    FormulaSnippet('ξ', '\\xi'),
    FormulaSnippet('ρ', '\\rho'),
    FormulaSnippet('σ', '\\sigma'),
    FormulaSnippet('φ', '\\varphi'),
    FormulaSnippet('ω', '\\omega'),
    FormulaSnippet('Δ', '\\Delta'),
    FormulaSnippet('Φ', '\\Phi'),
    FormulaSnippet('π', '\\pi'),
  ]),
  FormulaGroup('线性代数', [
    FormulaSnippet('矩阵', '\\begin{pmatrix}$kFormulaPlaceholder\\end{pmatrix}'),
    FormulaSnippet('行列式', '\\begin{vmatrix}$kFormulaPlaceholder\\end{vmatrix}'),
    FormulaSnippet('转置', '^{T}'),
    FormulaSnippet('逆', '^{-1}'),
    FormulaSnippet('伴随', '^{*}'),
    FormulaSnippet('秩', 'r($kFormulaPlaceholder)'),
    FormulaSnippet('转置共轭', '\\bar{$kFormulaPlaceholder}'),
    FormulaSnippet('特征值', '\\lambda'),
    FormulaSnippet('单位阵', 'E'),
  ]),
];

/// 公式快捷键盘。
///
/// 面板形态由 [compact] 决定：窄屏用横向分组 + 可折叠；
/// 宽屏直接铺开所有分组（PC 有空间，少点一次是一次）。
class FormulaKeyboard extends StatefulWidget {
  /// 插入目标。
  final TextEditingController controller;

  /// 插入后是否把焦点还给输入框。
  ///
  /// 默认 true —— 点完按钮应该能直接继续打字。
  final bool refocus;

  /// 是否紧凑布局。
  final bool compact;

  /// 自定义片段表（测试用）。
  final List<FormulaGroup> groups;

  const FormulaKeyboard({
    super.key,
    required this.controller,
    this.refocus = true,
    this.compact = false,
    this.groups = kDefaultFormulaGroups,
  });

  @override
  State<FormulaKeyboard> createState() => _FormulaKeyboardState();
}

class _FormulaKeyboardState extends State<FormulaKeyboard> {
  String _activeGroup = kDefaultFormulaGroups.first.title;

  @override
  Widget build(BuildContext context) {
    final groups = widget.groups;
    if (groups.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final current = groups.firstWhere(
      (g) => g.title == _activeGroup,
      orElse: () => groups.first,
    );

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 分组标签
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final g in groups)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: _GroupChip(
                      label: g.title,
                      selected: g.title == current.title,
                      onTap: () => setState(() => _activeGroup = g.title),
                    ),
                  ),
                const SizedBox(width: 8),
                _HintChip(
                  icon: Icons.info_outline,
                  text: '$kFormulaPlaceholder = 占位符，插入后已选中',
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          // 片段按钮
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final s in current.snippets)
                _SnippetButton(
                  snippet: s,
                  onTap: () => insertFormulaSnippet(widget.controller, s.insert),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GroupChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _GroupChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? theme.colorScheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected
                ? theme.colorScheme.onPrimary
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _HintChip extends StatelessWidget {
  final IconData icon;
  final String text;

  const _HintChip({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: c),
        const SizedBox(width: 4),
        Text(text, style: TextStyle(fontSize: 10.5, color: c)),
      ],
    );
  }
}

class _SnippetButton extends StatelessWidget {
  final FormulaSnippet snippet;
  final VoidCallback onTap;

  const _SnippetButton({required this.snippet, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final button = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
          ),
        ),
        child: Text(
          snippet.label,
          style: const TextStyle(fontSize: 12.5, height: 1.1),
        ),
      ),
    );
    return snippet.tooltip == null
        ? button
        : Tooltip(message: snippet.tooltip!, child: button);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 插入逻辑（独立成函数，便于单测：不依赖 Widget 树）
// ─────────────────────────────────────────────────────────────────────────────

/// 把 [insert] 插到 [controller] 的光标处。
///
/// 行为：
/// 1. 有选区 → 用插入内容**替换**选区
/// 2. 插入内容含占位符 `□` → 插入后**选中第一个占位符**，
///    用户直接打字就能替换它
/// 3. 没有占位符 → 光标落到插入内容末尾
///
/// 返回插入后首个占位符在整个文本中的位置（没有则为 null）。
/// 返回值主要用于测试断言。
int? insertFormulaSnippet(TextEditingController controller, String insert) {
  final text = controller.text;
  final sel = controller.selection;

  // 没有有效选区时，退化为"追加到末尾"。
  // （输入框还没获得过焦点时 selection 是 -1/-1）
  final hasSelection = sel.isValid && sel.start >= 0 && sel.end >= 0;
  final start = hasSelection ? sel.start : text.length;
  final end = hasSelection ? sel.end : text.length;

  final newText = text.replaceRange(start, end, insert);
  final placeholderAt = insert.indexOf(kFormulaPlaceholder);

  if (placeholderAt >= 0) {
    final absolute = start + placeholderAt;
    controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection(baseOffset: absolute, extentOffset: absolute + 1),
      composing: TextRange.empty,
    );
    return absolute;
  }

  final caret = start + insert.length;
  controller.value = TextEditingValue(
    text: newText,
    selection: TextSelection.collapsed(offset: caret),
    composing: TextRange.empty,
  );
  return null;
}

/// 把选中的内容用一对定界符包起来（用于 `$...$`、`\left(...\right)`）。
///
/// 没有选区时什么也不做（避免插入半截符号）。
void wrapSelection(
  TextEditingController controller,
  String open,
  String close,
) {
  final sel = controller.selection;
  if (!sel.isValid || sel.isCollapsed) return;
  final text = controller.text;
  final body = text.substring(sel.start, sel.end);
  final newText = text.replaceRange(sel.start, sel.end, '$open$body$close');
  controller.value = TextEditingValue(
    text: newText,
    selection: TextSelection(
      baseOffset: sel.start + open.length,
      extentOffset: sel.start + open.length + body.length,
    ),
    composing: TextRange.empty,
  );
}

/// 键盘快捷键：把选中文字包进行内公式 `$...$`。
class InlineMathIntent extends Intent {
  const InlineMathIntent();
}

/// 处理 [InlineMathIntent]。
class InlineMathAction extends Action<InlineMathIntent> {
  final TextEditingController controller;

  InlineMathAction(this.controller);

  @override
  Object? invoke(InlineMathIntent intent) {
    wrapSelection(controller, r'$', r'$');
    return null;
  }
}

/// 用 `$...$` 包住选区的默认快捷键：Ctrl+M（Math）。
///
/// 选 M 而不是 `$`：`$` 本身要能正常输入（用户可能想手打定界符）。
const SingleActivator kInlineMathShortcut = SingleActivator(
  LogicalKeyboardKey.keyM,
  control: true,
);
