# -*- coding: utf-8 -*-
"""从生成的桌宠候选图里裁出选定角色，做成透明底参考图。

输入: C:/Users/yifuc/.codex/generated_images/01a10a8b-a883-74e1-8b92-8ec9e0021d0b/
输出: docs/design/pet/
  - pet_xiaoyan_reference.png   选定角色(暖棕发抱书), 透明底, 原始分辨率
  - candidates_sheet_1.png      候选总表(4人版), 缩到宽1200
  - candidates_sheet_2.png      候选总表(6人版), 缩到宽1200
"""
from pathlib import Path
from collections import deque
from PIL import Image

SRC = Path("C:/Users/yifuc/.codex/generated_images/01a10a8b-a883-74e1-8b92-8ec9e0021d0b")
DST = Path("docs/design/pet")
DST.mkdir(parents=True, exist_ok=True)

SHEET1 = SRC / "exec-08ff983d-c542-4198-ad4d-d2eb424445c7.png"  # 4人一排
SHEET2 = SRC / "exec-830b93fa-393b-4274-aca2-7e0cf6ea80b2.png"  # 6人版(清晰)


def near_black(px):
    r, g, b = px[:3]
    return r < 36 and g < 36 and b < 36


def strip_edge_black(img):
    """清黑底分两步：
    1) 从四边洪泛清除与边缘连通的近黑背景；
    2) 全图再清一遍所有近纯黑像素——发丝缝隙里封闭的残留底色没和边缘
       连通，第 1 步碰不到；而这套立绘的线稿是深棕色(非纯黑)，
       纯黑像素只可能是背景，清掉后在浅色 UI 上才不会出现黑斑。"""
    w, h = img.size
    px = img.load()
    seen = bytearray(w * h)
    q = deque()
    for x in range(w):
        for y in (0, h - 1):
            if near_black(px[x, y]) and not seen[y * w + x]:
                seen[y * w + x] = 1
                q.append((x, y))
    for y in range(h):
        for x in (0, w - 1):
            if near_black(px[x, y]) and not seen[y * w + x]:
                seen[y * w + x] = 1
                q.append((x, y))
    while q:
        x, y = q.popleft()
        px[x, y] = (0, 0, 0, 0)
        for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if 0 <= nx < w and 0 <= ny < h and not seen[ny * w + nx]:
                if near_black(px[nx, ny]):
                    seen[ny * w + nx] = 1
                    q.append((nx, ny))
    cleared = 0
    for y in range(h):
        for x in range(w):
            p = px[x, y]
            if p[3] != 0 and near_black(p):
                px[x, y] = (0, 0, 0, 0)
                cleared += 1
    print(f"第二步清除封闭残留黑底像素 {cleared} 个")


def content_segments(img, min_gap=8, min_width=40):
    """按列不透明度把一行角色切成若干段，返回每段 (x0, x1)。"""
    w, h = img.size
    px = img.load()
    cols = []
    for x in range(w):
        filled = 0
        for y in range(0, h, 4):
            if px[x, y][3] > 24:
                filled += 1
        cols.append(filled)
    segs, start, gap = [], None, 0
    for x, c in enumerate(cols):
        if c > 0:
            if start is None:
                start = x
            gap = 0
        elif start is not None:
            gap += 1
            if gap >= min_gap:
                if x - gap - start + 1 >= min_width:
                    segs.append((start, x - gap + 1))
                start, gap = None, 0
    if start is not None and w - start >= min_width:
        segs.append((start, w))
    return segs


def main():
    sheet1 = Image.open(SHEET1).convert("RGBA")
    w, h = sheet1.size
    segs = content_segments(sheet1)
    print(f"sheet1 {w}x{h}, 检出 {len(segs)} 个角色段: {segs}")
    if not segs:
        raise SystemExit("一个角色段都没检出，人工确认图片后再跑")
    # 前几只可能因像素粘连并成一段；最右一只独立成段即为目标。
    # 若末段宽度异常(超过全图 40%)说明粘连波及到了它，才需要人工介入。
    x0, x1 = segs[-1]
    if x1 - x0 > w * 0.4:
        raise SystemExit(f"末段宽 {x1 - x0} 可疑(可能是粘连)，人工确认后重跑")
    crop = sheet1.crop((max(0, x0 - 6), 0, min(w, x1 + 6), h))
    strip_edge_black(crop)

    # 收紧到实际内容的包围盒
    bbox = crop.getbbox()
    crop = crop.crop(bbox)
    out_ref = DST / "pet_xiaoyan_reference.png"
    crop.save(out_ref)
    print(f"选定角色 -> {out_ref} {crop.size}")

    # 两张候选总表缩档留档
    for src, name in ((SHEET1, "candidates_sheet_1.png"), (SHEET2, "candidates_sheet_2.png")):
        im = Image.open(src).convert("RGB")
        scale = 1200 / im.width
        im = im.resize((1200, round(im.height * scale)), Image.LANCZOS)
        im.save(DST / name, optimize=True)
        print(f"留档 -> {DST / name}")


if __name__ == "__main__":
    main()
