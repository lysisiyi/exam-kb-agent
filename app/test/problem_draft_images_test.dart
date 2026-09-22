import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/data/markdown/problem_markdown.dart';
import 'package:kaoyan_math_agent/domain/problem_draft.dart';

/// `ProblemDraft` 对 images / imagesPrimary 的透传。
///
/// 背景：草稿本来不携带 `images` —— "编辑已录入的题"或对话助手改题
/// （`ChatWriteExecutor` 走 `ProblemDraft.fromProblem` → 改字段 → `build`）
/// 一次，配图就静默丢失。透传字段正是为此补的；本测试防止它再退化。
void main() {
  test('fromProblem → build 往返，images 与 imagesPrimary 原样保留', () {
    const p = Problem(
      id: 't',
      fingerprint: 'fp',
      stem: '题干',
      images: ['images/t-0.png', 'images/t-1.png'],
      imagesPrimary: true,
    );

    final rebuilt = ProblemDraft.fromProblem(p).build();

    expect(rebuilt.images, ['images/t-0.png', 'images/t-1.png']);
    expect(rebuilt.imagesPrimary, isTrue);
  });

  test('无图题目的草稿往返不受影响（默认空、false）', () {
    const p = Problem(id: 't', fingerprint: 'fp', stem: '题干');

    final rebuilt = ProblemDraft.fromProblem(p).build();

    expect(rebuilt.images, isEmpty);
    expect(rebuilt.imagesPrimary, isFalse);
  });

  test('copy() 深拷贝同样保留（撤销/重置表单不丢图）', () {
    const p = Problem(
      id: 't',
      fingerprint: 'fp',
      stem: '题干',
      images: ['images/t-0.png'],
      imagesPrimary: true,
    );

    final copied = ProblemDraft.fromProblem(p).copy().build();

    expect(copied.images, ['images/t-0.png']);
    expect(copied.imagesPrimary, isTrue);
  });
}
