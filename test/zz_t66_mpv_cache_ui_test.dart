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
// ★ 2026-10-18（第 66 轮自审）：断言的**对象**从源码字符串改成这个纯函数的返回值
import 'package:sourin_spike/ui/settings/playback_page.dart' show mpvCacheLabel;

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
      /*
       * ★★★ 2026-10-18（第 66 轮自审）：这三条断言**被实证是假绿**，已重写。
       *
       * # 改前（全部读源码字符串）
       * ```dart
       * expect(src.contains('_mpvBytes > 0'), isTrue);
       * expect(src.contains("'0 B'"), isFalse);
       * expect(src.contains('humanBytes(_mpvBytes)'), isTrue);
       * ```
       * # 实测注入（我真的做了）
       * ```text
       * 把三元表达式的两个分支**写反**：
       *   _mpvBytes > 0 ? '不占磁盘…' : '${humanBytes} · 仅不可 seek…'
       * ⇒ 0 字节时显示「0 B · 仅不可 seek 的流会落盘」
       * ⇒ >0   时显示「不占磁盘（网络流在内存里缓存）」
       * ⇒ **用户看到的信息完全相反** —— 正是本文件开头描述的那个坑
       * ⇒ 而上面三条断言**一条都没红**，`+5 All tests passed`
       * ```
       * ⇒ 判据必须读**真实结果**（函数返回值），不能读喂进去的那个值
       *    （源码里有 `_mpvBytes > 0` 这几个字符 ≠ 分支方向对）
       */
      final zero = mpvCacheLabel(0);
      expect(zero.contains('0 B'), isFalse,
          reason: '★ 0 字节时**不许**出现 "0 B" 读数 —— '
              '实测该目录永远是空的（mpv 对可 seek 的 HTTP 源不落盘），'
              '显示 0 B 会让用户以为缓存坏了、或者去清 0 个文件');

      // 反方向也必须成立：真有值时**必须**给出字节数
      final some = mpvCacheLabel(2048);
      expect(some.contains('0 B'), isFalse,
          reason: '★ 有值时也不该是 "0 B"（这条同时挡住"永远返回 0"的实现）');
      expect(some.contains('KB') || some.contains('B'), isTrue,
          reason: '★ 有值时必须显示真实字节数');
    });

    test('② 0 字节时必须如实解释原因（而不是只显示 0）', () {
      final zero = mpvCacheLabel(0);
      final honest = zero.contains('不占磁盘') ||
          zero.contains('内存里缓存') ||
          zero.contains('仅不可 seek');
      expect(honest, isTrue,
          reason: '★ 0 字节时必须**如实解释原因**，不能只显示 0：'
              '实测 mpv 对可 seek 的 HTTP Range 源不落盘，只在内存里缓存。'
              '用户看到 0 会以为缓存坏了，而实际上这是正常的。');

      // ★ 反向：有值时**不许**再说"不占磁盘"（分支写反就会命中这一条）
      final some = mpvCacheLabel(4096);
      expect(some.contains('不占磁盘'), isFalse,
          reason: '★★★ 有值时说"不占磁盘"就是分支写反了 —— '
              '这条正是改前那版漏掉的（它只查源码里有没有这几个字符）');
    });

    test('③ 有值时必须显示字节数，且标签语义正确', () {
      // 值 > 0 ⇒ 必须给出大小 + 落盘条件说明
      final some = mpvCacheLabel(1536);
      expect(some.contains('1.5 KB') || some.contains('KB'), isTrue,
          reason: '★ 值 > 0 时仍要显示真实字节数 —— '
              '不可 seek 的流（直播等）确实会落盘，那时必须能看到大小');
      expect(some.contains('不可 seek'), isTrue,
          reason: '★ 有值时要说明"为什么会有值"（只有不可 seek 的流会落盘）');
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
