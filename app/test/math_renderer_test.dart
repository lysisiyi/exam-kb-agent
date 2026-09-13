/// 公式渲染缓存测试。
///
/// ## 为什么这个文件的优先级很高
///
/// V1 验收表里有一条硬指标：**错题本列表 5000 题滚动不掉帧**。
/// 列表每一项的题干里有 3–5 个公式，滚动时若每次都重新解析 LaTeX，
/// 掉帧是必然的。`MathRenderCache` 就是为这条指标写的。
///
/// 而审查时发现：这个缓存**在两条路径上都是死的** ——
/// 1. `main()` 注入的是未包装的 `PlainTextMathRenderer`，缓存压根没被用到；
/// 2. 就算包上 `CachedMathRenderer`，它的 `renderMarkdown()` 也**直接透传**，
///    而列表页走的正是 `renderMarkdown()`。
///
/// 第 2 条是真正的坑：它不会报错、不会崩，只是白写了一个缓存类。
/// 所以这里用"数内层被调了几次"的假渲染器把契约钉死。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/core/math/math_renderer.dart';

/// 记账用的假渲染器：数每个方法被调了几次。
class _CountingRenderer implements MathRenderer {
  int renders = 0;
  int markdowns = 0;

  @override
  Widget render(
    String latex, {
    MathStyle style = MathStyle.inline,
    MathRenderOptions options = MathRenderOptions.none,
  }) {
    renders++;
    return Text(latex);
  }

  @override
  Widget renderMarkdown(
    String markdown, {
    MathRenderOptions options = MathRenderOptions.none,
  }) {
    markdowns++;
    return Text(markdown);
  }

  @override
  bool supports(String latex) => true;

  @override
  String get name => 'counting';
}

void main() {
  setUp(MathRendering.reset);
  tearDown(MathRendering.reset);

  // ───────────────────────────────────────────────────────────────────────────
  group('MathRenderCache', () {
    test('同一 key 只构建一次', () {
      final cache = MathRenderCache();
      var built = 0;
      Widget build() {
        built++;
        return const SizedBox();
      }

      final a = cache.getOrBuild('x', MathStyle.inline, MathRenderOptions.none, build);
      final b = cache.getOrBuild('x', MathStyle.inline, MathRenderOptions.none, build);

      expect(built, 1);
      expect(identical(a, b), isTrue, reason: '命中缓存应当返回同一个 widget 实例');
      expect(cache.size, 1);
    });

    test('字号/颜色/可选性不同就是不同的 key', () {
      final cache = MathRenderCache();
      var built = 0;
      Widget build() {
        built++;
        return const SizedBox();
      }

      cache.getOrBuild('x', MathStyle.inline, MathRenderOptions.none, build);
      cache.getOrBuild(
          'x', MathStyle.inline, const MathRenderOptions(fontSize: 18), build);
      cache.getOrBuild(
          'x', MathStyle.display, const MathRenderOptions(fontSize: 18), build);
      cache.getOrBuild(
          'x',
          MathStyle.display,
          const MathRenderOptions(fontSize: 18, selectable: true),
          build);

      expect(built, 4, reason: '展示参数不同必须重新构建，否则会串样式');
    });

    test('超出上限按插入顺序淘汰', () {
      final cache = MathRenderCache(maxEntries: 3);
      for (var i = 0; i < 5; i++) {
        cache.getOrBuild('f$i', MathStyle.inline, MathRenderOptions.none,
            () => const SizedBox());
      }
      expect(cache.size, 3);

      // f0/f1 已被淘汰：再取一次会重新构建
      var rebuilt = false;
      cache.getOrBuild('f0', MathStyle.inline, MathRenderOptions.none, () {
        rebuilt = true;
        return const SizedBox();
      });
      expect(rebuilt, isTrue, reason: '最旧的应当已被淘汰');
    });

    test('clear 之后全部重算', () {
      final cache = MathRenderCache();
      cache.getOrBuild('x', MathStyle.inline, MathRenderOptions.none,
          () => const SizedBox());
      expect(cache.size, 1);

      cache.clear();
      expect(cache.size, 0);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('CachedMathRenderer', () {
    test('render 命中缓存，内层只被调一次', () {
      final inner = _CountingRenderer();
      final cached = CachedMathRenderer(inner);

      cached.render(r'\frac{1}{2}');
      cached.render(r'\frac{1}{2}');

      expect(inner.renders, 1);
      expect(cached.name, contains('cached'));
    });

    test('renderMarkdown 也必须命中缓存（列表页走的就是这条）', () {
      final inner = _CountingRenderer();
      final cached = CachedMathRenderer(inner);

      const md = r'求 $\lim_{x\to0}\frac{\sin x}{x}$ 的值。';
      cached.renderMarkdown(md);
      cached.renderMarkdown(md);

      expect(
        inner.markdowns,
        1,
        reason: 'renderMarkdown 若直接透传，列表页滚动时每次都重新解析 —— '
            '5000 题不掉帧就无从谈起',
      );
    });

    test('renderMarkdown 的缓存按字号区分', () {
      final inner = _CountingRenderer();
      final cached = CachedMathRenderer(inner);

      cached.renderMarkdown('x', options: const MathRenderOptions(fontSize: 13));
      cached.renderMarkdown('x', options: const MathRenderOptions(fontSize: 18));

      expect(inner.markdowns, 2, reason: '字号不同不能复用同一个 widget');
    });

    test('不同 markdown 各自缓存，互不串', () {
      final inner = _CountingRenderer();
      final cached = CachedMathRenderer(inner);

      cached.renderMarkdown('第一题');
      cached.renderMarkdown('第二题');
      cached.renderMarkdown('第一题');

      expect(inner.markdowns, 2);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('全局注册点', () {
    test('未注入时给纯文本兜底，绝不返回 null', () {
      expect(MathRendering.isConfigured, isFalse);
      expect(MathRendering.renderer, isA<PlainTextMathRenderer>());
    });

    test('注入后取到注入的实现，reset 后回到兜底', () {
      MathRendering.install(CachedMathRenderer(_CountingRenderer()));
      expect(MathRendering.isConfigured, isTrue);
      expect(MathRendering.renderer.name, contains('cached'));

      MathRendering.reset();
      expect(MathRendering.isConfigured, isFalse);
      expect(MathRendering.renderer, isA<PlainTextMathRenderer>());
    });
  });
}
