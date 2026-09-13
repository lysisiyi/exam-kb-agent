#!/usr/bin/env python3
"""知识点本体的共享工具：从树结构推导"章节"节点。

## 为什么需要这个模块
知识点树的**层级深度在不同科目间不一致**：

- 数学一：`math1` → `math1.calc` → `math1.calc.limit` → 叶子（4 层）
- 数学三：`math3` → `math3.calc` → `math3.calc.limit` → `math3.calc.limit.seq` → 叶子（5 层，多了「节」）

所以**不能用 id 段数或名称前缀判断"是不是章节"**。可靠的定义只有两个：

1. **科目根**（如 `math1`）—— 排除
2. **学科分段**（如 `math1.calc`）—— 其直接父节点是科目根；排除
3. **章节** —— 除上述之外，**拥有叶子后代**的非叶子节点

数学三的「节」节点虽然也有叶子后代，但它的父节点是章节（第 3 类），
因此靠"父节点是学科分段或科目根"这一条即可把它排除。

本模块被 `merge_frequency.py`（校验考频 id 对齐）和
`merge_shards.py`（覆盖率统计）共同使用，保证两处口径一致。
"""

from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
KP_DIR = ROOT / "data" / "knowledge_points"


def load_nodes(subject: str) -> list[dict]:
    """读取权威知识点文件里的节点列表。"""
    p = KP_DIR / f"{subject}.json"
    if not p.exists():
        return []
    doc = json.loads(p.read_text(encoding="utf-8"))
    return [n for n in doc.get("nodes", []) if isinstance(n, dict) and n.get("id")]


def build_index(nodes: list[dict]) -> dict:
    """建立父子索引与后代查询所需的数据结构。"""
    by_id = {n["id"]: n for n in nodes}
    children: dict[str | None, list[str]] = {}
    for n in nodes:
        children.setdefault(n.get("parent_id"), []).append(n["id"])
    return {"by_id": by_id, "children": children}


def has_leaf_descendant(node_id: str, index: dict, depth: int = 0) -> bool:
    """该节点是否有叶子后代。"""
    if depth > 10:
        return False
    for cid in index["children"].get(node_id, []):
        child = index["by_id"].get(cid)
        if child is None:
            continue
        if child.get("is_leaf"):
            return True
        if has_leaf_descendant(cid, index, depth + 1):
            return True
    return False


def is_root(node: dict) -> bool:
    """科目根节点（无父节点）。"""
    return not node.get("parent_id")


def is_section(node: dict, index: dict) -> bool:
    """学科分段节点：父节点是科目根。

    如 `math1.calc`（父 `math1`）、`math3.prob`（父 `math3`）。
    """
    parent_id = node.get("parent_id")
    if not parent_id:
        return False
    parent = index["by_id"].get(parent_id)
    return parent is not None and is_root(parent)


def chapters_of(subject: str) -> list[str]:
    """返回该科目的**章节** id 列表（即考频数据应覆盖的粒度）。

    判定：非叶子 + 有叶子后代 + 不是科目根 + 不是学科分段。
    """
    nodes = load_nodes(subject)
    if not nodes:
        return []
    index = build_index(nodes)

    out: list[str] = []
    for n in nodes:
        if n.get("is_leaf"):
            continue
        if is_root(n) or is_section(n, index):
            continue
        if has_leaf_descendant(n["id"], index):
            out.append(n["id"])
    return sorted(out)


def leaf_ids_under(subject: str, chapter_id: str) -> list[str]:
    """某章节下的全部叶子 id。"""
    nodes = load_nodes(subject)
    index = build_index(nodes)

    out: list[str] = []

    def walk(nid: str, depth: int = 0) -> None:
        if depth > 10:
            return
        for cid in index["children"].get(nid, []):
            child = index["by_id"].get(cid)
            if child is None:
                continue
            if child.get("is_leaf"):
                out.append(cid)
            else:
                walk(cid, depth + 1)

    walk(chapter_id)
    return out


def main() -> int:
    """自检：打印各科目的章节清单，便于人工核对。"""
    import sys

    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")

    for subject in ("math1", "math2", "math3"):
        chapters = chapters_of(subject)
        leaves = sum(len(leaf_ids_under(subject, c)) for c in chapters)
        print(f"\n{subject}: {len(chapters)} 章 / {leaves} 叶子")
        for c in chapters:
            print(f"   {c:<34} {len(leaf_ids_under(subject, c)):>3} 叶子")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
