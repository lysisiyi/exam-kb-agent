/// 知识库宿主页 —— D17「题库并入知识库」的落点（2026-10-05 优化后归位）。
///
/// 四个标签页保证功能可达：知识树（md 事实源，K1 起 Obsidian 式文件夹）｜
/// 题目（原错题本，K2 起演进为节点下图像题卡）｜录入（图像识别单题）｜批量导入。
/// 四个内容页都是无 Scaffold 的 body（见各自文件头），可以安全嵌套。
library;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../entry/entry_page.dart';
import '../ingest/ingest_page.dart';
import '../problems/problems_page.dart';
import 'knowledge_page.dart';

class KnowledgeHomePage extends StatelessWidget {
  const KnowledgeHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Column(
        children: [
          Container(
            color: AppColors.bg,
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
            child: const TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              dividerColor: AppColors.line,
              labelColor: AppColors.primaryStrong,
              unselectedLabelColor: AppColors.ink2,
              indicatorColor: AppColors.primary,
              labelStyle: TextStyle(
                  fontSize: 13.5, fontWeight: FontWeight.w700),
              unselectedLabelStyle: TextStyle(
                  fontSize: 13.5, fontWeight: FontWeight.w400),
              tabs: [
                Tab(text: '知识树'),
                Tab(text: '题目'),
                Tab(text: '图像录入'),
                Tab(text: '批量导入'),
              ],
            ),
          ),
          const Expanded(
            child: TabBarView(
              children: [
                KnowledgePage(),
                ProblemsPage(),
                EntryPage(),
                IngestPage(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
