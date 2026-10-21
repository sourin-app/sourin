// ======================================================================
//  CS-1「证据可复核」门禁（round-66，verify-34 第 6/7 轮）
//
//  # 为什么存在
//  第 66 轮 CS-1 曾自报「真机 56 ✓ / 0 ✗（7 张截图）」。复核时发现：
//  图落在 `.probe/`（被 `.gitignore` 覆盖 + 每次跑清 stale），**盘上一张都
//  找不到** ⇒ 这个读数只能算「自报」，谁都复核不了。
//  修法分两半：
//    ① 工具侧 —— `tools/e2e_shots.ps1 -OutDir docs/notes/evidence/<round>`
//       把图落到 git 跟踪路径，并生成 `manifest.json`（commit / generatedAt /
//       每张的 name,w,h,bytes,sha256,criterion）；指到被 ignore 的目录会拒绝。
//    ② 门禁侧 —— 就是本文件：图与 manifest 必须逐张对得上，**否则红**。
//
//  # 现在的状态是「故意红」
//  本轮只交工具与门禁，真机出图归 r4-device（窗口独占）。所以在证据图落地
//  之前，本文件**必须**是红的 —— 红着提醒「证据还没出」。这不是 bug，
//  **不要**为了让它变绿去手写 manifest.json 或塞占位图：那就是把这条门禁
//  变成假绿的开始（本仓明令禁止）。
//
//  # 怎么让它转绿（唯一正路）
//      pwsh -NoProfile -File tools/e2e_shots.ps1 `
//           -OutDir docs/notes/evidence/round-66-cs1 -ManifestOnly `
//           -Criterion "CS-1 登录态同步 / 导出导入：<这一张证明什么>"
//  或直接让 `e2e_shots.ps1` 用 `-OutDir docs/notes/evidence/round-66-cs1` 跑
//  一遍真图（脚本会自己写 manifest.json）。
//
//  # 判据（三条，全部来自 manifest，不猜）
//    ① 目录里实际 PNG 数 == manifest 条目数（两个方向都查：多一张少一张都红）
//    ② 每张的 sha256 与 manifest 逐字一致（改一个十六进制位就红）
//    ③ 每张的尺寸与字节数与 manifest 一致
//  另有「仪器自检」小组：sha256 用两个已知常量钉住，PNG 尺寸解析用合成字节
//  钉住 —— 扫描器自己坏掉时必须先红，而不是恒绿。
// ======================================================================
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// 证据目录（git 跟踪；**不是** `.probe/`）。
const String kEvidenceDir = 'docs/notes/evidence/round-66-cs1';
const String kManifestPath = '$kEvidenceDir/manifest.json';

/// 重跑命令：故意写全，让红的时候照着抄就能修。
const String kResealCmd = 'pwsh -NoProfile -File tools/e2e_shots.ps1 '
    '-OutDir $kEvidenceDir -ManifestOnly -Criterion "<这一张证明什么>"';

const String kMissingMsg = '★★★ 证据缺失：$kManifestPath 不存在。\n'
    'CS-1 的「56 ✓ / 7 张截图」必须能复核 ⇒ 请先出图再封存，不要手写 manifest：\n'
    '    $kResealCmd';

class _Shot {
  _Shot({
    required this.name,
    required this.w,
    required this.h,
    required this.bytes,
    required this.sha256,
    required this.criterion,
  });

  final String name;
  final int w;
  final int h;
  final int bytes;
  final String sha256;
  final String criterion;
}

/// 读 manifest；任何结构问题都直接 fail（不 skip、不 return、不吞异常）。
List<_Shot> _loadManifest() {
  final f = File(kManifestPath);
  if (!f.existsSync()) {
    fail(kMissingMsg);
  }
  final raw = f.readAsStringSync();
  if (raw.trim().isEmpty) {
    fail('★★★ $kManifestPath 是空文件（0 字节内容）。\n$kResealCmd');
  }
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException catch (e) {
    fail('★★★ $kManifestPath 不是合法 JSON：$e\n$kResealCmd');
  }
  if (decoded is! Map<String, dynamic>) {
    fail('★★★ $kManifestPath 顶层必须是对象 {commit, generatedAt, files:[...]}，'
        '实际是 ${decoded.runtimeType}。\n$kResealCmd');
  }
  for (final k in const <String>['commit', 'generatedAt', 'files']) {
    if (!decoded.containsKey(k)) {
      fail('★★★ $kManifestPath 缺字段 `$k`。\n$kResealCmd');
    }
  }
  final files = decoded['files'];
  if (files is! List) {
    fail('★★★ $kManifestPath 的 `files` 必须是数组，实际是 ${files.runtimeType}。\n$kResealCmd');
  }
  final out = <_Shot>[];
  for (var i = 0; i < files.length; i++) {
    final e = files[i];
    if (e is! Map) {
      fail('★★★ $kManifestPath 的 files[$i] 必须是对象。\n$kResealCmd');
    }
    int intOf(String k) {
      final v = e[k];
      if (v is int) return v;
      if (v is num) return v.toInt();
      fail('★★★ $kManifestPath 的 files[$i].$k 必须是整数，实际是 $v。\n$kResealCmd');
    }

    String strOf(String k) {
      final v = e[k];
      if (v is String) return v;
      fail('★★★ $kManifestPath 的 files[$i].$k 必须是字符串，实际是 $v。\n$kResealCmd');
    }

    out.add(_Shot(
      name: strOf('name'),
      w: intOf('w'),
      h: intOf('h'),
      bytes: intOf('bytes'),
      sha256: strOf('sha256'),
      criterion: (e['criterion'] is String) ? e['criterion'] as String : '',
    ));
  }
  return out;
}

/// 只读 PNG 的 IHDR 拿宽高（不用第三方图片库：证据只需要「尺寸对得上」）。
({int w, int h})? _pngSize(File f) {
  final b = f.readAsBytesSync();
  if (b.length < 24) return null;
  const sig = <int>[0x89, 0x50, 0x4E, 0x47];
  for (var i = 0; i < 4; i++) {
    if (b[i] != sig[i]) return null;
  }
  final bd = ByteData.sublistView(Uint8List.fromList(b));
  return (w: bd.getUint32(16), h: bd.getUint32(20));
}

String _sha256Of(File f) => sha256.convert(f.readAsBytesSync()).toString();

List<File> _pngFiles() {
  final d = Directory(kEvidenceDir);
  if (!d.existsSync()) return <File>[];
  final all = d
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.png'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return all;
}

void main() {
  // ------------------------------------------------------------------
  //  仪器自检：门禁自己坏掉时必须先红
  // ------------------------------------------------------------------
  group('◆ 仪器自检（判别式本身不许空转）', () {
    test('① sha256 实现钉死：空串 / "abc" 两个已知常量', () {
      // NIST FIPS 180-2 的公开测试向量。包实现坏了、或被换成「原样返回」，
      // 这两条立刻红。
      expect(
        sha256.convert(const <int>[]).toString(),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        reason: 'sha256(空) 与公开常量不符 ⇒ 本门禁的 ② 判据不可信',
      );
      expect(
        sha256.convert(utf8.encode('abc')).toString(),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
        reason: 'sha256("abc") 与公开常量不符',
      );
    });

    test('② PNG 尺寸解析器钉死：合成字节必须读出 3 x 2', () {
      // 24 字节的假 PNG 头：签名 + 长度 + 'IHDR' + 宽 3 + 高 2。
      final bytes = <int>[
        0x89, 0x50, 0x4E, 0x47, // 签名
        0x0D, 0x0A, 0x1A, 0x0A, // \r\n\x1a\n
        0x00, 0x00, 0x00, 0x0D, // IHDR 长度
        0x49, 0x48, 0x44, 0x52, // 'IHDR'
        0x00, 0x00, 0x00, 0x03, // width  = 3
        0x00, 0x00, 0x00, 0x02, // height = 2
      ];
      final tmp = File(
          '${Directory.systemTemp.path}${Platform.pathSeparator}zz_t66_manifest_probe.png')
        ..writeAsBytesSync(bytes);
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync();
      });
      final size = _pngSize(tmp);
      expect(size, isNotNull, reason: '解析器认不出签名 ⇒ 判据 ③ 不可信');
      expect(size!.w, 3);
      expect(size.h, 2);
    });

    test('③ 重跑命令里写的是真路径（防止红的时候照抄一条错命令）', () {
      expect(kResealCmd, contains(kEvidenceDir));
      expect(kManifestPath, equals('$kEvidenceDir/manifest.json'));
    });
  });

  // ------------------------------------------------------------------
  //  正文：证据可复核
  // ------------------------------------------------------------------
  group('◆ CS-1 证据可复核（$kEvidenceDir）', () {
    test('条目数必须 > 0（防空转：0 张 == 0 条 也是「相等」）', () {
      final entries = _loadManifest();
      expect(entries, isNotEmpty,
          reason: '★★★ manifest 里一条都没有 ⇒ 没有任何证据被登记。\n$kResealCmd');
    });

    test('① 目录里实际 PNG 数 == manifest 条目数（两个方向都查）', () {
      final entries = _loadManifest();
      final pngs = _pngFiles();
      final onDisk = pngs.map((f) => f.uri.pathSegments.last).toSet();
      final inManifest = entries.map((e) => e.name).toSet();

      expect(pngs.length, entries.length,
          reason: '目录里有 ${pngs.length} 张 PNG，manifest 登记了 ${entries.length} 条。\n'
              '目录独有=${onDisk.difference(inManifest)}\n'
              'manifest 独有=${inManifest.difference(onDisk)}\n$kResealCmd');
      expect(inManifest.difference(onDisk), isEmpty,
          reason: '★★★ manifest 指向的图在盘上不存在（证据被删/改名了）：'
              '${inManifest.difference(onDisk)}\n$kResealCmd');
      expect(onDisk.difference(inManifest), isEmpty,
          reason: '★★★ 目录里有 manifest 没登记的图（可能是旧图混进来了，'
              '它没有 sha256 就没有证据效力）：${onDisk.difference(inManifest)}\n$kResealCmd');
    });

    test('② 每张的 sha256 与 manifest 逐字一致', () {
      final entries = _loadManifest();
      final bad = <String>[];
      for (final e in entries) {
        final f = File('$kEvidenceDir/${e.name}');
        if (!f.existsSync()) {
          bad.add('${e.name}: 文件不存在');
          continue;
        }
        final actual = _sha256Of(f);
        if (actual != e.sha256.toLowerCase()) {
          bad.add('${e.name}: manifest=${e.sha256} 实际=$actual');
        }
      }
      expect(bad, isEmpty,
          reason: '★★★ 有图与 manifest 的 sha256 不符（图被换过 / manifest 被手改过）：\n'
              '${bad.join('\n')}\n$kResealCmd');
    });

    test('③ 每张的尺寸与字节数与 manifest 一致', () {
      final entries = _loadManifest();
      final bad = <String>[];
      for (final e in entries) {
        final f = File('$kEvidenceDir/${e.name}');
        if (!f.existsSync()) {
          bad.add('${e.name}: 文件不存在');
          continue;
        }
        final size = _pngSize(f);
        if (size == null) {
          bad.add('${e.name}: 不是可解码的 PNG 头');
          continue;
        }
        final bytes = f.lengthSync();
        if (size.w != e.w || size.h != e.h) {
          bad.add('${e.name}: manifest=${e.w}x${e.h} 实际=${size.w}x${size.h}');
        }
        if (bytes != e.bytes) {
          // ★ 这里必须是 `${e.bytes}`（带花括号）。写 `$e.bytes` 时 Dart 只把
          //   `$e` 当插值、`.bytes` 当字面量 ⇒ 报错信息会打成
          //       manifest=Instance of '_Shot'.bytes B 实际=34464 B
          //   实测出处：CI run 39538011233（macOS job）。
          //   ★ 断言本身没有错，错的是**它想说的话**——而排错时人只有这句话可看。
          bad.add('${e.name}: manifest=${e.bytes} B 实际=$bytes B');
        }
      }
      expect(bad, isEmpty, reason: '★★★ 尺寸/字节数与 manifest 不符：\n${bad.join('\n')}\n$kResealCmd');
    });

    test('④ criterion 覆盖情况（只报告，不判红）', () {
      final entries = _loadManifest();
      final missing = entries.where((e) => e.criterion.trim().isEmpty).map((e) => e.name).toList();
      // 不判红：criterion 是「人能读懂这一张证明什么」，缺了不影响 sha256 的可复核性。
      // 但它在收尾汇报里必须被看见，所以打出来。
      // ignore: avoid_print
      print('EVIDENCE|criterion 已填 ${entries.length - missing.length}/${entries.length}'
          '${missing.isEmpty ? '' : '；未填=$missing'}');
      expect(entries, isNotEmpty, reason: kMissingMsg);
    });
  });
}
