/// 知识点选择器。
///
/// ## 为什么需要搜索，而不是让用户在树里点
///
/// 知识点本体有 198 个叶子（数学一）。让用户每次录入都展开三级树去点，
/// 一轮下来就是十几次点击 —— 60 秒录入目标会被这一步吃掉。
///
/// 而**搜比点快得多**：用户已经知道这题考什么，打两个字就行。
/// 所以这里先是搜索框，树只是兜底（搜不到时按章节浏览）。
///
/// ## 搜索要命中别名，不只是名字
///
/// 知识点名是复合短语：用户想找「正态分布」，本体里的名字却是
/// 「正态分布及其标准化计算」。直接按名字搜，用户打「正态分布」能中，
/// 但打「N(0,1)」就什么也搜不到 —— 而后者才是他脑子里想的东西。
///
/// 所以搜索同时匹配 [`KnowledgePoint.aliases`]（T15 补进来的那批），
/// 这也是别名机制除了召回之外的第二份收益。
library;

import 'package:flutter/material.dart';

import '../../../domain/knowledge/knowledge_point.dart';

/// 一条搜索结果。
class KpMatch {
  final KnowledgePoint point;

  /// 命中的字段：`name` / `alias` / `weight`（空查询时的默认排序）。
  final String hitField;

  /// 实际命中的那个别名（[hitField] 为 `alias` 时有值），
  /// 用于告诉用户"为什么它被搜出来了"。
  final String? hitAlias;

  final int score;

  const KpMatch({
    required this.point,
    required this.hitField,
    this.hitAlias,
    required this.score,
  });
}

/// 归一化：去标点空白、转小写。
///
/// 与召回层用的归一化不是同一个函数，但**规则一致**，
/// 避免"召回能匹配上、搜索匹配不上"这种让人困惑的不一致。
String normalizeKpQuery(String s) => s
    .replaceAll(
      RegExp(r'''[\s,.;:!?()\[\]{}<>~\-—_/\\|"'`、。，；：！？（）【】《》]'''),
      '',
    )
    .toLowerCase();

/// 在叶子知识点里搜索。
///
/// [limit] 限制返回条数（默认 30）—— 结果太多反而难选。
/// [query] 为空时返回考频最高的前 [limit] 个，作为"高频考点"起点。
List<KpMatch> searchKnowledgePoints(
  KnowledgeBase kb,
  String query, {
  int limit = 30,
}) {
  final q = normalizeKpQuery(query);

  if (q.isEmpty) {
    final sorted = [...kb.leaves]
      ..sort((a, b) => (b.examWeight ?? 0).compareTo(a.examWeight ?? 0));
    return sorted
        .take(limit)
        .map((p) => KpMatch(point: p, hitField: 'weight', score: 0))
        .toList();
  }

  final out = <KpMatch>[];
  for (final p in kb.leaves) {
    final name = normalizeKpQuery(p.name);
    var best = 0;
    var field = '';
    String? alias;

    if (name == q) {
      best = 100;
      field = 'name';
    } else if (name.startsWith(q)) {
      best = 80;
      field = 'name';
    } else if (name.contains(q)) {
      best = 60;
      field = 'name';
    }

    for (final a in p.aliases) {
      final na = normalizeKpQuery(a);
      if (na.isEmpty) continue;
      if (na == q && best < 70) {
        best = 70;
        field = 'alias';
        alias = a;
      } else if (na.contains(q) && best < 40) {
        best = 40;
        field = 'alias';
        alias = a;
      }
    }

    if (best > 0) {
      out.add(KpMatch(
          point: p,
          hitField: field,
          hitAlias: alias,
          score: best,
        ));
    }
  }

  out.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    // 同分时高频考点优先 —— 考频高的更可能是用户要找的
    final byWeight =
        (b.point.examWeight ?? 0).compareTo(a.point.examWeight ?? 0);
    if (byWeight != 0) return byWeight;
    return a.point.id.compareTo(b.point.id);
  });

  return out.take(limit).toList();
}

/// 知识点选择结果。
class KpSelection {
  final String? primaryId;
  final List<String> secondaryIds;

  const KpSelection({this.primaryId, this.secondaryIds = const []});

  bool get isEmpty => primaryId == null && secondaryIds.isEmpty;

  @override
  String toString() => 'KpSelection(primary=$primaryId, '
      'secondary=$secondaryIds)';
}

/// 知识点选择对话框。
///
/// 返回 null 表示取消；返回 [KpSelection] 表示确认。
Future<KpSelection?> showKpPicker(
  BuildContext context, {
  required KnowledgeBase kb,
  String? primaryId,
  List<String> secondaryIds = const [],
  /// 是否允许选次考点。录入选主考点时不需要。
  bool allowSecondary = true,
}) {
  return showDialog<KpSelection>(
    context: context,
    builder: (_) => _KpPickerDialog(
      kb: kb,
      initialPrimary: primaryId,
      initialSecondary: secondaryIds,
      allowSecondary: allowSecondary,
    ),
  );
}

class _KpPickerDialog extends StatefulWidget {
  final KnowledgeBase kb;
  final String? initialPrimary;
  final List<String> initialSecondary;
  final bool allowSecondary;

  const _KpPickerDialog({
    required this.kb,
    this.initialPrimary,
    this.initialSecondary = const [],
    this.allowSecondary = true,
  });

  @override
  State<_KpPickerDialog> createState() => _KpPickerDialogState();
}

class _KpPickerDialogState extends State<_KpPickerDialog> {
  late final TextEditingController _query =
      TextEditingController(text: _initialQuery);
  late String? _primary = widget.initialPrimary;
  late final List<String> _secondary = [...widget.initialSecondary];

  String get _initialQuery {
    final id = widget.initialPrimary;
    if (id == null) return '';
    return widget.kb.byId[id]?.name ?? '';
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _togglePrimary(String id) {
    setState(() {
      if (_primary == id) {
        _primary = null;
      } else {
        _primary = id;
        // 主次互斥：设为主考点就从次考点里去掉
        _secondary.remove(id);
      }
    });
  }

  void _toggleSecondary(String id) {
    setState(() {
      if (_secondary.contains(id)) {
        _secondary.remove(id);
      } else if (_primary != id) {
        _secondary.add(id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final matches = searchKnowledgePoints(widget.kb, _query.text);
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(widget.allowSecondary ? '选择考点' : '选择主考点'),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      content: SizedBox(
        width: 620,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _query,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 18),
                hintText: '搜知识点名，也可以搜别名（如「正态分布」「极值」）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _query.text.trim().isEmpty
                  ? '高频考点（按考频排序）'
                  : '匹配 ${matches.length} 条',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: matches.isEmpty
                  ? Center(
                      child: Text(
                        '没有匹配的知识点',
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: matches.length,
                      itemBuilder: (_, i) => _MatchTile(
                        match: matches[i],
                        kb: widget.kb,
                        isPrimary: _primary == matches[i].point.id,
                        isSecondary:
                            _secondary.contains(matches[i].point.id),
                        allowSecondary: widget.allowSecondary,
                        onPrimary: () => _togglePrimary(matches[i].point.id),
                        onSecondary: () => _toggleSecondary(matches[i].point.id),
                      ),
                    ),
            ),
            if (_primary != null || _secondary.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '已选：主 ${_primary == null ? "—" : widget.kb.byId[_primary]?.name ?? _primary}'
                  '${_secondary.isEmpty ? "" : " ／ 次 ${_secondary.length} 个"}',
                  style: const TextStyle(fontSize: 11.5),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(
            const KpSelection(primaryId: null, secondaryIds: []),
          ),
          child: const Text('清空'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            KpSelection(primaryId: _primary, secondaryIds: _secondary),
          ),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

class _MatchTile extends StatelessWidget {
  final KpMatch match;
  final KnowledgeBase kb;
  final bool isPrimary;
  final bool isSecondary;
  final bool allowSecondary;
  final VoidCallback onPrimary;
  final VoidCallback onSecondary;

  const _MatchTile({
    required this.match,
    required this.kb,
    required this.isPrimary,
    required this.isSecondary,
    required this.allowSecondary,
    required this.onPrimary,
    required this.onSecondary,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kp = match.point;
    // 面包屑：章节名，帮助用户确认"是不是我理解的那个"
    final path = kb.pathTo(kp.id);
    final crumbs = path
        .where((n) => n.level >= 2 && n.id != kp.id)
        .map((n) => n.name)
        .join(' › ');

    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: IconButton(
        tooltip: isPrimary ? '取消主考点' : '设为主考点',
        icon: Icon(
          isPrimary ? Icons.radio_button_checked : Icons.radio_button_off,
          size: 19,
          color: isPrimary ? theme.colorScheme.primary : null,
        ),
        onPressed: onPrimary,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              kp.name,
              style: const TextStyle(fontSize: 13.5),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (match.hitAlias != null) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '别名「${match.hitAlias}」',
                style: TextStyle(
                  fontSize: 10,
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        '${kp.examWeight == null ? "" : "考频 ${kp.examWeight!.toStringAsFixed(2)}  ·  "}'
        '${kp.examCount > 0 ? "近 ${kp.examCount} 年考过  ·  " : ""}$crumbs',
        style: const TextStyle(fontSize: 11),
        overflow: TextOverflow.ellipsis,
      ),
      trailing: allowSecondary
          ? IconButton(
              tooltip: isSecondary ? '移除次考点' : '加为次考点',
              icon: Icon(
                isSecondary ? Icons.check_box : Icons.check_box_outline_blank,
                size: 18,
              ),
              onPressed: onSecondary,
            )
          : null,
      onTap: onPrimary,
    );
  }
}
