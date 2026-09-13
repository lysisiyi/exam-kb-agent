#!/usr/bin/env python3
"""T17 置信度校准分析：模型自报的 confidence 到底能不能区分对错。

## 为什么必须单独算这个

标注引擎的**置信度门禁**是整个设计的支点：
`LlmConfig.confidenceThreshold` 按模型档位给 0.70 / 0.78 / 0.85，
低于门槛的进"人工确认队列"。它假设了「自报置信度 ≈ 正确概率」。

如果这个假设不成立，那么：
- 答错时不会进确认队列 → 用户**静默拿到错标签**
- 门禁形同虚设，等于没有

所以要按区间统计实际准确率 —— 这才叫校准（calibration）。

## 用法
    python tools/data/calibrate_t17.py app/build/t17b_*.json
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

BINS = [(0.0, 0.70), (0.70, 0.80), (0.80, 0.90), (0.90, 0.95), (0.95, 1.01)]


def main() -> int:
    files = sys.argv[1:]
    if not files:
        print("用法：python tools/data/calibrate_t17.py <t17b_*.json> ...")
        return 2

    rows: list[tuple[float, bool, str]] = []
    for f in files:
        p = Path(f)
        if not p.exists():
            print(f"[X] 找不到 {p}")
            continue
        doc = json.loads(p.read_text(encoding="utf-8"))
        for i in doc.get("items", []):
            c = i.get("confidence")
            if c is None or i.get("predicted") is None:
                continue
            rows.append((float(c), i.get("predicted") == i.get("expected"),
                         i.get("id", "?")))

    if not rows:
        print("没有可分析的样本（全部调用失败？）")
        return 1

    print("=" * 74)
    print(f"置信度校准（{len(rows)} 个样本，来自 {len(files)} 个金标准集）")
    print("=" * 74)
    print()
    print(f"{'置信度区间':<14}{'样本':>5}{'正确':>5}{'实际准确率':>10}   说明")
    print("-" * 74)
    for lo, hi in BINS:
        grp = [(c, ok) for c, ok, _ in rows if lo <= c < hi]
        if not grp:
            print(f"{f'[{lo:.2f}, {hi:.2f})':<14}{0:>5}{'—':>5}{'—':>10}")
            continue
        n = len(grp)
        k = sum(1 for _, ok in grp if ok)
        print(f"{f'[{lo:.2f}, {hi:.2f})':<14}{n:>5}{k:>5}{k / n:>9.1%}")

    print()
    total_ok = sum(1 for _, ok, _ in rows if ok)
    print(f"总体准确率 {total_ok / len(rows):.1%}")

    # 门禁的实际效果：门槛处切一刀，看有多少错例被拦住
    for thr in (0.70, 0.85, 0.90):
        flagged = [(c, ok) for c, ok, _ in rows if c < thr]
        wrong = [(c, ok) for c, ok, _ in rows if not ok]
        caught = sum(1 for c, _ in wrong if c < thr)
        print(f"  门槛 {thr:.2f}：进队列 {len(flagged)}/{len(rows)}"
              f"（{len(flagged) / len(rows):.0%}），"
              f"拦住的错例 {caught}/{len(wrong)}"
              f"（{caught / len(wrong):.0%}）")

    print()
    confs = [c for c, _, _ in rows]
    wrong_confs = [c for c, ok, _ in rows if not ok]
    print(f"置信度分布：全部 均值 {sum(confs) / len(confs):.2f} "
          f"[{min(confs):.2f}, {max(confs):.2f}]")
    if wrong_confs:
        print(f"            错例 均值 {sum(wrong_confs) / len(wrong_confs):.2f} "
              f"[{min(wrong_confs):.2f}, {max(wrong_confs):.2f}]")
        print()
        print("结论：若两者几乎重合，说明**自报置信度没有区分度**，")
        print("      置信度门禁不成立 —— 需要换信号（召回排名 / 自一致性 / 人工纠正入口）。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
