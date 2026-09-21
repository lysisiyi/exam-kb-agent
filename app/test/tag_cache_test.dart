/// 标注缓存与用量台账测试。
///
/// ## 这两样东西为什么值得测
///
/// 它们都**不影响标注能不能跑通** —— 缓存挂了、台账写不进去，标注照样出结果。
/// 正因如此，它们的 bug 不会有任何症状：用户只会发现"怎么每次都花钱"
/// 或者"花的钱对不上"。这类"静默失效"只能靠测试盯住。
///
/// 另一条要盯的是**换模型必须让缓存失效**：T17 实测不同模型 Top-1
/// 差 3–5 个百分点，如果缓存不按模型区分，用户换模型后会一直拿到旧结果，
/// 而且完全看不出来。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/data/markdown/problem_markdown.dart';
import 'package:kaoyan_math_agent/domain/knowledge/knowledge_point.dart';
import 'package:kaoyan_math_agent/services/llm/llm_client.dart';
import 'package:kaoyan_math_agent/services/llm/provider_registry.dart';
import 'package:kaoyan_math_agent/services/tagger/knowledge_tagger.dart';
import 'package:kaoyan_math_agent/services/tagger/tag_cache_store.dart';
import 'package:kaoyan_math_agent/services/tagger/tag_prompt.dart';

import 'support/test_env.dart';

const _result = TagResult(
  primaryKpId: 'math1.calc.limit.lhopital',
  confidence: 0.93,
  secondary: [(kpId: 'math1.calc.limit.taylor', relevance: 0.7)],
  difficulty: 3,
  errorCauses: ['method'],
  reason: '看到 0/0 型未定式。',
  extractionStrategy: 'fenced',
);

void main() {
  late TempLibrary env;

  setUp(() async {
    env = await TempLibrary.create();
  });

  tearDown(() => env.dispose());

  // ───────────────────────────────────────────────────────────────────────────
  group('标注缓存', () {
    test('写进去能读回来，字段不丢', () async {
      final cache = SqliteTagCache(db: env.db, model: 'deepseek-chat');
      expect(await cache.get('fp-1'), isNull, reason: '空缓存应当未命中');

      await cache.put('fp-1', _result);
      final back = await cache.get('fp-1');

      expect(back, isNotNull);
      expect(back!.primaryKpId, _result.primaryKpId);
      expect(back.confidence, closeTo(_result.confidence, 1e-9));
      expect(back.difficulty, _result.difficulty);
      expect(back.errorCauses, _result.errorCauses);
      expect(back.reason, _result.reason);
      expect(back.secondary.length, 1);
      expect(back.secondary.first.kpId, 'math1.calc.limit.taylor');
      expect(back.secondary.first.relevance,
          closeTo(0.7, 1e-9));
    });

    test('同一指纹覆盖写，不产生第二行', () async {
      final cache = SqliteTagCache(db: env.db, model: 'm');
      await cache.put('fp-1', _result);
      await cache.put(
        'fp-1',
        const TagResult(primaryKpId: 'x', confidence: 0.5),
      );

      expect(await cache.count(), 1);
      expect((await cache.get('fp-1'))!.primaryKpId, 'x');
    });

    test('换了模型，旧缓存不再命中', () async {
      final old = SqliteTagCache(db: env.db, model: 'deepseek-chat');
      await old.put('fp-1', _result);

      final newer = SqliteTagCache(db: env.db, model: 'deepseek-reasoner');
      expect(await newer.get('fp-1'), isNull,
          reason: '换模型后复用旧结果 → 用户以为"换模型没用"');

      // 旧模型自己仍然命中
      expect(await old.get('fp-1'), isNotNull);
    });

    test('不指定模型时不做模型校验（测试/排查用）', () async {
      await SqliteTagCache(db: env.db, model: 'a').put('fp-1', _result);
      expect(await SqliteTagCache(db: env.db).get('fp-1'), isNotNull);
    });

    test('空指纹不写也不读', () async {
      final cache = SqliteTagCache(db: env.db, model: 'm');
      await cache.put('', _result);
      expect(await cache.count(), 0);
      expect(await cache.get(''), isNull);
    });

    test('缓存内容损坏时当作未命中，而不是抛异常', () async {
      final cache = SqliteTagCache(db: env.db, model: 'm');
      await cache.put('fp-1', _result);

      // 手工把内容改成垃圾
      await env.db.customStatement(
        "UPDATE tag_cache_entries SET result = '不是 JSON' WHERE fingerprint = 'fp-1'",
      );

      expect(await cache.get('fp-1'), isNull,
          reason: '缓存坏了要走真实标注，而不是让标注整个失败');
    });

    test('清空缓存', () async {
      final cache = SqliteTagCache(db: env.db, model: 'm');
      await cache.put('fp-1', _result);
      await cache.put('fp-2', _result);
      expect(await cache.count(), 2);

      await cache.clear();
      expect(await cache.count(), 0);
    });

    test('标注引擎真的会用缓存：第二次不再调 API', () async {
      // 用假的 http 记调用次数
      var calls = 0;
      final http = _CountingHttp(onCall: () => calls++);
      final cache = SqliteTagCache(db: env.db, model: 'test-model');

      final problem = _problem('fp-1');
      final tagger = KnowledgeTagger(
        knowledge: _kb(),
        client: LlmClient(
          config: _config(),
          http: http,
          sleep: _noSleep,
        ),
        cache: cache,
      );

      final first = await tagger.tag(problem);
      expect(first.ok, isTrue, reason: first.failure);
      expect(first.fromCache, isFalse);
      expect(calls, 1);

      final second = await tagger.tag(problem);
      expect(second.ok, isTrue);
      expect(second.fromCache, isTrue, reason: '第二次应当命中缓存');
      expect(calls, 1, reason: '命中缓存就不该再发请求');
      expect(second.usage.fromCache, isTrue);
      expect(second.usage.totalTokens, 0);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('用量台账', () {
    test('命中缓存的调用不记账（没花钱）', () async {
      final ledger = UsageLedger(env.db);
      await ledger.record(
        provider: 'deepseek',
        usage: const LlmUsage(inputTokens: 900, outputTokens: 120),
      );
      await ledger.record(
        provider: 'deepseek',
        usage: LlmUsage.cached, // 命中缓存
      );

      final s = await ledger.summary();
      expect(s.calls, 1, reason: '缓存命中不该让花费虚高');
      expect(s.inputTokens, 900);
      expect(s.outputTokens, 120);
      expect(s.totalTokens, 1020);
    });

    test('汇总把费用加总，缺价的模型按 0 计（下界）', () async {
      final ledger = UsageLedger(env.db);
      await ledger.record(
        provider: 'deepseek',
        usage: const LlmUsage(
          inputTokens: 1000,
          outputTokens: 200,
          costYuan: 0.0021,
          model: 'deepseek-chat',
        ),
      );
      await ledger.record(
        provider: 'custom',
        usage: const LlmUsage(inputTokens: 500, outputTokens: 100),
      );

      final s = await ledger.summary();
      expect(s.calls, 2);
      expect(s.costYuan, closeTo(0.0021, 1e-9));
      expect(s.tokensPerCall, closeTo(900, 1e-6));
    });

    test('可以只看某个时间之后的用量', () async {
      final ledger = UsageLedger(env.db);
      await ledger.record(
        provider: 'd',
        usage: const LlmUsage(inputTokens: 10),
        now: DateTime(2024, 1, 1),
      );
      await ledger.record(
        provider: 'd',
        usage: const LlmUsage(inputTokens: 20),
        now: DateTime(2024, 6, 1),
      );

      final all = await ledger.summary();
      expect(all.calls, 2);

      final recent = await ledger.summary(since: DateTime(2024, 3, 1));
      expect(recent.calls, 1);
      expect(recent.inputTokens, 20);
    });

    test('明细按时间倒序，最新的在前', () async {
      final ledger = UsageLedger(env.db);
      await ledger.record(
        provider: 'a',
        usage: const LlmUsage(inputTokens: 1),
        now: DateTime(2024, 1, 1),
      );
      await ledger.record(
        provider: 'b',
        usage: const LlmUsage(inputTokens: 2),
        now: DateTime(2024, 2, 1),
      );

      final rows = await ledger.recent();
      expect(rows.map((r) => r.provider).toList(), ['b', 'a']);
      expect(rows.first.inputTokens, 2);
    });

    test('describeUsage 给出人话，且空态不说"0 次调用"', () {
      expect(describeUsage(const UsageSummary()), '还没有调用过 AI');

      expect(
        describeUsage(const UsageSummary(
          calls: 3,
          inputTokens: 3000,
          outputTokens: 300,
          costYuan: 0.12,
        )),
        '3 次调用 · 3300 tokens · 约 ¥0.12',
      );

      // 极小的花费不该显示成 ¥0.00（用户会以为算错了）
      expect(
        describeUsage(const UsageSummary(
          calls: 1,
          inputTokens: 100,
          outputTokens: 10,
          costYuan: 0.0004,
        )),
        contains('<0.01'),
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('台账写入失败不影响结果', () {
    test('台账表被删掉也不抛异常', () async {
      await env.db.customStatement('DROP TABLE llm_usage_entries');
      final ledger = UsageLedger(env.db);

      // 不抛
      await ledger.record(
        provider: 'd',
        usage: const LlmUsage(inputTokens: 5),
      );

      final s = await ledger.summary();
      // ⚠️ 这里断言的是 **hasError**，不是 isEmpty。
      //
      // 早先 `summary()` 读库失败时返回一个空的 `UsageSummary`，界面于是
      // 显示「还没有调用过 AI」—— 一句听起来完全正常、但会让用户
      // 以为自己没花钱的谎。现在读不出来必须能被区分出来，
      // 所以 `isEmpty` 对"有错误"的汇总是 false。
      expect(s.hasError, isTrue, reason: '读不出来必须能被区分出来');
      expect(s.isEmpty, isFalse, reason: '有错误时不能装作"没有记录"');
      expect(describeUsage(s), contains('读取失败'));
      expect(await ledger.recent(), isEmpty);
    });
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试替身
// ─────────────────────────────────────────────────────────────────────────────

/// 计数的假 HTTP 适配器：返回一个合法的 OpenAI 兼容标注响应。
class _CountingHttp extends HttpAdapter {
  final void Function() onCall;

  _CountingHttp({required this.onCall});

  @override
  Future<HttpResponse> send(HttpRequest request) async {
    onCall();
    return HttpResponse(
      statusCode: 200,
      body: jsonEncode({
        'choices': [
          {
            'message': {
              'role': 'assistant',
              'content': jsonEncode({
                'primary': {
                  'kp_id': 'math1.calc.limit.lhopital',
                  'confidence': 0.93,
                },
                'difficulty': 2,
              }),
            },
          }
        ],
        'usage': {'prompt_tokens': 800, 'completion_tokens': 60},
      }),
    );
  }
}

/// 不真正等待的退避函数。
Future<void> _noSleep(Duration _) async {}

LlmConfig _config() => const LlmConfig(
      providerId: 'deepseek',
      apiKey: 'sk-test',
      modelOverride: 'test-model',
    );

/// 只放一个叶子的本体，够召回层用。
///
/// ⚠️ 层级必须完整（math1 → calc → limit → leaf）：召回层是按
/// "根 → 章 → 节 → 叶子"逐层展开的，缺中间层会召回到空集合。
KnowledgeBase _kb() => KnowledgeBase(
      subject: 'math1',
      subjectName: '数学一',
      version: 't',
      nodes: const [
        KnowledgePoint(id: 'math1', name: '数学一', level: 1, isLeaf: false),
        KnowledgePoint(
          id: 'math1.calc',
          name: '高等数学',
          level: 2,
          parentId: 'math1',
          isLeaf: false,
        ),
        KnowledgePoint(
          id: 'math1.calc.limit',
          name: '极限与连续',
          level: 3,
          parentId: 'math1.calc',
          isLeaf: false,
          examWeight: 0.92,
        ),
        KnowledgePoint(
          id: 'math1.calc.limit.lhopital',
          name: '洛必达法则',
          level: 4,
          parentId: 'math1.calc.limit',
          isLeaf: true,
          examWeight: 0.8,
          definition: '求未定式极限的法则。',
        ),
      ],
    );

Problem _problem(String fingerprint) => Problem(
      id: 'p-1',
      fingerprint: fingerprint,
      stem: r'求 $\lim_{x\to0}\frac{\sin x}{x}$',
    );
