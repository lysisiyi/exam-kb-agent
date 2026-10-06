# -*- coding: utf-8 -*-
"""把服务商桌宠总表裁成按服务商命名的透明底参考图。

输入（作者生成，位于仓库外）:
  D:/agent/workspaces/ai-desktop-pet-designs/global-ai-pets.png  1×4: ChatGPT/Gemini/Grok/Claude
  D:/agent/workspaces/ai-desktop-pet-designs/china-ai-pets.png   3×2: DeepSeek/通义/Kimi + 豆包/智谱/MiniMax
输出:
  docs/design/pet/providers/<id>.png   10 张透明底单图（Rive 换皮基准）
  docs/design/pet/sheets/*.png         两张总表缩档留源
"""
from pathlib import Path
from collections import deque
from PIL import Image

SRC_DIR = Path("D:/agent/workspaces/ai-desktop-pet-designs")
DST = Path("docs/design/pet/providers")
SHEETS = Path("docs/design/pet/sheets")

GLOBAL = (SRC_DIR / "global-ai-pets.png",
          [[("chatgpt", "ChatGPT"), ("gemini", "Gemini"),
            ("grok", "Grok"), ("claude", "Claude")]])
CHINA = (SRC_DIR / "china-ai-pets.png",
         [[("deepseek", "DeepSeek"), ("qwen", "通义千问"), ("kimi", "Kimi")],
          [("doubao", "豆包"), ("zhipu", "智谱 GLM"), ("minimax", "MiniMax")]])


def near_black(px):
    r, g, b = px[:3]
    return r < 36 and g < 36 and b < 36


def strip_black(img):
    """两步去黑底：先洪泛清与边缘连通的，再清全图残留的封闭纯黑。
    （同 make_pet_assets.py，线稿是深棕/深蓝非纯黑，清纯黑不伤画。）"""
    w, h = img.size
    px = img.load()
    seen = bytearray(w * h)
    q = deque()
    for x in range(w):
        for y in (0, h - 1):
            if near_black(px[x, y]):
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
    for y in range(h):
        for x in range(w):
            p = px[x, y]
            if p[3] != 0 and near_black(p):
                px[x, y] = (0, 0, 0, 0)


def bands(img, axis, expect, min_gap, min_count):
    """按某一轴的内容密度切出 expect 个连续带。
    axis=0 按行密度切（横向条带），axis=1 按列密度切（纵向条带）。"""
    w, h = img.size
    px = img.load()
    if axis == 0:
        n_outer, n_inner = h, w
    else:
        n_outer, n_inner = w, h
    density = []
    for i in range(n_outer):
        filled = 0
        for j in range(0, n_inner, 4):
            p = px[j, i] if axis == 0 else px[i, j]
            if p[3] > 24:
                filled += 1
        density.append(filled)
    segs, start, gap = [], None, 0
    for i, c in enumerate(density + [0]):
        if c >= min_count:
            if start is None:
                start = i
            gap = 0
        elif start is not None:
            gap += 1
            if gap >= min_gap:
                if i - gap - start + 1 >= 30:
                    segs.append((start, i - gap + 1))
                start, gap = None, 0
    # 角色通常顶到画布上下边缘，尾部没有 min_gap 个空带可等 —— 循环结束必须冲刷
    if start is not None and n_outer - start >= 30:
        segs.append((start, n_outer))
    return segs[:expect] if len(segs) >= expect else segs


def find_segments(img, expect, axis):
    """先按参数枚举找连续段；不足期望段数（立绘间的辉光会桥接空隙，
    常见于横排总表）时，对过宽段按密度最低的谷列递归二分补齐。"""
    w, h = img.size
    px = img.load()
    n_outer = h if axis == 0 else w
    n_inner = w if axis == 0 else h

    def density(a0, a1):
        d = {}
        for i in range(a0, a1):
            filled = sum(1 for j in range(0, n_inner, 4)
                         if (px[j, i] if axis == 0 else px[i, j])[3] > 24)
            d[i] = filled
        return d

    for min_count in (1, 2, 3, 4):
        for min_gap in (2, 4, 8, 16):
            segs = bands(img, axis, expect, min_gap, min_count)
            if len(segs) == expect:
                return segs
            d = None
    # 谷值分裂：谁最宽就切谁，直到段数凑齐
    d = density(0, n_outer)
    guard = 0
    while len(segs) < expect and guard < 24:
        guard += 1
        a, b = max(segs, key=lambda s: s[1] - s[0])
        if b - a < 160:
            break
        c = min(range(a + 80, b - 80), key=lambda i: d[i])
        segs = sorted([(a, c), (c, b)] + [s for s in segs if s != (a, b)])
    if len(segs) != expect:
        print(f"  诊断 expect={expect} axis={axis}: min_count=1 → "
              f"{bands(img, axis, expect, 4, 1)}；谷值分裂后 → {segs}")
        raise SystemExit(f"切分失败：期望 {expect} 段（axis={axis}），人工看诊断后调参")
    return segs


def drop_fragments(img, strip=42, min_mass=3000):
    """邻座碎片清理：裁切边界带入的碎片全贴着单元格左右边缘，
    且质量很小（~2-3k 实体像素）；而角色本体即使最窄的边缘也有大片实体。
    所以按条带质量判定：左右 strip 列内实体像素总量 < min_mass 就整条清掉。
    ⚠️ 不用腐蚀+连通域：脚踝、发梢这类细连接会被腐蚀切断，
    真部件（腿/鞋）变成 1-2k 的小域，和碎片同量级，按面积分不开。"""
    w, h = img.size
    px = img.load()
    for side in (range(min(strip, w)), range(max(0, w - strip), w)):
        mass = sum(1 for y in range(h) for x in side if px[x, y][3] > 60)
        if 0 < mass < min_mass:
            for y in range(h):
                for x in side:
                    if px[x, y][3] != 0:
                        px[x, y] = (0, 0, 0, 0)
    bbox = img.getbbox()
    return img.crop(bbox) if bbox else img


def cell_images(sheet, rows):
    """rows: 每行一个角色名单。返回 [(name, label, cropped_img)]。
    先整张去黑底（背景不透明，不先去则密度分段会把背景当内容），
    再按行带 → 行内列段两级切分。"""
    img = sheet.convert("RGBA")
    strip_black(img)
    w, h = img.size
    row_bands = find_segments(img, len(rows), axis=0)
    out = []
    for (y0, y1), row in zip(row_bands, rows):
        row_img = img.crop((0, y0, w, y1))
        for (x0, x1), (name, label) in zip(find_segments(row_img, len(row), axis=1), row):
            cell = row_img.crop((max(0, x0 - 4), 0, min(w, x1 + 4), y1 - y0))
            cell = drop_fragments(cell)
            out.append((name, label, cell))
    return out


def main():
    DST.mkdir(parents=True, exist_ok=True)
    SHEETS.mkdir(parents=True, exist_ok=True)
    for path, rows in (GLOBAL, CHINA):
        sheet = Image.open(path)
        print(f"{path.name} {sheet.size}")
        # 总表留档（缩到宽 1400，省仓库空间）
        keep = sheet.convert("RGB")
        if keep.width > 1400:
            keep = keep.resize((1400, round(keep.height * 1400 / keep.width)), Image.LANCZOS)
        keep.save(SHEETS / path.name.replace("-", "_").replace(".png", "_sheet.png"), optimize=True)
        for name, label, cell in cell_images(sheet, rows):
            out = DST / f"{name}.png"
            cell.save(out)
            print(f"  {label:<8} -> {out.name} {cell.size}")


if __name__ == "__main__":
    main()
