#!/usr/bin/env python3
"""把知识点本体的**层级字段与父链接**归一，并做结构自检。

## 这个脚本修的是什么

三个科目的本体是不同时期编的，`level` 字段与父链接各写各的：

| 科目 | 树的形状 | 修之前的 level | 修之前的问题 |
|---|---|---|---|
| math1 | 科目 → 分段 → 章节 → 叶子 | 1 / 2 / **2** / 4 | 章节标成了 2 → App 的"章节"数变 0 |
| math2 | 科目 → 分段 → 章节 → 叶子 | 1 / 2 / 3 / 4 ✅ | 无 |
| math3 | 科目 → 分段 → 章节 → 节 → 叶子 | **1 / 1 / 2 / 3 / 4** | 三个分段没挂在科目根下（根是空壳） |

约定只有一条：**`level` == id 段数（科目根为 1）**。三科树的深度本来就
不同（math3 多一层「节」），所以 level 表示"第几层"，不表示"是什么"。

## 两个模式

```bash
python tools/data/normalize_ontology.py --check   # 只校验，有问题退出码 1
python tools/data/normalize_ontology.py           # 就地修正 level 与父链接
```

修完记得同步到 assets：`python tools/data/sync_assets.py`
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import knowledge_tree as kt  # noqa: E402

KP_DIR = kt.KP_DIR


def _load(subject: str) -> tuple[Path, dict]:
    p = KP_DIR / f"{subject}.json"
    doc = json.loads(p.read_text(encoding="utf-8"))
    return p, doc


def fix_nodes(nodes: list[dict], subject: str) -> tuple[list[dict], list[str]]:
    """就地修正：level = id 段数；游离的分段挂到科目根下。

    返回 (新节点列表, 变更说明)。
    """
    changes: list[str] = []
    ids = {n.get("id") for n in nodes}

    for n in nodes:
        nid = n.get("id")
        if not nid:
            continue
        want = kt.id_depth(nid)

        # 游离节点：既不是科目根、又没有父节点 —— 挂到科目根下
        if nid != subject and not n.get("parent_id"):
            n["parent_id"] = subject
            changes.append(f"{nid}: parent_id 补成 {subject}（原来是游离的）")

        if n.get("level") != want:
            changes.append(f"{nid}: level {n.get('level')} → {want}")
            n["level"] = want

    # 父节点必须存在，否则挂到科目根（并如实记账）
    for n in nodes:
        pid = n.get("parent_id")
        if pid and pid not in ids:
            changes.append(f"{n['id']}: parent_id={pid} 不存在 → 改挂 {subject}")
            n["parent_id"] = subject

    return nodes, changes


def main() -> int:
    ap = argparse.ArgumentParser(description="知识点本体层级归一 / 自检")
    ap.add_argument("--check", action="store_true", help="只校验，不写文件")
    ap.add_argument("--subject", help="只处理指定科目")
    args = ap.parse_args()

    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")

    subjects = [args.subject] if args.subject else list(kt.SUBJECTS)
    exit_code = 0

    for subject in subjects:
        path, doc = _load(subject)
        nodes = doc.get("nodes") or []

        problems_before = kt.verify_ontology(subject)
        print(f"\n=== {subject}（{len(nodes)} 个节点）")
        if not problems_before:
            print("   ✅ 已经符合约定，无需改动")
            continue

        print(f"   结构问题 {len(problems_before)} 条：")
        for p in problems_before[:8]:
            print(f"      - {p}")
        if len(problems_before) > 8:
            print(f"      …… 另有 {len(problems_before) - 8} 条")

        if args.check:
            exit_code = 1
            continue

        fixed, changes = fix_nodes(nodes, subject)
        doc["nodes"] = fixed
        # ⚠️ 必须显式 `newline="\n"`：Windows 上默认会把 `\n` 翻成 `\r\n`，
        # 而仓库里所有文件都是 LF（见 .gitattributes）—— 行尾一乱，
        # 整个文件在 diff 里全变，评审时看不出真正改了什么。
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(json.dumps(doc, ensure_ascii=False, indent=2) + "\n")
        print(f"   ✍️  已修正 {len(changes)} 处，写入 {path.name}")
        for c in changes[:5]:
            print(f"      · {c}")
        if len(changes) > 5:
            print(f"      …… 另有 {len(changes) - 5} 处")

        problems_after = kt.verify_ontology(subject)
        if problems_after:
            exit_code = 1
            print(f"   ❌ 修正后仍有 {len(problems_after)} 条问题：")
            for p in problems_after[:8]:
                print(f"      - {p}")
        else:
            print("   ✅ 修正后结构校验通过")

    if not args.check:
        print("\n提示：改动 data/ 之后要跑 `python tools/data/sync_assets.py`")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
