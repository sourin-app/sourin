// ═══════════════════════════════════════════════════════════════════════
//  CS-1 门禁：SyncPanel 在 Windows 显示缩放（100%/125%/150%/175%）下不许坏
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要这条（它不是"多测一点"，是补一个真实缺口）
//
// 证据图是 widget 层渲染的（见 `zz_t66_cs1_evidence_shots_test.dart`），
// 而 README 里原本写着一条"不能证明什么"：
//
// ```text
// ✗ 真机窗口的 DPI 缩放 / 系统字体差异     ← 一直是「未知」
// ```
//
// 「未知」不能被渲染成「没问题」。但这条**能查** ⇒ 就查掉它。
//
// # 怎么模拟"Windows 显示缩放 125%"
//
// ```text
// ★ 不是「逻辑区域不变、DPR 变大」（那只是出图更清晰，布局完全一样）
//   而是「**物理屏幕固定、逻辑区域变小**」：
//     物理 1920x1080 固定
//     DPR 1.00 → 逻辑宽 1920
//     DPR 1.25 → 逻辑宽 1536
//     DPR 1.50 → 逻辑宽 1280
//     DPR 1.75 → 逻辑宽 1097
//   ⇒ 用户开 150% 缩放时，他看到的**逻辑空间真的变窄了**，
//     这才是可能挤爆布局的地方。
// ```
//
// # 踩过的坑：双重缩放（第一版探针就是这么错的）
//
// ```text
// 错：t.view.physicalSize = logical × dpr  +  toImage(pixelRatio: dpr)
//     ⇒ 图 = logical × dpr × dpr，内容只占左上 1/dpr
//     ⇒ 看起来"右侧被裁" —— 其实是探针把画布放大了两倍
// 正：只改 devicePixelRatio，physicalSize 保持固定
//     ⇒ 逻辑宽自动 = physicalSize / dpr
// ```
//
// # 判据（每条都对应"用户会看到坏样子"）
//
// ```text
// ① 不许有 RenderFlex overflow
// ② 状态行：四档都必须是 1 行（它在逻辑宽 1097 时仍有大量富余）
// ③ 关键告知「网盘那边解不开」必须可见且不越出面板
// ④ 五个动作按钮的文字不许被压到 0 宽/极小高
// ```
//
// ★ 阳性对照：逻辑宽 480 时状态行必须折成 2 行。
//   没有它，上面四条在"探针量不到东西"时也会全绿。

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/sync_panel.dart';

import 'support/ui_shot.dart';

/// 状态行**单行**高度（逻辑像素）—— 实测值，不是推算
///
/// 依据：DPR 1.0 / 逻辑宽 1920 时 `sync-credentials-status` 的
/// `RenderBox.size.height == 12.0`；逻辑宽 480 时折成 2 行 = 24.0。
/// ⚠️ 第一版我猜「cap(11~12) × lineHeight(1.6) ≈ 19」，用它做除数
///    会把真实的 2 行算成 1 行 ⇒ 阳性对照当场抓到。
const double kStatusLineHeight = 12.0;

/// 一档缩放的读数
class ScaleReading {
  ScaleReading(this.label, this.dpr);
  final String label;
  final double dpr;

  double logicW = 0;
  bool overflow = false;
  int statusLines = 0;
  String statusBox = '';
  bool disclosureVisible = false;
  bool disclosureOutsidePanel = false;
  int buttonsOk = 0;
  int buttonsTotal = 0;
  List<String> buttonProblems = [];

  @override
  String toString() => '$label(dpr=$dpr, logic=${logicW.toStringAsFixed(0)}): '
      'overflow=$overflow statusLines=$statusLines box=$statusBox '
      'disclosure=$disclosureVisible/${disclosureOutsidePanel} '
      'buttons=$buttonsOk/$buttonsTotal'
      '${buttonProblems.isEmpty ? '' : ' problems=$buttonProblems'}';
}

void main() {
  setUpAll(loadRealFonts);
  tearDown(() => SourinApi.installSyncDebugFetchers());

  Future<void> installCredFetchers() async {
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
      credentials: () async => const CredentialsStatus(
        enabled: true,
        passphraseSet: true,
        providers: 2,
      ),
    );
  }

  Future<void> pumpPanel(WidgetTester t) async {
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

  /// 量一档：物理屏幕固定，只改 DPR（= Windows 显示缩放）
  Future<ScaleReading> measure(
    WidgetTester t,
    String label,
    double dpr, {
    Size physical = const Size(1920, 1080),
  }) async {
    await installCredFetchers();
    t.view.devicePixelRatio = dpr;
    t.view.physicalSize = physical;
    addTearDown(t.view.reset);

    final r = ScaleReading(label, dpr)..logicW = physical.width / dpr;
    await pumpPanel(t);

    // ① 溢出
    final ex = t.takeException();
    if (ex != null) r.overflow = true;
    for (final w in find.byType(Text).evaluate()) {
      final d = (w.widget as Text).data ?? '';
      if (d.contains('overflowed by') || d.contains('OVERFLOW')) {
        r.overflow = true;
      }
    }

    // ② 状态行
    final sf = find.byKey(const ValueKey('sync-credentials-status'));
    if (sf.evaluate().isNotEmpty) {
      final box = t.renderObject<RenderBox>(sf);
      r.statusBox = '${box.size.width.toStringAsFixed(1)}x'
          '${box.size.height.toStringAsFixed(1)}';
      r.statusLines = (box.size.height / kStatusLineHeight).round().clamp(1, 99);
    }

    // ③ 关键告知
    final df = find.textContaining('网盘那边解不开');
    if (df.evaluate().isNotEmpty) {
      r.disclosureVisible = true;
      final box = t.renderObject<RenderBox>(df.first);
      final panel = t.renderObject<RenderBox>(find.byType(SyncPanel));
      final dr = box.localToGlobal(Offset.zero) & box.size;
      final pr = panel.localToGlobal(Offset.zero) & panel.size;
      r.disclosureOutsidePanel =
          dr.right > pr.right + 0.5 || dr.bottom > pr.bottom + 0.5;
    }

    // ④ 按钮
    for (final lb in ['重新配置', '测试连接', '立即同步', '立即备份', '断开']) {
      final f = find.text(lb);
      if (f.evaluate().isEmpty) continue;
      r.buttonsTotal++;
      final b = t.renderObject<RenderBox>(f);
      if (b.size.width <= 0 || b.size.height < 10) {
        r.buttonProblems.add('$lb ${b.size.width}x${b.size.height}');
      } else {
        r.buttonsOk++;
      }
    }
    return r;
  }

  // ─────────────────────────────────────────────────────────────
  // ★★★ 四档 Windows 显示缩放
  // ─────────────────────────────────────────────────────────────

  for (final e in <(String, double)>[
    ('100%', 1.0),
    ('125%', 1.25),
    ('150%', 1.5),
    ('175%', 1.75),
  ]) {
    testWidgets('★★★ Windows 显示缩放 ${e.$1} 下布局不许坏', (t) async {
      final r = await measure(t, e.$1, e.$2);
      // ignore: avoid_print
      print('[SCALE] $r');

      expect(r.overflow, isFalse,
          reason: '★ ${e.$1} 缩放下出现 RenderFlex overflow —— 真机上用户会看到内容被裁');
      expect(r.statusLines, 1,
          reason: '★ ${e.$1} 缩放下状态行折成 ${r.statusLines} 行'
              '（box=${r.statusBox}）—— 逻辑宽 ${r.logicW.toStringAsFixed(0)} 时不该折');
      expect(r.disclosureVisible, isTrue,
          reason: '★★ ${e.$1} 缩放下「网盘那边解不开」那句不见了 —— '
              '那是 CS-1 的关键告知');
      expect(r.disclosureOutsidePanel, isFalse,
          reason: '★ ${e.$1} 缩放下关键告知越出面板');
      expect(r.buttonsTotal, 5, reason: '五个动作按钮必须都在');
      expect(r.buttonProblems, isEmpty,
          reason: '★ ${e.$1} 缩放下按钮被挤变形: ${r.buttonProblems}');
    });
  }

  // ─────────────────────────────────────────────────────────────
  // ★★★ 阳性对照：判据必须能测出「真的坏了」
  // ─────────────────────────────────────────────────────────────

  testWidgets('★★★ 阳性对照：逻辑宽 480 时状态行必须折行', (t) async {
    /*
     * 没有这条，上面四档的"全绿"可能只是**探针量不到东西**。
     * 480 逻辑宽（= 物理 480 / DPR 1.0）下，状态行必然折成 2 行。
     */
    final r = await measure(t, 'control-480', 1.0,
        physical: const Size(480, 900));
    // ignore: avoid_print
    print('[SCALE-CONTROL] $r');

    expect(
      r.statusLines > 1,
      isTrue,
      reason: '★★★ 阳性对照失败：480 逻辑宽下状态行仍是 ${r.statusLines} 行'
          '（box=${r.statusBox}）—— 说明本门禁的判据量不到折行，'
          '上面四档的"正常"不可信。',
    );
  });
}
