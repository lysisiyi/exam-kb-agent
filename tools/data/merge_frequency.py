#!/usr/bin/env python3
"""把单科目考频文件注入多科目容器 `data/exam_frequency.json`。

## 背景
考频数据由多次 AI 生成产出，每次只覆盖一个科目，写成独立文件
（`exam_frequency_math2.json`、`exam_frequency_math3.json`…）。
但下游工具（`merge_knowledge.py`）需要的是**统一的容器**：

```json
{
  "version": "2.0.0",
  "subjects": {
    "math1": { ...完整考频文档... },
    "math2": { ... },
    "math3": { ... }
  }
}
```

本脚本负责「单科目文件 → 容器」这一步，并做**结构校验**。

## 用法
    python tools/data/merge_frequency.py --dry-run    # 只校验，不写
    python tools/data/merge_frequency.py              # 注入并写回
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import re
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")


def _import_sibling(module_name: str):
    """导入同目录下的兄弟模块。

    这些脚本是命令行工具而非包，因此不能直接 `import knowledge_tree` ——
    那样只有从本目录运行时才有效。用 importlib 按文件路径加载，
    保证从仓库任意位置运行都正常。
    """
    path = Path(__file__).resolve().parent / f"{module_name}.py"
    spec = importlib.util.spec_from_file_location(f"_kp_{module_name}", path)
    if spec is None or spec.loader is None:
        raise ImportError(f"无法加载 {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


knowledge_tree = _import_sibling("knowledge_tree")

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "data"
CONTAINER = DATA / "exam_frequency.json"
KP_DIR = DATA / "knowledge_points"

REQUIRED_CHAPTER_FIELDS = {
    "id", "name", "section", "qtype_frequency",
    "total_appearances", "avg_score", "years", "hotspots",
    "exam_weight", "confidence",
}

REQUIRED_TOP_FIELDS = {
    "subject", "subject_name", "years_covered", "note",
    "data_confidence", "chapters",
}


def load_json(p: Path):
    return json.loads(p.read_text(encoding="utf-8"))


def save_json(p: Path, obj) -> None:
    p.write_text(
        json.dumps(obj, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    , newline="")


def chapter_ids_of(subject: str) -> list[str]:
    """从权威知识点文件读出该科目的章节 id 列表。

    章节的判定**完全基于树结构**（见 `knowledge_tree.py`）：
    凡拥有叶子后代的非叶子节点，且不是科目根 / 学科分段，即为章节。

    不能按 id 段数或层级判断 —— 数学三是 5 层（章 → 节 → 叶子），
    其可考查单元是"节"那一层；数学一是 4 层，可考查单元就是"章"。
    """
    return knowledge_tree.chapters_of(subject)


def validate(doc: dict, subject: str) -> tuple[list[str], list[str]]:
    """返回 (错误, 警告)。"""
    errors: list[str] = []
    warnings: list[str] = []

    for f in REQUIRED_TOP_FIELDS:
        if f not in doc:
            errors.append(f"缺少顶层字段：{f}")

    if doc.get("subject") != subject:
        errors.append(f"subject 字段是 {doc.get('subject')!r}，应为 {subject!r}")

    note = doc.get("note", "")
    required_sentence = "本数据为基于公开命题规律的估算，非官方逐题统计"
    if required_sentence not in note:
        warnings.append(
            "note 未包含必备的诚实声明句"
            "（「本数据为基于公开命题规律的估算，非官方逐题统计…」）"
        )

    dc = doc.get("data_confidence")
    if isinstance(dc, dict):
        if dc.get("verified_against_official_papers") is not False:
            warnings.append(
                "data_confidence.verified_against_official_papers 应为 false"
            )
    else:
        errors.append("data_confidence 缺失或不是对象")

    chapters = doc.get("chapters")
    if not isinstance(chapters, list) or not chapters:
        errors.append("chapters 缺失或为空")
        return errors, warnings

    # 字段完整性
    for ch in chapters:
        if not isinstance(ch, dict):
            errors.append(f"chapters 里有非对象元素：{str(ch)[:50]!r}")
            continue
        cid = ch.get("id", "<无 id>")
        missing = REQUIRED_CHAPTER_FIELDS - set(ch)
        if missing:
            errors.append(f"{cid} 缺少字段：{', '.join(sorted(missing))}")
        if not ch.get("hotspots"):
            warnings.append(f"{cid} 没有 hotspots")
        if ch.get("confidence") not in ("high", "medium", "low"):
            warnings.append(
                f"{cid} 的 confidence={ch.get('confidence')!r} 不是 high/medium/low"
            )

    # id 必须与知识点本体的章节 id 对齐
    expected = chapter_ids_of(subject)
    got = {ch.get("id") for ch in chapters if isinstance(ch, dict)}
    if expected:
        missing_ch = sorted(set(expected) - got)
        extra_ch = sorted(got - set(expected))
        if missing_ch:
            errors.append(
                f"以下章节在知识点本体中存在，但考频数据里缺失：\n"
                + "\n".join(f"      - {c}" for c in missing_ch)
            )
        if extra_ch:
            errors.append(
                f"以下章节 id 不在知识点本体中（拼写不一致？）：\n"
                + "\n".join(f"      - {c}" for c in extra_ch)
            )
    else:
        warnings.append(f"找不到 {subject}.json，无法校验章节 id 对齐")

    # exam_weight 校验
    weights = [
        ch.get("exam_weight") for ch in chapters
        if isinstance(ch, dict) and isinstance(ch.get("exam_weight"), (int, float))
    ]
    if weights:
        mx = max(weights)
        if not (0.99 <= mx <= 1.001):
            warnings.append(
                f"exam_weight 最大值是 {mx}，按公式应归一化到 1.00"
            )
        bad = [
            ch.get("id") for ch in chapters
            if isinstance(ch, dict)
            and isinstance(ch.get("exam_weight"), (int, float))
            and not (0.0 <= ch["exam_weight"] <= 1.0)
        ]
        if bad:
            errors.append(f"exam_weight 越界（应在 0–1）：{', '.join(bad[:5])}")

    # 年份范围
    for ch in chapters:
        if not isinstance(ch, dict):
            continue
        for y in ch.get("years") or []:
            if not isinstance(y, int) or not (2010 <= y <= 2024):
                warnings.append(f"{ch.get('id')} 的 years 含越界值：{y}")

    return errors, warnings


def build_subject_doc(
    docs: list[tuple[str, dict]],
    subject: str,
) -> tuple[dict, list[str]]:
    """把同一科目的多份文档按章节 id 合并成一份，并**重新归一化 exam_weight**。

    为什么要重新归一化：考频数据可能分多次生成（如数学三先有 27 个单元、
    后补 15 个单元）。各分片内部的 `exam_weight` 是在**各自的分片内**归一化的，
    直接拼接会让数值失去可比性。

    正确做法：以 `raw = total_appearances × avg_score` 为准，
    在**合并后的全量单元**上重新归一化。

    返回 (合并后的文档, 日志)。
    """
    log: list[str] = []

    # 选信息最全的一份作为基底（章节数最多者优先，其次字段更完整者）
    base_name, base = max(
        docs,
        key=lambda kv: (
            len(kv[1].get("chapters") or []),
            len(kv[1].get("data_confidence") or {}),
        ),
    )
    log.append(f"  基底文档：{base_name}（{len(base.get('chapters') or [])} 个单元）")

    merged: dict[str, dict] = {}
    duplicate_conflicts: list[str] = []

    for name, doc in docs:
        for ch in doc.get("chapters") or []:
            if not isinstance(ch, dict) or not ch.get("id"):
                continue
            cid = ch["id"]
            if cid in merged:
                # 同一单元出现在多份文档里：保留 raw 更大的（信息更实的那个），
                # 但记录冲突以便人工复核
                old_raw = _raw_of(merged[cid])
                new_raw = _raw_of(ch)
                if new_raw > old_raw:
                    merged[cid] = ch
                if old_raw != new_raw:
                    duplicate_conflicts.append(
                        f"{cid}（{name} raw={new_raw} vs 已有 raw={old_raw}）"
                    )
                continue
            merged[cid] = ch

    log.append(f"  合并后单元数：{len(merged)}")
    if duplicate_conflicts:
        log.append(f"  [!] {len(duplicate_conflicts)} 个单元在多份文档中数值不同，"
                   f"已取 raw 较大的那个：")
        for c in duplicate_conflicts[:5]:
            log.append(f"      {c}")

    # 重新归一化
    raws = {cid: _raw_of(ch) for cid, ch in merged.items()}
    max_raw = max(raws.values()) if raws else 0
    if max_raw > 0:
        changed = 0
        for cid, ch in merged.items():
            new_weight = round(raws[cid] / max_raw, 2)
            if ch.get("exam_weight") != new_weight:
                changed += 1
            ch["exam_weight"] = new_weight
        log.append(f"  重新归一化：基准 max(raw) = {max_raw}，"
                   f"{changed} 个单元的 exam_weight 被更新")

        top = max(merged.items(), key=lambda kv: raws[kv[0]])
        log.append(f"  权重最高：{top[0]} = {top[1]['exam_weight']}（raw {raws[top[0]]}）")
        low = min(merged.items(), key=lambda kv: raws[kv[0]])
        log.append(f"  权重最低：{low[0]} = {low[1]['exam_weight']}（raw {raws[low[0]]}）")

    # 以基底文档的顶层字段为准，替换 chapters
    out = dict(base)
    out["chapters"] = [merged[cid] for cid in sorted(merged)]
    out["subject"] = subject

    if len(docs) > 1:
        names = "、".join(n for n, _ in docs)
        out["integration_notes"] = {
            **(base.get("integration_notes") or {}),
            "merged_from": names,
            "exam_weight_renormalized": (
                f"本文档由 {len(docs)} 份分片按章节 id 合并而成，"
                f"exam_weight 已在合并后的 {len(merged)} 个单元上重新归一化"
                f"（基准 raw = {max_raw}）。"
            ),
        }

    return out, log


def _raw_of(ch: dict) -> float:
    """单元的 raw 分值暴露量 = total_appearances × avg_score。"""
    try:
        return float(ch.get("total_appearances") or 0) * float(ch.get("avg_score") or 0)
    except (TypeError, ValueError):
        return 0.0


def main() -> int:
    ap = argparse.ArgumentParser(description="单科目考频文件注入多科目容器")
    ap.add_argument("--dry-run", action="store_true", help="只校验，不写文件")
    args = ap.parse_args()

    if not CONTAINER.exists():
        print(f"错误：找不到容器 {CONTAINER}")
        return 1

    container = load_json(CONTAINER)
    if "subjects" not in container:
        print("错误：容器缺少 subjects 字段。请先运行结构升级。")
        return 1

    subjects = container["subjects"]

    # 收集候选：容器里已有的 + 全部独立文件（含 _part2 之类的分片）
    # 结构：{subject: [(来源名, 文档), ...]}
    candidates: dict[str, list[tuple[str, dict]]] = {}

    def _subject_of(stem: str) -> str | None:
        """从文件名推导科目，如 exam_frequency_math2_part2 -> math2。"""
        m = re.match(r"exam_frequency_(math[123])(?:_part\d+)?$", stem)
        return m.group(1) if m else None

    for key, value in subjects.items():
        if isinstance(value, dict) and value.get("chapters"):
            candidates.setdefault(key, []).append(("容器内已有", value))

    for p in sorted(DATA.glob("exam_frequency_math*.json")):
        subject = _subject_of(p.stem)
        if not subject:
            continue
        try:
            doc = load_json(p)
        except Exception as e:
            print(f"  [X] {p.name}: JSON 解析失败 -> {e}")
            continue
        if not isinstance(doc.get("chapters"), list):
            print(f"  [X] {p.name}: 缺少 chapters 数组")
            continue
        candidates.setdefault(subject, []).append((p.name, doc))

    if not candidates:
        print("没有找到任何考频数据（容器为空且无独立文件）。")
        return 1

    print(f"待处理科目："
          f"{', '.join(f'{k}({len(v)} 份)' for k, v in sorted(candidates.items()))}\n")

    had_error = False
    for subject in sorted(candidates):
        docs = candidates[subject]
        print(f"{'=' * 66}\n科目 {subject}   （{len(docs)} 份来源）\n{'=' * 66}")

        merged_doc, log = build_subject_doc(docs, subject)
        for line in log:
            print(line)

        errors, warnings = validate(merged_doc, subject)

        chapters = merged_doc.get("chapters", [])
        hotspots = sum(
            len(ch.get("hotspots") or []) for ch in chapters if isinstance(ch, dict)
        )
        print(f"  最终：章节 {len(chapters)} · 热点 {hotspots}")

        if warnings:
            print(f"  --- 警告 {len(warnings)} 条 ---")
            for w in warnings:
                print(f"    [!] {w}")

        if errors:
            had_error = True
            print(f"  --- 错误 {len(errors)} 条 ---")
            for e in errors:
                print(f"    [X] {e}")
            print(f"  -> 跳过 {subject}（校验未通过）")
            continue

        print(f"  [OK] 校验通过")
        if not args.dry_run:
            subjects[subject] = merged_doc

    if args.dry_run:
        print("\n[dry-run] 未写入容器")
        return 1 if had_error else 0

    container["updated_at"] = "2026-03-15"
    save_json(CONTAINER, container)

    print(f"\n[OK] 容器已更新：{', '.join(sorted(subjects))}")
    print(f"     {CONTAINER.relative_to(ROOT)}")
    return 1 if had_error else 0


if __name__ == "__main__":
    sys.exit(main())
