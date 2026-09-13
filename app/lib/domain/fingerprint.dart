/// 题目去重指纹计算。
///
/// ## 用途
/// 全局题库（`problems` 表）里，同一道题只应存一份。用户 A 和用户 B 拍到同一道
/// 真题时，应当复用同一条题目记录 —— 这是成本控制与标注质量复用的基础。
///
/// ## 重要限制
/// LaTeX 的写法**极度不稳定**：同一个公式可以写成
/// `\frac{1}{2}`、`\dfrac{1}{2}`、`{1 \over 2}`、`\tfrac12`。
/// 因此指纹**只能识别"规范化后完全相同"的题目**，
/// **不能用来判断两道题是否相似**。相似题检索需要向量语义匹配（V3）。
///
/// 指纹基于**题干**计算，不包含答案、解析、图片、来源。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// LaTeX / Markdown 文本规范化器。
///
/// 目标不是"让文本变好看"，而是**消除等价的写法差异**，
/// 使指纹稳定、使公式检索更准。
class LatexNormalizer {
  const LatexNormalizer._();

  /// 全角标点 → 半角。用户从 Word / 网页粘贴时经常混入。
  static const Map<String, String> _fullWidthPunct = {
    '，': ',', '。': '.', '；': ';', '：': ':', '？': '?', '！': '!',
    '（': '(', '）': ')', '【': '[', '】': ']', '《': '<', '》': '>',
    '、': ',', '～': '~', '—': '-', '－': '-',
  };

  /// 不可见字符，必须清掉，否则指纹会被"看不见的差异"污染。
  static final RegExp _invisible = RegExp(
    r'[\u200B-\u200F\u202A-\u202E\u2060-\u2064\uFEFF\u00AD]',
  );

  /// 归一化公式分隔符：
  /// - `\( ... \)`  → `$ ... $`
  /// - `\[ ... \]`  → `$$ ... $$`
  /// - `\begin{equation}...\end{equation}` → `$$...$$`
  static String normalizeDelimiters(String s) {
    var out = s;
    out = out.replaceAllMapped(
      RegExp(r'\\\[(.*?)\\\]', dotAll: true),
      (m) => '\$\$${m.group(1)}\$\$',
    );
    out = out.replaceAllMapped(
      RegExp(r'\\\((.*?)\\\)', dotAll: true),
      (m) => '\$${m.group(1)}\$',
    );
    out = out.replaceAllMapped(
      RegExp(r'\\begin\{equation\*?\}(.*?)\\end\{equation\*?\}', dotAll: true),
      (m) => '\$\$${m.group(1)}\$\$',
    );
    return out;
  }

  /// 通用清理：换行统一、去不可见字符、去 HTML 实体、标点归一。
  static String clean(String input) {
    var s = input;

    // 1. 换行统一
    s = s.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

    // 2. 去不可见字符
    s = s.replaceAll(_invisible, '');

    // 3. 常见 HTML 实体（Word 粘贴）
    const entities = {
      '&nbsp;': ' ', '&amp;': '&', '&lt;': '<', '&gt;': '>',
      '&quot;': '"', '&#39;': "'", '&ldquo;': '“', '&rdquo;': '”',
    };
    entities.forEach((k, v) => s = s.replaceAll(k, v));

    // 4. 全角标点归一
    _fullWidthPunct.forEach((k, v) => s = s.replaceAll(k, v));

    // 5. 折叠 3 个以上连续换行
    s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');

    // 6. 去掉行尾空白
    s = s.split('\n').map((l) => l.replaceAll(RegExp(r'[ \t]+$'), '')).join('\n');

    return s.trim();
  }

  /// 针对**指纹计算**的激进规范化。有损，不可用于展示。
  ///
  /// 与 [clean] 的区别：这里会删掉所有排版性差异，
  /// 输出仅用于哈希，**绝不能写回文件**。
  static String aggressiveForFingerprint(String input) {
    var s = clean(input);

    // 去所有数学环境分隔符
    s = s.replaceAll(RegExp(r'\$\$?'), '');

    // 去可变的分隔符宏
    s = s.replaceAll(RegExp(r'\\(left|right|big|Big|bigg|Bigg)\b'), '');

    // 统一分式写法
    s = s.replaceAll(RegExp(r'\\[dt]frac'), r'\frac');
    s = s.replaceAll(RegExp(r'\\tfrac'), r'\frac');

    // 去纯排版宏。
    // ⚠️ 这里**不能**写 \b? —— 词边界断言不可加量词，Dart 的 RegExp 会抛
    //    FormatException: Nothing to repeat。改用 (?![a-zA-Z]) 负向先行断言，
    //    它可加量词且语义相同（确保匹配到的是完整宏名，不会截断 \limitsx）。
    s = s.replaceAll(
      RegExp(r'\\(?:displaystyle|textstyle|scriptstyle|limits|nolimits'
          r'|quad|qquad|enspace|thinspace)(?![a-zA-Z])'
          r'|\\[,;!:]'),
      '',
    );

    // 统一微分符号写法：\mathrm{d}x / \text{d}x / dx → dx
    s = s.replaceAll(RegExp(r'\\math(rm|it)\{d\}'), 'd');
    s = s.replaceAll(RegExp(r'\\text\{d\}'), 'd');
    s = s.replaceAll(RegExp(r'\\,?d(?=[a-zA-Z])'), 'd');

    // 去所有空白
    s = s.replaceAll(RegExp(r'\s+'), '');

    // 去所有标点（中英文）。
    // 用 r'''...''' 三引号原始字符串，以便安全包含单引号与双引号 ——
    // 在 r'...' 里写 \' 是无效转义，反而会让字符串提前结束（编译期语法错误）。
    s = s.replaceAll(RegExp(r'''[,.!?;:()\[\]{}<>~\-—_/\\|"'`]'''), '');

    return s.toLowerCase();
  }
}

/// 题目指纹计算器。
class ProblemFingerprint {
  const ProblemFingerprint._();

  /// 计算题目指纹：16 位十六进制字符串。
  ///
  /// 输入应当是**题干**（Markdown + LaTeX），不要传答案或解析。
  static String compute(String stem) {
    final canonical = LatexNormalizer.aggressiveForFingerprint(stem);
    if (canonical.isEmpty) return '';
    final digest = sha256.convert(utf8.encode(canonical));
    return digest.toString().substring(0, 16);
  }

  /// 两道题的题干是否（在规范化后）完全相同。
  static bool isSame(String stemA, String stemB) {
    final a = compute(stemA);
    final b = compute(stemB);
    return a.isNotEmpty && a == b;
  }
}
