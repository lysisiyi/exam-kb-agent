#!/usr/bin/env python3
"""Windows 开发环境自举脚本。

把「装 Flutter + 配镜像 + 解决 sqlite3 原生库被墙」这套流程固化下来，
换机器或清缓存后可以一条命令恢复。

## 背景：为什么需要它

在国内网络环境下，Flutter 项目有三个特有的坑：

1. **Flutter SDK 下载**：`storage.googleapis.com` 不可达，须走 `storage.flutter-io.cn`
2. **pub 依赖下载**：`pub.dev` 慢，须走 `pub.flutter-io.cn`
3. **`sqlite3` 原生库**：`sqlite3` 包的 build hook 会从 **GitHub Releases**
   下载 `sqlite3.x64.windows.dll`。GitHub 在部分网络下不可达，导致
   `flutter test` / `flutter build` 直接失败。

第 3 条最隐蔽：它不是 pub 依赖问题，而是**构建期**的原生资产下载，
改 pub 镜像无效。本脚本预先把 DLL 放到 hook 的缓存目录，让 hook 命中缓存跳过下载。

## 用法

    python tools/setup_windows.py --check      # 只体检，不改动
    python tools/setup_windows.py              # 执行全部修复
    python tools/setup_windows.py --dll-only   # 只修 sqlite3 DLL
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "app"

# ── sqlite3 原生库 ───────────────────────────────────────────────────────────
# 版本与哈希必须与 pub 解析出的 sqlite3 包一致，否则 hook 会判定缓存无效并重新下载。
SQLITE3_VERSION = "3.5.2"
SQLITE3_DLL_NAME = "sqlite3.x64.windows.dll"
SQLITE3_SHA256 = "2bf39f2aadafdc59a90b260f582a8fccebc5b89eb94175fdbaa9148c1e1f084d"
SQLITE3_RELEASE_URL = (
    f"https://github.com/simolus3/sqlite3.dart/releases/download/"
    f"sqlite3-{SQLITE3_VERSION}/{SQLITE3_DLL_NAME}"
)
# 国内可用的 GitHub 加速前缀（按可用性排序，脚本会逐个尝试）
GITHUB_MIRRORS = [
    "https://ghproxy.net/",
    "https://gh-proxy.com/",
    "",  # 直连
]

VENDOR_DIR = ROOT / "tools" / "vendor"
VENDOR_DLL = VENDOR_DIR / SQLITE3_DLL_NAME


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def find_flutter() -> Path | None:
    """定位 Flutter SDK。"""
    exe = shutil.which("flutter")
    if exe:
        return Path(exe).resolve().parent
    for candidate in (
        Path(r"D:\software\flutter\bin"),
        Path(r"C:\flutter\bin"),
        Path(r"D:\flutter\bin"),
        Path.home() / "flutter" / "bin",
    ):
        if (candidate / "flutter.bat").exists():
            return candidate
    return None


def check_flutter() -> tuple[bool, str]:
    """验证 Flutter SDK 是否就绪。

    ⚠️ 优先**不调用** flutter 子进程，而是检查 SDK 关键文件。
    原因：受限沙箱环境不允许嵌套子进程（执行 .bat 会挂住直至超时），
    而大多数情况下我们只想知道"SDK 在不在、Dart 装没装"。
    只有在文件检查不通过时才退回调用 `flutter --version` 以求更准确的诊断。
    """
    f = find_flutter()
    if not f:
        return False, "未找到 Flutter SDK（建议装到 D:\\software\\flutter）"

    # find_flutter() 返回的是 .../flutter/bin，SDK 根目录是它的上一级
    sdk_root = f.parent
    # 注意：老版本 Flutter 在 SDK 根目录放一个 `version` 文件，
    # 新版已废弃该文件，改用 bin/cache/flutter.version.json。不要检查 `version`。
    dart = f / "cache" / "dart-sdk" / "bin" / "dart.exe"
    snapshot = f / "cache" / "flutter_tools.snapshot"
    version_json = f / "cache" / "flutter.version.json"

    missing = []
    if not (f / "flutter.bat").exists():
        missing.append("bin/flutter.bat")
    if not dart.exists():
        missing.append("cache/dart-sdk（Dart 未下载，首次运行未完成）")
    if not snapshot.exists():
        missing.append("cache/flutter_tools.snapshot（工具未构建，首次运行未完成）")

    if missing:
        return False, (
            f"SDK 不完整，缺少：{', '.join(missing)}。"
            f"请运行一次 `flutter --version` 完成初始化"
        )

    # 读缓存里的版本信息，比调用子进程更快也更可靠
    try:
        info = json.loads(version_json.read_text(encoding="utf-8"))
        return True, (
            f"Flutter {info.get('flutterVersion')} · "
            f"Dart {info.get('dartSdkVersion')} · "
            f"{info.get('channel')} · {sdk_root}"
        )
    except Exception:  # noqa: BLE001
        return True, f"SDK 文件齐备（{sdk_root}），但无法读取 flutter.version.json"


def check_mirrors() -> dict[str, str]:
    """检查国内镜像配置。

    环境变量可能只设在**用户级注册表**里，当前进程未必继承（尤其是沙箱子进程）。
    因此进程环境读不到时，回退去读用户级注册表。
    """
    keys = ("FLUTTER_STORAGE_BASE_URL", "PUB_HOSTED_URL")
    out: dict[str, str] = {}

    for k in keys:
        v = os.environ.get(k, "")
        if not v:
            # 回退：读 HKCU\Environment
            try:
                import winreg  # type: ignore[import-not-found]

                with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as key:
                    v, _ = winreg.QueryValueEx(key, k)
            except Exception:  # noqa: BLE001
                v = ""
        out[k] = v or ""

    return out


def _hook_cache_dirs() -> list[Path]:
    """返回 sqlite3 build hook 可能使用的缓存目录（按哈希前 8 位命名）。"""
    base = APP / ".dart_tool" / "hooks_runner" / "shared" / "sqlite3" / "build"
    if not base.exists():
        return []
    prefix = SQLITE3_SHA256[:8]
    return [d for d in base.iterdir() if d.is_dir() and d.name.startswith("download-")]


def ensure_dll(force_download: bool = False) -> tuple[bool, str]:
    """确保 sqlite3 DLL 存在且被放到 hook 缓存中。

    返回 (是否成功, 说明)。
    """
    VENDOR_DIR.mkdir(parents=True, exist_ok=True)

    # 1. 确保本地副本存在且哈希正确
    need_download = force_download or not VENDOR_DLL.exists()
    if VENDOR_DLL.exists() and not force_download:
        if sha256_of(VENDOR_DLL) != SQLITE3_SHA256:
            print("  [!] 本地副本哈希不符，重新下载")
            need_download = True

    if need_download:
        print(f"  下载 {SQLITE3_DLL_NAME} …")
        ok = False
        for prefix in GITHUB_MIRRORS:
            url = prefix + SQLITE3_RELEASE_URL
            label = prefix or "（直连 GitHub）"
            try:
                with urllib.request.urlopen(url, timeout=180) as resp:
                    data = resp.read()
                # 校验哈希后再落盘
                digest = hashlib.sha256(data).hexdigest()
                if digest != SQLITE3_SHA256:
                    print(f"    [X] {label} 哈希不符，跳过")
                    continue
                VENDOR_DLL.write_bytes(data)
                print(f"    [OK] {label} 下载并校验通过（{len(data):,} bytes）")
                ok = True
                break
            except (urllib.error.URLError, TimeoutError, OSError) as e:
                print(f"    [X] {label} 失败：{e}")
        if not ok:
            return False, "所有下载源均失败；请手动下载并放到 tools/vendor/"

    if sha256_of(VENDOR_DLL) != SQLITE3_SHA256:
        return False, "本地副本哈希不符"

    # 2. 放进 hook 缓存
    dirs = _hook_cache_dirs()
    if not dirs:
        # hook 还没跑过，缓存目录未创建。等首次构建后重跑本脚本即可。
        return False, (
            "hook 缓存目录尚未生成。请先运行一次 `flutter pub get`，"
            "再重跑本脚本（或直接重跑本脚本，它会自动重试）"
        )

    placed = 0
    for d in dirs:
        # 清掉上次失败留下的 0 字节 .tmp
        for tmp in d.glob("*.tmp"):
            tmp.unlink(missing_ok=True)
        target = d / "sqlite3.dll"
        if target.exists() and sha256_of(target) == SQLITE3_SHA256:
            placed += 1
            continue
        shutil.copy2(VENDOR_DLL, target)
        placed += 1
    return placed > 0, f"已放入 {placed} 个 hook 缓存目录"


def sqlite3_package_version() -> str | None:
    """从 pubspec.lock 读出实际解析到的 sqlite3 版本，用于校验常量是否需要更新。"""
    lock = APP / "pubspec.lock"
    if not lock.exists():
        return None
    try:
        text = lock.read_text(encoding="utf-8")
        # 极简解析：找 sqlite3: 段下的 version
        lines = text.splitlines()
        for i, line in enumerate(lines):
            if line.strip() == "sqlite3:":
                for sub in lines[i : i + 12]:
                    s = sub.strip()
                    if s.startswith("version:"):
                        return s.split(":", 1)[1].strip().strip('"')
    except Exception:  # noqa: BLE001
        pass
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description="Windows 开发环境自举")
    ap.add_argument("--check", action="store_true", help="只体检，不改动")
    ap.add_argument("--dll-only", action="store_true", help="只处理 sqlite3 DLL")
    args = ap.parse_args()

    print("=" * 70)
    print("Windows 开发环境体检")
    print("=" * 70)

    problems: list[str] = []

    # ── Flutter ──
    if not args.dll_only:
        ok, msg = check_flutter()
        print(f"\n[Flutter]  {'[OK]' if ok else '[X]'}  {msg}")
        if not ok:
            problems.append("Flutter 未就绪")

        mirrors = check_mirrors()
        print("\n[国内镜像]")
        for k, v in mirrors.items():
            mark = "[OK]" if v else "[X]"
            print(f"  {mark} {k} = {v or '(未设置)'}")
            if not v:
                problems.append(f"{k} 未设置")

        pkg_ver = sqlite3_package_version()
        print(f"\n[sqlite3 版本]  pubspec.lock = {pkg_ver or '(未解析)'}  |  "
              f"脚本常量 = {SQLITE3_VERSION}")
        if pkg_ver and pkg_ver != SQLITE3_VERSION:
            print("  [!] 版本不一致 —— 需更新本脚本的 SQLITE3_VERSION 与哈希常量")

    # ── sqlite3 DLL ──
    cached = [
        d for d in _hook_cache_dirs()
        if (d / "sqlite3.dll").exists()
        and sha256_of(d / "sqlite3.dll") == SQLITE3_SHA256
    ]
    print(f"\n[sqlite3 原生库]")
    print(f"  本地副本: {'[OK]' if VENDOR_DLL.exists() else '[X]'} {VENDOR_DLL}")
    print(f"  hook 缓存: {len(cached)} 个目录已就绪")

    if not cached:
        problems.append("sqlite3 DLL 未就位（flutter test/build 会失败）")

    if args.check:
        print("\n" + "=" * 70)
        if problems:
            print("发现 %d 个问题：" % len(problems))
            for p in problems:
                print(f"  - {p}")
            print("\n运行 `python tools/setup_windows.py` 修复。")
            return 1
        print("[OK] 环境就绪")
        return 0

    if not args.dll_only:
        print("\n" + "=" * 70)
        print("镜像环境变量设置（用户级，重开终端生效）")
        print("=" * 70)
        for k, v in (
            ("FLUTTER_STORAGE_BASE_URL", "https://storage.flutter-io.cn"),
            ("PUB_HOSTED_URL", "https://pub.flutter-io.cn"),
        ):
            try:
                subprocess.run(
                    ["powershell", "-NoProfile", "-Command",
                     f"[Environment]::SetEnvironmentVariable('{k}','{v}','User')"],
                    check=True, capture_output=True,
                )
                print(f"  [OK] {k}")
            except Exception as e:  # noqa: BLE001
                print(f"  [X] {k}: {e}")

    print("\n" + "=" * 70)
    print("修复 sqlite3 原生库")
    print("=" * 70)
    ok, msg = ensure_dll()
    print(f"  {'[OK]' if ok else '[X]'} {msg}")

    print("\n完成。")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
