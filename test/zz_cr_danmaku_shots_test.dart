// 弹幕设置面板的**看图台**（自用，不是断言型测试）—— 改前/改后各出一张图给人眼看。
//
// 跑法：
//   $env:SOURIN_SHOT_DIR = '.probe\shots'
//   flutter test test/zz_cr_danmaku_shots_test.dart --concurrency=1
//
// ⚠️ 本文件**只**依赖面板本身（不吃 FFI 核心），flutter_tester 里能跑。
// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';

import 'support/ui_shot.dart';

DanmakuSettingsState _state({int count = 111}) => DanmakuSettingsState(
      enabled: true,
      appId: '',
      appSecret: '',
      fontScale: 1.0,
      opacity: 0.9,
      speed: 1.0,
      area: 0.5,
      count: count,
      lanes: 6,
      dropped: 12,
      status: '外部视频站 · 新增 111 条，共 111 条',
      sourceLine: '本机未探测到外部弹幕服务',
    );

Future<void> _pump(WidgetTester t, Widget child) async {
  await setShotViewport(t, const Size(700, 1000));
  await t.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeFor(Brightness.dark),
    builder: (context, c) => AppThemeHost(
      data: AppTheme.themeFor(Brightness.dark),
      child: c ?? const SizedBox(),
    ),
    home: Scaffold(
      backgroundColor: const Color(0xFF101014),
      body: Center(
        child: SizedBox(width: 560, child: child),
      ),
    ),
  ));
  await t.pumpAndSettle();
}

Widget _dialog(DanmakuSettingsState s) => DanmakuSettingsDialog(
      state: s,
      onSetEnabled: (_) {},
      onSetFontScale: (_) {},
      onSetOpacity: (_) {},
      onSetSpeed: (_) {},
      onSetArea: (_) {},
      onReload: () {},
      onClose: () {},
      fill: false,
    );

void main() {
  setUpAll(loadRealFonts);

  testWidgets('弹幕面板 改前/改后 对照图', (t) async {
    await _pump(t, _dialog(_state()));
    await saveViewShot(t, 'danmaku_panel');
  });
}
