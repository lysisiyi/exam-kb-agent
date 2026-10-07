# 研伴 V3 · 开发交接文档

> 写给下一个接手开发的 agent。**先读完这份再动代码。**
> 更新时间：2026-10-07（题库全量重扫收口后）。当前测试基线：**1175 全绿**、`flutter analyze` 零输出、Release 构建通过。
>
> ⚠️ **仓库事实源：`kaoyan-math-agent`（唯一开发源）。** `D:\agent\workspaces\study_V3`
> 是它的镜像副本（在那里 `git fetch origin && git reset --hard origin/main` 同步即可），
> **不要在那里开发**——曾双源并行造成一次分叉丢码。
> Windows Git Bash 环境下，**任何写操作前先 `pwd`**，写文件一律绝对路径（cwd 曾在双仓间漂移，把文件写进镜像仓）。

---

## 0. 一句话现状

「研伴」（D:\agent\workspaces\kaoyan-math-agent）是一个 **Flutter Windows 桌面应用**，定位
「本地优先的考研网课学习伴侣」：看网课时桌宠伴学自动记笔记 → 生成练习 → 练错的题进
FSRS 复习闭环，知识库是可编辑的 Obsidian 式 md 树。

**V3 计划（P0–P5 / K1–K3 / D1–D17）功能项已全部落地**：骨架换肤、截图笔记管道、
知识库 Markdown 事实源 + 树编辑器 + 建库向导 + AI 梳理、练习生成三轨与 lesson runner、
B 站字幕轨、桌宠窗口/托盘/换皮、笔记 Obsidian 化。

**2026-10-07 完成题库全量重扫**：1800 → **2774 题**（+974）。切题器修了四类根因
（两本从未切过的书、inline 阈值 bug、wzx 双版式/双栏、前置页污染），App 索引已重建
（「新增 976 / 更新 1597 / 移除 2 / 失败 0」）。

**剩余**：只有真机验收（§5.1，需作者上机）与一项已知遗留（§5.2 图片题锚点断层）+ 技术债（§5.3）。
没有待开发的功能项——**新需求来了从 §2 的纪律和 §3 的地图起步**。

## 1. 读文档的顺序

| 文档 | 内容 |
|---|---|
| 本文件 | 现状、纪律、代码地图、踩坑录、剩余清单 |
| `docs/PROGRESS.md` | **唯一可信的进度台账**（新条目在文件末尾）。历史决策与每次提交的证据都在这里，遇到"为什么这么做"先查它 |
| `docs/V3_PLAN.md` | V3 总方案：P0–P5 阶段、D1–D17 决策记录 |
| `docs/V3_KB_PLAN.md` | 知识库 2.0 专项：K1–K3 阶段、D13–D16 |
| `docs/design/ui/ui_mockups.html` + 六张 png | UI 参考图（实施以图为准） |
| `docs/DATA_FORMAT.md` / `docs/SETUP.md` | 数据格式约定 / 本机构建环境（镜像、代理） |

## 2. 工作方式（必须遵守）

1. **每个增量**：改代码 → `cd app && flutter analyze`（必须零输出）→ `flutter test`
   （必须全绿，基线 **1175**）→ `git commit` → 往 `docs/PROGRESS.md` 追加一行台账
   （含提交号/测试数/踩坑）。→ 推送后同步镜像仓。
2. **不静默降级**：读不出、解析失败、能力不支持——一律如实报错并给用户出路；
   绝不把失败渲染成"看起来正常的空态"。
3. **Markdown 是事实源，SQLite 只是派生索引**。题目 `library/problems/*.md`、课时
   `library/courses/*.md`、知识库 `library/knowledge/**/*.md` 均如此。索引坏了就重扫。
4. **BYOK**：所有 AI 调用走用户自己的 Key（`services/llm/provider_registry.dart` 预置 11 家）；
   默认走免费档（智谱 glm-4.6v-flash 视觉）。
5. **不内置版权题库**：练习=题库匹配+AI 原创题+用户手动导入。扫描入本地库是"用户的教材用户自己扫"。
6. **先量再改**：性能/额度相关的改动先做测量或写可验证的验收标准（本次重扫就是先离线
   重放 `find_anchors` 量化了 150+ 被拒真题才动手）。
7. **不动 FSRS 数学**（`domain/fsrs/fsrs_scheduler.dart`，已与 py-fsrs 对拍，测试守着）。
8. **非 ASCII 内容不用 PowerShell Get-Content/Set-Content**——用 Read/Write/Edit 工具或
   Python 显式 `encoding='utf-8'`（T36 规则）。
9. 测试是**闸门**不是形式：`knowledge_size_test`（只允许 w400/w700）、`knowledge_palette_test`
   （白底 ≥4.5:1）、`llm_pricing_test`、`shell_navigation_test` 拦下你是正常的，改代码适配
   而不是改断言放水（除非断言本身假设过时——如 `.first` 定位，此时换具名 key）。
10. **改完外部数据（题库/知识库）必须走验证**：切题产物三件套一致性（§7.3）、启动 App
    看 startup.log 的索引同步行、必要时直接查 `.index/index.sqlite`。

## 3. 代码地图

```
app/lib/                            # 约 115 个 dart 文件
├── main.dart                       # 入口；多窗口分流（arguments=='pet'→PetWindow）
├── dev_shell.dart                  # 导航清单（6 项：学习台/网课/复习/知识库/画像/设置）+ 侧栏页脚
├── core/
│   ├── providers.dart              # ★ Riverpod 根：所有数据源入口（改数据先看这）
│   ├── theme/app_theme.dart        # 手账风 token（暖白 #FAF7F2 / 焦糖橙 #BA5614）
│   ├── math/{katex_renderer,math_renderer,latex_text_split}.dart  # 公式渲染
│   ├── platform/                   # capabilities/OCR stub/安全存储/启动日志
│   └── widgets/{adaptive_shell,page_header,state_views}.dart
├── pet/{pet_window,pet_service,pet_tray}.dart   # 桌宠窗口/气泡通道/托盘（0.5.0 API）
├── data/
│   ├── knowledge_md/knowledge_md_store.dart     # ★ 知识库读写核心（树/编辑/笔记回流/AI 草稿）
│   ├── db/{database,tables}.dart                # Drift schema（当前 v7，cover_image）
│   ├── index/index_builder.dart                 # library → problems_index 扫描器
│   ├── markdown/problem_store.dart              # 题目事实源（md）
│   └── knowledge/knowledge_repository.dart      # 旧 JSON 加载（种子模板）
├── domain/{fsrs,knowledge,paper,fingerprint,...}  # 纯模型与算法（不改）
├── services/
│   ├── companion/{course_store,screen_capture,note_llm,bilibili_client,subtitle_notes}.dart  # 伴学管道
│   ├── llm/{llm_client,provider_registry,robust_json,llm_stream}.dart   # BYOK
│   ├── tagger/ chat/ paper/ practice/ review/ profile/ knowledge/       # 各业务服务
│   └── paper/paper_repository.dart              # 练习留痕（config.kind='lesson_practice'）
└── features/  # dashboard / courses / knowledge(★) / problems / review /
               # practice(lesson_runner) / paper / entry / ingest / settings / profile / chat
```

### 数据地图（用户机器上的真实位置）

```
C:\Users\<user>\AppData\Roaming\com.kaoyan\kaoyan_math_agent\library\
├── problems\*.md        # 题库事实源（2774 题：6 本教材 2573 + self-* 自创 201）
├── images\*.png         # 题面图（文件名 = qid.png，md frontmatter 里 images: images/<qid>.png）
├── courses\*.md         # 课时 + 笔记（覆盖写入）
├── knowledge\<科目>\    # 知识库的 Obsidian 式 md 树（一个考点一个 md）
├── .index\index.sqlite  # Drift 派生物：problems_index + FTS + 复习状态 + 练习留痕
└── startup.log          # 每次启动的能力探测 + 索引同步结果（排查第一现场）
```

## 4. 已完成（可验证）

| 阶段 | 内容 | 证据 |
|---|---|---|
| P0 | 导航重组（8→7）、手账风换肤、学习台/网课页 | 台账 2026-10-04 起 |
| P1 | 截图笔记管道（框选→定时/热键截→aHash 跳帧→glm-4.6v-flash→指纹去重→课时 md） | `services/companion/` |
| K1 | 知识库 Markdown 事实源（Obsidian 式，id 稳定、幂等导入、坏文件宽容） | `knowledge_md_test.dart` |
| K2 | 树编辑器（增删改/拖拽换父/同级重排 order/AI 补全/笔记回流/建库向导/AI 梳理一键应用） | 台账 10-05 |
| P3 | 练习三轨 + lesson runner 自主判分 + recordWrong 进 FSRS + 练习落 papers | `lesson_practice_record_test.dart` |
| P2c | 托盘（tray_manager **钉 0.5.0**）、全局热键、换皮（10 只立绘）、✕=退出定案 | 台账 10-05 |
| P4 | B 站字幕轨（BV→cid→CC 字幕→5 分钟分窗→带时间戳笔记） | 待真机 SESSDATA 实测 |
| 图片题面 | `problems_index.cover_image`（v7 迁移"清空重扫"）+ 错题本行/组卷预览以图当题面 | 51d7c95 |
| **题库重扫** | **1800 → 2774 题**；切题器四类根因修复 + `_stitch` 跨页拼接 + 导入脚本 | 3efe404，索引「新增 976 / 更新 1597 / 移除 2 / 失败 0」 |

## 5. 剩余清单

### 5.1 真机验收（**只有作者本人能做的**，代码侧无法验证）

1. 桌宠：三键交互手感（左键菜单/右键动画/中键截图）、置顶/透明/拖拽。
2. 托盘：图标可见性、✕=正常退出（定案，不再拦截）。
3. P1 截图管道实跑：黑帧探测、免费档频控阈值。
4. B 站字幕轨：需作者填一次 SESSDATA（设置页），跑一节带 CC 的课。
5. 知识库新排版（手账风详情卡）观感。
6. **题库重扫产物**：错题本列表以图当题面在 2774 题下的滚动性能；随机抽几本新扫的题
   （1800gd/wzx）看图面质量；练习生成时新题能否被 FTS 匹配到。

### 5.2 已知遗留：图片题锚点断层（可选精修，不紧急）

zy1000 约 50 处、1800xd 约 9 处的**纯公式/图片页**题号本身印在图里，OCR 读不出文字
→ 该页内容已并入前一题的图（**内容不丢，少一个题号条目**）。如需补切：检测"同页相邻
锚点间 y-gap 异常大"或"跨页题号跳号"，把断层区域切为独立题（qid 用插值猜测并标注
"疑似缺题号"）。zy1000 882 vs 名义 1000 题的差值主要来自这里。

### 5.3 技术债

- `test/ingest_draft_test.dart` 在**全量跑**时偶发失败（单跑必绿，疑顺序耦合/临时目录冲突）。
- 知识库笔记还没有 FTS（`knowledge_fts` 在 V3_KB_PLAN 里规划，K1 只做了 md 数据层）。
- `problems→节点归档`：题目挂在 `problem_knowledge` 表（旧 JSON 考点 id，K1 保 id 所以不丢）。
- 跨页题 `_stitch` 只处理"整页无锚点"的延续；同页顶部的小延续段（<30pt 起判）仍会被
  丢弃（数量极少，见 split_pdf.py `split_page` 的 cont 逻辑注释）。

## 6. 踩坑录（硬知识，省你几个小时）

### 6.1 切题器 / 数据处理（2026-10-07 重扫新增）

| 坑 | 表现 | 解法 |
|---|---|---|
| **阈值型 bug** | `len(rest) > 4` 本意挡小数假锚点，却把「7.求lim」「15.曲线」这类真题干全挡掉（3 本书 150+ 题） | 假锚点的特征是**首字符是数字**，不是短。改 `_inline_rest_ok`：非数字开头即题干。修前先用 cache 离线重放 `find_anchors` 量化影响面 |
| **前置页判据** | ①封面/目录被当"上一题延续"挂给下一页首题→题图从页顶切、文本混入目录 ②封面裸数字「1700」被 workbook 规则当题号产假题 | `_is_front_matter`：`pno==0` 无条件 + 前 6 页内查版权/目录实词，整页跳过。⚠️ 判据**不要**含水印词（关注公众号/免费考研）——正文页页脚也有；判据**不要**放宽到 `pno<2`——曾误杀 wzx 正文首页丢 8 题 |
| **目录判据要计数** | 「第…章/节」单次命中就判目录 → 正文页里的章节标题（「第一章」「第一节函数」）把整页误杀 | 章节标题 ≥3 行才算目录页 |
| **双栏排版负高度** | 讲义同页左右两栏锚点 y 相同 → `next.y - 4` 算出负高度 region，产出 9 个空条目 | y_end 取下一个**真正更靠下**（+8pt）的锚点；本栏图右界收在同高右邻锚点左侧 |
| **qid 覆盖** | 例号在题型内重启 → 同页两个「例 1」互相覆盖，stats 报 297 只落 264 个文件 | 命名键必须保证唯一：wzx 的 qid 改**页内序号**，例号写进 `source` 字段保留 |
| **坐标混用** | 跨页拼接写成 `min(pbox[0], rb[1])`（拿上页 x0 当本页 y0）——像素实际被丢，只并了文本 | 跨页拼接用 PIL 真拼（`_stitch`），跨页 bbox 合成在物理上无意义 |
| **OCR 缓存是资产** | 重切 617 页以为要重跑 OCR | `cache/page_NNN.json` 断点续跑：改切分逻辑不用重 OCR，重切全量秒级；**但改完规则要全量重切所有书**（新旧规则产物混用会让数字对不上），重切前 `rm -rf <tag>/{problems,images,index.jsonl,stats.json}` 防孤儿残留 |
| **三件套一致性** | 切完不知道对不对 | 校验：`stats.questions == md 数 == png 数`（差值应恰为 cont 图数）；入库后再用导入脚本 `--dry-run` 对账 |

### 6.2 工程通用（此前累积）

| 坑 | 表现 | 解法 |
|---|---|---|
| bash heredoc 转义 | python SyntaxError / `\a` 变响铃 / Dart 字符串被**真换行**破坏 | 写文件用 Write 工具；改代码用 Edit；给 Dart 生成补丁脚本时凡是要产出 `\n` 两字面量的地方**必须 `chr(10)`/`chr(92)` 构造** |
| 双仓 cwd 漂移 | 相对路径 `cat >` / python 把文件写进 study_V3 镜像仓（发生过多次） | 写操作前 `pwd`；一律绝对路径；发现写错 `mv` 回事实源 |
| Dart `$$` 插值 | `'$$'` 编译错 "A '$' has special meaning" | 用 `r'$$'`（写 md 公式块必踩） |
| Dart RegExp 无 `\Z` | 正则永不匹配或报错 | 改行扫描（见 `knowledge_md_store` 的 section()） |
| `desktop_multi_window` 0.3.x | 网上教程全失效：无 `close/startDragging/setFrame` | 每个引擎跑同一份 `main`，`fromCurrentEngine().arguments` 分流；窗口形态交给 `window_manager` |
| `tray_manager` 0.7 | `TrayManager` 方法全 undefined | 0.7 的 barrel 与 nativeapi **导出同名类冲突**；**钉 0.5.0 经典 API**（`trayManager` 单例 + `TrayListener`），`setIcon` 收资产相对路径 |
| `screen_capturer` | 截图会**清空并劫持剪贴板** | `copyToClipboard: false`；`CaptureMode.screen` 要 `sc.` 前缀 |
| Row 的非 flex 子项 | 拿到**无界主轴约束**：Text 按自然宽度排版、ellipsis 永不生效，窄栏必溢出 | 需要压缩的文本一律 `Flexible` 包住 |
| ExpansionTile 墨迹断言 | 内部是 ListTile，其上方必须有 Material；被 DecoratedBox 卡片包住触发"墨迹不可见" | 卡片里放 ExpansionTile 时套 Material |
| 测试 settle 时机 | 默认 160ms < ExpansionTile 展开动画 200ms，收起断言假失败 | `pumpAndSettle` 带 `frames:20` 或用显式时长 |
| 校验器空判 | "0 孤儿"在全 null（生成器漏 parent_id）时**空判通过**，界面却是平树 | 校验要验"有没有检查对象"（verify_kb 有扁平整树检测） |
| 脆断言 `.first` | 新增 Wrap/Widget 后抓错对象 | 加显式 `ValueKey` 后改测试定位 |
| CRLF 警告 | `warning: CRLF will be replaced by LF` | 无害，忽略 |
| 沙箱无 GUI | 截屏/窗口/多窗口全部测不了 | 真机事项列清单交作者（§5.1） |
| `flutter test` 目录 | 在仓库根跑报 "No pubspec.yaml" | 必须先 `cd app` |

### 6.3 用户预期类（血的教训）

- **关闭键（两个方向的两次翻车）**：先"拦截 ✕=缩托盘但托盘没装成"→幽灵进程；后
  "托盘装成了仍拦截"→用户仍报失效。**最终定案：✕ 永远是正常退出，任何情况不拦截；
  "隐藏到托盘"是托盘菜单的显式选项。** 教训：替代路径齐备也不够，**用户的预期才算数**。
- **`appendLessonNote` 只返回不落盘**：HEAD 里是纯函数，唯一调用方丢失后归档静默无效。
  教训：写盘函数**在类内直接写**，别设计成"返回内容由调用方写"。
- **双源并行开发**曾造成分叉丢码（K2 归档 UI 在跨仓复制中丢失过）。镜像仓只 pull，不开发。

## 7. 工具链与命令速查

### 7.1 日常

```bash
cd app && flutter analyze          # 必须零输出
cd app && flutter test             # 必须全绿（1175）
run_app.bat                        # Release 构建 + 中国镜像启动（仓库根）
git push → cd ../study_V3 && git fetch origin && git reset --hard origin/main   # 同步镜像
```

### 7.2 题库切题器 `tools/pdf_splitter/split_pdf.py`

```bash
python tools/pdf_splitter/split_pdf.py --tag <tag>           # 全量（缓存命中则秒级）
python tools/pdf_splitter/split_pdf.py --tag <tag> --start 0 --end 8   # 调试样页
```

- **源 PDF**：`D:/study/数学/考研数学教材参考/`（BOOK_DEFAULTS 里六个 tag 的绝对路径；
  换机器/换书要改这里。⚠️「660 高数」文件名 `.pdf` 前有一个空格是真实的）。
- **输出**：`D:/study/数学/考研数学教材参考/split_out/<tag>/{problems,images,cache,index.jsonl,stats.json}`。
- **版式**：`worksheet`（张宇，题号+题干同行）/ `workbook`（660 做题本，裸数字红块）/
  `landscape`（1800 Ipad 版）/ `wzx`（武忠祥：讲义页 `【P7例2】` + 书末附真题页普通题号**按页分流**）。
- 依赖：`pymupdf` + `rapidocr_onnxruntime` + `pillow`（Git Bash 的 `python` 指向
  `C:\Users\yifuc\.agent-reach-venv`，`pip install` 装那里）。
- 重切前：`rm -rf split_out/<tag>/{problems,images,index.jsonl,stats.json}`（**保留 cache**）。
- 质量校验：`stats.questions == md 数 == png 数`（差 = cont 图）；另可跑
  `tools/pdf_splitter/audit_pages.py`、`analyze_layout.py` 查版式。

### 7.3 题库入库 `tools/data/import_split_to_library.py`

```bash
python tools/data/import_split_to_library.py --dry-run   # 先对账
python tools/data/import_split_to_library.py             # 覆盖式导入（安全：旧库 qid 是新产物子集）
python tools/data/import_split_to_library.py --prune     # 版本升级后清孤儿（删本 tag 前缀、新产物没有的 md/png）
```

导入后**启动一次 App**（索引会重建）→ 看 `library/startup.log` 的「启动索引同步：
新增 N / 更新 M / 移除 K（失败 0）」→ 必要时核对数据库：

```bash
python -c "
import sqlite3
db = r'C:/Users/yifuc/AppData/Roaming/com.kaoyan/kaoyan_math_agent/library/.index/index.sqlite'
con = sqlite3.connect(f'file:{db}?mode=ro', uri=True)
print(con.execute('SELECT COUNT(*) FROM problems_index').fetchone()[0])
"
```

### 7.4 知识库工具

- 生成器：`tools/data/build_kb_from_outline.py`（缩进大纲 → md 树；章下全叶子自动补节；
  ⚠️ parent_id 必须写，曾漏写导致平树且"0 孤儿"空判）。
- 校验器：`dart run app/tool/verify_kb.dart <knowledge/子目录>`（父子完整、扁平整树检测）。
- AI 骨架/梳理：`services/knowledge/kb_outline_writer.dart`、`kb_review_writer.dart`。

### 7.5 资产与设计

- 桌宠立绘：`docs/design/pet/providers/<服务商id>.png`（10 张透明底）+ `app/assets/pets/`；
  裁切脚本 `python tools/design/make_provider_pets.py`。
- UI 参考图重渲：改 `docs/design/ui/ui_mockups.html` → 无头 Chrome
  `--window-size=1280,5040 --screenshot=_full.png`（**不要用内置浏览器 fullPage**，本机有拼接伪影）
  → `python tools/design/split_mockups.py`。
