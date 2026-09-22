#!/usr/bin/env python3
"""给"图为主"的存量题目补打 `images_primary: true` 标记。

## 背景

混合制导入（split_pdf.py）早期产出的 md 只有 `images:`，没有
`images_primary:`。App 端后来加了"图为主显示"逻辑：只有带该标记的题
才把配图当题目本体渲染（OCR 文本收进折叠区）；不带标记的题维持
"文字为主、配图为辅"的旧行为——这是刻意设计，避免误伤手工录题的示意图。

本脚本把**已经带 `images:` frontmatter** 的存量题统一补上标记。
判定依据就是"有配图"：目前库里有配图的题全部来自切题器，手工录题
暂不支持贴图，因此不会误伤。

## 用法

    python mark_image_primary.py <library>/problems [--apply]

默认 dry-run（只统计不写盘）；`--apply` 才真正写入。
写入用 tmp + os.replace 原子替换；已带标记的文件跳过（幂等，可重复跑）。
"""

import os
import sys
from pathlib import Path


def process_file(path: Path) -> bool:
    """返回 True 表示需要补标记（dry-run 下不写盘）。"""
    text = path.read_text(encoding="utf-8")
    lines = text.split("\n")

    # 定位 frontmatter：必须以 --- 开头（与 App 端解析器同规则）
    if not lines or lines[0].strip() != "---":
        return False
    try:
        close = next(i for i in range(1, len(lines)) if lines[i].strip() == "---")
    except StopIteration:
        return False

    yaml_lines = lines[1:close]
    has_images = any(ln.strip() == "images:" or ln.strip().startswith("images:")
                     for ln in yaml_lines)
    if not has_images:
        return False
    if any("images_primary" in ln for ln in yaml_lines):
        return False  # 已打标，幂等跳过

    if "--apply" in sys.argv:
        # 插在 frontmatter 末尾（关闭 --- 之前），YAML 键序无关
        new_lines = lines[:close] + ["images_primary: true"] + lines[close:]
        tmp = path.with_suffix(".md.tmp")
        tmp.write_text("\n".join(new_lines), encoding="utf-8")
        os.replace(tmp, path)
    return True


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    root = Path(sys.argv[1])
    if not root.is_dir():
        print(f"目录不存在：{root}")
        return 2

    files = sorted(root.glob("*.md"))
    hit = skipped = 0
    for f in files:
        try:
            if process_file(f):
                hit += 1
            else:
                skipped += 1
        except Exception as e:  # 单文件失败不中断
            print(f"  [失败] {f.name}: {e}")

    mode = "已写入" if "--apply" in sys.argv else "dry-run（未写盘，加 --apply 生效）"
    print(f"共 {len(files)} 个 md：补标 {hit}，跳过 {skipped} —— {mode}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
