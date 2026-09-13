#!/usr/bin/env python3
"""一次性脚本：把"分片里有、权威文件里没有"的叶子 id 写成永久删除标记。

## 为什么需要它

`merge_shards.py` 是**并集**合并：分片里还留着每次去重删掉的节点副本，
不显式跳过就会把去重成果原样搬回来。

实测：不跳过时权威文件 142 个叶子，跑一遍管线就变回 170。

本脚本按"分片叶子 − 权威叶子"算出该跳过的集合，写进
`merge_map.json` 的 `suppressed_drops`。

⚠️ 这个集合是**自动算出来的**，但它不是"每次都自动排除分片里的未知 id"——
那样会让将来新增的分片永远合并不进来。所以落成显式列表。
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = Path(__file__).resolve().parents[2]
KP = ROOT / "data" / "knowledge_points"

NOTE = (
    "已删除、永不复活的叶子 id（永久删除标记）。"
    "它们在 AI 分片文件里还留着副本，而 merge_shards.py 是并集合并 —— "
    "不显式跳过就会把去重成果原样搬回权威文件"
    "（实测：不跳过时 math1 的 142 个叶子会变回 170）。"
    "本列表由『分片叶子 − 权威叶子』算出，包含两批："
    "1) 早期白名单去重删掉的；2) 2026-03-15 T19 合并映射删掉的。"
    "新增分片的 id 不在本列表里，所以仍然能正常合并进来。"
    "重新计算：tools/data/refresh_suppressed.py"
)


def main() -> int:
    auth: set[str] = set()
    for s in ("math1", "math2", "math3"):
        doc = json.loads((KP / f"{s}.json").read_text(encoding="utf-8"))
        auth |= {n["id"] for n in doc["nodes"] if n.get("is_leaf")}

    shard: set[str] = set()
    for p in sorted(KP.glob("math*_*.json")):
        doc = json.loads(p.read_text(encoding="utf-8"))
        shard |= {
            n["id"]
            for n in doc.get("nodes", [])
            if isinstance(n, dict) and n.get("is_leaf")
        }

    resurrect = sorted(shard - auth)

    mp = KP / "merge_map.json"
    doc = json.loads(mp.read_text(encoding="utf-8"))
    old = doc.get("suppressed_drops") or []
    doc["suppressed_drops"] = resurrect
    doc["suppressed_drops_note"] = NOTE
    mp.write_text(
        json.dumps(doc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    , newline="")

    print(f"权威叶子 {len(auth)}｜分片叶子 {len(shard)}")
    print(f"suppressed_drops: {len(old)} → {len(resurrect)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
