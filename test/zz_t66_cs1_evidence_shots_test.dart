// ═══════════════════════════════════════════════════════════════════════
//  CS-1 证据出图：SyncPanel 的两种凭据状态（widget 层渲染）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件是什么 / 不是什么
//
// ```text
// 是：把 SyncPanel 在两种凭据状态下的**真实渲染**落成 PNG，
//     供 docs/notes/evidence/round-66-cs1/ 封存成可复核证据。
// 不是：真机截图。这里是 flutter_tester 的 widget 层渲染
//       （RenderRepaintBoundary 的 OffsetLayer.toImage）。
// ```
// ⇒ 证据 README 与 manifest 的 criterion 都写明了这一点。
//   **宁可诚实地标注来源，也不要让下一个人以为那是真机图。**
//
// # 可复用写法（抄自 test/zz_t66_r4_dialog_pixel_test.dart，那处已验证可用）
//
// ```dart
// final view  = t.binding.renderViews.first;
// final layer = view.debugLayer! as OffsetLayer;
// final size  = view.size;
// await t.runAsync(() async {          // ★ 必须 runAsync
//   final img = await layer.toImage(Offset.zero & size);
//   final bd  = await img.toByteData(format: ui.ImageByteFormat.png);
// });
// ```
//
// # ★ 三个必须抄的细节（每个都对应 r4 那份注释里记的坑）
//
// ```text
// ① 截**整个视口**（renderViews.first.debugLayer），不是 RepaintBoundary
//    —— 否则弹窗/Overlay 画在外层时截不到
// ② 必须包 `t.runAsync` —— toImage 在 fake-async 的 testWidgets 里**永不完成**
// ③ 必须 `import 'package:flutter/rendering.dart'` —— 否则 `OffsetLayer isn't a type`
// ```
//
// # 状态怎么造（不用写配置文件）
//
// SyncPanel 的状态**全部**经 `SourinApi` 的注入点读：
// `syncStatus` / `syncSettings` / `syncBackupList` / `credentialsStatus`。
// ⇒ 用 `installSyncDebugFetchers` 造状态即可，**不需要**隔离数据目录，
//   也不会碰 `%APPDATA%\app.sourin.player`（那些注入点根本不读盘）。
//
// # 为什么断言「颜色数」而不只是「字节数」
//
// 一个纯色块也能有几千字节。**字节数大 ≠ 图里有内容**。
// ⇒ 解 PNG 的 rawRgba 数不同颜色数：真面板有几百种（文字抗锯齿），
//   纯色块只有 1~2 种。
//
// # ⚠️ 这条判据的**真实作用域**（故障注入测出来的，不是想出来的）
//
// 我原以为它也能拦住「别人往证据目录里塞一张占位图」。**实测拦不住**：
// ```text
// 注入：把 cs1-sync-disabled.png 换成 5372 B 的纯色 PNG
// 跑：  flutter test test/zz_t66_cs1_evidence_shots_test.dart
// 结果：+3 All tests passed！  ← 没红
// 原因：本文件的用例会**重新渲染并覆盖**那两张图，
//       占位图在断言执行前就被真图替换掉了 ⇒ 颜色判据看到的永远是刚渲染的真图。
// ```
// ⇒ 它真正拦的是「**渲染出来的东西**是纯色块」（例如 pumpWidget 失败、
//   主题全黑、widget 没挂上）。那是有价值的一条，但**不是**「防别人塞占位图」。
//
// 防「塞占位图」靠的是**另外两条**：
// ```text
// ① manifest 的 sha256 逐字比对（zz_t66_cs1_evidence_manifest_test.dart）
//    —— 塞进来的图没有对应 sha 登记 ⇒ 红。实测注入「+1 字节」⇒ -2。
// ② 本文件的 ③ 号用例（两张图字节数必须不同）
//    —— 同一张存两遍会被抓。实测删一张 ⇒ manifest -3。
// ```
// ★ 这条更正是「判据作用域写错」的又一例：**判据有效 ≠ 判据能拦你以为的那个东西**。

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/sync_panel.dart';

import 'support/ui_shot.dart';

/// 出图目标目录（证据目录，git 跟踪）
const String kOutDir = 'docs/notes/evidence/round-66-cs1';

/// 出图结果
typedef ShotResult = ({int bytes, int w, int h, int colors});

/// 把**整个视口**渲染成 PNG 落盘，并数颜色种数
Future<ShotResult> capture(WidgetTester t, String name) async {
  final view = t.binding.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  final size = view.size;

  late ui.Image img;
  late Uint8List png;
  // ★ 必须 runAsync：fake-async 里 toImage 永不完成（r4 那份注释里记的坑 3）
  await t.runAsync(() async {
    img = await layer.toImage(Offset.zero & size);
    final bd = await img.toByteData(format: ui.ImageByteFormat.png);
    png = bd!.buffer.asUint8List();
  });

  final dir = Directory(kOutDir)..createSync(recursive: true);
  final f = File('${dir.path}/$name.png');
  f.writeAsBytesSync(png, flush: true);

  final distinct = <int>{};
  await t.runAsync(() async {
    final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    final b = bd!.buffer.asUint8List();
    for (var i = 0; i < b.length; i += 4) {
      distinct.add((b[i] << 16) | (b[i + 1] << 8) | b[i + 2]);
    }
  });

  return (bytes: png.length, w: img.width, h: img.height, colors: distinct.length);
}

void main() {
  setUpAll(loadRealFonts);

  // 注入点是全局静态 ⇒ 每个用例后复原，避免污染同进程其它测试
  tearDown(() => SourinApi.installSyncDebugFetchers());

  /// 造状态 + 挂面板
  Future<void> pump(WidgetTester t, CredentialsStatus cred) async {
    SourinApi.installSyncDebugFetchers(
      status: () async => const SyncStatus(
        connected: true,
        backend: 'WebDAV',
        deviceId: 'dev-a',
      ),
      settings: () async => const SyncSettings(
        connected: true,
        baseUrl: 'https://dav.example.invalid/dav/',
        username: 'user@example.invalid',
        remoteDir: 'sourin',
      ),
      backups: () async => const <SyncBackupEntry>[],
      credentials: () async => cred,
    );
    await setShotViewport(t, const Size(1280, 900));
    await t.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeFor(Brightness.dark),
        home: const Scaffold(
          body: SingleChildScrollView(
            child: Padding(padding: EdgeInsets.all(16), child: SyncPanel()),
          ),
        ),
      ),
    );
    await t.pump();
    await t.pump(const Duration(milliseconds: 120));
  }

  // ─────────────────────────────────────────────────────────────
  // ① 口令未设置
  // ─────────────────────────────────────────────────────────────

  testWidgets('① 出图：口令未设置（状态行必须是「凭据未同步」）', (t) async {
    await pump(
      t,
      const CredentialsStatus(enabled: true, passphraseSet: false, providers: 2),
    );

    // ★ 先断言界面上真的有那句话，再出图 —— 否则图里可能是别的状态
    expect(
      find.textContaining('凭据未同步'),
      findsWidgets,
      reason: '出图前必须确认状态行是「凭据未同步」，否则这张图名不副实',
    );

    final r = await capture(t, 'cs1-sync-disabled');
    // ignore: avoid_print
    print('[EVIDENCE] cs1-sync-disabled.png  ${r.w}x${r.h}  '
        '${r.bytes} B  colors=${r.colors}');

    /*
     * ★ 「不许塞占位图」的机械判据：
     *   纯色块只有 1~2 种颜色；真面板有几百种（文字抗锯齿、圆角、阴影）。
     *   字节数大 ≠ 有内容 —— 所以要数颜色。
     */
    expect(r.colors, greaterThan(50),
        reason: '颜色太少 ⇒ 图里没有真实内容（可能是占位/纯色块）');
    expect(r.bytes, greaterThan(10000), reason: '1280x900 的面板图不该这么小');
    expect(r.w, 1280);
    expect(r.h, 900);
  });

  // ─────────────────────────────────────────────────────────────
  // ② 口令已设置
  // ─────────────────────────────────────────────────────────────

  testWidgets('② 出图：口令已设置（状态行必须含「将同步」与方向语义）', (t) async {
    await pump(
      t,
      const CredentialsStatus(enabled: true, passphraseSet: true, providers: 2),
    );

    expect(
      find.textContaining('凭据将同步'),
      findsWidgets,
      reason: '出图前必须确认状态行是「凭据将同步」',
    );
    /*
     * ★ 这张图要能证明 CS-1 的**方向语义**（只上行 + 取回用导入）。
     *   若那句话被删了，图还在但证明力没了 ⇒ 先断言再出图。
     */
    expect(
      find.textContaining('仅上行'),
      findsWidgets,
      reason: '这张图的意义之一是证明方向语义在界面上可见',
    );
    expect(
      find.textContaining('网盘那边解不开'),
      findsWidgets,
      reason: '这张图的意义之一是证明「服务端解不开」那句关键告知在界面上',
    );

    final r = await capture(t, 'cs1-sync-enabled');
    // ignore: avoid_print
    print('[EVIDENCE] cs1-sync-enabled.png   ${r.w}x${r.h}  '
        '${r.bytes} B  colors=${r.colors}');

    expect(r.colors, greaterThan(50));
    expect(r.bytes, greaterThan(10000));
  });

  // ─────────────────────────────────────────────────────────────
  // ③ 两张图必须**真的不同**（否则等于只出了一张）
  // ─────────────────────────────────────────────────────────────

  test('③ 两张图的内容必须不同（不是同一张存了两遍）', () {
    final a = File('$kOutDir/cs1-sync-disabled.png');
    final b = File('$kOutDir/cs1-sync-enabled.png');
    expect(a.existsSync(), isTrue, reason: '先跑上面两个出图用例');
    expect(b.existsSync(), isTrue);

    final ba = a.readAsBytesSync();
    final bb = b.readAsBytesSync();

    /*
     * 两种状态在界面上差着**整行文案**（「凭据未同步（未设置口令）」
     * vs「凭据将同步：2 个源（仅上行…）」），像素必然不同。
     * 若这里相同 ⇒ 说明注入没生效（两个用例造的是同一个状态）⇒ 假证据。
     */
    expect(ba.length, isNot(bb.length),
        reason: '两张图的字节数不该完全相同（状态不同，文案不同）');
  });
}
