import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/data/markdown/problem_markdown.dart';
import 'package:kaoyan_math_agent/data/markdown/problem_store.dart';
import 'package:kaoyan_math_agent/domain/fingerprint.dart';

void main() {
  const parser = ProblemMarkdownParser();

  group('正常解析', () {
    test('完整的 frontmatter + 正文能全部解析出来', () {
      const md = '''
---
id: 2023-shu1-T18
fingerprint: a3f8c9e12b4d7f21
subject: math1
qtype: solve
difficulty: 2
source: 2023 年数学（一）真题 第 18 题
source_type: real_exam
source_year: 2023
knowledge:
  - id: math1.calc.limit.closed_interval
    role: primary
    relevance: 1.0
  - id: math1.calc.limit.zero_point
    role: secondary
    relevance: 0.7
error_causes: [idea]
images:
  - images/2023-shu1-T18-1.png
created_at: 2026-03-15
tags: [真题, 证明题]
---

## 题干

设 \$f(x)\$ 在 \$[0,1]\$ 上连续，且 \$\$\\int_0^1 f(x)dx = 0\$\$

## 答案

存在 \$\\xi\$ 使 \$f(\\xi)=0\$。

## 解析

由积分中值定理可得。

## 我的笔记

构造辅助函数套路。
''';

      final r = parser.parse(md);
      expect(r.isOk, isTrue, reason: r.error);

      final p = r.problem!;
      expect(p.id, '2023-shu1-T18');
      expect(p.fingerprint, 'a3f8c9e12b4d7f21');
      expect(p.subject, 'math1');
      expect(p.qtype, QuestionType.solve);
      expect(p.difficulty, 2);
      expect(p.sourceType, SourceType.realExam);
      expect(p.sourceYear, 2023);
      expect(p.errorCauses, ['idea']);
      expect(p.tags, ['真题', '证明题']);
      expect(p.images, ['images/2023-shu1-T18-1.png']);
      expect(p.createdAt, DateTime(2026, 3, 15));

      expect(p.knowledge.length, 2);
      expect(p.primaryKnowledge?.id, 'math1.calc.limit.closed_interval');
      expect(p.primaryKnowledge?.relevance, 1.0);

      expect(p.stem, contains(r'\int_0^1'));
      expect(p.answer, isNotNull);
      expect(p.solution, contains('积分中值定理'));
      expect(p.note, contains('辅助函数'));

      expect(p.needsReview, isFalse);
      expect(p.warnings, isEmpty);
    });

    test('题型枚举解析正确', () {
      String md(String qtype) => '---\nid: t\nqtype: $qtype\n---\n\n## 题干\n\n内容';
      expect(parser.parse(md('choice')).problem!.qtype, QuestionType.choice);
      expect(parser.parse(md('fill')).problem!.qtype, QuestionType.fill);
      expect(parser.parse(md('proof')).problem!.qtype, QuestionType.proof);
      // 未知题型降级为 solve
      expect(parser.parse(md('weird')).problem!.qtype, QuestionType.solve);
    });

    // `needs_review` 曾经是**只写不读**的：序列化会写它，解析却不读它，
    // 于是"读进来再存回去"（编辑一次、批量维护一次）就把它静默清掉了。
    // 实测（2026-09-19）：一次批量维护清掉了 201 道导入题的待确认标记。
    group('needs_review 必须能被读回来', () {
      String md({required bool review}) => '---\nid: t\n'
          'subject: math1\nneeds_review: $review\n'
          '---\n\n## 题干\n\n内容';

      test('写了 true 就是 true（哪怕没有解析警告）', () {
        final r = parser.parse(md(review: true));
        expect(r.problem!.needsReview, isTrue);
        expect(r.problem!.warnings, isEmpty, reason: '这不是"解析有问题"，是显式标记');
      });

      test('写了 false 就是 false（显式字段优先）', () {
        expect(parser.parse(md(review: false)).problem!.needsReview, isFalse);
      });

      test('序列化后再解析，标记不丢（往返一致）', () {
        final p = parser.parse(md(review: true)).problem!;
        final again = parser
            .parse(ProblemMarkdownSerializer.serialize(p))
            .problem!;
        expect(again.needsReview, isTrue,
            reason: '往返会丢标记的话，用户编辑一次题就脱离了待确认队列');
      });

      test('没写这个字段时，仍按解析警告推导', () {
        // 缺 frontmatter 会产生警告 → 需要人工确认
        final r = parser.parse('设 \$x\$ 连续。');
        expect(r.problem!.needsReview, isTrue);
      });
    });
  });

  group('宽容原则：坏数据不能丢题', () {
    test('完全没有 frontmatter → 仍能读出题干，用 fallbackId', () {
      const md = '''
设 \$f(x)\$ 在 \$[0,1]\$ 上连续。

证明：存在 \$\\xi\$ 使 \$f(\\xi)=0\$。
''';
      final r = parser.parse(md, fallbackId: 'my-problem-01');
      expect(r.isOk, isTrue);
      expect(r.problem!.id, 'my-problem-01');
      expect(r.problem!.stem, contains(r'\xi'));
      expect(r.problem!.needsReview, isTrue);
      expect(r.problem!.warnings, isNotEmpty);
      // 自动算出指纹
      expect(r.problem!.fingerprint.length, 16);
    });

    test('自动指纹与 domain 层是同一个实现（中文全角标点不会算出两个值）', () {
      // ⚠️ 这条守着一个真实存在过的缺陷。
      //
      // `problem_markdown.dart` 里曾经有一份"看起来一样"的指纹算法副本，
      // 注释还写着"与 domain/fingerprint.dart 保持一致"，但它漏掉了那边的
      // `clean()` —— 全角标点归一、HTML 实体解码、不可见字符清除。
      //
      // 于是同一个题干经两条路径算出**不同**指纹：
      //   - 用户在录入页打字 → ProblemDraft.fingerprint() → domain 版本
      //   - 手工写 / 批量导入的 .md 没有 fingerprint 字段 → 副本版本
      //
      // 一旦不一致，`ProblemService.findByFingerprint` 永远查不到重复：
      // 同一道题被存成两条，错题次数与 FSRS 进度分成两份，
      // AI 标注缓存也会各花一次钱。而中文用全角标点是粘贴场景的常态。
      const md = '''
---
id: manual-01
subject: math1
qtype: solve
---

## 题干

求极限，当 \$x\\to0\$ 时 \$\\dfrac{\\sin x}{x}\$ 的值（重要）。
''';
      final r = parser.parse(md, fallbackId: 'manual-01');
      expect(r.isOk, isTrue);
      expect(r.problem!.fingerprint, isNotEmpty);
      expect(
        r.problem!.fingerprint,
        ProblemFingerprint.compute(r.problem!.stem),
        reason: '解析器算出的指纹必须与 domain 层一致，否则查重会失效',
      );
    });

    test('YAML 语法损坏 → 逐行抢救标量字段', () {
      // yaml 库会在这种缩进下抛错；抢救逻辑应把标量读出来
      const md = '''
---
id: salvaged-01
subject: math2
difficulty: 3
knowledge: [这个结构会被丢弃
---

## 题干

内容
''';
      final r = parser.parse(md, fallbackId: 'fb');
      expect(r.isOk, isTrue);
      final p = r.problem!;
      // 抢救出的字段生效（若 YAML 恰好解析成功也接受）
      expect(p.id, anyOf('salvaged-01', 'fb'));
      expect(p.stem, contains('内容'));
      expect(p.needsReview, isTrue);
    });

    test('题干为空 → 明确失败，不产生半个对象', () {
      const md = '---\nid: empty\n---\n\n## 答案\n\n只有答案没有题干';
      final r = parser.parse(md);
      expect(r.isOk, isFalse);
      expect(r.error, isNotNull);
    });

    test('缺少 primary 知识点 → 标记 needsReview', () {
      const md = '''
---
id: no-primary
knowledge:
  - id: math1.calc.limit.seq
    role: secondary
---

## 题干

内容
''';
      final r = parser.parse(md);
      expect(r.isOk, isTrue);
      expect(r.problem!.needsReview, isTrue);
      expect(
        r.problem!.warnings.any((w) => w.contains('primary')),
        isTrue,
      );
    });

    test('多个 primary 知识点 → 标记 needsReview', () {
      const md = '''
---
id: two-primary
knowledge:
  - id: a
    role: primary
  - id: b
    role: primary
---

## 题干

内容
''';
      final r = parser.parse(md);
      expect(r.problem!.needsReview, isTrue);
    });

    test('AI 置信度低于 0.7 → 自动进人工确认队列', () {
      const md = '''
---
id: low-conf
ai_tagged: true
ai_confidence: 0.55
knowledge:
  - id: some.kp
    role: primary
---

## 题干

内容
''';
      final r = parser.parse(md);
      expect(r.problem!.aiTagged, isTrue);
      expect(r.problem!.aiConfidence, 0.55);
      expect(r.problem!.needsReview, isTrue);
    });
  });

  group('正文分区容错', () {
    test('标题别名全部可识别', () {
      const md = '''
---
id: alias-test
---

## 题目

题干内容

## 解答

解析内容

## 笔记

笔记内容
''';
      final p = parser.parse(md).problem!;
      expect(p.stem, contains('题干内容'));
      expect(p.solution, contains('解析内容'));
      expect(p.note, contains('笔记内容'));
    });

    test('未识别的标题当作题干的一部分（宁可多不可漏）', () {
      const md = '''
---
id: unknown-heading
---

## 题干

内容一

## 一些额外说明

内容二
''';
      final p = parser.parse(md).problem!;
      expect(p.stem, contains('内容一'));
      expect(p.stem, contains('一些额外说明'));
      expect(p.stem, contains('内容二'));
    });

    test('标题带冒号或加粗也能识别', () {
      const md = '''
---
id: heading-variant
---

## **题干：**

内容

### 解析：

解析
''';
      final p = parser.parse(md).problem!;
      expect(p.stem, contains('内容'));
      expect(p.solution, contains('解析'));
    });
  });

  group('公式分隔符归一化', () {
    test(r'\( \) 与 \[ \] 被转成 $ 与 $$', () {
      const md = r'''
---
id: delim
---

## 题干

行内 \(a+b\) 与行间 \[c+d\]
''';
      final p = parser.parse(md).problem!;
      expect(p.stem, contains(r'$a+b$'));
      expect(p.stem, contains(r'$$c+d$$'));
      expect(p.stem, isNot(contains(r'\(')));
      expect(p.stem, isNot(contains(r'\[')));
    });

    test('equation 环境被转成 display math', () {
      const md = r'''
---
id: eq-env
---

## 题干

\begin{equation}
E = mc^2
\end{equation}
''';
      final p = parser.parse(md).problem!;
      expect(p.stem, contains(r'$$'));
      expect(p.stem, isNot(contains(r'\begin{equation}')));
    });
  });

  group('脏数据清理', () {
    test('不可见字符被清除', () {
      const md = '---\nid: dirty\n---\n\n## 题干\n\n设\u200Bf\u200C(x)\uFEFF=0';
      final p = parser.parse(md).problem!;
      expect(p.stem.contains('\u200B'), isFalse);
      expect(p.stem.contains('\u200C'), isFalse);
      expect(p.stem.contains('\uFEFF'), isFalse);
    });

    test('行尾空白被清除', () {
      const md = '---\nid: trailing\n---\n\n## 题干\n\n内容   \n\n更多  ';
      final p = parser.parse(md).problem!;
      expect(p.stem, '内容\n\n更多');
    });
  });

  group('列表与标量容错', () {
    test('error_causes 支持逗号分隔字符串', () {
      const md = '''
---
id: list-str
error_causes: [idea, calc]
knowledge:
  - id: k
    role: primary
---

## 题干

内容
''';
      final p = parser.parse(md).problem!;
      expect(p.errorCauses, ['idea', 'calc']);
    });

    test('knowledge 支持纯字符串简写', () {
      const md = '''
---
id: kp-short
knowledge: [math1.calc.limit.seq, math1.calc.limit.func]
---

## 题干

内容
''';
      final r = parser.parse(md);
      expect(r.problem!.knowledge.length, 2);
      // 简写没有 primary → 需人工确认
      expect(r.problem!.needsReview, isTrue);
    });

    test('difficulty 越界被夹到 [1,3]', () {
      String md(int d) => '---\nid: x\ndifficulty: $d\n---\n\n## 题干\n\n内容';
      expect(parser.parse(md(0)).problem!.difficulty, 1);
      expect(parser.parse(md(9)).problem!.difficulty, 3);
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  group('指纹计算', () {
    test('等价写法得到相同指纹（去空白/排版宏）', () {
      const a = r'设 $f(x)$ 连续，且 $\int_0^1 f(x) dx = 0$。';
      const b = r'设 $f(x)$   连续，且  $\displaystyle\int_0^1 f(x)\,\mathrm{d}x=0$。';

      final fa = ProblemFingerprint.compute(a);
      final fb = ProblemFingerprint.compute(b);

      expect(fa.length, 16);
      // 空白与 \displaystyle 应被消除；\mathrm{d} 也归一到 d
      expect(fa, fb);
    });

    test(r'\dfrac 与 \frac 视为相同', () {
      expect(
        ProblemFingerprint.compute(r'$\dfrac{1}{2}$'),
        ProblemFingerprint.compute(r'$\frac{1}{2}$'),
      );
    });

    test(r'\left \right 被忽略', () {
      expect(
        ProblemFingerprint.compute(r'$\left(\frac{a}{b}\right)$'),
        ProblemFingerprint.compute(r'$(\frac{a}{b})$'),
      );
    });

    test('不同题目得到不同指纹', () {
      expect(
        ProblemFingerprint.compute(r'求 $\lim_{x\to 0}\frac{\sin x}{x}$'),
        isNot(ProblemFingerprint.compute(r'求 $\lim_{x\to 0}\frac{\tan x}{x}$')),
      );
    });

    test('空输入返回空串，不抛异常', () {
      expect(ProblemFingerprint.compute(''), '');
      expect(ProblemFingerprint.compute('   '), '');
    });

    test('isSame 快捷判断', () {
      expect(ProblemFingerprint.isSame(r'$a+b$', r'$ a + b $'), isTrue);
      expect(ProblemFingerprint.isSame(r'$a+b$', r'$a-b$'), isFalse);
    });
  });
}
