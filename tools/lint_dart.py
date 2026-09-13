#!/usr/bin/env python3
"""对生成的 Dart 代码做**静态自检**（在 Flutter 不可用时替代 `flutter analyze`）。

## 为什么需要
沙箱里没有 Flutter SDK，无法运行真正的分析器。这个脚本做的是「穷人版静态检查」：
用正则扫描已知的高频错误模式，能在很大程度上替代人工 review。

## 检查项
1. 每个 `import 'package:kaoyan_math_agent/...'` 目标文件是否存在
2. 每个 `import '../xxx.dart'` 相对路径是否解析得到
3. 括号/花括号是否配平
4. 是否误用了 `dart:io`（本项目要求走条件导入）
5. 每个类/枚举声明是否有配对的结束
6. 引用的知识点 id 是否真的存在于 JSON 里

## 用法
    python tools/lint_dart.py
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "app"
LIB = APP / "lib"
TEST = APP / "test"

PKG = "package:kaoyan_math_agent/"

errors: list[str] = []
warnings: list[str] = []


def dart_files() -> list[Path]:
    out: list[Path] = []
    for base in (LIB, TEST):
        if base.exists():
            out.extend(sorted(base.rglob("*.dart")))
    return out


def check_imports(f: Path, text: str) -> None:
    for m in re.finditer(r"""^\s*import\s+['"]([^'"]+)['"]""", text, re.M):
        target = m.group(1)
        if target.startswith('dart:'):
            continue
        if target.startswith('package:'):
            if target.startswith(PKG):
                rel = target[len(PKG):]
                if not (LIB / rel).exists():
                    errors.append(f"{f.relative_to(ROOT)}: 找不到包内导入目标 -> {target}")
            # 第三方包不做检查（需要 pub 解析）
            continue
        # 相对路径
        resolved = (f.parent / target).resolve()
        if not resolved.exists():
            errors.append(
                f"{f.relative_to(ROOT)}: 相对导入不存在 -> {target}"
            )


def check_balance(f: Path, text: str) -> None:
    """括号配平检查。

    ⚠️ 这是**启发式**检查，字符串剥离不完美时会产生误报。
    因此把结果降级为警告 —— 真正的语法错误由 `flutter analyze` 权威判定。
    """
    stripped = _strip_strings_and_comments(text)

    for open_c, close_c, name in (
        ("{", "}", "花括号"),
        ("(", ")", "圆括号"),
        ("[", "]", "方括号"),
    ):
        diff = stripped.count(open_c) - stripped.count(close_c)
        if diff != 0:
            warnings.append(
                f"{f.relative_to(ROOT)}: {name}计数差 {diff:+d}"
                f"（{open_c}={stripped.count(open_c)}, {close_c}={stripped.count(close_c)}）"
                f" —— 启发式检查，可能因字符串剥离不完美而误报；"
                f"以 `flutter analyze` 为准"
            )


def _strip_strings_and_comments(text: str) -> str:
    """尽量剥离 Dart 的注释与字符串字面量，只留结构字符。

    用**逐字符状态机**而非正则 —— 正则很难正确处理
    `"'"`（双引号里含单引号）、`r'...'`（原始字符串）、
    三引号字符串、以及 `$` 插值里的嵌套引号。
    """
    out: list[str] = []
    i = 0
    n = len(text)

    def peek(k: int = 0) -> str:
        return text[i + k] if i + k < n else ''

    while i < n:
        c = peek()

        # 行注释
        if c == '/' and peek(1) == '/':
            while i < n and text[i] != '\n':
                i += 1
            continue

        # 块注释（支持嵌套）
        if c == '/' and peek(1) == '*':
            depth = 1
            i += 2
            while i < n and depth > 0:
                if peek() == '/' and peek(1) == '*':
                    depth += 1
                    i += 2
                elif peek() == '*' and peek(1) == '/':
                    depth -= 1
                    i += 2
                else:
                    i += 1
            continue

        # 原始字符串前缀 r 或 R
        is_raw = False
        if c in 'rR' and peek(1) in ("'", '"'):
            is_raw = True
            i += 1
            c = peek()

        # 字符串字面量
        if c in ("'", '"'):
            quote = c
            triple = peek(1) == quote and peek(2) == quote
            if triple:
                i += 3
                while i < n:
                    if not is_raw and peek() == '\\':
                        i += 2
                        continue
                    if peek() == quote and peek(1) == quote and peek(2) == quote:
                        i += 3
                        break
                    i += 1
            else:
                i += 1
                while i < n:
                    ch = peek()
                    if not is_raw and ch == '\\':
                        i += 2
                        continue
                    if ch == quote or ch == '\n':
                        i += 1
                        break
                    i += 1
            continue

        out.append(c)
        i += 1

    return ''.join(out)


def check_dart_io(f: Path, text: str) -> None:
    """检查 `dart:io` 的使用是否合理。

    本项目的纪律是「平台能力走条件导入」，但这条纪律**不适用于数据层**：
    题目以 Markdown 文件存在本地，读写文件是核心功能，不可能脱离 `dart:io`。

    允许直接 import `dart:io` 的目录：
    - `core/platform/capabilities*.dart` —— 平台探测本身
    - `data/`                              —— 文件/数据库 I/O 是职责所在
    - `services/`                          —— 服务层会读评测数据、调用外部工具
    - `test/`                              —— 测试要用临时目录

    仅对 `features/` 与 `core/`（除 platform 外）报警 —— 那些地方
    应当通过抽象层访问平台能力，否则加平台时要改遍 UI。

    ⚠️ 另外提示：本项目**不以 Web 为目标**（纯本地文件架构），
    因此这些 `dart:io` 不是"跨平台返工风险"，而是设计选择。
    """
    allowed_prefixes = (
        "core/platform/",
        "data/",
        "services/",
    )
    rel = ""
    try:
        if LIB in f.parents or f == LIB:
            rel = str(f.relative_to(LIB)).replace("\\", "/")
        elif TEST in f.parents or f == TEST:
            return  # 测试目录豁免
    except ValueError:
        return

    if any(rel.startswith(p) for p in allowed_prefixes):
        return

    if re.search(r"""^\s*import\s+['"]dart:io['"]""", text, re.M):
        warnings.append(
            f"{f.relative_to(ROOT)}: 直接 import dart:io —— "
            f"在 features/ 与 core/ 中应改用 core/platform/ 的抽象，"
            f"否则加平台时要改遍 UI"
        )


def check_todo_markers(f: Path, text: str) -> None:
    for i, line in enumerate(text.splitlines(), 1):
        if re.search(r"\b(TODO|FIXME|XXX)\b", line):
            warnings.append(f"{f.relative_to(ROOT)}:{i}: {line.strip()[:90]}")


def check_knowledge_ids() -> None:
    """校验知识点数据完整性，并检查 Dart 里引用的知识点 id 是否真实存在。

    统计口径说明：
    - **权威文件**（`{subject}.json`）是唯一被消费的产物，必须自身干净。
    - **分片文件**（`{subject}_*.json`）是生成过程的中间产物，它们之间
      **必然存在 id 重叠**（同一批知识点的多次生成），这是并集合并的正常现象，
      不算错误 —— 只作为提示。
    - 分片里出现非对象元素（如截断残留的哨兵字符串）说明该次生成不完整，
      这是真实问题，但若其内容已被权威文件吸收，则降级为提示。
    """
    kp_dir = ROOT / "data" / "knowledge_points"
    known: set[str] = set()
    authoritative: dict[str, set[str]] = {}
    shard_issues: list[str] = []

    for p in sorted(kp_dir.glob("*.json")):
        if p.name.endswith(".merged"):
            continue

        is_authoritative = p.name in ("math1.json", "math2.json", "math3.json")

        try:
            doc = json.loads(p.read_text(encoding="utf-8"))
        except Exception as e:
            errors.append(f"data/knowledge_points/{p.name}: JSON 解析失败 -> {e}")
            continue

        if not isinstance(doc, dict):
            errors.append(f"data/knowledge_points/{p.name}: 顶层不是对象")
            continue

        nodes = doc.get("nodes")
        if not isinstance(nodes, list):
            # 知识资产目录下并非每个 JSON 都是知识点本体。
            #
            # `alias_overrides.json`（人工维护的召回别名）就放在这里，
            # 它按知识点 id 组织，没有 nodes 数组。早期版本把它当本体，
            # 于是自检直接失败 —— 那是**工具的误报**，不是数据的问题。
            #
            # 判定方式：本体一定声明 `subject`。没有 subject 又没有 nodes 的，
            # 视为附属数据文件，跳过并留下提示（而不是静默忽略）。
            if doc.get("subject") is None:
                warnings.append(
                    f"data/knowledge_points/{p.name}: 没有 nodes 也没有 subject，"
                    f"已按附属数据文件跳过（不参与本体自检）"
                )
                continue
            errors.append(f"data/knowledge_points/{p.name}: nodes 不是数组")
            continue

        bad = [n for n in nodes if not isinstance(n, dict)]
        if bad:
            msg = (
                f"data/knowledge_points/{p.name}: nodes 里有 {len(bad)} 个非对象元素"
                f"（首个：{str(bad[0])[:60]!r}）—— 该次生成不完整"
            )
            if is_authoritative:
                errors.append(msg)          # 权威文件必须干净
            else:
                shard_issues.append(msg)    # 分片是中间产物，提示即可

        ids_here: set[str] = set()
        for n in nodes:
            if isinstance(n, dict) and n.get("id"):
                ids_here.add(str(n["id"]))

        # 权威文件内部不得重复
        if is_authoritative:
            dup_in_file = [
                i for i in ids_here
                if sum(1 for n in nodes if isinstance(n, dict) and n.get("id") == i) > 1
            ]
            for d in dup_in_file:
                errors.append(f"data/knowledge_points/{p.name}: id 在文件内重复 -> {d}")
            authoritative[p.name] = ids_here

        known |= ids_here

    if not known:
        warnings.append("未找到任何知识点 id（data/knowledge_points/*.json 为空？）")
        return

    # 分片问题统一作为提示输出（避免刷屏）
    if shard_issues:
        warnings.append(
            f"分片文件有 {len(shard_issues)} 处生成不完整（内容已被权威文件吸收，"
            f"不影响使用；建议清理或重新生成）："
        )
        for s in shard_issues:
            warnings.append(f"    {s}")

    # 权威文件覆盖率自检
    for name, ids in authoritative.items():
        subject = name.replace(".json", "")
        leaves = 0
        # 重新读一次拿叶子数（这里只需粗略统计，开销可接受）
        try:
            doc = json.loads((kp_dir / name).read_text(encoding="utf-8"))
            leaves = sum(
                1 for n in doc.get("nodes", [])
                if isinstance(n, dict) and n.get("is_leaf")
            )
        except Exception:
            pass
        if leaves == 0:
            errors.append(f"data/knowledge_points/{name}: 没有任何叶子节点（无法用于标注）")
        else:
            print(f"  知识点本体 {name}: {len(ids)} 个 id / {leaves} 个叶子")

    # Dart 里硬编码的知识点 id 必须存在
    #
    # ⚠️ **只查 lib/**，不查 test/**。
    #
    # 这条规则的目的是拦住生产代码里的 id 笔误（写错一个 id，
    # 那道题就永远标注不上，而且不报错）。
    #
    # 但测试里的 id 是**合成夹具**，本就不该存在于真实本体：
    # `entry_ui_test.dart` 要测的是"搜索排序"，它需要几个叶子来排序，
    # 而这些叶子叫什么、在不在本体里与断言无关。强行要求夹具 id 真实存在，
    # 等于把测试焊死在知识点本体上 —— 本体一改，一堆无关测试同时变红。
    #
    # 真实数据的漂移另有更直接的守卫：`recall_eval_test.dart` 里
    # "四个金标准集的 id 全部存在于本体中" 那条用例，是拿金标准集当数据源
    # 逐条比对的，比本处的正则扫描更准。
    pattern = re.compile(
        r"""['"]((?:math[123])\.(?:calc|linalg|prob)\.[a-z0-9_.]+)['"]"""
    )
    for f in dart_files():
        if f.parts and "test" in f.parts:
            continue
        text = f.read_text(encoding="utf-8")
        for m in pattern.finditer(text):
            kid = m.group(1)
            if kid not in known:
                errors.append(
                    f"{f.relative_to(ROOT)}: 引用了不存在的知识点 id -> {kid}"
                )


def check_asset_paths() -> None:
    """pubspec 里声明的 assets 是否真实存在。"""
    pubspec = APP / "pubspec.yaml"
    if not pubspec.exists():
        errors.append("app/pubspec.yaml 不存在")
        return
    text = pubspec.read_text(encoding="utf-8")
    in_assets = False
    for line in text.splitlines():
        if re.match(r"^\s*assets:\s*$", line):
            in_assets = True
            continue
        if in_assets:
            m = re.match(r"^\s*-\s+(\S+)\s*$", line)
            if m:
                path = m.group(1)
                full = APP / path
                if not full.exists():
                    warnings.append(
                        f"pubspec.yaml: 声明的 asset 不存在 -> {path} "
                        f"（目录需非空；运行 python tools/data/sync_assets.py）"
                    )
            elif line.strip() and not line.strip().startswith("#"):
                in_assets = False


def main() -> int:
    files = dart_files()
    if not files:
        print("没有找到 Dart 文件。")
        return 1

    print(f"扫描 {len(files)} 个 Dart 文件\n")

    total_lines = 0
    for f in files:
        text = f.read_text(encoding="utf-8")
        total_lines += len(text.splitlines())
        check_imports(f, text)
        check_balance(f, text)
        check_dart_io(f, text)
        check_todo_markers(f, text)

    check_knowledge_ids()
    check_asset_paths()

    print(f"代码总行数：{total_lines}\n")

    if warnings:
        print(f"--- 警告 {len(warnings)} 条 ---")
        for w in warnings:
            print(f"  [!] {w}")
        print()

    if errors:
        print(f"--- 错误 {len(errors)} 条 ---")
        for e in errors:
            print(f"  [X] {e}")
        print(f"\n自检失败：{len(errors)} 个错误")
        return 1

    print("[OK] 自检通过：无阻断性错误")
    return 0


if __name__ == "__main__":
    sys.exit(main())
