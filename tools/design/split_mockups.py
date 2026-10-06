# -*- coding: utf-8 -*-
"""把 ui_mockups.html 的整页渲染切成四张参考图。

先用无头 Chrome 渲染（窗口高 = 4×840 画布总高，一次成像无拼接伪影，
IAB 浏览器的 fullPage 拼接在本机会重复内容，不要用）：

  chrome --headless=new --disable-gpu --hide-scrollbars \
         --force-device-scale-factor=1 --window-size=1280,3360 \
         --screenshot="_full.png" "file:///…/docs/design/ui/ui_mockups.html"

再运行本脚本切图。
"""
from pathlib import Path
from PIL import Image

HERE = Path(__file__).resolve().parent.parent.parent / "docs" / "design" / "ui"
NAMES = ["ui_dashboard", "ui_lesson_notes", "ui_practice", "ui_pet", "ui_provider_pets",
         "ui_knowledge"]
SHOT = 840


def main():
    im = Image.open(HERE / "_full.png")
    assert im.width == 1280 and im.height == SHOT * len(NAMES), f"整页尺寸异常: {im.size}"
    for i, n in enumerate(NAMES):
        im.crop((0, i * SHOT, 1280, (i + 1) * SHOT)).save(HERE / f"{n}.png", optimize=True)
        print(f"{n}.png saved")
    (HERE / "_full.png").unlink()
    print("temp _full.png removed")


if __name__ == "__main__":
    main()
