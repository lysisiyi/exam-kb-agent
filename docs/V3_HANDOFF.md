# 研伴 V3 · 开发交接文档

> 写给下一个接手开发的 agent。**先读完这份再动代码。**
> 更新时间：2026-10-05。当前测试基线：**1122 全绿**、`flutter analyze` 零输出。

---

## 0. 一句话现状

「研伴」（D:\agent\workspaces\kaoyan-math-agent）是一个 **Flutter Windows 桌面应用**，定位
「本地优先的考研网课学习伴侣」：看网课时桌宠伴学自动记笔记 → 生成练习 → 练错的题进
FSRS 复习闭环。V3 已完成 P0（骨架换肤）、P1（截图笔记管道）、K1（知识库 Markdown 事实源）、
P2a-c（桌宠窗口+气泡通道）、UI 重设计三批；**下一步主任务是 K2：知识库树编辑器**。

## 1. 读文档的顺序

| 文档 | 内容 |
|---|---|
| `docs/V3_PLAN.md` | V3 总方案：P0–P5 阶段、D1–D17 决策记录、工程默认值 |
| `docs/V3_KB_PLAN.md` | 知识库 2.0 专项：K1–K3 阶段、D13–D16 |
| `docs/PROGRESS.md` | **唯一可信的进度台账**，每次提交后追加一行（新条目在文件末尾） |
| `docs/design/ui/ui_mockups.html` + 六张 png | UI 参考图（实施以图为准） |
| 本文件 | 交接注意事项、踩坑、下一步拆解 |

## 2. 工作方式（必须遵守）

1. **每个增量**：改代码 → `cd app && flutter analyze`（必须零输出）→ `flutter test`（必须全绿，
   基线 1122）→ `git commit` → 往 `docs/PROGRESS.md` 追加一行台账（含提交号/测试数）。
2. **不静默降级**：读不出、解析失败、能力不支持——一律如实报错并给用户出路；
   绝不把失败渲染成"看起来正常的空态"。
3. **Markdown 是事实源，SQLite 只是派生索引**。题目 `problems/*.md`、课时
   `courses/*.md`、知识库 `knowledge/**/*.md` 均如此。
4. **BYOK**：所有 AI 调用走用户自己的 Key（`provider_registry.dart` 预置 11 家）；
   默认走免费档（智谱 glm-4.6v-flash 视觉）。
5. **不内置版权题库**：练习=题库匹配+AI 原创题+用户手动导入。
6. **先量再改**：性能/额度相关的改动先做测量或写可验证的验收标准。
7. **不动 FSRS 数学**（`domain/fsrs/`，已与 py-fsrs 6.3.2 数值对拍，测试守着）。
8. 测试是**闸门**不是形式：写新 UI 时被 `knowledge_size_test`（只允许 w400/w700）、
   `knowledge_palette_test`（白底 ≥4.5:1）、`llm_pricing_test`（建议模型必须估得出价）、
   `shell_navigation_test`（导航清单）拦下是正常的，改代码适配而不是改断言放水
   （除非断言本身假设过时——如 `.first` 定位，此时换具名 key）。

## 3. 代码地图

```
app/lib/
├── main.dart                      # 入口；多窗口分流（arguments=='pet'→PetWindow）
├── dev_shell.dart                 # 导航清单（6 项）+ 侧栏页脚
├── core/
│   ├── providers.dart             # Riverpod 根：knowledgeBaseProvider 等（改数据源先看这）
│   ├── theme/app_theme.dart       # 手账风 token（暖白 #FAF7F2/焦糖橙 #BA5614）
│   └── widgets/{adaptive_shell,page_header}.dart   # 导航壳（焦点隔离）/统一页头
├── pet/
│   ├── pet_window.dart            # 桌宠悬浮窗（无边框/置顶/拖拽/气泡 handler）
│   ├── pet_service.dart           # summon + sendBubble（主→宠通道）
│   └── pet_tray.dart              # 关窗缩后台策略（托盘图标待 spike）
├── data/
│   ├── knowledge_md/knowledge_md_store.dart  # ★ K1：JSON↔Obsidian 式 md 文件夹
│   ├── knowledge/knowledge_repository.dart   # 旧 JSON 加载（现为种子模板）
│   ├── markdown/problem_store.dart           # 题目事实源
│   └── db/database.dart                      # Drift schema + LibraryPaths
├── domain/knowledge/knowledge_point.dart     # KnowledgePoint/KnowledgeBase 模型
├── services/
│   ├── companion/{course_store,screen_capture,note_llm}.dart  # ★ P1 伴学管道
│   ├── llm/{llm_client,provider_registry,robust_json}.dart    # BYOK 底座
│   └── profile/mastery_service.dart          # problemsForKp + 掌握度现算
└── features/
    ├── dashboard/  courses/  # 学习台 / 网课（P1 UI：框选+伴学+笔记流）
    ├── knowledge/{knowledge_page,knowledge_home_page,knowledge_leaf_detail,
    │              knowledge_outline_view,knowledge_graph_view}.dart  # ★ K2 主战场
    ├── problems/             # 错题本（一题一卡）+ 详情抽屉
    ├── review/               # 复习（双卡手账风）
    ├── entry/ ingest/ paper/ profile/ settings/
    └── chat/                 # 对话页（已移出导航，P2 并入宠物问答后删）
```

## 4. 已完成（可验证）

- **P0**：导航重组、手账风 token 换肤、学习台/网课新页、命名「研伴」（提交 0871987 起）
- **P1**：截图笔记管道全链路——框选区域→定时/热键截屏→aHash 跳帧→glm-4.6v-flash
  结构化笔记→指纹去重→课时 md（`services/companion/`，090be1c）
- **K1**：知识库 Markdown 事实源——`knowledge/` 下 Obsidian 式文件夹（一考点一 md、
  文件夹=章节、序号前缀、科目根=_subject.md），id 原样保留、幂等导入、坏文件宽容
  （`data/knowledge_md/`，a24fe1c；测试 knowledge_md_test.dart 5 例）
- **P2a-c**：11 家服务商预设（含豆包/MiniMax/Grok）；桌宠第二窗口（0.3.x 契约、
  置顶/透明/拖拽）；主→宠气泡通道；✕=缩后台伴学不中断
- **UI 重设计**：统一页头四页；错题本一题一卡；复习页双卡；知识库页头+树状态点
  （最新：本文件同批提交）

## 5. 未完成清单（按优先级）

### 5.1 ★ K2 知识库树编辑器（用户最直接的诉求，下一个任务）

参考图 `docs/design/ui/ui_knowledge.png`。做完意味着"知识库=可编辑的 md 树"成立：

1. **大纲视图升级为编辑器**（`knowledge_outline_view.dart`）：
   - 就地增删改节点、拖拽移动（id 不变——移动=改文件位置，frontmatter 的 id 不动）、
     编辑别名/优先级；状态点已就位（实心绿=已填/空心灰=骨架）。
   - 写回走 `KnowledgeMdStore`：**新增方法** `createNode/renameNode/moveNode/deleteNode/
     updateNodeContent`，全部按"改 md 文件"实现（改名=改文件名+可能的标题行；移动=
     移动文件到新父节点文件夹；删除=删文件）。每次写操作后 `ref.invalidate(knowledgeBaseProvider)`。
2. **节点详情可编辑**（`knowledge_leaf_detail.dart`）：现有只读卡加"编辑"入口，
   直接编辑 md 的惯例小节（定义/公式/陷阱），保存=重写文件。
3. **笔记回流**（`knowledge` ← `courses`）：课时笔记确认时选归入节点，节点正文追加
   `## 来自 <课时> <mm:ss> 的笔记` 小节（`course_store` 的笔记结构已含时间戳）。
4. **"AI 补全此节"**：用户主动点 → 文本模型生成草稿 → 以 `## AI 草稿（待确认）`
   小节追加（source=ai），确认后转正。**AI 永远不直接改用户内容**。
5. 验收：拖拽移动后 id 不变且题目关联不丢；外部编辑器改 md 后重启 App 内容更新；
   新增/删除节点落盘正确。

### 5.2 P3 练习生成

三轨（题库匹配/AI 自创题/手动导入）→ runner（自主判分：亮答案用户自评）→
答错题 wrong_count+1 进错题本。细节见 V3_PLAN §6；`PaperComposer`/`problemSearchProvider`
可复用；练习页（paper_page）已改名「练习」并留了 P3 占位卡。

### 5.3 P2c 余项

- **托盘图标 spike**：`tray_manager` 0.7 的 `TrayManager.setIcon/addListener` 全部
  undefined（导出与 `nativeapi` 冲突）。尝试：直接用 `nativeapi` 的 TrayIcon API、
  或降级 tray_manager 版本、或接受任务栏回归。做完接 `pet_tray.dart` 的注释。
- **换皮设置项**：设置页加"桌宠皮肤"选择（10 只 `assets/pets/*.png` 目前只有 zhipu/claude），
  按当前 provider 自动选 + 手动覆盖；pet_window 的皮肤从设置读。
- **全局热键** `Ctrl+Alt+N`「记一下」（hotkey_manager），被占用要明确提示。

### 5.4 P4 B站字幕轨 / P5 换肤第三批

- P4：BV 号 → CC 字幕（用户自己的 SESSDATA，存 meta_entries）→ 分窗总结成带时间轴笔记。
- P5 第三批：录入表单分组卡片化、批量导入核对表、图谱视图换肤。

### 5.5 真机验收（**只有作者本人能做的**，代码侧无法验证）

桌宠置顶/透明/拖拽、气泡跨窗口推送、✕缩后台；P1 管道实跑（框选→记一下→看是否黑帧、
笔记质量、免费档频控阈值）；知识库 md 文件夹在真实库根生成情况。
交接时请明确提醒作者先跑 `run_app.bat` 做这轮验收。

### 5.6 已知技术债

- `test/ingest_draft_test.dart` 在**全量跑**时偶发失败（单跑必绿，疑似顺序耦合/临时目录
  冲突），需要定位隔离问题。
- 知识库笔记还没有 FTS（`knowledge_fts` 在 V3_KB_PLAN 里规划，K1 只做了 md 数据层）。
- problems→节点归档：题目目前仍挂在旧 JSON 考点 id 上（K1 保 id 所以不丢），
  K2 做完编辑器后题卡展示才算"归位"到 md 树。

## 6. 踩坑录（硬知识，省你几个小时）

| 坑 | 表现 | 解法 |
|---|---|---|
| Dart `$$` 插值 | `'$$'` 编译错 "A '$' has special meaning" | 用 `r'$$'`（写 md 公式块时必踩） |
| Dart RegExp 无 `\Z` | 正则永不匹配或报错 | 改行扫描（见 `knowledge_md_store` 的 section()） |
| `desktop_multi_window` 0.3.x | 网上教程全失效：无 `close/startDragging/setFrame` | 每个引擎跑同一份 `main`，`WindowController.fromCurrentEngine().arguments` 分流；窗口形态交给 `window_manager` |
| `tray_manager` 0.7 | `TrayManager` 方法全 undefined | 导出与 nativeapi 冲突，见 5.3（待 spike） |
| `screen_capturer` | 截图会**清空并劫持剪贴板** | `copyToClipboard: false`；`CaptureMode.screen` 要 `sc.` 前缀 |
| `getLuminanceRgb` | 返回 num 不是 int | `.toInt()` |
| bash heredoc + 中文/反斜杠 | python SyntaxError / `\a` 变响铃 / Dart 字符串被真换行破坏 | **写文件用 Write 工具，再 `python -c` 读取**；改代码优先 Edit 工具 |
| 测试目录 | `flutter test` 在仓库根跑报 "No pubspec.yaml" | 必须先 `cd app` |
| 脆断言 `.first` | 新增 Wrap/Widget 后抓错对象 | 加显式 `ValueKey` 后改测试定位 |
| CRLF 警告 | `warning: CRLF will be replaced by LF` | 无害，忽略 |
| 沙箱无 GUI | 截屏/窗口/多窗口全部测不了 | 真机事项列清单交作者（见 5.5） |

## 7. 资产与命令速查

- 桌宠立绘：`docs/design/pet/providers/<服务商id>.png`（10 张透明底）+ `app/assets/pets/`
- UI 参考图重渲：改 `docs/design/ui/ui_mockups.html` → 无头 Chrome
  `--window-size=1280,5040 --screenshot=_full.png`（**不要用内置浏览器 fullPage**，
  本机有拼接伪影）→ `python tools/design/split_mockups.py`
- 桌宠裁切：`python tools/design/make_provider_pets.py`
- 跑起来：仓库根 `run_app.bat`（Release 构建 + 中国镜像 + stale 检查）
- 测试：`cd app && flutter analyze && flutter test`
