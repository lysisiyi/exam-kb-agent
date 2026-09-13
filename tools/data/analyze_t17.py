#!/usr/bin/env python3
"""T17 结果分析：把错例归类，并看置信度分布。

## 为什么单独写一个分析脚本

汇总数字（Top-1=66.7%）只说明"有问题"，不说明**问题在哪**。
要决定下一步做什么，必须分清两类错：

1. **召回 MISS** —— 期望答案根本没进候选（规则层的锅）
2. **选错** —— 进了候选但 LLM 挑了别的（判定层 / 本体粒度 / prompt 的锅）

再叠加置信度分布，还能看出**置信度门禁有没有在干活** ——
如果错了一大片却一个都没进人工确认队列，说明门禁形同虚设。

## 用法
    python tools/data/analyze_t17.py app/build/t17_gold_set.json
"""

from __future__ import annotations

import json
import sys
from collections import Counter
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")


def main() -> int:
    if len(sys.argv) < 2:
        print("用法：python tools/data/analyze_t17.py <t17_*.json>")
        return 2

    for arg in sys.argv[1:]:
        p = Path(arg)
        if not p.exists():
            print(f"[X] 找不到 {p}")
            continue
        doc = json.loads(p.read_text(encoding="utf-8"))
        items = doc.get("items", [])
        wrong = [i for i in items if i.get("predicted") != i.get("expected")]

        print("=" * 74)
        print(f"{p.name}   Top-1 {doc.get('top1Accuracy')}   "
              f"可接受 {doc.get('acceptableRate')}")
        print("=" * 74)

        if not wrong:
            print("  没有错例 ✅\n")
            continue

        miss = [i for i in wrong if i.get("recallRank") is None]
        chosen = [i for i in wrong if i.get("recallRank") is not None]
        print(f"  错例 {len(wrong)}/{len(items)}："
              f"召回 MISS {len(miss)} ｜ 进了候选但选错 {len(chosen)}")
        print()

        # 置信度分布 —— 门禁有没有在干活
        confs = [i["confidence"] for i in items if i.get("confidence") is not None]
        wrong_confs = [i["confidence"] for i in wrong
                       if i.get("confidence") is not None]
        if confs:
            print(f"  置信度：全部均值 {sum(confs)/len(confs):.2f}"
                  f"（区间 {min(confs):.2f}–{max(confs):.2f}）")
        if wrong_confs:
            print(f"          错例均值 {sum(wrong_confs)/len(wrong_confs):.2f}"
                  f"（区间 {min(wrong_confs):.2f}–{max(wrong_confs):.2f}）")
            flagged = [i for i in wrong if i.get("needsReview")]
            print(f"          错例里被标记待确认的：{len(flagged)}/{len(wrong)}")
        print()

        print("  ── 逐条 ──")
        for i in wrong:
            rank = i.get("recallRank")
            tag = "召回MISS" if rank is None else f"召回#{rank}"
            print(f"  {i['id']:<10} {tag:<10} conf={i.get('confidence')}")
            print(f"      期望 {i['expected']}")
            print(f"      预测 {i.get('predicted')}")
            if i.get("failure"):
                print(f"      失败 {i['failure'].splitlines()[0]}")
        print()

        # 预测错到哪去了 —— 看是否集中在少数几个叶子
        stray = Counter(i["predicted"] for i in wrong if i.get("predicted"))
        if stray:
            print("  ── 被误选的目标（Top 5） ──")
            for kp, n in stray.most_common(5):
                print(f"      {n}×  {kp}")
        print()

    return 0


if __name__ == "__main__":
    sys.exit(main())
