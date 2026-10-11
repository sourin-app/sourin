import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart'; // 面板宿主同 t100：material_ui 的 MaterialApp 才带 Material 祖先
import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';

/// T27-12：面板内置凭证预填收口（task-12）。
///
/// 矛盾：fromPrefs() 取生效值 ⇒ 内置生效时面板把内置 AppId 明文预填，
/// 与同屏「留空则用内置凭证」状态行打架。修法只动面板初值 + 状态行：
/// DanmakuConfig 的 getter 语义一个不许动（DandanplayClient 构造来源）。

Widget dialogHost(DanmakuSettingsState state) => MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Stack(
          children: <Widget>[
            DanmakuSettingsDialog(
              state: state,
              onSetEnabled: (_) {},
              onSetAppId: (_) {},
              onSetAppSecret: (_) {},
              onSetFontScale: (_) {},
              onSetOpacity: (_) {},
              onSetSpeed: (_) {},
              onSetArea: (_) {},
              onClearCredentials: () {},
              onReload: () {},
              onClose: () {},
            ),
          ],
        ),
      ),
    );

Future<void> pumpPanel(WidgetTester t, DanmakuSettingsState s) async {
  // 卡片 maxHeight 620 ⇒ 默认 800x600 装不下，放大视口（同 t103）
  t.view.physicalSize = const Size(1200, 1600);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(dialogHost(s));
  await t.pump();
}

void main() {
  setUp(() {
    UiPrefs.debugResetForTest(<String, String>{});
    DanmakuConfig.debugSetBuiltin(); // 回到缺省（读 const）
  });

  tearDown(() {
    DanmakuConfig.debugSetBuiltin();
    UiPrefs.debugResetForTest(<String, String>{});
  });

  group('① 内置生效时面板不预填', () {
    test('debugSetBuiltin + UiPrefs 两键清空 ⇒ fromPrefs() 两格都是空串', () {
      DanmakuConfig.debugSetBuiltin(appId: 'xgmriqmqcq', appSecret: 's3cret');
      // 生效值非空（签名链路照常用内置），但面板初值必须为空
      expect(DanmakuConfig.appId, 'xgmriqmqcq');
      expect(DanmakuConfig.appSecret, 's3cret');
      final s = DanmakuSettingsState.fromPrefs();
      expect(s.appId, '');
      expect(s.appSecret, '');
    });
  });

  group('② 用户覆盖照样预填', () {
    test('同环境 + setAppId(myid) ⇒ fromPrefs().appId == myid', () {
      DanmakuConfig.debugSetBuiltin(appId: 'xgmriqmqcq', appSecret: 's3cret');
      DanmakuConfig.setAppId('myid');
      final s = DanmakuSettingsState.fromPrefs();
      expect(s.appId, 'myid'); // 覆盖半边照常预填
      expect(s.appSecret, ''); // 未覆盖半边仍不预填（内置在生效）
    });
  });

  group('③ 内置生效 + 面板两格空 ⇒ 状态行如实说内置（真树渲染）', () {
    testWidgets('状态行不含「还没填」、含「内置凭证」', (t) async {
      DanmakuConfig.debugSetBuiltin(appId: 'xgmriqmqcq', appSecret: 's3cret');
      DanmakuConfig.setEnabled(true);
      await pumpPanel(t, DanmakuSettingsState.fromPrefs());
      expect(find.textContaining('还没填'), findsNothing,
          reason: '内置生效时面板两格是空的，但状态行不许再说「还没填」');
      expect(find.textContaining('内置凭证'), findsWidgets);
    });
  });

  group('④ 无内置 + 无覆盖 ⇒ 旧文案逐字回归', () {
    test('fromPrefs().appId 空 + statusText 仍是「还没填」', () {
      DanmakuConfig.debugSetBuiltin(); // 恢复读 const（无注入构建 == 无内置）
      DanmakuConfig.setEnabled(true); // statusText 要求开着（reset 后缺省关）
      expect(DanmakuConfig.hasBuiltinCredentials, isFalse);
      final s = DanmakuSettingsState.fromPrefs();
      expect(s.appId, '');
      expect(DanmakuConfig.statusText, '弹幕已开启，但还没填 AppId / AppSecret');
    });
  });

  group('⑤ 源码契约', () {
    test('状态行走内置分支 + player_page 红线继续有效', () {
      final dlg =
          File('lib/ui/widgets/danmaku_settings_dialog.dart').readAsStringSync();
      final pp = File('lib/ui/player_page.dart').readAsStringSync();

      // fromPrefs 两半边都用 usingBuiltin* 判预填
      expect('usingBuiltinAppId'.allMatches(dlg).length,
          greaterThanOrEqualTo(1),
          reason: 'appId 初值必须用 usingBuiltinAppId 判是否预填');
      expect('usingBuiltinAppSecret'.allMatches(dlg).length,
          greaterThanOrEqualTo(1),
          reason: 'appSecret 初值必须用 usingBuiltinAppSecret 判是否预填');

      expect(dlg.contains('内置凭证 AppId'), isTrue,
          reason: '_statusText 要有内置在生效的分支文案');

      // player_page 红线（task-10 起持续有效）
      expect(pp.contains('builtinAppId'), isFalse,
          reason: 'player_page 绝不许动（w6-live 在改）');
      expect(pp.contains('usingBuiltinAppId'), isFalse);
    });
  });
}
