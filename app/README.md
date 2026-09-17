# kaoyan_math_agent（Flutter 应用目录）

这是 Flutter 工程本身。**项目文档不在这个目录** —— 去仓库根看：

| 想了解 | 去哪 |
|---|---|
| 这是什么、做到哪了 | [`../README.md`](../README.md) |
| 开发进度与技术债台账 | [`../docs/PROGRESS.md`](../docs/PROGRESS.md) |
| 装环境、工具链版本、构建踩过的坑 | [`../docs/SETUP.md`](../docs/SETUP.md) |
| 题目 Markdown 格式规范 | [`../docs/DATA_FORMAT.md`](../docs/DATA_FORMAT.md) |

## 常用命令

```powershell
flutter pub get
flutter test           # 全部用例
flutter analyze
flutter build windows --release
```

⚠️ 两个容易踩的：

- **改了 `lib/data/db/tables.dart` 必须重跑 codegen**：
  `dart run build_runner build --delete-conflicting-outputs`
  —— 生成产物是提交进仓库的，漏跑会在运行期才报
  "Table has no primary key" 这类错，而 `flutter analyze` 看不出来。
- **改了仓库根的 `data/` 必须同步资产**：`python ../tools/data/sync_assets.py`
  —— `assets/data/` 是构建产物（Flutter 不允许 assets 引用应用目录之外的路径）。

> 这个文件此前是 `flutter create` 留下的模板 README（"A new Flutter project"
> 加一串 Flutter 官方链接），与本项目毫无关系。换成上面这份索引 ——
> 一个指向别处的占位文件，比一份说不到点上的模板有用。
