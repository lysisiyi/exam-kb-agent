/// Dio 实现的 [HttpAdapter]。
///
/// 与 [LlmClient] 分离的原因：`llm_client.dart` 不依赖任何网络库，
/// 因此可以在纯 Dart 测试里用一个假适配器完整测试
/// 重试、错误分类、响应解析 —— 不需要网络、不花 token。
library;

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

  void close() => _dio.close(force: true);
}
