"""样页版式分析：渲染整页 -> rapidocr 识别 -> 打印题号锚点与栏结构。"""
import re
import sys
import time

import pymupdf
from rapidocr_onnxruntime import RapidOCR

BOOKS = {
    "zy1000": ("D:/study/数学/考研数学/27张宇1000题数二-试题册【公众号：考研小舟】免费分享.pdf", [8, 12, 20]),
    "660xd": ("D:/study/数学/考研数学/《基础过关660》-线代篇.pdf", [8, 15, 30]),
    "660gs": ("D:/study/数学/考研数学/《基础过关660》-高数篇 .pdf", [10, 20, 40]),
    "1800xd": ("D:/study/数学/考研数学/【Pad版】26汤家凤《1800题》基础篇-线代（数二）.pdf", [6, 10, 15]),
}

ANCHOR = re.compile(r"^(\d{1,4})[.、．]")

def main():
    ocr = RapidOCR()
    for tag, (path, pages) in BOOKS.items():
        doc = pymupdf.open(path)
        print(f"\n######## {tag}  共{len(doc)}页  页面尺寸: {doc[pages[0]].rect}")
        for pno in pages:
            pg = doc[pno]
            t0 = time.time()
            pix = pg.get_pixmap(matrix=pymupdf.Matrix(2, 2))  # ~144dpi
            img_bytes = pix.tobytes("png")
            result, _ = ocr(img_bytes)
            dt = time.time() - t0
            if not result:
                print(f"  p{pno+1}: 无识别结果 ({dt:.1f}s)")
                continue
            anchors = []
            xs, ys = [], []
            for box, text, conf in result:
                m = ANCHOR.match(text.strip())
                x0, y0 = box[0][0] / 2, box[0][1] / 2  # 回到 PDF 坐标
                xs.append(x0)
                ys.append(y0)
                if m and float(conf) > 0.6:
                    anchors.append((m.group(1), round(x0), round(y0), text.strip()[:14]))
            xs_sorted = sorted(xs)
            # 粗看文本起始 x 的分布，判断栏数
            left = sum(1 for x in xs_sorted if x < doc[pno].rect.width * 0.45)
            print(f"  p{pno+1}: 行数{len(result)} 锚点{len(anchors)} ({dt:.1f}s) "
                  f"x分布: min{xs_sorted[0]:.0f} 中位{xs_sorted[len(xs_sorted)//2]:.0f} max{xs_sorted[-1]:.0f} 左半{left}/{len(xs)}")
            for a in anchors[:12]:
                print(f"      锚 q{a[0]} @({a[1]},{a[2]}) 「{a[3]}」")
        doc.close()

if __name__ == "__main__":
    sys.exit(main())
