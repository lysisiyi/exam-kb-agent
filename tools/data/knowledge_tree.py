#!/usr/bin/env python3
"""知识点本体的共享工具：树结构推导、层级约定校验。

## 为什么需要这个模块
知识点树的**层级深度在不同科目间不一致**：

- 数学一：`math1` → `math1.calc` → `math1.calc.limit` → 叶子（4 层）
- 数学三：`math3` → `math3.calc` → `math3.calc.limit` → `math3.calc.limit.seq` → 叶子（5 层，多了「节」）

所以**不能用固定的 id 段数或 `level` 字段判断"是不是章节"**。
可靠的结构定义只有"从父链接走出来的形状"：

1. **科目根** —— 无父节点，且 id 等于科目名（`math1`）
2. **学科分段** —— 父节点是科目根（`math1.calc`）
3. **考频层** —— 除上述之外、**全部子节点都是叶子**的非叶节点

第 3 条正是"考频数据记录在哪一层"：数学一/二落在章节（第 3 段），
数学三落在「节」（第 4 段）。`merge_frequency.py` 与 `merge_shards.py`
共用这里，保证两处口径一致。

## 与 App 里的 `KnowledgeBase.chapters` 不是一回事
App 的「章节」= **id 第 3 段**的非叶节点（= `KnowledgePoint.chapterId`），
三科分别是 19 / 11 / 20 个；本模块的"考频层"数学三是 42 个（「节」）。
两者同名不同义，别混用 —— App 侧只做画像聚合与导航，考频层是数据口径。
"""

from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
KP_DIR = ROOT / "data" / "knowledge_points"

SUBJECTS = ("math1", "math2", "math3")


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


def id_depth(node_id: str) -> int:
    """id 段数 = 节点在树里的深度（科目根为 1）。"""
    return len(node_id.split("."))


def leaf_ids_under(subject: str, node_id: str) -> list[str]:
    """[node_id] 子树下所有叶子的 id（按 id 排序）。

    ⚠️ 这个函数曾经**漏了定义**，而 `main()` 一直在调它 ——
    也就是说 `python tools/data/knowledge_tree.py` 直接 `NameError` 崩掉，
    而 README 与管线文档都把它列为"改完 data/ 之后要跑的自检"。
    脚本没被跑过，所以没坏过事；但也正因如此没人发现。
    """
    index = build_index(load_nodes(subject))
    out: list[str] = []

    def walk(nid: str, depth: int = 0) -> None:
        if depth > 10:
            return
        node = index["by_id"].get(nid)
        if node is None:
            return
        if node.get("is_leaf"):
            out.append(nid)
            return
        for cid in index["children"].get(nid, []):
            walk(cid, depth + 1)

    walk(node_id)
    return sorted(out)


def chapters_of(subject: str) -> list[str]:
    """返回该科目**考频数据应覆盖的粒度层** id 列表。

    判定：非叶子 + **全部子节点都是叶子** + 不是科目根 + 不是学科分段。
    数学一/二是章节（第 3 段），数学三是「节」（第 4 段）。

    ⚠️ 早先这里写的是"有叶子后代"，那样数学三的章节（其子节点是「节」）
    会与「节」一起入选 62 个 —— 与 `exam_frequency.json` 的 42 条对不上。
    改成"全部子节点都是叶子"后三科输出与实测口径一致（19 / 11 / 42）。
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
        kids = [index["by_id"].get(c) for c in index["children"].get(n["id"], [])]
        if not kids or any(k is None for k in kids):
            continue
        if all(k.get("is_leaf") for k in kids):
            out.append(n["id"])
    return sorted(out)


def verify_ontology(subject: str) -> list[str]:
    """校验一个科目的本体是否符合约定的结构。

    返回问题清单（空列表 = 通过）。这是**开发期自检**，
    由 `normalize_ontology.py --check` 与 CI 调用。
    """
    problems: list[str] = []
    nodes = load_nodes(subject)
    if not nodes:
        return [f"{subject}: 读不到节点"]

    index = build_index(nodes)
    ids = set(index["by_id"])

    roots = [n["id"] for n in nodes if is_root(n)]
    if roots != [subject]:
        problems.append(f"科目根应当只有一个且 id 等于科目名，实际是 {sorted(roots)}")

    for n in nodes:
        pid = n.get("parent_id")
        if pid and pid not in ids:
            problems.append(f"{n['id']}: parent_id={pid} 不存在")

        # level 必须等于 id 段数（树深）
        if n.get("level") != id_depth(n["id"]):
            problems.append(
                f"{n['id']}: level={n.get('level')} 与 id 段数 {id_depth(n['id'])} 不一致"
            )

        kids = index["children"].get(n["id"], [])
        if n.get("is_leaf"):
            if kids:
                problems.append(f"{n['id']}: 标成叶子却有 {len(kids)} 个子节点")
            continue
        if not kids:
            problems.append(f"{n['id']}: 非叶节点却没有任何子节点")

    chapters = [n for n in nodes if not n.get("is_leaf") and id_depth(n["id"]) == 3]
    if not chapters:
        problems.append("章节（id 第 3 段的非叶节点）数为 0 —— 导航与画像会全空")

    if not any(n.get("is_leaf") for n in nodes):
        problems.append("一个叶子都没有")

    return problems


def main() -> int:
    """自检：打印各科目的章节清单 + 结构校验结果。"""
    import sys

    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")

    failed = False
    for subject in SUBJECTS:
        chapters = chapters_of(subject)
        leaves = sum(len(leaf_ids_under(subject, c)) for c in chapters)
        print(f"\n{subject}: 考频层 {len(chapters)} 个 / {leaves} 叶子")
        for c in chapters:
            print(f"   {c:<34} {len(leaf_ids_under(subject, c)):>3} 叶子")

        problems = verify_ontology(subject)
        if problems:
            failed = True
            print(f"   ❌ 结构校验未通过（{len(problems)} 条）：")
            for p in problems[:12]:
                print(f"      - {p}")
        else:
            print("   ✅ 结构校验通过")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
