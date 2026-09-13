"""扫描知识点本体的 `formulas`，找出 LaTeX 花括号不配平的条目。

## 为什么要做这一步

KaTeX 实测跑全语料时有 2 条**真实知识点公式**解析失败，其中一条是
`\\text{...}` 少了收尾花括号 —— 那是**数据录入错误**，不是渲染器的锅。
渲染器再好也救不了不合法的 LaTeX，而这种错误在界面上表现为
"这条公式显示成源码"，很难被当成数据问题去追。

所以在接渲染器之前先把数据扫干净：花括号必须配平，
且 `\\text{}` / `\\left` / `\\right` 这类"必须成对"的构造要单独看。

## 为什么不用 KaTeX 自己来判

用渲染器当校验器会把"渲染器的支持范围"和"公式的合法性"混在一起：
KaTeX 不支持 `\\iddots`，但 `\\iddots` 本身是合法的 LaTeX。
这个脚本只做**结构**检查，规则明确、可解释。

用法：
    python tools/data/check_formulas.py            # 只报告
    python tools/data/check_formulas.py --strict   # 有问题时退出码非 0
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
KP_DIR = ROOT / "data" / "knowledge_points"

# 只查权威本体文件。`*_rest.json` 等分片是历史残留，修它们没有意义
# （内容已并入权威文件，而管线也不会再读它们）。
AUTHORITATIVE = ["math1.json", "math2.json", "math3.json"]


def walk_formulas(node: dict, path: str):
    """递归产出 (知识点 id, 公式下标, 公式文本)。"""
    kp_id = node.get("id") or path
    for i, f in enumerate(node.get("formulas") or []):
        if isinstance(f, str):
            yield kp_id, i, f
    for child in node.get("children") or []:
        yield from walk_formulas(child, kp_id)


def brace_balance(s: str) -> tuple[int, int]:
    """返回 (未闭合的左括号数, 多余的右括号数)。

    `\\{` 与 `\\}` 是转义后的字面花括号，不参与配平 ——
    少了这一步，`\\{x\\}` 会被误判成不配平。
    """
    depth = 0
    surplus_close = 0
    i = 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            i += 2  # 跳过被转义的字符，包括 \{ \}
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            if depth == 0:
                surplus_close += 1
            else:
                depth -= 1
        i += 1
    return depth, surplus_close


def pairing_problems(s: str) -> list[str]:
    """检查必须成对出现的构造。"""
    out: list[str] = []
    # \left 必须配 \right
    if s.count(r"\left") != s.count(r"\right"):
        out.append(r"\left/\right 不成对")
    # \begin{env} 必须配 \end{env}
    begins = [s[m:] for m in _find_all(s, r"\begin{")]
    ends = [s[m:] for m in _find_all(s, r"\end{")]
    if len(begins) != len(ends):
        out.append(r"\begin/\end 数量不等")
    return out


def _find_all(s: str, needle: str) -> list[int]:
    out: list[int] = []
    start = 0
    while True:
        i = s.find(needle, start)
        if i < 0:
            return out
        out.append(i)
        start = i + len(needle)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--strict", action="store_true", help="有问题时返回非 0")
    args = ap.parse_args()

    total = 0
    problems: list[tuple[str, str, int, str, list[str]]] = []

    for name in AUTHORITATIVE:
        f = KP_DIR / name
        if not f.exists():
            print(f"[跳过] {name} 不存在")
            continue
        data = json.loads(f.read_text(encoding="utf-8"))
        roots = data.get("nodes") or []
        for root in roots:
            for kp_id, idx, latex in walk_formulas(root, name):
                total += 1
                issues: list[str] = []
                unclosed, surplus = brace_balance(latex)
                if unclosed:
                    issues.append(f"缺少 {unclosed} 个 '}}'")
                if surplus:
                    issues.append(f"多出 {surplus} 个 '}}'")
                issues.extend(pairing_problems(latex))
                if issues:
                    problems.append((name, kp_id, idx, latex, issues))

    print(f"扫描 {len(AUTHORITATIVE)} 个权威本体文件，共 {total} 条公式")
    if not problems:
        print("[OK] 没有发现结构性问题的公式")
        return 0

    print(f"\n[!] {len(problems)} 条公式有结构性问题：\n")
    for name, kp_id, idx, latex, issues in problems:
        print(f"  {name} · {kp_id} · formulas[{idx}]")
        print(f"    {' / '.join(issues)}")
        print(f"    {latex}")
        print()

    return 1 if args.strict else 0


if __name__ == "__main__":
    sys.exit(main())
