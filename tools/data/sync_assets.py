#!/usr/bin/env python3
"""把知识资产从 `data/` 同步到 `app/assets/data/`。

## 为什么需要这一步
Flutter **不允许** `pubspec.yaml` 的 `assets:` 引用应用目录之外的路径。
而 `data/` 是仓库级的知识资产（知识点本体、错因词表、考频数据、组卷模板），
被 Python 工具链和 Flutter 应用共同消费。

因此采用「单一事实源 + 构建前同步」：
- **事实源**：`data/`（仓库根目录）
- **消费副本**：`app/assets/data/`（构建产物，可随时删除重建）

## 用法
    python tools/data/sync_assets.py            # 同步
    python tools/data/sync_assets.py --check    # 只检查是否已同步（CI 用）
"""

from __future__ import annotations

import argparse
import filecmp
import re
import shutil
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "data"
DST = ROOT / "app" / "assets" / "data"

# 需要同步的内容（相对 data/ 的路径）
INCLUDE = [
    "knowledge_points",
    "error_causes.json",
    "exam_frequency.json",
    "exam_templates.json",
    "tag_whitelist.json",
]

# 只给工具链用、App 不需要的文件。
#
# 1. `alias_overrides.json` 是**别名的源数据**：内容已在构建期被
#    `gen_aliases.py` 合并进 `math*.json` 的 `aliases` 字段。
# 2. `math{1,2,3}_*.json` 是 AI 分片（`math1_calc` / `math1_rest` …），
#    只是 `merge_shards.py` 的**输入**；App 只读权威文件 `math{1,2,3}.json`。
#
# 两者都不该进 assets：白占约 480 KB 包体，还会制造"改哪个才生效"的困惑。
# 实测踩到过：打包产物里连 `math1_rest.json.bak` 都被打进去了。
EXCLUDE_NAMES = {"alias_overrides.json"}
EXCLUDE_SUFFIXES = (".merged", ".bak", ".partial", ".tmp")


def _should_skip(name: str) -> bool:
    """是否是"只给工具链用"的文件（不进 assets）。"""
    if name in EXCLUDE_NAMES:
        return True
    if name.endswith(EXCLUDE_SUFFIXES):
        return True
    # AI 分片：`math1_calc.json` 这类
    return bool(re.fullmatch(r"math[123]_.+\.json", name))


def _rel(p: Path) -> str:
    return str(p.relative_to(SRC)).replace("\\", "/")


def collect() -> list[tuple[Path, Path]]:
    """返回 [(源文件, 目标文件)]。"""
    pairs: list[tuple[Path, Path]] = []
    for item in INCLUDE:
        src = SRC / item
        if not src.exists():
            continue
        if src.is_dir():
            for f in sorted(src.rglob("*")):
                if f.is_file() and not _should_skip(f.name):
                    pairs.append((f, DST / _rel(f)))
        else:
            pairs.append((src, DST / item))
    return pairs


def main() -> int:
    ap = argparse.ArgumentParser(description="同步知识资产到 Flutter assets")
    ap.add_argument("--check", action="store_true", help="只检查，不写入")
    ap.add_argument("--clean", action="store_true", help="先清空目标目录")
    args = ap.parse_args()

    if not SRC.exists():
        print(f"错误：找不到源目录 {SRC}")
        return 1

    pairs = collect()
    if not pairs:
        print("没有找到任何需要同步的文件。检查 data/ 目录。")
        return 1

    if args.clean and DST.exists() and not args.check:
        shutil.rmtree(DST)
        print(f"已清空 {DST.relative_to(ROOT)}")

    copied, same, stale = 0, 0, []

    if not args.check:
        DST.mkdir(parents=True, exist_ok=True)

    for src, dst in pairs:
        if dst.exists() and filecmp.cmp(src, dst, shallow=False):
            same += 1
            continue
        if args.check:
            stale.append(_rel(src))
            continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        copied += 1
        print(f"  -> {_rel(src)}")

    print()
    print(f"源文件 {len(pairs)} 个：更新 {copied} / 已一致 {same}"
          + (f" / 待更新 {len(stale)}" if args.check else ""))

    if args.check and stale:
        print("\n以下文件与源不一致，请运行 `python tools/data/sync_assets.py`：")
        for s in stale:
            print(f"  - {s}")
        return 1

    if not args.check:
        print(f"\n[OK] 已同步到 {DST.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
