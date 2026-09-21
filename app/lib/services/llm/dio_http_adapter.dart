/// Dio 实现的 [HttpAdapter]。
///
/// 与 [LlmClient] 分离的原因：`llm_client.dart` 不依赖任何网络库，
/// 因此可以在纯 Dart 测试里用一个假适配器完整测试
/// 重试、错误分类、响应解析 —— 不需要网络、不花 token。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import 'llm_client.dart';

/// 基于 Dio 的 HTTP 适配器。
class DioHttpAdapter implements HttpAdapter {
  final Dio _dio;

  DioHttpAdapter({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                // 不在 Dio 层抛异常 —— 我们自己按状态码分类，
                // 让 LlmClient 拿到原始的 statusCode 与 body。
                validateStatus: (_) => true,
                // 不使用 Dio 的 followRedirects 默认行为变化
                followRedirects: true,
              ),
            );

  @override
  Future<HttpResponse> send(HttpRequest request) async {
    try {
      final resp = await _dio.request<String>(
        request.url,
        data: request.body,
        options: Options(
          method: request.method,
          headers: request.headers,
          responseType: ResponseType.plain,
          // ⚠️ `connectTimeout` 必须显式设。
          //
          // `sendTimeout` 管的是"连接建立之后发数据"，**不管建立连接**。
          // 少了它，一个丢包/黑洞的地址只能等操作系统的 TCP 超时 ——
          // Windows 上约 21 秒，而这期间界面什么都不显示。
          // 用户会以为软件卡死了，实际是卡在 TCP 握手。
          connectTimeout: request.timeout,
          sendTimeout: request.timeout,
          receiveTimeout: request.timeout,
        ),
      );

      return HttpResponse(
        statusCode: resp.statusCode ?? 0,
        body: resp.data ?? '',
      );
    } on DioException catch (e) {
      // 把 Dio 的异常类型翻成我们自己的传输层异常，
      // 由 LlmClient 统一分类成 timeout / network。
      throw HttpTransportException(
        _describe(e),
        e,
      );
    } catch (e) {
      throw HttpTransportException('请求失败：$e', e);
    }
  }

  /// 流式发送，返回响应体文本块流。
  ///
  /// ## 两处与 [send] 不同、且都不能照抄的地方
  ///
  /// **一、`receiveTimeout` 必须留空。**
  /// 它管的是"两次数据到达之间"的最大间隔，而不是整个请求的时长。
  /// 推理型模型在思考阶段可能几十秒不吐一个字 —— 沿用 [send] 那个
  /// 120 秒的接收超时，会把**正常的慢回复**判成超时掐断，
  /// 而用户看到的只是"聊到一半没反应了"。
  ///
  /// **二、必须用流式的 UTF-8 解码。**
  /// 一个中文或 emoji 占 3~4 个字节，而 TCP 分块边界几乎必然落在
  /// 字符中间。`utf8.decode(chunk)` 会直接抛 `FormatException`，
  /// 加 `allowMalformed` 则会把半个字符变成 `U+FFFD` ——
  /// 于是回复里冒出"�"。`utf8.decoder` 作为 **StreamTransformer**
  /// 会自己缓冲不完整的字符，这才是唯一正确的用法。
  ///
  /// 块里**不保证**是完整的行（甚至不保证是完整的字符），
  /// 切行由 `LlmClient` 侧的 `SseParser` 负责。
  @override
  Stream<HttpStreamChunk> sendStream(HttpRequest request) async* {
    final Response<ResponseBody> resp;
    try {
      resp = await _dio.request<ResponseBody>(
        request.url,
        data: request.body,
        options: Options(
          method: request.method,
          headers: {
            ...request.headers,
            // 明确声明要 SSE。少数网关按 Accept 决定回不回事件流格式。
            'Accept': 'text/event-stream',
          },
          responseType: ResponseType.stream,
          connectTimeout: request.timeout,
          sendTimeout: request.timeout,
          receiveTimeout: null, // 见方法头注释第一条
        ),
      );
    } on DioException catch (e) {
      throw HttpTransportException(_describe(e), e);
    } catch (e) {
      throw HttpTransportException('请求失败：$e', e);
    }

    final code = resp.statusCode ?? 0;
    final body = resp.data;
    if (body == null) {
      // 没有响应体也要交出一个空块：调用方靠它拿到 statusCode
      // （非 2xx 时就是在这里被识别出来的）。
      yield HttpStreamChunk(statusCode: code, text: '');
      return;
    }

    // ⚠️ `.cast<List<int>>()` 不能省。`Dio` 交出来的是
    // `Stream<Uint8List>`，而 `utf8.decoder` 是一个
    // `StreamTransformer<List<int>, String>` —— `StreamTransformer`
    // 的类型参数出现在 `bind` 的**参数**位置（逆变），
    // 于是 `Stream<Uint8List>` 直接 `.transform(utf8.decoder)` 会编译不过。
    // 先 cast 成 `Stream<List<int>>` 就对齐了。
    final decoded = body.stream.cast<List<int>>().transform(utf8.decoder);
    await for (final text in decoded) {
      yield HttpStreamChunk(statusCode: code, text: text);
    }
  }

  static String _describe(DioException e) {
    return switch (e.type) {
      DioExceptionType.connectionTimeout => '连接超时（timeout）',
      DioExceptionType.sendTimeout => '发送超时（timeout）',
      DioExceptionType.receiveTimeout => '接收超时（timeout）',
      // dio 5.4+ 新增。把它和另外三个超时并列，
      // **不要**用 `_ =>` 兜底 —— 兜底会吞掉未来新增的枚举值，
      // 而漏掉一个超时类型会让 LlmClient 把"超时"误判成"网络错误"（不可重试）。
      DioExceptionType.transformTimeout => '响应转换超时（timeout）',
      DioExceptionType.connectionError =>
        '无法建立连接：${e.message ?? e.error ?? "网络不可达"}',
      DioExceptionType.badCertificate => '证书校验失败',
      DioExceptionType.cancel => '请求已取消',
      DioExceptionType.badResponse =>
        'HTTP ${e.response?.statusCode}：${e.message ?? ""}',
      DioExceptionType.unknown =>
        '未知网络错误：${e.message ?? e.error ?? ""}',
    };
  }

  /// 关闭底层连接池。
  ///
  /// ⚠️ **调用方必须记得调它。** 每次 `buildTagger` / 每次新建适配器都会
  /// 建一个 Dio 实例，而每个实例自带一个连接池；不关的话这些池只能等 GC ——
  /// 在批量导入那种"一次几十次请求"的场景里会一直攒着。
  /// provider 里已经用 `ref.onDispose` 接上了（见 `providers.dart`）。
  void close() => _dio.close(force: true);
}
