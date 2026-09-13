#!/usr/bin/env python3
"""知识点去重：清理多次 AI 生成造成的同名冗余节点。

## 问题来源
知识点本体由多个子任务并行生成（按高数/线代/概率分工，且有重叠分片），
不同批次对同一知识点给出了**不同的英文 id 但相同的中文名**：

```
math1.calc.integral.by_parts   「分部积分法」
math1.calc.integral.byparts    「分部积分法」
```

对标注引擎来说这是**致命**的：LLM 看到两个「分部积分法」选项只能掷硬币，
Top-1 准确率会被人为拉低，而这**不是模型的问题**。

## 去重规则
1. **只按显式白名单删除**（见下方 `KNOWN_DUPLICATES`）。
2. 相似度只用来**提示候选**，不自动删除。

## ⚠️ 为什么不用相似度阈值自动删除
实测踩过这个坑：阈值 0.72 把**真正不同的概念**判成重复了：

```
「二阶常系数非齐次方程」 vs 「二阶常系数齐次方程」  相似度 0.82  ← 这是两个知识点！
「第一类曲面积分（对面积）」 vs 「第一类曲面积分」   相似度 0.75  ← 这个才是重复
```

两者的相似度区间**重叠**，没有安全的阈值。而去重是**语义问题**：
- 误删 → 永久丢失知识，**不可逆**
- 漏删 → LLM 在两个相似选项间犹豫，准确率下降

误删更严重。所以采用**白名单**：只删人工确认过、内容确实冗余的对。
新增白名单项时必须先 `--dry-run` 对比两份内容。

## 用法
    python tools/data/dedupe_knowledge.py --dry-run      # 报告 + 提示相似候选
    python tools/data/dedupe_knowledge.py --all          # 按白名单删除
    python tools/data/dedupe_knowledge.py --suggest      # 只列相似候选供人工判断
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


def score(node: dict) -> tuple:
    """信息完整度打分。分数高者保留。"""
    return (
        len(node.get("definition") or ""),
        len(node.get("formulas") or []),
        len(node.get("common_traps") or []),
        len(node.get("exam_years") or []),
    )


def score_desc(node: dict) -> str:
    d, f, t, y = score(node)
    return f"定义{d}字 公式{f}条 陷阱{t}条 考频{y}年"


def chapter_of(node_id: str, depth: int) -> str:
    parts = node_id.split(".")
    return ".".join(parts[:depth]) if len(parts) >= depth else node_id


def merge_into(keep: dict, drop: dict) -> list[str]:
    """把 drop 的独有内容并入 keep。返回合并说明。"""
    notes: list[str] = []

    # 别名：并集
    #
    # 必须并入。别名是召回率的命脉（见 tools/data/gen_aliases.py），
    # 而被删掉的那个叶子身上往往挂着**只有它才有**的符号别名 ——
    # 例如「曲线积分路径无关」写着的 `r(A^{T}A)` 式签名。
    # 直接删节点会把那些别名一起删掉，召回率静默下降。
    keep_a = list(keep.get("aliases") or [])
    seen_a = set(keep_a)
    added_a = 0
    for x in drop.get("aliases") or []:
        if x not in seen_a:
            keep_a.append(x)
            seen_a.add(x)
            added_a += 1
    if added_a:
        keep["aliases"] = keep_a
        notes.append(f"并入 {added_a} 条别名")

    # 公式：按归一化文本去重后并入
    keep_f = list(keep.get("formulas") or [])
    seen = {_norm(f) for f in keep_f}
    added_f = 0
    for f in drop.get("formulas") or []:
        if _norm(f) not in seen:
            keep_f.append(f)
            seen.add(_norm(f))
            added_f += 1
    if added_f:
        keep["formulas"] = keep_f
        notes.append(f"并入 {added_f} 条公式")

    # 陷阱：同样去重并入
    keep_t = list(keep.get("common_traps") or [])
    seen_t = {_norm(t) for t in keep_t}
    added_t = 0
    for t in drop.get("common_traps") or []:
        if _norm(t) not in seen_t:
            keep_t.append(t)
            seen_t.add(_norm(t))
            added_t += 1
    if added_t:
        keep["common_traps"] = keep_t
        notes.append(f"并入 {added_t} 条陷阱")

    # 考频年份：并集
    years = sorted(set(keep.get("exam_years") or []) | set(drop.get("exam_years") or []))
    if years != sorted(keep.get("exam_years") or []):
        added_y = len(years) - len(keep.get("exam_years") or [])
        keep["exam_years"] = years
        if added_y > 0:
            notes.append(f"并入 {added_y} 个考频年份")

    # 题型：并集
    qt = sorted(set(keep.get("typical_qtypes") or []) | set(drop.get("typical_qtypes") or []))
    if qt:
        keep["typical_qtypes"] = qt

    # 难度范围：取并集（更宽松）
    kr = keep.get("difficulty_range") or [1, 3]
    dr = drop.get("difficulty_range") or [1, 3]
    if kr and dr:
        keep["difficulty_range"] = [min(kr[0], dr[0]), max(kr[-1], dr[-1])]

    return notes


def _norm(s: str) -> str:
    return "".join(str(s).split()).lower()


def name_similarity(a: str, b: str) -> float:
    """两个中文名的相似度，用字符二元组 Dice 系数。

    为什么不用编辑距离：中文名的重复表现为"多了几个修饰字"
    （「正态分布及其标准化」vs「正态分布及其标准化计算」），
    编辑距离对长度差异敏感，而 Dice 系数对"共享大部分字符"更敏感。

    返回 0–1。中文短名（<2 字）直接按相等判断。
    """
    a, b = _norm(a), _norm(b)
    if a == b:
        return 1.0
    if len(a) < 2 or len(b) < 2:
        return 0.0

    def bigrams(s: str) -> set[str]:
        return {s[i : i + 2] for i in range(len(s) - 1)}

    ga, gb = bigrams(a), bigrams(b)
    if not ga or not gb:
        return 0.0
    inter = len(ga & gb)
    return 2.0 * inter / (len(ga) + len(gb))


# ─────────────────────────────────────────────────────────────────────────────
# 名称归一化（用于**发现**候选，不用于自动删除）
# ─────────────────────────────────────────────────────────────────────────────

# 中文名里常见的结构后缀，剔除后剩下的才是"概念内核"。
_STRUCT_SUFFIXES = [
    "及其标准化计算", "及其标准化", "及其矩阵表示", "及其矩阵",
    "与运算律", "及其运算", "及其求导", "及其性质", "及其应用",
    "的计算方法", "的计算技巧", "的计算", "的判定", "的应用", "的性质",
    "的讨论", "的综合应用", "求极限", "的计算与应用",
    "标准化计算", "的基本公式", "与基本公式",
    "计算方法", "计算技巧", "计算", "判定", "应用", "性质", "讨论",
    "方法", "概念", "表示",
]

# 拆开括号时用作分隔的内容（括号里常常只是限定语，去掉后才是同一概念）
_BRACKET = "（）()【】[]"

# 连接词/助词：在**检测**阶段一律剔除。
#
# ⚠️ 仅在检测阶段这么做。召回层的别名匹配**不能**剔除它们 ——
# 别名是靠"子串包含"匹配题干原文的，「重积分的几何应用」去掉"的"之后
# 就再也匹配不上题干里的「重积分的几何应用」了。
_DETECT_DROP = set("的与和及、，,。·—-")


def core_name(name: str) -> str:
    """把知识点名归一化为"概念内核"，用于发现重复。

    ## 为什么需要这一步

    早期版本的 `--suggest` 直接拿原始名字算 Dice 相似度，结果**漏报了大量重复**：

    ```
    A 「求导法则与基本公式」        bigrams 8 个
    B 「求导法则（四则、复合、反函数）」 bigrams 15 个
    交集只有 {求导, 导法, 法则} 3 个 → Dice 0.26  ← 阈值 0.72 直接漏掉
    ```

    可它们显然是同一个知识点 —— 名字后面挂的括号注释把相似度**稀释**了。

    修正分四步：
    1. 去掉括号及其内部内容（注释性限定语）
    2. 去掉标点、空白与连接词（的/与/和/及）
    3. 剔除结构后缀（"的计算"、"及其性质"、"求极限"…）
    4. 反复执行 3，直到稳定（"重积分的物理应用" → "重积分"）

    归一化后：
    - 「求导法则与基本公式」 → 「求导法则」
    - 「求导法则（四则、复合、反函数）」 → 「求导法则」
    → 完全相等，必然被检出。

    ## 反面教训：不能用"包含"当重复信号

    试过 `ca in cb` 之类的包含判定，误报泛滥：

    ```
    「方差」            ⊂ 「协方差与相关系数」     ← 两个不同概念
    「期望与方差的性质」  ⊂ 「常见分布的期望与方差」 ← 两个不同概念
    「抽样分布」         ⊂ 「正态总体的抽样分布」   ← 一般 vs 特殊
    ```

    所以本函数只负责**归一化**，是否重复由 `duplicate_candidate` 用
    "内核相等 / 相似度达阈值 / 公式内容高度重合"三个信号判断。
    """
    s = name or ""

    # 1. 去掉成对括号及其内部内容
    out: list[str] = []
    depth = 0
    for ch in s:
        if ch in _BRACKET:
            depth += 1 if depth == 0 else -1
            if depth < 0:
                depth = 0
            continue
        if depth == 0:
            out.append(ch)
    s = "".join(out)

    # 2. 去标点、空白与连接词
    s = "".join(c for c in s if c not in _DETECT_DROP)
    s = _norm(s)

    # 3+4. 反复剔除结构后缀，直到稳定
    changed = True
    while changed and s:
        changed = False
        for suf in _STRUCT_SUFFIXES:
            if s.endswith(suf) and len(s) > len(suf):
                s = s[: -len(suf)]
                changed = True
                break

    return s


def _formula_key(f: str) -> str:
    """公式归一化：去掉空白、花括号、排版命令，只看数学内容。"""
    s = str(f)
    for junk in ("\\left", "\\right", "\\,", "\\;", "\\!", "\\quad", "\\qquad",
                 "\\displaystyle", "\\limits", "{", "}", " "):
        s = s.replace(junk, "")
    s = s.replace("\\dfrac", "\\frac").replace("\\tfrac", "\\frac")
    return s.lower()


def content_similarity(a: dict, b: dict) -> float:
    """两个知识点的**内容**重合度（0–1），用于补名称检测的盲区。

    ## 为什么名称不够

    同一概念在不同批次被起成了完全不同的名字：

    ```
    「定积分的性质与牛顿-莱布尼茨公式」  math1.calc.integral.definite_properties
    「定积分性质与计算」                math1.calc.integral.definite
    ```

    名称 Dice 只有 0.47，任何阈值都抓不到。但它们的**公式几乎逐字相同**
    （都写着牛顿-莱布尼茨公式），这才是可靠的重复证据。

    取公式集合的 Jaccard 系数。定义文本不参与 —— 定义是自然语言，
    不同批次措辞差异大，只会制造噪声。
    """
    fa = {_formula_key(f) for f in (a.get("formulas") or [])}
    fb = {_formula_key(f) for f in (b.get("formulas") or [])}
    fa.discard("")
    fb.discard("")
    if not fa or not fb:
        return 0.0
    return len(fa & fb) / len(fa | fb)


# 公式 Jaccard 达到该值即视为"内容高度重合"（仅在名称也有一定相似度时才采信）
CONTENT_THRESHOLD = 0.50

# 采信内容信号时，名称至少要有这么相似 —— 防止"两个不同的知识点恰好共用一条公式"
CONTENT_MIN_NAME_SIM = 0.35


def duplicate_candidate(a: dict, b: dict) -> tuple[bool, str]:
    """判断两个叶子是否值得人工复核为重复。返回 (是否候选, 依据)。

    三个信号（任一成立即候选）：
    1. **内核完全相等** —— 最强信号
    2. **内核/原名相似度 ≥ 阈值**
    3. **公式高度重合 且 名称有起码相似度** —— 补名称检测的盲区

    三者都只用于**提示人工复核**，绝不自动删除。
    """
    na, nb = a.get("name", ""), b.get("name", "")
    ca, cb = core_name(na), core_name(nb)
    if len(ca) < 2 or len(cb) < 2:
        return False, ""
    fs = content_similarity(a, b)
    tag = f"  [公式重合{fs:.2f}]"
    if ca == cb:
        return True, f"内核相同「{ca}」{tag}"
    sim = name_similarity(na, nb)
    if sim >= SIMILARITY_THRESHOLD:
        return True, f"原名相似度 {sim:.2f}{tag}"
    csim = name_similarity(ca, cb)
    if csim >= SIMILARITY_THRESHOLD:
        return True, f"内核相似度 {csim:.2f}{tag}"
    csim = max(sim, csim)
    if csim >= CONTENT_MIN_NAME_SIM and fs >= CONTENT_THRESHOLD:
        return True, f"公式重合 {fs:.2f}（名称相似 {csim:.2f}）"
    return False, ""


# 相似度阈值 —— **仅用于提示候选**，不用于自动删除。
SIMILARITY_THRESHOLD = 0.72

# ─────────────────────────────────────────────────────────────────────────────
# 显式去重白名单
# ─────────────────────────────────────────────────────────────────────────────
#
# 每项是 (保留的 id, [要删除的 id])。保留侧的选取依据：definition 更长、
# formulas/traps 更多（即信息更全的那份）。
#
# ⚠️ 新增前必须：
#   1. 用 --dry-run 打印两份内容对比
#   2. 确认它们说的是**同一个知识点**，而不是共享前缀的不同概念
#      （反例：「二阶常系数齐次方程」vs「二阶常系数非齐次方程」是两回事）
#
KNOWN_DUPLICATES: list[tuple[str, list[str]]] = [
    # ── 高数 · 一元积分学 ──
    ("math1.calc.integral.byparts", ["math1.calc.integral.by_parts"]),
    ("math1.calc.integral.variable_limit", ["math1.calc.integral.varlimit"]),
    ("math1.calc.integral.geometry", ["math1.calc.integral.applications"]),
    # ── 高数 · 多元微分 ──
    ("math1.calc.multidiff.partial_derivative",
     ["math1.calc.multidiff.partial_deriv"]),
    ("math1.calc.multidiff.directional_gradient",
     ["math1.calc.multidiff.direction_gradient"]),
    # ── 高数 · 级数 ──
    ("math1.calc.series.power_sum", ["math1.calc.series.sum_function"]),
    ("math1.calc.series.positive_series", ["math1.calc.series.positive"]),
    # ── 高数 · 曲线曲面积分 ──
    ("math1.calc.curvesurface.surface_int_first",
     ["math1.calc.curvesurface.surface_first"]),
    ("math1.calc.curvesurface.stokes_rot_div",
     ["math1.calc.curvesurface.stokes"]),
    # ── 高数 · 微分方程 ──
    ("math1.calc.ode.first_order_separable", ["math1.calc.ode.separable"]),
    ("math1.calc.ode.reducible_order", ["math1.calc.ode.reducible"]),
    # ⚠️ 注意：math1.calc.ode.linear2_homo（齐次）与 linear2_nonhomo（非齐次）
    #    是**两个不同知识点**，绝不能合并 —— 这里刻意不列入白名单。
    # ── 线代 ──
    ("math1.linalg.det.definition_properties", ["math1.linalg.det.definition"]),
    ("math1.linalg.eigen.eigenvalue", ["math1.linalg.eigen.eigen_calc"]),
    ("math1.linalg.eigen.similarity", ["math1.linalg.eigen.similar"]),
    # ── 概率 · 数字特征 ──
    ("math1.prob.numchar.covariance", ["math1.prob.numchar.cov_corr"]),
    ("math1.prob.numchar.common_numchar", ["math1.prob.numchar.common_char"]),
    # ── 概率 · 大数定律 ──
    ("math1.prob.lln.chebyshev", ["math1.prob.lln.chebyshev_inequality"]),
    ("math1.prob.lln.clt_levy", ["math1.prob.lln.clt_iid"]),
    # ── 概率 · 一维随机变量 ──
    ("math1.prob.rv1.distribution_function", ["math1.prob.rv1.dist_func"]),
    ("math1.prob.rv1.discrete_distribution", ["math1.prob.rv1.discrete_law"]),
    ("math1.prob.rv1.continuous_density", ["math1.prob.rv1.density"]),
    ("math1.prob.rv1.function_of_rv", ["math1.prob.rv1.func_dist"]),
    ("math1.prob.rv1.normal_distribution", ["math1.prob.rv1.normal"]),
    ("math1.prob.rv1.mixed_type", ["math1.prob.rv1.mixed_dist"]),
    # ── 概率 · 二维随机变量 ──
    ("math1.prob.rv2.uniform_2d", ["math1.prob.rv2.uniform2d"]),
    ("math1.prob.rv2.normal_2d", ["math1.prob.rv2.normal2d"]),
    # ── 概率 · 数理统计 ──
    ("math1.prob.stat.population_sample", ["math1.prob.stat.sample_statistics"]),
    ("math1.prob.stat.moment_estimation", ["math1.prob.stat.moment_est"]),
]


def _candidates(nodes: list[dict]):
    """枚举全部疑似重复对。产出 (依据, 范围, A, B, 是否已在白名单)。

    **只在同范围（同 id 前缀）内比较** —— 跨章节的重复是另一类问题，
    混在一起会让信号变脏（不同章节共用一条通用公式很常见）。
    """
    by_scope: dict[str, list[dict]] = defaultdict(list)
    for n in nodes:
        if n.get("is_leaf"):
            by_scope[n["id"].rsplit(".", 1)[0]].append(n)

    out = []
    for scope, group in sorted(by_scope.items()):
        for i, a in enumerate(group):
            for b in group[i + 1 :]:
                hit, why = duplicate_candidate(a, b)
                if not hit:
                    continue
                already = any(
                    (a["id"] in keep and b["id"] in drops)
                    or (b["id"] in keep and a["id"] in drops)
                    for keep, drops in KNOWN_DUPLICATES
                )
                out.append((why, scope, a, b, already))
    return out


def dedupe_subject(
    subject: str, dry_run: bool, suggest: bool, review: bool = False
) -> tuple[int, int]:
    """返回 (去重组数, 移除节点数)。"""
    path = KP_DIR / f"{subject}.json"
    if not path.exists():
        print(f"  跳过：{path.name} 不存在")
        return 0, 0

    doc = json.loads(path.read_text(encoding="utf-8"))
    nodes = [n for n in doc.get("nodes", []) if isinstance(n, dict)]
    by_id = {n["id"]: n for n in nodes if n.get("id")}

    # ── suggest 模式：只提示相似候选，不做任何删除 ──
    if suggest:
        for why, scope, a, b, already in _candidates(nodes):
            mark = "（已在白名单）" if already else "← 待人工判断"
            print(f"  {why:<28} {scope}")
            print(f"        A 「{a.get('name')}」 {a['id']}")
            print(f"        B 「{b.get('name')}」 {b['id']}  {mark}")
        return 0, 0

    # ── review 模式：打印候选对的**完整内容**，供人工逐对判定 ──
    if review:
        for why, scope, a, b, already in _candidates(nodes):
            print()
            print("=" * 74)
            print(f"依据：{why}    范围：{scope}"
                  + ("    [已在白名单]" if already else ""))
            for side, n in (("A", a), ("B", b)):
                print("-" * 74)
                print(f"  {side}  {n['id']}")
                print(f"      「{n.get('name')}」 {score_desc(n)}")
                definition = (n.get("definition") or "").replace("\n", " ")
                print(f"      定义：{definition[:260]}")
                for f in (n.get("formulas") or [])[:4]:
                    print(f"      公式：{f}")
        return 0, 0

    # ── 按白名单删除 ──
    remove_ids: set[str] = set()
    groups = 0
    print(f"  {subject}：白名单 {len([k for k, _ in KNOWN_DUPLICATES if k.startswith(subject)])} 组")

    for keep_id, drop_ids in KNOWN_DUPLICATES:
        if not keep_id.startswith(subject):
            continue
        keep = by_id.get(keep_id)
        if keep is None:
            print(f"  [!] 保留项不存在，跳过：{keep_id}")
            continue

        actual_drops = [d for d in drop_ids if d in by_id]
        if not actual_drops:
            continue

        groups += 1
        print(f"\n  ── 保留 {keep_id}")
        print(f"      「{keep.get('name')}」 {score_desc(keep)}")
        for d in actual_drops:
            drop = by_id[d]
            sim = name_similarity(keep.get("name", ""), drop.get("name", ""))
            print(f"     移除 {d}")
            print(f"          「{drop.get('name')}」 {score_desc(drop)} 相似度{sim:.2f}")
            remove_ids.add(d)

    if not remove_ids:
        print(f"  [OK] {subject}：无需去重")
        return 0, 0

    if dry_run:
        print(f"\n  [dry-run] 将移除 {len(remove_ids)} 个节点")
        return groups, len(remove_ids)

    # ⚠️ 先合并内容，再删节点。
    #
    # 早期版本直接 `[n for n in nodes if id not in remove_ids]` 就把节点删了，
    # 而 `merge_into` 虽然写好了却**从来没有被调用过** ——
    # 结果被删那一侧的公式、陷阱、考频年份、别名全部无声丢失。
    # 去重的语义是"合并冗余"，不是"挑一份、扔掉另一份"。
    merged_notes: list[str] = []
    for keep_id, drop_ids in KNOWN_DUPLICATES:
        if not keep_id.startswith(subject):
            continue
        keep = by_id.get(keep_id)
        if keep is None:
            continue
        for d in drop_ids:
            drop = by_id.get(d)
            if drop is None or d not in remove_ids:
                continue
            notes = merge_into(keep, drop)
            if notes:
                merged_notes.append(f"  {keep_id} ← {d}：{'、'.join(notes)}")
    for line in merged_notes:
        print(line)

    doc["nodes"] = [n for n in nodes if n.get("id") not in remove_ids]
    cov = doc.setdefault("coverage", {})
    cov["deduped_at"] = "2026-03-15"
    cov["deduped_removed"] = len(remove_ids)

    path.write_text(
        json.dumps(doc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"\n  [OK] 已写入 {path.name}：移除 {len(remove_ids)} 个冗余节点")
    return groups, len(remove_ids)


def main() -> int:
    ap = argparse.ArgumentParser(description="知识点冗余去重（白名单制）")
    ap.add_argument("--subject", help="只处理指定科目")
    ap.add_argument("--all", action="store_true", help="处理全部科目")
    ap.add_argument("--dry-run", action="store_true", help="只报告，不写文件")
    ap.add_argument(
        "--suggest",
        action="store_true",
        help="只列出相似名候选供人工判断（不做删除）",
    )
    ap.add_argument(
        "--review",
        action="store_true",
        help="打印候选对的完整内容，供逐对人工判定（不做删除）",
    )
    args = ap.parse_args()

    subjects = (
        [args.subject] if args.subject
        else ["math1", "math2", "math3"] if args.all
        else ["math1"]
    )

    total_groups = total_removed = 0
    for s in subjects:
        print(f"\n{'=' * 70}\n科目 {s}\n{'=' * 70}")
        g, r = dedupe_subject(s, args.dry_run, args.suggest, args.review)
        total_groups += g
        total_removed += r

    if not args.suggest and not args.review:
        print(f"\n{'=' * 70}")
        print(f"合计：{total_groups} 组，移除 {total_removed} 个冗余节点")
        if args.dry_run:
            print("（dry-run，未写入）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
