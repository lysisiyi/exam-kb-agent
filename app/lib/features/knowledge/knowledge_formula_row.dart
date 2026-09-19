/// 一行公式：保证**永远不会被静默裁掉**。
///
/// ## 三种排法（按公式实际宽度选）
///
/// | 情况 | 排法 |
/// |---|---|
/// | 放得下 | 原样，左对齐 |
/// | 只超一点（缩到 ≥ [minScale] 就放得下） | `FittedBox(scaleDown)` 轻微缩小 |
/// | 超太多 | 保持原字号 + **横向拖动**，并显示"可左右拖动"的提示 |
///
/// ## 为什么必须三选一，而不是一律缩小或一律裁掉
///
/// 本体的公式最长 227 字符（14px 下 691px 宽）。固定宽度的框里只做其中
/// 任何一件事都会有代价：
///
/// - **一律裁掉**：用户看到的是半条公式，而且**没有任何提示** ——
///   这正是"知识库有些公式显示不完整"的原因。
/// - **一律缩小**：691px 挤进 360px 要缩到 0.52，字号从 14px 变成 7px，
///   同样等于看不清 —— 只是把"裁掉"换成了"糊掉"，一样是静默降级。
/// - **一律横向滚动**：短公式也被塞进滚动容器，白白多一层交互。
///
/// 所以按实测宽度分档：绝大多数公式（中位数 235px）原样显示，
/// 边缘情况缩一点，真正超宽的少数才给滚动并**明确告诉用户**。
///
/// 宽度用 `renderToBox` 现算（0.245 ms/式，且这里带缓存），与 katex
/// 真正排版用的是同一个箱子树，所以判断与实际渲染一致。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:katex/katex.dart' as katex;
import 'package:katex_dart/katex_dart.dart' show KatexOptions, renderToBox;

import '../../core/math/math_renderer.dart';
import '../../core/theme/app_theme.dart';

/// 缩到这个比例还不放得下，就改成横向滚动（而不是继续缩）。
///
/// 0.72 的来源：正文 12.5px × 0.72 ≈ 9px，是有立体感的显示器上仍能读清
/// 上下标的下限；再小就属于"能看见但读不了"。
const double kFormulaMinScale = 0.72;

/// 公式宽度的缓存。键是 `字号|tex`。
///
/// 本体的全部公式也就 824 条，缓存整个语料不到 1000 项；不设上限是因为
/// 它天然有界（只有知识点里的公式会走这里）。
final Map<String, double> _widthCache = {};

/// 一条公式在 [fontSize] 下的像素宽度。解析失败返回 null。
double? formulaWidth(String tex, double fontSize) {
  final key = '${fontSize.toStringAsFixed(2)}|$tex';
  final hit = _widthCache[key];
  if (hit != null) return hit;
  try {
    final box = renderToBox(tex, options: const KatexOptions());
    final w = katex.boxSizePxPadded(box, fontSize).width;
    _widthCache[key] = w;
    return w;
  } catch (_) {
    return null; // 非法 LaTeX：交给渲染器去降级显示源码
  }
}

/// 仅供测试：清掉宽度缓存。
@visibleForTesting
void resetFormulaWidthCache() => _widthCache.clear();

/// 一行公式。
class KnowledgeFormulaRow extends StatelessWidget {
  /// 已经按顶层 `\quad` 拆好的**单个**片段。
  final String tex;

  /// 公式序号（从 1 起）。null 表示这条公式是上一条的续行。
  final int? index;

  /// 字号（逻辑像素 / em）。
  final double fontSize;

  const KnowledgeFormulaRow({
    super.key,
    required this.tex,
    this.index,
    this.fontSize = 12.5,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, c) {
        final avail = c.maxWidth;
        final need = formulaWidth(tex, fontSize);

        // 量不出来（非法 LaTeX）：交给渲染器降级，别在这里猜
        if (need == null || need <= avail) {
          return _row(context, _math());
        }
        if (need <= avail / kFormulaMinScale) {
          return _row(
            context,
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: _math(),
            ),
            // 缩过了：如实标一下，免得用户以为公式本来就小
            shrunkTo: (avail / need).clamp(0.0, 1.0),
          );
        }

        // 超太多：原字号 + 横向拖动，并**明确告知**
        return _row(
          context,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SingleChildScrollView(
                key: ValueKey('formula-scroll-$tex'),
                scrollDirection: Axis.horizontal,
                child: _math(),
              ),
              const SizedBox(height: 3),
              Row(
                key: ValueKey('formula-scroll-hint-$tex'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.swipe, size: 12, color: AppColors.ink3),
                  const SizedBox(width: 4),
                  Text(
                    '公式较宽，按住左右拖动查看完整内容',
                    style: AppTypography.caption.copyWith(fontSize: 10.5),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _math() => MathRendering.renderer.render(
        tex,
        style: MathStyle.inline,
        options: MathRenderOptions(fontSize: fontSize),
      );

  Widget _row(BuildContext context, Widget child, {double? shrunkTo}) {
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
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primaryStrong,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
          ),
          Expanded(child: child),
          _CopyButton(tex: tex),
          if (shrunkTo != null && shrunkTo < 0.999)
            Tooltip(
              message: '公式较宽，已缩小到 ${(shrunkTo * 100).round()}% 显示',
              child: const Padding(
                padding: EdgeInsets.only(left: 2, top: 2),
                child: Icon(Icons.zoom_out_map, size: 12, color: AppColors.ink3),
              ),
            ),
        ],
      ),
    );
  }
}

/// 复制 LaTeX 源码。
///
/// 为什么值得放到卡片里：用户常要把公式抄进笔记/Anki，而这片公式是
/// 位图式的 `CustomPaint`，**选不中、也复制不出来** —— 不给一个按钮，
/// 他就只能自己去翻知识点文件。
class _CopyButton extends StatelessWidget {
  final String tex;
  const _CopyButton({required this.tex});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '复制 LaTeX 源码',
      child: InkWell(
        key: ValueKey('formula-copy-$tex'),
        borderRadius: BorderRadius.circular(5),
        onTap: () async {
          await Clipboard.setData(ClipboardData(text: tex));
          if (!context.mounted) return;
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(
              content: Text('已复制 LaTeX 源码'),
              duration: Duration(seconds: 2),
            ),
          );
        },
        child: const Padding(
          padding: EdgeInsets.all(3),
          child: Icon(Icons.copy_all_outlined, size: 13, color: AppColors.ink4),
        ),
      ),
    );
  }
}
