/// 流式输出：SSE 解析 + 逐字返回 + "什么时候可以重试"。
///
/// ## 为什么这个文件值得单独存在
///
/// 流式与普通请求的**失效方式完全不同**，而且都很难在真机上复盘：
///
/// 1. **半行缓冲**。TCP 分块边界不受我们控制，`data: {...}` 极可能被切成
///    `data: {"cho` + `ices":...}`。缓冲写错 → 一堆帧解析失败 →
///    用户看到回复缺字，而日志里只有"没有文本内容"。
/// 2. **中文跨块**。一个汉字 3 字节，切在中间时 `utf8.decode` 会抛异常
///    或被替换成 `U+FFFD`。这条在 `dio_http_adapter` 里靠
///    `utf8.decoder` 的流式版解决，这里守住"字符串层"的那一半。
/// 3. **重试会撕裂回复**。这是最要紧的一条：一旦吐过字就绝不能重试 ——
///    否则用户看到的是"洛必"+"洛必达法则"，永远分不清哪一遍算数。
///    测试里那两条相反的断言（吐过字→不重试 / 没吐字→重试）就是钉它的。
/// 4. **用量与停止原因藏在收尾帧里**，而那种帧的 `delta` 是空的 ——
///    把提取逻辑挂在"有 delta 才处理"的分支上，用量就永远记不到。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/services/llm/llm_client.dart';
import 'package:kaoyan_math_agent/services/llm/llm_stream.dart';
import 'package:kaoyan_math_agent/services/llm/provider_registry.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 脚手架
// ─────────────────────────────────────────────────────────────────────────────

/// 按脚本吐块的假适配器。
///
/// 脚本里的元素有两种：`HttpStreamChunk` 照常吐，
/// `Exception` 则在流中间抛出（模拟连接被掐断）。
///
/// ## ⚠️ 为什么脚本要"按轮"而不是"一个脚本重放"
///
/// 重试用例里第一轮必须失败、第二轮必须成功。如果每次调用都重放
/// 同一个脚本，每一轮都会撞上同一个失败，`attempt` 一路涨到上限 ——
/// 于是"重试后恢复"这条路径**永远测不到**，而失败的样子还很像
/// "重试没生效"（第一版就是这么写的，三条用例全挂在这里）。
class StreamHttp extends HttpAdapter {
  /// 每一轮（每次 HTTP 调用）的脚本；超出后重复最后一轮。
  final List<List<Object>> rounds;

  final List<HttpRequest> requests = [];
  int _i = 0;

  /// 单轮脚本。只适用于不涉及重试的用例。
  StreamHttp(List<Object> script) : rounds = [script];

  /// 多轮脚本，按调用次序取用。
  StreamHttp.rounds(this.rounds);

  int get calls => requests.length;

  @override
  Future<HttpResponse> send(HttpRequest request) =>
      throw StateError('这个测试只走流式，不该调 send');

  @override
  Stream<HttpStreamChunk> sendStream(HttpRequest request) async* {
    requests.add(request);
    final script = rounds[_i < rounds.length ? _i : rounds.length - 1];
    _i++;
    for (final item in script) {
      if (item is HttpStreamChunk) {
        yield item;
      } else if (item is Exception) {
        throw item;
      } else {
        throw StateError('不支持的脚本项：${item.runtimeType}');
      }
    }
  }
}

LlmClient _client(
  HttpAdapter http, {
  String provider = 'openai',
  int maxAttempts = 3,
  void Function(LlmUsage)? onUsage,
}) =>
    LlmClient(
      config: LlmConfig(
        providerId: provider,
        apiKey: 'k',
        modelOverride: 'gpt-4o-mini',
      ),
      http: http,
      retry: RetryPolicy(maxAttempts: maxAttempts),
      // 退避等待换成立即返回：否则"重试"那两条用例要真等好几秒
      sleep: (_) async {},
      onUsage: onUsage,
    );

ChatRequest _req() => const ChatRequest(system: '你是助手', user: '你好');

/// 一帧 OpenAI 风格的增量。
String _delta(String text) => jsonEncode({
      'choices': [
        {
          'index': 0,
          'delta': {'content': text},
        }
      ],
    });

/// 一帧只有用量、没有内容的收尾帧（OpenAI 的 `stream_options.include_usage`
/// 就是这么发的：`choices` 是**空数组**）。
String _usageOnly({int prompt = 120, int completion = 30}) => jsonEncode({
      'choices': <Object>[],
      'usage': {'prompt_tokens': prompt, 'completion_tokens': completion},
    });

String _sse(String payload) => 'data: $payload\n\n';

HttpStreamChunk _chunk(String text) =>
    HttpStreamChunk(statusCode: 200, text: text);

/// 把整条事件流收完。
Future<List<ChatStreamEvent>> _collect(LlmClient client) async {
  final out = <ChatStreamEvent>[];
  await for (final e in client.chatStream(_req())) {
    out.add(e);
  }
  return out;
}

Map<String, dynamic> _bodyOf(HttpRequest r) =>
    jsonDecode(r.body ?? '{}') as Map<String, dynamic>;

void main() {
  // ───────────────────────────────────────────────────────────────────────────
  group('SseParser：把陆续到达的文本切成 data 载荷', () {
    test('半行留在缓冲里，凑齐了才交出来', () {
      final p = SseParser();

      expect(p.feed('data: {"a"'), isEmpty, reason: '没有换行 → 这行还没结束');
      expect(p.feed(':1}\n'), ['{"a":1}']);
    });

    test('一次喂进来多行，按顺序全交出来', () {
      final p = SseParser();

      final got = p.feed('data: one\n\ndata: two\n\ndata: three\n\n');

      expect(got, ['one', 'two', 'three']);
    });

    test('CRLF 行尾也算数', () {
      final p = SseParser();

      expect(p.feed('data: x\r\n\r\n'), ['x']);
    });

    test('以冒号开头的是注释（心跳），不是数据', () {
      final p = SseParser();

      // 推理型模型"思考"时，服务商会隔几秒发一个 `:` 保活。
      // 把它当数据会解析出一串噪声，还会中断正常的打字机节奏。
      expect(p.feed(': keep-alive\n\n'), isEmpty);
    });

    test('event: / id: / retry: 一律忽略，只要 data:', () {
      final p = SseParser();

      final got = p.feed('event: message\nid: 7\nretry: 300\n'
          'data: payload\n\n');

      expect(got, ['payload']);
    });

    test('`data:` 后面有无空格都要认', () {
      final p = SseParser();

      // 规范说可以有一个空格，但实践里两种都出现过
      expect(p.feed('data:with-space\n'), ['with-space']);
      expect(p.feed('data:  two-spaces\n'), ['two-spaces']);
    });

    test('半个 JSON 被切成两块，仍能拼出一条完整载荷', () {
      final p = SseParser();

      // 模拟 TCP 把一帧切在中间 —— 这是最常见的一种
      final a = p.feed('data: {"choices":[{"delta":{"con');
      final b = p.feed('tent":"洛"}}]}\n\n');

      expect(a, isEmpty);
      expect(b, ['{"choices":[{"delta":{"content":"洛"}}]}']);
    });

    test('flush 交出没有结尾换行的那半行', () {
      final p = SseParser();

      p.feed('data: 最后一句');

      // 服务商没发结尾换行。丢掉它 → 用户看到"最后一句莫名缺了"，
      // 而且只在某些服务商上出现，极难归因。
      expect(p.flush(), ['最后一句']);
      expect(p.flush(), isEmpty, reason: 'flush 之后缓冲应该是空的');
    });

    test('flush 时缓冲为空（正常收尾）返回空', () {
      final p = SseParser();

      p.feed('data: x\n\n');

      expect(p.flush(), isEmpty);
    });

    test('flush 时剩下的半行不是数据行就丢掉，不硬凑', () {
      final p = SseParser();

      p.feed('event: message');

      // 半截事件名硬交出去只会让上层多解析一次、多报一个无用的错
      expect(p.flush(), isEmpty);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('chatStream：逐字返回', () {
    test('多帧 → 多个 delta，最后一帧带完整文本', () async {
      final http = StreamHttp([
        _chunk(_sse(_delta('洛'))),
        _chunk(_sse(_delta('必达'))),
        _chunk(_sse(_delta('法则'))),
        _chunk(_sse('[DONE]')),
      ]);

      final events = await _collect(_client(http));

      expect(
        events.whereType<ChatDelta>().map((d) => d.text),
        ['洛', '必达', '法则'],
      );
      final done = events.whereType<ChatDone>().single;
      expect(done.response.text, '洛必达法则');
      expect(done.response.attempts, 1);
    });

    test('一次收到多帧时也逐条吐出（不做批量合并）', () async {
      final http = StreamHttp([
        // 网络把三帧挤在一个 chunk 里到达 —— 很常见
        _chunk(_sse(_delta('甲')) + _sse(_delta('乙')) + _sse(_delta('丙'))),
      ]);

      final events = await _collect(_client(http));

      expect(
        events.whereType<ChatDelta>().map((d) => d.text),
        ['甲', '乙', '丙'],
      );
    });

    test('请求体里 stream 为 true', () async {
      final http = StreamHttp([_chunk(_sse(_delta('好')))]);

      await _collect(_client(http));

      final body = _bodyOf(http.requests.single);
      expect(body['stream'], isTrue);
      expect(body['model'], 'gpt-4o-mini');
    });

    test('收尾帧只有 usage、没有 content 时，用量照样记到', () async {
      // ⚠️ 这条守的是一个很容易犯的错：把 usage 提取写在
      // "有 delta 才处理" 的分支里。OpenAI 的收尾帧 `choices` 是空数组，
      // 那种帧永远进不了 delta 分支 —— 用量就整个丢了。
      final http = StreamHttp([
        _chunk(_sse(_delta('好'))),
        _chunk(_sse(_usageOnly(prompt: 120, completion: 30))),
        _chunk(_sse('[DONE]')),
      ]);

      final events = await _collect(_client(http));

      final done = events.whereType<ChatDone>().single;
      expect(done.response.usage.totalTokens, 150);
    });

    test('停止原因取自收尾帧，用于判断是否被截断', () async {
      final http = StreamHttp([
        _chunk(_sse(_delta('被砍断的回'))),
        _chunk(_sse(jsonEncode({
          'choices': [
            {'index': 0, 'delta': <String, dynamic>{}, 'finish_reason': 'length'},
          ],
        }))),
        _chunk(_sse('[DONE]')),
      ]);

      final events = await _collect(_client(http));

      final done = events.whereType<ChatDone>().single;
      expect(done.response.finishReason, 'length');
      expect(done.response.truncated, isTrue,
          reason: '流式下被截断同样要能报出来，否则用户以为回复本来就短');
    });

    test('一句话都不吐就结束：报 badResponse，并带上最后一帧的原文', () async {
      final http = StreamHttp([_chunk(_sse('this-is-not-json'))]);

      Object? err;
      try {
        await _collect(_client(http));
      } catch (e) {
        err = e;
      }

      expect(err, isA<LlmException>());
      final e = err! as LlmException;
      expect(e.kind, LlmErrorKind.badResponse);
      // 诊断证据：没有它，排查只剩一句"没有文本内容"，等于从零开始
      expect(e.rawBody, contains('this-is-not-json'));
    });

    test('onUsage 拿到的是这一轮的用量', () async {
      final seen = <LlmUsage>[];
      final http = StreamHttp([
        _chunk(_sse(_delta('好'))),
        _chunk(_sse(_usageOnly(prompt: 10, completion: 5))),
      ]);

      await _collect(_client(http, onUsage: seen.add));

      expect(seen.single.totalTokens, 15);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('重试：吐过字就不能重试', () {
    test('已经吐过字再断线 —— 绝不重试', () async {
      final http = StreamHttp([
        _chunk(_sse(_delta('洛'))),
        const HttpTransportException('连接被掐断'),
      ]);

      final deltas = <String>[];
      Object? err;
      try {
        await for (final e in _client(http).chatStream(_req())) {
          if (e is ChatDelta) deltas.add(e.text);
        }
      } catch (e) {
        err = e;
      }

      expect(http.calls, 1,
          reason: '重试会让回复变成"洛"+"洛必达法则"，'
              '用户完全无法判断哪一遍算数 —— 宁可这次失败，也要把选择权交回用户');
      expect(deltas, ['洛'], reason: '已经吐出去的字收不回来，它们是用户已经看到的');
      expect(err, isA<LlmException>());
    });

    test('一个字都没吐就断了 —— 照常重试（失败发生在建连阶段）', () async {
      final http = StreamHttp.rounds([
        [const HttpTransportException('连接被掐断')],
        [_chunk(_sse(_delta('好')) + _sse('[DONE]'))],
      ]);

      final events = await _collect(_client(http));

      expect(http.calls, 2, reason: '没吐过字，重试与普通请求语义一致');
      expect(events.whereType<ChatDone>().single.response.text, '好');
    });

    test('重试的那一轮不会把上一轮的半截文本带进来', () async {
      final http = StreamHttp.rounds([
        // 第一轮：吐了一个空 delta（等于没吐）然后断线 → 走重试
        [_chunk(_sse(_delta(''))), const HttpTransportException('断了')],
        [_chunk(_sse(_delta('新的')) + _sse('[DONE]'))],
      ]);

      final events = await _collect(_client(http));

      expect(events.whereType<ChatDone>().single.response.text, '新的');
      expect(http.calls, 2);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('HTTP 状态与协议支持', () {
    test('非 2xx：按 body 分类成"Key 无效"', () async {
      final http = StreamHttp([
        HttpStreamChunk(
          statusCode: 401,
          text: jsonEncode({
            'error': {'message': 'Incorrect API key provided'}
          }),
        ),
      ]);

      Object? err;
      try {
        await _collect(_client(http));
      } catch (e) {
        err = e;
      }

      expect(err, isA<LlmException>());
      expect((err! as LlmException).kind, LlmErrorKind.invalidKey);
      expect(http.calls, 1, reason: 'Key 错了重试多少次都一样');
    });

    test('supportsStreaming：OpenAI 兼容为真，另两家为假', () {
      expect(_client(StreamHttp([])).supportsStreaming, isTrue);
      expect(
        _client(StreamHttp([]), provider: 'deepseek').supportsStreaming,
        isTrue,
      );
      // 这两家的 SSE 格式与 OpenAI 完全不同，属于单独一期
      expect(
        _client(StreamHttp([]), provider: 'anthropic').supportsStreaming,
        isFalse,
      );
      expect(
        _client(StreamHttp([]), provider: 'gemini').supportsStreaming,
        isFalse,
      );
    });

    test('不支持流式的服务商：直接说清楚，而不是发一个畸形的请求', () async {
      final http = StreamHttp([]);

      Object? err;
      try {
        await _collect(_client(http, provider: 'anthropic'));
      } catch (e) {
        err = e;
      }

      expect(err, isA<LlmException>());
      expect(http.requests, isEmpty, reason: '报错要发生在发请求之前');
    });

    test('只有已知支持的服务商才带 stream_options', () async {
      // 传了不认识的字段，国产几家会直接 400 ——
      // 那会让对话在那些服务商上**完全不可用**，
      // 比"少记一点用量"严重得多。
      final ds = StreamHttp([_chunk(_sse(_delta('好')))]);
      await _collect(_client(ds, provider: 'deepseek'));
      expect(_bodyOf(ds.requests.single)['stream_options'],
          {'include_usage': true});

      final zp = StreamHttp([_chunk(_sse(_delta('好')))]);
      await _collect(_client(zp, provider: 'zhipu'));
      expect(_bodyOf(zp.requests.single).containsKey('stream_options'), isFalse);
    });
  });
}
