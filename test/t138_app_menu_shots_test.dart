@Tags(['needs-shot-dir'])
// ignore_for_file: avoid_print
//
// ═══════════════════════════════════════════════════════════════════════
//  T6 · 统一菜单的看图台（自用，非断言型）
// ═══════════════════════════════════════════════════════════════════════
//
// Owner 第 8 条：「还有插件那个点击出来操作菜单的也好难看」。
// 断言（t137_app_menu_test.dart）只能锁住可量化的部分
// （底色槽位 / 圆角 / 描边角色 / 条目高 / 危险色）。
// 这份负责把**改后的真实渲染**落成 PNG，给人眼确认「好不好看」。
//
// # 跑法
// ```powershell
//   $env:SOURIN_SHOT_DIR = '.probe\shots'
//   flutter test test/t138_app_menu_shots_test.dart --run-skipped \
//     --tags needs-shot-dir --concurrency=1
// ```
//
// # 两个入口
//   ① 插件区块头的 ⋮      → AppMenuButton（settings_page.dart:3024）
//   ② 「下载」按钮的菜单    → showAppMenu（detail_page.dart:4635）
//
// ⚠️ ②挂的是**真 DetailPage**（debugSetDetail 注入详情，同 t27_w3 的做法）；
//   ①不挂整页 —— `SettingsPage` 起手要跨 FFI 加载，没核心时永远转圈
//   （截出来一片黑）。⇒ ①用与生产**同一个** AppMenuButton + 同一批 5 项
//   渲染。菜单面是 app_menu.dart 画的，所以图里就是生产那层面。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/network_status.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/detail_page.dart';
import 'package:sourin_spike/ui/tokens.dart';
import 'package:sourin_spike/ui/widgets/app_menu.dart';

import 'support/ui_shot.dart';

void _claim(WidgetTester t) {
  while (t.takeException() != null) {}
}

/// 从已落盘的 PNG 里裁一块放大 —— 菜单在整屏里偏小，不放大看不清描边/圆角
Future<File> _crop(File src, Rect region, String name,
    {double scale = 2.5}) async {
  final codec = await ui.instantiateImageCodec(src.readAsBytesSync());
  final frame = await codec.getNextFrame();
  final img = frame.image;
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  final dst = Rect.fromLTWH(0, 0, region.width * scale, region.height * scale);
  canvas.drawImageRect(
      img, region, dst, Paint()..filterQuality = FilterQuality.high);
  final out = await rec
      .endRecording()
      .toImage(dst.width.round(), dst.height.round());
  final bd = await out.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  out.dispose();
  final f = File('${shotDir().path}${Platform.pathSeparator}$name.png');
  f.writeAsBytesSync(bd!.buffer.asUint8List());
  return f;
}

Widget _host(Widget child, Brightness b) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.themeFor(b),
      home: RepaintBoundary(
        key: const ValueKey<String>('page'),
        child: Scaffold(body: Material(child: child)),
      ),
    );

/// 插件区块头 ⋮ 菜单的 5 项 —— 与 settings_page.dart:3048 的**同一批**
/// （值/顺序/enabled 条件/文案逐字相同）
List<AppMenuItem<String>> _pluginItems({bool sweeping = false, bool busy = false}) =>
    <AppMenuItem<String>>[
      const AppMenuItem<String>(
        value: 'order',
        label: '调整顺序',
        icon: Icons.reorder,
      ),
      AppMenuItem<String>(
        value: 'health',
        label: sweeping ? '处理中…' : '健康检测',
        icon: Icons.monitor_heart_outlined,
        enabled: !sweeping,
      ),
      const AppMenuItem<String>(
        value: 'import',
        label: '导入源',
        icon: Icons.add,
      ),
      AppMenuItem<String>(
        value: 'reload',
        label: busy ? '处理中…' : '重新加载',
        icon: Icons.refresh,
        enabled: !busy,
      ),
      const AppMenuItem<String>(
        value: 'source',
        label: '粘贴源码安装',
        icon: Icons.code,
      ),
    ];

void main() {
  setUpAll(loadRealFonts);

  // ── ① 插件区块头的 ⋮ 菜单（AppMenuButton）──────────────────
  for (final b in Brightness.values) {
    testWidgets('MENU1 插件 ⋮ 菜单 · ${b.name}', (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await setShotViewport(t, const Size(760, 460));
        await t.pumpWidget(_host(
          Center(
            child: AppMenuButton<String>(
              tooltip: '更多操作',
              iconSize: 18,
              items: _pluginItems(),
              onSelected: (_) {},
            ),
          ),
          b,
        ));
        _claim(t);
        await t.tap(find.byType(AppMenuButton<String>));
        await t.pumpAndSettle();
        expect(find.text('调整顺序'), findsOneWidget, reason: '菜单必须弹得出');

        /*
         * ⚠️ 必须整视口截图，不能截 'page' 那个 RepaintBoundary ——
         *   菜单是被 push 到 Navigator overlay 的**路由**，它在 `home:` 之上，
         *   不在那个 boundary 里 ⇒ 截 boundary 只会拍到 ⋮ 按钮本身
         *   （本文件第一版就这么拍的，图里一个菜单项都没有）。
         */
        final full = await saveViewShot(t, 'menu_plugin_${b.name}');
        print('[shot] ${full.path} (${full.lengthSync()} B)');
        expect(full.lengthSync(), greaterThan(3000),
            reason: '截图只有 ${full.lengthSync()} 字节，疑似空图');

        // 菜单面矩形（往外扩一点留白）→ 放大裁图
        final rect = t.getRect(find.text('粘贴源码安装')).expandToInclude(
          t.getRect(find.text('调整顺序')),
        );
        final zoom = rect.inflate(26);
        print('[diag] ${b.name} 菜单面裁切区 = $zoom');
        final cropped = await t.runAsync(() => _crop(
              full,
              zoom,
              'menu_plugin_${b.name}_zoom',
            ));
        print('[shot] ${cropped!.path} (${cropped.lengthSync()} B)');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  // ── ①b 忙碌态（文案变「处理中…」+ 禁用）—— 证明文案没丢 ──
  testWidgets('MENU1b 插件 ⋮ 菜单 · 忙碌态', (t) async {
    await setShotViewport(t, const Size(760, 460));
    await t.pumpWidget(_host(
      Center(
        child: AppMenuButton<String>(
          tooltip: '更多操作',
          iconSize: 18,
          items: _pluginItems(sweeping: true, busy: true),
          onSelected: (_) {},
        ),
      ),
      Brightness.dark,
    ));
    _claim(t);
    await t.tap(find.byType(AppMenuButton<String>));
    await t.pumpAndSettle();
    expect(find.text('处理中…'), findsNWidgets(2),
        reason: '忙碌时「健康检测」与「重新加载」两项文案都该变「处理中…」');
    final full = await saveViewShot(t, 'menu_plugin_busy');
    print('[shot] ${full.path} (${full.lengthSync()} B)');
  });

  // ── ② 「下载」按钮的菜单（showAppMenu，真 DetailPage）───────
  for (final b in Brightness.values) {
    testWidgets('MENU2 下载菜单 · ${b.name}', (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await setShotViewport(t, const Size(1440, 900));
        NetworkStatus.debugProbe = () async => true;
        addTearDown(NetworkStatus.debugResetForTest);

        final key = GlobalKey<State<DetailPage>>();
        await t.pumpWidget(_host(
          DetailPage(key: key, provider: 'cycani', id: '3862', embedded: true),
          b,
        ));
        _claim(t);
        await t.pump(const Duration(milliseconds: 50));
        _claim(t);

        const d = MediaDetail(
          id: '3862',
          title: '无职转生 第三季',
          episodes: <Episode>[
            Episode(id: 'ep-1', title: '第01集'),
            Episode(id: 'ep-2', title: '第02集'),
          ],
        );
        // ignore: avoid_dynamic_calls
        (key.currentState! as dynamic).debugSetDetail(d, episodes: d.episodes);
        for (var i = 0; i < 4; i++) {
          await t.pump(const Duration(milliseconds: 60));
          _claim(t);
        }

        // 找到「下载」那一枚，点开菜单
        final dl = find.ancestor(
            of: find.text('下载'), matching: find.byType(OutlinedButton));
        expect(dl, findsOneWidget, reason: '操作行必须有「下载」这一枚');
        // ★ 按钮几何必须没变（与旁边三枚同档 —— t27_w3 钉着）
        final dlRect = t.getRect(dl);
        print('[diag] ${b.name} 下载按钮几何 = $dlRect');

        await t.tap(dl);
        await t.pumpAndSettle();
        expect(find.text('下载本集'), findsOneWidget, reason: '菜单必须弹得出');
        expect(find.text('下载全部集（2 集）'), findsOneWidget);

        final full = await saveViewShot(t, 'menu_download_${b.name}');
        print('[shot] ${full.path} (${full.lengthSync()} B)');

        // 菜单面 + 按钮一起裁出来（看它们是否同档）
        final rect = t
            .getRect(find.text('下载全部集（2 集）'))
            .expandToInclude(t.getRect(find.text('下载本集')))
            .expandToInclude(dlRect);
        final zoom = rect.inflate(28);
        print('[diag] ${b.name} 下载菜单裁切区 = $zoom');
        final cropped = await t.runAsync(() => _crop(
              full,
              zoom,
              'menu_download_${b.name}_zoom',
            ));
        print('[shot] ${cropped!.path} (${cropped.lengthSync()} B)');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }
}
