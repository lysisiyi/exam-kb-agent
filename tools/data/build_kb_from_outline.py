# -*- coding: utf-8 -*-
"""按课程大纲生成一个知识库（Obsidian 式 md 树）。

## 起因

「根据不同的课程内容构建不同的知识库」——先有课程大纲（网上找的/教材目录/
自己整理），再一键长成一棵可编辑、可拖拽、可挂题挂笔记的知识树。

## 输入（大纲文件）

```
# 课程名（首行 H1 = 知识库标题）
- 第一章 函数、极限、连续
  - 第一节 函数
    - 函数的概念及常见函数
```
每级缩进 2 空格。**有子项 = 分支（文件夹+自带 md），无子项 = 叶子**。

## 输出（与 App 的 K1 importTree 完全同构）

```
<目标 knowledge/>/<slug>/
  _subject.md
  01-第一章 函数、极限、连续/
    01-第一章 函数、极限、连续.md
    01-第一节 函数/
      01-第一节 函数.md
      01-函数的概念及常见函数.md
```

## 用法

  python tools/data/build_kb_from_outline.py \
      data/knowledge_points/course_outlines/wu-zhongxiang-gaoshu-base.md \
      --slug wzx-gaoshu-base \
      --id-prefix wzxgs \
      --target "%APPDATA%/com.kaoyan/kaoyan_math_agent/library/knowledge"

不带 --target 时写入仓库内 `build/kb_outlines/<slug>/`（供检查与入库前审阅）。
"""
import argparse
import re
import sys
from pathlib import Path

SAFE = re.compile(r'[\\/:*?"<>|]')


def parse_outline(path: Path):
    title = None
    roots = []
    stack = []  # [(level, node)] level 从 0 起
    for raw in path.read_text(encoding="utf-8").splitlines():
        if not raw.strip():
            continue
        if raw.startswith("# "):
            title = raw[2:].strip()
            continue
        m = re.match(r"^(\s*)-\s+(.*)$", raw)
        if not m:
            continue
        level = len(m.group(1)) // 2
        node = {"name": m.group(2).strip(), "children": []}
        while stack and stack[-1][0] >= level:
            stack.pop()
        if stack:
            stack[-1][1]["children"].append(node)
        else:
            roots.append(node)
        stack.append((level, node))
    return title, roots


def normalize(node: dict) -> None:
    """自动补节：一章的子项若**全是叶子**，包一层同名节。

    原因：App 用 **id 段数**判层级（`idDepth==3` 视为章节级）。章下直接挂
    叶子会让这些叶子停在"章节级"，编号/缩进/章节统计全都错位 —— 与 math1
    种子"章 → 节 → 知识点"的三层一致，这里补出中间层。
    """
    kids = node["children"]
    if kids and all(not k["children"] for k in kids):
        # "第二章 导数与微分" → 节名取去掉"第X章 "前缀的部分
        sec_name = re.sub(r"^第[一二三四五六七八九十]+[章节]\s*", "", node["name"])
        node["children"] = [{"name": sec_name, "children": kids}]
        # ⚠️ 必须 return：刚包出的节"子项全是叶子"，再递归会把它
        # 自己当成待包的章 —— 无限自噬（第一版就死在这，RecursionError）。
        return
    for k in node["children"]:
        normalize(k)


def write_node(parent_dir: Path, node: dict, seq: int, node_id: str,
               parent_id: str, depth: int) -> tuple[int, int]:
    """返回（写出的文件数, 叶子数）。"""
    name = node["name"]
    safe = SAFE.sub("_", name)
    is_leaf = not node["children"]
    files = 0
    leaves = 0

    if is_leaf:
        f = parent_dir / f"{seq:02d}-{safe}.md"
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(
            frontmatter(node_id, name, depth, True, parent_id) +
            f"\n# {name}\n",
            encoding="utf-8")
        return 1, 1

    d = parent_dir / f"{seq:02d}-{safe}"
    d.mkdir(parents=True, exist_ok=True)
    (d / f"{seq:02d}-{safe}.md").write_text(
        frontmatter(node_id, name, depth, False, parent_id) +
        f"\n# {name}\n",
        encoding="utf-8")
    files += 1
    for i, child in enumerate(node["children"], start=1):
        cf, cl = write_node(d, child, i, f"{node_id}.{i}", node_id, depth + 1)
        files += cf
        leaves += cl
    return files, leaves


def frontmatter(node_id: str, name: str, depth: int, is_leaf: bool,
                parent_id: str) -> str:
    lines = [
        "---",
        f"id: {node_id}",
        f"name: {name}",
        # ⚠️ parent_id 必须写：App 的树/大纲/拖拽全走 childrenOf(parent_id)，
        # 漏了它整棵树在界面上是平的（"0 孤儿"的校验也会空判通过）
        f"parent_id: {parent_id}",
        f"level: {depth}",
        f"is_leaf: {str(is_leaf).lower()}",
        "status: skeleton",       # 骨架：等用户逐节填内容
        "source: outline",        # 来源=课程大纲（区别于 seed JSON / user / ai）
        "---",
    ]
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("outline", type=Path)
    ap.add_argument("--slug", required=True, help="知识库目录名（= subject id）")
    ap.add_argument("--id-prefix", required=True, help="节点 id 前缀，如 wzxgs")
    ap.add_argument("--target", type=Path, default=None,
                    help="knowledge 目录；缺省写 build/kb_outlines/")
    args = ap.parse_args()

    title, roots = parse_outline(args.outline)
    for r in roots:
        normalize(r)
    if not title or not roots:
        print("大纲解析为空：首行需 '# 课程名'，条目用 '- '，子级缩进 2 空格",
              file=sys.stderr)
        return 1

    root = args.target or (Path("build") / "kb_outlines")
    kb_dir = root / args.slug
    if kb_dir.exists():
        print(f"目标已存在，先删除再生成：{kb_dir}", file=sys.stderr)
        return 1
    kb_dir.mkdir(parents=True)

    (kb_dir / "_subject.md").write_text(
        "\n".join([
            "---",
            f"id: {args.slug}",
            f"subject: {args.slug}",
            f"subject_name: {title}",
            "version: 0.1.0+outline",
            "level: 1",
            "is_leaf: false",
            "---",
            "",
            f"# {title}",
        ]) + "\n", encoding="utf-8")

    files, leaves = 1, 0
    for i, node in enumerate(roots, start=1):
        f, l = write_node(kb_dir, node, i, f"{args.id_prefix}.{i}",
                          args.slug, 2)
        files += f
        leaves += l

    print(f"[OK] {kb_dir}")
    print(f"     共 {files} 个文件（{len(roots)} 章 / {leaves} 个知识点叶）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
