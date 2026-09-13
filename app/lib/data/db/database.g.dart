// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $ProblemsIndexTable extends ProblemsIndex
    with TableInfo<$ProblemsIndexTable, ProblemIndexRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ProblemsIndexTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _ftsRowIdMeta =
      const VerificationMeta('ftsRowId');
  @override
  late final GeneratedColumn<int> ftsRowId = GeneratedColumn<int>(
      'rowid', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways('UNIQUE'));
  static const VerificationMeta _fingerprintMeta =
      const VerificationMeta('fingerprint');
  @override
  late final GeneratedColumn<String> fingerprint = GeneratedColumn<String>(
      'fingerprint', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _subjectMeta =
      const VerificationMeta('subject');
  @override
  late final GeneratedColumn<String> subject = GeneratedColumn<String>(
      'subject', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _qtypeMeta = const VerificationMeta('qtype');
  @override
  late final GeneratedColumn<String> qtype = GeneratedColumn<String>(
      'qtype', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _difficultyMeta =
      const VerificationMeta('difficulty');
  @override
  late final GeneratedColumn<int> difficulty = GeneratedColumn<int>(
      'difficulty', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(2));
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  @override
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
      'source', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _sourceTypeMeta =
      const VerificationMeta('sourceType');
  @override
  late final GeneratedColumn<String> sourceType = GeneratedColumn<String>(
      'source_type', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('unknown'));
  static const VerificationMeta _sourceYearMeta =
      const VerificationMeta('sourceYear');
  @override
  late final GeneratedColumn<int> sourceYear = GeneratedColumn<int>(
      'source_year', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _filePathMeta =
      const VerificationMeta('filePath');
  @override
  late final GeneratedColumn<String> filePath = GeneratedColumn<String>(
      'file_path', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _stemTextMeta =
      const VerificationMeta('stemText');
  @override
  late final GeneratedColumn<String> stemText = GeneratedColumn<String>(
      'stem_text', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _searchTokensMeta =
      const VerificationMeta('searchTokens');
  @override
  late final GeneratedColumn<String> searchTokens = GeneratedColumn<String>(
      'search_tokens', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _primaryKpWeightMeta =
      const VerificationMeta('primaryKpWeight');
  @override
  late final GeneratedColumn<double> primaryKpWeight = GeneratedColumn<double>(
      'primary_kp_weight', aliasedName, true,
      type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _primaryKpNameMeta =
      const VerificationMeta('primaryKpName');
  @override
  late final GeneratedColumn<String> primaryKpName = GeneratedColumn<String>(
      'primary_kp_name', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _parseWarningsMeta =
      const VerificationMeta('parseWarnings');
  @override
  late final GeneratedColumn<String> parseWarnings = GeneratedColumn<String>(
      'parse_warnings', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _needsReviewMeta =
      const VerificationMeta('needsReview');
  @override
  late final GeneratedColumn<bool> needsReview = GeneratedColumn<bool>(
      'needs_review', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'CHECK ("needs_review" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _aiTaggedMeta =
      const VerificationMeta('aiTagged');
  @override
  late final GeneratedColumn<bool> aiTagged = GeneratedColumn<bool>(
      'ai_tagged', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("ai_tagged" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _aiConfidenceMeta =
      const VerificationMeta('aiConfidence');
  @override
  late final GeneratedColumn<double> aiConfidence = GeneratedColumn<double>(
      'ai_confidence', aliasedName, true,
      type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  static const VerificationMeta _fileModifiedAtMeta =
      const VerificationMeta('fileModifiedAt');
  @override
  late final GeneratedColumn<DateTime> fileModifiedAt =
      GeneratedColumn<DateTime>('file_modified_at', aliasedName, true,
          type: DriftSqlType.dateTime, requiredDuringInsert: false);
  static const VerificationMeta _indexedAtMeta =
      const VerificationMeta('indexedAt');
  @override
  late final GeneratedColumn<DateTime> indexedAt = GeneratedColumn<DateTime>(
      'indexed_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  @override
  List<GeneratedColumn> get $columns => [
        ftsRowId,
        id,
        fingerprint,
        subject,
        qtype,
        difficulty,
        source,
        sourceType,
        sourceYear,
        filePath,
        stemText,
        searchTokens,
        primaryKpWeight,
        primaryKpName,
        parseWarnings,
        needsReview,
        aiTagged,
        aiConfidence,
        createdAt,
        fileModifiedAt,
        indexedAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'problems_index';
  @override
  VerificationContext validateIntegrity(Insertable<ProblemIndexRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('rowid')) {
      context.handle(_ftsRowIdMeta,
          ftsRowId.isAcceptableOrUnknown(data['rowid']!, _ftsRowIdMeta));
    }
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('fingerprint')) {
      context.handle(
          _fingerprintMeta,
          fingerprint.isAcceptableOrUnknown(
              data['fingerprint']!, _fingerprintMeta));
    } else if (isInserting) {
      context.missing(_fingerprintMeta);
    }
    if (data.containsKey('subject')) {
      context.handle(_subjectMeta,
          subject.isAcceptableOrUnknown(data['subject']!, _subjectMeta));
    } else if (isInserting) {
      context.missing(_subjectMeta);
    }
    if (data.containsKey('qtype')) {
      context.handle(
          _qtypeMeta, qtype.isAcceptableOrUnknown(data['qtype']!, _qtypeMeta));
    } else if (isInserting) {
      context.missing(_qtypeMeta);
    }
    if (data.containsKey('difficulty')) {
      context.handle(
          _difficultyMeta,
          difficulty.isAcceptableOrUnknown(
              data['difficulty']!, _difficultyMeta));
    }
    if (data.containsKey('source')) {
      context.handle(_sourceMeta,
          source.isAcceptableOrUnknown(data['source']!, _sourceMeta));
    }
    if (data.containsKey('source_type')) {
      context.handle(
          _sourceTypeMeta,
          sourceType.isAcceptableOrUnknown(
              data['source_type']!, _sourceTypeMeta));
    }
    if (data.containsKey('source_year')) {
      context.handle(
          _sourceYearMeta,
          sourceYear.isAcceptableOrUnknown(
              data['source_year']!, _sourceYearMeta));
    }
    if (data.containsKey('file_path')) {
      context.handle(_filePathMeta,
          filePath.isAcceptableOrUnknown(data['file_path']!, _filePathMeta));
    } else if (isInserting) {
      context.missing(_filePathMeta);
    }
    if (data.containsKey('stem_text')) {
      context.handle(_stemTextMeta,
          stemText.isAcceptableOrUnknown(data['stem_text']!, _stemTextMeta));
    } else if (isInserting) {
      context.missing(_stemTextMeta);
    }
    if (data.containsKey('search_tokens')) {
      context.handle(
          _searchTokensMeta,
          searchTokens.isAcceptableOrUnknown(
              data['search_tokens']!, _searchTokensMeta));
    }
    if (data.containsKey('primary_kp_weight')) {
      context.handle(
          _primaryKpWeightMeta,
          primaryKpWeight.isAcceptableOrUnknown(
              data['primary_kp_weight']!, _primaryKpWeightMeta));
    }
    if (data.containsKey('primary_kp_name')) {
      context.handle(
          _primaryKpNameMeta,
          primaryKpName.isAcceptableOrUnknown(
              data['primary_kp_name']!, _primaryKpNameMeta));
    }
    if (data.containsKey('parse_warnings')) {
      context.handle(
          _parseWarningsMeta,
          parseWarnings.isAcceptableOrUnknown(
              data['parse_warnings']!, _parseWarningsMeta));
    }
    if (data.containsKey('needs_review')) {
      context.handle(
          _needsReviewMeta,
          needsReview.isAcceptableOrUnknown(
              data['needs_review']!, _needsReviewMeta));
    }
    if (data.containsKey('ai_tagged')) {
      context.handle(_aiTaggedMeta,
          aiTagged.isAcceptableOrUnknown(data['ai_tagged']!, _aiTaggedMeta));
    }
    if (data.containsKey('ai_confidence')) {
      context.handle(
          _aiConfidenceMeta,
          aiConfidence.isAcceptableOrUnknown(
              data['ai_confidence']!, _aiConfidenceMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    }
    if (data.containsKey('file_modified_at')) {
      context.handle(
          _fileModifiedAtMeta,
          fileModifiedAt.isAcceptableOrUnknown(
              data['file_modified_at']!, _fileModifiedAtMeta));
    }
    if (data.containsKey('indexed_at')) {
      context.handle(_indexedAtMeta,
          indexedAt.isAcceptableOrUnknown(data['indexed_at']!, _indexedAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {ftsRowId};
  @override
  ProblemIndexRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ProblemIndexRow(
      ftsRowId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}rowid'])!,
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      fingerprint: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}fingerprint'])!,
      subject: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}subject'])!,
      qtype: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}qtype'])!,
      difficulty: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}difficulty'])!,
      source: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}source']),
      sourceType: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}source_type'])!,
      sourceYear: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}source_year']),
      filePath: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}file_path'])!,
      stemText: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}stem_text'])!,
      searchTokens: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}search_tokens'])!,
      primaryKpWeight: attachedDatabase.typeMapping.read(
          DriftSqlType.double, data['${effectivePrefix}primary_kp_weight']),
      primaryKpName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}primary_kp_name']),
      parseWarnings: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}parse_warnings']),
      needsReview: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}needs_review'])!,
      aiTagged: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}ai_tagged'])!,
      aiConfidence: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}ai_confidence']),
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at']),
      fileModifiedAt: attachedDatabase.typeMapping.read(
          DriftSqlType.dateTime, data['${effectivePrefix}file_modified_at']),
      indexedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}indexed_at'])!,
    );
  }

  @override
  $ProblemsIndexTable createAlias(String alias) {
    return $ProblemsIndexTable(attachedDatabase, alias);
  }
}

class ProblemIndexRow extends DataClass implements Insertable<ProblemIndexRow> {
  /// SQLite 隐式 rowid 的显式声明。
  ///
  /// ⚠️ Dart 列名**不能**叫 `rowid` —— 那会生成与 SQLite 隐式 rowid 同名的列，
  /// 造成 `problems_index.rowid` 语义歧义（而且 FTS5 external-content 表
  /// 要求 `content_rowid` 指向一个真实的整数主键）。
  ///
  /// 这里用 `ftsRowId` 作 Dart 名、`named('rowid')` 把 SQL 列名固定为 `rowid`，
  /// 既避免了歧义，又让 FTS5 的 `content_rowid='rowid'` 正常工作。
  final int ftsRowId;

  /// 题目业务 id，如 `2023-shu1-T18`。全局唯一。
  final String id;

  /// 去重指纹（16 位十六进制）。
  final String fingerprint;

  /// `math1` / `math2` / `math3`
  final String subject;

  /// `choice` / `fill` / `solve` / `proof`
  final String qtype;

  /// 1 基础 · 2 综合 · 3 拓展
  final int difficulty;
  final String? source;

  /// `real_exam` / `mock` / `textbook` / `self_made` / `unknown`
  final String sourceType;
  final int? sourceYear;

  /// Markdown 文件相对路径（相对 library 根目录）。
  final String filePath;

  /// 题干纯文本（去 Markdown 标记），保留原始可读形式。
  ///
  /// 用于展示、调试与将来的高亮。**不参与 FTS 索引** ——
  /// 见 [searchTokens] 的说明。
  final String stemText;

  /// 供 FTS5 索引的**分词后**文本。
  ///
  /// ⚠️ 这里存的是 `CjkTokenizer.space()` 处理过的版本 —— 中文逐字加空格。
  /// 原因：FTS5 的 `unicode61` 分词器按空白切词，中文句子没有空格会变成
  /// 单个巨型 token，导致中文检索完全失效（实测确认）。
  ///
  /// 之所以另起一列而不是复用 [stemText]：加空格后的文本**不可逆**
  /// （无法区分"原本就有空格"与"为分词而加的空格"），
  /// 保留原始版本才能正确展示与调试。
  ///
  /// 索引与查询必须使用**同一套分词规则**，详见 `CjkTokenizer`。
  final String searchTokens;

  /// 主考点的考频权重。冗余存放是为了让组卷/排序能纯 SQL 完成，
  /// 不必回查知识点本体文件。
  final double? primaryKpWeight;

  /// 主考点名称。同样用于展示与排序的便捷性。
  final String? primaryKpName;

  /// 解析期产生的警告（JSON 数组字符串）。非空表示需人工复核。
  final String? parseWarnings;
  final bool needsReview;
  final bool aiTagged;
  final double? aiConfidence;
  final DateTime? createdAt;

  /// 文件最后修改时间。用于增量重建索引：只重解析 mtime 变化的文件。
  final DateTime? fileModifiedAt;

  /// 索引行自身的插入/更新时间。
  final DateTime indexedAt;
  const ProblemIndexRow(
      {required this.ftsRowId,
      required this.id,
      required this.fingerprint,
      required this.subject,
      required this.qtype,
      required this.difficulty,
      this.source,
      required this.sourceType,
      this.sourceYear,
      required this.filePath,
      required this.stemText,
      required this.searchTokens,
      this.primaryKpWeight,
      this.primaryKpName,
      this.parseWarnings,
      required this.needsReview,
      required this.aiTagged,
      this.aiConfidence,
      this.createdAt,
      this.fileModifiedAt,
      required this.indexedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['rowid'] = Variable<int>(ftsRowId);
    map['id'] = Variable<String>(id);
    map['fingerprint'] = Variable<String>(fingerprint);
    map['subject'] = Variable<String>(subject);
    map['qtype'] = Variable<String>(qtype);
    map['difficulty'] = Variable<int>(difficulty);
    if (!nullToAbsent || source != null) {
      map['source'] = Variable<String>(source);
    }
    map['source_type'] = Variable<String>(sourceType);
    if (!nullToAbsent || sourceYear != null) {
      map['source_year'] = Variable<int>(sourceYear);
    }
    map['file_path'] = Variable<String>(filePath);
    map['stem_text'] = Variable<String>(stemText);
    map['search_tokens'] = Variable<String>(searchTokens);
    if (!nullToAbsent || primaryKpWeight != null) {
      map['primary_kp_weight'] = Variable<double>(primaryKpWeight);
    }
    if (!nullToAbsent || primaryKpName != null) {
      map['primary_kp_name'] = Variable<String>(primaryKpName);
    }
    if (!nullToAbsent || parseWarnings != null) {
      map['parse_warnings'] = Variable<String>(parseWarnings);
    }
    map['needs_review'] = Variable<bool>(needsReview);
    map['ai_tagged'] = Variable<bool>(aiTagged);
    if (!nullToAbsent || aiConfidence != null) {
      map['ai_confidence'] = Variable<double>(aiConfidence);
    }
    if (!nullToAbsent || createdAt != null) {
      map['created_at'] = Variable<DateTime>(createdAt);
    }
    if (!nullToAbsent || fileModifiedAt != null) {
      map['file_modified_at'] = Variable<DateTime>(fileModifiedAt);
    }
    map['indexed_at'] = Variable<DateTime>(indexedAt);
    return map;
  }

  ProblemsIndexCompanion toCompanion(bool nullToAbsent) {
    return ProblemsIndexCompanion(
      ftsRowId: Value(ftsRowId),
      id: Value(id),
      fingerprint: Value(fingerprint),
      subject: Value(subject),
      qtype: Value(qtype),
      difficulty: Value(difficulty),
      source:
          source == null && nullToAbsent ? const Value.absent() : Value(source),
      sourceType: Value(sourceType),
      sourceYear: sourceYear == null && nullToAbsent
          ? const Value.absent()
          : Value(sourceYear),
      filePath: Value(filePath),
      stemText: Value(stemText),
      searchTokens: Value(searchTokens),
      primaryKpWeight: primaryKpWeight == null && nullToAbsent
          ? const Value.absent()
          : Value(primaryKpWeight),
      primaryKpName: primaryKpName == null && nullToAbsent
          ? const Value.absent()
          : Value(primaryKpName),
      parseWarnings: parseWarnings == null && nullToAbsent
          ? const Value.absent()
          : Value(parseWarnings),
      needsReview: Value(needsReview),
      aiTagged: Value(aiTagged),
      aiConfidence: aiConfidence == null && nullToAbsent
          ? const Value.absent()
          : Value(aiConfidence),
      createdAt: createdAt == null && nullToAbsent
          ? const Value.absent()
          : Value(createdAt),
      fileModifiedAt: fileModifiedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(fileModifiedAt),
      indexedAt: Value(indexedAt),
    );
  }

  factory ProblemIndexRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ProblemIndexRow(
      ftsRowId: serializer.fromJson<int>(json['ftsRowId']),
      id: serializer.fromJson<String>(json['id']),
      fingerprint: serializer.fromJson<String>(json['fingerprint']),
      subject: serializer.fromJson<String>(json['subject']),
      qtype: serializer.fromJson<String>(json['qtype']),
      difficulty: serializer.fromJson<int>(json['difficulty']),
      source: serializer.fromJson<String?>(json['source']),
      sourceType: serializer.fromJson<String>(json['sourceType']),
      sourceYear: serializer.fromJson<int?>(json['sourceYear']),
      filePath: serializer.fromJson<String>(json['filePath']),
      stemText: serializer.fromJson<String>(json['stemText']),
      searchTokens: serializer.fromJson<String>(json['searchTokens']),
      primaryKpWeight: serializer.fromJson<double?>(json['primaryKpWeight']),
      primaryKpName: serializer.fromJson<String?>(json['primaryKpName']),
      parseWarnings: serializer.fromJson<String?>(json['parseWarnings']),
      needsReview: serializer.fromJson<bool>(json['needsReview']),
      aiTagged: serializer.fromJson<bool>(json['aiTagged']),
      aiConfidence: serializer.fromJson<double?>(json['aiConfidence']),
      createdAt: serializer.fromJson<DateTime?>(json['createdAt']),
      fileModifiedAt: serializer.fromJson<DateTime?>(json['fileModifiedAt']),
      indexedAt: serializer.fromJson<DateTime>(json['indexedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'ftsRowId': serializer.toJson<int>(ftsRowId),
      'id': serializer.toJson<String>(id),
      'fingerprint': serializer.toJson<String>(fingerprint),
      'subject': serializer.toJson<String>(subject),
      'qtype': serializer.toJson<String>(qtype),
      'difficulty': serializer.toJson<int>(difficulty),
      'source': serializer.toJson<String?>(source),
      'sourceType': serializer.toJson<String>(sourceType),
      'sourceYear': serializer.toJson<int?>(sourceYear),
      'filePath': serializer.toJson<String>(filePath),
      'stemText': serializer.toJson<String>(stemText),
      'searchTokens': serializer.toJson<String>(searchTokens),
      'primaryKpWeight': serializer.toJson<double?>(primaryKpWeight),
      'primaryKpName': serializer.toJson<String?>(primaryKpName),
      'parseWarnings': serializer.toJson<String?>(parseWarnings),
      'needsReview': serializer.toJson<bool>(needsReview),
      'aiTagged': serializer.toJson<bool>(aiTagged),
      'aiConfidence': serializer.toJson<double?>(aiConfidence),
      'createdAt': serializer.toJson<DateTime?>(createdAt),
      'fileModifiedAt': serializer.toJson<DateTime?>(fileModifiedAt),
      'indexedAt': serializer.toJson<DateTime>(indexedAt),
    };
  }

  ProblemIndexRow copyWith(
          {int? ftsRowId,
          String? id,
          String? fingerprint,
          String? subject,
          String? qtype,
          int? difficulty,
          Value<String?> source = const Value.absent(),
          String? sourceType,
          Value<int?> sourceYear = const Value.absent(),
          String? filePath,
          String? stemText,
          String? searchTokens,
          Value<double?> primaryKpWeight = const Value.absent(),
          Value<String?> primaryKpName = const Value.absent(),
          Value<String?> parseWarnings = const Value.absent(),
          bool? needsReview,
          bool? aiTagged,
          Value<double?> aiConfidence = const Value.absent(),
          Value<DateTime?> createdAt = const Value.absent(),
          Value<DateTime?> fileModifiedAt = const Value.absent(),
          DateTime? indexedAt}) =>
      ProblemIndexRow(
        ftsRowId: ftsRowId ?? this.ftsRowId,
        id: id ?? this.id,
        fingerprint: fingerprint ?? this.fingerprint,
        subject: subject ?? this.subject,
        qtype: qtype ?? this.qtype,
        difficulty: difficulty ?? this.difficulty,
        source: source.present ? source.value : this.source,
        sourceType: sourceType ?? this.sourceType,
        sourceYear: sourceYear.present ? sourceYear.value : this.sourceYear,
        filePath: filePath ?? this.filePath,
        stemText: stemText ?? this.stemText,
        searchTokens: searchTokens ?? this.searchTokens,
        primaryKpWeight: primaryKpWeight.present
            ? primaryKpWeight.value
            : this.primaryKpWeight,
        primaryKpName:
            primaryKpName.present ? primaryKpName.value : this.primaryKpName,
        parseWarnings:
            parseWarnings.present ? parseWarnings.value : this.parseWarnings,
        needsReview: needsReview ?? this.needsReview,
        aiTagged: aiTagged ?? this.aiTagged,
        aiConfidence:
            aiConfidence.present ? aiConfidence.value : this.aiConfidence,
        createdAt: createdAt.present ? createdAt.value : this.createdAt,
        fileModifiedAt:
            fileModifiedAt.present ? fileModifiedAt.value : this.fileModifiedAt,
        indexedAt: indexedAt ?? this.indexedAt,
      );
  ProblemIndexRow copyWithCompanion(ProblemsIndexCompanion data) {
    return ProblemIndexRow(
      ftsRowId: data.ftsRowId.present ? data.ftsRowId.value : this.ftsRowId,
      id: data.id.present ? data.id.value : this.id,
      fingerprint:
          data.fingerprint.present ? data.fingerprint.value : this.fingerprint,
      subject: data.subject.present ? data.subject.value : this.subject,
      qtype: data.qtype.present ? data.qtype.value : this.qtype,
      difficulty:
          data.difficulty.present ? data.difficulty.value : this.difficulty,
      source: data.source.present ? data.source.value : this.source,
      sourceType:
          data.sourceType.present ? data.sourceType.value : this.sourceType,
      sourceYear:
          data.sourceYear.present ? data.sourceYear.value : this.sourceYear,
      filePath: data.filePath.present ? data.filePath.value : this.filePath,
      stemText: data.stemText.present ? data.stemText.value : this.stemText,
      searchTokens: data.searchTokens.present
          ? data.searchTokens.value
          : this.searchTokens,
      primaryKpWeight: data.primaryKpWeight.present
          ? data.primaryKpWeight.value
          : this.primaryKpWeight,
      primaryKpName: data.primaryKpName.present
          ? data.primaryKpName.value
          : this.primaryKpName,
      parseWarnings: data.parseWarnings.present
          ? data.parseWarnings.value
          : this.parseWarnings,
      needsReview:
          data.needsReview.present ? data.needsReview.value : this.needsReview,
      aiTagged: data.aiTagged.present ? data.aiTagged.value : this.aiTagged,
      aiConfidence: data.aiConfidence.present
          ? data.aiConfidence.value
          : this.aiConfidence,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      fileModifiedAt: data.fileModifiedAt.present
          ? data.fileModifiedAt.value
          : this.fileModifiedAt,
      indexedAt: data.indexedAt.present ? data.indexedAt.value : this.indexedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ProblemIndexRow(')
          ..write('ftsRowId: $ftsRowId, ')
          ..write('id: $id, ')
          ..write('fingerprint: $fingerprint, ')
          ..write('subject: $subject, ')
          ..write('qtype: $qtype, ')
          ..write('difficulty: $difficulty, ')
          ..write('source: $source, ')
          ..write('sourceType: $sourceType, ')
          ..write('sourceYear: $sourceYear, ')
          ..write('filePath: $filePath, ')
          ..write('stemText: $stemText, ')
          ..write('searchTokens: $searchTokens, ')
          ..write('primaryKpWeight: $primaryKpWeight, ')
          ..write('primaryKpName: $primaryKpName, ')
          ..write('parseWarnings: $parseWarnings, ')
          ..write('needsReview: $needsReview, ')
          ..write('aiTagged: $aiTagged, ')
          ..write('aiConfidence: $aiConfidence, ')
          ..write('createdAt: $createdAt, ')
          ..write('fileModifiedAt: $fileModifiedAt, ')
          ..write('indexedAt: $indexedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
        ftsRowId,
        id,
        fingerprint,
        subject,
        qtype,
        difficulty,
        source,
        sourceType,
        sourceYear,
        filePath,
        stemText,
        searchTokens,
        primaryKpWeight,
        primaryKpName,
        parseWarnings,
        needsReview,
        aiTagged,
        aiConfidence,
        createdAt,
        fileModifiedAt,
        indexedAt
      ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ProblemIndexRow &&
          other.ftsRowId == this.ftsRowId &&
          other.id == this.id &&
          other.fingerprint == this.fingerprint &&
          other.subject == this.subject &&
          other.qtype == this.qtype &&
          other.difficulty == this.difficulty &&
          other.source == this.source &&
          other.sourceType == this.sourceType &&
          other.sourceYear == this.sourceYear &&
          other.filePath == this.filePath &&
          other.stemText == this.stemText &&
          other.searchTokens == this.searchTokens &&
          other.primaryKpWeight == this.primaryKpWeight &&
          other.primaryKpName == this.primaryKpName &&
          other.parseWarnings == this.parseWarnings &&
          other.needsReview == this.needsReview &&
          other.aiTagged == this.aiTagged &&
          other.aiConfidence == this.aiConfidence &&
          other.createdAt == this.createdAt &&
          other.fileModifiedAt == this.fileModifiedAt &&
          other.indexedAt == this.indexedAt);
}

class ProblemsIndexCompanion extends UpdateCompanion<ProblemIndexRow> {
  final Value<int> ftsRowId;
  final Value<String> id;
  final Value<String> fingerprint;
  final Value<String> subject;
  final Value<String> qtype;
  final Value<int> difficulty;
  final Value<String?> source;
  final Value<String> sourceType;
  final Value<int?> sourceYear;
  final Value<String> filePath;
  final Value<String> stemText;
  final Value<String> searchTokens;
  final Value<double?> primaryKpWeight;
  final Value<String?> primaryKpName;
  final Value<String?> parseWarnings;
  final Value<bool> needsReview;
  final Value<bool> aiTagged;
  final Value<double?> aiConfidence;
  final Value<DateTime?> createdAt;
  final Value<DateTime?> fileModifiedAt;
  final Value<DateTime> indexedAt;
  const ProblemsIndexCompanion({
    this.ftsRowId = const Value.absent(),
    this.id = const Value.absent(),
    this.fingerprint = const Value.absent(),
    this.subject = const Value.absent(),
    this.qtype = const Value.absent(),
    this.difficulty = const Value.absent(),
    this.source = const Value.absent(),
    this.sourceType = const Value.absent(),
    this.sourceYear = const Value.absent(),
    this.filePath = const Value.absent(),
    this.stemText = const Value.absent(),
    this.searchTokens = const Value.absent(),
    this.primaryKpWeight = const Value.absent(),
    this.primaryKpName = const Value.absent(),
    this.parseWarnings = const Value.absent(),
    this.needsReview = const Value.absent(),
    this.aiTagged = const Value.absent(),
    this.aiConfidence = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.fileModifiedAt = const Value.absent(),
    this.indexedAt = const Value.absent(),
  });
  ProblemsIndexCompanion.insert({
    this.ftsRowId = const Value.absent(),
    required String id,
    required String fingerprint,
    required String subject,
    required String qtype,
    this.difficulty = const Value.absent(),
    this.source = const Value.absent(),
    this.sourceType = const Value.absent(),
    this.sourceYear = const Value.absent(),
    required String filePath,
    required String stemText,
    this.searchTokens = const Value.absent(),
    this.primaryKpWeight = const Value.absent(),
    this.primaryKpName = const Value.absent(),
    this.parseWarnings = const Value.absent(),
    this.needsReview = const Value.absent(),
    this.aiTagged = const Value.absent(),
    this.aiConfidence = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.fileModifiedAt = const Value.absent(),
    this.indexedAt = const Value.absent(),
  })  : id = Value(id),
        fingerprint = Value(fingerprint),
        subject = Value(subject),
        qtype = Value(qtype),
        filePath = Value(filePath),
        stemText = Value(stemText);
  static Insertable<ProblemIndexRow> custom({
    Expression<int>? ftsRowId,
    Expression<String>? id,
    Expression<String>? fingerprint,
    Expression<String>? subject,
    Expression<String>? qtype,
    Expression<int>? difficulty,
    Expression<String>? source,
    Expression<String>? sourceType,
    Expression<int>? sourceYear,
    Expression<String>? filePath,
    Expression<String>? stemText,
    Expression<String>? searchTokens,
    Expression<double>? primaryKpWeight,
    Expression<String>? primaryKpName,
    Expression<String>? parseWarnings,
    Expression<bool>? needsReview,
    Expression<bool>? aiTagged,
    Expression<double>? aiConfidence,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? fileModifiedAt,
    Expression<DateTime>? indexedAt,
  }) {
    return RawValuesInsertable({
      if (ftsRowId != null) 'rowid': ftsRowId,
      if (id != null) 'id': id,
      if (fingerprint != null) 'fingerprint': fingerprint,
      if (subject != null) 'subject': subject,
      if (qtype != null) 'qtype': qtype,
      if (difficulty != null) 'difficulty': difficulty,
      if (source != null) 'source': source,
      if (sourceType != null) 'source_type': sourceType,
      if (sourceYear != null) 'source_year': sourceYear,
      if (filePath != null) 'file_path': filePath,
      if (stemText != null) 'stem_text': stemText,
      if (searchTokens != null) 'search_tokens': searchTokens,
      if (primaryKpWeight != null) 'primary_kp_weight': primaryKpWeight,
      if (primaryKpName != null) 'primary_kp_name': primaryKpName,
      if (parseWarnings != null) 'parse_warnings': parseWarnings,
      if (needsReview != null) 'needs_review': needsReview,
      if (aiTagged != null) 'ai_tagged': aiTagged,
      if (aiConfidence != null) 'ai_confidence': aiConfidence,
      if (createdAt != null) 'created_at': createdAt,
      if (fileModifiedAt != null) 'file_modified_at': fileModifiedAt,
      if (indexedAt != null) 'indexed_at': indexedAt,
    });
  }

  ProblemsIndexCompanion copyWith(
      {Value<int>? ftsRowId,
      Value<String>? id,
      Value<String>? fingerprint,
      Value<String>? subject,
      Value<String>? qtype,
      Value<int>? difficulty,
      Value<String?>? source,
      Value<String>? sourceType,
      Value<int?>? sourceYear,
      Value<String>? filePath,
      Value<String>? stemText,
      Value<String>? searchTokens,
      Value<double?>? primaryKpWeight,
      Value<String?>? primaryKpName,
      Value<String?>? parseWarnings,
      Value<bool>? needsReview,
      Value<bool>? aiTagged,
      Value<double?>? aiConfidence,
      Value<DateTime?>? createdAt,
      Value<DateTime?>? fileModifiedAt,
      Value<DateTime>? indexedAt}) {
    return ProblemsIndexCompanion(
      ftsRowId: ftsRowId ?? this.ftsRowId,
      id: id ?? this.id,
      fingerprint: fingerprint ?? this.fingerprint,
      subject: subject ?? this.subject,
      qtype: qtype ?? this.qtype,
      difficulty: difficulty ?? this.difficulty,
      source: source ?? this.source,
      sourceType: sourceType ?? this.sourceType,
      sourceYear: sourceYear ?? this.sourceYear,
      filePath: filePath ?? this.filePath,
      stemText: stemText ?? this.stemText,
      searchTokens: searchTokens ?? this.searchTokens,
      primaryKpWeight: primaryKpWeight ?? this.primaryKpWeight,
      primaryKpName: primaryKpName ?? this.primaryKpName,
      parseWarnings: parseWarnings ?? this.parseWarnings,
      needsReview: needsReview ?? this.needsReview,
      aiTagged: aiTagged ?? this.aiTagged,
      aiConfidence: aiConfidence ?? this.aiConfidence,
      createdAt: createdAt ?? this.createdAt,
      fileModifiedAt: fileModifiedAt ?? this.fileModifiedAt,
      indexedAt: indexedAt ?? this.indexedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (ftsRowId.present) {
      map['rowid'] = Variable<int>(ftsRowId.value);
    }
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (fingerprint.present) {
      map['fingerprint'] = Variable<String>(fingerprint.value);
    }
    if (subject.present) {
      map['subject'] = Variable<String>(subject.value);
    }
    if (qtype.present) {
      map['qtype'] = Variable<String>(qtype.value);
    }
    if (difficulty.present) {
      map['difficulty'] = Variable<int>(difficulty.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (sourceType.present) {
      map['source_type'] = Variable<String>(sourceType.value);
    }
    if (sourceYear.present) {
      map['source_year'] = Variable<int>(sourceYear.value);
    }
    if (filePath.present) {
      map['file_path'] = Variable<String>(filePath.value);
    }
    if (stemText.present) {
      map['stem_text'] = Variable<String>(stemText.value);
    }
    if (searchTokens.present) {
      map['search_tokens'] = Variable<String>(searchTokens.value);
    }
    if (primaryKpWeight.present) {
      map['primary_kp_weight'] = Variable<double>(primaryKpWeight.value);
    }
    if (primaryKpName.present) {
      map['primary_kp_name'] = Variable<String>(primaryKpName.value);
    }
    if (parseWarnings.present) {
      map['parse_warnings'] = Variable<String>(parseWarnings.value);
    }
    if (needsReview.present) {
      map['needs_review'] = Variable<bool>(needsReview.value);
    }
    if (aiTagged.present) {
      map['ai_tagged'] = Variable<bool>(aiTagged.value);
    }
    if (aiConfidence.present) {
      map['ai_confidence'] = Variable<double>(aiConfidence.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (fileModifiedAt.present) {
      map['file_modified_at'] = Variable<DateTime>(fileModifiedAt.value);
    }
    if (indexedAt.present) {
      map['indexed_at'] = Variable<DateTime>(indexedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ProblemsIndexCompanion(')
          ..write('ftsRowId: $ftsRowId, ')
          ..write('id: $id, ')
          ..write('fingerprint: $fingerprint, ')
          ..write('subject: $subject, ')
          ..write('qtype: $qtype, ')
          ..write('difficulty: $difficulty, ')
          ..write('source: $source, ')
          ..write('sourceType: $sourceType, ')
          ..write('sourceYear: $sourceYear, ')
          ..write('filePath: $filePath, ')
          ..write('stemText: $stemText, ')
          ..write('searchTokens: $searchTokens, ')
          ..write('primaryKpWeight: $primaryKpWeight, ')
          ..write('primaryKpName: $primaryKpName, ')
          ..write('parseWarnings: $parseWarnings, ')
          ..write('needsReview: $needsReview, ')
          ..write('aiTagged: $aiTagged, ')
          ..write('aiConfidence: $aiConfidence, ')
          ..write('createdAt: $createdAt, ')
          ..write('fileModifiedAt: $fileModifiedAt, ')
          ..write('indexedAt: $indexedAt')
          ..write(')'))
        .toString();
  }
}

class $ProblemKnowledgeTable extends ProblemKnowledge
    with TableInfo<$ProblemKnowledgeTable, ProblemKnowledgeRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ProblemKnowledgeTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _problemIdMeta =
      const VerificationMeta('problemId');
  @override
  late final GeneratedColumn<String> problemId = GeneratedColumn<String>(
      'problem_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _kpIdMeta = const VerificationMeta('kpId');
  @override
  late final GeneratedColumn<String> kpId = GeneratedColumn<String>(
      'kp_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _roleMeta = const VerificationMeta('role');
  @override
  late final GeneratedColumn<String> role = GeneratedColumn<String>(
      'role', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('secondary'));
  static const VerificationMeta _relevanceMeta =
      const VerificationMeta('relevance');
  @override
  late final GeneratedColumn<double> relevance = GeneratedColumn<double>(
      'relevance', aliasedName, false,
      type: DriftSqlType.double,
      requiredDuringInsert: false,
      defaultValue: const Constant(1.0));
  @override
  List<GeneratedColumn> get $columns => [id, problemId, kpId, role, relevance];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'problem_knowledge';
  @override
  VerificationContext validateIntegrity(
      Insertable<ProblemKnowledgeRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('problem_id')) {
      context.handle(_problemIdMeta,
          problemId.isAcceptableOrUnknown(data['problem_id']!, _problemIdMeta));
    } else if (isInserting) {
      context.missing(_problemIdMeta);
    }
    if (data.containsKey('kp_id')) {
      context.handle(
          _kpIdMeta, kpId.isAcceptableOrUnknown(data['kp_id']!, _kpIdMeta));
    } else if (isInserting) {
      context.missing(_kpIdMeta);
    }
    if (data.containsKey('role')) {
      context.handle(
          _roleMeta, role.isAcceptableOrUnknown(data['role']!, _roleMeta));
    }
    if (data.containsKey('relevance')) {
      context.handle(_relevanceMeta,
          relevance.isAcceptableOrUnknown(data['relevance']!, _relevanceMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ProblemKnowledgeRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ProblemKnowledgeRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      problemId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}problem_id'])!,
      kpId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}kp_id'])!,
      role: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}role'])!,
      relevance: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}relevance'])!,
    );
  }

  @override
  $ProblemKnowledgeTable createAlias(String alias) {
    return $ProblemKnowledgeTable(attachedDatabase, alias);
  }
}

class ProblemKnowledgeRow extends DataClass
    implements Insertable<ProblemKnowledgeRow> {
  final int id;

  /// 对应 [ProblemsIndex.id]。
  final String problemId;

  /// 知识点 id，必须在知识点本体中存在。
  final String kpId;

  /// `primary`（有且仅有一个）或 `secondary`。
  final String role;

  /// 相关度 0–1。
  final double relevance;
  const ProblemKnowledgeRow(
      {required this.id,
      required this.problemId,
      required this.kpId,
      required this.role,
      required this.relevance});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['problem_id'] = Variable<String>(problemId);
    map['kp_id'] = Variable<String>(kpId);
    map['role'] = Variable<String>(role);
    map['relevance'] = Variable<double>(relevance);
    return map;
  }

  ProblemKnowledgeCompanion toCompanion(bool nullToAbsent) {
    return ProblemKnowledgeCompanion(
      id: Value(id),
      problemId: Value(problemId),
      kpId: Value(kpId),
      role: Value(role),
      relevance: Value(relevance),
    );
  }

  factory ProblemKnowledgeRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ProblemKnowledgeRow(
      id: serializer.fromJson<int>(json['id']),
      problemId: serializer.fromJson<String>(json['problemId']),
      kpId: serializer.fromJson<String>(json['kpId']),
      role: serializer.fromJson<String>(json['role']),
      relevance: serializer.fromJson<double>(json['relevance']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'problemId': serializer.toJson<String>(problemId),
      'kpId': serializer.toJson<String>(kpId),
      'role': serializer.toJson<String>(role),
      'relevance': serializer.toJson<double>(relevance),
    };
  }

  ProblemKnowledgeRow copyWith(
          {int? id,
          String? problemId,
          String? kpId,
          String? role,
          double? relevance}) =>
      ProblemKnowledgeRow(
        id: id ?? this.id,
        problemId: problemId ?? this.problemId,
        kpId: kpId ?? this.kpId,
        role: role ?? this.role,
        relevance: relevance ?? this.relevance,
      );
  ProblemKnowledgeRow copyWithCompanion(ProblemKnowledgeCompanion data) {
    return ProblemKnowledgeRow(
      id: data.id.present ? data.id.value : this.id,
      problemId: data.problemId.present ? data.problemId.value : this.problemId,
      kpId: data.kpId.present ? data.kpId.value : this.kpId,
      role: data.role.present ? data.role.value : this.role,
      relevance: data.relevance.present ? data.relevance.value : this.relevance,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ProblemKnowledgeRow(')
          ..write('id: $id, ')
          ..write('problemId: $problemId, ')
          ..write('kpId: $kpId, ')
          ..write('role: $role, ')
          ..write('relevance: $relevance')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, problemId, kpId, role, relevance);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ProblemKnowledgeRow &&
          other.id == this.id &&
          other.problemId == this.problemId &&
          other.kpId == this.kpId &&
          other.role == this.role &&
          other.relevance == this.relevance);
}

class ProblemKnowledgeCompanion extends UpdateCompanion<ProblemKnowledgeRow> {
  final Value<int> id;
  final Value<String> problemId;
  final Value<String> kpId;
  final Value<String> role;
  final Value<double> relevance;
  const ProblemKnowledgeCompanion({
    this.id = const Value.absent(),
    this.problemId = const Value.absent(),
    this.kpId = const Value.absent(),
    this.role = const Value.absent(),
    this.relevance = const Value.absent(),
  });
  ProblemKnowledgeCompanion.insert({
    this.id = const Value.absent(),
    required String problemId,
    required String kpId,
    this.role = const Value.absent(),
    this.relevance = const Value.absent(),
  })  : problemId = Value(problemId),
        kpId = Value(kpId);
  static Insertable<ProblemKnowledgeRow> custom({
    Expression<int>? id,
    Expression<String>? problemId,
    Expression<String>? kpId,
    Expression<String>? role,
    Expression<double>? relevance,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (problemId != null) 'problem_id': problemId,
      if (kpId != null) 'kp_id': kpId,
      if (role != null) 'role': role,
      if (relevance != null) 'relevance': relevance,
    });
  }

  ProblemKnowledgeCompanion copyWith(
      {Value<int>? id,
      Value<String>? problemId,
      Value<String>? kpId,
      Value<String>? role,
      Value<double>? relevance}) {
    return ProblemKnowledgeCompanion(
      id: id ?? this.id,
      problemId: problemId ?? this.problemId,
      kpId: kpId ?? this.kpId,
      role: role ?? this.role,
      relevance: relevance ?? this.relevance,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (problemId.present) {
      map['problem_id'] = Variable<String>(problemId.value);
    }
    if (kpId.present) {
      map['kp_id'] = Variable<String>(kpId.value);
    }
    if (role.present) {
      map['role'] = Variable<String>(role.value);
    }
    if (relevance.present) {
      map['relevance'] = Variable<double>(relevance.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ProblemKnowledgeCompanion(')
          ..write('id: $id, ')
          ..write('problemId: $problemId, ')
          ..write('kpId: $kpId, ')
          ..write('role: $role, ')
          ..write('relevance: $relevance')
          ..write(')'))
        .toString();
  }
}

class $UserProblemStateTable extends UserProblemState
    with TableInfo<$UserProblemStateTable, UserProblemStateRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $UserProblemStateTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _problemIdMeta =
      const VerificationMeta('problemId');
  @override
  late final GeneratedColumn<String> problemId = GeneratedColumn<String>(
      'problem_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _wrongCountMeta =
      const VerificationMeta('wrongCount');
  @override
  late final GeneratedColumn<int> wrongCount = GeneratedColumn<int>(
      'wrong_count', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(1));
  static const VerificationMeta _firstSeenMeta =
      const VerificationMeta('firstSeen');
  @override
  late final GeneratedColumn<DateTime> firstSeen = GeneratedColumn<DateTime>(
      'first_seen', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  static const VerificationMeta _lastWrongMeta =
      const VerificationMeta('lastWrong');
  @override
  late final GeneratedColumn<DateTime> lastWrong = GeneratedColumn<DateTime>(
      'last_wrong', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  static const VerificationMeta _fsrsStateMeta =
      const VerificationMeta('fsrsState');
  @override
  late final GeneratedColumn<String> fsrsState = GeneratedColumn<String>(
      'fsrs_state', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _masteryMeta =
      const VerificationMeta('mastery');
  @override
  late final GeneratedColumn<double> mastery = GeneratedColumn<double>(
      'mastery', aliasedName, false,
      type: DriftSqlType.double,
      requiredDuringInsert: false,
      defaultValue: const Constant(0.0));
  static const VerificationMeta _errorCausesMeta =
      const VerificationMeta('errorCauses');
  @override
  late final GeneratedColumn<String> errorCauses = GeneratedColumn<String>(
      'error_causes', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('[]'));
  static const VerificationMeta _noteMeta = const VerificationMeta('note');
  @override
  late final GeneratedColumn<String> note = GeneratedColumn<String>(
      'note', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _starredMeta =
      const VerificationMeta('starred');
  @override
  late final GeneratedColumn<bool> starred = GeneratedColumn<bool>(
      'starred', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("starred" IN (0, 1))'),
      defaultValue: const Constant(false));
  @override
  List<GeneratedColumn> get $columns => [
        problemId,
        wrongCount,
        firstSeen,
        lastWrong,
        fsrsState,
        mastery,
        errorCauses,
        note,
        starred
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'user_problem_state';
  @override
  VerificationContext validateIntegrity(
      Insertable<UserProblemStateRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('problem_id')) {
      context.handle(_problemIdMeta,
          problemId.isAcceptableOrUnknown(data['problem_id']!, _problemIdMeta));
    } else if (isInserting) {
      context.missing(_problemIdMeta);
    }
    if (data.containsKey('wrong_count')) {
      context.handle(
          _wrongCountMeta,
          wrongCount.isAcceptableOrUnknown(
              data['wrong_count']!, _wrongCountMeta));
    }
    if (data.containsKey('first_seen')) {
      context.handle(_firstSeenMeta,
          firstSeen.isAcceptableOrUnknown(data['first_seen']!, _firstSeenMeta));
    }
    if (data.containsKey('last_wrong')) {
      context.handle(_lastWrongMeta,
          lastWrong.isAcceptableOrUnknown(data['last_wrong']!, _lastWrongMeta));
    }
    if (data.containsKey('fsrs_state')) {
      context.handle(_fsrsStateMeta,
          fsrsState.isAcceptableOrUnknown(data['fsrs_state']!, _fsrsStateMeta));
    }
    if (data.containsKey('mastery')) {
      context.handle(_masteryMeta,
          mastery.isAcceptableOrUnknown(data['mastery']!, _masteryMeta));
    }
    if (data.containsKey('error_causes')) {
      context.handle(
          _errorCausesMeta,
          errorCauses.isAcceptableOrUnknown(
              data['error_causes']!, _errorCausesMeta));
    }
    if (data.containsKey('note')) {
      context.handle(
          _noteMeta, note.isAcceptableOrUnknown(data['note']!, _noteMeta));
    }
    if (data.containsKey('starred')) {
      context.handle(_starredMeta,
          starred.isAcceptableOrUnknown(data['starred']!, _starredMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => const {};
  @override
  UserProblemStateRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return UserProblemStateRow(
      problemId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}problem_id'])!,
      wrongCount: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}wrong_count'])!,
      firstSeen: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}first_seen'])!,
      lastWrong: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}last_wrong']),
      fsrsState: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}fsrs_state']),
      mastery: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}mastery'])!,
      errorCauses: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}error_causes'])!,
      note: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}note']),
      starred: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}starred'])!,
    );
  }

  @override
  $UserProblemStateTable createAlias(String alias) {
    return $UserProblemStateTable(attachedDatabase, alias);
  }
}

class UserProblemStateRow extends DataClass
    implements Insertable<UserProblemStateRow> {
  /// 题目 id。一道题只有一条状态记录。
  final String problemId;

  /// 累计做错次数。
  final int wrongCount;
  final DateTime firstSeen;
  final DateTime? lastWrong;

  /// FSRS 卡片状态，`FsrsCard.toJson()` 的 JSON 字符串。
  ///
  /// 不拆成独立列的原因：FSRS 的字段集会随算法版本变化（21 个权重、
  /// 新增字段等），拆列意味着每次算法升级都要改 schema。整块 JSON 更稳。
  final String? fsrsState;

  /// 掌握度 0–1，由 FSRS 的可提取性推算。
  final double mastery;

  /// 错因（受控词表的多选），JSON 数组字符串。
  ///
  /// ⚠️ 这是**用户状态**（"我为什么错"），不是题目属性。
  /// 题干里的 `error_causes` 是 AI 预判的**易错点**，两者含义不同。
  final String errorCauses;

  /// 用户笔记。
  final String? note;

  /// 是否已收藏/标记为顽固错题。
  final bool starred;
  const UserProblemStateRow(
      {required this.problemId,
      required this.wrongCount,
      required this.firstSeen,
      this.lastWrong,
      this.fsrsState,
      required this.mastery,
      required this.errorCauses,
      this.note,
      required this.starred});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['problem_id'] = Variable<String>(problemId);
    map['wrong_count'] = Variable<int>(wrongCount);
    map['first_seen'] = Variable<DateTime>(firstSeen);
    if (!nullToAbsent || lastWrong != null) {
      map['last_wrong'] = Variable<DateTime>(lastWrong);
    }
    if (!nullToAbsent || fsrsState != null) {
      map['fsrs_state'] = Variable<String>(fsrsState);
    }
    map['mastery'] = Variable<double>(mastery);
    map['error_causes'] = Variable<String>(errorCauses);
    if (!nullToAbsent || note != null) {
      map['note'] = Variable<String>(note);
    }
    map['starred'] = Variable<bool>(starred);
    return map;
  }

  UserProblemStateCompanion toCompanion(bool nullToAbsent) {
    return UserProblemStateCompanion(
      problemId: Value(problemId),
      wrongCount: Value(wrongCount),
      firstSeen: Value(firstSeen),
      lastWrong: lastWrong == null && nullToAbsent
          ? const Value.absent()
          : Value(lastWrong),
      fsrsState: fsrsState == null && nullToAbsent
          ? const Value.absent()
          : Value(fsrsState),
      mastery: Value(mastery),
      errorCauses: Value(errorCauses),
      note: note == null && nullToAbsent ? const Value.absent() : Value(note),
      starred: Value(starred),
    );
  }

  factory UserProblemStateRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return UserProblemStateRow(
      problemId: serializer.fromJson<String>(json['problemId']),
      wrongCount: serializer.fromJson<int>(json['wrongCount']),
      firstSeen: serializer.fromJson<DateTime>(json['firstSeen']),
      lastWrong: serializer.fromJson<DateTime?>(json['lastWrong']),
      fsrsState: serializer.fromJson<String?>(json['fsrsState']),
      mastery: serializer.fromJson<double>(json['mastery']),
      errorCauses: serializer.fromJson<String>(json['errorCauses']),
      note: serializer.fromJson<String?>(json['note']),
      starred: serializer.fromJson<bool>(json['starred']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'problemId': serializer.toJson<String>(problemId),
      'wrongCount': serializer.toJson<int>(wrongCount),
      'firstSeen': serializer.toJson<DateTime>(firstSeen),
      'lastWrong': serializer.toJson<DateTime?>(lastWrong),
      'fsrsState': serializer.toJson<String?>(fsrsState),
      'mastery': serializer.toJson<double>(mastery),
      'errorCauses': serializer.toJson<String>(errorCauses),
      'note': serializer.toJson<String?>(note),
      'starred': serializer.toJson<bool>(starred),
    };
  }

  UserProblemStateRow copyWith(
          {String? problemId,
          int? wrongCount,
          DateTime? firstSeen,
          Value<DateTime?> lastWrong = const Value.absent(),
          Value<String?> fsrsState = const Value.absent(),
          double? mastery,
          String? errorCauses,
          Value<String?> note = const Value.absent(),
          bool? starred}) =>
      UserProblemStateRow(
        problemId: problemId ?? this.problemId,
        wrongCount: wrongCount ?? this.wrongCount,
        firstSeen: firstSeen ?? this.firstSeen,
        lastWrong: lastWrong.present ? lastWrong.value : this.lastWrong,
        fsrsState: fsrsState.present ? fsrsState.value : this.fsrsState,
        mastery: mastery ?? this.mastery,
        errorCauses: errorCauses ?? this.errorCauses,
        note: note.present ? note.value : this.note,
        starred: starred ?? this.starred,
      );
  UserProblemStateRow copyWithCompanion(UserProblemStateCompanion data) {
    return UserProblemStateRow(
      problemId: data.problemId.present ? data.problemId.value : this.problemId,
      wrongCount:
          data.wrongCount.present ? data.wrongCount.value : this.wrongCount,
      firstSeen: data.firstSeen.present ? data.firstSeen.value : this.firstSeen,
      lastWrong: data.lastWrong.present ? data.lastWrong.value : this.lastWrong,
      fsrsState: data.fsrsState.present ? data.fsrsState.value : this.fsrsState,
      mastery: data.mastery.present ? data.mastery.value : this.mastery,
      errorCauses:
          data.errorCauses.present ? data.errorCauses.value : this.errorCauses,
      note: data.note.present ? data.note.value : this.note,
      starred: data.starred.present ? data.starred.value : this.starred,
    );
  }

  @override
  String toString() {
    return (StringBuffer('UserProblemStateRow(')
          ..write('problemId: $problemId, ')
          ..write('wrongCount: $wrongCount, ')
          ..write('firstSeen: $firstSeen, ')
          ..write('lastWrong: $lastWrong, ')
          ..write('fsrsState: $fsrsState, ')
          ..write('mastery: $mastery, ')
          ..write('errorCauses: $errorCauses, ')
          ..write('note: $note, ')
          ..write('starred: $starred')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(problemId, wrongCount, firstSeen, lastWrong,
      fsrsState, mastery, errorCauses, note, starred);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is UserProblemStateRow &&
          other.problemId == this.problemId &&
          other.wrongCount == this.wrongCount &&
          other.firstSeen == this.firstSeen &&
          other.lastWrong == this.lastWrong &&
          other.fsrsState == this.fsrsState &&
          other.mastery == this.mastery &&
          other.errorCauses == this.errorCauses &&
          other.note == this.note &&
          other.starred == this.starred);
}

class UserProblemStateCompanion extends UpdateCompanion<UserProblemStateRow> {
  final Value<String> problemId;
  final Value<int> wrongCount;
  final Value<DateTime> firstSeen;
  final Value<DateTime?> lastWrong;
  final Value<String?> fsrsState;
  final Value<double> mastery;
  final Value<String> errorCauses;
  final Value<String?> note;
  final Value<bool> starred;
  final Value<int> rowid;
  const UserProblemStateCompanion({
    this.problemId = const Value.absent(),
    this.wrongCount = const Value.absent(),
    this.firstSeen = const Value.absent(),
    this.lastWrong = const Value.absent(),
    this.fsrsState = const Value.absent(),
    this.mastery = const Value.absent(),
    this.errorCauses = const Value.absent(),
    this.note = const Value.absent(),
    this.starred = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  UserProblemStateCompanion.insert({
    required String problemId,
    this.wrongCount = const Value.absent(),
    this.firstSeen = const Value.absent(),
    this.lastWrong = const Value.absent(),
    this.fsrsState = const Value.absent(),
    this.mastery = const Value.absent(),
    this.errorCauses = const Value.absent(),
    this.note = const Value.absent(),
    this.starred = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : problemId = Value(problemId);
  static Insertable<UserProblemStateRow> custom({
    Expression<String>? problemId,
    Expression<int>? wrongCount,
    Expression<DateTime>? firstSeen,
    Expression<DateTime>? lastWrong,
    Expression<String>? fsrsState,
    Expression<double>? mastery,
    Expression<String>? errorCauses,
    Expression<String>? note,
    Expression<bool>? starred,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (problemId != null) 'problem_id': problemId,
      if (wrongCount != null) 'wrong_count': wrongCount,
      if (firstSeen != null) 'first_seen': firstSeen,
      if (lastWrong != null) 'last_wrong': lastWrong,
      if (fsrsState != null) 'fsrs_state': fsrsState,
      if (mastery != null) 'mastery': mastery,
      if (errorCauses != null) 'error_causes': errorCauses,
      if (note != null) 'note': note,
      if (starred != null) 'starred': starred,
      if (rowid != null) 'rowid': rowid,
    });
  }

  UserProblemStateCompanion copyWith(
      {Value<String>? problemId,
      Value<int>? wrongCount,
      Value<DateTime>? firstSeen,
      Value<DateTime?>? lastWrong,
      Value<String?>? fsrsState,
      Value<double>? mastery,
      Value<String>? errorCauses,
      Value<String?>? note,
      Value<bool>? starred,
      Value<int>? rowid}) {
    return UserProblemStateCompanion(
      problemId: problemId ?? this.problemId,
      wrongCount: wrongCount ?? this.wrongCount,
      firstSeen: firstSeen ?? this.firstSeen,
      lastWrong: lastWrong ?? this.lastWrong,
      fsrsState: fsrsState ?? this.fsrsState,
      mastery: mastery ?? this.mastery,
      errorCauses: errorCauses ?? this.errorCauses,
      note: note ?? this.note,
      starred: starred ?? this.starred,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (problemId.present) {
      map['problem_id'] = Variable<String>(problemId.value);
    }
    if (wrongCount.present) {
      map['wrong_count'] = Variable<int>(wrongCount.value);
    }
    if (firstSeen.present) {
      map['first_seen'] = Variable<DateTime>(firstSeen.value);
    }
    if (lastWrong.present) {
      map['last_wrong'] = Variable<DateTime>(lastWrong.value);
    }
    if (fsrsState.present) {
      map['fsrs_state'] = Variable<String>(fsrsState.value);
    }
    if (mastery.present) {
      map['mastery'] = Variable<double>(mastery.value);
    }
    if (errorCauses.present) {
      map['error_causes'] = Variable<String>(errorCauses.value);
    }
    if (note.present) {
      map['note'] = Variable<String>(note.value);
    }
    if (starred.present) {
      map['starred'] = Variable<bool>(starred.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('UserProblemStateCompanion(')
          ..write('problemId: $problemId, ')
          ..write('wrongCount: $wrongCount, ')
          ..write('firstSeen: $firstSeen, ')
          ..write('lastWrong: $lastWrong, ')
          ..write('fsrsState: $fsrsState, ')
          ..write('mastery: $mastery, ')
          ..write('errorCauses: $errorCauses, ')
          ..write('note: $note, ')
          ..write('starred: $starred, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ReviewLogsTable extends ReviewLogs
    with TableInfo<$ReviewLogsTable, ReviewLogRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ReviewLogsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _problemIdMeta =
      const VerificationMeta('problemId');
  @override
  late final GeneratedColumn<String> problemId = GeneratedColumn<String>(
      'problem_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _ratingMeta = const VerificationMeta('rating');
  @override
  late final GeneratedColumn<int> rating = GeneratedColumn<int>(
      'rating', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _elapsedMsMeta =
      const VerificationMeta('elapsedMs');
  @override
  late final GeneratedColumn<int> elapsedMs = GeneratedColumn<int>(
      'elapsed_ms', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _elapsedDaysMeta =
      const VerificationMeta('elapsedDays');
  @override
  late final GeneratedColumn<int> elapsedDays = GeneratedColumn<int>(
      'elapsed_days', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _scheduledDaysMeta =
      const VerificationMeta('scheduledDays');
  @override
  late final GeneratedColumn<int> scheduledDays = GeneratedColumn<int>(
      'scheduled_days', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _stabilityAfterMeta =
      const VerificationMeta('stabilityAfter');
  @override
  late final GeneratedColumn<double> stabilityAfter = GeneratedColumn<double>(
      'stability_after', aliasedName, true,
      type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _difficultyAfterMeta =
      const VerificationMeta('difficultyAfter');
  @override
  late final GeneratedColumn<double> difficultyAfter = GeneratedColumn<double>(
      'difficulty_after', aliasedName, true,
      type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _reviewedAtMeta =
      const VerificationMeta('reviewedAt');
  @override
  late final GeneratedColumn<DateTime> reviewedAt = GeneratedColumn<DateTime>(
      'reviewed_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        problemId,
        rating,
        elapsedMs,
        elapsedDays,
        scheduledDays,
        stabilityAfter,
        difficultyAfter,
        reviewedAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'review_logs';
  @override
  VerificationContext validateIntegrity(Insertable<ReviewLogRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('problem_id')) {
      context.handle(_problemIdMeta,
          problemId.isAcceptableOrUnknown(data['problem_id']!, _problemIdMeta));
    } else if (isInserting) {
      context.missing(_problemIdMeta);
    }
    if (data.containsKey('rating')) {
      context.handle(_ratingMeta,
          rating.isAcceptableOrUnknown(data['rating']!, _ratingMeta));
    } else if (isInserting) {
      context.missing(_ratingMeta);
    }
    if (data.containsKey('elapsed_ms')) {
      context.handle(_elapsedMsMeta,
          elapsedMs.isAcceptableOrUnknown(data['elapsed_ms']!, _elapsedMsMeta));
    }
    if (data.containsKey('elapsed_days')) {
      context.handle(
          _elapsedDaysMeta,
          elapsedDays.isAcceptableOrUnknown(
              data['elapsed_days']!, _elapsedDaysMeta));
    }
    if (data.containsKey('scheduled_days')) {
      context.handle(
          _scheduledDaysMeta,
          scheduledDays.isAcceptableOrUnknown(
              data['scheduled_days']!, _scheduledDaysMeta));
    }
    if (data.containsKey('stability_after')) {
      context.handle(
          _stabilityAfterMeta,
          stabilityAfter.isAcceptableOrUnknown(
              data['stability_after']!, _stabilityAfterMeta));
    }
    if (data.containsKey('difficulty_after')) {
      context.handle(
          _difficultyAfterMeta,
          difficultyAfter.isAcceptableOrUnknown(
              data['difficulty_after']!, _difficultyAfterMeta));
    }
    if (data.containsKey('reviewed_at')) {
      context.handle(
          _reviewedAtMeta,
          reviewedAt.isAcceptableOrUnknown(
              data['reviewed_at']!, _reviewedAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ReviewLogRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ReviewLogRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      problemId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}problem_id'])!,
      rating: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}rating'])!,
      elapsedMs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}elapsed_ms']),
      elapsedDays: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}elapsed_days']),
      scheduledDays: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}scheduled_days']),
      stabilityAfter: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}stability_after']),
      difficultyAfter: attachedDatabase.typeMapping.read(
          DriftSqlType.double, data['${effectivePrefix}difficulty_after']),
      reviewedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}reviewed_at'])!,
    );
  }

  @override
  $ReviewLogsTable createAlias(String alias) {
    return $ReviewLogsTable(attachedDatabase, alias);
  }
}

class ReviewLogRow extends DataClass implements Insertable<ReviewLogRow> {
  final int id;

  /// 题目 id。冗余存放以便直接按题查询，避免 join [UserProblemState]。
  final String problemId;

  /// 1 = 忘了 · 2 = 吃力 · 3 = 轻松（对应 `Rating.value` 的子集）。
  final int rating;

  /// 本次作答耗时（毫秒）。用于分析"会做但慢"这类问题。
  final int? elapsedMs;

  /// 复习时距离上次复习的天数。
  final int? elapsedDays;

  /// 本次安排的下次间隔天数。
  final int? scheduledDays;

  /// 复习后的稳定性与难度快照，便于回放分析算法行为。
  final double? stabilityAfter;
  final double? difficultyAfter;
  final DateTime reviewedAt;
  const ReviewLogRow(
      {required this.id,
      required this.problemId,
      required this.rating,
      this.elapsedMs,
      this.elapsedDays,
      this.scheduledDays,
      this.stabilityAfter,
      this.difficultyAfter,
      required this.reviewedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['problem_id'] = Variable<String>(problemId);
    map['rating'] = Variable<int>(rating);
    if (!nullToAbsent || elapsedMs != null) {
      map['elapsed_ms'] = Variable<int>(elapsedMs);
    }
    if (!nullToAbsent || elapsedDays != null) {
      map['elapsed_days'] = Variable<int>(elapsedDays);
    }
    if (!nullToAbsent || scheduledDays != null) {
      map['scheduled_days'] = Variable<int>(scheduledDays);
    }
    if (!nullToAbsent || stabilityAfter != null) {
      map['stability_after'] = Variable<double>(stabilityAfter);
    }
    if (!nullToAbsent || difficultyAfter != null) {
      map['difficulty_after'] = Variable<double>(difficultyAfter);
    }
    map['reviewed_at'] = Variable<DateTime>(reviewedAt);
    return map;
  }

  ReviewLogsCompanion toCompanion(bool nullToAbsent) {
    return ReviewLogsCompanion(
      id: Value(id),
      problemId: Value(problemId),
      rating: Value(rating),
      elapsedMs: elapsedMs == null && nullToAbsent
          ? const Value.absent()
          : Value(elapsedMs),
      elapsedDays: elapsedDays == null && nullToAbsent
          ? const Value.absent()
          : Value(elapsedDays),
      scheduledDays: scheduledDays == null && nullToAbsent
          ? const Value.absent()
          : Value(scheduledDays),
      stabilityAfter: stabilityAfter == null && nullToAbsent
          ? const Value.absent()
          : Value(stabilityAfter),
      difficultyAfter: difficultyAfter == null && nullToAbsent
          ? const Value.absent()
          : Value(difficultyAfter),
      reviewedAt: Value(reviewedAt),
    );
  }

  factory ReviewLogRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ReviewLogRow(
      id: serializer.fromJson<int>(json['id']),
      problemId: serializer.fromJson<String>(json['problemId']),
      rating: serializer.fromJson<int>(json['rating']),
      elapsedMs: serializer.fromJson<int?>(json['elapsedMs']),
      elapsedDays: serializer.fromJson<int?>(json['elapsedDays']),
      scheduledDays: serializer.fromJson<int?>(json['scheduledDays']),
      stabilityAfter: serializer.fromJson<double?>(json['stabilityAfter']),
      difficultyAfter: serializer.fromJson<double?>(json['difficultyAfter']),
      reviewedAt: serializer.fromJson<DateTime>(json['reviewedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'problemId': serializer.toJson<String>(problemId),
      'rating': serializer.toJson<int>(rating),
      'elapsedMs': serializer.toJson<int?>(elapsedMs),
      'elapsedDays': serializer.toJson<int?>(elapsedDays),
      'scheduledDays': serializer.toJson<int?>(scheduledDays),
      'stabilityAfter': serializer.toJson<double?>(stabilityAfter),
      'difficultyAfter': serializer.toJson<double?>(difficultyAfter),
      'reviewedAt': serializer.toJson<DateTime>(reviewedAt),
    };
  }

  ReviewLogRow copyWith(
          {int? id,
          String? problemId,
          int? rating,
          Value<int?> elapsedMs = const Value.absent(),
          Value<int?> elapsedDays = const Value.absent(),
          Value<int?> scheduledDays = const Value.absent(),
          Value<double?> stabilityAfter = const Value.absent(),
          Value<double?> difficultyAfter = const Value.absent(),
          DateTime? reviewedAt}) =>
      ReviewLogRow(
        id: id ?? this.id,
        problemId: problemId ?? this.problemId,
        rating: rating ?? this.rating,
        elapsedMs: elapsedMs.present ? elapsedMs.value : this.elapsedMs,
        elapsedDays: elapsedDays.present ? elapsedDays.value : this.elapsedDays,
        scheduledDays:
            scheduledDays.present ? scheduledDays.value : this.scheduledDays,
        stabilityAfter:
            stabilityAfter.present ? stabilityAfter.value : this.stabilityAfter,
        difficultyAfter: difficultyAfter.present
            ? difficultyAfter.value
            : this.difficultyAfter,
        reviewedAt: reviewedAt ?? this.reviewedAt,
      );
  ReviewLogRow copyWithCompanion(ReviewLogsCompanion data) {
    return ReviewLogRow(
      id: data.id.present ? data.id.value : this.id,
      problemId: data.problemId.present ? data.problemId.value : this.problemId,
      rating: data.rating.present ? data.rating.value : this.rating,
      elapsedMs: data.elapsedMs.present ? data.elapsedMs.value : this.elapsedMs,
      elapsedDays:
          data.elapsedDays.present ? data.elapsedDays.value : this.elapsedDays,
      scheduledDays: data.scheduledDays.present
          ? data.scheduledDays.value
          : this.scheduledDays,
      stabilityAfter: data.stabilityAfter.present
          ? data.stabilityAfter.value
          : this.stabilityAfter,
      difficultyAfter: data.difficultyAfter.present
          ? data.difficultyAfter.value
          : this.difficultyAfter,
      reviewedAt:
          data.reviewedAt.present ? data.reviewedAt.value : this.reviewedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ReviewLogRow(')
          ..write('id: $id, ')
          ..write('problemId: $problemId, ')
          ..write('rating: $rating, ')
          ..write('elapsedMs: $elapsedMs, ')
          ..write('elapsedDays: $elapsedDays, ')
          ..write('scheduledDays: $scheduledDays, ')
          ..write('stabilityAfter: $stabilityAfter, ')
          ..write('difficultyAfter: $difficultyAfter, ')
          ..write('reviewedAt: $reviewedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, problemId, rating, elapsedMs, elapsedDays,
      scheduledDays, stabilityAfter, difficultyAfter, reviewedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ReviewLogRow &&
          other.id == this.id &&
          other.problemId == this.problemId &&
          other.rating == this.rating &&
          other.elapsedMs == this.elapsedMs &&
          other.elapsedDays == this.elapsedDays &&
          other.scheduledDays == this.scheduledDays &&
          other.stabilityAfter == this.stabilityAfter &&
          other.difficultyAfter == this.difficultyAfter &&
          other.reviewedAt == this.reviewedAt);
}

class ReviewLogsCompanion extends UpdateCompanion<ReviewLogRow> {
  final Value<int> id;
  final Value<String> problemId;
  final Value<int> rating;
  final Value<int?> elapsedMs;
  final Value<int?> elapsedDays;
  final Value<int?> scheduledDays;
  final Value<double?> stabilityAfter;
  final Value<double?> difficultyAfter;
  final Value<DateTime> reviewedAt;
  const ReviewLogsCompanion({
    this.id = const Value.absent(),
    this.problemId = const Value.absent(),
    this.rating = const Value.absent(),
    this.elapsedMs = const Value.absent(),
    this.elapsedDays = const Value.absent(),
    this.scheduledDays = const Value.absent(),
    this.stabilityAfter = const Value.absent(),
    this.difficultyAfter = const Value.absent(),
    this.reviewedAt = const Value.absent(),
  });
  ReviewLogsCompanion.insert({
    this.id = const Value.absent(),
    required String problemId,
    required int rating,
    this.elapsedMs = const Value.absent(),
    this.elapsedDays = const Value.absent(),
    this.scheduledDays = const Value.absent(),
    this.stabilityAfter = const Value.absent(),
    this.difficultyAfter = const Value.absent(),
    this.reviewedAt = const Value.absent(),
  })  : problemId = Value(problemId),
        rating = Value(rating);
  static Insertable<ReviewLogRow> custom({
    Expression<int>? id,
    Expression<String>? problemId,
    Expression<int>? rating,
    Expression<int>? elapsedMs,
    Expression<int>? elapsedDays,
    Expression<int>? scheduledDays,
    Expression<double>? stabilityAfter,
    Expression<double>? difficultyAfter,
    Expression<DateTime>? reviewedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (problemId != null) 'problem_id': problemId,
      if (rating != null) 'rating': rating,
      if (elapsedMs != null) 'elapsed_ms': elapsedMs,
      if (elapsedDays != null) 'elapsed_days': elapsedDays,
      if (scheduledDays != null) 'scheduled_days': scheduledDays,
      if (stabilityAfter != null) 'stability_after': stabilityAfter,
      if (difficultyAfter != null) 'difficulty_after': difficultyAfter,
      if (reviewedAt != null) 'reviewed_at': reviewedAt,
    });
  }

  ReviewLogsCompanion copyWith(
      {Value<int>? id,
      Value<String>? problemId,
      Value<int>? rating,
      Value<int?>? elapsedMs,
      Value<int?>? elapsedDays,
      Value<int?>? scheduledDays,
      Value<double?>? stabilityAfter,
      Value<double?>? difficultyAfter,
      Value<DateTime>? reviewedAt}) {
    return ReviewLogsCompanion(
      id: id ?? this.id,
      problemId: problemId ?? this.problemId,
      rating: rating ?? this.rating,
      elapsedMs: elapsedMs ?? this.elapsedMs,
      elapsedDays: elapsedDays ?? this.elapsedDays,
      scheduledDays: scheduledDays ?? this.scheduledDays,
      stabilityAfter: stabilityAfter ?? this.stabilityAfter,
      difficultyAfter: difficultyAfter ?? this.difficultyAfter,
      reviewedAt: reviewedAt ?? this.reviewedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (problemId.present) {
      map['problem_id'] = Variable<String>(problemId.value);
    }
    if (rating.present) {
      map['rating'] = Variable<int>(rating.value);
    }
    if (elapsedMs.present) {
      map['elapsed_ms'] = Variable<int>(elapsedMs.value);
    }
    if (elapsedDays.present) {
      map['elapsed_days'] = Variable<int>(elapsedDays.value);
    }
    if (scheduledDays.present) {
      map['scheduled_days'] = Variable<int>(scheduledDays.value);
    }
    if (stabilityAfter.present) {
      map['stability_after'] = Variable<double>(stabilityAfter.value);
    }
    if (difficultyAfter.present) {
      map['difficulty_after'] = Variable<double>(difficultyAfter.value);
    }
    if (reviewedAt.present) {
      map['reviewed_at'] = Variable<DateTime>(reviewedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ReviewLogsCompanion(')
          ..write('id: $id, ')
          ..write('problemId: $problemId, ')
          ..write('rating: $rating, ')
          ..write('elapsedMs: $elapsedMs, ')
          ..write('elapsedDays: $elapsedDays, ')
          ..write('scheduledDays: $scheduledDays, ')
          ..write('stabilityAfter: $stabilityAfter, ')
          ..write('difficultyAfter: $difficultyAfter, ')
          ..write('reviewedAt: $reviewedAt')
          ..write(')'))
        .toString();
  }
}

class $PapersTable extends Papers with TableInfo<$PapersTable, PaperRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PapersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
      'title', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _subjectMeta =
      const VerificationMeta('subject');
  @override
  late final GeneratedColumn<String> subject = GeneratedColumn<String>(
      'subject', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _configMeta = const VerificationMeta('config');
  @override
  late final GeneratedColumn<String> config = GeneratedColumn<String>(
      'config', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _itemsMeta = const VerificationMeta('items');
  @override
  late final GeneratedColumn<String> items = GeneratedColumn<String>(
      'items', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _totalScoreMeta =
      const VerificationMeta('totalScore');
  @override
  late final GeneratedColumn<int> totalScore = GeneratedColumn<int>(
      'total_score', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  @override
  List<GeneratedColumn> get $columns =>
      [id, title, subject, config, items, totalScore, createdAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'papers';
  @override
  VerificationContext validateIntegrity(Insertable<PaperRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
          _titleMeta, title.isAcceptableOrUnknown(data['title']!, _titleMeta));
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('subject')) {
      context.handle(_subjectMeta,
          subject.isAcceptableOrUnknown(data['subject']!, _subjectMeta));
    } else if (isInserting) {
      context.missing(_subjectMeta);
    }
    if (data.containsKey('config')) {
      context.handle(_configMeta,
          config.isAcceptableOrUnknown(data['config']!, _configMeta));
    } else if (isInserting) {
      context.missing(_configMeta);
    }
    if (data.containsKey('items')) {
      context.handle(
          _itemsMeta, items.isAcceptableOrUnknown(data['items']!, _itemsMeta));
    } else if (isInserting) {
      context.missing(_itemsMeta);
    }
    if (data.containsKey('total_score')) {
      context.handle(
          _totalScoreMeta,
          totalScore.isAcceptableOrUnknown(
              data['total_score']!, _totalScoreMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PaperRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PaperRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      title: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}title'])!,
      subject: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}subject'])!,
      config: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}config'])!,
      items: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}items'])!,
      totalScore: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}total_score']),
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
    );
  }

  @override
  $PapersTable createAlias(String alias) {
    return $PapersTable(attachedDatabase, alias);
  }
}

class PaperRow extends DataClass implements Insertable<PaperRow> {
  final String id;
  final String title;
  final String subject;

  /// 组卷参数快照，JSON。
  final String config;

  /// 选中的题目与分值，JSON 数组 `[{problemId, no, score}]`。
  final String items;
  final int? totalScore;
  final DateTime createdAt;
  const PaperRow(
      {required this.id,
      required this.title,
      required this.subject,
      required this.config,
      required this.items,
      this.totalScore,
      required this.createdAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['title'] = Variable<String>(title);
    map['subject'] = Variable<String>(subject);
    map['config'] = Variable<String>(config);
    map['items'] = Variable<String>(items);
    if (!nullToAbsent || totalScore != null) {
      map['total_score'] = Variable<int>(totalScore);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  PapersCompanion toCompanion(bool nullToAbsent) {
    return PapersCompanion(
      id: Value(id),
      title: Value(title),
      subject: Value(subject),
      config: Value(config),
      items: Value(items),
      totalScore: totalScore == null && nullToAbsent
          ? const Value.absent()
          : Value(totalScore),
      createdAt: Value(createdAt),
    );
  }

  factory PaperRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PaperRow(
      id: serializer.fromJson<String>(json['id']),
      title: serializer.fromJson<String>(json['title']),
      subject: serializer.fromJson<String>(json['subject']),
      config: serializer.fromJson<String>(json['config']),
      items: serializer.fromJson<String>(json['items']),
      totalScore: serializer.fromJson<int?>(json['totalScore']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'title': serializer.toJson<String>(title),
      'subject': serializer.toJson<String>(subject),
      'config': serializer.toJson<String>(config),
      'items': serializer.toJson<String>(items),
      'totalScore': serializer.toJson<int?>(totalScore),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  PaperRow copyWith(
          {String? id,
          String? title,
          String? subject,
          String? config,
          String? items,
          Value<int?> totalScore = const Value.absent(),
          DateTime? createdAt}) =>
      PaperRow(
        id: id ?? this.id,
        title: title ?? this.title,
        subject: subject ?? this.subject,
        config: config ?? this.config,
        items: items ?? this.items,
        totalScore: totalScore.present ? totalScore.value : this.totalScore,
        createdAt: createdAt ?? this.createdAt,
      );
  PaperRow copyWithCompanion(PapersCompanion data) {
    return PaperRow(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      subject: data.subject.present ? data.subject.value : this.subject,
      config: data.config.present ? data.config.value : this.config,
      items: data.items.present ? data.items.value : this.items,
      totalScore:
          data.totalScore.present ? data.totalScore.value : this.totalScore,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PaperRow(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('subject: $subject, ')
          ..write('config: $config, ')
          ..write('items: $items, ')
          ..write('totalScore: $totalScore, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, title, subject, config, items, totalScore, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PaperRow &&
          other.id == this.id &&
          other.title == this.title &&
          other.subject == this.subject &&
          other.config == this.config &&
          other.items == this.items &&
          other.totalScore == this.totalScore &&
          other.createdAt == this.createdAt);
}

class PapersCompanion extends UpdateCompanion<PaperRow> {
  final Value<String> id;
  final Value<String> title;
  final Value<String> subject;
  final Value<String> config;
  final Value<String> items;
  final Value<int?> totalScore;
  final Value<DateTime> createdAt;
  final Value<int> rowid;
  const PapersCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.subject = const Value.absent(),
    this.config = const Value.absent(),
    this.items = const Value.absent(),
    this.totalScore = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PapersCompanion.insert({
    required String id,
    required String title,
    required String subject,
    required String config,
    required String items,
    this.totalScore = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        title = Value(title),
        subject = Value(subject),
        config = Value(config),
        items = Value(items);
  static Insertable<PaperRow> custom({
    Expression<String>? id,
    Expression<String>? title,
    Expression<String>? subject,
    Expression<String>? config,
    Expression<String>? items,
    Expression<int>? totalScore,
    Expression<DateTime>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (subject != null) 'subject': subject,
      if (config != null) 'config': config,
      if (items != null) 'items': items,
      if (totalScore != null) 'total_score': totalScore,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PapersCompanion copyWith(
      {Value<String>? id,
      Value<String>? title,
      Value<String>? subject,
      Value<String>? config,
      Value<String>? items,
      Value<int?>? totalScore,
      Value<DateTime>? createdAt,
      Value<int>? rowid}) {
    return PapersCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      subject: subject ?? this.subject,
      config: config ?? this.config,
      items: items ?? this.items,
      totalScore: totalScore ?? this.totalScore,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (subject.present) {
      map['subject'] = Variable<String>(subject.value);
    }
    if (config.present) {
      map['config'] = Variable<String>(config.value);
    }
    if (items.present) {
      map['items'] = Variable<String>(items.value);
    }
    if (totalScore.present) {
      map['total_score'] = Variable<int>(totalScore.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PapersCompanion(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('subject: $subject, ')
          ..write('config: $config, ')
          ..write('items: $items, ')
          ..write('totalScore: $totalScore, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MetaEntriesTable extends MetaEntries
    with TableInfo<$MetaEntriesTable, MetaRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MetaEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
      'key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
      'value', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  @override
  List<GeneratedColumn> get $columns => [key, value, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'meta_entries';
  @override
  VerificationContext validateIntegrity(Insertable<MetaRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
          _keyMeta, key.isAcceptableOrUnknown(data['key']!, _keyMeta));
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
          _valueMeta, value.isAcceptableOrUnknown(data['value']!, _valueMeta));
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  MetaRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MetaRow(
      key: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}key'])!,
      value: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}value'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $MetaEntriesTable createAlias(String alias) {
    return $MetaEntriesTable(attachedDatabase, alias);
  }
}

class MetaRow extends DataClass implements Insertable<MetaRow> {
  final String key;
  final String value;
  final DateTime updatedAt;
  const MetaRow(
      {required this.key, required this.value, required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  MetaEntriesCompanion toCompanion(bool nullToAbsent) {
    return MetaEntriesCompanion(
      key: Value(key),
      value: Value(value),
      updatedAt: Value(updatedAt),
    );
  }

  factory MetaRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MetaRow(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  MetaRow copyWith({String? key, String? value, DateTime? updatedAt}) =>
      MetaRow(
        key: key ?? this.key,
        value: value ?? this.value,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  MetaRow copyWithCompanion(MetaEntriesCompanion data) {
    return MetaRow(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MetaRow(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MetaRow &&
          other.key == this.key &&
          other.value == this.value &&
          other.updatedAt == this.updatedAt);
}

class MetaEntriesCompanion extends UpdateCompanion<MetaRow> {
  final Value<String> key;
  final Value<String> value;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const MetaEntriesCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MetaEntriesCompanion.insert({
    required String key,
    required String value,
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : key = Value(key),
        value = Value(value);
  static Insertable<MetaRow> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MetaEntriesCompanion copyWith(
      {Value<String>? key,
      Value<String>? value,
      Value<DateTime>? updatedAt,
      Value<int>? rowid}) {
    return MetaEntriesCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MetaEntriesCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $ProblemsIndexTable problemsIndex = $ProblemsIndexTable(this);
  late final $ProblemKnowledgeTable problemKnowledge =
      $ProblemKnowledgeTable(this);
  late final $UserProblemStateTable userProblemState =
      $UserProblemStateTable(this);
  late final $ReviewLogsTable reviewLogs = $ReviewLogsTable(this);
  late final $PapersTable papers = $PapersTable(this);
  late final $MetaEntriesTable metaEntries = $MetaEntriesTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
        problemsIndex,
        problemKnowledge,
        userProblemState,
        reviewLogs,
        papers,
        metaEntries
      ];
}

typedef $$ProblemsIndexTableCreateCompanionBuilder = ProblemsIndexCompanion
    Function({
  Value<int> ftsRowId,
  required String id,
  required String fingerprint,
  required String subject,
  required String qtype,
  Value<int> difficulty,
  Value<String?> source,
  Value<String> sourceType,
  Value<int?> sourceYear,
  required String filePath,
  required String stemText,
  Value<String> searchTokens,
  Value<double?> primaryKpWeight,
  Value<String?> primaryKpName,
  Value<String?> parseWarnings,
  Value<bool> needsReview,
  Value<bool> aiTagged,
  Value<double?> aiConfidence,
  Value<DateTime?> createdAt,
  Value<DateTime?> fileModifiedAt,
  Value<DateTime> indexedAt,
});
typedef $$ProblemsIndexTableUpdateCompanionBuilder = ProblemsIndexCompanion
    Function({
  Value<int> ftsRowId,
  Value<String> id,
  Value<String> fingerprint,
  Value<String> subject,
  Value<String> qtype,
  Value<int> difficulty,
  Value<String?> source,
  Value<String> sourceType,
  Value<int?> sourceYear,
  Value<String> filePath,
  Value<String> stemText,
  Value<String> searchTokens,
  Value<double?> primaryKpWeight,
  Value<String?> primaryKpName,
  Value<String?> parseWarnings,
  Value<bool> needsReview,
  Value<bool> aiTagged,
  Value<double?> aiConfidence,
  Value<DateTime?> createdAt,
  Value<DateTime?> fileModifiedAt,
  Value<DateTime> indexedAt,
});

class $$ProblemsIndexTableFilterComposer
    extends Composer<_$AppDatabase, $ProblemsIndexTable> {
  $$ProblemsIndexTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get ftsRowId => $composableBuilder(
      column: $table.ftsRowId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get fingerprint => $composableBuilder(
      column: $table.fingerprint, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get subject => $composableBuilder(
      column: $table.subject, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get qtype => $composableBuilder(
      column: $table.qtype, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get difficulty => $composableBuilder(
      column: $table.difficulty, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get source => $composableBuilder(
      column: $table.source, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get sourceType => $composableBuilder(
      column: $table.sourceType, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get sourceYear => $composableBuilder(
      column: $table.sourceYear, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get filePath => $composableBuilder(
      column: $table.filePath, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get stemText => $composableBuilder(
      column: $table.stemText, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get searchTokens => $composableBuilder(
      column: $table.searchTokens, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get primaryKpWeight => $composableBuilder(
      column: $table.primaryKpWeight,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get primaryKpName => $composableBuilder(
      column: $table.primaryKpName, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get parseWarnings => $composableBuilder(
      column: $table.parseWarnings, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get needsReview => $composableBuilder(
      column: $table.needsReview, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get aiTagged => $composableBuilder(
      column: $table.aiTagged, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get aiConfidence => $composableBuilder(
      column: $table.aiConfidence, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get fileModifiedAt => $composableBuilder(
      column: $table.fileModifiedAt,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get indexedAt => $composableBuilder(
      column: $table.indexedAt, builder: (column) => ColumnFilters(column));
}

class $$ProblemsIndexTableOrderingComposer
    extends Composer<_$AppDatabase, $ProblemsIndexTable> {
  $$ProblemsIndexTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get ftsRowId => $composableBuilder(
      column: $table.ftsRowId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get fingerprint => $composableBuilder(
      column: $table.fingerprint, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get subject => $composableBuilder(
      column: $table.subject, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get qtype => $composableBuilder(
      column: $table.qtype, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get difficulty => $composableBuilder(
      column: $table.difficulty, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get source => $composableBuilder(
      column: $table.source, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get sourceType => $composableBuilder(
      column: $table.sourceType, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get sourceYear => $composableBuilder(
      column: $table.sourceYear, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get filePath => $composableBuilder(
      column: $table.filePath, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get stemText => $composableBuilder(
      column: $table.stemText, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get searchTokens => $composableBuilder(
      column: $table.searchTokens,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get primaryKpWeight => $composableBuilder(
      column: $table.primaryKpWeight,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get primaryKpName => $composableBuilder(
      column: $table.primaryKpName,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get parseWarnings => $composableBuilder(
      column: $table.parseWarnings,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get needsReview => $composableBuilder(
      column: $table.needsReview, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get aiTagged => $composableBuilder(
      column: $table.aiTagged, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get aiConfidence => $composableBuilder(
      column: $table.aiConfidence,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get fileModifiedAt => $composableBuilder(
      column: $table.fileModifiedAt,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get indexedAt => $composableBuilder(
      column: $table.indexedAt, builder: (column) => ColumnOrderings(column));
}

class $$ProblemsIndexTableAnnotationComposer
    extends Composer<_$AppDatabase, $ProblemsIndexTable> {
  $$ProblemsIndexTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get ftsRowId =>
      $composableBuilder(column: $table.ftsRowId, builder: (column) => column);

  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get fingerprint => $composableBuilder(
      column: $table.fingerprint, builder: (column) => column);

  GeneratedColumn<String> get subject =>
      $composableBuilder(column: $table.subject, builder: (column) => column);

  GeneratedColumn<String> get qtype =>
      $composableBuilder(column: $table.qtype, builder: (column) => column);

  GeneratedColumn<int> get difficulty => $composableBuilder(
      column: $table.difficulty, builder: (column) => column);

  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<String> get sourceType => $composableBuilder(
      column: $table.sourceType, builder: (column) => column);

  GeneratedColumn<int> get sourceYear => $composableBuilder(
      column: $table.sourceYear, builder: (column) => column);

  GeneratedColumn<String> get filePath =>
      $composableBuilder(column: $table.filePath, builder: (column) => column);

  GeneratedColumn<String> get stemText =>
      $composableBuilder(column: $table.stemText, builder: (column) => column);

  GeneratedColumn<String> get searchTokens => $composableBuilder(
      column: $table.searchTokens, builder: (column) => column);

  GeneratedColumn<double> get primaryKpWeight => $composableBuilder(
      column: $table.primaryKpWeight, builder: (column) => column);

  GeneratedColumn<String> get primaryKpName => $composableBuilder(
      column: $table.primaryKpName, builder: (column) => column);

  GeneratedColumn<String> get parseWarnings => $composableBuilder(
      column: $table.parseWarnings, builder: (column) => column);

  GeneratedColumn<bool> get needsReview => $composableBuilder(
      column: $table.needsReview, builder: (column) => column);

  GeneratedColumn<bool> get aiTagged =>
      $composableBuilder(column: $table.aiTagged, builder: (column) => column);

  GeneratedColumn<double> get aiConfidence => $composableBuilder(
      column: $table.aiConfidence, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get fileModifiedAt => $composableBuilder(
      column: $table.fileModifiedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get indexedAt =>
      $composableBuilder(column: $table.indexedAt, builder: (column) => column);
}

class $$ProblemsIndexTableTableManager extends RootTableManager<
    _$AppDatabase,
    $ProblemsIndexTable,
    ProblemIndexRow,
    $$ProblemsIndexTableFilterComposer,
    $$ProblemsIndexTableOrderingComposer,
    $$ProblemsIndexTableAnnotationComposer,
    $$ProblemsIndexTableCreateCompanionBuilder,
    $$ProblemsIndexTableUpdateCompanionBuilder,
    (
      ProblemIndexRow,
      BaseReferences<_$AppDatabase, $ProblemsIndexTable, ProblemIndexRow>
    ),
    ProblemIndexRow,
    PrefetchHooks Function()> {
  $$ProblemsIndexTableTableManager(_$AppDatabase db, $ProblemsIndexTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ProblemsIndexTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ProblemsIndexTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ProblemsIndexTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> ftsRowId = const Value.absent(),
            Value<String> id = const Value.absent(),
            Value<String> fingerprint = const Value.absent(),
            Value<String> subject = const Value.absent(),
            Value<String> qtype = const Value.absent(),
            Value<int> difficulty = const Value.absent(),
            Value<String?> source = const Value.absent(),
            Value<String> sourceType = const Value.absent(),
            Value<int?> sourceYear = const Value.absent(),
            Value<String> filePath = const Value.absent(),
            Value<String> stemText = const Value.absent(),
            Value<String> searchTokens = const Value.absent(),
            Value<double?> primaryKpWeight = const Value.absent(),
            Value<String?> primaryKpName = const Value.absent(),
            Value<String?> parseWarnings = const Value.absent(),
            Value<bool> needsReview = const Value.absent(),
            Value<bool> aiTagged = const Value.absent(),
            Value<double?> aiConfidence = const Value.absent(),
            Value<DateTime?> createdAt = const Value.absent(),
            Value<DateTime?> fileModifiedAt = const Value.absent(),
            Value<DateTime> indexedAt = const Value.absent(),
          }) =>
              ProblemsIndexCompanion(
            ftsRowId: ftsRowId,
            id: id,
            fingerprint: fingerprint,
            subject: subject,
            qtype: qtype,
            difficulty: difficulty,
            source: source,
            sourceType: sourceType,
            sourceYear: sourceYear,
            filePath: filePath,
            stemText: stemText,
            searchTokens: searchTokens,
            primaryKpWeight: primaryKpWeight,
            primaryKpName: primaryKpName,
            parseWarnings: parseWarnings,
            needsReview: needsReview,
            aiTagged: aiTagged,
            aiConfidence: aiConfidence,
            createdAt: createdAt,
            fileModifiedAt: fileModifiedAt,
            indexedAt: indexedAt,
          ),
          createCompanionCallback: ({
            Value<int> ftsRowId = const Value.absent(),
            required String id,
            required String fingerprint,
            required String subject,
            required String qtype,
            Value<int> difficulty = const Value.absent(),
            Value<String?> source = const Value.absent(),
            Value<String> sourceType = const Value.absent(),
            Value<int?> sourceYear = const Value.absent(),
            required String filePath,
            required String stemText,
            Value<String> searchTokens = const Value.absent(),
            Value<double?> primaryKpWeight = const Value.absent(),
            Value<String?> primaryKpName = const Value.absent(),
            Value<String?> parseWarnings = const Value.absent(),
            Value<bool> needsReview = const Value.absent(),
            Value<bool> aiTagged = const Value.absent(),
            Value<double?> aiConfidence = const Value.absent(),
            Value<DateTime?> createdAt = const Value.absent(),
            Value<DateTime?> fileModifiedAt = const Value.absent(),
            Value<DateTime> indexedAt = const Value.absent(),
          }) =>
              ProblemsIndexCompanion.insert(
            ftsRowId: ftsRowId,
            id: id,
            fingerprint: fingerprint,
            subject: subject,
            qtype: qtype,
            difficulty: difficulty,
            source: source,
            sourceType: sourceType,
            sourceYear: sourceYear,
            filePath: filePath,
            stemText: stemText,
            searchTokens: searchTokens,
            primaryKpWeight: primaryKpWeight,
            primaryKpName: primaryKpName,
            parseWarnings: parseWarnings,
            needsReview: needsReview,
            aiTagged: aiTagged,
            aiConfidence: aiConfidence,
            createdAt: createdAt,
            fileModifiedAt: fileModifiedAt,
            indexedAt: indexedAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$ProblemsIndexTable, ProblemIndexRow>(table),
                    BaseReferences<_$AppDatabase, $ProblemsIndexTable,
                        ProblemIndexRow>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$ProblemsIndexTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $ProblemsIndexTable,
    ProblemIndexRow,
    $$ProblemsIndexTableFilterComposer,
    $$ProblemsIndexTableOrderingComposer,
    $$ProblemsIndexTableAnnotationComposer,
    $$ProblemsIndexTableCreateCompanionBuilder,
    $$ProblemsIndexTableUpdateCompanionBuilder,
    (
      ProblemIndexRow,
      BaseReferences<_$AppDatabase, $ProblemsIndexTable, ProblemIndexRow>
    ),
    ProblemIndexRow,
    PrefetchHooks Function()>;
typedef $$ProblemKnowledgeTableCreateCompanionBuilder
    = ProblemKnowledgeCompanion Function({
  Value<int> id,
  required String problemId,
  required String kpId,
  Value<String> role,
  Value<double> relevance,
});
typedef $$ProblemKnowledgeTableUpdateCompanionBuilder
    = ProblemKnowledgeCompanion Function({
  Value<int> id,
  Value<String> problemId,
  Value<String> kpId,
  Value<String> role,
  Value<double> relevance,
});

class $$ProblemKnowledgeTableFilterComposer
    extends Composer<_$AppDatabase, $ProblemKnowledgeTable> {
  $$ProblemKnowledgeTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get problemId => $composableBuilder(
      column: $table.problemId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get kpId => $composableBuilder(
      column: $table.kpId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get role => $composableBuilder(
      column: $table.role, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get relevance => $composableBuilder(
      column: $table.relevance, builder: (column) => ColumnFilters(column));
}

class $$ProblemKnowledgeTableOrderingComposer
    extends Composer<_$AppDatabase, $ProblemKnowledgeTable> {
  $$ProblemKnowledgeTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get problemId => $composableBuilder(
      column: $table.problemId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get kpId => $composableBuilder(
      column: $table.kpId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get role => $composableBuilder(
      column: $table.role, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get relevance => $composableBuilder(
      column: $table.relevance, builder: (column) => ColumnOrderings(column));
}

class $$ProblemKnowledgeTableAnnotationComposer
    extends Composer<_$AppDatabase, $ProblemKnowledgeTable> {
  $$ProblemKnowledgeTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get problemId =>
      $composableBuilder(column: $table.problemId, builder: (column) => column);

  GeneratedColumn<String> get kpId =>
      $composableBuilder(column: $table.kpId, builder: (column) => column);

  GeneratedColumn<String> get role =>
      $composableBuilder(column: $table.role, builder: (column) => column);

  GeneratedColumn<double> get relevance =>
      $composableBuilder(column: $table.relevance, builder: (column) => column);
}

class $$ProblemKnowledgeTableTableManager extends RootTableManager<
    _$AppDatabase,
    $ProblemKnowledgeTable,
    ProblemKnowledgeRow,
    $$ProblemKnowledgeTableFilterComposer,
    $$ProblemKnowledgeTableOrderingComposer,
    $$ProblemKnowledgeTableAnnotationComposer,
    $$ProblemKnowledgeTableCreateCompanionBuilder,
    $$ProblemKnowledgeTableUpdateCompanionBuilder,
    (
      ProblemKnowledgeRow,
      BaseReferences<_$AppDatabase, $ProblemKnowledgeTable, ProblemKnowledgeRow>
    ),
    ProblemKnowledgeRow,
    PrefetchHooks Function()> {
  $$ProblemKnowledgeTableTableManager(
      _$AppDatabase db, $ProblemKnowledgeTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ProblemKnowledgeTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ProblemKnowledgeTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ProblemKnowledgeTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> problemId = const Value.absent(),
            Value<String> kpId = const Value.absent(),
            Value<String> role = const Value.absent(),
            Value<double> relevance = const Value.absent(),
          }) =>
              ProblemKnowledgeCompanion(
            id: id,
            problemId: problemId,
            kpId: kpId,
            role: role,
            relevance: relevance,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String problemId,
            required String kpId,
            Value<String> role = const Value.absent(),
            Value<double> relevance = const Value.absent(),
          }) =>
              ProblemKnowledgeCompanion.insert(
            id: id,
            problemId: problemId,
            kpId: kpId,
            role: role,
            relevance: relevance,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$ProblemKnowledgeTable, ProblemKnowledgeRow>(
                        table),
                    BaseReferences<_$AppDatabase, $ProblemKnowledgeTable,
                        ProblemKnowledgeRow>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$ProblemKnowledgeTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $ProblemKnowledgeTable,
    ProblemKnowledgeRow,
    $$ProblemKnowledgeTableFilterComposer,
    $$ProblemKnowledgeTableOrderingComposer,
    $$ProblemKnowledgeTableAnnotationComposer,
    $$ProblemKnowledgeTableCreateCompanionBuilder,
    $$ProblemKnowledgeTableUpdateCompanionBuilder,
    (
      ProblemKnowledgeRow,
      BaseReferences<_$AppDatabase, $ProblemKnowledgeTable, ProblemKnowledgeRow>
    ),
    ProblemKnowledgeRow,
    PrefetchHooks Function()>;
typedef $$UserProblemStateTableCreateCompanionBuilder
    = UserProblemStateCompanion Function({
  required String problemId,
  Value<int> wrongCount,
  Value<DateTime> firstSeen,
  Value<DateTime?> lastWrong,
  Value<String?> fsrsState,
  Value<double> mastery,
  Value<String> errorCauses,
  Value<String?> note,
  Value<bool> starred,
  Value<int> rowid,
});
typedef $$UserProblemStateTableUpdateCompanionBuilder
    = UserProblemStateCompanion Function({
  Value<String> problemId,
  Value<int> wrongCount,
  Value<DateTime> firstSeen,
  Value<DateTime?> lastWrong,
  Value<String?> fsrsState,
  Value<double> mastery,
  Value<String> errorCauses,
  Value<String?> note,
  Value<bool> starred,
  Value<int> rowid,
});

class $$UserProblemStateTableFilterComposer
    extends Composer<_$AppDatabase, $UserProblemStateTable> {
  $$UserProblemStateTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get problemId => $composableBuilder(
      column: $table.problemId, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get wrongCount => $composableBuilder(
      column: $table.wrongCount, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get firstSeen => $composableBuilder(
      column: $table.firstSeen, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get lastWrong => $composableBuilder(
      column: $table.lastWrong, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get fsrsState => $composableBuilder(
      column: $table.fsrsState, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get mastery => $composableBuilder(
      column: $table.mastery, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get errorCauses => $composableBuilder(
      column: $table.errorCauses, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get note => $composableBuilder(
      column: $table.note, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get starred => $composableBuilder(
      column: $table.starred, builder: (column) => ColumnFilters(column));
}

class $$UserProblemStateTableOrderingComposer
    extends Composer<_$AppDatabase, $UserProblemStateTable> {
  $$UserProblemStateTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get problemId => $composableBuilder(
      column: $table.problemId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get wrongCount => $composableBuilder(
      column: $table.wrongCount, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get firstSeen => $composableBuilder(
      column: $table.firstSeen, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get lastWrong => $composableBuilder(
      column: $table.lastWrong, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get fsrsState => $composableBuilder(
      column: $table.fsrsState, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get mastery => $composableBuilder(
      column: $table.mastery, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get errorCauses => $composableBuilder(
      column: $table.errorCauses, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get note => $composableBuilder(
      column: $table.note, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get starred => $composableBuilder(
      column: $table.starred, builder: (column) => ColumnOrderings(column));
}

class $$UserProblemStateTableAnnotationComposer
    extends Composer<_$AppDatabase, $UserProblemStateTable> {
  $$UserProblemStateTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get problemId =>
      $composableBuilder(column: $table.problemId, builder: (column) => column);

  GeneratedColumn<int> get wrongCount => $composableBuilder(
      column: $table.wrongCount, builder: (column) => column);

  GeneratedColumn<DateTime> get firstSeen =>
      $composableBuilder(column: $table.firstSeen, builder: (column) => column);

  GeneratedColumn<DateTime> get lastWrong =>
      $composableBuilder(column: $table.lastWrong, builder: (column) => column);

  GeneratedColumn<String> get fsrsState =>
      $composableBuilder(column: $table.fsrsState, builder: (column) => column);

  GeneratedColumn<double> get mastery =>
      $composableBuilder(column: $table.mastery, builder: (column) => column);

  GeneratedColumn<String> get errorCauses => $composableBuilder(
      column: $table.errorCauses, builder: (column) => column);

  GeneratedColumn<String> get note =>
      $composableBuilder(column: $table.note, builder: (column) => column);

  GeneratedColumn<bool> get starred =>
      $composableBuilder(column: $table.starred, builder: (column) => column);
}

class $$UserProblemStateTableTableManager extends RootTableManager<
    _$AppDatabase,
    $UserProblemStateTable,
    UserProblemStateRow,
    $$UserProblemStateTableFilterComposer,
    $$UserProblemStateTableOrderingComposer,
    $$UserProblemStateTableAnnotationComposer,
    $$UserProblemStateTableCreateCompanionBuilder,
    $$UserProblemStateTableUpdateCompanionBuilder,
    (
      UserProblemStateRow,
      BaseReferences<_$AppDatabase, $UserProblemStateTable, UserProblemStateRow>
    ),
    UserProblemStateRow,
    PrefetchHooks Function()> {
  $$UserProblemStateTableTableManager(
      _$AppDatabase db, $UserProblemStateTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$UserProblemStateTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$UserProblemStateTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$UserProblemStateTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> problemId = const Value.absent(),
            Value<int> wrongCount = const Value.absent(),
            Value<DateTime> firstSeen = const Value.absent(),
            Value<DateTime?> lastWrong = const Value.absent(),
            Value<String?> fsrsState = const Value.absent(),
            Value<double> mastery = const Value.absent(),
            Value<String> errorCauses = const Value.absent(),
            Value<String?> note = const Value.absent(),
            Value<bool> starred = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              UserProblemStateCompanion(
            problemId: problemId,
            wrongCount: wrongCount,
            firstSeen: firstSeen,
            lastWrong: lastWrong,
            fsrsState: fsrsState,
            mastery: mastery,
            errorCauses: errorCauses,
            note: note,
            starred: starred,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String problemId,
            Value<int> wrongCount = const Value.absent(),
            Value<DateTime> firstSeen = const Value.absent(),
            Value<DateTime?> lastWrong = const Value.absent(),
            Value<String?> fsrsState = const Value.absent(),
            Value<double> mastery = const Value.absent(),
            Value<String> errorCauses = const Value.absent(),
            Value<String?> note = const Value.absent(),
            Value<bool> starred = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              UserProblemStateCompanion.insert(
            problemId: problemId,
            wrongCount: wrongCount,
            firstSeen: firstSeen,
            lastWrong: lastWrong,
            fsrsState: fsrsState,
            mastery: mastery,
            errorCauses: errorCauses,
            note: note,
            starred: starred,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$UserProblemStateTable, UserProblemStateRow>(
                        table),
                    BaseReferences<_$AppDatabase, $UserProblemStateTable,
                        UserProblemStateRow>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$UserProblemStateTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $UserProblemStateTable,
    UserProblemStateRow,
    $$UserProblemStateTableFilterComposer,
    $$UserProblemStateTableOrderingComposer,
    $$UserProblemStateTableAnnotationComposer,
    $$UserProblemStateTableCreateCompanionBuilder,
    $$UserProblemStateTableUpdateCompanionBuilder,
    (
      UserProblemStateRow,
      BaseReferences<_$AppDatabase, $UserProblemStateTable, UserProblemStateRow>
    ),
    UserProblemStateRow,
    PrefetchHooks Function()>;
typedef $$ReviewLogsTableCreateCompanionBuilder = ReviewLogsCompanion Function({
  Value<int> id,
  required String problemId,
  required int rating,
  Value<int?> elapsedMs,
  Value<int?> elapsedDays,
  Value<int?> scheduledDays,
  Value<double?> stabilityAfter,
  Value<double?> difficultyAfter,
  Value<DateTime> reviewedAt,
});
typedef $$ReviewLogsTableUpdateCompanionBuilder = ReviewLogsCompanion Function({
  Value<int> id,
  Value<String> problemId,
  Value<int> rating,
  Value<int?> elapsedMs,
  Value<int?> elapsedDays,
  Value<int?> scheduledDays,
  Value<double?> stabilityAfter,
  Value<double?> difficultyAfter,
  Value<DateTime> reviewedAt,
});

class $$ReviewLogsTableFilterComposer
    extends Composer<_$AppDatabase, $ReviewLogsTable> {
  $$ReviewLogsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get problemId => $composableBuilder(
      column: $table.problemId, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get rating => $composableBuilder(
      column: $table.rating, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get elapsedMs => $composableBuilder(
      column: $table.elapsedMs, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get elapsedDays => $composableBuilder(
      column: $table.elapsedDays, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get scheduledDays => $composableBuilder(
      column: $table.scheduledDays, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get stabilityAfter => $composableBuilder(
      column: $table.stabilityAfter,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get difficultyAfter => $composableBuilder(
      column: $table.difficultyAfter,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get reviewedAt => $composableBuilder(
      column: $table.reviewedAt, builder: (column) => ColumnFilters(column));
}

class $$ReviewLogsTableOrderingComposer
    extends Composer<_$AppDatabase, $ReviewLogsTable> {
  $$ReviewLogsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get problemId => $composableBuilder(
      column: $table.problemId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get rating => $composableBuilder(
      column: $table.rating, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get elapsedMs => $composableBuilder(
      column: $table.elapsedMs, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get elapsedDays => $composableBuilder(
      column: $table.elapsedDays, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get scheduledDays => $composableBuilder(
      column: $table.scheduledDays,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get stabilityAfter => $composableBuilder(
      column: $table.stabilityAfter,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get difficultyAfter => $composableBuilder(
      column: $table.difficultyAfter,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get reviewedAt => $composableBuilder(
      column: $table.reviewedAt, builder: (column) => ColumnOrderings(column));
}

class $$ReviewLogsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ReviewLogsTable> {
  $$ReviewLogsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get problemId =>
      $composableBuilder(column: $table.problemId, builder: (column) => column);

  GeneratedColumn<int> get rating =>
      $composableBuilder(column: $table.rating, builder: (column) => column);

  GeneratedColumn<int> get elapsedMs =>
      $composableBuilder(column: $table.elapsedMs, builder: (column) => column);

  GeneratedColumn<int> get elapsedDays => $composableBuilder(
      column: $table.elapsedDays, builder: (column) => column);

  GeneratedColumn<int> get scheduledDays => $composableBuilder(
      column: $table.scheduledDays, builder: (column) => column);

  GeneratedColumn<double> get stabilityAfter => $composableBuilder(
      column: $table.stabilityAfter, builder: (column) => column);

  GeneratedColumn<double> get difficultyAfter => $composableBuilder(
      column: $table.difficultyAfter, builder: (column) => column);

  GeneratedColumn<DateTime> get reviewedAt => $composableBuilder(
      column: $table.reviewedAt, builder: (column) => column);
}

class $$ReviewLogsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $ReviewLogsTable,
    ReviewLogRow,
    $$ReviewLogsTableFilterComposer,
    $$ReviewLogsTableOrderingComposer,
    $$ReviewLogsTableAnnotationComposer,
    $$ReviewLogsTableCreateCompanionBuilder,
    $$ReviewLogsTableUpdateCompanionBuilder,
    (
      ReviewLogRow,
      BaseReferences<_$AppDatabase, $ReviewLogsTable, ReviewLogRow>
    ),
    ReviewLogRow,
    PrefetchHooks Function()> {
  $$ReviewLogsTableTableManager(_$AppDatabase db, $ReviewLogsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ReviewLogsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ReviewLogsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ReviewLogsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> problemId = const Value.absent(),
            Value<int> rating = const Value.absent(),
            Value<int?> elapsedMs = const Value.absent(),
            Value<int?> elapsedDays = const Value.absent(),
            Value<int?> scheduledDays = const Value.absent(),
            Value<double?> stabilityAfter = const Value.absent(),
            Value<double?> difficultyAfter = const Value.absent(),
            Value<DateTime> reviewedAt = const Value.absent(),
          }) =>
              ReviewLogsCompanion(
            id: id,
            problemId: problemId,
            rating: rating,
            elapsedMs: elapsedMs,
            elapsedDays: elapsedDays,
            scheduledDays: scheduledDays,
            stabilityAfter: stabilityAfter,
            difficultyAfter: difficultyAfter,
            reviewedAt: reviewedAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String problemId,
            required int rating,
            Value<int?> elapsedMs = const Value.absent(),
            Value<int?> elapsedDays = const Value.absent(),
            Value<int?> scheduledDays = const Value.absent(),
            Value<double?> stabilityAfter = const Value.absent(),
            Value<double?> difficultyAfter = const Value.absent(),
            Value<DateTime> reviewedAt = const Value.absent(),
          }) =>
              ReviewLogsCompanion.insert(
            id: id,
            problemId: problemId,
            rating: rating,
            elapsedMs: elapsedMs,
            elapsedDays: elapsedDays,
            scheduledDays: scheduledDays,
            stabilityAfter: stabilityAfter,
            difficultyAfter: difficultyAfter,
            reviewedAt: reviewedAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$ReviewLogsTable, ReviewLogRow>(table),
                    BaseReferences<_$AppDatabase, $ReviewLogsTable,
                        ReviewLogRow>(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$ReviewLogsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $ReviewLogsTable,
    ReviewLogRow,
    $$ReviewLogsTableFilterComposer,
    $$ReviewLogsTableOrderingComposer,
    $$ReviewLogsTableAnnotationComposer,
    $$ReviewLogsTableCreateCompanionBuilder,
    $$ReviewLogsTableUpdateCompanionBuilder,
    (
      ReviewLogRow,
      BaseReferences<_$AppDatabase, $ReviewLogsTable, ReviewLogRow>
    ),
    ReviewLogRow,
    PrefetchHooks Function()>;
typedef $$PapersTableCreateCompanionBuilder = PapersCompanion Function({
  required String id,
  required String title,
  required String subject,
  required String config,
  required String items,
  Value<int?> totalScore,
  Value<DateTime> createdAt,
  Value<int> rowid,
});
typedef $$PapersTableUpdateCompanionBuilder = PapersCompanion Function({
  Value<String> id,
  Value<String> title,
  Value<String> subject,
  Value<String> config,
  Value<String> items,
  Value<int?> totalScore,
  Value<DateTime> createdAt,
  Value<int> rowid,
});

class $$PapersTableFilterComposer
    extends Composer<_$AppDatabase, $PapersTable> {
  $$PapersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get subject => $composableBuilder(
      column: $table.subject, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get config => $composableBuilder(
      column: $table.config, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get items => $composableBuilder(
      column: $table.items, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get totalScore => $composableBuilder(
      column: $table.totalScore, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));
}

class $$PapersTableOrderingComposer
    extends Composer<_$AppDatabase, $PapersTable> {
  $$PapersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get subject => $composableBuilder(
      column: $table.subject, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get config => $composableBuilder(
      column: $table.config, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get items => $composableBuilder(
      column: $table.items, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get totalScore => $composableBuilder(
      column: $table.totalScore, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));
}

class $$PapersTableAnnotationComposer
    extends Composer<_$AppDatabase, $PapersTable> {
  $$PapersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get subject =>
      $composableBuilder(column: $table.subject, builder: (column) => column);

  GeneratedColumn<String> get config =>
      $composableBuilder(column: $table.config, builder: (column) => column);

  GeneratedColumn<String> get items =>
      $composableBuilder(column: $table.items, builder: (column) => column);

  GeneratedColumn<int> get totalScore => $composableBuilder(
      column: $table.totalScore, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$PapersTableTableManager extends RootTableManager<
    _$AppDatabase,
    $PapersTable,
    PaperRow,
    $$PapersTableFilterComposer,
    $$PapersTableOrderingComposer,
    $$PapersTableAnnotationComposer,
    $$PapersTableCreateCompanionBuilder,
    $$PapersTableUpdateCompanionBuilder,
    (PaperRow, BaseReferences<_$AppDatabase, $PapersTable, PaperRow>),
    PaperRow,
    PrefetchHooks Function()> {
  $$PapersTableTableManager(_$AppDatabase db, $PapersTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PapersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PapersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PapersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> title = const Value.absent(),
            Value<String> subject = const Value.absent(),
            Value<String> config = const Value.absent(),
            Value<String> items = const Value.absent(),
            Value<int?> totalScore = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              PapersCompanion(
            id: id,
            title: title,
            subject: subject,
            config: config,
            items: items,
            totalScore: totalScore,
            createdAt: createdAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String title,
            required String subject,
            required String config,
            required String items,
            Value<int?> totalScore = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              PapersCompanion.insert(
            id: id,
            title: title,
            subject: subject,
            config: config,
            items: items,
            totalScore: totalScore,
            createdAt: createdAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$PapersTable, PaperRow>(table),
                    BaseReferences<_$AppDatabase, $PapersTable, PaperRow>(
                        db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$PapersTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $PapersTable,
    PaperRow,
    $$PapersTableFilterComposer,
    $$PapersTableOrderingComposer,
    $$PapersTableAnnotationComposer,
    $$PapersTableCreateCompanionBuilder,
    $$PapersTableUpdateCompanionBuilder,
    (PaperRow, BaseReferences<_$AppDatabase, $PapersTable, PaperRow>),
    PaperRow,
    PrefetchHooks Function()>;
typedef $$MetaEntriesTableCreateCompanionBuilder = MetaEntriesCompanion
    Function({
  required String key,
  required String value,
  Value<DateTime> updatedAt,
  Value<int> rowid,
});
typedef $$MetaEntriesTableUpdateCompanionBuilder = MetaEntriesCompanion
    Function({
  Value<String> key,
  Value<String> value,
  Value<DateTime> updatedAt,
  Value<int> rowid,
});

class $$MetaEntriesTableFilterComposer
    extends Composer<_$AppDatabase, $MetaEntriesTable> {
  $$MetaEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get value => $composableBuilder(
      column: $table.value, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));
}

class $$MetaEntriesTableOrderingComposer
    extends Composer<_$AppDatabase, $MetaEntriesTable> {
  $$MetaEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get value => $composableBuilder(
      column: $table.value, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
}

class $$MetaEntriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $MetaEntriesTable> {
  $$MetaEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$MetaEntriesTableTableManager extends RootTableManager<
    _$AppDatabase,
    $MetaEntriesTable,
    MetaRow,
    $$MetaEntriesTableFilterComposer,
    $$MetaEntriesTableOrderingComposer,
    $$MetaEntriesTableAnnotationComposer,
    $$MetaEntriesTableCreateCompanionBuilder,
    $$MetaEntriesTableUpdateCompanionBuilder,
    (MetaRow, BaseReferences<_$AppDatabase, $MetaEntriesTable, MetaRow>),
    MetaRow,
    PrefetchHooks Function()> {
  $$MetaEntriesTableTableManager(_$AppDatabase db, $MetaEntriesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MetaEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MetaEntriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MetaEntriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> key = const Value.absent(),
            Value<String> value = const Value.absent(),
            Value<DateTime> updatedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              MetaEntriesCompanion(
            key: key,
            value: value,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String key,
            required String value,
            Value<DateTime> updatedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              MetaEntriesCompanion.insert(
            key: key,
            value: value,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$MetaEntriesTable, MetaRow>(table),
                    BaseReferences<_$AppDatabase, $MetaEntriesTable, MetaRow>(
                        db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$MetaEntriesTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $MetaEntriesTable,
    MetaRow,
    $$MetaEntriesTableFilterComposer,
    $$MetaEntriesTableOrderingComposer,
    $$MetaEntriesTableAnnotationComposer,
    $$MetaEntriesTableCreateCompanionBuilder,
    $$MetaEntriesTableUpdateCompanionBuilder,
    (MetaRow, BaseReferences<_$AppDatabase, $MetaEntriesTable, MetaRow>),
    MetaRow,
    PrefetchHooks Function()>;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$ProblemsIndexTableTableManager get problemsIndex =>
      $$ProblemsIndexTableTableManager(_db, _db.problemsIndex);
  $$ProblemKnowledgeTableTableManager get problemKnowledge =>
      $$ProblemKnowledgeTableTableManager(_db, _db.problemKnowledge);
  $$UserProblemStateTableTableManager get userProblemState =>
      $$UserProblemStateTableTableManager(_db, _db.userProblemState);
  $$ReviewLogsTableTableManager get reviewLogs =>
      $$ReviewLogsTableTableManager(_db, _db.reviewLogs);
  $$PapersTableTableManager get papers =>
      $$PapersTableTableManager(_db, _db.papers);
  $$MetaEntriesTableTableManager get metaEntries =>
      $$MetaEntriesTableTableManager(_db, _db.metaEntries);
}
