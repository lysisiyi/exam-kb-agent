# 考试知识库 Agent · Windows V1 开发计划

> 版本 v1.0 · 2026-03-15
> 平台范围：**Windows 桌面端**（Flutter），架构预留 Android / iPadOS / macOS / iOS 扩展位
> 本文档是 V1 的**唯一范围依据**。任何不在此文档内的功能，默认不做。

---

## 0. 一页纸摘要

| 项目 | 内容 |
|---|---|
| **平台** | Windows 10/11 x64（Flutter desktop） |
| **目标** | 跑通一条闭环，验证「录一道错题 ≤60 秒」这个核心假设 |
| **不是目标** | 功能齐全、好看、能卖钱 |
| **核心闭环** | 录入错题 → AI 打标 → 进错题本 → FSRS 复习 → 组卷导出 |
| **工期** | 单人全职 ≈ **44 天**；业余（每晚+周末）≈ **2.5–3 个月** |
| **关键路径** | M0（知识点本体）→ M4（录入闭环） |
| **成败判据** | 你自己录完 50 题后，**还想录第 51 题** |
| **成本** | ¥0 服务器 · ¥0 运维 · LLM 用你自己的 API Key |

---

## 1. 范围定义

### 1.1 必做（10 项）

| # | 功能 | 说明 | 验收标准 |
|---|---|---|---|
| F1 | **知识点本体** | 考研数学一/二/三，约 300–500 叶子节点 | 能按知识点筛选；含考频权重 |
| F2 | **Markdown 题目存储** | YAML frontmatter + 正文，一题一文件 | 用户能直接用编辑器打开、能用 Git 管理 |
| F3 | **LaTeX 录入** | 快捷公式键盘 / 粘贴 / 图片识别 | 输入 `\int_0^1 \frac{\sin x}{x}dx` ≤ 15 秒 |
| F4 | **AI 自动标注** | 知识点 + 难度 + 题型 + 错因建议 | Top-1 准确率 ≥ 80% |
| F5 | **错题本** | 列表 / 详情 / 多维筛选 / 搜索 | 5000 题列表滚动不掉帧 |
| F6 | **FSRS 复习调度** | 三档反馈（忘了/吃力/轻松） | 复习队列每天正确生成 |
| F7 | **掌握度画像** | 按知识点/章节统计，薄弱点排序 | 薄弱点排序符合主观感受 |
| F8 | **组卷 + PDF 导出** | 真题结构模板 + 错题加权 + 三版式导出 | 生成 150 分卷，约束全满足 |
| F9 | **数据导出** | 一键导出 Markdown + 图片包 | 导出后能在 Obsidian 里直接用 |
| F10 | **PC 批量导入** ★ | 图片/PDF 批量解析入题库 | 一次导入 ≥100 题，成功率 ≥85% |

> ★ **F10 是 PC 版独有的杀手锏。** MinerU 是 Python 库，手机上跑不了，PC 上可以本地批量处理整个题库。这是 Windows 版相对移动端的真正优势，也是解决冷启动最快的方式。

### 1.2 明确不做

| 不做 | 理由 | 何时做 |
|---|---|---|
| AI 生成变式题 | 需 SymPy 验证链路，工程量≈半个 V1 | V2 |
| Agent 对话式复盘 | 需状态机 + 大量 prompt 调优 | V2 |
| 网络搜题扩充题库 | 版权风险 + 抓取质量差 | V3 |
| 账号系统 / 云同步 | 纯本地单机，跨设备靠导入导出 | V2 用 iCloud/Drive |
| 向量检索 | 5000 题内 FTS5 够用 | V3 |
| Apple Pencil / 手写 | Windows 端无此硬件 | iOS 版 |
| 拍照录入 | PC 无摄像头使用场景 | 移动端 |
| 社交 / 打卡 / 排行榜 | 与核心价值无关 | 不做（永久） |

### 1.3 「够用就好」清单

| 模块 | V1 实现 | 升级路径 |
|---|---|---|
| 组卷算法 | **贪心 + 回溯**（毫秒级） | V2 换 OR-Tools CP-SAT |
| 全文搜索 | SQLite **FTS5** | V3 加向量 + RRF 混合 |
| 公式识别 | 云端 API（多模态大模型） | V2 自建 UniMERNet |
| 知识点标注 | 单次 LLM + 受控词表 | V2 加 RAG 召回 + few-shot |
| OCR 抽象 | 端侧 WinRT OCR + 云端公式 | — |

---

## 2. 技术栈（锁定）

```
Flutter SDK          3.24+  /  Dart 3.5+
────────────────────────────────────────────────
UI 框架              flutter_riverpod         状态管理
                    go_router                路由
                    fluent_ui (可选)          Windows Fluent 风格控件
                    bitsdojo_window (可选)    自绘标题栏

数据层              drift + sqlite3_flutter_libs   SQLite + FTS5
                    path_provider             应用目录
                    flutter_secure_storage    API Key（Windows DPAPI）

公式渲染            katex (Dart 版)           纯 Dart，无 WebView
                    → 经 MathRenderer 抽象层包装

PDF 导出            pdf + printing            Playwright 太重，不用

网络                dio                       直连 LLM API

系统集成            file_selector             文件选择
                    window_manager            窗口管理
                    flutter_local_notifications  本地提醒
                    share_plus                导出分享

════════════════ 不引入 ════════════════
❌ PostgreSQL / Redis / Celery / FastAPI
❌ Playwright / Chromium
❌ FastAPI / SQLAlchemy / Alembic
❌ 任何需要常驻服务的组件
```

### 为什么全部纯本地

最重的计算（LLM 推理、公式识别）走**云端 API + 用户自己的 Key**，因此：
- 服务器成本 **¥0**，运维成本 **¥0**
- 设备要求极低
- 用户数据 100% 留在本机（隐私卖点）
- 无合规、无备案、无备案负担

---

## 3. 数据架构：双层结构

```
┌──────────────────────────────────────────────────────────┐
│  事实源（Source of Truth）                                │
│                                                           │
│  题目内容  →  Markdown 文件（一题一文件）                 │
│              人类可读 · 可 Git · 可迁移到 Obsidian        │
│                                                           │
│  用户状态  →  SQLite（高频写、需事务）                    │
│              错误次数 / FSRS 状态 / 掌握度 / 笔记         │
└──────────────────────────────────────────────────────────┘
                          ↓ 构建
┌──────────────────────────────────────────────────────────┐
│  索引层（Derived，可随时从 Markdown 全量重建）            │
│                                                           │
│  problems_index  +  FTS5 全文索引  +  知识点关联表        │
└──────────────────────────────────────────────────────────┘
```

### 铁律

> **绝不把用户状态写进 Markdown 文件。**
> 一旦 `wrong_count` / `fsrs_state` 落到 `.md` 里，你会同时陷入「高频重写文件」和「索引无法重建」两个坑。

### 数据归属

| 数据 | 存储 | 理由 |
|---|---|---|
| 题面 / 答案 / 解析 | Markdown | 写一次，很少改，需可迁移 |
| 知识点标签 | Markdown frontmatter | 跟着题目走，导出要带上 |
| 错因 / 错误次数 | SQLite | 每次复习都改 |
| FSRS 状态 | SQLite | 高频写，机器用 |
| 掌握度 | SQLite | 派生数据，可重算 |
| 我的笔记 | SQLite（导出时合并进 md） | 高频写 |

### 目录结构

```
%APPDATA%/kaoyan_math_agent/library/
├── problems/                 题目 Markdown（事实源）
│   ├── 2023-shu1-T18.md
│   └── ...
├── images/                   图片
├── strokes/                  手写笔迹（V2）
├── .index/index.sqlite       索引 + 用户状态（不可重建部分需备份）
└── seeds/                    内置种子题库（只读）
```

---

## 4. 里程碑

| 阶段 | 内容 | 工期 | 交付判定 |
|---|---|---|---|
| **M0 地基** ★ | 知识点本体 JSON（三科）+ 错因词表 + 考频数据 + Markdown 格式规范 + Drift schema | **5 天** | 能按知识点查询；`exam_frequency` 有真实数据 |
| **M1 项目骨架** | Flutter 工程 + 平台抽象层 + 断点系统 + `MathRenderer` + 主题 | **4 天** | 能渲染公式、能在三档断点切换布局 |
| **M2 数据层** | Drift 建表 + Markdown 读写 + 索引构建 + 迁移机制 | **5 天** | 手工放一个 .md 进去，App 能读到并建索引 |
| **M3 标注引擎** | LLM 客户端（多 provider）+ 召回 + 判定 + 置信度门禁 + 缓存 | **5 天** | 100 道真题 Top-1 ≥ 80% |
| **M4 录入闭环** ★ | 快捷公式键盘 + 粘贴 + 图片识别 + 编辑页 + 错因选择 + 保存 | **7 天** | **掐表 ≤ 60 秒** |
| **M5 错题本 + 复习** | 列表/详情/筛选/搜索 + FSRS（纯 Dart）+ 今日队列 + 三档反馈 | **6 天** | 录 50 题后连续复习 7 天正常 |
| **M6 组卷 + 导出** | 贪心组卷 + 三版式 PDF + 数据导出 | **5 天** | 生成 150 分卷且约束全满足 |
| **M7 PC 批量导入** ★ | 图片/PDF 批量解析 + 逐题核对 + 批量打标 | **4 天** | 一次导入 ≥100 题，成功率 ≥85% |
| **M8 画像 + 打磨** | 掌握度统计 + 空态/错误态 + 性能优化 + 自用验证 | **4 天** | 连续自用 7 天 |
| | | **≈45 天** | |

**关键路径是 M0 和 M4**：
- M0 卡住，后面全卡 —— 它是所有功能的尺子
- M4 做不好，整个产品没意义 —— 它是用户唯一的高频动作

---

## 5. 工程纪律（现在就要守）

这几条做不到，以后加 Android/iOS/macOS 就是重写。

### 纪律 1：平台能力走抽象接口

```dart
// lib/core/platform/
abstract class OcrService {
  Future<OcrResult> recognizeText(Uint8List imageBytes);
}
abstract class ImageSourceService {
  bool get supportsCamera;
  Future<List<Uint8List>> pickMultipleFiles();
}
abstract class NotifyService {
  Future<void> scheduleReviewReminder(DateTime at, int dueCount);
}
abstract class SecureStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}
```

V1 只实现 Windows 版 + Mock 版。加平台时只补实现，不改调用方。

### 纪律 2：永远不硬编码路径

```dart
// ❌ 禁止
Directory('C:\\Users\\me\\problems');

// ✅ 正确
final base = await getApplicationSupportDirectory();
Directory(p.join(base.path, 'library', 'problems'));
```

### 纪律 3：UI 按宽度断点，不按设备判断

```dart
enum LayoutBreakpoint { compact, medium, expanded, large }

LayoutBreakpoint bp(double w) {
  if (w < 600)  return LayoutBreakpoint.compact;   // 手机竖屏
  if (w < 900)  return LayoutBreakpoint.medium;    // 手机横屏
  if (w < 1200) return LayoutBreakpoint.expanded;  // iPad 竖屏 / Split View
  return LayoutBreakpoint.large;                    // PC / iPad 横屏
}
```

**绝不写 `if (Platform.isAndroid)` 来决定布局。**

### 纪律 4：桌面交互要单独设计

PC 版不是"把 iPad 拉宽"，必须补：悬停高亮、右键菜单、键盘快捷键（`Ctrl+N/F/Z`）、多窗口。

### 纪律 5：状态只进 SQLite，内容只进 Markdown

见 §3 铁律。

### 纪律 6：`json_serializable` / `drift` 等 codegen 一律提交生成产物

避免协作者和新机器需要重跑 build_runner 才能编译。

---

## 6. 关键风险与对策

| 风险 | 概率 | 影响 | 对策 |
|---|---|---|---|
| **知识点本体建不完** | 高 | 致命 | M0 先用**数学一**跑通，数二数三后补；一个章节一个章节推进 |
| **公式识别准确率不达标** | 中 | 高 | M4 前先做实验：30 张真实题目测 2–3 家 API，拿到基线再定方案 |
| **录入超过 60 秒** | 中 | 高 | 砍掉非必要步骤；错因选择改事后批量补 |
| **标注准确率 < 80%** | 中 | 中 | 加 RAG 召回 + few-shot；仍不行则改为"给 3 个候选让用户选" |
| **列表公式渲染掉帧** | 中 | 中 | 必须做渲染缓存 + `RepaintBoundary`（M5 验收项） |
| **Markdown 解析崩溃** | 低 | 高 | 宽容解析 + 降级：frontmatter 坏了也要能读出题目 |
| **MinerU 解析质量差** | 中 | 中 | 先用图片导入跑通，PDF 作为增强 |

---

## 7. 验收总表

V1 完成必须全部满足：

- [ ] 手工放一个 `.md` 到 `problems/`，启动 App 能自动建索引并显示
- [ ] 用公式键盘输入一个含积分、分式、上下标的公式 ≤15 秒
- [ ] 从图片识别一道题，得到可编辑的 LaTeX，整体 ≤60 秒完成入库
- [ ] 100 道真题自动标注，Top-1 知识点准确率 ≥80%
- [ ] 录入 50 题后，复习队列连续 7 天正确生成
- [ ] 错题本列表 5000 题滚动不掉帧（可用脚本灌数据测试）
- [ ] 组卷生成 150 分真题结构卷，题型/难度/分值约束 100% 满足
- [ ] 导出 PDF 打印清晰、公式无截断、留白足够演算
- [ ] 导出 Markdown 包，能在 Obsidian 中直接打开并正确渲染公式
- [ ] 批量导入 100 题图片，成功率 ≥85%
- [ ] 断网状态下，错题本 / 复习 / 组卷 / 导出**全部可用**
- [ ] 关闭 App 杀掉进程，重开无数据丢失

---

## 8. 目录结构（目标）

```
kaoyan-math-agent/
├── app/                                  Flutter 工程
│   ├── lib/
│   │   ├── main.dart
│   │   ├── core/
│   │   │   ├── layout/                   断点系统
│   │   │   ├── math/                     MathRenderer 抽象 + katex 实现
│   │   │   ├── platform/                 ★ 平台抽象层
│   │   │   │   ├── ocr_service.dart
│   │   │   │   ├── image_source_service.dart
│   │   │   │   ├── notify_service.dart
│   │   │   │   └── secure_store.dart
│   │   │   ├── theme/
│   │   │   └── db/                       Drift schema + migration
│   │   ├── data/
│   │   │   ├── markdown/                 ★ 解析器 + 序列化 + 原子写
│   │   │   ├── index/                    ★ 索引构建 + FTS5
│   │   │   └── repositories/
│   │   ├── domain/                       纯 Dart 业务逻辑
│   │   │   ├── fsrs/                     FSRS 调度
│   │   │   ├── composer/                 组卷引擎
│   │   │   ├── fingerprint.dart          去重指纹
│   │   │   └── latex_normalizer.dart
│   │   ├── services/
│   │   │   ├── llm/                      LLM 客户端（多 provider）
│   │   │   ├── tagger/                   知识点标注
│   │   │   ├── ingest/                   批量导入
│   │   │   └── render/                   PDF 导出
│   │   └── features/
│   │       ├── home/  capture/  book/  review/  paper/
│   │       ├── import/  profile/
│   ├── windows/
│   └── test/
├── data/                                 ★ 知识资产（随包分发）
│   ├── knowledge_points/
│   │   ├── math1.json
│   │   ├── math2.json
│   │   └── math3.json
│   ├── error_causes.json
│   ├── exam_frequency.json
│   └── exam_templates.json
├── tools/
│   ├── mineru-pack/                      PC 端题库解析（Python，V2）
│   └── seed-builder/                     种子题库打包
└── docs/
    ├── V1_PLAN.md                        ← 本文档
    ├── DATA_FORMAT.md                    Markdown 题目格式规范
    ├── ARCHITECTURE.md
    └── SETUP.md                          环境搭建
```

---

## 9. 第一个 Sprint（M0 + M1，9 天）

| 天 | 任务 | 产出 |
|---|---|---|
| D1 | 知识点本体 schema 定稿 + 数学一「极限与连续」整章 | `data/knowledge_points/math1.json` 第一版 |
| D2 | 错因词表 + 考频数据 | `error_causes.json`、`exam_frequency.json` |
| D3 | Markdown 题目格式规范 + 样例 | `DATA_FORMAT.md` + 3 个样例 .md |
| D4 | 数学一剩余章节知识点 | `math1.json` 完整 |
| D5 | 数二/数三知识点（或降级为"后补"） | `math2.json` / `math3.json` |
| D6 | Flutter 工程初始化 + 平台抽象层 + 断点系统 | 能跑起来、能切布局 |
| D7 | `MathRenderer` 抽象 + katex 集成 + 主题 | 公式能渲染、设计 token 落地 |
| D8 | Drift schema + 迁移机制 | 建表脚本可跑 |
| D9 | Markdown 读写 + 索引构建 | 放一个 .md 进去能读到并建索引 |

**D9 结束时，M2 完成度约 60%**，可以立刻接 M3 标注引擎。

---

## 10. 变更控制

本计划一旦开工：

- **新功能一律进 V2 backlog**，不进 V1
- 只有两种改动允许：① 发现验收标准不可达；② 发现技术方案有硬伤
- 每次改动记录在本文档末尾的变更日志

### 变更日志

| 日期 | 变更 | 原因 |
|---|---|---|
| 2026-03-15 | 初版 | — |
