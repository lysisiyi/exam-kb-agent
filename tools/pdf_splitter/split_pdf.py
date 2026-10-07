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
from PIL import Image
from rapidocr_onnxruntime import RapidOCR

ANCHOR_FULL = re.compile(r"^(\d{1,4})[.、．]\s*$")          # `12.` 独立成行
ANCHOR_BARE = re.compile(r"^(\d{1,4})\s*$")                  # `497` 裸数字（做题本红块）
ANCHOR_WITH_TEXT = re.compile(r"^(\d{1,4})[.、．]\s*(\S.*)$")  # `5.设A为三阶矩阵…`（锚与题干同行）
# 武忠祥做题本：`【P7例2】以下四个命题…`（讲义页码 + 例题号，含空格容错）
WZX_ANCHOR = re.compile(r"^[【\[]\s*P\s*(\d{1,4})\s*例\s*(\d{1,4})\s*[】\]]")
MAX_QNUM = 2000


def _inline_rest_ok(rest: str) -> bool:
    """`N.` 与题干同行时，判定后面那段文本是不是题干。

    ## 为什么只看首字符，不看长度

    这里曾经是 `len(rest) > 4` —— 它的本意是挡掉 `3.5`、`2.8倍` 这类
    OCR 把小数读成「序号 3 + 内容 5」的假锚点。但这个阈值同时挡掉了
    **大量真题干**：`7.求lim`（rest=`求lim`，4 字符）、`15.曲线`（2 字符）、
    `14.设A =`（4 字符）全都不 `> 4` —— 这些页于是被判「无锚点」，
    整页内容被当成上一题的延续（或直接丢弃）。

    2026-10-07 实测量化：1800gd 86 页只切出 38 题、另 46 个真题干被拒；
    zy1000 808 题另有 75 个被拒；1800xd 156 题另有 33 个被拒 ——
    这正是「题库很多题缺失」的直接原因。

    假锚点的真实特征是**首字符是数字**（小数/编号），而不是短。
    """
    rest = rest.strip()
    return bool(rest) and not rest[0].isdigit()


def find_anchors_wzx(lines: list, page_w: float, page_h: float):
    """武忠祥讲义做题本的锚点：`【P7例2】` 行。

    不做单调过滤 —— 题号是「讲义页码 P + 例号」的复合体，例号跨章会重启，
    `P` 页码也非本题册页码。每个匹配到的标记就是一道新例题。
    例题号只用于 qid 命名（同页不会重复），引用页码存进 `p_ref`。
    """
    out = []
    for x0, y0, x1, y1, text, conf in lines:
        if conf < 0.5 or y0 > page_h * 0.94:
            continue
        m = WZX_ANCHOR.match(text)
        if not m:
            continue
        p_ref, ex_num = int(m.group(1)), int(m.group(2))
        if not (0 < ex_num <= MAX_QNUM):
            continue
        rest = text[m.end():].strip()
        out.append({"num": ex_num, "x0": x0, "y": y0, "text": text,
                    "inline": rest or None, "p_ref": p_ref})
    return out


_TOC_LINE = re.compile(r"第[一二三四五六七八九十百0-9]{1,4}\s*[章节]")
# ⚠️ 不要放进页脚水印词（关注公众号/免费考研/免费分享/无水印）—— 它们在
# 正文页的页脚也出现，会把正文页误判成前置页。这里只保留版权/目录实词。
_FRONT_MARK = re.compile(
    r"目录|版权|图书在版编目|CIP|出版社|出版发行|ISBN|主编|副主编")


def _is_front_matter(lines: list, pno: int) -> bool:
    """封面 / 版权 / 目录 / 前言页：整页跳过（不产题、不挂延续段）。

    这些页都在书的最前面且带明显的关键词。此前它们会被当成「上一题的
    延续」挂给下一页首题 —— 题图从页顶切开、题目文本里混进整页目录/版权
    文字（1800xd 第 1 题、zy1000 第 1 题都被这样污染过）；封面的裸数字
    还会被 workbook 规则当成题号产假题（660gs_p000_q1700）。

    ⚠️ pno == 0（第 1 页）无条件视为前置页；**不要**扩大到 pno < 2 ——
    wzx 的第 2 页（pno=1）就是正文首页（例 1/2/3 在那里），曾因此丢 8 题。
    """
    if pno == 0:
        return True
    if pno >= 6:
        return False
    text = " ".join(l[4] for l in lines)
    if _FRONT_MARK.search(text):
        return True
    # 章节标题要**成片**才算目录 —— 正文页正文里也有「第一章」「第一节函数」
    # 这类标题（wzx 第 2 页就是），单次命中会把整页误杀。
    return sum(1 for l in lines if _TOC_LINE.search(l[4])) >= 3


def _render_clip(doc, pno: int, box, W, H):
    """按 PDF-pt bbox 渲染单页区域（zoom=3）为 PIL 图。"""
    x0, y0, x1, y1 = box
    clip = pymupdf.Rect(max(0, x0), max(0, y0), min(W - 1, x1), min(H - 1, y1))
    if clip.is_empty or clip.width < 30 or clip.height < 20:
        return None
    pix = doc[pno].get_pixmap(matrix=pymupdf.Matrix(3, 3), clip=clip)
    return Image.frombytes("RGB", (pix.width, pix.height), pix.samples)


def _stitch(doc, prev_pno: int, pbox, pno: int, cbox, out, W, H) -> bool:
    """跨页题：上一页延续段 + 当前页首题，纵向拼成一张图。

    题目跨页时，前半在上一页的图里并不存在 —— 早先的实现只把文本并进
    md、像素直接丢弃（`min(pbox[0], rb[1])` 那个 bbox 合成是坐标混用，
    并不会把上一页的像素带过来）。这里真正把两段图拼起来，
    中间加一条 24px 分隔线。
    """
    p_img = _render_clip(doc, prev_pno, pbox, W, H)
    c_img = _render_clip(doc, pno, cbox, W, H)
    if p_img is None or c_img is None:
        return False
    w = max(p_img.width, c_img.width)
    gap = 24
    canvas = Image.new("RGB", (w, p_img.height + gap + c_img.height), "white")
    canvas.paste(p_img, (0, 0))
    canvas.paste(c_img, (0, p_img.height + gap))
    canvas.save(str(out))
    return True

# PDF 目录：旧路径 D:/study/数学/考研数学/ 已不存在（2026-10-05 全量
# 迁移到「考研数学教材参考」），这里跟着迁。⚠️「660 高数」文件名 `.pdf`
# 前有一个空格，是真实文件名，别"顺手"去掉。
_PDF_DIR = "D:/study/数学/考研数学教材参考"

BOOK_DEFAULTS = {
    # tag: (源文件, 样式提示, 页码范围 0-based [start, end))
    "zy1000": (f"{_PDF_DIR}/27张宇1000题数二-试题册【公众号：考研小舟】免费分享.pdf",
               "worksheet", (0, None)),
    "660xd": (f"{_PDF_DIR}/《基础过关660》-线代篇.pdf", "workbook", (0, None)),
    "660gs": (f"{_PDF_DIR}/《基础过关660》-高数篇 .pdf", "workbook", (0, None)),
    "1800xd": (f"{_PDF_DIR}/【Pad版】26汤家凤《1800题》基础篇-线代（数二）.pdf",
               "landscape", (0, None)),
    # 2026-10-05 新增：这两本此前从未切过（题库缺题的主因）
    "1800gd": (f"{_PDF_DIR}/【Ipad版】26《汤家凤1800题》基础篇-高数（数二）【公众号：考研小舟】.pdf",
               "landscape", (0, None)),
    "wzx": (f"{_PDF_DIR}/【A4紧凑】27武忠祥强化辅导讲义做题本.pdf",
            "wzx", (0, None)),
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
    if style == "wzx":
        out = find_anchors_wzx(lines, page_w, page_h)
        if out:
            return out
        # 书末「附 26 真题」部分没有【P*例*】标记，用标准 worksheet 锚点
        # （普通题号 `1.设x→0时…` / `19.(本题满分12分)`）。此前这段被
        # wzx 专用规则整个漏掉 —— 判据按**页**分流，两种版式共存。
        style = "worksheet"
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
            m = m_full or (m_inline if m_inline and _inline_rest_ok(m_inline.group(2)) else None)
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
        # y_end：下一个**真正更靠下**的锚点。wzx 讲义是双栏排版，同一水平线
        # 左右各有一道题（y 相同），直接取下一个锚点会算出负高度 region
        # （产出空条目：wzx 曾有 9 个 md 没图也没文本）。
        y_end = None
        for b in anchors[i + 1:]:
            if b["y"] > a["y"] + 8:
                y_end = b["y"] - 4
                break
        # wzx 双栏：本栏图右界收在同高右邻锚点左侧，避免把隔壁栏切进来
        x1_lim = page_w - 20
        if style == "wzx":
            for b in anchors:
                if abs(b["y"] - a["y"]) <= 8 and b["x0"] > a["x0"]:
                    x1_lim = min(x1_lim, b["x0"] - 8)
                    break
        # 做题本：难度/答题区框是天然下界
        if style in ("workbook", "landscape", "worksheet", "wzx"):
            for x0, y0, x1, y1, text, conf in body:
                if y0 > a["y"] + 8 and (y_end is None or y0 < y_end) and (
                        text.startswith("难度") or text.startswith("答题区")):
                    y_end = y0 - 2
                    break
        if y_end is None:
            in_reg = [l for l in body if l[1] > a["y"] - 2]
            y_end = (max(l[3] for l in in_reg) + 10) if in_reg else a["y"] + 60
        x0_lim = a["x0"] - 16
        reg_lines = [l for l in body
                     if a["y"] - 2 <= l[1] < y_end
                     and l[0] >= x0_lim - 2
                     and (style != "wzx" or l[2] <= x1_lim + 40)]
        regions.append((a, (x0_lim, a["y"] - 6, x1_lim, y_end), reg_lines))
    return regions, cont


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", required=True, choices=list(BOOK_DEFAULTS))
    ap.add_argument("--out", default="D:/study/数学/考研数学教材参考/split_out")
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

    t0, pending_cont = time.time(), None   # pending_cont: (prev_qid, prev_pno, bbox, lines)
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

        # 前置页（封面/版权/目录）：整页跳过 —— 不产题也不挂延续段。
        # 封面上的「1700」这类裸数字曾被子工作本规则当成题号产出假题
        # （660gs_p000_q1700），目录页内容也曾污染下一页首题（1800xd 第 1 题）。
        if _is_front_matter(lines, pno):
            pending_cont = None
            stats["pages"] += 1
            continue

        regions, cont = split_page(lines, style, W, H)

        # 先把上一页的延续段拼到本页第一题（或独立成图）
        stitched_first = False
        if pending_cont:
            prev_qid, prev_pno, pbox, plines = pending_cont
            if regions:
                a0 = regions[0][0]
                qid_num0 = 1 if style == "wzx" else a0["num"]
                qid = f"{args.tag}_p{pno:03d}_q{qid_num0:03d}"
                rb = regions[0][1]
                regions[0] = (a0, rb, plines + regions[0][2])
                stitched_first = _stitch(doc, prev_pno, pbox, pno, rb,
                                         img_dir / f"{qid}.png", W, H)
            else:
                qid = prev_qid + "-cont"
                _save_crop(doc[prev_pno], pbox, img_dir / f"{qid}.png", W, H)
                stats["conts"] += 1
            _append_meta(root, prev_qid, qid, pno, plines)
            pending_cont = None

        for idx, (a, bbox, reg_lines) in enumerate(regions):
            # x 边界按区域内 OCR 行的实际范围取 —— 锚点固定偏移会把
            # 换行文本（比题号更靠左的段落边距）切掉半个字。
            if reg_lines:
                bbox = (max(4, min(l[0] for l in reg_lines) - 10), bbox[1],
                        min(W - 5, max(l[2] for l in reg_lines) + 14), bbox[3])
            # wzx 的 qid 用「页内锚点序号」：例号在题型内会重启（同页可能
            # 有两个「例 1」），用例号当 qid 会互相覆盖（曾 297 题只落 264 个文件）。
            qid_num = (idx + 1) if style == "wzx" else a["num"]
            qid = f"{args.tag}_p{pno:03d}_q{qid_num:03d}"
            if idx == 0 and stitched_first:
                pass                                   # 图已由 _stitch 写盘
            elif bbox[3] - bbox[1] < 20 or bbox[2] - bbox[0] < 30:
                # 区域太小：孤立数字/广告页上的假锚点，不是题
                # （660gs 书末广告页的「150」曾产出一个空条目）
                continue
            else:
                _save_crop(pg, bbox, img_dir / f"{qid}.png", W, H)
            _write_md(root, args.tag, qid, a, bbox, reg_lines, pno, style)
            stats["questions"] += 1

        # 本页没有锚点但有内容 -> 延续段挂起（贴给下一页第一题）。
        # 防护：延续段只允许**单页** —— 连续两页无锚点说明进入了无题区
        # （目录/答案册），叠加会把几十页内容灌进一张图，直接丢弃。
        if cont and not regions:
            if pending_cont is None:
                pending_cont = (last_qid(root, args.tag, pno), pno,
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
           "660gs": "《660题》高数篇（做题本）", "1800xd": "汤家凤《1800题》基础篇 线代（数二）",
           "1800gd": "汤家凤《1800题》基础篇 高数（数二）",
           "wzx": "武忠祥《强化辅导讲义》做题本"}[tag]
    # wzx 的 qid 是页内序号，例号要写进 source 才不丢（复习时能对上讲义）
    if tag == "wzx" and a.get("p_ref"):
        src = f"{src} P{a['p_ref']}例{a['num']}（第{pno + 1}页）"
    else:
        src = f"{src} 第{pno + 1}页"
    md = f"""---
id: {qid}
subject: math2
qtype: {qtype}
difficulty: 2
source: {src}
source_type: textbook
images_primary: true
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
