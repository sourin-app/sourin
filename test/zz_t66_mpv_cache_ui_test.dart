// ★★★ 2026-10-18（N14 取证结论）：设置页「播放器缓存」不许再显示"0 B"误导用户
//
// # 背景（实测，不是推测）
// ```text
// <dataDir>/mpv-cache 目录**始终是空的**
//   · 轨道 B 的探针：0 字节
//   · 用户真实目录 %APPDATA%\app.sourin.player\mpv-cache：也是空的
// 原因：mpv 对**可 seek 的 HTTP Range 源不落盘**，只在内存里缓存。
// ```
//
// ⇒ 旧文案「播放器缓存 0 B · mpv-cache」会让用户以为：
// ```text
// ① 「我的缓存没生效」→ 去点「清空播放器缓存」，清了 0 个文件
// ② 「为什么别人的播放器缓存占几个 G，我的是 0」→ 怀疑软件坏了
// ```
// 都是假问题，但用户无法知道。
//
// # 本门禁守什么
// ```text
// ① 值为 0 时**不许**出现 "0 B" 这种字面读数
//    必须说明"不占磁盘（网络流在内存里缓存）"
// ② 值 > 0 时仍要正常显示字节数（不能为了修 0 而把有值的场景也改坏）
// ③ 标签必须说清是"临时"缓存，与"片段缓存"（成品）区分
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 剥掉 Dart 注释（行 + 块），避免断言命中注释里的示例文本
String stripComments(String s) {
  var out = StringBuffer();
  var i = 0;
  while (i < s.length) {
    if (s.startsWith('//', i)) {
      while (i < s.length && s[i] != '\n') {
        i++;
      }
    } else if (s.startsWith('/*', i)) {
      i += 2;
      while (i < s.length && !s.startsWith('*/', i)) {
        i++;
      }
      i += 2;
    } else {
      out.write(s[i]);
      i++;
    }
  }
  return out.toString();
}

void main() {
  late String src;

  setUpAll(() {
    final f = File('lib/ui/settings/playback_page.dart');
    expect(f.existsSync(), isTrue,
        reason: '找不到 lib/ui/settings/playback_page.dart');
    src = stripComments(f.readAsStringSync());
  });

  group('★★★ 播放器缓存文案：不许误导用户', () {
    test('① 0 字节时不许显示 "0 B" 字面读数', () {
      // 允许出现 humanBytes(_mpvBytes) 但**必须在 _mpvBytes > 0 的分支里**
      expect(src.contains('_mpvBytes > 0'), isTrue,
          reason: '★ 必须有 `_mpvBytes > 0` 的分支判断 —— '
              '否则 0 字节时会显示"播放器缓存 0 B"，'
              '而实测该目录**永远是空的**（mpv 对可 seek 的 HTTP 源不落盘）');

      // 硬编码 "0 B" 字符串不许出现
      expect(src.contains("'0 B'"), isFalse,
          reason: '★ 不许硬编码 "0 B" 当作播放器缓存的读数');
    });

    test('② 必须有"不占磁盘"或"内存里缓存"之类的如实说明', () {
      final honest = src.contains('不占磁盘') ||
          src.contains('内存里缓存') ||
          src.contains('仅不可 seek');
      expect(honest, isTrue,
          reason: '★ 0 字节时必须**如实解释原因**，不能只显示 0：'
              '实测 mpv 对可 seek 的 HTTP Range 源不落盘，只在内存里缓存。'
              '用户看到 0 会以为缓存坏了，而实际上这是正常的。');
    });

    test('③ 有值时仍要显示字节数（不能为了修 0 而改坏有值场景）', () {
      expect(src.contains('humanBytes(_mpvBytes)'), isTrue,
          reason: '★ 值 > 0 时仍要显示真实字节数 —— '
              '不可 seek 的流（直播等）确实会落盘，那时必须能看到大小');
    });

    test('④ 标签要说明是"临时"缓存，与片段缓存（成品）区分', () {
      expect(src.contains('播放器临时缓存'), isTrue,
          reason: '★ 标签必须含"临时"二字：'
              'clip-cache 是可淘汰的成品，mpv-cache 是临时解复用，'
              '两者删除代价不同（前者要重新下，后者只是重缓冲）');
      // 反向：不许再叫旧的笼统名字
      expect(src.contains("label: '播放器缓存'"), isFalse,
          reason: '★ 旧的笼统标签「播放器缓存」要改掉');
    });

    test('⑤ 不许删除这个 UI 区块（机制仍在，只是当前值为 0）', () {
      expect(src.contains('SettingsInfoRow'), isTrue);
      // 该目录仍在传给 mpv —— cache-dir 不能被顺手删
      final cd = stripComments(
          File('lib/core/clip_download.dart').readAsStringSync());
      expect(cd.contains('cache-dir') || cd.contains('kMpvCacheDirKey'), isTrue,
          reason: '★ `cache-dir` 仍在传给 mpv：'
              '它对不可 seek 的流（直播/某些 HLS）仍会落盘，'
              '不能因为"现在显示 0"就把机制删掉');
    });
  });
}
