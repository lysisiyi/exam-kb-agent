"""把 split_out/<tag>/ 的切题产物导入 App 题库（library/）。

## 事实源

`split_out` 是切题器的产物，重切后比库里旧文件更准（锚点规则修过两轮：
inline 阈值 + 前置页过滤）。所以本脚本做**覆盖式**导入：

- `problems/*.md`  -> `library/problems/`（同名覆盖）
- `images/*.png`    -> `library/images/`（同名覆盖）
- 跳过 `*-cont.png`：跨页延续图在 md 里没有引用（题目跨页时已用
  `_stitch` 拼进首题图），拷过去就是悬空文件
- 不动 library 里其他来源的文件（self-* 自创题）

覆盖是安全的：2026-10-07 核对过旧库所有 qid 都是新产物的**子集**
（孤儿 = 0），覆盖只更新图与文本，不产生重复。

用法：
    python tools/data/import_split_to_library.py            # 全量
    python tools/data/import_split_to_library.py --dry-run  # 只统计
    python tools/data/import_split_to_library.py --tag wzx
    python tools/data/import_split_to_library.py --prune    # 顺带删孤儿

`--prune`：删除库里属于本 tag 前缀、但新产物里已不存在的条目
（切题器修复后不再产出的假题，如封面页的 `660gs_p000_q1700`）。
默认**不删**——覆盖式导入是幂等常规操作，prune 只在版本升级后跑一次。
"""
from __future__ import annotations

import argparse
import os
import shutil
import sys
from pathlib import Path

TAGS = ["zy1000", "660xd", "660gs", "1800xd", "1800gd", "wzx"]

DEFAULT_SPLIT_OUT = Path("D:/study/数学/考研数学教材参考/split_out")
DEFAULT_LIBRARY = Path(os.environ.get("APPDATA", "")) / "com.kaoyan" / \
    "kaoyan_math_agent" / "library"


def import_tag(tag: str, split_out: Path, library: Path, dry_run: bool) -> dict:
    src = split_out / tag
    if not (src / "problems").exists():
        print(f"[{tag}] 未切分，跳过")
        return {}

    md_src, png_src = src / "problems", src / "images"
    md_dst, png_dst = library / "problems", library / "images"
    stat = {"new_md": 0, "over_md": 0, "new_png": 0, "over_png": 0, "cont_skip": 0}

    for f in sorted(md_src.glob("*.md")):
        dst = md_dst / f.name
        if dst.exists():
            stat["over_md"] += 1
        else:
            stat["new_md"] += 1
        if not dry_run:
            shutil.copy2(f, dst)

    for f in sorted(png_src.glob("*.png")):
        if f.stem.endswith("-cont"):
            stat["cont_skip"] += 1
            continue
        dst = png_dst / f.name
        if dst.exists():
            stat["over_png"] += 1
        else:
            stat["new_png"] += 1
        if not dry_run:
            shutil.copy2(f, dst)

    print(f"[{tag}] md 新增 {stat['new_md']} / 覆盖 {stat['over_md']} | "
          f"图 新增 {stat['new_png']} / 覆盖 {stat['over_png']} | "
          f"跳过 cont 图 {stat['cont_skip']}")
    return stat


def prune_tag(tag: str, split_out: Path, library: Path, dry_run: bool) -> int:
    """删除库里属于本 tag 前缀、但新产物已不含的 md 与 png（孤儿）。"""
    md_src, png_src = split_out / tag / "problems", split_out / tag / "images"
    new_md = {f.stem for f in md_src.glob("*.md")}
    new_png = {f.stem for f in png_src.glob("*.png")}
    removed = 0
    for f in (library / "problems").glob(f"{tag}_*.md"):
        if f.stem not in new_md:
            print(f"  [prune] 删 md {f.name}")
            if not dry_run:
                f.unlink()
            removed += 1
    for f in (library / "images").glob(f"{tag}_*.png"):
        if f.stem not in new_png:
            print(f"  [prune] 删图 {f.name}")
            if not dry_run:
                f.unlink()
            removed += 1
    return removed


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", choices=TAGS, action="append")
    ap.add_argument("--split-out", type=Path, default=DEFAULT_SPLIT_OUT)
    ap.add_argument("--library", type=Path, default=DEFAULT_LIBRARY)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--prune", action="store_true")
    args = ap.parse_args()

    if not args.library.exists():
        print(f"library 不存在：{args.library}", file=sys.stderr)
        return 1
    if not args.split_out.exists():
        print(f"split_out 不存在：{args.split_out}", file=sys.stderr)
        return 1

    totals: dict = {}
    pruned = 0
    for tag in (args.tag or TAGS):
        stat = import_tag(tag, args.split_out, args.library, args.dry_run)
        for k, v in stat.items():
            totals[k] = totals.get(k, 0) + v
        if args.prune and stat:
            pruned += prune_tag(tag, args.split_out, args.library, args.dry_run)

    mode = "（dry-run，未写入）" if args.dry_run else ""
    if args.prune:
        print(f"prune 删除 {pruned} 个孤儿条目 {mode}")
    print(f"合计：md +{totals.get('new_md', 0)} 新 / {totals.get('over_md', 0)} 覆盖，"
          f"图 +{totals.get('new_png', 0)} 新 / {totals.get('over_png', 0)} 覆盖 {mode}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
