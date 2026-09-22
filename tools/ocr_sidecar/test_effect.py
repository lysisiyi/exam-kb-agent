# -*- coding: utf-8 -*-
"""TexTeller 识别效果试验：对 660 线代切好的题图跑公式 OCR。

用法（在 ocr-test 虚拟环境里）：
  python tools/ocr_sidecar/test_effect.py <图片...> [--out results.json]

模型权重首次运行会从 HuggingFace 下载，国内需设置：
  HF_ENDPOINT=https://hf-mirror.com
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("images", nargs="+")
    ap.add_argument("--out", default="texteller_results.json")
    ap.add_argument(
        "--model-dir",
        default=None,
        help="本地权重目录（含 config.json + model.safetensors + 分词器）。"
        "不传则从 HuggingFace 下载（国内建议 HF_ENDPOINT=https://hf-mirror.com）",
    )
    args = ap.parse_args()

    # 延迟导入：参数解析不用等 torch
    from texteller import img2latex, load_model, load_tokenizer  # noqa: I001

    t0 = time.time()
    model = load_model(args.model_dir)  # 本地目录或默认 HF 权重
    tokenizer = load_tokenizer(args.model_dir)
    print(f"[load] model ready in {time.time() - t0:.1f}s", file=sys.stderr)

    results = []
    for img in args.images:
        p = Path(img)
        if not p.exists():
            results.append({"image": str(p), "error": "not found"})
            continue
        t1 = time.time()
        try:
            # img2latex 接收路径列表，返回等长的 LaTeX 列表
            latex = img2latex(model, tokenizer, [str(p)])[0]
            results.append(
                {"image": str(p), "latex": latex, "seconds": round(time.time() - t1, 1)}
            )
            print(f"[ocr] {p.name} ({time.time() - t1:.1f}s)", file=sys.stderr)
        except Exception as e:  # noqa: BLE001
            results.append({"image": str(p), "error": repr(e)})
            print(f"[err] {p.name}: {e!r}", file=sys.stderr)

    Path(args.out).write_text(
        json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(f"[done] {len(results)} results -> {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
