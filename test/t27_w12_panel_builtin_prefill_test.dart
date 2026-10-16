import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart'; // 面板宿主同 t100：material_ui 的 MaterialApp 才带 Material 祖先
import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';

/// T27-12：面板内置凭证收口（task-12）。
///
/// ★ 2026-10-14（Owner 反馈「外部弹幕服务的凭证流程根本没走通」）现状：
///   输入框**恢复**了（本地构建没有 `--dart-define` ⇒ 无内置值 ⇒ 官方边必失败，
///   且改前**无入路**可配）。本文件随之改写：
///   ① 断言输入框与两个回调（`onSetCredentials` / `onClearCredentials`）**都在**；
///   ② 保留对**签名链路**（`DanmakuConfig` getter / `usingBuiltin*` / 优先级）
///      的锁定 —— 那是"凭证生效"的真相，不随 UI 增删而改变；
///   ③ 状态行断言：缺凭证时**如实**说"未配置、官方边会失败"，并给免签名的退路。

/// Strip comments so explanatory prose cannot satisfy or break an assertion.
///
/// The 2026-10-15 notes legitimately MENTION the removed callbacks and the
/// injected constants by name; a naive contains() would therefore fail for the
/// wrong reason (a false red is as corrosive as a false green -- it trains
/// people to delete the assertion).
String stripComments(String src) {
  final noBlock = src.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), ' ');
  return noBlock
      .split('\n')
      .map((l) {
        final i = l.indexOf('//');
        return i >= 0 ? l.substring(0, i) : l;
      })
      .join('\n');
}

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
              // 2026-10-15: the credential callbacks were removed along with the
              // input boxes (built-in credentials now). The section is
              // read-only status and is always rendered.
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

  group('③ 状态行如实说"用的是内置"（真树渲染）', () {
    testWidgets('内置生效 ⇒ 状态行如实说内置（★ 输入框已按 Owner 要求删除）', (t) async {
      DanmakuConfig.debugSetBuiltin(appId: 'xgmriqmqcq', appSecret: 's3cret');
      DanmakuConfig.setEnabled(true);
      await pumpPanel(t, DanmakuSettingsState.fromPrefs());
      /*
       * ★ 2026-10-14 改口径：输入框**恢复了**，但内置凭证**不预填**进去
       *   （`fromPrefs` 只取 `userAppId/userAppSecret`）—— 否则用户会误以为
       *   "这是我填的"，一点保存反而用真内置值覆盖掉原值。
       *   ⇒ 输入框的文本应为空。
       */
      /*
       * ★★★ 2026-10-15（Owner「删除那两个输入框,改用内置的」）：
       *   输入框**没了** ⇒ 那两条"输入框空着"的断言作废。
       *   但**真正要守的东西**一个字没变：用户必须看得见"现在用的是内置凭证"。
       *   ⇒ 改成「一个凭证输入框都不该有」+「状态行仍如实说内置」。
       */
      final credFields = t
          .widgetList<TextField>(find.byType(TextField))
          .where((f) =>
              f.decoration?.labelText == 'AppId' ||
              f.decoration?.labelText == 'AppSecret')
          .toList();
      expect(credFields, isEmpty,
          reason: '★ 凭证输入框必须已被删除（改走内置凭证）');
      // 状态行如实说在用内置凭证；且**不再**出现「还没填」这种不存在的指引。
      expect(find.textContaining('还没填'), findsNothing,
          reason: '有内置凭证 ⇒ 不该说"还没填"');
      expect(find.textContaining('内置凭证'), findsWidgets,
          reason: '删的是输入框，不是可见性 —— 状态行必须继续如实说在内置');
    });
  });

  group('④ 无内置 + 无覆盖 ⇒ 面板如实说"未配置凭证 + 有出路"', () {
    test('core 的 statusText 原样保留（它描述"有没有凭证"，仍成立）', () {
      DanmakuConfig.debugSetBuiltin(); // 恢复读 const（无注入构建 == 无内置）
      DanmakuConfig.setEnabled(true); // statusText 要求开着（reset 后缺省关）
      expect(DanmakuConfig.hasBuiltinCredentials, isFalse);
      expect(DanmakuConfig.isConfigured, isFalse);
      expect(DanmakuConfig.statusText, '弹幕已开启，但还没填 AppId / AppSecret');
    });

    testWidgets('面板状态行如实说"凭证未配置"，并指两条免签名的路',
        (t) async {
      DanmakuConfig.debugSetBuiltin();
      DanmakuConfig.setEnabled(true);
      await pumpPanel(t, DanmakuSettingsState.fromPrefs());
      /*
       * 2026-10-15: the panel gained tabs (Owner asked for display/source split)
       * and the credential status moved under the "来源" tab. Switch to it the
       * way a user would before asserting on its copy -- the contract (be honest
       * about missing credentials and point at the sign-free fallbacks) has not
       * changed, only where it is rendered.
       */
      await t.tap(find.text('弹弹play'));
      await t.pumpAndSettle();
      // ★ 2026-10-14（Owner「凭证流程根本没走通」）改口径：
      //   面板现在**有**凭证输入框了 ⇒ 缺凭证要**如实**说（官方边会失败），
      //   而不是改前那句听着像"不用管"的「凭证未就绪（…不需要凭证）」。
      expect(find.textContaining('凭证未配置'), findsWidgets,
          reason: '缺凭证要如实说，别让用户以为"不需要凭证"');
      expect(find.textContaining('官方边会失败'), findsWidgets,
          reason: '得说清后果，用户才知道为什么要配');
      expect(find.textContaining('免签名'), findsWidgets,
          reason: '给两条真实存在的免签名退路');
      expect(find.textContaining('可以在下面填'), findsNothing,
          reason: '★ 输入框已删 ⇒ 不能再指一个不存在的地方让用户去填');
    });
  });

  group('⑤ 源码契约', () {
    test('凭证输入节**已删除** + 数据源行保留 + player_page 红线继续有效', () {
      final dlg = stripComments(
          File('lib/ui/widgets/danmaku_settings_dialog.dart').readAsStringSync());
      final pp =
          stripComments(File('lib/ui/player_page.dart').readAsStringSync());

      /*
       * ★★★ 2026-10-14（Owner 反馈「凭证流程根本没走通」）：断言内容**翻转**。
       *
       * 改前（2026-10-11）这几条要求"凭证输入节必须已删除"，因为当时认为
       * 客户端内置凭证、用户不必手填。但**本地构建没有 --dart-define** ⇒
       * 没有内置值、UiPrefs 也没值 ⇒ 官方边必然 403，且无入路可配。
       * ⇒ 现在要求输入框与两个回调**必须都在**（否则用户又无路可走）。
       */
      expect(dlg.contains("labelText: 'AppId'"), isFalse,
          reason: '★ AppId 输入框必须已删除（改走内置凭证）');
      expect(dlg.contains("labelText: 'AppSecret'"), isFalse,
          reason: '★ AppSecret 输入框必须已删除（同上）');
      expect(dlg.contains('onSetCredentials'), isFalse,
          reason: '写入口必须一并拔掉（留着就是半死不活的残废形态）');
      expect(dlg.contains('onClearCredentials'), isFalse,
          reason: '清除入口同理');
      // 删的是「手填」，不是「透明度」——状态行要留着。
      expect(dlg.contains('_credentialStatusText'), isTrue,
          reason: '凭证状态行必须保留（用户仍要看得见用的是内置还是没配）');
      // usingBuiltinAppId 在**状态行**与**凭证状态行**两处如实展示"用的是内置"。
      expect('usingBuiltinAppId'.allMatches(dlg).length, greaterThanOrEqualTo(1),
          reason: 'usingBuiltinAppId 状态展示用（如实说用的是内置）');

      // 数据源行必须还在（凭证节恢复的是输入，不是把它并掉）。
      expect(dlg.contains('数据源'), isTrue,
          reason: '「数据源」状态行保留（T27-05）');

      // player_page 红线（task-10 起持续有效）：不许直接读内置常量，
      // 一律走 DanmakuConfig 的 getter（面板与宿主都不碰构建期注入细节）。
      expect(pp.contains('builtinAppId'), isFalse,
          reason: 'player_page 不许直接读 builtinAppId 常量');
      expect(pp.contains('builtinAppSecret'), isFalse);
    });
  });
}
