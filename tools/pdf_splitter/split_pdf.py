"""扫描版考研数学 PDF 切题器 —— 混合制转换主体。

输出契约（docs/DATA_FORMAT.md v1.0）：
  <out>/<tag>/problems/<id>.md   一题一文件，frontmatter 带 images:
  <out>/<tag>/images/*.png       题图（zoom=3 高清裁切，ground truth）
  <out>/<tag>/cache/page_NNN.json  页级缓存（断点续跑：已有缓存直接跳过 OCR）

三种已探明的版式（2026-09-22 样页分析，analyze_layout.py）：
  worksheet  张宇1000：题号 `N.` 在左缘 x≈78，题目连续排布，无答题区。
  workbook   660做题本：题号是**裸数字**（红色块内），题干下方有 难度/答题区
             大框 —— 裁切必须在「难度」框上沿截断，否则 60% 是空白答题区。
  landscape  1800 Pad 版：横版 842x595，题号 `N.` 在左缘，每页题少、
             底部大片空白 —— 底界取本页最后内容行，不能取页底。

断点续跑与认领规则：按**页**认领（page_NNN.json 存在即视为完成），
重跑不重复花 OCR 的 3-4s/页。
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import time
from pathlib import Path

import pymupdf
from rapidocr_onnxruntime import RapidOCR

ANCHOR_FULL = re.compile(r"^(\d{1,4})[.、．]\s*$")          # `12.` 独立成行
ANCHOR_BARE = re.compile(r"^(\d{1,4})\s*$")                  # `497` 裸数字（做题本红块）
ANCHOR_WITH_TEXT = re.compile(r"^(\d{1,4})[.、．]\s*(\S.*)$")  # `5.设A为三阶矩阵…`（锚与题干同行）
MAX_QNUM = 2000

BOOK_DEFAULTS = {
    # tag: (源文件, 样式提示, 页码范围 0-based [start, end))
    "zy1000": ("D:/study/数学/考研数学/27张宇1000题数二-试题册【公众号：考研小舟】免费分享.pdf",
               "worksheet", (0, None)),
    "660xd": ("D:/study/数学/考研数学/《基础过关660》-线代篇.pdf", "workbook", (0, None)),
    "660gs": ("D:/study/数学/考研数学/《基础过关660》-高数篇 .pdf", "workbook", (0, None)),
    "1800xd": ("D:/study/数学/考研数学/【Pad版】26汤家凤《1800题》基础篇-线代（数二）.pdf",
               "landscape", (0, None)),
}


def ocr_page(ocr: RapidOCR, png: bytes, zoom: float):
    """返回 [(x0, y0, x1, y1, text, conf)]，坐标**除以 zoom** 回到 PDF pt。"""
    result, _ = ocr(png)
    lines = []
    if result:
        for box, text, conf in result:
            xs = [p[0] for p in box]
            ys = [p[1] for p in box]
            lines.append((min(xs) / zoom, min(ys) / zoom, max(xs) / zoom,
                          max(ys) / zoom, text.strip(), float(conf)))
    return lines


def find_anchors(lines: list, page_w: float, page_h: float, style: str):
    """题号锚点候选 -> 单调过滤后的 [(num, x0, y0, text, inline_rest)]。

    锚点三条件：短数字文本、位于左带（x0 < 24% 页宽）、置信度够。
    单调过滤：同页内题号必须递增（张宇每章重新编号，允许从 <=5 的小号重启）。
    """
    cands = []
    for x0, y0, x1, y1, text, conf in lines:
        if conf < 0.5 or y0 > page_h * 0.94:      # 页脚页码不算
            continue
        if x0 > page_w * 0.24:
            continue
        inline_rest = None
        m_full, m_bare, m_inline = ANCHOR_FULL.match(text), ANCHOR_BARE.match(text), ANCHOR_WITH_TEXT.match(text)
        if style == "workbook":
            m = m_bare
        elif style in ("worksheet", "landscape"):
            m = m_full or (m_inline if m_inline and len(m_inline.group(2)) > 4 else None)
            if m_inline and not m_full:
                inline_rest = m_inline.group(2)
        else:
            m = m_full or m_bare
        if not m:
            continue
        num = int(m.group(1))
        if not (0 < num <= MAX_QNUM):
            continue
        if (y1 - y0) > page_h * 0.06:             # 大标题不算
            continue
        cands.append((num, x0, y0, text, inline_rest, conf))

    cands.sort(key=lambda c: c[2])
    out: list = []
    last = 0
    for num, x0, y0, text, inline_rest, conf in cands:
        if num > last or (last > 20 and num <= 5):  # 递增；章重启
            out.append({"num": num, "x0": x0, "y": y0, "text": text, "inline": inline_rest})
            last = num
    return out


def content_band(lines: list, page_h: float):
    """正文行（剔除页眉 y<6% 与页脚 y>94%）。"""
    return [l for l in lines if page_h * 0.06 < l[1] < page_h * 0.94]


def split_page(lines: list, style: str, page_w: float, page_h: float):
    """一页 -> [(题号, crop_bbox, ocr_lines, inline_rest)]；可能带一个跨页续段。"""
    body = content_band(lines, page_h)
    anchors = find_anchors(lines, page_w, page_h, style)
    if not body:
        return [], None
    if not anchors:
        # 整页无锚点：全部正文都是上一页末题的延续
        return [], {"x0": min(l[0] for l in body) - 12, "y0": min(l[1] for l in body) - 4,
                    "x1": max(l[2] for l in body) + 12, "y1": max(l[3] for l in body) + 6,
                    "lines": body}

    regions = []
    # 页首延续段：第一个锚点上方有正文（>30pt）则切给上一题
    first_body_top = min(l[1] for l in body)
    cont = None
    if first_body_top < anchors[0]["y"] - 30:
        cont_lines = [l for l in body if l[3] < anchors[0]["y"] - 4]
        if cont_lines:
            cont = {"x0": min(l[0] for l in cont_lines) - 12, "y0": first_body_top - 4,
                    "x1": max(l[2] for l in cont_lines) + 12, "y1": anchors[0]["y"] - 6,
                    "lines": cont_lines}

    for i, a in enumerate(anchors):
        y_end = anchors[i + 1]["y"] - 4 if i + 1 < len(anchors) else None
        # 做题本：难度/答题区框是天然下界
        if style in ("workbook", "landscape", "worksheet"):
            for x0, y0, x1, y1, text, conf in body:
                if y0 > a["y"] + 8 and (y_end is None or y0 < y_end) and (
                        text.startswith("难度") or text.startswith("答题区")):
                    y_end = y0 - 2
                    break
        if y_end is None:
            in_reg = [l for l in body if l[1] > a["y"] - 2]
            y_end = (max(l[3] for l in in_reg) + 10) if in_reg else a["y"] + 60
        reg_lines = [l for l in body if a["y"] - 2 <= l[1] < y_end]
        regions.append((a, (a["x0"] - 16, a["y"] - 6, page_w - 20, y_end), reg_lines))
    return regions, cont


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", required=True, choices=list(BOOK_DEFAULTS))
    ap.add_argument("--out", default="D:/study/数学/考研数学/split_out")
    ap.add_argument("--start", type=int, default=None, help="0-based 起始页（调试用）")
    ap.add_argument("--end", type=int, default=None, help="0-based 结束页（不含）")
    args = ap.parse_args()

    pdf_path, style, (d_start, d_end) = BOOK_DEFAULTS[args.tag]
    start = args.start if args.start is not None else d_start
    end = args.end if args.end is not None else d_end

    root = Path(args.out) / args.tag
    img_dir, md_dir, cache = root / "images", root / "problems", root / "cache"
    for d in (img_dir, md_dir, cache):
        d.mkdir(parents=True, exist_ok=True)

    ocr = RapidOCR()
    doc = pymupdf.open(pdf_path)
    n_pages = len(doc)
    end = n_pages if end is None else min(end, n_pages)
    print(f"[{args.tag}] {pdf_path} 共{n_pages}页，处理 [{start},{end})，样式={style}")

    t0, pending_cont = time.time(), None   # pending_cont: (prev_qid, bbox, lines)
    stats = {"pages": 0, "questions": 0, "conts": 0, "ocr_s": 0.0}

    for pno in range(start, end):
        page_cache = cache / f"page_{pno:03d}.json"
        pg = doc[pno]
        W, H = pg.rect.width, pg.rect.height
        if page_cache.exists():
            data = json.loads(page_cache.read_text(encoding="utf-8"))
            lines = [tuple(l) for l in data["lines"]]
        else:
            tob = time.time()
            lines = ocr_page(ocr, pg.get_pixmap(matrix=pymupdf.Matrix(2, 2)).tobytes("png"), zoom=2.0)
            stats["ocr_s"] += time.time() - tob
            page_cache.write_text(json.dumps(
                {"lines": [list(l) for l in lines]}, ensure_ascii=False), encoding="utf-8")

        # 答案页剔除：660 做题本 PDF 的后半是「参考答案」。两个判据并用以防漏：
        # ① 页眉「参考答案」—— 只有奇数页有（奇偶页眉交替）；
        # ② 正文【答案】/【分析】/【评注】标记 —— 答案区每页都有，题目区没有。
        # 答案页的题号会被当成新锚点，把答案文本切成一堆假题 —— 命中即整页跳过。
        if any("参考答案" in l[4] or "【答案】" in l[4] or "【分析】" in l[4]
               or "【评注】" in l[4] for l in lines):
            pending_cont = None
            stats["pages"] += 1
            continue

        regions, cont = split_page(lines, style, W, H)

        # 先把上一页的延续段贴到本页第一题（或独立成图）
        if pending_cont:
            prev_qid, pbox, plines = pending_cont
            if regions:
                a0 = regions[0][0]
                qid = f"{args.tag}_p{pno:03d}_q{a0['num']:03d}"
                rb = regions[0][1]
                regions[0] = (a0, (rb[0], min(pbox[0], rb[1]), rb[2], rb[3]),
                              plines + regions[0][2])
            else:
                qid = prev_qid + "-cont"
                _save_crop(pg, pbox, img_dir / f"{qid}.png", W, H)
                stats["conts"] += 1
            _append_meta(root, prev_qid, qid, pno, plines)
            pending_cont = None

        for a, bbox, reg_lines in regions:
            # x 边界按区域内 OCR 行的实际范围取 —— 锚点固定偏移会把
            # 换行文本（比题号更靠左的段落边距）切掉半个字。
            if reg_lines:
                bbox = (max(4, min(l[0] for l in reg_lines) - 10), bbox[1],
                        min(W - 5, max(l[2] for l in reg_lines) + 14), bbox[3])
            qid = f"{args.tag}_p{pno:03d}_q{a['num']:03d}"
            _save_crop(pg, bbox, img_dir / f"{qid}.png", W, H)
            _write_md(root, args.tag, qid, a, bbox, reg_lines, pno, style)
            stats["questions"] += 1

        # 本页没有锚点但有内容 -> 延续段挂起（贴给下一页第一题）。
        # 防护：延续段只允许**单页** —— 连续两页无锚点说明进入了无题区
        # （目录/答案册），叠加会把几十页内容灌进一张图，直接丢弃。
        if cont and not regions:
            if pending_cont is None:
                pending_cont = (last_qid(root, args.tag, pno),
                                (cont["x0"], cont["y0"], cont["x1"], cont["y1"]),
                                cont["lines"])
            else:
                print(f"  p{pno+1}: 连续无锚点页，延续段丢弃", flush=True)
                pending_cont = None
        stats["pages"] += 1
        if stats["pages"] % 10 == 0:
            el = time.time() - t0
            print(f"  p{pno+1}/{end} 题{stats['questions']} 续{stats['conts']} "
                  f"OCR共{stats['ocr_s']:.0f}s 总{el:.0f}s", flush=True)

    (root / "stats.json").write_text(json.dumps(stats, ensure_ascii=False), encoding="utf-8")
    print(f"[{args.tag}] 完成：{stats}")
    doc.close()
    return 0


def _save_crop(pg, bbox, out: Path, W, H):
    """按 bbox 以 zoom=3 渲染裁切图（每题一次 clip 渲染，快且清晰）。"""
    x0, y0, x1, y1 = bbox
    clip = pymupdf.Rect(max(0, x0), max(0, y0), min(W - 1, x1), min(H - 1, y1))
    if clip.is_empty or clip.width < 30 or clip.height < 20:
        return
    pg.get_pixmap(matrix=pymupdf.Matrix(3, 3), clip=clip).save(str(out))


def last_qid(root: Path, tag: str, pno: int) -> str:
    ids = sorted(md_dir_glob(root))
    return ids[-1].stem if ids else f"{tag}_p{pno:03d}_q000"


def md_dir_glob(root: Path):
    return (root / "problems").glob("*.md")


def _append_meta(root: Path, prev_qid: str, cont_qid: str, pno: int, lines):
    (root / "index.jsonl").open("a", encoding="utf-8").write(
        json.dumps({"kind": "cont", "from": prev_qid, "cont_id": cont_qid,
                    "page": pno, "text": " ".join(l[4] for l in lines)},
                   ensure_ascii=False) + "\n")


def _write_md(root: Path, tag: str, qid: str, a, bbox, lines, pno, style):
    text = " ".join(l[4] for l in lines if l[4])
    qtype = "fill" if ("__" in text or "____" in text) else "solve"
    src = {"zy1000": "张宇《1000题》数二 试题册", "660xd": "《660题》线代篇（做题本）",
           "660gs": "《660题》高数篇（做题本）", "1800xd": "汤家凤《1800题》基础篇 线代（数二）"}[tag]
    md = f"""---
id: {qid}
subject: math2
qtype: {qtype}
difficulty: 2
source: {src} 第{pno + 1}页
source_type: textbook
images:
  - images/{qid}.png
tags: [{tag}, 图片题]
---

## 题干

**题干以配图为准**（印刷原题）；下方 OCR 文本仅供检索，公式可能失真。

{text}

"""
    (root / "problems" / f"{qid}.md").write_text(md, encoding="utf-8")


if __name__ == "__main__":
    sys.exit(main())
