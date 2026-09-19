/// 修模型写坏的 LaTeX。
///
/// ## 两个真实缺陷（2026-09-19 实测，660 线代 201 道导入题）
///
/// ### 1. JSON 转义把 LaTeX 命令吃掉一个反斜杠（110 处 / 29 个文件）
///
/// 模型在 JSON 字符串里直接写 `\begin{...}`（只写一个反斜杠）。
/// 而 `\b` 在 JSON 里是**合法转义**（退格 0x08），于是解码后变成
/// `<退格>egin{...}` —— 反斜杠没了，命令也没了：
///
/// ```
/// 模型给的 JSON：  "\begin{bmatrix}1&2\end{bmatrix}"
/// 解码之后：      "<0x08>egin{bmatrix}1&2\end{bmatrix}"
/// 应该是：        "\begin{bmatrix}1&2\end{bmatrix}"
/// ```
///
/// 同理还有 `\frac`（`\f` 是换页 0x0C）、`\beta`、`\forall` 等。
/// 后果是整条公式渲染失败 —— 用户看到的就是"公式显示不出来"。
/// **退格与换页字符在题干/答案/解析里永远不可能是正常内容**，
/// 所以把它们换回反斜杠是无歧义的。
///
/// ### 2. 矩阵的行分隔符少写一个反斜杠（18 个文件）
///
/// ```
/// 模型给的：\begin{bmatrix} 3 & a+2 & 4 \ 5 & a & a+5 \end{bmatrix}
/// 应该是：  \begin{bmatrix} 3 & a+2 & 4 \\ 5 & a & a+5 \end{bmatrix}
/// ```
///
/// `\4` 在 LaTeX 里是未定义命令，KaTeX 同样解析失败。
///
/// ## 两个缺陷会叠加
///
/// 第 1 个缺陷把 `\begin` 变成 `<退格>egin` 之后，第 2 个缺陷的修复
/// **就找不到矩阵环境了**（没有 `\begin` 可匹配），于是一页里两处都坏着。
/// 所以调用顺序必须是**先恢复转义、再修换行** —— 见 [repairLatex]。
///
/// ## 修法的边界（宁可少修，不可改语义）
///
/// 换行只动 `\begin{...}` 与 `\end{...}` **之间**的内容：
/// 环境里单独一个反斜杠永远不是合法 LaTeX，替换安全；环境之外的
/// `\ `（控制空格）、`\&`（转义 &）可能是有意的，不动。
library;

/// `\begin{名字}` —— 名字里允许 `*`（如 `aligned*`）。
final RegExp _begin = RegExp(r'\\begin\{[a-zA-Z*]+\}');

/// 退格 / 换页 —— 只可能来自"被 JSON 转义吃掉的 LaTeX 反斜杠"。
const String _backspace = '\x08';
const String _formFeed = '\x0c';

/// LaTeX 文本的**完整修复**：先恢复被 JSON 吃掉的转义，再修矩阵换行。
///
/// 顺序不能反 —— 理由见库文件顶部的"两个缺陷会叠加"。
String repairLatex(String input) =>
    repairMatrixRowBreaks(repairEatenEscapes(input));

/// 把被 JSON 转义吃掉的 LaTeX 命令恢复回来。
///
/// ## 恢复的是**两个字符**，不是一个
///
/// JSON 的 `\b` 是**一个**退格字符，它替掉的是原文里的 `\` + `b`。
/// 所以恢复时要还原成 `\b` 这两个字符，后面原来的 `egin` 接上才是 `\begin`：
///
/// ```
/// 模型写的   "  \begin{...}  "      ← JSON 源码
/// 解码得到   "  <0x08>egin{...}  "  ← \b 变成了一个字符
/// 恢复回来   "  \begin{...}  "      ← 退格 → `\b`
/// ```
///
/// 只把退格换成 `\` 会得到 `\egin` —— 看着像修好了，其实还是坏命令。
///
/// 只处理**无歧义**的两个：退格（`\b`）与换页（`\f`）。
/// 换行（`\n`）与制表（`\t`）**故意不动** —— 模型也用它们表达真正的换行，
/// 分不清就只能不改（实测这类只有 8 处，而改错的代价是语义被篡改）。
String repairEatenEscapes(String input) {
  if (input.isEmpty) return input;
  if (!input.contains(_backspace) && !input.contains(_formFeed)) return input;
  return input
      .replaceAll(_backspace, r'\b')
      .replaceAll(_formFeed, r'\f');
}

/// 把 [input] 里矩阵环境内部的坏行分隔符修成 `\\`。
///
/// 没有 `\begin` / 没有坏分隔符时原样返回（幂等）。
String repairMatrixRowBreaks(String input) {
  if (input.isEmpty) return input;
  if (!input.contains(r'\begin')) return input;

  final out = StringBuffer();
  var cursor = 0;

  while (true) {
    final begin = _begin.firstMatch(input.substring(cursor));
    if (begin == null) break;

    final bodyStart = cursor + begin.end;

    // 找配对的 \end{同名}；找不到（多半是被截断）就一路修到末尾
    final envName = begin.group(0)!.substring(r'\begin{'.length);
    final name = envName.substring(0, envName.length - 1);
    final endIdx = input.indexOf('\\end{$name}', bodyStart);

    out.write(input.substring(cursor, bodyStart));
    final body = endIdx < 0
        ? input.substring(bodyStart)
        : input.substring(bodyStart, endIdx);
    out.write(_fixInsideEnv(body));
    cursor = endIdx < 0 ? input.length : endIdx;
    if (endIdx < 0) break;
  }

  out.write(input.substring(cursor));
  return out.toString();
}

/// 环境内部：反斜杠 + （数字 | `&` | 空白）→ `\\` + 那个字符。
String _fixInsideEnv(String body) {
  final out = StringBuffer();
  for (var i = 0; i < body.length; i++) {
    final c = body[i];
    if (c != r'\') {
      out.write(c);
      continue;
    }
    // 已经是 `\\`：正确写法，原样抄过去
    if (i + 1 < body.length && body[i + 1] == r'\') {
      out.write(r'\\');
      i++;
      continue;
    }
    final next = i + 1 < body.length ? body[i + 1] : '';
    final isDigit = next.isNotEmpty && '0123456789'.contains(next);
    final isAmp = next == '&';
    final isSpace = next.isNotEmpty && (next == ' ' || next == '\t');
    if (isDigit || isAmp || isSpace) {
      out.write(r'\\');
      continue;
    }
    out.write(c);
  }
  return out.toString();
}
