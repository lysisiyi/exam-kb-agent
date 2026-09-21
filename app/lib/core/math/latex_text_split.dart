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
/// 判据收敛成一句：**`\text` 只要在任何一个未闭合的 `{...}` 里，就不摘**。
/// 这比逐一识别"这是谁的参数"更保守，但保守的方向是对的 ——
/// 摘错的后果不是"中文变成方框"，而是**整条公式变成红色乱码**
/// （切出来的 LaTeX 片段各自都不完整，katex 直接抛 ParseError）。
///
/// ## 第二条入口：裸中文
///
/// 中文**没有**包在 `\text{}` 里、直接写在数学模式里（`无解\iff r(A)<r(A|b)`）
/// 也要救 —— 真实语料里有，用户自己录入时更常见。这段走的是
/// [splitLatexText] 主循环里那条"找不到命令"的分支，安全性判据与
/// `\text{}` 共用 [_isTopLevel]，并额外要求中文**不紧贴命令名**
/// （见 [_precededByCommandName]：`\overline解` 的 `解` 是命令参数）。
///
/// ## 剩下多少救不了
///
/// 2026-09-21 实测：语料 1400 条公式、610 条含中文，**18 条摘不出来**
/// （8 命令参数 / 5 `\left..\right` / 3 上下标 / 2 环境），摘分率 96.8%。
/// 这 18 条的中文仍会交给 KaTeX，只能指望 Skia 的隐式字体回退 ——
/// 而那件事在 `flutter test` 里**验证不了**（测试字体 Ahem 把每个字形都
/// 画成实心方框），所以要靠真机确认。
///
/// 这条不变量由 `test/cjk_split_corpus_test.dart` 守着：
/// 它不只看"切开了多少条"，还要求**每一个 LatexChunk 自己都能被 katex 解析**。
/// 少了后一条，切坏公式这件事可以长期潜伏 —— 切分率看起来还很漂亮。
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

/// 把一条**长公式**按顶层的 `\quad` / `\qquad` 拆成几段，便于逐行排版。
///
/// ## 为什么需要它
///
/// 本体的公式平均 **64 字符**、最长 **227 字符**（实测 824 条）。一条
/// `\lim_{x\to x_0}f(x)=A \iff \forall\varepsilon>0,\exists\delta>0,\dots`
/// 在 14px 下宽 500–700px，塞进固定宽度的框里只剩两个选择：裁掉一截
/// （用户看不全）或缩到看不清。
///
/// 而数据里大量使用 `\quad` 作为**并列分隔**（`\sin x\sim x,\quad \tan x\sim x`
/// 这种等价表就是典型）。拆成一行一条，既不裁也不缩，读起来也和教材一致。
/// 实测 824 条里有 **295 条**含顶层 `\quad`。
///
/// ## 只在"顶层"拆
///
/// `\quad` 出现在 `{...}`、`\left..\right`、环境里时**不能拆** ——
/// 那会把结构切断（`\left(\frac00\quad\frac11\right)` 拆开就不成对了）。
/// 判据直接复用 [_isTopLevel]（花括号深度 + `\left..\right`/环境配对 +
/// 上下标），与"摘中文"那条路径同一套逻辑 —— 免得两处对"什么是顶层"的
/// 理解慢慢分叉。
///
/// 返回至少一个元素；不含顶层分隔符时原样返回整条公式。
List<String> splitTopLevelQuad(String tex) {
  final parts = <String>[];
  final buf = StringBuffer();
  var i = 0;

  while (i < tex.length) {
    final sep = tex[i] == r'\' ? _matchQuadSeparator(tex, i) : null;
    if (sep != null && _isTopLevel(tex, i)) {
      parts.add(buf.toString());
      buf.clear();
      i += sep.length;
      // 吃掉分隔符后面的空白，免得每段以空格开头
      while (i < tex.length && (tex[i] == ' ' || tex[i] == '\t')) {
        i++;
      }
      continue;
    }

    // 普通命令 / 转义：连同下一个字符一起写进去（`\{` 不能被当成花括号）
    buf.write(tex[i]);
    i++;
    if (i < tex.length && tex[i - 1] == r'\') {
      buf.write(tex[i]);
      i++;
    }
  }
  parts.add(buf.toString());

  final cleaned = [
    for (final s in parts)
      if (s.trim().isNotEmpty) s.trim(),
  ];
  return cleaned.isEmpty ? [tex] : cleaned;
}

/// [i] 处是不是 `\quad` / `\qquad`（长的先判；后面不能跟字母）。
String? _matchQuadSeparator(String tex, int i) {
  for (final cmd in const [r'\qquad', r'\quad']) {
    if (!tex.startsWith(cmd, i)) continue;
    final after = i + cmd.length;
    if (after < tex.length) {
      if (_isAsciiLetter(tex.codeUnitAt(after))) continue; // `\quadratic` 之类不是分隔符
    }
    return cmd;
  }
  return null;
}

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
      // ── 裸中文 ──────────────────────────────────────────────────────────
      //
      // 中文**没有**包在 `\text{}` 里，直接写在数学模式里。这在真实语料
      // 中就有（`无解\iff r(A)<r(A|b)`），而用户自己录入时更常见 ——
      // 不是每个人都知道公式里的中文要包 `\text{}`。
      //
      // 这条路径此前完全不处理：`_matchTextCommand` 找不到命令，于是整条
      // 公式原样交给 katex；而 KaTeX 字体对裸中文同样没有字形，
      // 结果依然是方框。也就是说改动之前**没有任何机制**能救这类公式。
      //
      // 安全性判据与 `\text{}` 完全一致 —— 只在顶层摘。所以 `x_{旧}`
      // （中文在花括号里）照旧不动：摘掉会留下 `x_{` 这种不能解析的残片，
      // 整条公式会变成红色乱码，比方框更糟。
      //
      // ⚠️ 还要多守一条：**紧贴着命令名的中文不能摘**。
      // `\overline解` 里的 `解` 是 `\overline` 的参数（TeX 允许参数不加
      // 花括号），摘掉就留下一个缺参数的 `\overline` —— katex 直接抛错，
      // 整条公式降级成红色乱码。而 `设A为矩阵` 里的 `A` 是独立记号，
      // 摘掉它后面的中文完全安全。两者的区别就是 [_precededByCommandName]。
      if (_isTopLevel(tex, i) &&
          !_precededByCommandName(tex, i) &&
          _isCjkOrFullWidthRune(tex.codeUnitAt(i))) {
        var j = i;
        while (j < tex.length && _isCjkOrFullWidthRune(tex.codeUnitAt(j))) {
          j++;
        }
        final prefix = tex.substring(cursor, i);
        if (prefix.isNotEmpty) out.add(LatexChunk(prefix));
        out.add(TextChunk(tex.substring(i, j)));
        cursor = j;
        i = j;
        found = true;
        continue;
      }
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
    out.add(TextChunk(_unescapeTextBody(body)));

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

/// 把 `\text{}` 内容里的 LaTeX 转义还原成用户该看到的字符。
///
/// ## 为什么必须做
///
/// 摘出来的内容会作为**普通文本**交给 Flutter 排。而 LaTeX 里的转义
/// 是给排版引擎看的：
///
/// | 公式里写的 | LaTeX 排出来 | 不还原的话用户看到 |
/// |---|---|---|
/// | `\text{在关于\ x\ 轴对称的}` | 在关于 x 轴对称的 | `在关于\ x\ 轴对称的` |
/// | `\text{命中率 50\%}` | 命中率 50% | `命中率 50\%` |
///
/// 真实语料里有 1 条命中（`\text{若}\ f\ \text{在关于\ x\ 轴对称的}\ D`），
/// 变体（`\%` `\&` `\_` `\text{甲\text{乙}丙}`）都属同类。
///
/// ⚠️ **认不出的转义要原样保留**，不能静默吞掉反斜杠 ——
/// 那会把 `\alpha` 变成 `alpha`，性质比"多显示一个反斜杠"更糟。
String _unescapeTextBody(String s) {
  final b = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final c = s[i];
    if (c != r'\' || i + 1 >= s.length) {
      b.write(c);
      i++;
      continue;
    }
    final n = s[i + 1];
    switch (n) {
      // 反斜杠本身：`\\` → `\`
      case '\\':
        b.write(r'\');
        i += 2;
      // LaTeX 的"字面字符"转义
      case '{':
      case '}':
      case '%':
      case '&':
      case '#':
      case '_':
      case r'$':
        b.write(n);
        i += 2;
      // `\ `（反斜杠 + 空格）是一个显式空格
      case ' ':
        b.write(' ');
        i += 2;
      // 其余（`\alpha`、嵌套的 `\text` 等）保持原样，只跳过这两个字符
      default:
        b.write(c);
        i++;
    }
  }
  return b.toString();
}

/// 单个码点是不是中文或全角标点。
///
/// 抽成函数是因为**裸中文**（没有 `\text{}` 包裹、直接写在数学模式里）
/// 也要按码点逐个识别，见 [splitLatexText]。
bool _isCjkOrFullWidthRune(int r) {
  // CJK 统一表意文字 + 扩展 A
  if (r >= 0x4E00 && r <= 0x9FFF) return true;
  if (r >= 0x3400 && r <= 0x4DBF) return true;
  // CJK 标点（、。「」等）
  if (r >= 0x3000 && r <= 0x303F) return true;
  // 全角形式（（）、，：；！？）
  if (r >= 0xFF00 && r <= 0xFFEF) return true;
  return false;
}

/// 文本片段里是否含中文或全角标点。
bool _hasCjkOrFullWidth(String s) {
  for (final r in s.runes) {
    if (_isCjkOrFullWidthRune(r)) return true;
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
/// 判据只有三条，但第一条就把绝大多数情况覆盖了。
///
/// ## ⚠️ 为什么不能用"紧邻的字符是什么"来判断
///
/// 早先这里靠 `_isCommandArgument` / `_isSubOrSuperscript` 两个函数，
/// 它们都只看 `\text` **紧挨着的前一个字符**。这对"第二个参数"和
/// "跟在前一组后面"的写法全部失效：
///
/// ```
/// \frac{A\ \text{包含的样本点数}}{\text{样本点总数}}
///                        ↑ 前面是 `}`，两个判定都返回 false
/// \underbrace{\int\cdots\int}_{n\ \text{次}}
///                               ↑ 在 _{...} 里面，但前面是 `\ `
/// ```
///
/// 判成"顶层"就会被摘出来，于是外层的 `\frac{...}{...}` 被切成
/// `\frac{A\ ` / `}{` / `}` 三段，**每一段单独都不能解析** ——
/// `renderToBox` 抛 ParseError，katex 把整条公式降级成红色的原始 LaTeX。
/// 也就是说：这个函数本意是"让中文别显示成方框"，实际效果却是
/// 把**原本排版正常**的公式变成一串红色乱码。全语料实测有 4 条命中了
/// 这条路径（都是概率论里的核心公式）。
///
/// ## 正确的判据
///
/// `\text` 只要处在**任何一个未闭合的 `{...}` 里**，它就不是顶层 ——
/// 不需要知道那个 `{` 属于谁。这一条同时覆盖了：
/// - 命令参数：`\xrightarrow{\text{…}}`、`\frac{x}{\text{…}}`
/// - 上下标组：`S_{\text{侧}}`
/// - 任意嵌套分组
///
/// 再加上"无边括号的上下标"（`S_\text{侧}`）与 `\left..\right` /
/// `\begin..\end` 两条，就完整了。
///
/// 代价是比原来保守一点：少数嵌套很深的公式不再被切开，
/// 中文退回"显示成方框"。**这恰恰是设计上可接受的降级** ——
/// 方框只是不好看，红色乱码是坏掉。
bool _isTopLevel(String tex, int pos) {
  if (_braceDepth(tex, pos) > 0) return false;

  // 无边括号的上下标：`S_\text{侧}`。前一个非空白字符是 `_` / `^`。
  final prev = _prevNonSpace(tex, pos);
  if (prev == '_' || prev == '^') return false;

  if (_insidePairing(tex, pos)) return false;
  return true;
}

/// `tex[0..pos)` 里未闭合的 `{` 数量。跳过被转义的 `\{` `\}`。
///
/// 只看花括号，不看 `\left(`/`\right)` —— 后者由 [_insidePairing] 负责。
int _braceDepth(String tex, int pos) {
  var depth = 0;
  for (var i = 0; i < pos && i < tex.length; i++) {
    final c = tex[i];
    if (c == r'\' && i + 1 < tex.length) {
      i++; // 跳过转义对，`\{` 不算花括号
      continue;
    }
    if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
    }
  }
  return depth;
}

/// [pos] 之前第一个非空白字符。没有则返回 `''`。
String _prevNonSpace(String tex, int pos) {
  var j = pos - 1;
  while (j >= 0 && (tex[j] == ' ' || tex[j] == '\t')) {
    j--;
  }
  return j < 0 ? '' : tex[j];
}

/// [pos] 左边紧挨着的那个记号，是不是一个**反斜杠命令的名字**。
///
/// 用来区分两种长得一样的写法：
///
/// | 写法 | 左边的记号 | 汉字是它的参数吗 | 能不能摘 |
/// |---|---|---|---|
/// | `\overline解` | 命令 `\overline` | 是（TeX 允许参数不带花括号） | ❌ 不能 |
/// | `\mathbf A解` | 独立字符 `A` | 否（`\mathbf` 只吃 `A`） | ✅ 能 |
/// | `设A为矩阵` | 独立字符 `A` | —— | ✅ 能 |
///
/// 判据：从 [pos] 往前跳过空白，再跳过一串字母；如果字母串**紧挨着 `\`**，
/// 那它就是一个命令名而不是独立字符。
///
/// ⚠️ 摘错的代价不对称：摘对了是"中文不再显示成方框"，摘错了是
/// **整条公式变成红色乱码**。所以这条判据宁可保守 ——
/// `\alpha解` 这种写法也一并挡住，代价只是一条公式的中文留在方框里。
bool _precededByCommandName(String tex, int pos) {
  var j = pos - 1;
  while (j >= 0 && (tex[j] == ' ' || tex[j] == '\t')) {
    j--;
  }
  if (j < 0) return false;

  if (!_isAsciiLetter(tex.codeUnitAt(j))) return false;

  // 往前走完整个命令名
  while (j >= 0 && _isAsciiLetter(tex.codeUnitAt(j))) {
    j--;
  }
  return j >= 0 && tex[j] == r'\';
}

bool _isAsciiLetter(int c) =>
    (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A);

/// 是否处在未闭合的 `\left...\right` 或 `\begin{}...\end{}` 之内。
bool _insidePairing(String tex, int pos) {
  var leftDepth = 0;
  var envDepth = 0;
  var i = 0;
  while (i < pos) {
    if (_isDelimiterCommand(tex, i, r'\left')) {
      leftDepth++;
      i += 5;
      continue;
    }
    if (_isDelimiterCommand(tex, i, r'\right')) {
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

/// [i] 处的 [cmd]（`\left` / `\right`）是不是**定界符**，
/// 而不是某个更长命令的前缀。
///
/// ⚠️ 只写 `startsWith(r'\left')` 会把 `\leftarrow`、`\leftrightarrow`
/// 也当成左定界符：`leftDepth` 从此不再归零，那条公式**剩下的部分
/// 全都不再摘中文** —— 中文退回显示成方框，而且完全没有报错。
/// 当前语料里 0 命中，但 `\leftarrow` 在数学里太常见，属于迟早会踩的坑。
bool _isDelimiterCommand(String tex, int i, String cmd) {
  if (!tex.startsWith(cmd, i)) return false;
  final after = i + cmd.length;
  if (after >= tex.length) return true; // 公式到此结束，算定界符
  return !_isAsciiLetter(tex.codeUnitAt(after));
}

