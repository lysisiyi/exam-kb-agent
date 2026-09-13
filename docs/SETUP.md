# 环境搭建（Windows）

> 本文档记录本机实测的环境状态与补齐步骤。
> 最后更新：2026-03-15

---

## 0. 当前状态：环境已就绪 ✅

一条命令体检：

```powershell
python tools/setup_windows.py --check
```

本机实测结果：

```
[Flutter]  [OK]  Flutter 3.47.4 · Dart 3.13.3 · stable · D:\software\flutter
[国内镜像]  [OK]  FLUTTER_STORAGE_BASE_URL / PUB_HOSTED_URL
[sqlite3]  [OK]  版本 3.5.2 匹配；hook 缓存已就绪
```

**Flutter 已装在 `D:\software\flutter`，PATH 与镜像已配置。**

> ⚠️ 首次跑 `win` 命令前请确认 `D:\software\flutter\bin` 在当前 PATH 里。
> 若新开的终端仍找不到 `flutter`，把 `D:\software\flutter\bin` 手动加进系统 PATH。

---

## 1. 本机实测状态

| 组件 | 状态 | 说明 |
|---|---|---|
| **Flutter SDK** | ✅ **3.47.4 stable** | `D:\software\flutter` |
| **Dart** | ✅ **3.13.3** | 随 Flutter 附带 |
| **Visual Studio 2026 Community** | ✅ 已装 | `D:\software\VisualStdio\Community` |
| **C++ 桌面开发工作负载** | ✅ 已装 | `Microsoft.VisualStudio.Component.VC.Tools.x86.x64` |
| **Windows 11 SDK** | ✅ 已装 | Flutter Windows 构建必需 |
| **MSBuild** | ✅ 已装 | `...\MSBuild\Current\Bin\MSBuild.exe` |
| Git | ✅ 已装 | `D:\software\Git\Git\cmd\git.exe` |
| Python | ✅ 已装 | — |
| winget | ✅ 可用 | — |

`flutter doctor` 结果：

```
[√] Flutter (Channel stable, 3.47.4, on Microsoft Windows [版本 10.0.26200.9445])
[√] Windows Version (Windows 11 or higher, 25H2, 2009)
[X] Android toolchain           ← V1 不做 Android，可忽略
[√] Visual Studio - develop Windows apps (Visual Studio Community 2026 18.10.0)
[√] Connected device (1 available)
[!] Network resources           ← github.com 不可达，见 §3
```

---

## 2. 从零开始装（换机器时参考）

Windows 构建的三个硬前置（VS + C++ 工作负载 + Windows 11 SDK）已就绪，
只差 Flutter 本身。**必须在普通终端里执行**（受限沙箱无外网）。

### 2.1 装 Flutter SDK

GitHub 在部分网络下不可达，`winget` 也可能因源不可用而失败。
最稳的方式是 **git clone stable 分支**：

```powershell
git clone -b stable --depth 1 https://github.com/flutter/flutter.git D:\software\flutter
```

> 如果 GitHub 也连不上，用镜像：
> ```powershell
> git clone -b stable --depth 1 https://ghproxy.net/https://github.com/flutter/flutter.git D:\software\flutter
> ```

### 2.2 配置 PATH 与国内镜像

```powershell
$flutterBin = "D:\software\flutter\bin"
$old = [Environment]::GetEnvironmentVariable("Path","User")
if ($old -notlike "*$flutterBin*") {
    [Environment]::SetEnvironmentVariable("Path", "$old;$flutterBin", "User")
}
[Environment]::SetEnvironmentVariable("FLUTTER_STORAGE_BASE_URL","https://storage.flutter-io.cn","User")
[Environment]::SetEnvironmentVariable("PUB_HOSTED_URL","https://pub.flutter-io.cn","User")
```

**重开终端**让 PATH 生效。

### 2.3 完成首次初始化

```powershell
flutter --version
```

首次运行会下载 Dart SDK（约 600 MB）并构建 flutter_tools 快照，
**耗时可能超过 10 分钟**。如果被中断，重跑即可（有断点续传）。
看到 `Flutter 3.47.4 • channel stable • Dart 3.13.3` 就成功了。

### 2.4 启用 Windows 桌面

```powershell
flutter config --enable-windows-desktop --no-enable-web `
               --no-enable-linux-desktop --no-enable-macos-desktop
```

---

## 3. ⚠️ 国内网络特有的三个坑

这一节是本项目踩过的真实问题，换机器/清缓存后一定会再遇到。

> **一条通用兜底**：本机装了本地加速器（FlyingBird / Watt Toolkit），
> 系统代理是 `127.0.0.1:26561`。凡是"下载卡住"的情况，先把代理环境变量接上再重试：
>
> ```powershell
> $env:HTTP_PROXY="http://127.0.0.1:26561"
> $env:HTTPS_PROXY="http://127.0.0.1:26561"
> ```
>
> 查当前系统代理端口：
> `reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer`
>
> **判断标准**：卡住时先看目标文件是不是 **0 字节**。国内被墙的下载往往不是
> 快速失败，而是**无限期挂住**（CMake / ExternalProject 会一直重试），
> 表现得像"编译很慢"，实际是永远编不完。

### 坑 1：`storage.googleapis.com` 不可达

**症状**：`flutter --version` 卡住或报网络错误。

**原因**：Flutter 默认从 Google 存储下载引擎构件。

**解决**：设置 `FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn`（见 §2.2）。

### 坑 2：`pub.dev` 慢

**症状**：`flutter pub get` 长时间无响应。

**解决**：设置 `PUB_HOSTED_URL=https://pub.flutter-io.cn`。

### 坑 3：`sqlite3` 原生库从 GitHub 下载 —— 最隐蔽

**症状**：

```
Unhandled exception:
By default, this package downloads a pre-compiled SQLite library.
This failed (attempted to download
  https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-3.5.2/sqlite3.x64.windows.dll)
Original cause: SocketException: 远程计算机拒绝网络连接。
  ...
Building native assets failed.
```

`flutter test` 与 `flutter build` 都会因此失败。

**为什么改 pub 镜像无效**：这不是 pub 依赖下载，而是
**构建期 build hook 的原生资产下载**，它硬编码走 GitHub Releases。

**解决**（`tools/setup_windows.py` 已自动化）：

```powershell
python tools/setup_windows.py --dll-only
```

脚本做的事：

1. 从 GitHub 加速镜像下载 `sqlite3.x64.windows.dll`
2. **校验 SHA256**（必须与 `sqlite3` 包内 `asset_hashes.dart` 期望值一致，
   否则 hook 会判定缓存无效并重新下载）
3. 放进 hook 的缓存目录
   `app/.dart_tool/hooks_runner/shared/sqlite3/build/download-<哈希前8位>/sqlite3.dll`
4. 同时在 `tools/vendor/` 留一份副本

> hook 会校验缓存文件的 SHA256；匹配则直接复用，跳过下载。

**相关常量**（如果 `sqlite3` 升级了需要同步更新）：

| 项 | 值 |
|---|---|
| 版本 | `3.5.2` |
| 文件名 | `sqlite3.x64.windows.dll` |
| SHA256 | `2bf39f2aadafdc59a90b260f582a8fccebc5b89eb94175fdbaa9148c1e1f084d` |

`python tools/setup_windows.py --check` 会自动比对 `pubspec.lock` 里的实际版本，
不一致会提示。

### 坑 4：`printing` 插件下载 pdfium（已通过移除依赖规避）

**症状**：

```
CMake Error at flutter/ephemeral/.plugin_symlinks/printing/windows/DownloadProject.cmake:179 (message):
  Build step for pdfium failed: 1
Error: Unable to generate build files
```

`printing` 构建时要从 GitHub Releases 取 `pdfium-win-x64.tgz`。
它当前**没有任何代码在用**（只在 `dev_shell.dart` 的占位文案里出现过），
却让整个工程构建不了，所以已从 `pubspec.yaml` 移除。

M6 做 PDF 预览/打印时再引回来，按坑 3 的办法预置 pdfium 二进制。

> `pdf` 包保留着 —— 它是**纯 Dart**，负责生成 PDF 字节流，不涉及下载。

### 坑 5：`sqlite3_flutter_libs` 下载 sqlite 源码（已通过移除依赖规避）

**症状**：构建**不报错、直接挂死**，看起来像"编译很慢"：

```
Building Windows application...   ← 卡在这里，可以无限等下去
```

查 `build/windows/x64/_deps/sqlite3-subbuild/.../src/` 会发现：

```
sqlite-autoconf-3520000.tar.gz     0 字节   ← 下载失败，但 CMake 在反复重试
```

地址是 `https://sqlite.org/2026/sqlite-autoconf-3520000.tar.gz`。

**根因是架构重复**：`sqlite3_flutter_libs`（CMake 下载源码现场编译）和
`sqlite3`（Dart Native Assets 直接取预编译 DLL，即坑 3 那套）提供的是
**同一份原生库**。保留两套还有个隐患：同一份库被链接两次。

所以已移除 `sqlite3_flutter_libs`，只留 Native Assets 一条路。
验收点：构建产物里必须有 `sqlite3.dll`（约 1.6 MB）。

### 坑 6：脏 `CMakeCache.txt` 把安装前缀固化成 `C:/Program Files`

**症状**：编译全部通过，最后倒在 INSTALL 步骤：

```
CMake Error at cmake_install.cmake:90 (file):
  file cannot create directory: C:/Program Files/kaoyan_math_agent.
  Maybe need administrative privileges.
MSBuild ... error MSB3073: ... INSTALL.vcxproj ... 已退出，代码为 1
```

MSB3073 只会说"子命令返回非零"，**真正的原因被吞掉了**。要看到原始报错，
得手动跑那一步：

```powershell
cd app\build\windows\x64
& "D:\software\VisualStdio\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe" -DBUILD_TYPE=Debug -P cmake_install.cmake
```

**原因**：`windows/CMakeLists.txt:68` 本来有正确的守卫
（`if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)` → 改成 bundle 目录），
但被之前一次**卡死的构建**留下的脏缓存固化了：

```
CMAKE_INSTALL_PREFIX:PATH=C:/Program Files/kaoyan_math_agent     ← 脏值
CMAKE_INSTALL_PREFIX:PATH=$<TARGET_FILE_DIR:kaoyan_math_agent>   ← 正常值
```

**解决**：删掉构建目录重新配置。

```powershell
cd app
Remove-Item -Recurse -Force build     # 只删 build/，不要用 flutter clean
```

**同一个坑的第二种触发方式：把项目目录挪到别处。**

`CMakeCache.txt` 里存的是**绝对路径**，移动项目后 CMake 会直接拒绝：

```
CMake Error: The current CMakeCache.txt directory .../kaoyan-math-agent/app/build/windows/x64/CMakeCache.txt
  is different than the directory d:/agent/deepseekharness/Project/app/build/windows/x64
  where CMakeCache.txt was created.
CMake Error: The source ".../kaoyan-math-agent/app/windows/CMakeLists.txt" does not match
  the source ".../Project/app/windows/CMakeLists.txt" used to generate cache.
Unable to generate build files
```

处理办法完全相同：删 `app/build/` 重新构建。

> ⚠️ **不要用 `flutter clean`** —— 它会连带删掉
> `windows/flutter/ephemeral/.plugin_symlinks`，而重建那些符号链接
> **又需要开发者模式**（见 §5）。只删 `app/build/` 就够了，
> 符号链接位于 `app/windows/` 下，不受影响。

---

## 4. 创建 / 补齐工程脚手架

工程已存在（`app/`），`windows/` 平台脚手架已生成。
如需在别的机器上重建：

```powershell
cd app
flutter create --platforms=windows --org com.kaoyan --project-name kaoyan_math_agent .
```

> 该命令**不会覆盖**已有的 `lib/` 代码，只补齐平台目录。

---

## 5. 拉依赖与跑测试

```powershell
cd app
flutter pub get
flutter test
```

### ⚠️ 关于 Windows「开发者模式」——**构建 exe 必须开启**

`flutter pub get` 与 `flutter build windows` 会提示：

```
Building with plugins requires symlink support.
Please enable Developer Mode in your system settings. Run
  start ms-settings:developers
```

**实测结论**：

| 命令 | 是否需要开发者模式 |
|---|---|
| `flutter test` | ❌ 不需要（已实测 112 个用例通过） |
| `flutter analyze` | ❌ 不需要 |
| `flutter run -d windows` | ✅ **需要** |
| `flutter build windows` | ✅ **需要** |

原因：Flutter 在构建 Windows 应用时，需要为每个插件创建**符号链接**
（`file_selector_windows`、`flutter_secure_storage_windows` 等）。
创建符号链接需要 `SeCreateSymbolicLinkPrivilege` 权限，
只有管理员或**开发者模式**下才默认拥有。

**开启方式**（三选一）：

```powershell
# 方式 1：打开设置页面，手动开启「开发人员模式」
start ms-settings:developers
```

```
方式 2：设置 → 系统 → 开发者选项 → 开发人员模式（开）
```

```powershell
# 方式 3：管理员 PowerShell 里执行
New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" `
  -Name AllowDevelopmentWithoutDevLicense -Value 1 -PropertyType DWORD -Force
```

> ⚠️ 方式 3 需要**管理员权限**。普通用户身份执行会报
> `Requested registry access is not allowed`。
> 此前已实测：非管理员无法写入该注册表键，必须走方式 1 或 2 手动开启。

开启后无需重启，直接重跑 `flutter build windows` 即可。

---

## 6. 跑起来

**最省事**（仓库根目录，双击即可）：

```
run_app.bat
```

它会设好国内镜像与代理、必要时构建、然后启动 App。

**或手动**：

```powershell
cd app
flutter run -d windows
```

首次构建会编译 C++ runner，**耗时 2–5 分钟**，之后增量构建很快。

只想要一个能双击的 exe：

```powershell
cd app
flutter build windows --debug
# 产物：app\build\windows\x64\runner\Debug\kaoyan_math_agent.exe
```

---

## 7. 常用命令

```powershell
# 环境体检
python tools/setup_windows.py --check

# 修 sqlite3 原生库（清缓存后必跑）
python tools/setup_windows.py --dll-only

# 测试
cd app; flutter test

# 静态分析
cd app; flutter analyze

# 运行
cd app; flutter run -d windows

# 构建发布版
cd app; flutter build windows --release
```

---

## 8. 常见问题

| 现象 | 原因 | 解决 |
|---|---|---|
| `flutter` 不是内部或外部命令 | PATH 未生效 | 重开终端；确认 PATH 含 `D:\software\flutter\bin` |
| `flutter --version` 卡住 | 首次在下载 Dart SDK | 耐心等，或检查镜像变量 |
| `Building with plugins requires symlink support` | 未开开发者模式 | **见 §5**（构建 exe 必须开启） |
| `Building native assets failed` + GitHub 报错 | sqlite3 DLL | `python tools/setup_windows.py --dll-only` |
| `No named parameter with the name 'windows'` | 包版本不支持 Windows | 检查该包是否真的支持 Windows（我们踩过 `flutter_local_notifications 17.x`） |
| `flutter pub get` 卡住 | 官方源慢 | 检查 `PUB_HOSTED_URL` |
| `flutter doctor` 报 Android 错误 | 未装 Android SDK | **忽略**，V1 不用 |
| 子进程调用 `flutter.bat` 挂住 | 受限沙箱不允许嵌套子进程 | 在普通终端直接跑，不要经脚本调用 |

