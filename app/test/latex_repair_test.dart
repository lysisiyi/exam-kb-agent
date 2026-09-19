/// 模型写坏矩阵换行这件事，是**量出来的**，不是猜的。
///
/// 实测（2026-09-19，660 线代 205 道导入题）：`\\` 被写成单反斜杠
/// **194 处 / 60 个文件（29%）**，另有 41 处 `\ `、1 处 `\&`。
/// `\4` 在 LaTeX 里是未定义命令 → KaTeX 解析失败 → 整条公式渲染不出来。
///
/// 这组测试守两件事：**该修的修对**、**不该动的绝不动**。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/services/ingest/ingest_extractor.dart';
import 'package:kaoyan_math_agent/services/ingest/ingest_models.dart';
import 'package:kaoyan_math_agent/services/ingest/latex_repair.dart';

void main() {
  // ── 缺陷 1：JSON 转义把 LaTeX 命令吃掉一个反斜杠 ──────────────────────
  group('被 JSON 转义吃掉的 LaTeX 命令', () {
    test('`\\b` 退格 → `\\begin` / `\\beta`', () {
      // 模型写 "\begin{...}"，JSON 解码后 `\b` 成了退格字符
      expect(
        repairEatenEscapes('${'\x08'}egin{bmatrix}1&2\\\\end{bmatrix}'),
        r'\begin{bmatrix}1&2\\end{bmatrix}',
      );
      expect(repairEatenEscapes('${'\x08'}eta'), r'\beta');
    });

    test('`\\f` 换页 → `\\frac` / `\\forall`', () {
      expect(repairEatenEscapes('${'\x0c'}rac{1}{2}'), r'\frac{1}{2}');
      expect(repairEatenEscapes('${'\x0c'}orall x'), r'\forall x');
    });

    // 换行与制表**故意**不修：模型也用它们表达真正的换行，
    // 分不清就不改 —— 改错的代价是语义被篡改。
    test('换行 / 制表保持原样（有歧义，不猜）', () {
      const s = '第一行\n第二行\t后面';
      expect(repairEatenEscapes(s), s);
    });

    test('没坏的内容原样返回', () {
      expect(repairEatenEscapes(r'\alpha+\beta'), r'\alpha+\beta');
      expect(repairEatenEscapes(''), '');
    });

    // 两个缺陷会叠加：`\begin` 被吃掉之后，矩阵换行就**找不到环境**了。
    test('叠加场景：先恢复转义，再修矩阵换行', () {
      const bs = r'\'; // 一个反斜杠
      const rowBreak = '$bs$bs'; // 正确的行分隔符
      const backspace = '\x08';
      const broken = '设\$A=${backspace}egin{bmatrix}1&-2&0'
          '${bs}2&1&5${bs}0&1&1'
          '${rowBreak}end{bmatrix}\$';
      final fixed = repairLatex(broken);
      expect(fixed, contains('${bs}begin{bmatrix}'));
      expect(fixed, contains('1&-2&0${rowBreak}2&1&5${rowBreak}0&1&1'),
          reason: '只修其中一个的话，另一处仍然渲染不出来');
      expect(fixed, isNot(contains(backspace)));
    });
  });

  group('矩阵换行修复', () {
    test('反斜杠 + 数字（实测最多的一种）', () {
      expect(
        repairMatrixRowBreaks(
          r'\begin{bmatrix} 3 & a+2 & 4 \ 5 & a & a+5 \ 1 & -1 & 2 \end{bmatrix}',
        ),
        r'\begin{bmatrix} 3 & a+2 & 4 \\ 5 & a & a+5 \\ 1 & -1 & 2 \end{bmatrix}',
      );
    });

    test('已经写对的 `\\` 原样保留（幂等）', () {
      const ok = r'\begin{bmatrix}1&2\\3&4\end{bmatrix}';
      expect(repairMatrixRowBreaks(ok), ok);
      expect(repairMatrixRowBreaks(repairMatrixRowBreaks(ok)), ok);
    });

    test('反斜杠 + `&`（模型把行分隔符和对齐符一起转义了）', () {
      expect(
        repairMatrixRowBreaks(r'\begin{bmatrix}1&1\&-1\end{bmatrix}'),
        r'\begin{bmatrix}1&1\\&-1\end{bmatrix}',
      );
    });

    test('反斜杠 + 空格', () {
      expect(
        repairMatrixRowBreaks(r'\begin{matrix} A & O \ O & B \end{matrix}'),
        r'\begin{matrix} A & O \\ O & B \end{matrix}',
      );
    });

    test('cases / aligned* 等环境同样处理', () {
      expect(
        repairMatrixRowBreaks(r'\begin{cases} x \ 1 \end{cases}'),
        r'\begin{cases} x \\ 1 \end{cases}',
      );
    });

    // ── 不该动的 ──────────────────────────────────────────────────────────
    test('环境外面一律不动（控制空格与转义 & 可能是有意的）', () {
      const s = r'a \ b \& c \2';
      expect(repairMatrixRowBreaks(s), s);
    });

    test('环境里的正常命令不受影响（quad / alpha / frac）', () {
      const s = r'\begin{bmatrix}\alpha\quad\frac{1}{2}&1\\2&3\end{bmatrix}';
      expect(repairMatrixRowBreaks(s), s);
    });

    test('没有 begin / 空串直接返回', () {
      expect(repairMatrixRowBreaks(''), '');
      expect(repairMatrixRowBreaks(r'$x^2$'), r'$x^2$');
    });

    test('被截断（没有 \\end）时也修到底，不吞内容', () {
      expect(
        repairMatrixRowBreaks(r'\begin{bmatrix}1&2\3&4'),
        r'\begin{bmatrix}1&2\\3&4',
      );
    });

    test('公式之间的普通文本不被吃掉', () {
      expect(
        repairMatrixRowBreaks(
          r'设 A=\begin{bmatrix}1\2\end{bmatrix}, 则 r(A)=',
        ),
        r'设 A=\begin{bmatrix}1\\2\end{bmatrix}, 则 r(A)=',
      );
    });
  });

  // 修复必须**发生在前**：指纹从 stem 现算，先算指纹再修文，
  // 以后拿修好的文本再导同一页就会查不出重复。
  group('修复接进了提炼管线', () {
    test('入库的题干已经是修好的，指纹也按修好的算', () {
      final r = IngestExtractor.parse(
        jsonEncode({
          'problems': [
            {
              // 模型真实产出的形态：行分隔符少了一个反斜杠
              'stem': r'设 A=\begin{bmatrix}1&2\3&4\end{bmatrix}',
              'answer': null,
              'solution': null,
              'answer_from_source': true,
            }
          ]
        }),
        sourceName: 'p1.png',
      );
      expect(r.problems, hasLength(1));
      expect(r.problems.single.stem,
          contains(r'\begin{bmatrix}1&2\\3&4\end{bmatrix}'),
          reason: r'\3 这种写法 KaTeX 解析不了，整条公式会渲染失败');
      // 指纹要与"拿修好的文本再算一次"一致
      expect(
        r.problems.single.fingerprint,
        ExtractedProblem.fingerprintOf(r.problems.single.stem),
      );
    });

    test('选项里的矩阵也一起修', () {
      final r = IngestExtractor.parse(
        jsonEncode({
          'problems': [
            {
              'stem': '选一个',
              'qtype': 'choice',
              'options': [r'\begin{bmatrix}1\2\end{bmatrix}', '2'],
              'answer': null,
              'solution': null,
              'answer_from_source': true,
            }
          ]
        }),
        sourceName: 'p1.png',
      );
      expect(r.problems.single.options.first,
          contains(r'\begin{bmatrix}1\\2\end{bmatrix}'));
    });
  });
}
