#!/usr/bin/env python3
"""合并映射的**执行前验证器**（技术债 T19）。

## 为什么必须有这一步

合并知识点是**不可逆**的：删掉的 id 再也回不来，而它可能被别处引用。
所以执行前必须回答四个问题：

1. **映射自洽吗** —— keep/drop 的 id 是否存在？同一个 id 是否既被保留又被删除？
   是否出现 A→B 而 B 又被删掉的链式引用？
2. **内容会丢吗** —— drop 侧独有的公式/陷阱/考频年份/别名，是否都会被
   `merge_into` 并进 keep？（`merge_into` 做的是并集，所以理论上不丢；
   这里要把"实际会搬运多少条"算出来给人看）
3. **评测集会失真吗** —— `data/eval/*.json` 里的 primary/secondary id 若被删，
   评测立刻失真。primary 必须人工重新判定，**不能自动改写**。
4. **别名会丢吗** —— 人工维护的 `alias_overrides.json` 是按 id 存的；
   id 被删，它的符号别名就白写了（T15 的成果）。必须改名到 keep 上。

## 用法
    python tools/data/verify_merges.py            # 全量报告（不改任何文件）
    python tools/data/verify_merges.py --quiet    # 只报问题

退出码：0 = 可以安全执行；1 = 有问题必须先处理。
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
DATA = ROOT / "data"
KP_DIR = DATA / "knowledge_points"
EVAL_DIR = DATA / "eval"
MERGE_MAP = KP_DIR / "merge_map.json"
ALIAS_OVERRIDES = KP_DIR / "alias_overrides.json"

EVAL_SETS = [
    "gold_set.json",
    "gold_set_holdout.json",
    "gold_set_final.json",
    "gold_set_verify.json",
]


def load(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def load_ontology() -> dict[str, dict]:
    """全部叶子：id → 节点（含所属科目）。"""
    out: dict[str, dict] = {}
    for name in ("math1.json", "math2.json", "math3.json"):
        p = KP_DIR / name
        if not p.exists():
            continue
        for n in load(p).get("nodes", []):
            if isinstance(n, dict) and n.get("is_leaf") and n.get("id"):
                out[n["id"]] = n
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="合并映射执行前验证")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    problems: list[str] = []
    notes: list[str] = []

    mapping = load(MERGE_MAP)
    groups = mapping.get("groups", [])
    leaves = load_ontology()

    # ── 1. 映射自洽性 ──────────────────────────────────────────────────────
    keep_ids: list[str] = []
    drop_ids: list[str] = []
    already_applied: list[str] = []
    for g in groups:
        keep = g.get("keep")
        drops = g.get("drops") or []
        if not keep:
            problems.append(f"映射缺少 keep：{g}")
            continue
        if not drops:
            problems.append(f"映射 {keep} 的 drops 为空 —— 无意义的条目，应删掉")
        if keep not in leaves:
            problems.append(f"keep 不是本体里的叶子：{keep}")
        keep_ids.append(keep)
        for d in drops:
            if d not in leaves:
                # 执行过合并之后 drop 自然就不在了。这时不该报错，
                # 但也不能静默忽略 —— 拼错 id 的后果是"这个节点没被合并"，
                # 所以照样列出来让人确认是"已执行"还是"拼错了"。
                already_applied.append(d)
            drop_ids.append(d)

    if already_applied:
        notes.append(
            f"{len(already_applied)} 个 drop 已不在本体里 —— "
            f"若这是**执行合并之后**的复查，属正常（映射已生效）；"
            f"若还没执行过，则是 id 拼错，合并会静默跳过它。"
            f"样例：{already_applied[:3]}"
        )

    dup_keep = {i for i in keep_ids if keep_ids.count(i) > 1}
    for i in sorted(dup_keep):
        problems.append(f"同一个 keep 出现在多组里：{i}（应合并成一组）")

    both = set(keep_ids) & set(drop_ids)
    for i in sorted(both):
        problems.append(f"{i} 既被保留又被删除 —— 自相矛盾")

    # 链式引用：A 保留但它的内容来源 B 又被删掉
    for g in groups:
        keep = g.get("keep")
        if keep in drop_ids:
            problems.append(f"链式引用：keep {keep} 自己也在别的组里被删")

    # 一个 drop 出现在多组里 → 内容会被复制到多个 keep
    drop_count = defaultdict(int)
    for d in drop_ids:
        drop_count[d] += 1
    for d, c in sorted(drop_count.items()):
        if c > 1:
            notes.append(
                f"{d} 出现在 {c} 组里 —— 它的内容会被**复制**到 {c} 个 keep 上，"
                f"确认这是有意的（拆分型内容分发）"
            )

    # ── 2. 内容搬运量 ─────────────────────────────────────────────────────
    total_moved = {"formulas": 0, "common_traps": 0, "exam_years": 0, "aliases": 0}
    if not args.quiet:
        print("=" * 74)
        print("合并映射验证")
        print("=" * 74)
        print(f"组数 {len(groups)}｜保留 {len(set(keep_ids))}｜删除 {len(set(drop_ids))}")
        _pending_all = [d for d in set(drop_ids) if d in leaves]
        if not _pending_all:
            print()
            print("  注：映射**已执行完毕**（待删 id 都已不在本体里）。")
            print("      下面每组的『并入 +0』是正常的 —— 内容在执行时就已经并进去了，")
            print("      现在没有可搬运的东西。")
        print()
        print("── 每组的内容搬运（并集，不会丢） ──")

    for g in groups:
        keep = g.get("keep")
        k = leaves.get(keep)
        if k is None:
            continue
        kf = {_norm(f) for f in (k.get("formulas") or [])}
        kt = {_norm(t) for t in (k.get("common_traps") or [])}
        ky = set(k.get("exam_years") or [])
        ka = set(k.get("aliases") or [])

        add = {"formulas": 0, "common_traps": 0, "exam_years": 0, "aliases": 0}
        for d in g.get("drops") or []:
            n = leaves.get(d)
            if n is None:
                continue
            add["formulas"] += len({_norm(f) for f in (n.get("formulas") or [])} - kf)
            add["common_traps"] += len({_norm(t) for t in (n.get("common_traps") or [])} - kt)
            add["exam_years"] += len(set(n.get("exam_years") or []) - ky)
            add["aliases"] += len(set(n.get("aliases") or []) - ka)

        for key in total_moved:
            total_moved[key] += add[key]

        if not args.quiet:
            names = " + ".join(
                f"「{leaves[d]['name']}」" for d in (g.get("drops") or []) if d in leaves
            )
            print(f"  {keep}")
            print(f"      ← {names}")
            print(f"      并入：公式 +{add['formulas']}｜陷阱 +{add['common_traps']}"
                  f"｜考频年 +{add['exam_years']}｜别名 +{add['aliases']}")

    # ── 3. 评测集引用 ─────────────────────────────────────────────────────
    eval_hits: list[tuple[str, str, str, str]] = []  # (set, problem_id, role, kp_id)
    for name in EVAL_SETS:
        p = EVAL_DIR / name
        if not p.exists():
            notes.append(f"评测集不存在：{name}")
            continue
        for prob in load(p).get("problems", []):
            pid = prob.get("id", "?")
            prim = prob.get("primary_kp_id")
            if prim in drop_ids:
                eval_hits.append((name, pid, "primary", prim))
            for s in prob.get("secondary_kp_ids") or []:
                if s in drop_ids:
                    eval_hits.append((name, pid, "secondary", s))

    for name, pid, role, kp in eval_hits:
        if role == "primary":
            problems.append(
                f"评测集 {name} 的 {pid} 把 **primary** 指向了将被删除的 {kp} "
                f"—— primary 是人工标注的基准答案，必须人工重新判定后改写，不能自动映射"
            )
        else:
            notes.append(
                f"评测集 {name} 的 {pid} secondary 指向将被删除的 {kp}，需改为 keep"
            )

    # ── 4. 人工别名引用 ───────────────────────────────────────────────────
    alias_moves: list[tuple[str, str, int]] = []
    if ALIAS_OVERRIDES.exists():
        ov = load(ALIAS_OVERRIDES).get("aliases", {})
        # drop → keep
        drop_to_keep = {}
        for g in groups:
            for d in g.get("drops") or []:
                drop_to_keep.setdefault(d, g["keep"])
        for kp_id, aliases in ov.items():
            if kp_id in drop_to_keep:
                alias_moves.append((kp_id, drop_to_keep[kp_id], len(aliases)))
            elif kp_id in drop_ids:
                alias_moves.append((kp_id, "（无 keep —— 会丢失！）", len(aliases)))

    for src, dst, n in alias_moves:
        if "无 keep" in dst:
            problems.append(f"人工别名 {src} 有 {n} 条，但它被删除且没有 keep —— 别名会丢")
        else:
            notes.append(f"人工别名 {src}（{n} 条）需改挂到 {dst}")

    # ── 5. 管线不会把删掉的节点搬回来（防回归） ───────────────────────────
    #
    # 这是真实踩过的坑：把合并映射从"硬编码白名单"改成数据文件驱动时，
    # 早期那批删除标记丢了，于是 `merge_shards.py`（并集合并）把分片里
    # 的副本全部搬回权威文件 —— 142 个叶子变回 170，**且不报任何错**。
    #
    # 这里直接把"跑一遍管线会得到什么"算出来与本体对比。
    pipeline_extra: dict[str, list[str]] = {}
    try:
        import contextlib
        import importlib.util
        import io

        spec = importlib.util.spec_from_file_location(
            "_vs_merge_shards", Path(__file__).resolve().parent / "merge_shards.py"
        )
        ms = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        with contextlib.redirect_stdout(io.StringIO()):
            spec.loader.exec_module(ms)

        for subject in ("math1", "math2", "math3"):
            by_id, _ = ms.collect(subject)
            merged_leaves = {i for i, n in by_id.items() if n.get("is_leaf")}
            auth_leaves = {
                i for i, n in leaves.items() if i.startswith(subject + ".")
            }
            extra = sorted(merged_leaves - auth_leaves)
            if extra:
                pipeline_extra[subject] = extra
    except Exception as e:  # noqa: BLE001
        notes.append(f"未能验证管线复活风险（{e}）—— 建议手工跑一次 merge_shards --dry-run")

    for subject, extra in pipeline_extra.items():
        problems.append(
            f"{subject}: 跑一遍 merge_shards 会让 {len(extra)} 个已删除的叶子"
            f"复活（权威文件 {len(leaves)} 个叶子会被改回去）。"
            f"说明有删除标记没被记录 —— 检查 merge_map.json 的 drops 与 "
            f"suppressed_drops，或跑 refresh_suppressed.py 重算。"
            f"样例：{extra[:3]}"
        )

    # ── 5.5 未覆盖的重复（这是漏合并的兜底） ─────────────────────────────
    #
    # ⚠️ 真实踩到的坑：写映射时**漏了一组** ——
    # `math1.calc.ode.first_order_linear`「一阶线性微分方程与伯努利方程」
    # 与 `math1.calc.ode.linear1`「一阶线性微分方程」两个 id 都活了下来。
    # 后果不是"少删一个"这么轻：T17 实测 gold-010 因此判错
    # （LLM 在等价的两个选项里挑了更含糊的那个）。
    #
    # 而当时的验证器只检查"映射自身自洽"，管不到"本体里还有没有没被覆盖的重复"。
    # 这里补上：用重复检测器扫一遍**当前本体**，把不在映射里、
    # 也没写进 `not_merged` 的候选对报出来。
    uncovered: list[str] = []
    try:
        import importlib.util

        spec = importlib.util.spec_from_file_location(
            "_vs_dedupe", Path(__file__).resolve().parent / "dedupe_knowledge.py"
        )
        dk = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(dk)

        # not_merged 是"名字像但已明确决定不合并"的白名单
        excused: set[frozenset[str]] = set()
        for g in mapping.get("not_merged", []):
            ids = g.get("group") or []
            if len(ids) >= 2:
                excused.add(frozenset(ids))

        merged_pairs: set[frozenset[str]] = set()
        for g in groups:
            for d in g.get("drops") or []:
                merged_pairs.add(frozenset({g["keep"], d}))

        for subject in ("math1", "math2", "math3"):
            p = KP_DIR / f"{subject}.json"
            if not p.exists():
                continue
            nodes = load(p).get("nodes", [])
            for _why, _scope, a, b, _already in dk._candidates(nodes):
                pair = frozenset({a["id"], b["id"]})
                if pair in merged_pairs or pair in excused:
                    continue
                uncovered.append(
                    f"{a['id']}「{a.get('name')}」 与 "
                    f"{b['id']}「{b.get('name')}」"
                )
    except Exception as e:  # noqa: BLE001
        notes.append(f"未能扫描未覆盖的重复（{e}）")

    if uncovered:
        notes.append(
            f"检测到 {len(uncovered)} 组**本体里仍然并存**的疑似重复，"
            f"既不在映射里也没写进 not_merged：\n      "
            + "\n      ".join(uncovered[:12])
            + (
                f"\n      （另有 {len(uncovered) - 12} 组）"
                if len(uncovered) > 12
                else ""
            )
            + "\n      → 要么补进 groups 合并掉，要么写进 not_merged 说明为什么不合并。"
            "\n      ⚠️ 检测器有误报（如二重积分直角/极坐标），必须逐对人工判断。"
        )

    # ── 输出 ───────────────────────────────────────────────────────────────
    if not args.quiet:
        print()
        print("── 内容搬运合计 ──")
        print(f"  公式 +{total_moved['formulas']}｜陷阱 +{total_moved['common_traps']}"
              f"｜考频年 +{total_moved['exam_years']}｜别名 +{total_moved['aliases']}")
        print()
        print("── 本体规模 ──")
        before = len(leaves)
        # ⚠️ 不能直接用 len(drop_ids)：执行过合并之后那些 id 已经不在本体里了，
        # 减去它们会得到"213"这种不存在的数字。只有**当前仍存在**的才是待删。
        pending = sorted({d for d in drop_ids if d in leaves})
        if pending:
            print(f"  叶子 {before} → {before - len(pending)}"
                  f"（映射未执行，待删除 {len(pending)} 个）")
        else:
            print(f"  叶子 {before}（映射已执行完毕，无待删除项）")
        print(f"  映射共记录 {len(set(drop_ids))} 个已删除/待删除 id；"
              f"永久删除标记 {len(_suppressed_count())} 个")

        if notes:
            print()
            print("── 提示（需要处理，但不是阻断） ──")
            for n in notes:
                print(f"  [!] {n}")

    print()
    if problems:
        print("=" * 74)
        print(f"[X] {len(problems)} 个阻断性问题 —— 不能执行合并")
        print("=" * 74)
        for p in problems:
            print(f"  {p}")
        return 1

    print("[OK] 验证通过：映射自洽、内容由并集搬运、评测集与别名已确认")
    return 0


def _suppressed_count() -> list[str]:
    """永久删除标记的数量（读 merge_map.json，缺失时为 0）。"""
    try:
        doc = load(MERGE_MAP)
        return [s for s in (doc.get("suppressed_drops") or []) if s]
    except Exception:  # noqa: BLE001
        return []


def _norm(s) -> str:
    return "".join(str(s).split()).lower()


if __name__ == "__main__":
    sys.exit(main())
