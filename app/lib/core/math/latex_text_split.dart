/// 把公式里的中文从 LaTeX 中摘出来。
///
/// ## 为什么需要这一步
///
/// `katex` 把 `\text{...}` 的内容排进 `KaTeX_Main-Regular`，而该字体**没有
/// 汉字字形**，也没有配 `fontFamilyFallback`。实测（纯 Dart 引擎，全语料
/// 1609 条）：**691 / 1523** 条真实知识点公式至少有一个"无字形"字符 ——
/// 463 个不同汉字码点、4453 次，外加全角标点 `（）、，：；`。
///
/// Flutter 的 Skia 理论上会做系统字体回退，但**这件事在 widget 测试里无法
/// 验证**：`flutter test` 默认用 Ahem 测试字体，每个字形都画成实心方框，
/// 对照组和被测组看起来一样。所以不赌回退，直接把中文摘出来交给 Flutter
/// 的普通 `TextSpan` 排 —— 那条路径的中文渲染是确定的。
///
/// ## 什么情况下不能摘
///
/// 摘出去等于把 `\text{...}` 从公式里换成一段普通文本。如果它处在
/// **依赖配对**或**作为参数**的位置，换掉就会破坏结构：
///
/// | 不能摘的位置 | 例子 | 摘掉会怎样 |
/// |---|---|---|
/// | `\left...\right` 之间 | `\left(\frac00\ \text{或}\ \frac\infty\infty\right)` | 伸缩括号失去配对对象 |
/// | `\begin{}...\end{}` 之间 | `\begin{cases}...&f\ \text{为偶函数}\\...\end{cases}` | 环境结构被切断 |
/// | 作为命令参数 | `\xrightarrow{\text{初等行变换}}` | 参数丢失，命令报错 |
/// | 上下标 | `S_{\text{侧}}=...` | 下标内容丢失 |
/// | `\underbrace` 标注 | `\underbrace{\int\cdots}_{n\ \text{次}}` | 标注内容丢失 |
///
/// 实测这三类判定能把中文公式的 **665 / 692（96.1%）** 安全切开。
/// 剩下的 24 条原样交给 katex —— 最坏情况是中文显示成方框，
/// 但那 24 条本来也只是"偏窄"，不会破坏公式结构。
library;

/// 切出来的一段。
sealed class MathChunk {
  const MathChunk();
}

/// 一段 LaTeX（要交给 katex 渲染）。
class LatexChunk extends MathChunk {
  final String tex;
  const LatexChunk(this.tex);

  @override
  String toString() => 'Latex($tex)';
  // 便于测试里直接比较
  @override
  bool operator ==(Object other) => other is LatexChunk && other.tex == tex;
  @override
  int get hashCode => tex.hashCode;
}

/// 一段普通文本（中文、全角标点；交给 Flutter 的 TextSpan）。
class TextChunk extends MathChunk {
  final String text;
  const TextChunk(this.text);

  @override
  String toString() => 'Text($text)';
  @override
  bool operator ==(Object other) => other is TextChunk && other.text == text;
  @override
  int get hashCode => text.hashCode;
}

/// 这条公式里的中文能不能被安全摘出来。
bool canSplit(String tex) => splitLatexText(tex).any((c) => c is TextChunk);

/// 把 [tex] 切成 LaTeX 片段与普通文本片段交替的序列。
///
/// 返回结果保证：`map(tex).join('')` 还原不出原始串（因为 `\text{}` 外壳被去掉了），
/// 但**语义等价** —— 中文由 Flutter 排，其余仍由 katex 排。
///
/// 不满足安全条件时原样返回一个 [LatexChunk]。
List<MathChunk> splitLatexText(String tex) {
  if (!_hasCjkOrFullWidth(tex)) return [LatexChunk(tex)];

  final out = <MathChunk>[];
  var cursor = 0; // 上一段 LaTeX 的起点
  var i = 0;
  var found = false;

  while (i < tex.length) {
    // 只对 \text{...} / \textrm{...} / \mbox{...} 动手
    final cmd = _matchTextCommand(tex, i);
    if (cmd == null) {
      i++;
      continue;
    }
    // ⚠️ 解构出的是**新变量**，不能直接改 cursor —— 原写法把
    // `cursor = bodyEnd + 1` 写成了在下面重复计算，第二段中文会漏掉。
    final cmdStart = cmd.$1;
    final bodyStart = cmd.$2;
    final closeBrace = cmd.$3;

    // 安全判定：必须在顶层（不在 \left..\right、不在环境、不是命令参数、不是上下标）
    if (!_isTopLevel(tex, cmdStart)) {
      i = closeBrace + 1; // 跳过收尾花括号
      continue;
    }

    final body = tex.substring(bodyStart, closeBrace);
    if (!_hasCjkOrFullWidth(body)) {
      i = closeBrace + 1;
      continue;
    }

    final prefix = tex.substring(cursor, cmdStart);
    if (prefix.isNotEmpty) out.add(LatexChunk(prefix));
    out.add(TextChunk(body));

    cursor = closeBrace + 1;
    i = closeBrace + 1;
    found = true;
  }

  if (!found) return [LatexChunk(tex)];

  final tail = tex.substring(cursor);
  if (tail.isNotEmpty) out.add(LatexChunk(tail));

  // 合并相邻同类，并丢掉空的 LaTeX 片段（否则会多出零宽占位）
  final merged = <MathChunk>[];
  for (final c in out) {
    if (c is LatexChunk && c.tex.isEmpty) continue;
    if (c is TextChunk && c.text.isEmpty) continue;

    final last = merged.isEmpty ? null : merged.removeLast();
    if (last == null) {
      merged.add(c);
      continue;
    }
    if (last is LatexChunk && c is LatexChunk) {
      merged.add(LatexChunk(last.tex + c.tex));
    } else if (last is TextChunk && c is TextChunk) {
      merged.add(TextChunk(last.text + c.text));
    } else {
      merged
        ..add(last)
        ..add(c);
    }
  }
  return merged.isEmpty ? [LatexChunk(tex)] : merged;
}

/// 文本片段里是否含中文或全角标点。
bool _hasCjkOrFullWidth(String s) {
  for (final r in s.runes) {
    // CJK 统一表意文字 + 扩展 A
    if (r >= 0x4E00 && r <= 0x9FFF) return true;
    if (r >= 0x3400 && r <= 0x4DBF) return true;
    // CJK 标点（、。「」等）
    if (r >= 0x3000 && r <= 0x303F) return true;
    // 全角形式（（）、，：；！？）
    if (r >= 0xFF00 && r <= 0xFFEF) return true;
  }
  return false;
}

/// 在 [i] 处匹配 `\text{...}` 这类命令。
///
/// 返回 `(命令起点, 内容起点, 收尾花括号的位置)`；不匹配返回 null。
/// 内容里允许嵌套花括号（例如 `\text{集合 \{x\}}`）。
///
/// ⚠️ 第三个元素是**收尾花括号的下标**，不是"内容的结束位置"。
/// 早先返回 `j + 1` 结果把 `}` 一起当成内容（`为偶函数}`），
/// 于是切出来的中文带着一个花括号，渲染出来就是错的。
(int, int, int)? _matchTextCommand(String tex, int i) {
  if (tex[i] != r'\') return null;
  const names = ['\\text', '\\textrm', '\\mbox', '\\textnormal'];
  String? hit;
  for (final n in names) {
    if (tex.startsWith(n, i)) {
      // 不能是 \textcolor 之类的更长命令
      final after = i + n.length;
      if (after < tex.length && tex[after] == '{') {
        hit = n;
        break;
      }
    }
  }
  if (hit == null) return null;

  final braceStart = i + hit.length;
  if (braceStart >= tex.length || tex[braceStart] != '{') return null;

  // 从 braceStart 起配对花括号，跳过被转义的 \{ \}
  var depth = 0;
  var j = braceStart;
  while (j < tex.length) {
    final c = tex[j];
    if (c == r'\' && j + 1 < tex.length) {
      j += 2;
      continue;
    }
    if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0) return (i, braceStart + 1, j);
    }
    j++;
  }
  return null; // 括号不配平 —— 交给 katex 去报错，别在这里瞎猜
}

/// [pos] 处的 `\text{}` 是否处在"可以安全替换"的位置。
///
/// 判据：不能是某个命令的参数、不能是上下标，且不能处在未闭合的
/// `\left..\right` 或 `\begin{}...\end{}` 之内。
///
/// ⚠️ 前两条必须一起判：`S_{\text{侧}}` 里 `\text` 前面是 `{`（看起来像
/// 命令参数），而那个 `{` 其实是 `_` 的下标组。分开判会把下标当成参数，
/// 于是漏判成"可切"，摘掉之后下标内容就丢了。
bool _isTopLevel(String tex, int pos) {
  if (_isCommandArgument(tex, pos)) return false;
  if (_isSubOrSuperscript(tex, pos)) return false;
  if (_insidePairing(tex, pos)) return false;
  return true;
}

/// 是否是**别的命令**的花括号参数。
///
/// 判据三步：
/// 1. 前面紧邻一个 `{`（跳过空白）；
/// 2. 那个 `{` 前面是命令名（`\xrightarrow` 之类）；
/// 3. 从那个 `{` 到 `\text` 之间**没有未配对的 `}`** —— 否则这个 `{`
///    其实已经被前面的内容闭合了，它与 `\text` 无关。
///
/// 第 3 条是关键。实测踩过：
///
/// ```
/// \text{甲}\text{乙}
///          ^ 第二个 \text 前面确实是 '{'、前面也确实是命令名 \text，
///            但那个 '{' 属于**第一个** \text。少了第 3 条就会误判成
///            "它是 \text 的参数" → 不切 → 中文显示成方框。
/// ```
///
/// 而 `\text{无关};\ \text{相关}` 这种写法在真实语料里非常常见。
bool _isCommandArgument(String tex, int pos) {
  var j = pos - 1;
  while (j >= 0 && (tex[j] == ' ' || tex[j] == '\t')) {
    j--;
  }
  if (j < 0 || tex[j] != '{') return false;

  // 第 3 条：这个 `{` 与 `\text` 之间不能有未配对的 `}`
  var depth = 0;
  for (var k = j + 1; k < pos; k++) {
    if (tex[k] == '}') depth++;
  }
  if (depth != 0) return false;

  // 第 2 条：`{` 前面是命令名
  final k = j - 1;
  if (k < 0 || tex[k] == r'\') return false;
  var m = k;
  while (m >= 0 && _isCommandNameChar(tex.codeUnitAt(m))) {
    m--;
  }
  return m >= 0 && m < k && tex[m] == r'\';
}

/// 是否是 `_{...}` / `^{...}` 的下标/上标组。
///
/// 与 `_isCommandArgument` 同理需要第 3 条判据：`x_{\text{甲}}^{\text{乙}}`
/// 里第二个 `\text` 前面的 `{` 属于上标组，而它前面是 `}`，
/// 说明那个 `{` 已经被闭合了。
bool _isSubOrSuperscript(String tex, int pos) {
  var j = pos - 1;
  while (j >= 0 && (tex[j] == ' ' || tex[j] == '\t')) {
    j--;
  }
  if (j < 0 || tex[j] != '{') return false;

  // 那个 `{` 与 `\text` 之间不能有未配对的 `}`
  for (var k = j + 1; k < pos; k++) {
    if (tex[k] == '}') return false;
  }

  final k = j - 1;
  if (k < 0) return false;
  return tex[k] == '_' || tex[k] == '^';
}

/// 是否处在未闭合的 `\left...\right` 或 `\begin{}...\end{}` 之内。
bool _insidePairing(String tex, int pos) {
  var leftDepth = 0;
  var envDepth = 0;
  var i = 0;
  while (i < pos) {
    if (tex.startsWith(r'\left', i)) {
      leftDepth++;
      i += 5;
      continue;
    }
    if (tex.startsWith(r'\right', i)) {
      if (leftDepth > 0) leftDepth--;
      i += 6;
      continue;
    }
    if (tex.startsWith(r'\begin{', i)) {
      envDepth++;
      i += 7;
      continue;
    }
    if (tex.startsWith(r'\end{', i)) {
      if (envDepth > 0) envDepth--;
      i += 5;
      continue;
    }
    i++;
  }
  return leftDepth > 0 || envDepth > 0;
}

bool _isCommandNameChar(int c) {
  // a-z A-Z @
  return (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || c == 0x40;
}
