// ═══════════════════════════════════════════════════════════════════════
//  N12 门禁：登录轮询失败的文案必须**与真因一致**
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话
// > 我刚刚测试某个视频站的插件无法登陆，提示网络异常 这也是bug
//
// # 缺陷（改前）
// ```dart
// } catch (_) {                                   // catch-all 吞掉一切
//   if (mounted) setState(() => _qrMsg = '网络异常，重试中…');
// }
// ```
//
// # 实测证明「网络异常」当时是**猜的**（轨道 H 第 4 步）
// ```text
// qr_login_start   ✓ 440ms 真申请成功
// qr_login_poll    ✓ 42ms  status=Expired（正常返回，不抛）
// 连打 3 次         ✓ 59/86/85ms 全 Pending，一次没抛
// ⇒ 网络一直是好的。
// ```
//
// # 这组断言的核心价值（Lead 特别要求）
// ```text
// ★ 反例才是关键：注入「核心尚未启动」⇒ 必须**不显示**「网络异常」。
//   只断言"网络异常时显示网络异常"是不够的 —— 那个实现（catch-all）
//   在改前**也**能满足，门禁会假绿。
// ```

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/ffi.dart' show SourinCoreException;
import 'package:sourin_spike/core/sourin_api.dart';

void main() {
  group('① 真的网络问题 ⇒ 保留「网络异常」（原文案此时是对的）', () {
    test('SocketException', () {
      final e = const SocketException('Failed host lookup: example.com');
      expect(QrPollErrorText.of(e), '网络异常，重试中…');
    });

    test('TimeoutException', () {
      expect(
        QrPollErrorText.of(TimeoutException('poll timeout')),
        '网络异常，重试中…',
      );
    });

    test('结构化 kind=network（核心侧判定的，比猜字符串可靠）', () {
      final e = SourinCoreException('某件事没成', 'network');
      expect(QrPollErrorText.of(e), '网络异常，重试中…',
          reason: '★ kind 是结构化的，优先于文案关键词');
    });

    test('插件抛的 network: 前缀', () {
      expect(
        QrPollErrorText.of(Exception('network: 请求失败: connection closed')),
        '网络异常，重试中…',
      );
    });
  });

  group('★★ ② 反例：核心未就绪**不许**说「网络异常」', () {
    test('核心尚未启动', () {
      final msg = QrPollErrorText.of(Exception('核心尚未启动'));
      expect(msg.contains('网络异常'), isFalse,
          reason: '★★ 这跟网络毫无关系 —— 说「网络异常」会让用户去查网线');
      expect(msg.contains('核心'), isTrue,
          reason: '★ 要如实说"核心"');
    });

    test('dll 没绑上（实测形态：Failed to load dynamic library）', () {
      final msg = QrPollErrorText.of(Exception(
        "Invalid argument(s): Failed to load dynamic library "
        "'sourin_core.dll': The specified module could not be found.",
      ));
      expect(msg.contains('网络异常'), isFalse,
          reason: '★★ 加载不到 dll 不是网络问题');
    });

    test('UnsupportedError（不支持的平台）', () {
      final msg = QrPollErrorText.of(UnsupportedError('不支持的平台: windows'));
      expect(msg.contains('网络异常'), isFalse,
          reason: '★★ 平台不支持与网络无关');
    });

    test('未绑定', () {
      final msg = QrPollErrorText.of(Exception('核心不可用：未绑定'));
      expect(msg.contains('网络异常'), isFalse);
    });
  });

  group('③ 其他异常 ⇒ 透传真因（不许吞掉）', () {
    test('未知异常要带出原文', () {
      final msg = QrPollErrorText.of(Exception('某个谁也没见过的错误 xyz'));
      expect(msg.contains('xyz'), isTrue,
          reason: '★ 真因必须可见 —— 吞掉它就没法排查');
      expect(msg.contains('网络异常'), isFalse,
          reason: '★ 不许把未知错误说成网络问题');
    });

    test('宿主包装前缀要被剥掉（Owner 第 7 条）', () {
      final msg = QrPollErrorText.of(
        Exception('SourinCoreException(other): 插件报错: 某个真因'),
      );
      expect(msg.contains('SourinCoreException'), isFalse,
          reason: '★ 第 7 条：只留原文');
      expect(msg.contains('插件报错'), isFalse);
      expect(msg.contains('某个真因'), isTrue);
    });

    test('内部地址不许出现（Owner 第 6 条）', () {
      final msg = QrPollErrorText.of(
        Exception('Failed to open http://127.0.0.1:1234/s/abc/'),
      );
      expect(msg.contains('127.0.0.1'), isFalse,
          reason: '★ 第 6 条：内部代理地址不上屏');
    });

    test('空异常也要给一句话（不许空白）', () {
      expect(QrPollErrorText.of(null).trim().isNotEmpty, isTrue);
      expect(QrPollErrorText.of('').trim().isNotEmpty, isTrue);
    });
  });

  group('④ 文案纪律', () {
    test('四种产出的文案都不许带宿主类名 / 内部地址', () {
      final inputs = <Object?>[
        const SocketException('x'),
        Exception('核心尚未启动'),
        Exception('随便什么'),
        null,
      ];
      for (final e in inputs) {
        final msg = QrPollErrorText.of(e);
        expect(msg.contains('SourinCoreException'), isFalse, reason: '$e');
        expect(msg.contains('127.0.0.1'), isFalse, reason: '$e');
        expect(msg.contains('插件报错'), isFalse, reason: '$e');
      }
    });
  });
}
