// task-66 任务 B：弹幕发送栏**玻璃化**截图（人工目检用）
//
// 跑法：
//   SOURIN_SHOT_DIR=.probe/shots_t66b \
//     flutter test test/zz_t66b_send_glass_shots_test.dart \
//     --run-skipped --tags needs-shot-dir --concurrency=1
@Tags(<String>['needs-shot-dir'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/player/player_bottom_bar.dart';

import 'support/ui_shot.dart';

Widget _host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        /*
         * 用一个有明暗变化的背景 —— 玻璃材质的效果**必须有东西可透**，
         * 纯色底上看不出任何差别（那就等于没验证）。
         */
        body: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[Color(0xFF1B2340), Color(0xFF0B0D12)],
            ),
          ),
          child: Center(
            child: RepaintBoundary(
              key: const ValueKey<String>('page'),
              child: SizedBox(width: 560, child: child),
            ),
          ),
        ),
      ),
    );

DanmakuSendInline _send({
  String debugInitialText = '',
  bool sending = false,
}) =>
    DanmakuSendInline(
      provider: 'demo',
      episodeId: 'ep1',
      positionMs: () => 1000,
      onSend: (text, ms) async {
        if (sending) {
          await Future<void>.delayed(const Duration(seconds: 30));
        }
        return null;
      },
      debugInitialText: debugInitialText,
    );

void main() {
  setUpAll(loadRealFonts);

  testWidgets('发送栏 · 空态（玻璃 + 原生输入框）', (t) async {
    await setShotViewport(t, const Size(760, 320));
    await t.pumpWidget(_host(_send()));
    await t.pumpAndSettle();
    await saveViewShot(t, 't66b_send_empty');
    print('[SHOT] t66b_send_empty');
  });

  testWidgets('发送栏 · 有字（发送按钮激活）', (t) async {
    await setShotViewport(t, const Size(760, 320));
    await t.pumpWidget(_host(_send(debugInitialText: '这一段打斗真好看')));
    await t.pumpAndSettle();
    await saveViewShot(t, 't66b_send_filled');
    print('[SHOT] t66b_send_filled');
  });

  testWidgets('发送栏 · 聚焦态（外框提亮）', (t) async {
    await setShotViewport(t, const Size(760, 320));
    await t.pumpWidget(_host(_send()));
    await t.pumpAndSettle();
    await t.tap(find.byType(TextField));
    await t.pumpAndSettle();
    await saveViewShot(t, 't66b_send_focused');
    print('[SHOT] t66b_send_focused');
  });

  testWidgets('发送栏 · 失败提示', (t) async {
    await setShotViewport(t, const Size(760, 320));
    await t.pumpWidget(_host(DanmakuSendInline(
      provider: 'demo',
      episodeId: 'ep1',
      positionMs: () => 1000,
      onSend: (text, ms) async => '这个源不支持发送弹幕',
      debugInitialText: '发不出去的一句话',
    )));
    await t.pumpAndSettle();
    await t.tap(find.text('发送'));
    await t.pumpAndSettle();
    await saveViewShot(t, 't66b_send_error');
    print('[SHOT] t66b_send_error');
  });
}
