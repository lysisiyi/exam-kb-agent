/// 知识库宿主页 —— V3 信息架构下「题库并入知识库」（D17）的过渡形态。
///
/// K2 会把「题目」演进为知识点下方的图像题卡；在那之前，
/// 用四个标签页保证原有功能全部可达、一个不少：
/// 知识树（原知识库）｜题目（原错题本）｜录入｜批量导入。
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
                Tab(text: '录入'),
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
