# -*- coding: utf-8 -*-
"""UI：错题本行以图当题面；组卷预览缩略图；测试种子支持 imagesPrimary。"""
from pathlib import Path
APP = Path("D:/agent/workspaces/kaoyan-math-agent/app")

# 1) 测试种子：imagesPrimary
p = APP / "test/support/test_env.dart"
s = p.read_text(encoding="utf-8")
s = s.replace("""  /// 题目引用的图片（相对路径，如 `images/p-1-1.png`）。
  final List<String> images;""",
"""  /// 题目引用的图片（相对路径，如 `images/p-1-1.png`）。
  final List<String> images;

  /// 配图是否即题面本体（扫描/拍照导入的题）。
  final bool imagesPrimary;""")
s = s.replace("    this.images = const [],", "    this.images = const [],\n    this.imagesPrimary = false,")
p.write_text(s, encoding="utf-8")
print("seed fields ok")

# 找种子写出 frontmatter 的位置，追加 images_primary
s = p.read_text(encoding="utf-8")
import re
m = re.search(r"images:(.*?)\n", s)
print("images line ctx:", repr(s[max(0, m.start()-120):m.end()+40]) if m else "NOT FOUND")
