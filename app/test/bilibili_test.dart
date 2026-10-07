/// B站字幕轨（P4）的纯函数测试：BV 提取、分P 解析、字幕清单/正文解析、
/// 分窗切片、提示词文本。网络层可注入，测试不碰网。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/services/companion/bilibili_client.dart';

void main() {
  group('extractBvid / extractPageNumber', () {
    test('各种输入形态都能提出 BV 号', () {
      const bv = 'BV1GJ411x7h7';
      expect(extractBvid('https://www.bilibili.com/video/$bv/?p=3&t=12'), bv);
      expect(extractBvid(bv), bv);
      expect(extractBvid('【线性代数】第5讲 $bv 分享自哔哩哔哩'), bv);
      expect(extractBvid('没有 BV 号的文本'), isNull);
      expect(extractBvid('BV123'), isNull, reason: '长度不够不算');
    });

    test('分P 参数', () {
      expect(extractPageNumber('https://b23.tv/x?p=3'), 3);
      expect(extractPageNumber('https://x/video?foo=1&p=12'), 12);
      expect(extractPageNumber('https://x/video'), isNull);
    });
  });

  test('formatSeconds：mm:ss 与 h:mm:ss', () {
    expect(formatSeconds(0), '00:00');
    expect(formatSeconds(65.9), '01:05');
    expect(formatSeconds(754), '12:34');
    expect(formatSeconds(3661), '1:01:01');
  });

  group('解析（损坏数据全部退化，不抛）', () {
    test('parsePages / parseViewTitle', () {
      const view = '''
{"code":0,"data":{"title":"线性代数基础班","pages":[
 {"page":1,"cid":101,"part":"第1讲 行列式"},
 {"page":2,"cid":102,"part":"第2讲 矩阵"}]}}''';
      final pages = parsePages(view);
      expect(pages.length, 2);
      expect(pages[1].cid, 102);
      expect(pages[1].part, '第2讲 矩阵');
      expect(parseViewTitle(view), '线性代数基础班');

      expect(parsePages('不是 json'), isEmpty);
      expect(parseViewTitle('{"code":-404}'), '');
    });

    test('parseSubtitleList：协议相对 URL 补 https；缺字段跳过', () {
      const player = '''
{"data":{"subtitle":{"subtitles":[
 {"lan":"zh-CN","subtitle_url":"//aisubtitle.hdslb.com/bfs/ai_subtitle/x.json"},
 {"lan":"ai-zh","subtitle_url":"https://aisubtitle.hdslb.com/y.json"},
 {"lan":"en-US"}]}}}''';
      final subs = parseSubtitleList(player);
      expect(subs.length, 2);
      expect(subs[0].url, startsWith('https://aisubtitle.hdslb.com'));
      expect(subs[1].lan, 'ai-zh');
      expect(parseSubtitleList('{}'), isEmpty);
    });

    test('parseSubtitleBody：body 数组；空内容行丢弃；坏 JSON 为空', () {
      const body = '''
{"body":[
 {"from":0.0,"to":3.5,"content":"大家好"},
 {"from":3.5,"to":6.0,"content":"  "},
 {"from":6.0,"to":9.0,"content":"今天讲特征值"}]}''';
      final lines = parseSubtitleBody(body);
      expect(lines.length, 2);
      expect(lines[1].content, '今天讲特征值');
      expect(lines[1].timeLabel, '00:06');
      expect(parseSubtitleBody('{bad'), isEmpty);
    });
  });

  group('分窗切片', () {
    List<SubtitleLine> linesWithTimes(List<double> froms) => [
          for (final f in froms)
            SubtitleLine(from: f, to: f + 2, content: 't$f'),
        ];

    test('按窗口秒数切；空输入为空', () {
      final lines = linesWithTimes([0, 60, 120, 299, 301, 420, 601]);
      final windows = sliceWindows(lines, windowSec: 300);
      expect(windows.length, 3);
      expect(windows[0].length, 4, reason: '0..299 同窗');
      expect(windows[1].first.from, 301);
      expect(windows[2].first.from, 601);
      expect(sliceWindows(const []), isEmpty);
    });

    test('单窗口：全部行留在同一段', () {
      final windows = sliceWindows(linesWithTimes([10, 20, 30]));
      expect(windows.length, 1);
      expect(windows.single.length, 3);
    });
  });

  test('windowToPromptText：每行带真实时间戳前缀', () {
    final text = windowToPromptText(const [
      SubtitleLine(from: 754, to: 758, content: '先写定义式'),
      SubtitleLine(from: 758, to: 762, content: '再变形'),
    ]);
    expect(text, '[12:34] 先写定义式\n[12:38] 再变形');
  });
}
