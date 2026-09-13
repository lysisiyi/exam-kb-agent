#!/usr/bin/env python3
"""知识点别名生成器 —— 把"名称片段"与"人工符号别名"写进知识点本体。

## 为什么需要别名（技术债 T15）

召回层用**规则**从 198 个叶子里粗筛 25 个候选给 LLM。规则靠字面重合，
于是有一类题必然失败：**题干不含知识点名**。

```
gold-011  设 X~N(0,1)，求 P{|X|<1}
          期望考点「正态分布及其标准化计算」
          题干里既没有"正态分布"四个字，也没有完整的知识点名
          → 规则完全匹配不上，LLM 再强也选不对（答案根本没进候选）
```

实测 4 道失败题全是这个模式。而它们恰恰是 LLM 最擅长的
（认出 N(0,1) 就是正态分布）。

**别名的本质是"把知识点名翻译成题干里可能出现的样子"**，
让规则匹配够得着，剩下的交给 LLM。

## 两类别名

### 1. 名称片段（自动派生）
中文知识点名几乎都是**复合短语**，整名匹配等于要求题干写全称：

| 知识点名 | 题干实际会写的 |
|---|---|
| 正态分布及其标准化计算 | 正态分布 |
| 单调性、极值与最值 | 极值 |
| 二重积分（极坐标） | 二重积分 |
| 一阶线性微分方程与伯努利方程 | 微分方程、通解 |
| 泰勒公式求极限 | 泰勒公式 |

按分隔符（及其 / 与 / 、/ 括号）拆开，再剥掉结构后缀（的计算 / 及其性质 /
求极限…），就得到片段。这一步能自动覆盖全部 329 个叶子。

### 2. 符号别名（人工维护）
纯符号的题干连片段都匹配不上：

```
X~N(μ,σ²)        → 正态分布
∬_D f dσ         → 二重积分（极坐标）
y'+P(x)y=Q(x)    → 一阶线性微分方程
```

这类映射是**领域知识**，无法从名称派生，必须人工写。
放在 `data/knowledge_points/alias_overrides.json`。

## 输出
把 `aliases` 数组写进 `data/knowledge_points/{subject}.json` 的叶子节点。
生成器**幂等**：重复运行结果一致。

## 用法
    python tools/data/gen_aliases.py --check        # 只报告差异
    python tools/data/gen_aliases.py --all          # 生成并写回
    python tools/data/gen_aliases.py --subject math1 --show   # 打印每个叶子的别名
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

ROOT = Path(__file__).resolve().parents[2]
KP_DIR = ROOT / "data" / "knowledge_points"
OVERRIDE_FILE = KP_DIR / "alias_overrides.json"

# 分隔符：按这个顺序切分（长分隔符必须在前，否则 "及其" 会被 "及" 抢先切开）
SEPARATORS = [
    "及其", "以及与", "以及", "与其", "与", "及",
    "、", "，", ",", "；", ";", "/", "·",
    "（", "）", "(", ")",
]

# 结构后缀：剥掉之后剩下的才是"概念内核"，也才是题干里可能出现的词。
# 长后缀必须排在前（"的计算" 要在 "计算" 之前尝试）。
STRUCT_SUFFIXES = [
    "及其标准化计算", "的标准化计算", "标准化计算",
    "及其矩阵表示", "的矩阵表示",
    "的计算方法", "的计算技巧", "的计算与应用", "的计算",
    "的基本公式", "的综合应用", "的等价条件", "的判定与等价条件",
    "的判定", "的应用", "的性质", "的讨论", "的求法", "的求解",
    "的运算", "的方法", "的表示", "的概念", "的结构",
    "计算技巧", "计算方法", "计算",
    "判定", "应用", "性质", "讨论", "求极限", "求法", "求解",
    "方法", "概念", "表示", "运算",
]

# 切出来的片段若只是这些泛词，没有区分度，直接丢弃。
STOP_FRAGMENTS = {
    "性质", "应用", "计算", "判定", "方法", "概念", "讨论", "表示",
    "运算", "求解", "求法", "分类", "关系", "结构", "存在性",
    "等价条件", "综合应用", "间接法", "直接法", "基本公式",
    "标准化计算", "计算技巧", "计算方法", "矩阵表示",
    "定义", "定理", "公式", "一般", "特殊",
    "物理", "几何", "联系", "步骤", "技巧", "意义", "条件", "结论",
    "比较", "不等式", "证明", "求导", "判断", "推导",
}

# "定语 + 的 + 中心语" 里，定语若是这些泛词就不要单独成别名。
# 否则会产出「曲线」「函数」这种在任何题干里都出现的别名，纯噪声。
STOP_HEADS = {
    "曲线", "函数", "方程", "方程组", "矩阵", "向量", "级数", "积分",
    "数列", "事件", "分布", "总体", "样本", "估计量", "二次型",
    "空间", "平面", "区域", "随机变量", "曲面", "极限", "导数",
}

_CJK = re.compile(r"[\u4e00-\u9fff]")


def _clean(part: str) -> str:
    """去掉片段两端的空白与残留标点。"""
    return part.strip().strip("　 、，,；;·-—的").strip()


def _strip_suffix(part: str) -> str:
    """剥掉一个结构后缀（只剥一次，最长匹配优先）。"""
    for suf in STRUCT_SUFFIXES:
        if part.endswith(suf) and len(part) > len(suf):
            return part[: -len(suf)]
    return part


def _plausible(frag: str) -> bool:
    """片段是否值得作为别名。

    - 至少 2 个字符
    - 含汉字，或形如 N(0,1) 的符号串（含字母/数字/括号）
    - 不是纯泛词
    """
    if len(frag) < 2:
        return False
    if frag in STOP_FRAGMENTS:
        return False
    if _CJK.search(frag):
        return True
    # 非中文片段：只接受带数字/括号的符号串，避免收录 "abc" 之类的噪声
    return bool(re.search(r"[0-9()]", frag))


def derive_aliases(name: str) -> list[str]:
    """从一个知识点名派生出可用的别名片段。

    ## 例
    | 名称 | 派生别名 |
    |---|---|
    | 正态分布及其标准化计算 | 正态分布、标准化计算→（被 STOP 丢弃） |
    | 单调性、极值与最值 | 单调性、极值、最值 |
    | 二重积分（极坐标） | 二重积分、极坐标 |
    | 三重积分的计算 | 三重积分 |
    | 泰勒公式求极限 | 泰勒公式 |
    | 定积分的性质与牛顿-莱布尼茨公式 | 定积分、牛顿-莱布尼茨公式、定积分性质 |
    | 齐次线性方程组 | （无：整名已由名称匹配覆盖） |

    ## 为什么同时产出"剥后缀前"和"剥后缀后"

    「定积分的性质」剥掉"的性质"得到「定积分」，但题干也可能写"定积分的性质"，
    所以两者都留。别名多一条的代价只是数据大一点，漏一条的代价是召回失败。
    """
    if not name:
        return []

    # 1. 按分隔符切分
    parts = [name]
    for sep in SEPARATORS:
        nxt: list[str] = []
        for p in parts:
            nxt.extend(p.split(sep))
        parts = nxt

    out: list[str] = []
    for raw in parts:
        part = _clean(raw)
        if not part:
            continue

        # 2a. 片段本身
        if _plausible(part) and part != name:
            out.append(part)

        # 2b. 剥掉结构后缀后的版本
        stripped = _strip_suffix(part)
        if stripped != part and _plausible(stripped) and stripped != name:
            out.append(stripped)

        # 2c. "定语 + 的 + 中心语"：定语与中心语各自都可能是题干里的说法
        #
        # 「反常积分的敛散性」 → 「反常积分」+「敛散性」
        # 「曲线的凹凸性」     → 「凹凸性」（定语"曲线"是泛词，丢弃）
        # 「定积分的性质」     → 「定积分」（中心语"性质"是泛词，丢弃）
        if "的" in part:
            head, tail = part.rsplit("的", 1)
            head, tail = _clean(head), _clean(tail)
            for cand in (tail, _strip_suffix(tail)):
                if _plausible(cand) and cand != name and cand not in out:
                    out.append(cand)
            if head not in STOP_HEADS:
                for cand in (head, _strip_suffix(head)):
                    if _plausible(cand) and cand != name and cand not in out:
                        out.append(cand)

    # 3. 整名剥后缀
    #
    # ⚠️ 只在**没有分隔符**时才做。否则会把复合名的尾巴也剥掉，产出垃圾：
    #    「重积分的几何与物理应用」 → 「重积分的几何与物理」（不是任何真实说法）
    if len(parts) == 1:
        whole = _strip_suffix(_clean(name))
        if whole != name and _plausible(whole):
            out.append(whole)

    # 去重并保序
    seen: set[str] = set()
    unique: list[str] = []
    for a in out:
        if a not in seen:
            seen.add(a)
            unique.append(a)
    return unique


def load_overrides() -> dict:
    if not OVERRIDE_FILE.exists():
        return {}
    doc = json.loads(OVERRIDE_FILE.read_text(encoding="utf-8"))
    return doc.get("aliases") or {}


def build_aliases(name: str, kp_id: str, overrides: dict) -> list[str]:
    """合并人工别名与派生片段。**人工别名排在前面**（它们是刻意设计的签名）。"""
    manual = list(overrides.get(kp_id) or [])
    derived = derive_aliases(name)

    seen: set[str] = set()
    out: list[str] = []
    for a in manual + derived:
        a = _clean(a)
        if not a or a == name or a in seen:
            continue
        seen.add(a)
        out.append(a)
    return out


def process_subject(subject: str, overrides: dict, check: bool, show: bool) -> int:
    """返回 0 表示无变化/成功，1 表示 check 模式下有差异。"""
    path = KP_DIR / f"{subject}.json"
    if not path.exists():
        print(f"  跳过：{path.name} 不存在")
        return 0

    doc = json.loads(path.read_text(encoding="utf-8"))
    nodes = doc.get("nodes") or []

    changed = 0
    total_leaves = 0
    total_aliases = 0
    missing_override: list[str] = []

    for n in nodes:
        if not n.get("is_leaf"):
            continue
        total_leaves += 1
        want = build_aliases(n.get("name", ""), n["id"], overrides)
        total_aliases += len(want)
        # ⚠️ 必须用 `or []` —— 没有别名的叶子会被 pop 掉该字段，
        # `n.get("aliases")` 返回 None，而 `None != []` 恒为真，
        # 会让"已是最新"被误报成"需要更新"，工具失去幂等性。
        if (n.get("aliases") or []) != want:
            changed += 1
            if check:
                old = n.get("aliases") or []
                print(f"  ~ {n['id']}")
                print(f"      旧：{old}")
                print(f"      新：{want}")
        if not check:
            if want:
                n["aliases"] = want
            else:
                n.pop("aliases", None)
        if show:
            print(f"  {n['id']:<52} {want}")

    # 人工别名指向了不存在的知识点 —— 通常是改名/去重后忘了同步
    leaf_ids = {n["id"] for n in nodes if n.get("is_leaf")}
    for kp_id in overrides:
        if kp_id.startswith(subject) and kp_id not in leaf_ids:
            missing_override.append(kp_id)

    print(f"  叶子 {total_leaves}，别名合计 {total_aliases} 条"
          f"（平均 {total_aliases / total_leaves:.1f} 条/叶子）")
    if missing_override:
        print(f"  [X] {len(missing_override)} 条人工别名指向不存在的知识点：")
        for k in missing_override:
            print(f"      {k}")

    if check:
        print(f"  [check] 需更新 {changed} 个叶子（未写入）")
        return 1 if changed or missing_override else 0

    if changed:
        path.write_text(
            json.dumps(doc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        print(f"  [OK] 已写入 {path.name}：更新 {changed} 个叶子的别名")
    else:
        print("  [OK] 别名已是最新，无需写入")

    return 1 if missing_override else 0


def main() -> int:
    ap = argparse.ArgumentParser(description="知识点别名生成")
    ap.add_argument("--subject", help="只处理指定科目")
    ap.add_argument("--all", action="store_true", help="处理全部三个科目")
    ap.add_argument("--check", action="store_true", help="只报告差异，不写文件")
    ap.add_argument("--show", action="store_true", help="打印每个叶子的别名")
    args = ap.parse_args()

    overrides = load_overrides()
    print(f"人工符号别名：{len(overrides)} 个知识点"
          f"（共 {sum(len(v) for v in overrides.values())} 条）")

    if args.subject:
        subjects = [args.subject]
    elif args.all:
        subjects = ["math1", "math2", "math3"]
    else:
        subjects = ["math1"]

    bad = 0
    for s in subjects:
        print(f"\n{'=' * 72}\n科目 {s}\n{'=' * 72}")
        bad |= process_subject(s, overrides, args.check, args.show)

    return bad


if __name__ == "__main__":
    sys.exit(main())
