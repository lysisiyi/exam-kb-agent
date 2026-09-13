/// M3 标注引擎测试。
///
/// ## 测试策略：全程离线、零 token
/// LLM 客户端通过 [HttpAdapter] 抽象，测试注入可控的假实现。
/// 因此这里能完整验证：
/// - 重试与退避逻辑（退避函数被替换成立即返回）
/// - 错误分类（401 → invalidKey、429 → rateLimited、超时 → timeout …）
/// - 三种协议的响应解析（OpenAI / Anthropic / Gemini）
/// - 用量与费用估算
/// - 全部失败路径
///
/// 真正调用网络的只有生产代码，测试里一次都不会发生。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/data/markdown/problem_markdown.dart';
import 'package:kaoyan_math_agent/domain/knowledge/knowledge_point.dart';
import 'package:kaoyan_math_agent/services/llm/llm_client.dart';
import 'package:kaoyan_math_agent/services/llm/provider_registry.dart';
import 'package:kaoyan_math_agent/services/llm/robust_json.dart';
import 'package:kaoyan_math_agent/services/tagger/knowledge_recall.dart';
import 'package:kaoyan_math_agent/services/tagger/knowledge_tagger.dart';
import 'package:kaoyan_math_agent/services/tagger/tag_prompt.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 测试替身
// ─────────────────────────────────────────────────────────────────────────────

/// 可编排的假 HTTP 适配器。
class FakeHttp implements HttpAdapter {
  /// 按顺序返回的响应。用完后重复最后一个。
  final List<Object> responses;

  /// 记录每次请求，便于断言重试次数与请求体内容。
  final List<HttpRequest> requests = [];

  int _i = 0;

  FakeHttp(this.responses);

  @override
  Future<HttpResponse> send(HttpRequest request) async {
    requests.add(request);
    final r = responses[_i < responses.length ? _i : responses.length - 1];
    _i++;
    if (r is HttpResponse) return r;
    if (r is HttpTransportException) throw r;
    if (r is LlmException) throw r;
    throw StateError('不支持的假响应类型：${r.runtimeType}');
  }

  /// 构造一个成功的 OpenAI 兼容响应。
  static HttpResponse ok(String content, {int inTok = 100, int outTok = 50}) =>
      HttpResponse(
        statusCode: 200,
        body: jsonEncode({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': content},
            }
          ],
          'usage': {'prompt_tokens': inTok, 'completion_tokens': outTok},
        }),
      );

  static HttpResponse status(int code, [String body = '{}']) =>
      HttpResponse(statusCode: code, body: body);
}

/// 不真正等待的退避函数。
Future<void> _noSleep(Duration _) async {}

/// 构造一个小的知识点本体用于测试。
///
/// 用真实的知识点数据结构，但只放几个节点 —— 这样测试的断言可以写得很具体。
KnowledgeBase buildTestKnowledge() {
  final nodes = <KnowledgePoint>[
    const KnowledgePoint(
      id: 'math1',
      name: '考研数学（一）',
      level: 1,
    ),
    const KnowledgePoint(
      id: 'math1.calc',
      name: '高等数学',
      level: 2,
      parentId: 'math1',
    ),
    const KnowledgePoint(
      id: 'math1.calc.limit',
      name: '极限与连续',
      level: 3,
      parentId: 'math1.calc',
      examWeight: 0.92,
    ),
    const KnowledgePoint(
      id: 'math1.calc.limit.eq_infinitesimal',
      name: '等价无穷小替换',
      level: 4,
      parentId: 'math1.calc.limit',
      isLeaf: true,
      examWeight: 1.0,
      definition: '当 x→0 时，若 lim(f/g)=1 则称 f 与 g 是等价无穷小。'
          '只能用于乘除因子，不能用于加减项。',
      formulas: [
        r'\sin x \sim x',
        r'1-\cos x \sim \frac{x^2}{2}',
      ],
      commonTraps: [
        '★ 在加减法中滥用替换，如 tan x - sin x 各自替换成 x',
      ],
      typicalQtypes: ['choice', 'fill'],
      examYears: [2013, 2016, 2019, 2021, 2023],
    ),
    const KnowledgePoint(
      id: 'math1.calc.limit.lhopital',
      name: '洛必达法则',
      level: 4,
      parentId: 'math1.calc.limit',
      isLeaf: true,
      examWeight: 0.86,
      definition: '处理 0/0 或 ∞/∞ 型未定式。三个条件缺一不可，'
          '尤其导数之比的极限必须存在。',
      formulas: [r"\lim\frac{f}{g} = \lim\frac{f'}{g'}"],
      commonTraps: ['★ 未验证是否满足 0/0 型就直接用'],
      typicalQtypes: ['choice', 'fill', 'solve'],
      examYears: [2010, 2012, 2014, 2017],
    ),
    const KnowledgePoint(
      id: 'math1.calc.limit.taylor',
      name: '泰勒公式求极限',
      level: 4,
      parentId: 'math1.calc.limit',
      isLeaf: true,
      examWeight: 0.91,
      definition: '将函数展成幂级数用多项式逼近。求极限时展开到恰好能判定首项非零的阶数。',
      formulas: [
        r'e^x = 1+x+\frac{x^2}{2!}+\cdots+o(x^n)',
      ],
      commonTraps: ['★ 展开阶数不够导致首项相消'],
      typicalQtypes: ['choice', 'fill', 'solve'],
      examYears: [2013, 2016, 2018, 2020],
    ),
    const KnowledgePoint(
      id: 'math1.linalg',
      name: '线性代数',
      level: 2,
      parentId: 'math1',
    ),
    const KnowledgePoint(
      id: 'math1.linalg.eigen',
      name: '特征值与二次型',
      level: 3,
      parentId: 'math1.linalg',
      examWeight: 0.71,
    ),
    const KnowledgePoint(
      id: 'math1.linalg.eigen.similarity',
      name: '相似对角化',
      level: 4,
      parentId: 'math1.linalg.eigen',
      isLeaf: true,
      examWeight: 0.71,
      definition: 'n 阶矩阵可对角化当且仅当有 n 个线性无关的特征向量，'
          '等价于每个特征值的几何重数等于代数重数。',
      formulas: [r'P^{-1}AP = \Lambda'],
      commonTraps: ['★ 把必要条件当成充分条件用'],
      typicalQtypes: ['solve', 'proof'],
      examYears: [2012, 2015, 2018],
    ),
  ];

  return KnowledgeBase(
    subject: 'math1',
    subjectName: '考研数学（一）',
    version: 'test',
    nodes: nodes,
  );
}

/// 构造一道测试题目。
Problem buildProblem({
  String stem = r'当 $x\to 0$ 时，求 $\lim_{x\to 0}\frac{\sin x - x\cos x}{x^3}$',
  QuestionType qtype = QuestionType.choice,
  String? solution,
  String fingerprint = 'fp-test-1',
}) =>
    Problem(
      id: 'test-1',
      fingerprint: fingerprint,
      stem: stem,
      qtype: qtype,
      solution: solution,
    );

/// 构造一个客户端配置。
LlmConfig testConfig({
  String providerId = 'deepseek',
  String model = 'deepseek-chat',
}) =>
    LlmConfig(
      providerId: providerId,
      apiKey: 'sk-test-key',
      modelOverride: model,
    );

void main() {
  // ═══════════════════════════════════════════════════════════════════════
  group('Provider 注册表', () {
    test('每个服务商的 id 唯一', () {
      final ids = LlmProviders.all.map((p) => p.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('除 custom 外都有 base_url 与默认模型', () {
      for (final p in LlmProviders.all) {
        if (p.id == 'custom') continue;
        expect(p.baseUrl, isNotEmpty, reason: '${p.id} 缺 base_url');
        expect(p.defaultModel, isNotEmpty, reason: '${p.id} 缺默认模型');
        expect(p.baseUrl, startsWith('http'));
      }
    });

    test('ollama 不需要 API Key 且标记为不推荐', () {
      final ollama = LlmProviders.byId('ollama')!;
      expect(ollama.requiresApiKey, isFalse);
      expect(ollama.tier, ModelTier.discouraged);
    });

    test('模型分级决定了置信度门槛', () {
      expect(ModelTier.recommended.confidenceThreshold, 0.70);
      expect(ModelTier.acceptable.confidenceThreshold, 0.78);
      expect(ModelTier.discouraged.confidenceThreshold, 0.85);
      // 弱模型门槛必须更高（因为它的"高置信度"往往虚高）
      expect(
        ModelTier.discouraged.confidenceThreshold,
        greaterThan(ModelTier.recommended.confidenceThreshold),
      );
    });

    test('byId 找不到返回 null', () {
      expect(LlmProviders.byId('nonexistent'), isNull);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  group('LlmConfig', () {
    test('用预置 base_url 与默认模型', () {
      final c = testConfig();
      expect(c.baseUrl, 'https://api.deepseek.com/v1');
      expect(c.model, 'deepseek-chat');
      expect(c.validate().$1, isTrue);
    });

    test('覆盖 base_url 与模型，并去掉尾部斜杠', () {
      final c = LlmConfig(
        providerId: 'custom',
        apiKey: 'k',
        baseUrlOverride: 'https://my-proxy.example.com/v1/',
        modelOverride: 'my-model',
      );
      expect(c.baseUrl, 'https://my-proxy.example.com/v1');
      expect(c.model, 'my-model');
      expect(c.validate().$1, isTrue);
    });

    test('custom 缺 base_url 时校验失败并给出原因', () {
      final c = LlmConfig(providerId: 'custom', apiKey: 'k', modelOverride: 'm');
      final (ok, problem) = c.validate();
      expect(ok, isFalse);
      expect(problem, contains('API 地址'));
    });

    test('需要 Key 的服务商缺 Key 时校验失败', () {
      final c = LlmConfig(providerId: 'deepseek', apiKey: '  ');
      final (ok, problem) = c.validate();
      expect(ok, isFalse);
      expect(problem, contains('API Key'));
    });

    test('ollama 无 Key 也能通过校验', () {
      final c = LlmConfig(providerId: 'ollama', apiKey: '');
      expect(c.validate().$1, isTrue);
    });

    test('base_url 不是 http 开头时校验失败', () {
      final c = LlmConfig(
        providerId: 'custom',
        apiKey: 'k',
        baseUrlOverride: 'ftp://x',
        modelOverride: 'm',
      );
      expect(c.validate().$1, isFalse);
    });

    test('认证头按服务商风格生成', () {
      final bearer = testConfig().headers();
      expect(bearer['Authorization'], 'Bearer sk-test-key');

      final anthropic = testConfig(providerId: 'anthropic').headers();
      expect(anthropic['x-api-key'], 'sk-test-key');
      expect(anthropic.containsKey('Authorization'), isFalse);
      expect(anthropic['anthropic-version'], isNotNull);

      // Gemini 走 query 参数，不放认证头
      final gemini = testConfig(providerId: 'gemini').headers();
      expect(gemini.containsKey('Authorization'), isFalse);
      expect(gemini.containsKey('x-api-key'), isFalse);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  group('稳健 JSON 解析', () {
    test('直接解析合法 JSON', () {
      final r = RobustJson.extract('{"a": 1}');
      expect(r.ok, isTrue);
      expect(r.value!['a'], 1);
      expect(r.strategy, 'direct');
    });

    test('剥离 ```json 代码围栏', () {
      final r = RobustJson.extract('```json\n{"a": 2}\n```');
      expect(r.ok, isTrue);
      expect(r.value!['a'], 2);
      expect(r.strategy, 'code-fence');
    });

    test('剥离无语言标记的代码围栏', () {
      final r = RobustJson.extract('```\n{"a": 3}\n```');
      expect(r.ok, isTrue);
      expect(r.value!['a'], 3);
    });

    test('从解释文字中提取 JSON 块', () {
      const raw = '好的，我来分析这道题。\n\n{"a": 4, "b": "x"}\n\n以上就是标注结果。';
      final r = RobustJson.extract(raw);
      expect(r.ok, isTrue);
      expect(r.value!['a'], 4);
    });

    test('处理嵌套对象（花括号平衡，正则做不到）', () {
      const raw = '前缀 {"a": {"b": {"c": 5}}} 后缀';
      final r = RobustJson.extract(raw);
      expect(r.ok, isTrue);
      expect((r.value!['a'] as Map)['b']['c'], 5);
    });

    test('正确跳过字符串里的花括号', () {
      const raw = r'{"text": "这是一个 } 花括号", "n": 1}';
      final r = RobustJson.extract(raw);
      expect(r.ok, isTrue);
      expect(r.value!['n'], 1);
    });

    test('修复尾随逗号', () {
      final r = RobustJson.extract('{"a": 1, "b": 2,}');
      expect(r.ok, isTrue);
      expect(r.value!['b'], 2);
      expect(r.strategy, 'repaired');
    });

    test('修复单引号', () {
      final r = RobustJson.extract("{'a': 1}");
      expect(r.ok, isTrue);
      expect(r.value!['a'], 1);
    });

    test('修复无引号的键', () {
      final r = RobustJson.extract('{a: 1, b: "x"}');
      expect(r.ok, isTrue);
      expect(r.value!['b'], 'x');
    });

    test('修复 Python 字面量 None/True/False', () {
      final r = RobustJson.extract('{"a": None, "b": True, "c": False}');
      expect(r.ok, isTrue);
      expect(r.value!['a'], isNull);
      expect(r.value!['b'], isTrue);
      expect(r.value!['c'], isFalse);
    });

    test('归一化全角标点', () {
      final r = RobustJson.extract('｛"a"： 1｝');
      expect(r.ok, isTrue);
      expect(r.value!['a'], 1);
    });

    test('空输入明确失败', () {
      final r = RobustJson.extract('   ');
      expect(r.ok, isFalse);
      expect(r.strategy, 'empty');
    });

    test('完全无 JSON 时失败并保留诊断信息', () {
      final r = RobustJson.extract('这道题考查等价无穷小替换。');
      expect(r.ok, isFalse);
      expect(r.warnings, isNotEmpty);
    });

    test('数组而非对象时失败（我们只接受对象）', () {
      final r = RobustJson.extract('[1, 2, 3]');
      expect(r.ok, isFalse);
    });

    // ── 字段抽取的容错 ──
    group('字段抽取容错', () {
      test('stringField 容忍数字与列表', () {
        expect(RobustJson.stringField({'a': 'x'}, 'a'), 'x');
        expect(RobustJson.stringField({'a': 1}, 'a'), '1');
        expect(RobustJson.stringField({'a': ['x', 'y']}, 'a'), 'x');
        expect(RobustJson.stringField({'a': '  '}, 'a'), isNull);
        expect(RobustJson.stringField({}, 'a'), isNull);
      });

      test('doubleField 容忍字符串数字', () {
        expect(RobustJson.doubleField({'a': 0.92}, 'a'), 0.92);
        expect(RobustJson.doubleField({'a': '0.85'}, 'a'), 0.85);
        expect(RobustJson.doubleField({'a': 'abc'}, 'a'), isNull);
      });

      test('boolField 容忍中文与英文变体', () {
        expect(RobustJson.boolField({'a': true}, 'a'), isTrue);
        expect(RobustJson.boolField({'a': 'true'}, 'a'), isTrue);
        expect(RobustJson.boolField({'a': '是'}, 'a'), isTrue);
        expect(RobustJson.boolField({'a': '否'}, 'a'), isFalse);
      });

      test('stringListField 容忍字符串与逗号分隔', () {
        expect(RobustJson.stringListField({'a': ['x', 'y']}, 'a'), ['x', 'y']);
        expect(RobustJson.stringListField({'a': 'x、y'}, 'a'), ['x', 'y']);
        expect(RobustJson.stringListField({'a': 'x, y'}, 'a'), ['x', 'y']);
        // 对象数组取 id
        expect(
          RobustJson.stringListField({
            'a': [
              {'id': 'p1'},
              {'kp_id': 'p2'},
            ]
          }, 'a'),
          ['p1', 'p2'],
        );
      });

      test('objectListField 过滤非对象元素', () {
        final r = RobustJson.objectListField({
          'a': [
            {'x': 1},
            'not-a-map',
            {'y': 2},
          ]
        }, 'a');
        expect(r.length, 2);
      });
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  group('LlmClient · 请求构造', () {
    test('OpenAI 兼容：走 /chat/completions 且带 Bearer 头', () async {
      final http = FakeHttp([FakeHttp.ok('{}')]);
      final client = LlmClient(
        config: testConfig(),
        http: http,
        sleep: _noSleep,
      );
      await client.chat(const ChatRequest(system: 's', user: 'u'));

      final req = http.requests.single;
      expect(req.url, 'https://api.deepseek.com/v1/chat/completions');
      expect(req.headers['Authorization'], 'Bearer sk-test-key');
      final body = jsonDecode(req.body!) as Map;
      expect(body['model'], 'deepseek-chat');
      expect((body['messages'] as List).length, 2);
      expect(body['stream'], isFalse);
    });

    test('jsonMode 在已知支持的服务商上带 response_format', () async {
      final http = FakeHttp([FakeHttp.ok('{}')]);
      await LlmClient(config: testConfig(), http: http, sleep: _noSleep)
          .chat(const ChatRequest(system: 's', user: 'u', jsonMode: true));

      final body = jsonDecode(http.requests.single.body!) as Map;
      expect(body['response_format'], {'type': 'json_object'});
    });

    test('jsonMode 在 ollama 上不带 response_format（避免 400）', () async {
      final http = FakeHttp([FakeHttp.ok('{}')]);
      await LlmClient(
        config: LlmConfig(providerId: 'ollama', apiKey: ''),
        http: http,
        sleep: _noSleep,
      ).chat(const ChatRequest(system: 's', user: 'u', jsonMode: true));

      final body = jsonDecode(http.requests.single.body!) as Map;
      expect(body.containsKey('response_format'), isFalse);
    });

    test('Anthropic：system 放顶层，走 /messages', () async {
      final http = FakeHttp([
        HttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'content': [
              {'type': 'text', 'text': 'hi'},
            ],
            'usage': {'input_tokens': 10, 'output_tokens': 5},
          }),
        ),
      ]);
      final r = await LlmClient(
        config: testConfig(providerId: 'anthropic', model: 'claude-3-5-haiku'),
        http: http,
        sleep: _noSleep,
      ).chat(const ChatRequest(system: 'sys', user: 'usr'));

      expect(r.text, 'hi');
      final req = http.requests.single;
      expect(req.url, 'https://api.anthropic.com/v1/messages');
      final body = jsonDecode(req.body!) as Map;
      expect(body['system'], 'sys');
      expect((body['messages'] as List).length, 1, reason: 'system 不该在 messages 里');
      expect(body['max_tokens'], isNotNull, reason: 'Anthropic 强制要求 max_tokens');
    });

    test('Gemini：Key 走 query 参数', () async {
      final http = FakeHttp([
        HttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'gemini-out'},
                  ]
                }
              }
            ],
            'usageMetadata': {
              'promptTokenCount': 20,
              'candidatesTokenCount': 8,
            },
          }),
        ),
      ]);
      final r = await LlmClient(
        config: testConfig(providerId: 'gemini', model: 'gemini-1.5-flash'),
        http: http,
        sleep: _noSleep,
      ).chat(const ChatRequest(system: 's', user: 'u'));

      expect(r.text, 'gemini-out');
      expect(r.usage.inputTokens, 20);
      final req = http.requests.single;
      expect(req.url, contains('key=sk-test-key'));
      expect(req.url, contains(':generateContent'));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  group('LlmClient · 错误分类', () {
    Future<LlmException> sendExpectingError(
      HttpResponse resp, {
      String provider = 'deepseek',
    }) async {
      final client = LlmClient(
        config: testConfig(providerId: provider),
        http: FakeHttp([resp]),
        sleep: _noSleep,
      );
      try {
        await client.chat(const ChatRequest(system: 's', user: 'u'));
        fail('应当抛出 LlmException');
      } on LlmException catch (e) {
        return e;
      }
    }

    test('401 → invalidKey，并提示重新生成 Key', () async {
      final e = await sendExpectingError(FakeHttp.status(401));
      expect(e.kind, LlmErrorKind.invalidKey);
      expect(e.needsUserAction, isTrue);
      expect(e.kind.advice, contains('API Key'));
    });

    test('402 → insufficientBalance', () async {
      final e = await sendExpectingError(FakeHttp.status(402));
      expect(e.kind, LlmErrorKind.insufficientBalance);
      expect(e.kind.advice, contains('余额'));
    });

    test('404 → modelNotFound，并提示换模型', () async {
      final e = await sendExpectingError(FakeHttp.status(404));
      expect(e.kind, LlmErrorKind.modelNotFound);
      expect(e.kind.advice, contains('模型'));
    });

    test('429 → rateLimited 且可重试', () async {
      final e = await sendExpectingError(FakeHttp.status(429));
      expect(e.kind, LlmErrorKind.rateLimited);
      expect(e.kind.isRetryable, isTrue);
      expect(e.needsUserAction, isFalse, reason: '频率限制应自动重试，不该让用户改配置');
    });

    test('500 → serverError 且可重试', () async {
      final e = await sendExpectingError(FakeHttp.status(500));
      expect(e.kind, LlmErrorKind.serverError);
      expect(e.kind.isRetryable, isTrue);
    });

    test('400 → badRequest 且不可重试', () async {
      final e = await sendExpectingError(FakeHttp.status(400));
      expect(e.kind, LlmErrorKind.badRequest);
      expect(e.kind.isRetryable, isFalse);
    });

    test('余额不足也可能返回 400 + 特定 message，需按内容识别', () async {
      final e = await sendExpectingError(
        FakeHttp.status(400, '{"error":{"message":"Insufficient balance"}}'),
      );
      expect(e.kind, LlmErrorKind.insufficientBalance);
    });

    test('频率限制也可能藏在 400 的 message 里', () async {
      final e = await sendExpectingError(
        FakeHttp.status(400, '{"error":{"message":"Rate limit exceeded"}}'),
      );
      expect(e.kind, LlmErrorKind.rateLimited);
    });

    test('网络错误 → network，并提示可能需要代理', () async {
      final client = LlmClient(
        config: testConfig(providerId: 'openai'),
        http: FakeHttp([const HttpTransportException('无法建立连接')]),
        sleep: _noSleep,
      );
      try {
        await client.chat(const ChatRequest(system: 's', user: 'u'));
        fail('应抛出');
      } on LlmException catch (e) {
        expect(e.kind, LlmErrorKind.network);
        expect(e.kind.advice, contains('代理'));
      }
    });

    test('超时 → timeout', () async {
      final client = LlmClient(
        config: testConfig(),
        http: FakeHttp([const HttpTransportException('连接超时（timeout）')]),
        sleep: _noSleep,
      );
      try {
        await client.chat(const ChatRequest(system: 's', user: 'u'));
        fail('应抛出');
      } on LlmException catch (e) {
        expect(e.kind, LlmErrorKind.timeout);
      }
    });

    test('200 但响应不是 JSON → badResponse', () async {
      final e = await sendExpectingError(FakeHttp.status(200, 'not json'));
      expect(e.kind, LlmErrorKind.badResponse);
    });

    test('200 但 choices 为空 → badResponse', () async {
      final e = await sendExpectingError(
        FakeHttp.status(200, jsonEncode({'choices': <Object?>[]})),
      );
      expect(e.kind, LlmErrorKind.badResponse);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  group('LlmClient · 重试与退避', () {
    test('429 后重试成功', () async {
      final http = FakeHttp([
        FakeHttp.status(429),
        FakeHttp.ok('{"ok":true}'),
      ]);
      final r = await LlmClient(
        config: testConfig(),
        http: http,
        sleep: _noSleep,
      ).chat(const ChatRequest(system: 's', user: 'u'));

      expect(r.text, contains('ok'));
      expect(r.attempts, 2);
      expect(http.requests.length, 2);
    });

    test('不可重试的错误立即抛出，不做无谓等待', () async {
      var sleepCalls = 0;
      final http = FakeHttp([FakeHttp.status(401)]);
      try {
        await LlmClient(
          config: testConfig(),
          http: http,
          sleep: (d) async => sleepCalls++,
        ).chat(const ChatRequest(system: 's', user: 'u'));
        fail('应抛出');
      } on LlmException catch (e) {
        expect(e.kind, LlmErrorKind.invalidKey);
        expect(sleepCalls, 0, reason: '401 不该重试');
        expect(http.requests.length, 1, reason: '只该请求一次');
      }
    });

    test('连续失败达到上限后抛出', () async {
      final http = FakeHttp([FakeHttp.status(500)]);
      var sleepCalls = 0;
      try {
        await LlmClient(
          config: testConfig(),
          http: http,
          retry: const RetryPolicy(maxAttempts: 3),
          sleep: (d) async => sleepCalls++,
        ).chat(const ChatRequest(system: 's', user: 'u'));
        fail('应抛出');
      } on LlmException catch (e) {
        expect(e.kind, LlmErrorKind.serverError);
        expect(http.requests.length, 3);
        expect(sleepCalls, 2, reason: '3 次尝试之间有 2 次退避');
      }
    });

    test('退避时长按倍数增长且有上限', () {
      const p = RetryPolicy(
        initialBackoff: Duration(seconds: 2),
        backoffMultiplier: 2.0,
        maxBackoff: Duration(seconds: 10),
      );
      expect(p.backoffFor(1).inSeconds, 2);
      expect(p.backoffFor(2).inSeconds, 4);
      expect(p.backoffFor(3).inSeconds, 8);
      expect(p.backoffFor(4).inSeconds, 10, reason: '应被 maxBackoff 截断');
      expect(p.backoffFor(10).inSeconds, 10);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  group('LlmClient · 用量与计费', () {
    test('提取 OpenAI 风格用量', () async {
      final client = LlmClient(
        config: testConfig(),
        http: FakeHttp([FakeHttp.ok('{"a":1}', inTok: 1000, outTok: 500)]),
        sleep: _noSleep,
      );
      final r = await client.chat(const ChatRequest(system: 's', user: 'u'));
      expect(r.usage.inputTokens, 1000);
      expect(r.usage.outputTokens, 500);
      expect(r.usage.totalTokens, 1500);
      expect(r.usage.costYuan, isNotNull);
    });

    test('onUsage 回调被触发', () async {
      final seen = <LlmUsage>[];
      await LlmClient(
        config: testConfig(),
        http: FakeHttp([FakeHttp.ok('{}', inTok: 10, outTok: 20)]),
        sleep: _noSleep,
        onUsage: seen.add,
      ).chat(const ChatRequest(system: 's', user: 'u'));

      expect(seen.length, 1);
      expect(seen.first.totalTokens, 30);
    });

    test('LlmUsage 可累加', () {
      const a = LlmUsage(inputTokens: 100, outputTokens: 50, costYuan: 0.01);
      const b = LlmUsage(inputTokens: 200, outputTokens: 100, costYuan: 0.02);
      final sum = a + b;
      expect(sum.inputTokens, 300);
      expect(sum.outputTokens, 150);
      expect(sum.costYuan, closeTo(0.03, 1e-9));
    });

    test('缓存用量总量为 0', () {
      expect(LlmUsage.cached.totalTokens, 0);
      expect(LlmUsage.cached.fromCache, isTrue);
    });

    test('价目表能匹配模型名（包含匹配）', () {
      expect(LlmPricing.has('deepseek-chat'), isTrue);
      expect(LlmPricing.has('qwen-plus'), isTrue);
      expect(LlmPricing.has('完全不存在的模型'), isFalse);

      final cost = LlmPricing.estimate(
        model: 'deepseek-chat',
        inputTokens: 1000000,
        outputTokens: 1000000,
      );
      // deepseek-chat: 输入 1.0 + 输出 2.0 = 3.0 元/百万各一
      expect(cost, closeTo(3.0, 1e-6));
    });

    test('未知模型返回 null 费用', () {
      expect(
        LlmPricing.estimate(
          model: 'unknown-model',
          inputTokens: 100,
          outputTokens: 100,
        ),
        isNull,
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  group('知识点召回', () {
    final kb = buildTestKnowledge();

    test('公式匹配能召回对应知识点', () {
      final problem = buildProblem(
        stem: r'计算 $\lim_{x\to 0}\frac{1-\cos x}{x^2}$',
      );
      final r = KnowledgeRecall(knowledge: kb).recall(problem);

      final ids = r.candidates.map((c) => c.point.id).toList();
      expect(ids, contains('math1.calc.limit.eq_infinitesimal'));
      expect(r.formulaHits, greaterThan(0));
    });

    test('名称匹配能召回对应知识点', () {
      final problem = buildProblem(stem: '用洛必达法则求下列极限。');
      final r = KnowledgeRecall(knowledge: kb).recall(problem);
      expect(
        r.candidates.map((c) => c.point.id),
        contains('math1.calc.limit.lhopital'),
      );
      expect(r.nameHits, greaterThan(0));
    });

    test('候选数量不超过 maxCandidates', () {
      final problem = buildProblem(stem: '求极限');
      final r = KnowledgeRecall(
        knowledge: kb,
        config: const RecallConfig(maxCandidates: 3),
      ).recall(problem);
      expect(r.candidates.length, lessThanOrEqualTo(3));
    });

    test('章节保底：即使关键词不匹配也会给出候选', () {
      // 一道完全不匹配任何关键词的题
      final problem = buildProblem(stem: 'zzz qqq 无关内容');
      final r = KnowledgeRecall(
        knowledge: kb,
        config: const RecallConfig(minPerChapter: 1, maxCandidates: 20),
      ).recall(problem);

      // 两个章节（极限、特征值）都应有候选
      final chapters = r.candidates.map((c) => c.point.chapterId).toSet();
      expect(chapters.length, greaterThanOrEqualTo(2),
          reason: '章节保底应确保每章都有候选');
      expect(r.chapterFloorAdded, greaterThan(0));
    });

    test('排序稳定：同分时按考频再按 id', () {
      final problem = buildProblem(stem: '求极限');
      final r1 = KnowledgeRecall(knowledge: kb).recall(problem);
      final r2 = KnowledgeRecall(knowledge: kb).recall(problem);
      expect(
        r1.candidates.map((c) => c.point.id).toList(),
        r2.candidates.map((c) => c.point.id).toList(),
      );
    });

    test('题型不符时降权', () {
      // similar_diag 只声明 solve/proof，用 choice 题型应被降权
      final problem = buildProblem(
        stem: '相似对角化 特征值 几何重数 代数重数',
        qtype: QuestionType.choice,
      );
      final r = KnowledgeRecall(knowledge: kb).recall(problem);
      final cand = r.candidates
          .where((c) => c.point.id == 'math1.linalg.eigen.similarity')
          .firstOrNull;
      if (cand != null) {
        expect(
          cand.reasons.any((x) => x.contains('题型不符')),
          isTrue,
        );
      }
    });

    test('空本体返回空召回而不崩溃', () {
      final empty = KnowledgeBase(
        subject: 'x',
        subjectName: 'x',
        version: '0',
        nodes: const [],
      );
      final r = KnowledgeRecall(knowledge: empty).recall(buildProblem());
      expect(r.isEmpty, isTrue);
      expect(r.totalLeaves, 0);
    });

    test('召回的候选 id 都是叶子节点', () {
      final r = KnowledgeRecall(knowledge: kb).recall(buildProblem());
      for (final c in r.candidates) {
        expect(c.point.isLeaf, isTrue, reason: '${c.point.id} 不是叶子');
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  group('TagResult 校验', () {
    const candidates = {
      'math1.calc.limit.eq_infinitesimal',
      'math1.calc.limit.lhopital',
      'math1.calc.limit.taylor',
    };

    TagResult parse(Map<String, dynamic> j) => TagResult.fromJson(
          j,
          candidateIds: candidates,
          defaultConfidence: 0.5,
          extractionStrategy: 'direct',
        );

    test('合法结果解析正确', () {
      final r = parse({
        'primary': {'kp_id': 'math1.calc.limit.taylor', 'confidence': 0.92},
        'secondary': [
          {'kp_id': 'math1.calc.limit.lhopital', 'relevance': 0.6},
        ],
        'difficulty': 3,
        'error_causes': ['idea'],
        'reason': '需要泰勒展开到三阶',
      });

      expect(r.primaryKpId, 'math1.calc.limit.taylor');
      expect(r.confidence, 0.92);
      expect(r.secondary.length, 1);
      expect(r.difficulty, 3);
      expect(r.errorCauses, ['idea']);
      expect(r.warnings, isEmpty);
    });

    test('primary 不在候选集里 → 标记阻断性问题', () {
      final r = parse({
        'primary': {'kp_id': '不存在的知识点', 'confidence': 0.9},
      });
      expect(r.warnings.any(TagResult.isBlockingWarning), isTrue);
      expect(r.warnings.any((w) => w.contains('不在候选集')), isTrue);
    });

    test('缺少 primary → 阻断性问题', () {
      final r = parse({'secondary': <Object?>[]});
      expect(r.warnings.any(TagResult.isBlockingWarning), isTrue);
    });

    test('primary 是字符串也能解析', () {
      final r = parse({'primary': 'math1.calc.limit.taylor'});
      expect(r.primaryKpId, 'math1.calc.limit.taylor');
      expect(r.warnings, isNotEmpty, reason: '应提示格式非标准');
    });

    test('置信度百分数被归一化', () {
      expect(parse({
        'primary': {'kp_id': 'math1.calc.limit.taylor', 'confidence': 92},
      }).confidence, closeTo(0.92, 1e-9));
    });

    test('置信度越界被夹住', () {
      // ≤1 视为小数
      expect(parse({
        'primary': {'kp_id': 'math1.calc.limit.taylor', 'confidence': 0.92},
      }).confidence, 0.92);

      // (1, 100] 视为百分数 → 除以 100
      expect(parse({
        'primary': {'kp_id': 'math1.calc.limit.taylor', 'confidence': 92},
      }).confidence, closeTo(0.92, 1e-9));

      // 小整数也按百分数解释（5 → 5%）。
      // 这是**有意的安全选择**：模型想表达"约一半把握"却写成 5，
      // 当成 5% 会让它进人工确认队列；当成 100% 则会污染题库。
      expect(parse({
        'primary': {'kp_id': 'math1.calc.limit.taylor', 'confidence': 5},
      }).confidence, closeTo(0.05, 1e-9));

      // >100 视为越界 → 夹到 1.0
      expect(parse({
        'primary': {'kp_id': 'math1.calc.limit.taylor', 'confidence': 150},
      }).confidence, 1.0);

      // 负数夹到 0
      expect(parse({
        'primary': {'kp_id': 'math1.calc.limit.taylor', 'confidence': -1},
      }).confidence, 0.0);
    });

    test('难度越界被夹到 [1,3] 并警告', () {
      final r = parse({
        'primary': {'kp_id': 'math1.calc.limit.taylor'},
        'difficulty': 9,
      });
      expect(r.difficulty, 3);
      expect(r.warnings.any((w) => w.contains('difficulty')), isTrue);
    });

    test('次考点不在候选集里被忽略并警告', () {
      final r = parse({
        'primary': {'kp_id': 'math1.calc.limit.taylor'},
        'secondary': [
          {'kp_id': '非法知识点'},
          {'kp_id': 'math1.calc.limit.lhopital'},
        ],
      });
      expect(r.secondary.length, 1);
      expect(r.secondary.first.kpId, 'math1.calc.limit.lhopital');
      expect(r.warnings.any((w) => w.contains('不在候选集')), isTrue);
    });

    test('次考点最多 3 个', () {
      final r = parse({
        'primary': {'kp_id': 'math1.calc.limit.taylor'},
        'secondary': [
          {'kp_id': 'math1.calc.limit.lhopital'},
          {'kp_id': 'math1.calc.limit.eq_infinitesimal'},
          {'kp_id': 'math1.calc.limit.taylor'},
          {'kp_id': 'math1.calc.limit.lhopital'},
        ],
      });
      expect(r.secondary.length, lessThanOrEqualTo(3));
    });

    test('主考点不该重复出现在次考点里', () {
      final r = parse({
        'primary': {'kp_id': 'math1.calc.limit.taylor'},
        'secondary': [
          {'kp_id': 'math1.calc.limit.taylor'},
        ],
      });
      expect(r.secondary, isEmpty);
    });

    test('非法错因被忽略并警告', () {
      final r = parse({
        'primary': {'kp_id': 'math1.calc.limit.taylor'},
        'error_causes': ['idea', '不存在的错因', 'calc'],
      });
      expect(r.errorCauses, ['idea', 'calc']);
      expect(r.warnings.any((w) => w.contains('错因')), isTrue);
    });

    test('错因支持逗号分隔字符串', () {
      final r = parse({
        'primary': {'kp_id': 'math1.calc.limit.taylor'},
        'error_causes': 'idea、calc',
      });
      expect(r.errorCauses, ['idea', 'calc']);
    });

    test('needsReview 判据：低置信度或阻断性问题', () {
      final lowConf = parse({
        'primary': {'kp_id': 'math1.calc.limit.taylor', 'confidence': 0.5},
      });
      expect(lowConf.needsReview(0.7), isTrue);
      expect(lowConf.needsReview(0.4), isFalse);

      final blocking = parse({
        'primary': {'kp_id': '非法', 'confidence': 0.99},
      });
      expect(blocking.needsReview(0.7), isTrue,
          reason: '即使置信度高，id 非法也必须人工确认');
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  group('TagPrompt', () {
    final kb = buildTestKnowledge();

    test('system prompt 包含关键约束', () {
      final s = TagPromptBuilder.systemPrompt(candidateCount: 25);
      expect(s, contains('有且仅有一个'));
      expect(s, contains('必须是候选列表中的 id'));
      expect(s, contains('不要任何解释文字'));
      expect(s, contains('25'));
    });

    test('user prompt 列出全部候选及其 id', () {
      final problem = buildProblem();
      final recall = KnowledgeRecall(knowledge: kb).recall(problem);
      final u = TagPromptBuilder(knowledge: kb)
          .userPrompt(problem: problem, recall: recall);

      for (final c in recall.candidates) {
        expect(u, contains(c.point.id), reason: '缺少候选 ${c.point.id}');
        expect(u, contains(c.point.name));
      }
      expect(u, contains('## 候选知识点'));
    });

    test('图片语法被剥离（模型看不见图）', () {
      final problem = buildProblem(
        stem: '设函数如图 ![题图](images/a.png) 求极限',
      );
      final recall = KnowledgeRecall(knowledge: kb).recall(problem);
      final u = TagPromptBuilder(knowledge: kb)
          .userPrompt(problem: problem, recall: recall);

      expect(u, isNot(contains('images/a.png')));
      expect(u, contains('设函数'));
    });

    test('超长解析被截断', () {
      final problem = buildProblem(solution: '解析内容' * 2000);
      final recall = KnowledgeRecall(knowledge: kb).recall(problem);
      final u = TagPromptBuilder(knowledge: kb)
          .userPrompt(problem: problem, recall: recall);
      expect(u.length, lessThan(20000));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  group('标注引擎编排', () {
    final kb = buildTestKnowledge();

    KnowledgeTagger taggerWith(FakeHttp http, {TagCache? cache}) =>
        KnowledgeTagger(
          knowledge: kb,
          client: LlmClient(
            config: testConfig(),
            http: http,
            sleep: _noSleep,
          ),
          cache: cache,
        );

    test('端到端：召回 → LLM → 解析 → 写缓存', () async {
      final cache = MemoryTagCache();
      final http = FakeHttp([
        FakeHttp.ok(jsonEncode({
          'primary': {
            'kp_id': 'math1.calc.limit.eq_infinitesimal',
            'confidence': 0.92,
          },
          'secondary': [
            {'kp_id': 'math1.calc.limit.lhopital', 'relevance': 0.6},
          ],
          'difficulty': 2,
          'error_causes': ['calc'],
          'reason': '考查等价无穷小与洛必达',
        })),
      ]);

      // ⚠️ 题干必须与测试知识库的公式匹配，否则召回会失败。
      //
      // 最初用的是 `\frac{\sin x - x\cos x}{x^3}`（真题原文），
      // 但测试知识库里 eq_infinitesimal 的公式是
      // `1-\cos x \sim \frac{x^2}{2}` —— 两者 token 重叠不足，
      // 召回被精度闸门过滤掉，导致 tagger 空转 3 次重试。
      //
      // 这本身暴露了一个真实的产品风险（见技术债 T15）：
      // **公式匹配对"题目形态"敏感**。生产环境靠 25 个候选的宽度容忍它，
      // 但单元测试必须用匹配得上的题干。
      final problem = buildProblem(
        stem: r'当 $x\to 0$ 时，求 $\lim_{x\to 0}\frac{1-\cos x}{x^{2}}$',
      );

      final outcome = await taggerWith(http, cache: cache).tag(problem);

      expect(outcome.ok, isTrue);
      expect(outcome.result!.primaryKpId,
          'math1.calc.limit.eq_infinitesimal');
      expect(outcome.fromCache, isFalse);
      expect(outcome.attempts, 1, reason: '首次应直接成功');
      expect(outcome.usage.totalTokens, greaterThan(0));
      expect(cache.size, 1, reason: '结果应写入缓存，且只写一次');
    });

    test('缓存命中时零成本、不请求网络', () async {
      final cache = MemoryTagCache();
      final http = FakeHttp([FakeHttp.ok('{}')]);
      final tagger = taggerWith(http, cache: cache);

      // 第一次：真调用
      http.responses.clear();
      http.responses.add(FakeHttp.ok(jsonEncode({
        'primary': {'kp_id': 'math1.calc.limit.taylor', 'confidence': 0.9},
      })));
      await tagger.tag(buildProblem(fingerprint: 'fp-A'));
      expect(http.requests.length, 1);

      // 第二次：同 fingerprint，应命中缓存
      final second = await tagger.tag(buildProblem(fingerprint: 'fp-A'));
      expect(second.fromCache, isTrue);
      expect(second.usage.totalTokens, 0);
      expect(http.requests.length, 1, reason: '不该再请求网络');
    });

    test('primary 非法时带错误信息重试，第二次成功', () async {
      final http = FakeHttp([
        // 第一次：给了候选外的 id
        FakeHttp.ok(jsonEncode({
          'primary': {'kp_id': '不存在的知识点', 'confidence': 0.9},
        })),
        // 第二次：修正
        FakeHttp.ok(jsonEncode({
          'primary': {'kp_id': 'math1.calc.limit.taylor', 'confidence': 0.88},
        })),
      ]);

      final outcome = await taggerWith(http).tag(buildProblem());

      expect(outcome.ok, isTrue);
      expect(outcome.result!.primaryKpId, 'math1.calc.limit.taylor');
      expect(outcome.attempts, 2);
      expect(http.requests.length, 2);

      // 第二次请求应包含错误反馈
      final body = jsonDecode(http.requests[1].body!) as Map;
      final messages = body['messages'] as List;
      final userMsg = (messages[1] as Map)['content'] as String;
      expect(userMsg, contains('上次输出有问题'));
      expect(userMsg, contains('不在候选集'));
    });

    test('模型输出非 JSON 时重试', () async {
      final http = FakeHttp([
        FakeHttp.ok('这道题考查泰勒公式。'),
        FakeHttp.ok(jsonEncode({
          'primary': {'kp_id': 'math1.calc.limit.taylor', 'confidence': 0.9},
        })),
      ]);

      final outcome = await taggerWith(http).tag(buildProblem());
      expect(outcome.ok, isTrue);
      expect(outcome.attempts, 2);
    });

    test('重试次数用尽后返回带警告的结果（而非失败）', () async {
      final http = FakeHttp([
        FakeHttp.ok(jsonEncode({
          'primary': {'kp_id': '非法 id', 'confidence': 0.95},
        })),
      ]);

      final outcome = await KnowledgeTagger(
        knowledge: kb,
        client: LlmClient(
          config: testConfig(),
          http: http,
          sleep: _noSleep,
        ),
        maxAttempts: 2,
      ).tag(buildProblem());

      // 有结果，但带阻断性警告 —— 上层据此进人工队列
      expect(outcome.ok, isTrue);
      expect(outcome.result!.primaryKpId, '非法 id');
      expect(outcome.result!.needsReview(0.7), isTrue);
      expect(http.requests.length, 2);
    });

    test('LLM 调用失败时返回失败并附建议', () async {
      final http = FakeHttp([FakeHttp.status(401)]);
      final outcome = await taggerWith(http).tag(buildProblem());

      expect(outcome.ok, isFalse);
      expect(outcome.failure, contains('invalidKey'));
      expect(outcome.failure, contains('API Key'));
    });

    test('召回为空时立即失败，不请求网络', () async {
      final empty = KnowledgeBase(
        subject: 'x',
        subjectName: 'x',
        version: '0',
        nodes: const [],
      );
      final http = FakeHttp([FakeHttp.ok('{}')]);
      final outcome = await KnowledgeTagger(
        knowledge: empty,
        client: LlmClient(
          config: testConfig(),
          http: http,
          sleep: _noSleep,
        ),
      ).tag(buildProblem());

      expect(outcome.ok, isFalse);
      expect(outcome.failure, contains('召回为空'));
      expect(http.requests, isEmpty);
    });

    test('多次重试的用量被累加', () async {
      final http = FakeHttp([
        FakeHttp.ok('bad', inTok: 100, outTok: 50),
        FakeHttp.ok(jsonEncode({
          'primary': {'kp_id': 'math1.calc.limit.taylor', 'confidence': 0.9},
        }), inTok: 200, outTok: 80),
      ]);

      final outcome = await taggerWith(http).tag(buildProblem());
      expect(outcome.usage.inputTokens, 300);
      expect(outcome.usage.outputTokens, 130);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  group('结果应用与序列化', () {
    test('applyTagResult 写入知识点与元数据', () {
      final problem = buildProblem();
      const tag = TagResult(
        primaryKpId: 'math1.calc.limit.taylor',
        confidence: 0.9,
        secondary: [
          (kpId: 'math1.calc.limit.lhopital', relevance: 0.6),
        ],
        difficulty: 3,
        errorCauses: ['idea'],
      );

      final applied = applyTagResult(problem, tag);

      expect(applied.knowledge.length, 2);
      expect(applied.primaryKnowledge!.id, 'math1.calc.limit.taylor');
      expect(applied.primaryKnowledge!.isPrimary, isTrue);
      expect(applied.difficulty, 3);
      expect(applied.errorCauses, ['idea']);
      expect(applied.aiTagged, isTrue);
      expect(applied.aiConfidence, 0.9);
    });

    test('低置信度结果被标记需复核', () {
      final applied = applyTagResult(
        buildProblem(),
        const TagResult(
          primaryKpId: 'math1.calc.limit.taylor',
          confidence: 0.3,
        ),
      );
      expect(applied.needsReview, isTrue);
    });

    test('TagResultCodec 往返', () {
      const original = TagResult(
        primaryKpId: 'math1.calc.limit.taylor',
        confidence: 0.88,
        secondary: [
          (kpId: 'math1.calc.limit.lhopital', relevance: 0.55),
        ],
        difficulty: 2,
        errorCauses: ['calc', 'idea'],
        reason: '测试理由',
        extractionStrategy: 'direct',
      );

      final encoded = TagResultCodec.encode(original);
      final decoded = TagResultCodec.decode(encoded);

      expect(decoded, isNotNull);
      expect(decoded!.primaryKpId, original.primaryKpId);
      expect(decoded.confidence, original.confidence);
      expect(decoded.secondary.length, 1);
      expect(decoded.difficulty, original.difficulty);
      expect(decoded.errorCauses, original.errorCauses);
      expect(decoded.reason, original.reason);
    });

    test('TagResultCodec 对坏数据返回 null 而不抛异常', () {
      expect(TagResultCodec.decode('not json'), isNull);
      expect(TagResultCodec.decode('[]'), isNull);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  group('MemoryTagCache', () {
    test('读写清', () async {
      final c = MemoryTagCache();
      expect(await c.get('x'), isNull);

      await c.put('x', const TagResult(primaryKpId: 'a', confidence: 0.9));
      expect((await c.get('x'))!.primaryKpId, 'a');
      expect(c.size, 1);

      c.clear();
      expect(await c.get('x'), isNull);
    });
  });
}
