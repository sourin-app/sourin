import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/clip_download.dart';
import 'package:sourin_spike/core/ui_prefs.dart';

/// N14 缓存窗口门禁：前向预读必须**同时**有字节上界与时间上界
///
/// # 为什么需要这条门禁
///
/// 用户原话：
/// > 缓存提前拉取播放那个缓存，不要一直把所有的都缓存完，
/// > 只缓存播放 + 一个时间段，五分钟或者十分钟
/// >（不要提前一次性把所有的都拉取完 这是错误的）
///
/// 改前的缺陷：`mpvCacheProperties()` 只下发 `demuxer-max-bytes` /
/// `demuxer-max-back-bytes` / `cache-dir`，**没有** `cache-secs`。
/// 于是 mpv 用的是它自己的默认 `cache-secs = 3600000`（≈1000 小时，等于不限），
/// 唯一的闸门就只剩字节数 ⇒ 只要没读满 256MB 就一直往后读。
///
/// 实测读数（工程实际会跑的 libmpv-2.dll，2Mbps / 60 分钟片，字节上限 256MB）：
/// ```text
/// 无 cache-secs ⇒ 前向窗口 938 s，起播拉 240 MB   ← 用户抱怨的行为
/// cache-secs=600 ⇒ 前向窗口 622 s，起播拉 164 MB  （-34% / -32%）
/// cache-secs=300 ⇒ 前向窗口 322 s，起播拉  89 MB  （-66% / -63%）
/// ```
///
/// # 为什么字节上界**不能**动
///
/// 用户原话：「缓存不用下降，有些视频是 4k，这个默认还是 256」。
/// 4K 高码率下回看 10 分钟需要 1.5~3GB ⇒ 256MB 对 4K 回看不是浪费，是必要。
/// ⇒ 下面有一条专门钉住「前向与回看字节数**必须相等**」，
///   防止有人（包括曾经的我自己）把回看单独调小。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    UiPrefs.debugResetForTest();
  });

  tearDown(() {
    UiPrefs.debugResetForTest();
  });

  List<(String, String)> props() =>
      ClipDownloader.mpvCacheProperties(r'C:\tmp\mpv-cache');

  String? valueOf(String key) {
    for (final p in props()) {
      if (p.$1 == key) return p.$2;
    }
    return null;
  }

  group('N14 缓存窗口', () {
    test('★★★ 必须下发 cache-secs（改前完全没有这个属性）', () {
      final keys = props().map((p) => p.$1).toList();
      expect(
        keys,
        contains(ClipDownloader.kMpvCacheSecsKey),
        reason: '★ 缺 cache-secs ⇒ mpv 用它自己的默认值 3600000 秒（等于不限）'
            '⇒ 只剩字节闸门 ⇒ 会一直往后读到 256MB 才停，'
            '这正是用户说的「一次性把所有的都拉取完」',
      );
    });

    test('★★★ cache-secs 的值 = 600（10 分钟，用户给的取舍范围）', () {
      expect(valueOf(ClipDownloader.kMpvCacheSecsKey), '600');
    });

    test('★★★ 字节上界保持 256MB（用户明确要求「不用下降」）', () {
      // 默认配置下 = defaultCacheLimitMb
      expect(ClipDownloader.cacheLimitMb, ClipDownloader.defaultCacheLimitMb);
      expect(ClipDownloader.defaultCacheLimitMb, 256,
          reason: '★ 用户原话：「缓存不用下降，有些视频是 4k，这个默认还是 256」');
      expect(
        valueOf(ClipDownloader.kMpvMaxBytesKey),
        (256 * 1024 * 1024).toString(),
      );
    });

    test('★★★ 前向与回看的字节上界**必须相等**', () {
      /*
       * ★ 这条是专门防「把回看单独调小」的。
       *
       * 我曾经建议把 demuxer-max-back-bytes 降到 64MB，理由是
       * 「8Mbps 合成片实测 32MB 就够」。用户否了这个建议，理由是
       * 「有些视频是 4k」—— 4K 20~40Mbps 下回看 10 分钟要 1.5~3GB。
       *
       * ⇒ 实测数据不能替代真实使用场景。这条门禁把结论钉住。
       */
      expect(
        valueOf(ClipDownloader.kMpvMaxBackBytesKey),
        valueOf(ClipDownloader.kMpvMaxBytesKey),
        reason: '★ 回看缓存必须与预读缓存同宽：4K 高码率下回看 10 分钟需要 1.5~3GB，'
            '把回看单独调小会让「拖回刚看过的地方」重新缓冲',
      );
    });

    test('★★ 用户调大/调小缓存上限时，时间窗不跟着变（两个上界独立）', () {
      // 两个上界各司其职：字节管"占多少"，秒数管"往后多久"
      for (final mb in ClipDownloader.cacheLimitOptions) {
        ClipDownloader.setCacheLimitMb(mb);
        final p = props();
        String? v(String k) {
          for (final e in p) {
            if (e.$1 == k) return e.$2;
          }
          return null;
        }

        expect(v(ClipDownloader.kMpvMaxBytesKey), (mb * 1024 * 1024).toString(),
            reason: '★ 上限 $mb MB 必须如实下发到 demuxer-max-bytes');
        expect(v(ClipDownloader.kMpvMaxBackBytesKey),
            (mb * 1024 * 1024).toString(),
            reason: '★ 回看必须跟着上限走，不能是固定值');
        expect(v(ClipDownloader.kMpvCacheSecsKey), '600',
            reason: '★ 时间窗是独立常量，不随字节上限变化');
      }
    });

    test('★ 属性表里每个 key 只出现一次（防止重复下发）', () {
      final keys = props().map((p) => p.$1).toList();
      expect(keys.toSet().length, keys.length);
    });

    test('★ 缓存目录仍然下发（不能因为加属性把它挤掉）', () {
      expect(valueOf(ClipDownloader.kMpvCacheDirKey), r'C:\tmp\mpv-cache');
    });
  });
}
