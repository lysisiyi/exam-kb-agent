/// 一个知识点的详情卡片。
///
/// 大纲视图（就地展开）与图谱视图（底部面板）共用同一份 ——
/// 两处各写一遍的话，同一个考点在两种视图里显示的信息迟早不一致。
///
/// ## 排版原则（用户反馈"公式和知识排版要有条理、增强可读性"）
///
/// 1. **每节都有标题**，标题带一条细线延伸到右边 —— 扫一眼就知道
///    这段是定义、那段是公式、下面是陷阱，而不是一坨同权重的文字。
/// 2. **公式一行一条并编号**：长公式先按顶层 `\quad` 拆（
///    见 `splitTopLevelQuad`），再交给 [KnowledgeFormulaRow] 保证
///    **永远不会被裁掉**。同一组公式的续行不重复编号。
/// 3. **陷阱编号列出**：`1. 2. 3.`，条与条之间留空，不再挤成一堆。
/// 4. **考频/题型这类字段左右对齐**成两列表，值不会因为标签长度不齐。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/math/latex_text_split.dart';
import '../../core/math/math_renderer.dart';
import '../../core/providers.dart';
import '../../core/theme/app_fonts.dart';
import '../../core/theme/app_theme.dart';
import '../../data/error_causes.dart';
import '../../data/problem_file.dart';
import '../../domain/knowledge/knowledge_point.dart';
import '../../services/llm/llm_client.dart';
import '../../services/profile/mastery_service.dart';
import '../problems/problem_detail.dart';
import '../problems/problem_images.dart';
import 'knowledge_formula_row.dart';
import 'knowledge_node_style.dart';
import 'knowledge_sizes.dart';

/// 知识点详情：定义 / 核心公式 / 常见陷阱 / 你的题目 / 考频 / 别名。
class KnowledgeLeafDetail extends ConsumerWidget {
  final KnowledgePoint leaf;

  /// 所属章节名（配合学科分段显示成面包屑，避免用户忘了在看哪一章）。
  final String? chapterName;

  /// 学科分段名（可选，用于面包屑的第一段）。
  final String? sectionName;

  const KnowledgeLeafDetail({
    super.key,
    required this.leaf,
    this.chapterName,
    this.sectionName,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 公式先按顶层 \quad 拆开，再逐条渲染 —— 见 splitTopLevelQuad 的说明
    final formulas = <String>[
      for (final f in leaf.formulas) ...splitTopLevelQuad(f),
    ];
    // 别名分两类：含 LaTeX 记号的要渲染成公式，纯文字保持 chip
    final latexAliases = [
      for (final a in leaf.aliases)
        if (_looksLikeLatex(a)) a,
    ];
    final textAliases = [
      for (final a in leaf.aliases)
        if (!_looksLikeLatex(a)) a,
    ];
    final crumbs = [
      if (sectionName != null && sectionName!.isNotEmpty) sectionName!,
      if (chapterName != null && chapterName!.isNotEmpty) chapterName!,
    ];

    return Container(
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
        children: [
          // ── 标题 ──────────────────────────────────────────────────────
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  leaf.name,
                  style: const TextStyle(
                    fontSize: KnowledgeSizes.heading,
                    fontWeight: FontWeight.w700,
                    height: 1.35,
                  ),
                ),
              ),
              // md 状态（与树上的状态点、页头 chips 同一口径：有定义即已填）
              _MdStatusPill(
                  filled: (leaf.definition ?? '').trim().isNotEmpty),
              if (leaf.examWeight != null) ...[
                const SizedBox(width: 6),
                _Stars(weight: leaf.examWeight!),
              ],
            ],
          ),
          // 参考图右上角「✍ AI 补全此节」——按钮在标题行，草稿框在下方。
          // 手动编辑同在标题行：二者是"自己写"与"让 AI 起草"两条并行的路。
          Align(
            alignment: Alignment.centerRight,
            // Wrap 而不是 Row：窄栏（560 两栏下的右卡 ≈260px）两个按钮
            // 一行放不下时换到第二行，而不是顶穿卡片。
            child: Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _ManualEditButton(leaf: leaf),
                _AiDraftButton(leaf: leaf, crumbs: crumbs),
              ],
            ),
          ),
          // 参考图：面包屑与 md 路径**同一行**（`章节 › 节 · …/x.md`）。
          // 一行放不下时路径先省略（它比面包屑次要），面包屑保持可读。
          const SizedBox(height: 4),
          Row(children: [
            if (crumbs.isNotEmpty) ...[
              Flexible(
                child: Text(crumbs.join(' › '),
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: KnowledgeSizes.secondary,
                        color: kSecondaryInk)),
              ),
              const SizedBox(width: 6),
              const Text('·',
                  style: TextStyle(
                      fontSize: KnowledgeSizes.secondary, color: AppColors.ink3)),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text(
                  '…/knowledge/${(crumbs.isNotEmpty ? crumbs.join('/') : leaf.id)}/${leaf.name}.md',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontFamily: AppFonts.mono,
                      fontFamilyFallback: AppFonts.monoFallback,
                      fontSize: KnowledgeSizes.secondary,
                      color: AppColors.ink3)),
            ),
          ]),

          // ── 定义 ──────────────────────────────────────────────────────
          if (leaf.definition != null && leaf.definition!.isNotEmpty) ...[
            const _SectionTitle('定义'),
            // 中文正文行高 1.85（clreq 建议 1.6–1.75 的上限一带；知识卡
            // 是逐字读的场景，宁松勿紧）。
            DefaultTextStyle.merge(
              // 中文正文行高 1.85（clreq 建议区间上限一带，逐字读宁松勿紧）
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
          ],

          // ── 核心公式 ──────────────────────────────────────────────────
          if (formulas.isNotEmpty) ...[
            _SectionTitle('核心公式', count: formulas.length),
            for (var i = 0; i < formulas.length; i++)
              KnowledgeFormulaRow(
                key: ValueKey('formula-${leaf.id}-$i'),
                tex: formulas[i],
                index: i + 1,
                // 刻意**不**传 fontSize：那会把 `kFormulaFontSize`
                // （= `AppMathSizes.reading`，14）这个决定覆盖掉，
                // 于是同一页里「别名公式」走 14、「核心公式」走 12.5。
                // 这里用默认值即可。
              ),
          ],

          // ── 常见陷阱 ──────────────────────────────────────────────────
          if (leaf.commonTraps.isNotEmpty) ...[
            _SectionTitle('常见陷阱', count: leaf.commonTraps.length),
            for (var i = 0; i < leaf.commonTraps.length; i++)
              _TrapItem(index: i + 1, text: leaf.commonTraps[i]),
          ],

          // ── AI 草稿框（有草稿才出现；参考图 ui_knowledge.png 的琥珀框） ──
          _DraftBox(leaf: leaf),

          // ── 你的题目 ──────────────────────────────────────────────────
          // 主考点挂在这里的错题清单（次考点命中折叠在下面）。
          // 数据是异步的，但节标题恒在 —— 加载中/失败都不改变卡片结构，
          // 只换这一节的内容（与错题本的错误态同一纪律：如实显示 + 出路）。
          _KpProblemsSection(kpId: leaf.id, causes: ref.watch(errorCauseCatalogProvider).valueOrNull),

          // ── 考频 / 题型 ───────────────────────────────────────────────
          const _SectionTitle('考频与题型'),
          _FactRow(
            label: '考频',
            value: leaf.examYears.isEmpty
                ? '暂无数据'
                : '近 ${leaf.examYears.length} 次考过'
                    '${leaf.examYears.isEmpty ? "" : " · 最近 ${leaf.examYears.last} 年"}',
          ),
          if (leaf.examYears.isNotEmpty)
            _FactRow(
              label: '年份',
              // 年份数量有限（一个热点最多十来次），全列出来比"近 N 次"
              // 更有用 —— 用户能直接看出"2021 与 2024 各一次"和"连考三年"
              // 的区别，那是两种完全不同的复习优先级。
              value: leaf.examYears.reversed.join('、'),
            ),
          _FactRow(
            label: '题型',
            value: leaf.typicalQtypes.isEmpty
                ? '—'
                : leaf.typicalQtypes.map(_qtypeLabel).join(' / '),
          ),
          if (leaf.difficultyRange.length == 2 &&
              (leaf.difficultyRange[0] != 1 || leaf.difficultyRange[1] != 3))
            _FactRow(
              label: '难度',
              value:
                  '${_difficultyLabel(leaf.difficultyRange[0])} – ${_difficultyLabel(leaf.difficultyRange[1])}',
            ),
          // ⚠️ 考频是**估算值**（exam_frequency.json 自述 data_confidence
          // 为 medium-low，README 许可节也要求 UI 必须标注）。不标的话
          // 用户会把它当官方逐题统计来规划复习 —— 那是它没有的精度。
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '考频为估算值，仅供安排优先级时参考，非官方逐题统计。',
              style: _secondary(KnowledgeSizes.secondary),
            ),
          ),

          // ── 别名 ──────────────────────────────────────────────────────
          if (leaf.aliases.isNotEmpty) ...[
            _SectionTitle('召回别名', count: leaf.aliases.length),
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '题干里可能这样写 —— 别名命中也会把这个考点召回给 AI',
                style: _secondary(KnowledgeSizes.secondary),
              ),
            ),
            // 文字别名（「极值」「二重积分」这类）用 chip 排；
            // **符号别名是 LaTeX**（实测 768 条里 182 条含 `\`/`_`/`^`），
            // 早先按普通文字显示 = 给用户看源码。现在按公式渲染，
            // 并且走同一套"不会被裁"的排版。
            if (textAliases.isNotEmpty)
              Wrap(
                spacing: 5,
                runSpacing: 5,
                children: [
                  for (final a in textAliases.take(12)) _AliasChip(text: a),
                  if (textAliases.length > 12)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text('+${textAliases.length - 12}',
                          style: _secondary(KnowledgeSizes.secondary)),
                    ),
                ],
              ),
            if (latexAliases.isNotEmpty) ...[
              if (textAliases.isNotEmpty) const SizedBox(height: 8),
              for (final a in latexAliases)
                KnowledgeFormulaRow(
                  key: ValueKey('alias-formula-${leaf.id}-$a'),
                  tex: a,
                  // 同样**不传** fontSize —— 这里此前硬编码传了 13，
                  // 于是同一张卡里「核心公式」走 `kFormulaFontSize`(16)、
                  // 「别名公式」走 13，又是一大一小。这是那处缺陷的残留。
                ),
            ],
          ],
        ],
      ),
    );
  }
}

String _difficultyLabel(int d) => switch (d) {
      1 => '基础',
      2 => '综合',
      3 => '拓展',
      _ => '难度$d',
    };

String _qtypeLabel(String q) => switch (q) {
      'choice' => '选择',
      'fill' => '填空',
      'solve' => '解答',
      'proof' => '证明',
      _ => q,
    };

/// 这条别名看起来是 LaTeX 吗？
///
/// 判据取保守方向：出现反斜杠命令、上下标、或 `$` 就按公式渲染。
/// 误判成公式的后果只是"多渲染一条"（文字改名也能被 katex 排出来），
/// 而**漏判**的后果是用户又看到一串源码 —— 两害相权取其轻。
bool _looksLikeLatex(String s) =>
    s.contains(r'\') || s.contains('_') || s.contains('^') || s.contains(r'$');

/// 卡片里的次要文字：比 `AppTypography.caption` 深一档。
///
/// `caption` 用的是 `ink3`，白底上只有 **3.2:1**，低于 AA 的 4.5:1；
/// 卡片里的面包屑、说明、计数都属于"要读的文字"，所以显式用 ink2。
TextStyle _secondary(double size) =>
    TextStyle(fontSize: size, color: kSecondaryInk);
/// 从本体里取出该考点的面包屑（学科分段 › 章节）。
///
/// 两个视图都要用它，所以放在这里 —— 各自写一遍迟早会不一致
/// （比如一个显示"高等数学 › 极限与连续"，另一个只显示章节名）。
({String? section, String? chapter}) detailBreadcrumb(
  KnowledgeBase kb,
  String leafId,
) {
  final path = kb.pathTo(leafId);
  // 叶子在第 4 段（数三在第 5 段，中间多个"节"），所以从后往前数：
  // 自身之前的那一级是章节，再往前一级是学科分段。
  final before =
      path.length >= 2 ? path.sublist(0, path.length - 1) : const <KnowledgePoint>[];
  final chapter = before.isNotEmpty ? before.last.name : null;
  final section = before.length >= 2 ? before[before.length - 2].name : null;
  return (section: section, chapter: chapter);
}

/// 小节标题：`标题 ────────`。
///
/// 细线不是装饰 —— 它把"标题"和"内容"在视觉上分开，卡片长了以后
/// 一眼能看出这一段的边界在哪。
class _SectionTitle extends StatelessWidget {
  final String text;
  final int? count;

  const _SectionTitle(this.text, {this.count});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 13, bottom: 7),
      child: Row(
        children: [
          // ⚠️ 必须 Flexible 包住：Row 给**非 flex** 子项的是无界主轴约束，
          // 裸 Text 会按自然宽度排版（曾以 151px 顶穿 128px 的紧约束）；
          // Flexible 之后 Text 才拿到有界宽度、省略号才会生效。
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: KnowledgeSizes.secondary,
                fontWeight: FontWeight.w700,
                // ink3 在卡片底色（bg）上只有 3.2:1，低于 AA —— 而分节标记
                // 是"一眼扫到就知道这段是什么"的东西，必须能读清
                color: kSecondaryInk,
                letterSpacing: 0.6,
              ),
            ),
          ),
          if (count != null) ...[
            const SizedBox(width: 5),
            Text(
              '$count 条',
              style: const TextStyle(
                  fontSize: KnowledgeSizes.secondary, color: kSecondaryInk),
            ),
          ],

        ],
      ),
    );
  }
}

/// 陷阱一条（参考图：纯文本编号行，琥珀色字，无底色）。
class _TrapItem extends StatelessWidget {
  final int index;
  final String text;

  const _TrapItem({required this.index, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(Icons.warning_amber_rounded,
                size: 13, color: AppColors.warning),
          ),
          const SizedBox(width: 5),
          SizedBox(
            width: 15,
            child: Text(
              '$index.',
              style: const TextStyle(
                fontSize: KnowledgeSizes.secondary,
                fontWeight: FontWeight.w700,
                color: AppColors.warningInk,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          Expanded(
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
}

/// 一个字段：标签列定宽，值左对齐 —— 多个字段叠起来就是一张对齐的表。
class _FactRow extends StatelessWidget {
  final String label;
  final String value;

  const _FactRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 40,
            child: Text(
              label,
              style: const TextStyle(
                  fontSize: KnowledgeSizes.body, color: kSecondaryInk),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: KnowledgeSizes.body,
                fontWeight: AppFonts.bold,
                color: AppColors.ink2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Stars extends StatelessWidget {
  final double weight;
  const _Stars({required this.weight});

  @override
  Widget build(BuildContext context) {
    // 参考图的"优先级 ★★"：按考频权重映射，暖橙显示（纯装饰性级别提示，
    // 考频为估算值的口径见「考频与题型」节）。
    final n = weight >= 0.85 ? 3 : (weight >= 0.6 ? 2 : 1);
    return Tooltip(
      message: '优先级 $n（按考频估算）',
      child: Text(
        '★' * n,
        style: const TextStyle(
          fontSize: KnowledgeSizes.secondary,
          fontWeight: FontWeight.w700,
          color: AppColors.warning,
          letterSpacing: 1.5,
        ),
      ),
    );
  }
}

class _AliasChip extends StatelessWidget {
  final String text;
  const _AliasChip({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text,
        style: const TextStyle(
            fontSize: KnowledgeSizes.secondary, color: AppColors.ink2),
      ),
    );
  }
}

/// 节点下题目的首图（D17 图像题面卡）。没有配图返回 null（行内不渲染）。
final kpProblemCoverProvider =
    FutureProvider.family<({String dir, String name})?, String>(
        (ref, problemId) async {
  final store = await ref.read(problemStoreProvider.future);
  final db = await ref.read(databaseProvider.future);
  final read = await readIndexedProblem(db: db, store: store, problemId: problemId);
  if (!read.isOk) return null;
  final problem = read.problem!;
  if (problem.images.isEmpty) return null;
  return (dir: store.imagesDir.path, name: problem.images.first);
});

/// 「你的题目」：主考点挂在这个考点下的错题清单（P1-1）。
///
/// ## 为什么放在知识点详情里
///
/// 用户在看一个考点时最想问的是"我这道题错得怎么样了"——
/// 错题本按题目组织、画像按人组织，只有这里是按**考点**组织的。
/// 数据全部现成（`problem_knowledge` 连接表 + `masteryNowOf` 现算），
/// 不写任何新状态进 Markdown。
///
/// ## 口径（与画像一致，2026-10-03 决策）
///
/// 主考点命中的题进清单主体；仅次考点关联的**折叠**在"也关联"里 ——
/// 与 `MasteryService` 聚合只用 primary 的口径相同，折叠而非丢弃
/// 则不漏信息。
class _KpProblemsSection extends ConsumerWidget {
  final String kpId;
  final ErrorCauseCatalog? causes;

  const _KpProblemsSection({required this.kpId, this.causes});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final problemsAsync = ref.watch(kpProblemsProvider(kpId));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          // Expanded：标题与「导入到此节点」同排时，标题拿剩余宽度并
          // 单行省略（_SectionTitle 的文本已 maxLines:1）——窄栏下换行会
          // 把整行撑高、且曾以单行 151px 溢出 64px 的余量。
          const Expanded(child: _SectionTitle('本节点题目 · 图像题面')),
          // 参考图右上角「＋ 导入到此节点」：切到宿主的「图像录入」标签
          TextButton.icon(
            onPressed: () {
              final controller = DefaultTabController.maybeOf(context);
              if (controller != null) {
                controller.animateTo(2);
              } else {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('入口在「知识库 › 图像录入」标签')));
              }
            },
            icon: const Icon(Icons.add, size: 14),
            style: TextButton.styleFrom(
                foregroundColor: AppColors.primaryStrong,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                minimumSize: const Size(0, 28)),
            label: const Text('导入到此节点', style: TextStyle(fontSize: 11.5)),
          ),
        ]),
        problemsAsync.when(
          loading: () => Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('正在读取题目…', style: _secondary(KnowledgeSizes.secondary)),
          ),
          error: (e, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ⚠️ 不能把读不出来渲染成"还没有题目" —— 那是 M8 修掉的
              // "看起来正常的空态"毛病在这里重演。如实报错 + 给出路。
              Text('题目读取失败：$e',
                  style: const TextStyle(
                      fontSize: KnowledgeSizes.secondary,
                      color: AppColors.danger)),
              const SizedBox(height: 4),
              TextButton.icon(
                onPressed: () => ref.invalidate(kpProblemsProvider(kpId)),
                icon: const Icon(Icons.refresh, size: 15),
                label: const Text('重试',
                    style: TextStyle(
                        fontSize: KnowledgeSizes.secondary,
                        color: kSecondaryInk)),
              ),
            ],
          ),
          data: (problems) {
            if (problems.isEmpty) {
              // 空槽而不是 0% —— "还没有题目"是**还没有**，不是"都不会"。
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '这个考点下还没有题目。录入或批量导入时把它选作主考点，'
                  '就会出现在这里。',
                  style: _secondary(KnowledgeSizes.secondary),
                ),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final e in problems.primary)
                  _KpProblemRow(
                    key: ValueKey('kp-problem-${e.id}'),
                    entry: e,
                    kpId: kpId,
                    causes: causes,
                  ),
                if (problems.secondary.isNotEmpty)
                  _SecondaryAssociation(items: problems.secondary, kpId: kpId, causes: causes),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// 一行错题：题面摘要 + 错因 + 错次 + 掌握度。点开完整详情。
class _KpProblemRow extends ConsumerWidget {
  final KpProblemEntry entry;
  final String kpId;
  final ErrorCauseCatalog? causes;

  const _KpProblemRow({
    super.key,
    required this.entry,
    required this.kpId,
    this.causes,
  });

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final store = await ref.read(problemStoreProvider.future);
    final db = await ref.read(databaseProvider.future);
    // 按索引真实路径读（P0-7）：外部题库 id ≠ 文件名是常态而非例外
    final read = await readIndexedProblem(
      db: db,
      store: store,
      problemId: entry.id,
    );
    if (!read.isOk || !context.mounted) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('读取失败：${read.error ?? '未知原因'}')),
        );
      }
      return;
    }
    // 详情里的编辑/删除会改变这个考点的清单与徽标数字 —— 一起失效。
    await openProblemDetail(context, ref, read.problem!, onChanged: () {
      ref.invalidate(kpProblemsProvider(kpId));
      ref.invalidate(masteryReportProvider);
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final e = entry;
    return InkWell(
      onTap: () => _open(context, ref),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 图像题面（D17）：有配图的题直接亮图，文字摘要退居其后。
                  ref.watch(kpProblemCoverProvider(e.id)).when(
                    loading: () => const SizedBox.shrink(),
                    error: (_, __) => const SizedBox.shrink(),
                    data: (cover) => cover == null
                        ? const SizedBox.shrink()
                        : Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: ProblemImageList(
                              images: [cover.name],
                              imagesDirPath: cover.dir,
                              maxHeight: 120,
                            ),
                          ),
                  ),
                  Text(
                    e.stemPreview.isEmpty ? '（无题干）' : e.stemPreview,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: KnowledgeSizes.body,
                      height: 1.5,
                      color: AppColors.ink1,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: Wrap(
                          spacing: 4,
                          runSpacing: 3,
                          children: [
                            for (final id in e.errorCauses.take(3))
                              _CauseChip(
                                label: causes?.nameOf(id) ?? id,
                                // 词表本身不带颜色 —— 错因在陷阱区走
                                // warning 系，这里保持同一语义
                                color: AppColors.warningInk,
                              ),
                            if (e.errorCauses.length > 3)
                              _CauseChip(
                                label: '+${e.errorCauses.length - 3}',
                                color: AppColors.ink3,
                              ),
                            if (e.needsReview)
                              const _CauseChip(
                                label: '待复核',
                                color: AppColors.warningInk,
                              ),
                          ],
                        ),
                      ),
                      // 有多少数据说多少话：掌握度是现算的（与画像同一函数），
                      // 没复习过显示"未复习"而不是 0% —— 那是两个意思。
                      Text(
                        '${e.mastery != null ? "掌握 ${(e.mastery! * 100).round()}%" : "未复习"}'
                        '${e.wrongCount > 0 ? " · 错 ${e.wrongCount} 次" : ""}',
                        style: const TextStyle(
                          fontSize: KnowledgeSizes.secondary,
                          color: kSecondaryInk,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(left: 4, top: 14),
              child: Icon(Icons.chevron_right, size: 16, color: AppColors.ink4),
            ),
          ],
        ),
      ),
    );
  }
}

/// 错因小 chip。
class _CauseChip extends StatelessWidget {
  final String label;
  final Color color;

  const _CauseChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
            fontSize: KnowledgeSizes.secondary,
            color: color,
            fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// 次考点关联折叠区。
class _SecondaryAssociation extends StatefulWidget {
  final List<KpProblemEntry> items;
  final String kpId;
  final ErrorCauseCatalog? causes;

  const _SecondaryAssociation({
    required this.items,
    required this.kpId,
    this.causes,
  });

  @override
  State<_SecondaryAssociation> createState() => _SecondaryAssociationState();
}

class _SecondaryAssociationState extends State<_SecondaryAssociation> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          borderRadius: BorderRadius.circular(5),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 2),
            child: Row(
              children: [
                Icon(
                  _open ? Icons.expand_less : Icons.expand_more,
                  size: 15,
                  color: AppColors.ink3,
                ),
                const SizedBox(width: 4),
                Text(
                  '也关联这个考点的题目（次考点，' '${widget.items.length}' ' 道）',
                  style: _secondary(KnowledgeSizes.secondary),
                ),
              ],
            ),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final e in widget.items)
                  _KpProblemRow(
                    key: ValueKey('kp-problem-sec-${e.id}'),
                    entry: e,
                    kpId: widget.kpId,
                    causes: widget.causes,
                  ),
              ],
            ),
          ),
      ],
    );
  }
}


/// md 状态小胶囊：已填（实心绿点）/ 骨架（空心点）。
class _MdStatusPill extends StatelessWidget {
  final bool filled;
  const _MdStatusPill({required this.filled});

  @override
  Widget build(BuildContext context) {
    final color = filled ? AppColors.success : AppColors.ink3;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: filled ? color : null,
            border: filled ? null : Border.all(color: color, width: 1.4),
          ),
        ),
        const SizedBox(width: 5),
        Text(filled ? '已填' : '骨架',
            style: TextStyle(
                fontSize: KnowledgeSizes.secondary,
                fontWeight: FontWeight.w700,
                color: color)),
      ]),
    );
  }
}

/// AI 草稿提示词：只依据给定信息起草，不编造；输出纯 Markdown 正文。
const _kDraftSystemPrompt =
    '你在帮用户完善他的知识库草稿。只依据给定信息起草，不要引入不确定的细节，宁可简短。\n'
    '输出纯 Markdown 正文（不要代码块围栏、不要任何小节标题）、依次是：一段简短定义；'
    '若干条核心公式（每条独立成行，用双美元号包裹）；若干条易错点（用 - 开头）。';

/// 该知识点 md 里现存的 AI 草稿正文（无草稿/无文件 = null）。
final kpAiDraftProvider =
    FutureProvider.family<String?, String>((ref, nodeId) async {
  final store = await ref.watch(knowledgeMdStoreProvider.future);
  final subject = ref.watch(currentSubjectProvider).id;
  final file = store.fileOf(subject, nodeId);
  if (file == null) return null;
  return store.draftOf(file);
});

/// 「✍ AI 补全此节」按钮（参考图右上）。生成草稿写进 md 的
/// `## AI 草稿（待确认）` 小节——**用户点"接纳"之前绝不并入正式内容**。
class _AiDraftButton extends ConsumerStatefulWidget {
  final KnowledgePoint leaf;
  final List<String> crumbs;
  const _AiDraftButton({required this.leaf, required this.crumbs});

  @override
  ConsumerState<_AiDraftButton> createState() => _AiDraftButtonState();
}

class _AiDraftButtonState extends ConsumerState<_AiDraftButton> {
  bool _busy = false;

  Future<File?> _fileFor() async {
    final store = await ref.read(knowledgeMdStoreProvider.future);
    final subject = ref.read(currentSubjectProvider).id;
    return store.fileOf(subject, widget.leaf.id);
  }

  void _say(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _generate() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final client = ref.read(chatClientProvider);
      if (client == null) {
        _say('先到「设置」里配好 AI 服务商（文本模型即可）。');
        return;
      }
      final file = await _fileFor();
      if (file == null) {
        _say('找不到这个知识点的 md 文件——知识库需来自 knowledge/ 文件夹（K1 导入）。');
        return;
      }
      final leaf = widget.leaf;
      final resp = await client.chat(ChatRequest(
        system: _kDraftSystemPrompt,
        user: '知识点：${leaf.name}\n'
            '章节：${widget.crumbs.join(' › ')}\n'
            '已有定义：${(leaf.definition ?? '').trim().isEmpty ? '（无）' : leaf.definition}\n'
            '已有公式：${leaf.formulas.isEmpty ? '（无）' : leaf.formulas.join('；')}',
        temperature: 0.3,
        maxTokens: 1024,
      ));
      final store = await ref.read(knowledgeMdStoreProvider.future);
      store.writeAiDraft(file, resp.text.trim());
      ref.invalidate(kpAiDraftProvider(widget.leaf.id));
      _say('草稿已写入 md 的「AI 草稿（待确认）」小节。');
    } catch (e) {
      _say('生成失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasDraft =
        (ref.watch(kpAiDraftProvider(widget.leaf.id)).valueOrNull ?? '')
            .isNotEmpty;
    return TextButton.icon(
      onPressed: _busy ? null : _generate,
      icon: _busy
          ? const SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.auto_awesome, size: 15),
      label: Text(hasDraft ? '重新生成草稿' : 'AI 补全此节'),
      style: TextButton.styleFrom(
          foregroundColor: AppColors.primaryStrong,
          padding: const EdgeInsets.symmetric(horizontal: 8)),
    );
  }
}

/// 「✍ 手动编辑」：定义 / 公式 / 陷阱三个字段直接改 md（事实源）。
class _ManualEditButton extends ConsumerStatefulWidget {
  final KnowledgePoint leaf;
  const _ManualEditButton({required this.leaf});

  @override
  ConsumerState<_ManualEditButton> createState() => _ManualEditButtonState();
}

class _ManualEditButtonState extends ConsumerState<_ManualEditButton> {
  Future<void> _open() async {
    final leaf = widget.leaf;
    final defCtl = TextEditingController(text: leaf.definition ?? '');
    final formulaCtl =
        TextEditingController(text: leaf.formulas.join('\n'));
    final trapCtl = TextEditingController(text: leaf.commonTraps.join('\n'));
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('手动编辑 · ${leaf.name}'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: defCtl,
                maxLines: 4,
                minLines: 2,
                decoration: const InputDecoration(hintText: '定义（可留空=删除该节）'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: formulaCtl,
                maxLines: 4,
                minLines: 2,
                decoration:
                    const InputDecoration(hintText: '公式：一行一条（自动包成数学块）'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: trapCtl,
                maxLines: 4,
                minLines: 2,
                decoration: const InputDecoration(hintText: '陷阱：一行一条（自动编号）'),
              ),
              const SizedBox(height: 6),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('写回知识节点的 md（事实源）；其余小节与笔记回流不受影响。',
                    style: TextStyle(fontSize: 11, color: AppColors.ink3)),
              ),
            ]),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final store = await ref.read(knowledgeMdStoreProvider.future);
    final subject = ref.read(currentSubjectProvider).id;
    final file = store.fileOf(subject, leaf.id);
    if (file == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('找不到该知识点的 md 文件（先确认知识库来自 knowledge/ 文件夹）')));
      }
      return;
    }
    store.updateNodeContent(
      file,
      definition: defCtl.text,
      formulas: formulaCtl.text
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(),
      traps: trapCtl.text
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(),
    );
    ref.invalidate(knowledgeBaseProvider);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已写回节点 md')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: _open,
      icon: const Icon(Icons.edit_outlined, size: 15),
      label: const Text('手动编辑'),
      style: TextButton.styleFrom(
          foregroundColor: AppColors.ink2,
          padding: const EdgeInsets.symmetric(horizontal: 8)),
    );
  }
}

/// 草稿琥珀框：渲染草稿 + ✓接纳进「定义」/ 丢弃。
class _DraftBox extends ConsumerWidget {
  final KnowledgePoint leaf;
  const _DraftBox({required this.leaf});

  Future<void> _accept(BuildContext context, WidgetRef ref) async {
    final store = await ref.read(knowledgeMdStoreProvider.future);
    final file = store.fileOf(ref.read(currentSubjectProvider).id, leaf.id);
    if (file == null) return;
    store.acceptAiDraft(file);
    ref.invalidate(kpAiDraftProvider(leaf.id));
    ref.invalidate(knowledgeBaseProvider); // 定义变了 → 树状态点刷新
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已接纳进「定义」小节。')));
    }
  }

  Future<void> _discard(BuildContext context, WidgetRef ref) async {
    final store = await ref.read(knowledgeMdStoreProvider.future);
    final file = store.fileOf(ref.read(currentSubjectProvider).id, leaf.id);
    if (file == null) return;
    store.discardAiDraft(file);
    ref.invalidate(kpAiDraftProvider(leaf.id));
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('草稿已丢弃。')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(kpAiDraftProvider(leaf.id)).valueOrNull;
    if (draft == null || draft.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 13),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
        decoration: BoxDecoration(
          color: AppColors.warningWeak,
          borderRadius: AppRadius.rMd,
          border: Border.all(color: AppColors.warning.withValues(alpha: 0.45)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('✨ AI 草稿（待确认） · 不会在接纳前并入正式内容',
                style: TextStyle(
                    fontSize: KnowledgeSizes.secondary,
                    fontWeight: FontWeight.w700,
                    color: AppColors.warningInk)),
            const SizedBox(height: 6),
            MathRendering.renderer.renderMarkdown(
              draft,
              options: const MathRenderOptions(fontSize: AppMathSizes.reading),
            ),
            const SizedBox(height: 8),
            Row(children: [
              FilledButton(
                onPressed: () => _accept(context, ref),
                style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 6),
                    minimumSize: const Size(0, 32)),
                child:
                    const Text('✓ 接纳进「定义」', style: TextStyle(fontSize: 12)),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => _discard(context, ref),
                style: OutlinedButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    minimumSize: const Size(0, 32)),
                child: const Text('丢弃', style: TextStyle(fontSize: 12)),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
