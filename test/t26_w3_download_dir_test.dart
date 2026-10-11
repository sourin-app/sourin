// ZZ-CR-DL · CR-05 · 目录名尾随点/空格（Win32 路径段规整）回归测试
//
// 缺陷（原 lib/core/download_dir.dart 的 forWork）：
//   final name = ClipDownloader.safeName(raw);      // 只挡 '.' / '..'
//   final d = Directory('$base${Platform.pathSeparator}$name');
//   —— Win32 在**解析路径**时会把每个**路径段**末尾的点与空格规整掉：
//        '<根>\...'    → '<根>'          （段被吃光 ⇒ 等于下载根本身）
//        '<根>\. .'    → '<根>'
//        '<根>\剧名. ' → '<根>\剧名'      （尾随点/空格被吃掉）
//   ⇒ forWork('...') 返回的**就是下载根**，而 DownloadQueue.removeWork(
//     force: true) 会拿它 Directory.delete(recursive: true)
//     ⇒ 整个下载根连同里面所有作品一起没了（RED 实测见 .probe/ops/t26-w3-download.md）。
//
// 判据：
//   ① forWork(<尾随点/空格标题>) 的结果必须落在 root() 之下（root 是它的祖先），
//      且**不等于** root() 本身；
//   ② 那个目录必须在盘上**真存在**，而且能往里**真写文件**；
//   ③ 对它做一次真的 recursive 删除之后，下载根与「上级哨兵」都必须还在。
//
// ★ 为什么不能直接断言 resolved != root：Windows 上
//   Directory('<root>\...').resolveSymbolicLinksSync() 自己就抛
//   FileSystemException(OS Error: 系统找不到指定的文件。, errno = 2)
//   ⇒ 只能像 zz_cr_dl_c16_workdir_test.dart:31-45 那样**自己按段解析**。
//
// 跑法：flutter test test/t26_w3_download_dir_test.dart --concurrency=1

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/download_dir.dart';
import 'package:sourin_spike/core/download_queue.dart';
import 'package:sourin_spike/core/ui_prefs.dart';

/// 把路径按 . / .. 段**真解析**成规范形式
/// （照抄 zz_cr_dl_c16_workdir_test.dart:31-45：字符串前缀比较是假门禁）
String _normalize(String p) {
  final norm = p.replaceAll(String.fromCharCode(92), '/');
  final drive = norm.length >= 2 && norm[1] == ':' ? norm.substring(0, 2) : '';
  final body = drive.isEmpty ? norm : norm.substring(2);
  final out = <String>[];
  for (final seg in body.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (out.isNotEmpty) out.removeLast();
      continue;
    }
    out.add(seg);
  }
  return drive + '/' + out.join('/');
}

String _sandboxRoot() => Directory(
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}cr_dl_c05')
    .path;

/// 根目录上面再垫一层「上级」，这样 .. 一旦生效就会指向一个真实存在的目录，
/// 我们能在磁盘上**看见**它，而不是只比对字符串（同 c16 的做法）。
Future<String> _freshRoot(String tag) async {
  final d = Directory(
      '${_sandboxRoot()}${Platform.pathSeparator}$tag${Platform.pathSeparator}下载根');
  if (await d.exists()) await d.delete(recursive: true);
  await d.create(recursive: true);
  return d.path;
}

void main() {
  late String rootPath;
  late String parentPath;
  late String sentinelPath;

  setUp(() async {
    rootPath = await _freshRoot('case');
    parentPath = Directory(rootPath).parent.path;
    sentinelPath = parentPath + Platform.pathSeparator + 'CR05 上级哨兵.txt';
    await File(sentinelPath).writeAsString('别删我', flush: true);
    // ★ 不用 DownloadDir.setConfiguredDir：它内部调 AppLog.write，
    //   而 AppLog.logDir() 会走 ClipDownloader.dataDir() → path_provider
    //   ⇒ 在 flutter_test 里是 MissingPluginException（插件没注册）。
    //   这里直接灌 UiPrefs 的内存数据，效果等价且不碰插件。
    UiPrefs.debugResetForTest(<String, String>{DownloadDir.kDirKey: rootPath});
    DownloadDir.debugReset();
  });

  tearDown(() {
    DownloadDir.debugReset();
    UiPrefs.debugResetForTest();
  });

  test('★ 前置：普通剧名不得被这条改动带偏（否则下面几条的红分不清是谁的红）', () async {
    final r = await DownloadDir.root();
    final nr = _normalize(r);
    for (final t in <String>['无职转生', '普通剧名']) {
      final d = await DownloadDir.forWork(t);
      expect(_normalize(d), isNot(equals(nr)),
          reason: '★ 普通名字不该落到下载根本身：$t → $d');
      expect(_normalize(d).startsWith(nr + '/'), isTrue,
          reason: '★ 普通名字不该逃出下载根：$t → $d');
      expect(Directory(d).existsSync(), isTrue,
          reason: '★ 目录必须在盘上真存在：$t → $d');
    }
  });

  test('★★ CR-05：尾随点/空格的标题不得让 forWork 塌回下载根本身（Win32 路径段规整）',
      () async {
    final sep = Platform.pathSeparator;
    final r = await DownloadDir.root();
    final nr = _normalize(r);
    final bad = <String>[];
    /*
     * ★ 这批输入就是 Win32 会「规整掉尾随点/空格」的那些：
     *   '...' / '. .' / '.. .' 整段被吃光 ⇒ 解析结果 = 下载根；
     *   '剧名. ' / '剧名 ' 则变成 '剧名' ⇒ 与另一个名字**撞目录**。
     */
    for (final t in <String>['...', '. .', '.. .', '剧名. ', '剧名 ', '剧名...  ', '.', '..']) {
      final d = await DownloadDir.forWork(t);
      final nd = _normalize(d);
      if (nd == nr) {
        bad.add('★★ forWork(${jsonEncode(t)}) 落到了**下载根本身**：$d');
      }
      if (!nd.startsWith(nr + '/')) {
        bad.add('★★ forWork(${jsonEncode(t)}) 逃出了下载根：$d');
      }
      if (!Directory(d).existsSync()) {
        bad.add('★ forWork(${jsonEncode(t)}) 的目录在盘上不存在：$d');
      }
      // ★★ 光比字符串是**假门禁**：_normalize 把 '...' 当一个普通段留着，
      //    所以它永远算「在根下面」，哪怕 Win32 已经把这个段整个吃掉。
      //    必须落到**文件系统**上问一句：这个目录里到底写不写得进东西？
      //    写进去的字节又有没有跑到下载根那一层去？
      final probe = File(d + sep + 'probe.bin');
      try {
        await probe.writeAsBytes(<int>[7, 7, 7], flush: true);
      } catch (e) {
        bad.add('★★ 往 forWork(${jsonEncode(t)}) 里写文件失败（Win32 把这一段规整到根上去了）：$e');
      }
      if (!probe.existsSync()) {
        bad.add('★ 往 forWork(${jsonEncode(t)}) 里写文件后文件不在：$probe');
      }
      if (File(rootPath + sep + 'probe.bin').existsSync()) {
        bad.add('★★ forWork(${jsonEncode(t)}) 写出来的文件落进了**下载根**这一层 ⇒ 这个「目录」就是根');
      }
      try {
        if (probe.existsSync()) await probe.delete();
      } catch (_) {
        // 收尾失败不影响判据
      }
    }
    expect(bad, isEmpty, reason: bad.join('\n'));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('★★ CR-05：对 forWork(尾随点标题) 的目录做真递归删除，不得动到下载根与上级哨兵',
      () async {
    final sep = Platform.pathSeparator;
    final inside = await DownloadDir.forWork('正常剧');
    await File(inside + sep + '第01集.mp4').writeAsBytes(<int>[1, 2, 3]);

    final bad = <String>[];
    for (final t in <String>['...', '. .', '剧名. ']) {
      final d = await DownloadDir.forWork(t);
      // ① 结果必须真的是「根下面的一层」，否则下面那一刀砍的就是根
      final nd = _normalize(d);
      if (nd == _normalize(rootPath)) {
        bad.add('★★ forWork(${jsonEncode(t)}) == 下载根 ⇒ 这一刀会砍掉整个下载根');
      }
      // ② 目录里能真写进文件（不是个指向别处的空壳）
      final probe = File(d + sep + 'probe.bin');
      try {
        await probe.writeAsBytes(<int>[7, 7, 7], flush: true);
        if (!probe.existsSync()) bad.add('★ 往 forWork(${jsonEncode(t)}) 里写文件后文件不在');
      } catch (e) {
        bad.add('★ 往 forWork(${jsonEncode(t)}) 里写文件失败：$e');
      }
      // ③ 真删一刀（removeWork(force:true) 干的就是这个）
      try {
        await Directory(d).delete(recursive: true);
      } catch (e) {
        bad.add('★ 删 forWork(${jsonEncode(t)}) 失败：$e');
      }
      if (!Directory(rootPath).existsSync()) {
        bad.add('★★ 删完 forWork(${jsonEncode(t)}) 之后**下载根没了**（root=$rootPath）');
      }
      if (!File(sentinelPath).existsSync()) {
        bad.add('★★ 删完 forWork(${jsonEncode(t)}) 之后**上级哨兵没了**（$sentinelPath）');
      }
      if (!File(inside + sep + '第01集.mp4').existsSync()) {
        bad.add('★★ 删完 forWork(${jsonEncode(t)}) 之后**别的作品的剧集没了**');
      }
    }
    expect(bad, isEmpty, reason: bad.join('\n'));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('★ 对照：真的越界输入（手写 .. 拼出来的路径）必须**真的**能把根删掉 —— 证明上一条的读数是活的',
      () async {
    final sep = Platform.pathSeparator;
    final escaped = rootPath + sep + '..' + sep + '下载根';
    final probe = Directory(escaped);
    expect(probe.existsSync(), isTrue, reason: '前置：拼出来的越界路径必须真的指向下载根');
    expect(_normalize(escaped), equals(_normalize(rootPath)),
        reason: '前置：_normalize 必须认得这种越界形态');
    // 真删一次：根必须真的消失（这条是**阳性对照**，红了说明探针根本没在测东西）
    await probe.delete(recursive: true);
    expect(Directory(rootPath).existsSync(), isFalse,
        reason: '★ 阳性对照失效：<根>\\..\\下载根 居然删不掉根，说明这组探针测不到删除路径');
    // 收尾：把根建回来，别让后面的用例看到半个世界
    await Directory(rootPath).create(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
