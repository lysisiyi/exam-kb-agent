#!/usr/bin/env python3
"""知识点条目速查 —— 用于人工审阅/补别名。

## 为什么需要它
给知识点补"符号别名"（技术债 T15）时必须先看清该知识点**现有**的
名称、定义、公式、陷阱，否则容易写出与已有信息重复、或与实际考点不符的别名。

直接翻 300KB 的 `math1.json` 不现实，本工具按 id 精确打印。

## 用法
    python tools/data/kp_probe.py math1.calc.limit.taylor
    python tools/data/kp_probe.py --subject math1 --grep 极值
    python tools/data/kp_probe.py --subject math1 --missing-aliases
    python tools/data/kp_probe.py --subject math1 --leaf-count
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

ROOT = Path(__file__).resolve().parents[2]
KP_DIR = ROOT / "data" / "knowledge_points"


def load(subject: str) -> dict:
    path = KP_DIR / f"{subject}.json"
    if not path.exists():
        raise SystemExit(f"找不到 {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def show(node: dict) -> None:
    print("=" * 74)
    print(f"{node.get('id')}")
    print(f"  名称      {node.get('name')}")
    print(f"  叶子      {node.get('is_leaf')}   考频 {node.get('exam_weight')}")
    print(f"  题型      {node.get('typical_qtypes')}")
    print(f"  别名      {node.get('aliases') or '（无）'}")
    definition = node.get("definition") or ""
    print(f"  定义      {definition}")
    for i, f in enumerate(node.get("formulas") or []):
        print(f"  公式[{i}]   {f}")
    for i, t in enumerate(node.get("common_traps") or []):
        print(f"  陷阱[{i}]   {t}")


def main() -> int:
    ap = argparse.ArgumentParser(description="知识点条目速查")
    ap.add_argument("ids", nargs="*", help="要查看的知识点 id")
    ap.add_argument("--subject", default="math1")
    ap.add_argument("--grep", help="按名称/定义模糊搜索")
    ap.add_argument("--missing-aliases", action="store_true",
                    help="列出所有还没有别名的叶子")
    ap.add_argument("--leaf-count", action="store_true", help="只统计叶子数")
    ap.add_argument("--limit", type=int, default=40)
    args = ap.parse_args()

    doc = load(args.subject)
    nodes = doc.get("nodes") or []
    by_id = {n["id"]: n for n in nodes if n.get("id")}

    if args.leaf_count:
        leaves = [n for n in nodes if n.get("is_leaf")]
        with_alias = [n for n in leaves if n.get("aliases")]
        print(f"{args.subject}: 节点 {len(nodes)} / 叶子 {len(leaves)} / "
              f"带别名 {len(with_alias)}")
        return 0

    if args.missing_aliases:
        leaves = [n for n in nodes if n.get("is_leaf") and not n.get("aliases")]
        print(f"{args.subject}: {len(leaves)} 个叶子没有别名")
        for n in leaves[: args.limit]:
            print(f"  {n['id']:<52} {n.get('name')}")
        return 0

    if args.grep:
        hits = [n for n in nodes
                if args.grep in (n.get("name") or "")
                or args.grep in (n.get("definition") or "")]
        print(f"匹配「{args.grep}」：{len(hits)} 个节点")
        for n in hits[: args.limit]:
            kind = "叶" if n.get("is_leaf") else "  "
            print(f"  [{kind}] {n['id']:<52} {n.get('name')}")
        return 0

    if not args.ids:
        ap.print_help()
        return 0

    for i in args.ids:
        node = by_id.get(i)
        if node is None:
            print(f"[X] 找不到 {i}")
            continue
        show(node)
    return 0


if __name__ == "__main__":
    sys.exit(main())
