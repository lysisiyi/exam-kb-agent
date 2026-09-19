#!/usr/bin/env python3
"""多分片知识点合并器 —— 按 id 合并所有来源，并报告覆盖缺口。

## 为什么需要它
知识点本体由多次 AI 生成产出，分片命名不统一（`math1_calc.json`、
`math1_rest.json`、`math2.new.json`…），且**同一 id 可能在多个分片里重复**
（不同批次生成的重叠部分）。

手工挑"用哪个文件"是错的 —— 正确做法是**按 id 合并全部来源**，
冲突时保留信息更完整的那个，最后报告**哪些章节还没覆盖**。

## 用法
    python tools/data/merge_shards.py --dry-run      # 只报告，不写文件
    python tools/data/merge_shards.py                # 实际合并
    python tools/data/merge_shards.py --subject math1
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

ROOT = Path(__file__).resolve().parents[2]
KP_DIR = ROOT / "data" / "knowledge_points"

def _import_sibling(module_name: str):
    """导入同目录下的兄弟模块（这些脚本是命令行工具而非包）。"""
    import importlib.util

    path = Path(__file__).resolve().parent / f"{module_name}.py"
    spec = importlib.util.spec_from_file_location(f"_kp_{module_name}", path)
    if spec is None or spec.loader is None:
        raise ImportError(f"无法加载 {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


knowledge_tree = _import_sibling("knowledge_tree")
dedupe = _import_sibling("dedupe_knowledge")

# ─────────────────────────────────────────────────────────────────────────────
# 永远不要复活已被去重删除的节点
# ─────────────────────────────────────────────────────────────────────────────
#
# ⚠️ 这是实测踩到的坑。`dedupe_knowledge.py` 删掉的冗余叶子仍然留在各个
# AI 分片文件里（分片是历史产物，不回收）。而本脚本是**并集**合并，
# 于是"按文档顺序跑一遍管线"会把那些重复叶子原样搬回权威文件：
#
#     权威文件 142 叶子  --merge_shards-->  170 叶子（重复全部复活）
#
# 后果很隐蔽：不报错，但 LLM 又要在两个同名选项间掷硬币，标注准确率下降。
#
# 修法：维护一份**永久删除标记**，合并时直接跳过。它由两部分组成：
#
#   1. `merge_map.json` 的 `drops`     —— 本次合并映射删掉的
#   2. `merge_map.json` 的 `suppressed_drops` —— 早期白名单删掉的补集
#      （只从 drops 取会漏掉早期那批，实测漏 28 个）
DROPPED_IDS: set[str] = (
    {d for _, drops in dedupe.KNOWN_DUPLICATES for d in drops}
    | dedupe.load_suppressed_drops()
)

# ⚠️ 章节清单**不再硬编码**。
#
# 早期版本在这里手写各科目的章节 id 列表，结果错得很隐蔽：
# 数学三是 5 层树（章 → 节 → 叶子），可考查单元是「节」那一层（42 个），
# 而不是「章」那一层（20 个）。硬编码清单把数三误报成 20 章。
#
# 现在改为从权威知识点文件**按树结构推导**：凡拥有叶子后代的非叶子节点
# 且不是科目根 / 学科分段，即为章节。见 `knowledge_tree.py`。


def expected_chapters(subject: str) -> list[str]:
    """该科目应当覆盖的章节 id（从知识点本体推导，不是硬编码）。"""
    return knowledge_tree.chapters_of(subject)

# 分片文件名 → 是否是"待合并的输入"（权威文件本身不作为输入）
AUTHORITATIVE = {"math1.json", "math2.json", "math3.json"}
SKIP_SUFFIX = (".merged", ".partial", ".bak")


def node_quality(n: dict) -> int:
    """节点信息完整度打分，用于冲突时决定保留哪一个。"""
    score = 0
    if n.get("definition"):
        score += 3 + min(len(n["definition"]) // 40, 5)
    score += min(len(n.get("formulas") or []), 6)
    score += min(len(n.get("common_traps") or []), 6)
    score += min(len(n.get("exam_years") or []), 8)
    if n.get("typical_qtypes"):
        score += 2
    if n.get("difficulty_range"):
        score += 1
    # 别名是人工/工具产出的资产（见 tools/data/gen_aliases.py），
    # 有别名的一侧更完整。不过真正的保障是 collect() 里的并集回填 ——
    # 打分只影响"选哪一份正文"，不该决定"别名还在不在"。
    if n.get("aliases"):
        score += 2
    return score


def collect(subject: str) -> tuple[dict[str, dict], list[str]]:
    """收集该科目的全部节点，按 id 去重（保留质量更高的）。

    **权威文件（`{subject}.json`）也作为输入** —— 否则会把已完成的章节
    （如数学一的「极限与连续」）误判为缺失。

    ## 别名为什么要单独做并集回填

    `aliases` 不是 AI 分片带出来的字段，而是 `tools/data/gen_aliases.py`
    事后写进权威文件的**派生产物**（名称片段 + 人工符号别名）。

    如果只靠 `node_quality` 决定保留哪一份，就会出现：
    某个 AI 分片恰好比权威文件的正文更全 → 选中分片那份 → 别名整批消失，
    而且**没有任何报错**，直到召回率悄悄掉回 73%。

    所以别名按 id 做真并集，与"选中哪一份正文"解耦。
    """
    by_id: dict[str, dict] = {}
    sources: list[str] = []
    # id → 别名并集（保序去重）
    alias_union: dict[str, list[str]] = {}

    candidates = [
        p for p in sorted(KP_DIR.glob(f"{subject}*.json"))
        if not any(p.name.endswith(s) for s in SKIP_SUFFIX)
    ]

    for p in candidates:
        try:
            doc = json.loads(p.read_text(encoding="utf-8"))
        except Exception as e:
            print(f"  [X] 跳过 {p.name}：JSON 解析失败 {e}")
            continue

        if doc.get("subject") != subject:
            continue

        nodes = doc.get("nodes")
        if not isinstance(nodes, list):
            print(f"  [X] 跳过 {p.name}：nodes 不是数组")
            continue

        sources.append(p.name)
        bad = 0
        skipped_dropped = 0
        for n in nodes:
            if not isinstance(n, dict) or not n.get("id"):
                bad += 1
                continue
            nid = n["id"]

            # 已去重的冗余节点不参与合并（见 DROPPED_IDS 的说明）
            if nid in DROPPED_IDS:
                skipped_dropped += 1
                continue

            # 别名并集：先收集，最后统一写回
            for a in n.get("aliases") or []:
                bucket = alias_union.setdefault(nid, [])
                if a not in bucket:
                    bucket.append(a)

            prev = by_id.get(nid)
            if prev is not None and node_quality(n) > node_quality(prev):
                # 新来源信息更完整，替换
                by_id[nid] = n
            elif prev is None:
                by_id[nid] = n
        if bad:
            print(f"  [!] {p.name}: 跳过 {bad} 个非法元素（该文件生成不完整）")
        if skipped_dropped:
            print(f"  [i] {p.name}: 跳过 {skipped_dropped} 个已去重的冗余节点")

    # 别名并集回填（覆盖选中那份可能缺失/更少的别名）
    restored = 0
    for nid, aliases in alias_union.items():
        node = by_id.get(nid)
        if node is None or not aliases:
            continue
        if node.get("aliases") != aliases:
            node["aliases"] = aliases
            restored += 1
    if restored:
        print(f"  [i] 别名并集回填 {restored} 个节点"
              f"（防止分片替换正文时丢掉派生别名）")

    return by_id, sources


def coverage_report(subject: str, by_id: dict[str, dict]) -> tuple[list[str], list[str]]:
    """返回 (已覆盖章节, 缺失章节)。

    "已覆盖"的判定：该章节下**至少有一个叶子存在**（不要求全部叶子都在）。
    章节清单来自知识点本体的树结构推导，不是硬编码。
    """
    expected = expected_chapters(subject)

    # 收集本次合并结果中出现的全部节点 id
    present_ids = set(by_id.keys())

    # 一个章节算"已覆盖"，当且仅当它下挂的任一叶子出现在结果里
    present: set[str] = set()
    for ch in expected:
        leaves = knowledge_tree.leaf_ids_under(subject, ch)
        if any(lid in present_ids for lid in leaves):
            present.add(ch)

    done = [c for c in expected if c in present]
    missing = [c for c in expected if c not in present]
    return done, missing


def ensure_anchors(nodes: list[dict], subject: str, subject_name: str) -> list[dict]:
    """补齐根节点与学科分段节点，并把 level / 父链接归一。"""
    existing = {n["id"] for n in nodes if n.get("id")}
    section_names = {
        "calc": "高等数学", "linalg": "线性代数", "prob": "概率论与数理统计",
    }

    out = list(nodes)
    if subject not in existing:
        out.insert(0, {
            "id": subject, "name": subject_name, "level": 1,
            "parent_id": None, "is_leaf": False, "exam_weight": 1.0,
        })
        existing.add(subject)

    needed = set()
    for n in out:
        pid = n.get("parent_id")
        if pid and pid.startswith(f"{subject}.") and pid.count(".") == 1:
            needed.add(pid)

    for sec in sorted(needed):
        if sec in existing:
            continue
        key = sec.split(".")[-1]
        out.append({
            "id": sec, "name": section_names.get(key, key), "level": 2,
            "parent_id": subject, "is_leaf": False, "exam_weight": 0.9,
        })
        existing.add(sec)

    # 归一：`level` 必须等于 id 段数（树深），游离节点挂到科目根下。
    #
    # 为什么必须做：分片里的章节是"分片内的第 2 层"，并进来之后会与学科
    # 分段同为 level 2 —— 而 App 的"章节"判据过去正是 `level == 3`，
    # 于是 math1 显示"章节 0"（见 tools/data/knowledge_tree.py 的说明）。
    # 分片还会带出没有父节点的分段（math3 就是这样），也一并挂到根下。
    for n in out:
        nid = n.get("id") or ""
        if not nid:
            continue
        if nid != subject and not n.get("parent_id"):
            n["parent_id"] = subject
        n["level"] = knowledge_tree.id_depth(nid)

    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="多分片知识点合并")
    ap.add_argument("--subject", help="只处理指定科目")
    ap.add_argument("--dry-run", action="store_true", help="只报告，不写文件")
    ap.add_argument(
        "--allow-partial",
        action="store_true",
        help="即使有章节缺失也写入（并集语义下安全，可增量重跑补齐）",
    )
    args = ap.parse_args()

    subjects = [args.subject] if args.subject else ["math1", "math2", "math3"]
    exit_code = 0

    for subject in subjects:
        print(f"\n{'=' * 74}\n科目 {subject}\n{'=' * 74}")

        by_id, sources = collect(subject)
        if not by_id:
            print("  没有找到可合并的分片")
            continue

        print(f"  来源分片: {', '.join(sources)}")
        leaves = {k: v for k, v in by_id.items() if v.get("is_leaf")}
        chapters = {k: v for k, v in by_id.items() if not v.get("is_leaf")}
        print(f"  合并后: 节点 {len(by_id)}（章节 {len(chapters)} / 叶子 {len(leaves)}）")

        done, missing = coverage_report(subject, by_id)
        print(f"\n  章节覆盖: {len(done)}/{len(done) + len(missing)}")
        if missing:
            print("  缺失章节:")
            for m in missing:
                print(f"    - {m}")
        else:
            print("  [OK] 全部章节已覆盖")

        # 叶子分布（按章节归属，而不是按 id 前 3 段 —— 数三是 5 层树，
        # 前 3 段会切到"章"而不是"节"，导致统计口径与 coverage_report 不一致）
        expected = expected_chapters(subject)
        leaf_to_chapter: dict[str, str] = {}
        for ch in expected:
            for lid in knowledge_tree.leaf_ids_under(subject, ch):
                leaf_to_chapter[lid] = ch

        dist: dict[str, int] = defaultdict(int)
        unassigned: list[str] = []
        for lid in leaves:
            ch = leaf_to_chapter.get(lid)
            if ch is None:
                # 分片里可能有知识点本体尚未收录的叶子，单独列出
                unassigned.append(lid)
                continue
            dist[ch] += 1

        print("\n  各章叶子数:")
        for k in sorted(dist):
            print(f"    {k:<34} {dist[k]:>3}")
        if unassigned:
            print(f"\n  [!] {len(unassigned)} 个叶子不属于任何已知章节"
                  f"（知识点本体尚未收录），前 5 个：")
            for u in unassigned[:5]:
                print(f"      {u}")

        if args.dry_run:
            print("\n  [dry-run] 未写入文件")
            continue

        if missing and not args.allow_partial:
            print(f"\n  [!] 仍有 {len(missing)} 章缺失，跳过写入")
            print("      确认接受部分覆盖请加 --allow-partial（并集语义安全，可增量重跑）")
            exit_code = 2
            continue

        # 组装并写入权威文件
        subject_name = {
            "math1": "考研数学（一）",
            "math2": "考研数学（二）",
            "math3": "考研数学（三）",
        }[subject]

        nodes = ensure_anchors(list(by_id.values()), subject, subject_name)
        doc = {
            "version": "1.0.0",
            "subject": subject,
            "subject_name": subject_name,
            "updated_at": "2026-03-15",
            "coverage": {
                "status": "partial" if missing else "complete",
                "chapters_done": done,
                "chapters_todo": missing,
            },
            "id_convention": (
                f"{subject}.{{科}}.{{章}}.{{知识点}}；科: calc=高数 "
                f"linalg=线代 prob=概率"
            ),
            "exam_weight_formula": (
                "章节级权威来源=data/exam_frequency.json："
                "raw = total_appearances × avg_score，"
                "exam_weight = round(raw / max(raw), 2)。"
                "叶子级由 tools/data/merge_knowledge.py 派生。"
            ),
            "nodes": nodes,
        }

        out = KP_DIR / f"{subject}.json"
        out.write_text(
            json.dumps(doc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        , newline="")
        tag = "（部分覆盖）" if missing else ""
        print(f"\n  [OK] 已写入 {out.name}：{len(nodes)} 个节点 / "
              f"{len(leaves)} 叶子 / {len(done)} 章{tag}")

    print("\n完成。")
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
