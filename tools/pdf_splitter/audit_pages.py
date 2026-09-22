"""审计：区分题目页与答案页（workbook 版式：题目页有「难度」框，答案页没有）。"""
import json
import re
import sys
from pathlib import Path

OUT = Path("D:/study/数学/考研数学/split_out")

def page_lines(tag: str, pno: int):
    f = OUT / tag / "cache" / f"page_{pno:03d}.json"
    if not f.exists():
        return None
    return [tuple(l) for l in json.loads(f.read_text(encoding="utf-8"))["lines"]]

def classify(tag: str, style: str, n_pages: int):
    """返回每页分类：qpage(有锚+难度框) / apage(有锚无难度框) / other。"""
    transitions = []
    prev_cls = None
    counts = {"qpage": 0, "apage": 0, "other": 0}
    for pno in range(n_pages):
        lines = page_lines(tag, pno)
        if lines is None:
            break
        H = 841.0 if style != "landscape" else 595.35
        W = 595.0 if style != "landscape" else 841.99
        body = [l for l in lines if H * 0.06 < l[1] < H * 0.94]
        has_anchor = any(
            re.match(r"^\d{1,4}[.、．]?\s*$", l[4]) and l[0] < W * 0.24 and float(l[5]) > 0.5
            for l in body)
        has_nanodu = any(l[4].startswith("难度") or l[4].startswith("答题区") for l in body)
        cls = "qpage" if (has_anchor and has_nanodu) else ("apage" if has_anchor else "other")
        counts[cls] += 1
        if cls != prev_cls:
            transitions.append(f"p{pno+1}:{cls}")
            prev_cls = cls
    return counts, transitions

for tag, style, n in [("zy1000", "worksheet", 138), ("660xd", "workbook", 145),
                      ("660gs", "workbook", 347), ("1800xd", "landscape", 202)]:
    c, t = classify(tag, style, n)
    print(f"{tag}: {c}")
    print(f"   分界: {t}")
