# 考研数学错题 Agent

> 面向考研数学的 AI 错题分类管理工具。
> **Windows 桌面版 V1 开发中**，架构预留 Android / iPadOS / macOS / iOS 扩展位。

---

## 这个项目要解决什么

市面上的错题 App 都在做「整理得漂亮」，但考研党真正的问题是**这些题以后还会错**。

本项目的立足点：

| 竞品的做法 | 本项目的做法 |
|---|---|
| 拍照 → 给答案 | 拍照 → **记录你为什么错** → 按错因开处方 |
| 标签由 AI 自由生成 | **受控知识点词表**，AI 只能从 400+ 个知识点里选 |
| 按知识点统计错题数 | **六维错因 × 考频权重**，区分"不会"和"算错" |
| 组卷靠随机抽题 | **真题结构 + 薄弱点加权 + 考频软偏好** |
| 数据锁在服务器 | **Markdown 存盘**，用户能用 Git 管理、能迁移到 Obsidian |

**核心闭环**：录入一道错题（≤60 秒）→ AI 打标 → 进错题本 → FSRS 按遗忘曲线提醒复习 → 攒够了出一份针对性检测卷。

**V1 只需要证明一件事**：用户录完第一道题之后，**会想录第二道题**。

---

## 当前状态

> 详细进度见 **[`docs/PROGRESS.md`](docs/PROGRESS.md)**

| 里程碑 | 状态 |
|---|---|
| M0 地基（知识资产 + 格式规范） | 🟢 完成 |
| M1 项目骨架（抽象层 + 断点 + 主题） | 🟢 完成 |
| M2 数据层（Drift + Markdown + 索引） | 🟢 完成 |
| M3 标注引擎（LLM + 召回 + 评测） | 🟡 召回率 **91.7%** 已达标；LLM Top-1 待实跑 |
| M4 录入闭环（公式键盘 + 编辑页 + 错因 + 保存） | 🟢 主流程完成（图片识别按计划不做） |
| M5–M8 | ⚪ 未开始 |

```
flutter test    → 310 个用例全绿
flutter analyze → 0 error / 0 warning
```

### 知识资产覆盖

| 科目 | 可考查单元 | 叶子节点 | 状态 |
|---|---|---|---|
| 数学一 | 19 | 198 | 🟢 覆盖完整（含 28 组已去重冗余） |
| 数学二 | 12 | 60 | 🟢 完成 |
| 数学三 | 42 | 71 | 🟢 完成 |

> ⚠️ 本体仍有约 25% 近义/重复叶子（技术债 T19）。它**不影响召回率**
> 但会拉低 LLM 的 Top-1 准确率 —— 详见 `docs/PROGRESS.md`。

### 代码规模

```
app/lib     45 个文件   11500+ 行
app/test    10 个文件   5800+ 行   （295 个用例，全部通过）
```

### 召回率是怎么测的（重要）

四个金标准集角色分离，**引用数字时用最后一个**：

| 文件 | 题数 | 角色 | 实测 |
|---|---|---|---|
| `data/eval/gold_set.json` | 15 | 开发集（调参时一直看它） | 100% |
| `data/eval/gold_set_holdout.json` | 25 | 留出集（已用它诊断过，**污染**） | 96% |
| `data/eval/gold_set_final.json` | 15 | 第一次独立验证 | 100% |
| **`data/eval/gold_set_verify.json`** | 12 | **对外报数** | **91.7%** |

在同一个集合上反复调参会把它变成训练集。新增验证集时**不要回头改别名再跑** ——
那样它立刻退化成开发集。

---

## 快速开始

### 1. Flutter（已装好）

`D:\software\flutter`（3.47.4 stable），国内镜像 `FLUTTER_STORAGE_BASE_URL` /
`PUB_HOSTED_URL` 已配，`windows/` 脚手架与 sqlite3 原生库均已就绪。

> ⚠️ **唯一剩下的环境阻塞**：`flutter build windows` / `flutter run -d windows`
> 需要 **Windows 开发者模式**（插件走符号链接）。
> `flutter test` / `flutter analyze` **不需要**。
>
> ```powershell
> start ms-settings:developers
> ```
>
> 详见 **[`docs/SETUP.md`](docs/SETUP.md)** §5。

### 2. 同步知识资产

Flutter 不允许 `pubspec.yaml` 引用应用目录之外的路径，所以 `data/` 需要同步到
`app/assets/data/`：

```powershell
python tools/data/sync_assets.py
```

> ⚠️ **改完 `data/` 后必须重新同步**，否则 App 读到的还是旧数据。
> 改过**知识点名称**还要先重跑 `gen_aliases.py`（见"常用命令"）。

### 3. 跑起来

```powershell
cd app
flutter pub get
flutter test          # 295 个用例
flutter analyze       # 0 error / 0 warning
flutter run -d windows   # 需先开开发者模式
```

---

## 目录结构

```
├── app/                              Flutter 工程
│   ├── lib/
│   │   ├── core/
│   │   │   ├── layout/               断点系统（4 档，替代"按设备判断"）
│   │   │   ├── math/                 MathRenderer 抽象 + 渲染缓存
│   │   │   ├── platform/             平台能力抽象（OCR/图片/通知/安全存储）
│   │   │   ├── theme/                设计 token（与 UI 原型一致）
│   │   │   └── widgets/              自适应导航外壳
│   │   ├── data/
│   │   │   ├── markdown/             题目 Markdown 宽容解析器
│   │   │   ├── db/                   Drift schema（6 表 + FTS5 + 触发器）
│   │   │   └── index/                增量索引 + 中文全文检索
│   │   ├── domain/
│   │   │   ├── fsrs/                 FSRS-6 调度器（纯 Dart）
│   │   │   ├── fingerprint.dart      题目去重指纹
│   │   │   └── knowledge/            知识点模型（含 aliases）
│   │   ├── services/
│   │   │   ├── llm/                  服务商注册表 + 客户端 + 稳健 JSON + BYOK 配置
│   │   │   ├── tagger/               召回 + Prompt + 判定 + 评测器
│   │   │   └── library/              录入闭环：草稿 → 落盘 → 刷索引
│   │   └── features/
│   │       ├── knowledge/            知识库三级树
│   │       └── entry/                录入页 + 公式键盘 + 考点选择器
│   ├── test/                         单元测试（295 个用例）
│   └── tool/
│       └── recall_lab.dart           召回实验台（快速看每题失败细节）
│
├── data/                             ★ 知识资产（单一事实源）
│   ├── knowledge_points/             知识点本体（math1/2/3）
│   │   └── alias_overrides.json      人工维护的符号别名
│   ├── error_causes.json             错因受控词表（6 类 + 处方）
│   ├── exam_frequency.json           考频数据（三科 72 单元 / 282 热点）
│   ├── exam_templates.json           组卷模板
│   └── eval/                         四个金标准集（角色见上文）
│
├── tools/
│   ├── data/
│   │   ├── sync_assets.py            资产同步到 app/assets/
│   │   ├── merge_shards.py           多分片合并 + 覆盖缺口报告
│   │   ├── merge_knowledge.py        合并分片 + 派生 exam_weight
│   │   ├── merge_frequency.py        考频分片合并 + 重新归一化
│   │   ├── dedupe_knowledge.py       冗余知识点去重（白名单制）
│   │   ├── gen_aliases.py            生成召回别名（幂等）
│   │   ├── kp_probe.py               知识点条目速查
│   │   └── knowledge_tree.py         从树结构推导章节清单
│   ├── lint_dart.py                  Dart 静态自检（无 Flutter 时替代 analyze）
│   └── setup_windows.py              环境自举
│
├── docs/
│   ├── V1_PLAN.md                    ★ 开发计划（范围/里程碑/纪律/风险/验收）
│   ├── DATA_FORMAT.md                ★ 题目 Markdown 格式契约
│   ├── SETUP.md                      环境搭建
│   └── PROGRESS.md                   进度台账
│
└── ui-mockups/
    ├── index.html                    手机版 5 屏高保真原型
    └── ipad.html                     iPad 版 5 屏 + 适配规则
```

---

## 核心技术决策

### 1. 纯本地架构，零服务器

最重的计算（LLM 推理、公式识别）走**云端 API + 用户自己的 Key**：

- 服务器成本 **¥0**，运维成本 **¥0**
- 用户数据 100% 留在本机（隐私卖点）
- 无备案、无合规负担
- **AI 挂了产品不能挂** —— 错题本 / 复习 / 组卷 / 导出必须 100% 离线可用

### 2. 双层存储：Markdown 存内容，SQLite 存状态

```
题目内容  →  Markdown 文件（人类可读、可 Git、可迁移到 Obsidian）
用户状态  →  SQLite（高频写、需事务）
查询加速  →  SQLite FTS5 索引（可从 Markdown 全量重建）
```

> **铁律：绝不把用户状态写进 Markdown。**
> 一旦 `wrong_count` / `fsrs_state` 落进 `.md`，会同时陷入「高频重写文件」和「索引无法重建」两个坑。

### 3. `exam_weight` 统一算法

早期知识点文件与考频文件用了两套公式，已统一：

```
章节级（权威 = data/exam_frequency.json）
    raw     = total_appearances × avg_score
    chapter = round(raw / max(raw), 2)

叶子级（tools/data/merge_knowledge.py 派生）
    leaf = clamp(chapter × hotspot_boost × year_factor, 0.10, 1.00)
```

### 4. 章节解析沿 `parent_id` 向上找，不按段数硬切

| 科目 | 层级深度 |
|---|---|
| 数学一 | `math1 → calc → limit → 叶子`（4 段） |
| 数学三 | `math3 → calc → limit → 节 → 叶子`（5 段） |

且**必须限定同一学科前缀** —— 否则 `math3.prob.limit`（大数定律）会错配到
`math3.calc.limit`（极限）。

### 5. 知识点带 `aliases`（召回别名）

召回层是纯规则的，靠字面重合。而知识点名往往是复合短语、题干只写符号：

```
知识点名：正态分布及其标准化计算
题干：    设 $X\sim N(0,1)$，求 $P\{|X|<1\}$
```

两边没有任何共同子串 → 规则层完全匹配不上 → 正确答案进不了候选集 → LLM 再强也没用。
`aliases` 就是把知识点名"翻译"成题干可能的样子：

| 来源 | 例子 | 生成方式 |
|---|---|---|
| 名称片段 | 「单调性、极值与最值」→ 极值 / 最值 | `gen_aliases.py` 自动派生 |
| 符号写法 | `X\sim N(\mu,\sigma^2)` / `\iint_D` | `alias_overrides.json` 人工维护 |

含反斜杠的走公式 token 匹配，其余走文本包含匹配。
**实测把召回率从 73.3% 提到 91.7%**（见上文评测表）。

### 6. 平台能力走抽象接口

`OcrService` / `ImageSourceService` / `NotifyService` / `SecureStore` 四个接口，
V1 只实现 Mock + Windows。加 Android/iOS/macOS 时只补实现，不改调用方。

### 7. UI 按宽度断点，不按设备判断

```dart
LayoutBreakpoint bp(double w) {
  if (w < 600)  return compact;   // 手机竖屏
  if (w < 900)  return medium;    // 手机横屏
  if (w < 1200) return expanded;  // iPad 竖屏 / Split View
  return large;                    // PC / iPad 横屏
}
```

**绝不写 `if (Platform.isAndroid)` 来决定布局** —— Windows 窗口拖窄、iPad 分屏时会崩。

---

## 常用命令

```powershell
# 同步知识资产（改完 data/ 必跑）
python tools/data/sync_assets.py

# 检查资产是否已同步（CI 用）
python tools/data/sync_assets.py --check

# 合并多分片知识点 + 报告覆盖缺口
python tools/data/merge_shards.py --dry-run

# 派生 exam_weight
python tools/data/merge_knowledge.py --subject math1 --check

# 生成召回别名（幂等；改过知识点名之后必跑）
python tools/data/gen_aliases.py --all
python tools/data/gen_aliases.py --all --check    # 自检：应为 0 处待更新

# 找冗余知识点（只提示，不删除）
python tools/data/dedupe_knowledge.py --suggest
python tools/data/dedupe_knowledge.py --review    # 打印候选对的完整内容

# 查某个知识点的名称/定义/公式/陷阱（补别名时用）
python tools/data/kp_probe.py math1.prob.rv1.normal_distribution

# Dart 静态自检（无 Flutter 时替代 flutter analyze）
python tools/lint_dart.py

# 测试与运行
cd app
flutter test
flutter run -d windows

# 召回率快速实验台（比 flutter test 快，能看每题失败细节）
cd app
dart run tool/recall_lab.dart --misses --candidates 5
dart run tool/recall_lab.dart --set gold_set_verify --rank
```

---

## 参考的开源项目

| 项目 | 借鉴点 |
|---|---|
| [ruoshui03/kaoyan-PinPaper](https://github.com/ruoshui03/kaoyan-PinPaper) | 题库 Markdown 结构、三版式 PDF、考频软偏好组卷 |
| [shuangzhebai/gaokao-analyzer](https://github.com/shuangzhebai/gaokao-analyzer) | OR-Tools 组卷、IRT 掌握度模型、FTS5 检索 |
| [chnjames/exam-forge](https://github.com/chnjames/exam-forge) | **三层验证**（沙箱 + SymPy + LLM-as-judge） |
| [open-spaced-repetition/py-fsrs](https://github.com/open-spaced-repetition/py-fsrs) | FSRS 调度算法（本项目移植为纯 Dart） |
| [opendatalab/MinerU](https://github.com/opendatalab/MinerU) | 中文学术 PDF 解析（公式→LaTeX、表格→HTML） |
| [opendatalab/UniMERNet](https://github.com/opendatalab/UniMERNet) | 数学公式识别（CDM 追平 Mathpix） |
| KnowTS（[arXiv 2406.13885](https://doi.org/10.48550/arxiv.2406.13885)） | LLM 做数学题知识点打标的方法论 baseline |

---

## 许可与声明

- **知识资产中的考频数据是估算值**，非官方逐题统计。详见
  `data/exam_frequency.json` 的 `data_confidence` 字段。UI 上展示时须标注「估算值」。
- 题库版权：本项目不内置任何受版权保护的题库。用户自行导入的资料需自行确认合规性。
