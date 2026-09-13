/// 知识点本体的加载与缓存。
///
/// 数据来源：`assets/data/knowledge_points/{subject}.json`
/// 事实源在仓库根的 `data/knowledge_points/`，由
/// `tools/data/sync_assets.py` 同步到 assets。
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../../domain/knowledge/knowledge_point.dart';

/// 支持的科目。
enum Subject {
  math1('math1', '数学一'),
  math2('math2', '数学二'),
  math3('math3', '数学三');

  const Subject(this.id, this.label);
  final String id;
  final String label;

  String get assetPath => 'assets/data/knowledge_points/$id.json';
}

class KnowledgeBaseException implements Exception {
  final String message;
  final Object? cause;
  const KnowledgeBaseException(this.message, [this.cause]);
  @override
  String toString() => 'KnowledgeBaseException: $message';
}

/// 知识点本体仓库。
///
/// 单例缓存：知识点数据在 100KB 量级，全量载入内存比反复解析划算。
class KnowledgeRepository {
  KnowledgeRepository._();

  static final KnowledgeRepository instance = KnowledgeRepository._();

  final Map<String, KnowledgeBase> _cache = {};

  /// 已成功载入的科目。
  Set<String> get loadedSubjects => _cache.keys.toSet();

  /// 载入指定科目。命中缓存则直接返回。
  Future<KnowledgeBase> load(Subject subject) async {
    final cached = _cache[subject.id];
    if (cached != null) return cached;

    final String raw;
    try {
      raw = await rootBundle.loadString(subject.assetPath);
    } catch (e) {
      throw KnowledgeBaseException(
        '无法读取知识点文件 ${subject.assetPath}。'
        '请确认已运行 `python tools/data/sync_assets.py` 并重新构建。',
        e,
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (e) {
      throw KnowledgeBaseException('知识点文件 ${subject.assetPath} 不是合法 JSON', e);
    }

    if (decoded is! Map) {
      throw KnowledgeBaseException('知识点文件 ${subject.assetPath} 顶层不是对象');
    }

    final kb = KnowledgeBase.fromJson(decoded.cast<String, dynamic>());

    if (kb.nodes.isEmpty) {
      throw KnowledgeBaseException('知识点文件 ${subject.assetPath} 里没有任何节点');
    }
    if (kb.leaves.isEmpty) {
      throw KnowledgeBaseException(
        '知识点文件 ${subject.assetPath} 里没有叶子节点（is_leaf=true），'
        '无法用于题目标注',
      );
    }

    _cache[subject.id] = kb;
    return kb;
  }

  /// 尝试载入多个科目，跳过不存在的（数二/数三可能尚未编好）。
  Future<Map<Subject, KnowledgeBase>> loadAvailable(
    Iterable<Subject> subjects,
  ) async {
    final out = <Subject, KnowledgeBase>{};
    for (final s in subjects) {
      try {
        out[s] = await load(s);
      } on KnowledgeBaseException {
        // 该科目数据尚未准备好，跳过
        continue;
      }
    }
    return out;
  }

  /// 清空缓存（测试与"热重载知识库"用）。
  void clear() => _cache.clear();
}
