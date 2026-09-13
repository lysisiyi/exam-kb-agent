# 题目 Markdown 格式规范

> 版本 v1.0 · 2026-03-15
> 这是本项目的**核心数据契约**。所有题目、题库、导出包都遵循此格式。
> 设计目标：**人类可读 · Git 友好 · 可迁移到 Obsidian/Typora · AI 可解析**

---

## 1. 设计原则

| 原则 | 含义 |
|---|---|
| **一题一文件** | Git diff 干净、可单独分享、解析快、冲突隔离 |
| **YAML frontmatter 存元数据** | Obsidian / Jekyll / Hugo 生态标准，工具链现成 |
| **正文用纯 Markdown** | 任何渲染器都能显示，不引入私有语法 |
| **公式用 `$` / `$$`** | 与 KaTeX 默认一致，可直接在 Obsidian 渲染 |
| **图片用相对路径 + 标准语法** | `![](images/xxx.png)`，迁移后立刻能看图 |
| **用户状态不写进文件** ⚠️ | 见 §6 —— 这是避免架构崩坏的关键 |

---

## 2. 完整示例

文件：`problems/2023-shu1-T18.md`

```markdown
---
id: 2023-shu1-T18
fingerprint: a3f8c9e12b4d7f21
subject: math1
qtype: solve
difficulty: 2
source: 2023 年数学（一）真题 第 18 题
source_type: real_exam
source_year: 2023
knowledge:
  - id: math1.calc.integral.mean_value
    role: primary
    relevance: 1.0
  - id: math1.calc.proof.rolle
    role: secondary
    relevance: 0.7
  - id: math1.calc.proof.auxiliary_function
    role: secondary
    relevance: 0.64
error_causes: [idea]
images:
  - images/2023-shu1-T18-1.png
created_at: 2026-03-15
tags: [真题, 证明题, 中值定理]
---

## 题干

设 $f(x)$ 在 $[0,1]$ 上连续，且

$$\int_0^1 f(x)\,\mathrm{d}x = 0,\qquad f(1)=0$$

证明：存在 $\xi \in (0,1)$，使得 $f(\xi)=0$。

![题图](images/2023-shu1-T18-1.png)

## 答案

存在 $\xi \in (0,1)$ 使 $f(\xi)=0$。

## 解析

由积分中值定理，存在 $c \in [0,1]$ 使得

$$\int_0^1 f(x)\,\mathrm{d}x = f(c)\cdot 1 = 0 \quad\Longrightarrow\quad f(c)=0$$

又 $f(1)=0$，故 $c$ 与 $1$ 均为 $f$ 的零点。对 $f$ 在区间 $[c,1]$ 上应用罗尔定理，
即存在 $\xi \in (c,1) \subset (0,1)$ 使 $f(\xi)=0$。

## 我的笔记

辅助函数构造套路：见到 $\int_a^b f = 0$ 就先想积分中值定理拿一个零点，
再找题面里第二个零点条件（这里就是 $f(1)=0$），最后罗尔。
```

---

## 3. Frontmatter 字段定义

### 3.1 必填字段

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | string | **全局唯一**。见 §4 命名规则 |
| `fingerprint` | string | 16 位十六进制，用于去重。见 §5 |
| `subject` | enum | `math1` / `math2` / `math3` |
| `qtype` | enum | `choice` / `fill` / `solve` / `proof` |
| `difficulty` | int 1–3 | `1` 基础 · `2` 综合 · `3` 拓展 |
| `knowledge` | array | 至少 1 项，且**有且仅有一个** `role: primary` |
| `created_at` | date | `YYYY-MM-DD` |

### 3.2 可选字段

| 字段 | 类型 | 说明 |
|---|---|---|
| `source` | string | 人类可读来源，如 `880 线代 第 6 章` |
| `source_type` | enum | `real_exam` / `mock` / `textbook` / `self_made` / `unknown` |
| `source_year` | int | 真题年份 |
| `options` | array | 选择题选项，`["A. ...", "B. ..."]` |
| `answer` | string | 简短答案（也可只写在正文 `## 答案`） |
| `error_causes` | array | 预判易错点。见 §7 |
| `images` | array | 相对路径数组 |
| `tags` | array | 自由标签（**受控**，见 §8） |
| `ai_tagged` | bool | 是否由 AI 标注 |
| `ai_confidence` | float | primary 知识点置信度 0–1 |
| `needs_review` | bool | 标记待人工确认 |

### 3.3 `knowledge` 条目结构

```yaml
knowledge:
  - id: math1.calc.integral.mean_value   # 必须在知识点本体中存在的 id
    role: primary                        # primary | secondary
    relevance: 1.0                       # 0–1
```

**约束**（解析时必须校验，违反则降级为 `needs_review`）：
- `role: primary` 的条目**有且仅有一个**
- `relevance` 在 `[0, 1]`
- `id` 必须在知识点本体里存在；不存在则保留但标记 `needs_review`

---

## 4. `id` 命名规则

**人可读优先**，便于 Git 和人工排查。

| 来源 | 格式 | 示例 |
|---|---|---|
| 真题 | `{年}-{科目}-T{题号}` | `2023-shu1-T18` |
| 教辅 | `{书简称}-{章节}-{题号}` | `880-xiandai-6-12` |
| 自建 | `self-{yyyymmdd}-{seq}` | `self-20260315-01` |
| 导入 | `imp-{批次}-{seq}` | `imp-a1b2c3-007` |

**冲突处理**：若 id 已存在但内容不同，追加 `-2`、`-3` 后缀。

---

## 5. 去重指纹（fingerprint）

> ⚠️ **重要限制**：LaTeX 写法极度不稳定（`\frac{1}{2}` vs `\dfrac{1}{2}` vs `{1\over2}`），
> **指纹只能识别"完全相同"的题，不能做相似题判断。** 相似题留到 V3 用向量检索。

### 规范化流程

```dart
String computeFingerprint(String stemMarkdown) {
  var s = stemMarkdown;
  s = s.replaceAll(RegExp(r'\s+'), '');                    // 去所有空白
  s = s.replaceAll(RegExp(r'\\left|\\right'), '');         // 去可变分隔符
  s = s.replaceAll(RegExp(r'\\[dt]frac'), r'\frac');       // 统一分式
  s = s.replaceAll(RegExp(r'\\(?:displaystyle|limits|,|;|!|quad|qquad)'), '');
  s = s.replaceAll(RegExp(r'[，。；：、,.;:]'), '');          // 去标点
  s = s.replaceAll(RegExp(r'\$\$?'), '');                  // 去公式分隔符
  s = s.replaceAll(RegExp(r'\s'), '');
  return sha256.convert(utf8.encode(s)).toString().substring(0, 16);
}
```

**注意**：指纹基于**规范化后的题干**，不含答案、解析、图片。

---

## 6. 用户状态：绝对不写进 Markdown ⚠️

这是整个架构最容易踩的坑。

| 数据 | 存放位置 | 原因 |
|---|---|---|
| 题面 / 答案 / 解析 | ✅ Markdown | 写一次，很少改，需可迁移 |
| 知识点标签 | ✅ Markdown frontmatter | 跟着题目走，导出要带上 |
| **错误次数** | ❌ **SQLite** | 每次复习都改 → 高频重写文件 |
| **FSRS 状态** | ❌ **SQLite** | 同上，且是机器数据 |
| **掌握度** | ❌ **SQLite** | 派生数据，可重算 |
| **我的笔记** | ❌ SQLite（导出时合并） | 用户高频编辑 |

### 为什么不写进文件

1. **性能**：用户每点一次「忘了」就要重写整个 .md 文件
2. **事务性**：文件系统无 ACID，多字段更新可能只写一半
3. **索引无法重建**：Markdown 是"事实源"，但它不该包含高频变化的状态
4. **同步冲突**：多设备时状态字段会疯狂冲突

### 导出时怎么办

导出给用户时，**动态合并**——生成一份自包含的 Markdown：

```markdown
---
id: 2023-shu1-T18
# ... 原有字段 ...
# ↓ 导出时追加的用户状态（前缀 my_）
my_wrong_count: 3
my_mastery: 0.26
my_last_wrong: 2026-03-20
my_next_review: 2026-03-27
my_error_causes: [idea]
my_note: 构造辅助函数还是没思路
---
```

**规则**：用户状态字段一律用 `my_` 前缀。导入时，`my_` 前缀的字段写入 SQLite，其余写入 Markdown。

---

## 7. 错因（error_causes）

**受控词表**，定义在 `data/error_causes.json`。固定 6 个值：

| id | 名称 | 含义 |
|---|---|---|
| `concept` | 概念不清 | 定义/定理没掌握 |
| `calc` | 计算失误 | 会做但算错 |
| `idea` | 思路缺失 | 不知道从哪下手 |
| `reading` | 审题错误 | 看错条件/漏条件 |
| `method` | 方法选择错误 | 用了笨方法/错方法 |
| `time` | 时间不够 | 会做但来不及 |

### 语义区分（给 LLM 的判断依据）

| 场景 | 归类 |
|---|---|
| 知道要用洛必达，但求导求错了 | `calc` |
| 根本不知道这里能用洛必达 | `concept` |
| 知道该用中值定理，但想不到构造辅助函数 | `idea` |
| 用夹逼定理能做但用了洛必达导致算不出来 | `method` |
| 题目问"不正确的是"，看成了"正确的是" | `reading` |
| 会做但考试时没时间做完 | `time` |

---

## 8. 标签（tags）

**自由标签是灾难**——用 3 个月会得到 2000 个同义标签。

规则：
- `tags` 只用于**弱分类**（如 `真题`、`证明题`、`计算量大`）
- **知识点一律走 `knowledge` 字段**，不允许把知识点写进 `tags`
- 新标签进入前需人工确认；维护一份 `data/tag_whitelist.json`

---

## 9. 解析规则（宽容原则）

必须遵守：**frontmatter 解析失败不能导致题目丢失。**

### 解析优先级

```
1. 标准解析：正则提取 --- ... --- 之间的 YAML
2. YAML 语法错误 → 逐行正则提取能识别的字段，其余丢弃，标记 needs_review
3. 完全没有 frontmatter → 整个文件当纯文本题目，id 用文件名，标记 needs_review
4. 文件读取失败 → 跳过并记录到错误日志，不中断批量导入
```

### 正文分区识别

正文用二级标题分区，**必须容忍变体**：

```dart
const sectionAliases = {
  'stem':     ['题干', '题目', '问题', 'stem', 'Stem'],
  'answer':   ['答案', 'answer', 'Answer'],
  'solution': ['解析', '解答', '解题过程', 'solution', 'Solution'],
  'note':     ['我的笔记', '笔记', 'note', 'Note'],
};
```

**未识别的部分**：全部归入题干（宁可多，不可漏）。

### 脏数据容错

用户从网上粘贴的题目常带这些，解析器必须处理：

| 脏格式 | 处理 |
|---|---|
| `**考点：** xxx` 全角冒号 | 归一化全角 → 半角 |
| `\( ... \)` / `\[ ... \]` | 转成 `$ ... $` / `$$ ... $$` |
| `\begin{equation}...\end{equation}` | 转成 `$$...$$` |
| 不可见字符（`\u200b` 等） | `unicodedata` 清理 |
| Word 粘贴带来的 HTML 实体 | 反转义 |
| 混合换行符 `\r\n` | 统一为 `\n` |

---

## 10. 原子写（必须）

文件系统没有事务。写文件必须：

```dart
Future<void> atomicWrite(File target, String content) async {
  final tmp = File('${target.path}.tmp');
  await tmp.writeAsString(content, flush: true);
  await tmp.rename(target.path);      // 同分区 rename 是原子的
}
```

**绝不直接覆盖原文件。**

---

## 11. 批量导入格式

导入包是一个 ZIP：

```
import-package.zip
├── manifest.json          # { version, created_at, count, app_version }
├── problems/
│   ├── xxx.md
│   └── ...
└── images/
    └── ...
```

`manifest.json`：

```json
{
  "format": "kaoyan-math-agent/problem-pack",
  "version": "1.0.0",
  "created_at": "2026-03-15T10:00:00Z",
  "app_version": "1.0.0",
  "problem_count": 187,
  "subject": "math1",
  "contains_user_state": false
}
```

**种子题库**（随 App 分发）用同一格式，只是 `contains_user_state: false` 且放在 `seeds/`。

---

## 12. 变更日志

| 版本 | 日期 | 变更 |
|---|---|---|
| v1.0 | 2026-03-15 | 初版 |
