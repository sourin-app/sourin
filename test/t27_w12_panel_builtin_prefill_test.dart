import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart'; // 面板宿主同 t100：material_ui 的 MaterialApp 才带 Material 祖先
import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';

/// T27-12：面板内置凭证收口（task-12）。
///
/// ★ 2026-10-11（Owner 反馈）现状：面板上的 AppId / AppSecret 输入框**整节删除**，
///   因为客户端已内置官方凭证（构建期 `--dart-define` 注入）。本文件随之改写：
///   ① 不再断言输入框/预填（那一节已不存在）；
///   ② 保留对**签名链路**（`DanmakuConfig` getter / `usingBuiltin*` / 优先级）
///      的锁定 —— 那才是"内置生效"的真相，不随 UI 删除而改变；
///   ③ 状态行断言改为"不再把用户指去输入框填凭证"。

Widget dialogHost(DanmakuSettingsState state) => MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Stack(
          children: <Widget>[
            DanmakuSettingsDialog(
              state: state,
              onSetEnabled: (_) {},
              onSetFontScale: (_) {},
              onSetOpacity: (_) {},
              onSetSpeed: (_) {},
              onSetArea: (_) {},
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

  group('① 面板不再有凭证输入 UI（删除后）', () {
    test('fromPrefs() 仍是纯 UI 状态；签名链路读的是 DanmakuConfig 生效值', () {
      DanmakuConfig.debugSetBuiltin(appId: 'xgmriqmqcq', appSecret: 's3cret');
      // 生效值非空（签名链路照常用内置）—— 与面板 UI 无关，面板也不再显示它。
      expect(DanmakuConfig.appId, 'xgmriqmqcq');
      expect(DanmakuConfig.appSecret, 's3cret');
      expect(DanmakuConfig.isConfigured, isTrue);
      expect(DanmakuConfig.usingBuiltinAppId, isTrue);
    });
  });

  group('② 用户覆盖优先于内置（签名链路语义不变）', () {
    test('同环境 + setAppId(myid) ⇒ 生效值取用户覆盖', () {
      DanmakuConfig.debugSetBuiltin(appId: 'xgmriqmqcq', appSecret: 's3cret');
      DanmakuConfig.setAppId('myid');
      expect(DanmakuConfig.appId, 'myid'); // 覆盖半边生效
      expect(DanmakuConfig.appSecret, 's3cret'); // 未覆盖半边仍走内置
      expect(DanmakuConfig.usingBuiltinAppId, isFalse);
      expect(DanmakuConfig.usingBuiltinAppSecret, isTrue);
    });
  });

  group('③ 状态行不再把用户指去输入框（真树渲染）', () {
    testWidgets('内置生效 ⇒ 面板不含 AppId/AppSecret 输入框，状态行说内置', (t) async {
      DanmakuConfig.debugSetBuiltin(appId: 'xgmriqmqcq', appSecret: 's3cret');
      DanmakuConfig.setEnabled(true);
      await pumpPanel(t, DanmakuSettingsState.fromPrefs());
      // 凭证输入框已删除：面板里再也找不到这两个 label。
      expect(find.text('AppId'), findsNothing);
      expect(find.text('AppSecret'), findsNothing);
      // 状态行如实说在用内置凭证；且**不再**出现「还没填」这种不存在的指引。
      expect(find.textContaining('还没填'), findsNothing,
          reason: '输入框已删，状态行不能再叫用户去"填"');
      expect(find.textContaining('内置凭证'), findsWidgets);
    });
  });

  group('④ 无内置 + 无覆盖 ⇒ 状态行不再谎称"去填凭证"', () {
    test('core 的 statusText 原样保留（它描述"有没有凭证"，仍成立）', () {
      DanmakuConfig.debugSetBuiltin(); // 恢复读 const（无注入构建 == 无内置）
      DanmakuConfig.setEnabled(true); // statusText 要求开着（reset 后缺省关）
      expect(DanmakuConfig.hasBuiltinCredentials, isFalse);
      expect(DanmakuConfig.isConfigured, isFalse);
      expect(DanmakuConfig.statusText, '弹幕已开启，但还没填 AppId / AppSecret');
    });

    testWidgets('面板状态行改口径：说"凭证未就绪 + 两条免凭证的路"，不说"还没填"',
        (t) async {
      DanmakuConfig.debugSetBuiltin();
      DanmakuConfig.setEnabled(true);
      await pumpPanel(t, DanmakuSettingsState.fromPrefs());
      expect(find.textContaining('还没填'), findsNothing,
          reason: '面板上已无输入框，不能再说"还没填 AppId / AppSecret"');
      expect(find.textContaining('凭证未就绪'), findsWidgets);
    });
  });

  group('⑤ 源码契约', () {
    test('凭证输入节删除 + 数据源行保留 + player_page 红线继续有效', () {
      final dlg =
          File('lib/ui/widgets/danmaku_settings_dialog.dart').readAsStringSync();
      final pp = File('lib/ui/player_page.dart').readAsStringSync();

      // 凭证节相关标识符全部消失（回调 / 输入框 / 删除按钮 / 预填逻辑）。
      expect(dlg.contains('onSetAppId'), isFalse,
          reason: '面板不再有凭证回调（输入框已删）');
      expect(dlg.contains('onSetAppSecret'), isFalse);
      expect(dlg.contains('onClearCredentials'), isFalse);
      expect(dlg.contains("labelText: 'AppId'"), isFalse);
      expect(dlg.contains("labelText: 'AppSecret'"), isFalse);
      expect(dlg.contains('清除凭证'), isFalse);
      // usingBuiltinAppId 仍在 `_statusText` 里（状态行如实说"用的是内置"），
      // 但**不再**出现在任何预填/渲染逻辑里 —— 冻结调用点数量以防回归。
      expect('usingBuiltinAppId'.allMatches(dlg).length, 1,
          reason: 'usingBuiltinAppId 只该在 _statusText 出现一次（状态展示）');
      expect(dlg.contains('usingBuiltinAppSecret'), isFalse,
          reason: 'usingBuiltinAppSecret 已无用处（预填逻辑删除）');

      // 数据源行必须还在（删的是凭证节，不是它）。
      expect(dlg.contains('数据源'), isTrue,
          reason: '「数据源」状态行保留（T27-05）');

      // player_page 红线（task-10 起持续有效）
      expect(pp.contains('builtinAppId'), isFalse,
          reason: 'player_page 绝不许动（w6-live 在改）');
      expect(pp.contains('usingBuiltinAppId'), isFalse);
    });
  });
}
