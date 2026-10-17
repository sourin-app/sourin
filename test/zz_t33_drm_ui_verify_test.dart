// ═══════════════════════════════════════════════════════════════════════
//  task-33 验证：DRM 流上 UI 到底显示什么（Lead 指定「不需要外部样本」）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么能不用外部样本验
// ```text
// DRM 判定完全发生在**本地数据**上：StreamCandidate.drmProtected + isPlayable。
// 只要能构造出「全部候选都 drmProtected」的列表，就能验 UI 分支。
// ⇒ 不需要真去播一个 DRM 流。
// ```
//
// # 本测试验的三件事
// ```text
// ① 全 DRM 列表 ⇒ 错误文案是「所有线路都不可播（可能受 DRM 保护）」
//    （不是「解析失败」/「网络错误」这种误导文案）
// ② 线路面板里 DRM 行**不可点**（enabled=false / onTap=null）
// ③ 线路面板里 DRM 行有「受 DRM 保护，暂不支持」副标题
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models.dart';

void main() {
  group('① isPlayable 判据（DRM 的唯一闸门）', () {
    test('drmProtected=true ⇒ 不可播，即使 url 非空', () {
      const c = StreamCandidate(url: 'https://x/a.m3u8', drmProtected: true);
      expect(c.isPlayable, isFalse,
          reason: 'DRM 流必须被 isPlayable 拦下，否则会静默播成黑屏/绿屏');
    });

    test('url 为空 ⇒ 不可播', () {
      const c = StreamCandidate(url: '');
      expect(c.isPlayable, isFalse);
    });

    test('正常流 ⇒ 可播', () {
      const c = StreamCandidate(url: 'https://x/a.m3u8');
      expect(c.isPlayable, isTrue);
    });

    test('★ 默认值必须是 false（老插件不传 drmProtected 时行为不变）', () {
      const c = StreamCandidate(url: 'https://x/a.m3u8');
      expect(c.drmProtected, isFalse,
          reason: '默认 true 会让所有老插件瞬间全部不可播');
    });
  });

  group('② 全 DRM 时播放页的错误文案', () {
    test('★ 文案必须是「所有线路都不可播（可能受 DRM 保护）」', () {
      final src = File('lib/ui/player_page.dart').readAsStringSync();

      expect(src.contains('所有线路都不可播（可能受 DRM 保护）'), isTrue,
          reason: '点播的全 DRM 分支必须给出 DRM 相关文案');
      expect(src.contains('该内容没有可播放的地址'), isTrue,
          reason: '列表为空是另一回事，文案必须分开');
    });

    test('★ 不许把 DRM 说成「解析失败」或「网络错误」', () {
      final src = File('lib/ui/player_page.dart').readAsStringSync();
      // 找 DRM 分支前后，确认没有误导性措辞挂在同一条赋值上
      final idx = src.indexOf('所有线路都不可播（可能受 DRM 保护）');
      expect(idx, greaterThan(0));
      final lineStart = src.lastIndexOf('\n', idx) + 1;
      final lineEnd = src.indexOf('\n', idx);
      final line = src.substring(lineStart, lineEnd);

      expect(line.contains('解析失败'), isFalse,
          reason: 'DRM 不是解析失败 —— 说成解析失败会让用户以为重试有用');
      expect(line.contains('网络'), isFalse,
          reason: 'DRM 不是网络问题 —— 说成网络错误会让用户去查网络');
    });

    test('③ 直播与点播两条通道都有 DRM 文案（不能只修一条）', () {
      final src = File('lib/ui/player_page.dart').readAsStringSync();
      final n = '所有线路都不可播（可能受 DRM 保护）'
          .allMatches(src)
          .length;
      expect(n, greaterThanOrEqualTo(2),
          reason: '点播(_load) 与直播(_loadLive) 是两条独立代码路径，'
              '只改一条会留下另一个「静默黑屏」的口子。实测应为 2 处。');
    });
  });

  group('④ 线路面板里的 DRM 行', () {
    late String src;
    setUpAll(() => src = File('lib/ui/player_page.dart').readAsStringSync());

    test('★ DRM 行必须有「受 DRM 保护，暂不支持」副标题', () {
      expect(src.contains('受 DRM 保护，暂不支持'), isTrue,
          reason: '线路面板要让用户看见为什么这条线路点不动');
    });

    test('★ DRM 行必须不可点（enabled: s.isPlayable）', () {
      final idx = src.indexOf('受 DRM 保护，暂不支持');
      expect(idx, greaterThan(0));
      // 往前找这个 ListTile 的 enabled / onTap
      /*
       * ⚠️ 窗口必须**跨两侧**：同一个 ListTile 里
       *   `enabled:` 在副标题**之前**，`onTap:` 在副标题**之后**
       * （实测布局 19175 / 19209 / 19215）。
       * 我第一次只往前取 2000 字符 ⇒ onTap 落在窗口外 ⇒ 假红。
       */
      final window = src.substring(
        (idx - 2000).clamp(0, src.length),
        (idx + 800).clamp(0, src.length),
      );
      expect(window.contains('enabled: s.isPlayable'), isTrue,
          reason: 'DRM 行必须 enabled=false，否则用户点了必然黑屏');
      expect(window.contains('onTap: s.isPlayable ?'), isTrue,
          reason: 'DRM 行必须 onTap=null');
    });
  });

  group('⑤ 已知缺口（本测试记录，不是断言它该这样）', () {
    test('⚠️ 全仓没有任何自动 DRM 探测 —— drmProtected 只能靠插件填', () {
      /*
       * 这条**不是**「应该如此」，而是把现状钉住，防止有人以为有自动探测。
       * 实测：grep -rn '\\.drm()' rust/ 在生产代码里 0 处。
       *
       * ⇒ 后果：若插件不填 drmProtected，DRM 流会**绕过 isPlayable**，
       *   直接被交给 mpv ⇒ 用户看到黑屏/绿屏，且**没有任何提示**。
       *   这正是本仓 model.rs:405-421 那段注释描述的故障形态。
       */
      final rs = Directory('rust/sourin_core/src')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.rs'))
          .map((f) => f.readAsStringSync())
          .join('\n');

      final builderCalls = RegExp(r'\.drm\(\)').allMatches(rs).length;
      expect(builderCalls, 0,
          reason: '若哪天有人加了自动探测，这条会红 —— '
              '那就该把上面那段注释一起更新（说明探测在哪层做）。');
    });
  });
}
