/// 平台服务抽象层测试。
///
/// 这一层是**跨平台扩展的地基**，因此必须锁住行为契约：
/// - 密钥掩码绝不泄露完整值
/// - 提醒调度的"每天只提醒一次"逻辑正确
/// - 不支持的能力要**明确抛 UnsupportedError**，而不是静默返回 null
///   （静默失败会让 UI 显示一个点了没反应的按钮，极难排查）
/// - Mock 实现的行为要与真实实现一致，否则开发期与生产的差异会成为 bug 温床
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaoyan_math_agent/core/platform/capabilities.dart';
import 'package:kaoyan_math_agent/core/platform/image_source_windows.dart';
import 'package:kaoyan_math_agent/core/platform/notify_service_windows.dart';
import 'package:kaoyan_math_agent/core/platform/ocr_service_stub.dart';
import 'package:kaoyan_math_agent/core/platform/platform_services.dart';
import 'package:kaoyan_math_agent/core/platform/platform_services_mock.dart';
import 'package:kaoyan_math_agent/core/platform/secure_store_windows.dart';

void main() {
  // ───────────────────────────────────────────────────────────────────────
  group('PlatformServices 注入', () {
    tearDown(PlatformServices.reset);

    test('未安装时访问 instance 抛出可读的错误', () {
      PlatformServices.reset();
      expect(
        () => PlatformServices.instance,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('PlatformServices 尚未初始化'),
          ),
        ),
      );
    });

    test('安装后 isInstalled 为 true 且能取到各服务', () {
      PlatformServices.install(mockPlatformServices());
      expect(PlatformServices.isInstalled, isTrue);
      expect(PlatformServices.instance.ocr, isNotNull);
      expect(PlatformServices.instance.imageSource, isNotNull);
      expect(PlatformServices.instance.secureStore, isNotNull);
      expect(PlatformServices.instance.notify, isNotNull);
    });

    test('重复安装会替换旧实例', () {
      final a = mockPlatformServices();
      PlatformServices.install(a);
      final b = mockPlatformServices();
      PlatformServices.install(b);
      expect(identical(PlatformServices.instance, b), isTrue);
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  group('密钥掩码', () {
    test('保留头 3 位与尾 4 位，中间全掩', () {
      final masked = SecureStoreWindows.maskSecret('sk-abcdefghijklmnop3f2a');
      expect(masked, isNotNull);
      expect(masked, startsWith('sk-'));
      expect(masked, endsWith('3f2a'));
      expect(masked, contains('••••••••'));
      // 关键：中间部分不能泄露
      expect(masked, isNot(contains('defghijklmnop')));
    });

    test('短密钥全部掩掉，不泄露长度以外的信息', () {
      expect(SecureStoreWindows.maskSecret('abc'), '••••••••');
      expect(SecureStoreWindows.maskSecret('12345678'), '••••••••');
    });

    test('null 与空串返回 null', () {
      expect(SecureStoreWindows.maskSecret(null), isNull);
      expect(SecureStoreWindows.maskSecret(''), isNull);
    });

    test('掩码后的字符串长度不精确等于原长（避免被反推）', () {
      final secret = 'sk-${'x' * 40}';
      final masked = SecureStoreWindows.maskSecret(secret)!;
      expect(masked.length, lessThan(secret.length));
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  group('Mock 安全存储', () {
    test('读写删', () async {
      final store = MockSecureStore();
      expect(await store.read('k'), isNull);

      await store.write('k', 'v');
      expect(await store.read('k'), 'v');

      await store.delete('k');
      expect(await store.read('k'), isNull);
    });

    test('deleteAll 清空', () async {
      final store = MockSecureStore();
      await store.write('a', '1');
      await store.write('b', '2');
      await store.deleteAll();
      expect(await store.read('a'), isNull);
      expect(await store.read('b'), isNull);
    });

    test('readMasked 返回掩码而非原值', () async {
      final store = MockSecureStore();
      await store.write('k', 'sk-abcdefghijklmnop3f2a');
      final masked = await store.readMasked('k');
      expect(masked, isNot('sk-abcdefghijklmnop3f2a'));
      expect(masked, contains('••••'));
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  group('不支持的能力必须明确报错', () {
    test('UnavailableOcrService.isAvailable 为 false', () {
      expect(const UnavailableOcrService().isAvailable, isFalse);
    });

    test('调用 OCR 抛 OcrException 且带替代方案提示', () async {
      const ocr = UnavailableOcrService();
      await expectLater(
        ocr.recognizeText(Uint8List.fromList([1, 2, 3])),
        throwsA(
          isA<OcrException>().having(
            (e) => e.message,
            'message',
            allOf(contains('公式键盘'), contains('粘贴')),
          ),
        ),
      );
    });

    test('PC 的 supportsCamera 为 false', () {
      expect(const ImageSourceServiceWindows().supportsCamera, isFalse);
      expect(const ImageSourceServiceWindows().supportsDirectoryPicker, isTrue);
    });

    test('调用拍照抛 UnsupportedError 并给出替代路径', () async {
      const src = ImageSourceServiceWindows();
      await expectLater(
        src.pickFromCamera(),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            contains('选择文件夹'),
          ),
        ),
      );
    });

    test('Mock 的 pickFromCamera 在 camera=false 时也抛 UnsupportedError', () async {
      final src = MockImageSourceService(camera: false);
      await expectLater(src.pickFromCamera(), throwsA(isA<UnsupportedError>()));
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  group('PickedFile 扩展', () {
    test('按扩展名识别图片', () {
      const png = PickedFile(path: r'C:\a\b.png', name: 'b.png');
      const jpg = PickedFile(path: r'C:\a\B.JPG', name: 'B.JPG');
      const pdf = PickedFile(path: r'C:\a\c.pdf', name: 'c.pdf');
      const md = PickedFile(path: r'C:\a\d.md', name: 'd.md');

      expect(png.isImage, isTrue);
      expect(jpg.isImage, isTrue, reason: '扩展名判断应不区分大小写');
      expect(pdf.isImage, isFalse);
      expect(pdf.isPdf, isTrue);
      expect(md.isPdf, isFalse);
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  group('每日提醒调度（应用内）', () {
    test('未到提醒点不提醒', () {
      final s = ReminderScheduler(hour: 20, minute: 0);
      expect(s.shouldNotifyNow(DateTime(2026, 3, 15, 19, 59)), isFalse);
    });

    test('到点提醒', () {
      final s = ReminderScheduler(hour: 20, minute: 0);
      expect(s.shouldNotifyNow(DateTime(2026, 3, 15, 20, 0)), isTrue);
    });

    test('过了提醒点、当天未提醒过 → 提醒', () {
      final s = ReminderScheduler(hour: 20, minute: 0);
      expect(s.shouldNotifyNow(DateTime(2026, 3, 15, 23, 30)), isTrue);
    });

    test('标记后当天不再提醒', () {
      final s = ReminderScheduler(hour: 20, minute: 0);
      final now = DateTime(2026, 3, 15, 20, 0);
      expect(s.shouldNotifyNow(now), isTrue);
      s.markNotified(now);
      expect(s.shouldNotifyNow(DateTime(2026, 3, 15, 21, 0)), isFalse);
    });

    test('跨天后重新可以提醒', () {
      final s = ReminderScheduler(hour: 20, minute: 0);
      s.markNotified(DateTime(2026, 3, 15, 20, 0));
      expect(s.shouldNotifyNow(DateTime(2026, 3, 16, 20, 0)), isTrue);
    });

    test('hour 为 null 表示关闭提醒', () {
      final s = ReminderScheduler(hour: null, minute: null);
      expect(s.enabled, isFalse);
      expect(s.shouldNotifyNow(DateTime(2026, 3, 15, 23, 59)), isFalse);
    });

    test('状态可序列化与恢复', () {
      final s = ReminderScheduler(hour: 21, minute: 30);
      s.markNotified(DateTime(2026, 3, 15, 21, 30));

      final restored = ReminderScheduler()
        ..restoreFromJson(s.toJson());

      expect(restored.hour, 21);
      expect(restored.minute, 30);
      // 已提醒状态也要恢复，否则重启后会重复提醒
      expect(restored.shouldNotifyNow(DateTime(2026, 3, 15, 22, 0)), isFalse);
      expect(restored.shouldNotifyNow(DateTime(2026, 3, 16, 22, 0)), isTrue);
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  group('Windows 通知的降级行为', () {
    test('未初始化时 isAvailable 为 false，show 不抛异常', () async {
      final n = NotifyServiceWindows();
      expect(n.isAvailable, isFalse);

      // 未初始化就发通知：应静默跳过而不是崩
      await expectLater(
        n.show(title: 't', body: 'b'),
        completes,
      );
    });

    test('scheduleDailyReminder 是空操作（Windows 不支持平台级重复提醒）', () async {
      final n = NotifyServiceWindows();
      await expectLater(
        n.scheduleDailyReminder(hour: 20, minute: 0, dueCount: 5),
        completes,
      );
    });

    test('cancelAll 在不可用时也不抛异常', () async {
      final n = NotifyServiceWindows();
      await expectLater(n.cancelAll(), completes);
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  group('平台能力探测', () {
    test('各标志互斥且自洽', () {
      // 桌面与移动不应同时为真
      expect(
        PlatformCapabilities.isDesktopOS && PlatformCapabilities.isMobileOS,
        isFalse,
      );
      // Windows 测试环境下应识别为桌面
      if (PlatformCapabilities.isWindows) {
        expect(PlatformCapabilities.isDesktopOS, isTrue);
        expect(PlatformCapabilities.usesDesktopInteractions, isTrue);
        expect(PlatformCapabilities.supportsDirectoryPicker, isTrue);
        // PC 无拍照录入场景
        expect(PlatformCapabilities.hasCamera, isFalse);
      }
    });

    test('name 返回可读字符串', () {
      expect(PlatformCapabilities.name, isNotEmpty);
      expect(PlatformCapabilities.name, isNot('unknown'));
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  group('Mock 通知服务可断言', () {
    test('记录已发送的通知，便于测试 UI 反馈', () async {
      final n = MockNotifyService();
      await n.show(title: '标注完成', body: '3 道题已打标');
      expect(n.sent.length, 1);
      expect(n.sent.first.title, '标注完成');
    });

    test('权限状态可配置', () async {
      expect(await MockNotifyService().requestPermission(), isTrue);
      expect(
        await MockNotifyService(permissionGranted: false).requestPermission(),
        isFalse,
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  group('Mock OCR 结果结构', () {
    test('默认返回两个文本块与整体置信度', () async {
      final ocr = MockOcrService();
      expect(ocr.isAvailable, isTrue);

      final r = await ocr.recognizeText(Uint8List(0));
      expect(r.blocks.length, 2);
      expect(r.engine, 'mock');
      expect(r.overallConfidence, greaterThan(0));
      expect(r.plainText, contains('f(x)'));
    });

    test('可配置为抛出指定异常', () async {
      final ocr = MockOcrService(throwOnRecognize: const OcrException('模拟失败'));
      await expectLater(
        ocr.recognizeText(Uint8List(0)),
        throwsA(isA<OcrException>()),
      );
    });

    test('OcrBlock 归一化坐标可读', () async {
      final r = await MockOcrService().recognizeText(Uint8List(0));
      final b = r.blocks.first;
      expect(b.left, 0.05);
      expect(b.top, 0.05);
      expect(b.right, 0.95);
      expect(b.bottom, 0.35);
    });
  });
}
