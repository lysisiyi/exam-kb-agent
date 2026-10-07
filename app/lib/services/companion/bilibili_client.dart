/// B站字幕轨（P4）：把网课的 CC 字幕变成课时笔记。
///
/// ## 与截图轨的分工
///
/// 截图轨是"通用兜底"（任何播放器都能记，但受识别质量与 5 分钟粒度限制）；
/// 字幕轨是"精确轨道"：BV 号 → 分P(cid) → CC 字幕 → 按窗口总结成
/// 带**真实时间戳**的笔记。有 CC 字幕的课可以完全不开截图。
///
/// ## 登录态
///
/// 多数视频的字幕需要登录才能取。用**用户自己的 SESSDATA**
/// （存 `meta_entries.bilibili_sessdata`，仅本机、只在本机请求里当 Cookie 用）。
///
/// ## 版权纪律
///
/// 拉取的是**用户自己有权访问**的视频的字幕接口，产物只落在用户本地的
/// 课时 md 里 —— 不聚集、不分享、不内置任何题库内容。
///
/// ## 网络与解析分离
///
/// 解析全是纯函数（测试全覆盖）；网络层可注入（[BiliHttp]），
/// 真机用 Dio，测试不碰网。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

/// 一条字幕。
class SubtitleLine {
  /// 起始秒。
  final double from;
  final double to;
  final String content;

  const SubtitleLine(
      {required this.from, required this.to, required this.content});

  /// mm:ss（或 h:mm:ss）——note 里展示用。
  String get timeLabel => formatSeconds(from);
}

/// 一个分P（B站"选集"里的一集）。
class BiliPage {
  final int page;
  final int cid;
  final String part;

  const BiliPage({required this.page, required this.cid, required this.part});
}

/// 从各种输入形态里提取 BV 号：
/// 完整链接（可能带 ?p=3、?t=12 等）、裸 BV 号、分享文案（"【标题】 … https://…"）。
/// 提取不出返回 null。
String? extractBvid(String input) {
  final m = RegExp(r'BV[0-9A-Za-z]{10}').firstMatch(input);
  return m?.group(0);
}

/// 从链接里提取分P（`?p=3`），没有返回 null。
int? extractPageNumber(String input) {
  final m = RegExp(r'[?&]p=(\d+)').firstMatch(input);
  return m == null ? null : int.tryParse(m.group(1)!);
}

/// 秒 → mm:ss / h:mm:ss。
String formatSeconds(double seconds) {
  final total = seconds.floor();
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

/// 解析 view 接口的 pages（分P 列表）。损坏数据返回空表。
List<BiliPage> parsePages(String viewJson) {
  try {
    final data = (jsonDecode(viewJson) as Map)['data'] as Map?;
    final pages = (data?['pages'] as List?) ?? const [];
    return [
      for (final p in pages)
        if (p is Map)
          BiliPage(
            page: (p['page'] as num?)?.toInt() ?? 0,
            cid: (p['cid'] as num?)?.toInt() ?? 0,
            part: p['part']?.toString() ?? '',
          ),
    ];
  } catch (_) {
    return const [];
  }
}

/// view 接口里的视频标题（拼接失败返回空串）。
String parseViewTitle(String viewJson) {
  try {
    final data = (jsonDecode(viewJson) as Map)['data'] as Map?;
    return data?['title']?.toString() ?? '';
  } catch (_) {
    return '';
  }
}

/// 解析 player/v2 的字幕清单 → [(语言, 绝对 URL)]。
///
/// `subtitle_url` 是协议相对地址（`//aisubtitle…`），补齐 https ——
/// 直接拿去请求会因无协议被 Dio 拒绝。
List<({String lan, String url})> parseSubtitleList(String playerJson) {
  try {
    final data = (jsonDecode(playerJson) as Map)['data'] as Map?;
    final subs = ((data?['subtitle'] as Map?)?['subtitles'] as List?) ??
        const [];
    final out = <({String lan, String url})>[];
    for (final s in subs) {
      if (s is! Map) continue;
      final url = s['subtitle_url']?.toString() ?? '';
      if (url.isEmpty) continue;
      out.add((
        lan: s['lan']?.toString() ?? 'unknown',
        url: url.startsWith('//') ? 'https:$url' : url,
      ));
    }
    return out;
  } catch (_) {
    return const [];
  }
}

/// 解析字幕正文 JSON（`{"body":[{"from":0.0,"to":3.5,"content":"…"}]}`）。
List<SubtitleLine> parseSubtitleBody(String bodyJson) {
  try {
    final root = jsonDecode(bodyJson);
    final body = (root is Map ? root['body'] : root) as List? ?? const [];
    final out = <SubtitleLine>[];
    for (final l in body) {
      if (l is! Map) continue;
      final content = l['content']?.toString().trim() ?? '';
      if (content.isEmpty) continue;
      out.add(SubtitleLine(
        from: (l['from'] as num?)?.toDouble() ?? 0,
        to: (l['to'] as num?)?.toDouble() ?? 0,
        content: content,
      ));
    }
    return out;
  } catch (_) {
    return const [];
  }
}

/// 把字幕按 [windowSec] 秒切成窗口（各窗口是一段 [SubtitleLine]）。
///
/// 边界按**行起始时间**归属：一行跨窗口时归给它的起点所在窗口——
/// 字幕行都很短（几秒），这种近似不产生可感知的时间轴误差。
List<List<SubtitleLine>> sliceWindows(List<SubtitleLine> lines,
    {int windowSec = 300}) {
  final out = <List<SubtitleLine>>[];
  var current = <SubtitleLine>[];
  var windowStart = lines.isEmpty ? 0.0 : lines.first.from;
  for (final l in lines) {
    if (l.from - windowStart >= windowSec && current.isNotEmpty) {
      out.add(current);
      current = <SubtitleLine>[];
      windowStart = l.from;
    }
    current.add(l);
  }
  if (current.isNotEmpty) out.add(current);
  return out;
}

/// 一个窗口 → 送给文本模型的原文（带真实时间戳前缀，便于模型给 note 填时间）。
String windowToPromptText(List<SubtitleLine> window) => [
      for (final l in window) '[${l.timeLabel}] ${l.content}',
    ].join('\n');

/// 网络接口（可注入；测试不碰网）。
abstract interface class BiliHttp {
  /// GET 文本。带 [sessdata] 时以 Cookie 形式附带。
  Future<String> getText(String url, {String? sessdata});
}

/// 真机实现：Dio + 浏览器 UA。
class DioBiliHttp implements BiliHttp {
  final Dio _dio;
  DioBiliHttp()
      : _dio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 12),
          receiveTimeout: const Duration(seconds: 20),
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            'Referer': 'https://www.bilibili.com/',
          },
        ));

  @override
  Future<String> getText(String url, {String? sessdata}) async {
    final resp = await _dio.get<String>(
      url,
      options: Options(
        responseType: ResponseType.plain,
        headers: sessdata == null || sessdata.isEmpty
            ? null
            : {'Cookie': 'SESSDATA=$sessdata'},
      ),
    );
    return resp.data ?? '';
  }

  void close() => _dio.close(force: true);
}

/// 字幕轨客户端：BV → 分P → 字幕清单 → 字幕行。
class BiliSubtitleClient {
  final BiliHttp http;
  final String? sessdata;

  BiliSubtitleClient(this.http, {this.sessdata});

  Future<List<BiliPage>> pages(String bvid) async {
    final json = await http.getText(
        'https://api.bilibili.com/x/web-interface/view?bvid=$bvid',
        sessdata: sessdata);
    return parsePages(json);
  }

  Future<String> title(String bvid) async {
    final json = await http.getText(
        'https://api.bilibili.com/x/web-interface/view?bvid=$bvid',
        sessdata: sessdata);
    return parseViewTitle(json);
  }

  /// 该分P 可用字幕列表（可能为空：没字幕或未登录）。
  Future<List<({String lan, String url})>> subtitleList(
      String bvid, int cid) async {
    final json = await http.getText(
        'https://api.bilibili.com/x/player/v2?bvid=$bvid&cid=$cid',
        sessdata: sessdata);
    return parseSubtitleList(json);
  }

  Future<List<SubtitleLine>> subtitleLines(String subtitleUrl) async {
    final body = await http.getText(subtitleUrl, sessdata: sessdata);
    return parseSubtitleBody(body);
  }
}
