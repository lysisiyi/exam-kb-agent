#!/usr/bin/env python3
"""知识点本体与考频数据的合并 / 权重派生工具。

## 背景
知识点本体（`data/knowledge_points/*.json`）和考频数据（`data/exam_frequency.json`）
最初由不同来源产生，存在两个集成问题：

1. **章节 id 必须对齐** —— 知识点按章节组织，考频数据也按章节统计，两者必须用同一套 id。
2. **exam_weight 的算法必须统一** —— 否则同一章节在两份文件里权重不同，UI 会自相矛盾。

## 统一后的 exam_weight 定义（唯一权威）

**章节级**（权威来源 = `exam_frequency.json`）：

    raw      = total_appearances × avg_score      # 15 年累计"分值暴露量"
    chapter  = round(raw / max(raw_all_chapters), 2)   # 相对最重章节归一化

**叶子级**（本工具派生，因为考频数据只到章节粒度）：

    leaf = chapter × hotspot_boost × year_factor

    hotspot_boost = hits(leaf, chapter.hotspots) ≥ 1 ? 1.15 : 1.0
        # 叶子名或 id 末段与该章 hotspot 名称匹配上，说明是高频考点
    year_factor   = 0.85 + 0.30 × min(len(leaf.exam_years), 15) / 15
        # 出现年份越多权重越高，限制在 [0.85, 1.15]

    leaf = clamp(leaf, 0.10, 1.00)

## 用法
    python tools/data/merge_knowledge.py --check          # 只检查，不写文件
    python tools/data/merge_knowledge.py --subject math1  # 合并并写回
    python tools/data/merge_knowledge.py --all
"""

from __future__ import annotations

import argparse
import json
import re
import sys

# 中文 Windows 控制台默认 GBK，遇到非 GBK 字符会 UnicodeEncodeError 崩溃。
# 强制 stdout/stderr 使用 UTF-8。
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
from pathlib import Path

# ─────────────────────────────────────────────────────────────────────────────
# 路径
# ─────────────────────────────────────────────────────────────────────────────

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "data"
KP_DIR = DATA / "knowledge_points"
FREQ_FILE = DATA / "exam_frequency.json"

# exam_weight 统一算法的说明，会写进知识点文件供下游引用
WEIGHT_FORMULA_DOC = (
    "章节级权威来源=data/exam_frequency.json："
    "raw = total_appearances × avg_score，exam_weight = round(raw / max(raw), 2)。"
    "叶子级由 tools/data/merge_knowledge.py 派生："
    "leaf = clamp(chapter × hotspot_boost × year_factor, 0.10, 1.00)，"
    "其中 hotspot_boost = 命中该章 hotspots ? 1.15 : 1.0，"
    "year_factor = 0.85 + 0.30 × min(len(exam_years), 15) / 15。"
)

MIN_WEIGHT = 0.10
MAX_WEIGHT = 1.00


# ─────────────────────────────────────────────────────────────────────────────
# 工具函数
# ─────────────────────────────────────────────────────────────────────────────

def load_json(path: Path):
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def save_json(path: Path, obj) -> None:
    """写 JSON：保持 UTF-8、缩进 2、不转义中文、末尾换行。"""
    text = json.dumps(obj, ensure_ascii=False, indent=2)
    path.write_text(text + "\n", encoding="utf-8", newline="")


def normalize(s: str) -> str:
    """用于名称匹配的归一化：只留中文/字母/数字，转小写。"""
    return re.sub(r"[^\u4e00-\u9fffa-zA-Z0-9]", "", s or "").lower()


def leaf_segment(kp_id: str) -> str:
    """取知识点 id 的最后一段，如 math1.calc.diff.derivative_def -> derivative_def。"""
    parts = kp_id.split(".")
    return parts[-1] if parts else kp_id


def chapter_of(kp_id: str) -> str:
    """取知识点所属章节 id。叶子是 4 段，章节是 3 段。"""
    parts = kp_id.split(".")
    if len(parts) >= 3:
        return ".".join(parts[:3])
    return kp_id


# 学科分段节点的显示名
_SECTION_NAMES = {
    "calc": "高等数学",
    "linalg": "线性代数",
    "prob": "概率论与数理统计",
}


def _is_structural(kp_id: str) -> bool:
    """是否为结构性节点（科目根 / 学科分段）。

    考频数据只统计到章节粒度，所以这类节点不该被要求出现在考频文件里。
    - `math1`                 → 根节点
    - `math1.calc`            → 学科分段
    - `math1.calc.limit`      → 章节（不是结构性节点）
    """
    return kp_id.count(".") <= 1


def ancestors_of(kp_id: str) -> list[str]:
    """返回从直属父级到根的 id 链。

    用于**层级深度不确定**的情况：数一是
    `math1 → math1.calc → math1.calc.limit → 叶子`（4 段），
    而数三多了「节」这一层：
    `math3 → math3.calc → math3.calc.limit → math3.calc.limit.xxx → 叶子`（5 段）。

    因此**不能按段数硬切**，必须沿 parent_id 向上找。
    """
    parts = kp_id.split(".")
    return [".".join(parts[:i]) for i in range(len(parts) - 1, 0, -1)]


def _module_prefix(kp_id: str) -> str | None:
    """取学科前缀，如 `math3.prob`。

    ⚠️ 这一步不能省：`math3.prob.limit`（大数定律）与 `math3.calc.limit`（极限）
    在不同学科下同名，前缀匹配必须限定在同一学科内，否则会串章。
    """
    parts = kp_id.split(".")
    return ".".join(parts[:2]) if len(parts) >= 2 else None


def resolve_chapter(
    kp_id: str,
    parent_of: dict[str, str | None],
    chapters: dict[str, dict],
) -> tuple[str | None, dict | None]:
    """沿 parent_id 向上查找第一个在考频数据中注册的祖先。

    返回 (章节 id, 该章节的考频信息)；找不到则返回 (None, None)。
    """
    prefix = _module_prefix(kp_id)

    def _in_scope(candidate: str) -> bool:
        # 必须与目标同属一个学科（math{N}.{科}），避免跨学科串章
        return _module_prefix(candidate) == prefix

    seen: set[str] = set()
    cur = parent_of.get(kp_id)
    while cur and cur not in seen:
        seen.add(cur)
        if _in_scope(cur):
            info = chapters.get(cur)
            if info is not None:
                return cur, info
        cur = parent_of.get(cur)

    # 兜底：parent_id 信息不全时，用 id 前缀逐个试（同样限定学科）
    for anc in ancestors_of(kp_id):
        if not _in_scope(anc):
            continue
        info = chapters.get(anc)
        if info is not None:
            return anc, info
    return None, None


def _ensure_anchor_nodes(doc: dict, subject: str) -> None:
    """补齐缺失的根节点与学科分段节点。

    知识点树是 `math1` → `math1.calc` → `math1.calc.limit` → 叶子。
    各分片文件只提供自己负责的部分，锚点节点可能缺席，导致 parent_id 悬空。
    这里按需补上，避免下游按 parent_id 建树时报错。
    """
    nodes: list[dict] = doc.setdefault("nodes", [])
    existing = {n["id"] for n in nodes}

    # 根节点
    if subject not in existing:
        nodes.insert(0, {
            "id": subject,
            "name": doc.get("subject_name", subject),
            "level": 1,
            "parent_id": None,
            "is_leaf": False,
            "exam_weight": 1.0,
        })
        existing.add(subject)

    # 学科分段节点：从现有节点的 parent_id 里推断
    needed_sections: set[str] = set()
    for n in nodes:
        pid = n.get("parent_id")
        if pid and pid.startswith(f"{subject}.") and pid.count(".") == 1:
            needed_sections.add(pid)

    for sec_id in sorted(needed_sections):
        if sec_id in existing:
            continue
        key = sec_id.split(".")[-1]
        nodes.append({
            "id": sec_id,
            "name": _SECTION_NAMES.get(key, key),
            "level": 2,
            "parent_id": subject,
            "is_leaf": False,
            "exam_weight": 0.9,
        })
        existing.add(sec_id)


# ─────────────────────────────────────────────────────────────────────────────
# 核心逻辑
# ─────────────────────────────────────────────────────────────────────────────

class Merger:
    def __init__(self, subject: str, freq: dict | None):
        self.subject = subject
        self.freq = freq
        # 章节 id -> {exam_weight, hotspots[], confidence}
        self.chapters: dict[str, dict] = {}
        if freq and freq.get("subject") == subject:
            for ch in freq.get("chapters", []):
                self.chapters[ch["id"]] = {
                    "exam_weight": ch.get("exam_weight"),
                    "hotspots": ch.get("hotspots", []),
                    "confidence": ch.get("confidence", "unknown"),
                    "total_appearances": ch.get("total_appearances"),
                    "avg_score": ch.get("avg_score"),
                }

        # id -> parent_id，供沿父链解析章节用
        self.parent_of: dict[str, str | None] = {}

    def index_nodes(self, nodes: list[dict]) -> None:
        """建立 id → parent_id 索引。必须在派生权重前调用。"""
        self.parent_of = {
            n["id"]: n.get("parent_id")
            for n in nodes
            if isinstance(n, dict) and n.get("id")
        }

    def chapter_info_for(self, kp_id: str) -> tuple[str | None, dict | None]:
        """沿父链找到 kp_id 所属的、在考频数据中注册的祖先章节。"""
        return resolve_chapter(kp_id, self.parent_of, self.chapters)

    def _has_registered_descendant(self, node_id: str, nodes: list[dict]) -> bool:
        """该节点的后代里是否有在考频数据中注册的节点。

        用于区分两种情况：
        - **层级不同**（数三的「章」下面还有「节」才是考频单元）→ 不是问题
        - **真的没数据**（整个分支都不在考频文件里）→ 值得警告
        """
        prefix = f"{node_id}."
        return any(
            other["id"].startswith(prefix) and other["id"] in self.chapters
            for other in nodes
            if isinstance(other, dict) and other.get("id")
        )

    # ── 权重派生 ──────────────────────────────────────────────────────────

    def hotspot_boost(self, leaf: dict, ch: dict | None) -> float:
        """叶子是否为该章的高频考点。

        匹配方式：叶子名 / id 末段 与该章任一 hotspot 名称互相包含。
        例如叶子「等价无穷小替换」命中 hotspot「等价无穷小」。
        """
        if not ch:
            return 1.0

        leaf_name = normalize(leaf.get("name", ""))
        leaf_seg = normalize(leaf_segment(leaf["id"]))
        if not leaf_name and not leaf_seg:
            return 1.0

        for hs in ch.get("hotspots", []):
            hs_norm = normalize(hs.get("name", ""))
            if not hs_norm:
                continue
            if (hs_norm in leaf_name or leaf_name in hs_norm
                    or hs_norm in leaf_seg or leaf_seg in hs_norm):
                return 1.15
        return 1.0

    @staticmethod
    def year_factor(leaf: dict) -> float:
        years = leaf.get("exam_years") or []
        return 0.85 + 0.30 * min(len(years), 15) / 15.0

    def derive_leaf_weight(self, leaf: dict) -> tuple[float | None, str | None]:
        """派生叶子权重。返回 (权重, 命中的章节 id)。"""
        ch_id, ch = self.chapter_info_for(leaf["id"])
        if not ch or ch.get("exam_weight") is None:
            return None, ch_id
        w = ch["exam_weight"] * self.hotspot_boost(leaf, ch) * self.year_factor(leaf)
        return round(max(MIN_WEIGHT, min(MAX_WEIGHT, w)), 2), ch_id

    # ── 主流程 ────────────────────────────────────────────────────────────

    def process(self, doc: dict, check_only: bool) -> tuple[dict, list[str]]:
        log: list[str] = []
        nodes = doc.get("nodes", [])

        # 0. 确保科目根节点与学科分段节点存在，作为 parent_id 锚点
        _ensure_anchor_nodes(doc, self.subject)
        nodes = doc.get("nodes", [])

        # 建立父链索引（派生权重必须依赖它，不能按段数硬切）
        self.index_nodes(nodes)

        # 1. 统一顶层公式说明
        doc["exam_weight_formula"] = WEIGHT_FORMULA_DOC

        # 2. 章节节点：用考频数据的权威权重覆盖
        for n in nodes:
            if n.get("is_leaf", False):
                continue
            ch = self.chapters.get(n["id"])
            if ch and ch.get("exam_weight") is not None:
                old = n.get("exam_weight")
                n["exam_weight"] = ch["exam_weight"]
                if old != ch["exam_weight"]:
                    log.append(
                        f"  章节 {n['id']}: exam_weight {old} -> {ch['exam_weight']}（考频权威值）"
                    )
            elif _is_structural(n["id"]):
                # 根节点与学科分段节点本来就不在考频数据里（考频只统计到章节）
                continue
            elif self._has_registered_descendant(n["id"], nodes):
                # 数三是 5 层树（章 → 节 → 叶子），可考查单元是「节」。
                # 「章」这一层自然不在考频数据里 —— 那不是缺失，是层级不同。
                # 不排除掉的话每次都会刷出十几条假警告，久而久之没人再看警告。
                continue
            else:
                log.append(
                    f"  [!] 章节 {n['id']} 在考频数据中未注册"
                    f"（该科目考频数据可能缺失或 id 不一致）"
                )

        # 3. 叶子节点：派生权重
        derived, not_derived = 0, []
        for n in nodes:
            if not n.get("is_leaf", False):
                continue
            w, ch_id = self.derive_leaf_weight(n)
            if w is None:
                not_derived.append(n["id"])
                n.pop("exam_weight", None)
                n.pop("weight_source", None)
            else:
                n["exam_weight"] = w
                n["weight_source"] = "derived"
                derived += 1

        log.append(f"  叶子权重派生：成功 {derived} / 未派生 {len(not_derived)}")
        if not_derived:
            # 只报前 5 条，避免刷屏
            for nid in not_derived[:5]:
                log.append(f"    [!] 无法派生：{nid}")
            if len(not_derived) > 5:
                log.append(f"    ... 另有 {len(not_derived) - 5} 个")

        # 4. 校验
        log.extend(self._validate(nodes))

        return doc, log

    def _validate(self, nodes: list[dict]) -> list[str]:
        log: list[str] = []
        ids = [n["id"] for n in nodes]

        # id 唯一
        dup = {i for i in ids if ids.count(i) > 1}
        for d in dup:
            log.append(f"  [X] id 重复: {d}")

        # parent_id 必须存在
        idset = set(ids)
        for n in nodes:
            pid = n.get("parent_id")
            if pid and pid not in idset:
                log.append(f"  [!] {n['id']} 的 parent_id={pid} 不存在于本文件（可能在该科目的其他分片里）")

        # 叶子必须有定义和公式
        for n in nodes:
            if not n.get("is_leaf", False):
                continue
            if not n.get("definition"):
                log.append(f"  [X] 叶子 {n['id']} 缺少 definition")
            if not n.get("formulas"):
                log.append(f"  [!] 叶子 {n['id']} 缺少 formulas")
            if not n.get("exam_years"):
                log.append(f"  [!] 叶子 {n['id']} 缺少 exam_years")

        return log


def load_frequency_index(path: Path) -> dict[str, dict]:
    """读取考频数据，返回 {科目: 考频文档}。

    兼容两种结构：
    - **v2 多科目容器**：`{ version, subjects: { math1: {...}, math2: {...} } }`
    - **v1 单科目**：`{ version, subject: "math1", chapters: [...] }`

    v1 结构在早期只有数学一时使用；现在三科都有数据，统一走 v2。
    """
    if not path.exists():
        print(f"错误：找不到 {path}")
        return {}

    doc = json.loads(path.read_text(encoding="utf-8"))

    # v2 容器
    subjects = doc.get("subjects")
    if isinstance(subjects, dict):
        out: dict[str, dict] = {}
        for key, value in subjects.items():
            if isinstance(value, dict) and value.get("chapters"):
                out[key] = value
        return out

    # v1 单科目
    if doc.get("chapters"):
        return {doc.get("subject", "math1"): doc}

    print(f"警告：{path.name} 结构无法识别（既无 subjects 也无 chapters）")
    return {}


def merge_subject(subject: str, freq_all: dict, check_only: bool) -> None:
    print(f"\n{'=' * 72}\n科目: {subject}\n{'=' * 72}")

    base = KP_DIR / f"{subject}.json"

    if not base.exists():
        print(f"  跳过：{base.name} 不存在")
        return

    doc = load_json(base)
    freq = freq_all.get(subject)
    merger = Merger(subject, freq)

    if not merger.chapters:
        print(f"  [!] 考频数据中没有 {subject} 的条目，exam_weight 将保持不变")

    # ⚠️ 分片合并是 `tools/data/merge_shards.py` 的职责，本脚本**不做合并**。
    #
    # 早期版本在这里尝试合并 `{subject}_rest.json`，与 merge_shards 的并集语义
    # 重复，且会反复归档该文件、在权威文件里制造重复内容。已移除。
    #
    # 正确流程：
    #   1. python tools/data/merge_shards.py --allow-partial    # 并集合并 → 权威文件
    #   2. python tools/data/merge_knowledge.py --subject math1 # 派生 exam_weight

    nodes = doc.get("nodes", [])
    leaves = [n for n in nodes if isinstance(n, dict) and n.get("is_leaf")]
    chapters = [n for n in nodes if isinstance(n, dict) and not n.get("is_leaf")]
    print(f"  节点总数 {len(nodes)}（章节 {len(chapters)} / 叶子 {len(leaves)}）")

    doc, log = merger.process(doc, check_only)
    for line in log:
        print(line)

    if check_only:
        print("  [check 模式] 未写入文件")
        return

    save_json(base, doc)
    print(f"  [OK] 已写入 {base.name}")


def main() -> int:
    ap = argparse.ArgumentParser(description="知识点本体与考频数据合并 / 权重派生")
    ap.add_argument("--subject", help="只处理指定科目，如 math1")
    ap.add_argument("--all", action="store_true", help="处理全部科目")
    ap.add_argument("--check", action="store_true", help="只检查，不写文件")
    args = ap.parse_args()

    freq_all = load_frequency_index(FREQ_FILE)
    if not freq_all:
        return 1

    print(f"考频数据已载入科目：{', '.join(sorted(freq_all))}")

    if args.subject:
        subjects = [args.subject]
    elif args.all:
        # 只处理**权威文件**（math1/math2/math3），跳过 AI 生成的分片
        # （math1_calc / math1_linalg / math1_prob / math1_rest 等）。
        # 分片的角色是合并输入，由 merge_shards.py 消费。
        subjects = [
            p.stem for p in sorted(KP_DIR.glob("math[123].json"))
            if p.is_file()
        ]
    else:
        subjects = ["math1"]

    for s in subjects:
        merge_subject(s, freq_all, args.check)

    # 汇总：哪些科目仍缺考频数据
    missing = [s for s in subjects if s not in freq_all]
    if missing:
        print(f"\n[!] 以下科目没有考频数据，其叶子 exam_weight 无法派生："
              f"{', '.join(missing)}")
        print("    补齐 data/exam_frequency.json 的 subjects.<科目> 后重跑本脚本。")

    print("\n完成。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
