// ═══════════════════════════════════════════════════════════════════════
//  123 云盘「账号密码登录」—— 表单门禁（离线）
// ═══════════════════════════════════════════════════════════════════════
//
// # 守什么
// ```text
// ① 表单**只**挂在 123 这一行（其余 8 家不许出现账号密码框 —— 它们没有这条路）
// ② 填什么就传什么：kind/account/password **逐字**进命令（界面不改写用户输入）
// ③ 密码框必须 obscureText（不许明文回显）
// ④ 成功 ⇒ 成功文案 + **就地刷新登录状态**（真状态来自钥匙串链路，不是界面自说自话）
// ⑤ 失败 ⇒ 错误显示在「登录」按钮下方，且**不出现**成功文案
// ⑥ 空输入 ⇒ 不调命令，直接说清缺什么
// ⑦ 源码门禁：命令名 `pan_password_login` 在位、注入点 `debugPasswordLogin` 在位
//    （生产恒 null）、页面不 import dart:io（凭据只进钥匙串，不落盘）
// ```
//
// # 注入纪律
// ```text
// 真登录 = 打 123 的 sign_in + 写系统钥匙串；`flutter test` 里两样都没有
// ⇒ 全部走 `debugPasswordLogin` / `debugPanCredentialStatusFetcher` 两个替身。
// 替身只替**传输**，不替判断。
// ```
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/ffi.dart' show SourinCoreException;
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings/pan_settings_page.dart';

/// 用户会填的一对账号密码（**密码里带空格与符号**：任何 trim/改写都会露出来）
const String kAccount = 'demo@example.com';
const String kPassword = 'p@ss w0rd!';

/// 只含 123 一行的夹具（未登录）
List<PanAccountStatus> accountsOnly123({
  bool loggedIn = false,
  bool expired = false,
  String account = '',
}) =>
    <PanAccountStatus>[
      PanAccountStatus(
        kind: '123',
        kindName: '123 网盘',
        loggedIn: loggedIn,
        expired: expired,
        keyringAvailable: true,
        account: account,
      ),
    ];

/// 不含 123 的夹具（用来证明"表单只挂在 123 行"）
List<PanAccountStatus> accountsWithout123() => const <PanAccountStatus>[
      PanAccountStatus(
        kind: 'quark',
        kindName: '夸克网盘',
        loggedIn: false,
        expired: false,
        keyringAvailable: true,
      ),
      PanAccountStatus(
        kind: 'baidu',
        kindName: '百度网盘',
        loggedIn: false,
        expired: false,
        keyringAvailable: true,
      ),
    ];

Widget host(Widget child) => MaterialApp(
      theme: AppTheme.themeFor(Brightness.dark),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

/// 页面里那几个 key（**逐字**，改一个就是改契约）
const ValueKey<String> kFormKey = ValueKey<String>('pan-password-123-form');
const ValueKey<String> kAccountKey = ValueKey<String>('pan-password-123-account');
const ValueKey<String> kPasswordKey =
    ValueKey<String>('pan-password-123-password');
const ValueKey<String> kSubmitKey = ValueKey<String>('pan-password-123-submit');
const ValueKey<String> kErrorKey = ValueKey<String>('pan-password-123-error');
const ValueKey<String> kOkKey = ValueKey<String>('pan-password-123-ok');

void main() {
  tearDown(() {
    debugPanCredentialStatusFetcher = null;
    debugPasswordLogin = null;
  });

  // ───────────────────────────────────────────────────────────────
  //  ① 表单只挂在 123 行
  // ───────────────────────────────────────────────────────────────
  group('① 表单只挂在 123 这一行', () {
    testWidgets('★★★ 有 123 ⇒ 账号/密码/登录三件套都在，密码框被遮蔽', (t) async {
      debugPanCredentialStatusFetcher = () async => accountsOnly123();
      await t.pumpWidget(host(const PanSettingsBody()));
      await t.pump();

      expect(find.byKey(kFormKey), findsOneWidget,
          reason: '★★★ 123 这一行必须展开成账号密码表单（它没有扫码这条路）');
      expect(find.byKey(kAccountKey), findsOneWidget);
      expect(find.byKey(kPasswordKey), findsOneWidget);
      expect(find.byKey(kSubmitKey), findsOneWidget);
      expect(find.text('登录'), findsOneWidget, reason: '★ 按钮文案就是「登录」');

      final pw = t.widget<TextField>(find.byKey(kPasswordKey));
      expect(pw.obscureText, isTrue,
          reason: '★★★ 密码框必须 obscureText —— 注入「去掉 obscureText」本条立刻红');
    });

    testWidgets('★★★ 没有 123 的行 ⇒ 整页不出现账号密码表单', (t) async {
      debugPanCredentialStatusFetcher = () async => accountsWithout123();
      await t.pumpWidget(host(const PanSettingsBody()));
      await t.pump();

      expect(find.byKey(kFormKey), findsNothing,
          reason: '★★★ 其余盘（夸克/百度…）**没有**密码登录这条路 ⇒ 不许出现表单；'
              '注入「把 if (a.kind == "123") 去掉」本条立刻红');
      expect(find.byKey(kAccountKey), findsNothing);
      expect(find.byKey(kPasswordKey), findsNothing);
      expect(find.byKey(kSubmitKey), findsNothing);
    });
  });

  // ───────────────────────────────────────────────────────────────
  //  ② 参数逐字 + 成功文案 + 就地刷新
  // ───────────────────────────────────────────────────────────────
  group('② 输入 → 点登录 → 参数逐字 + 成功文案 + 状态刷新', () {
    testWidgets('★★★ 调到的 kind/account/password 逐字；成功后真的重拉登录状态',
        (t) async {
      final calls = <List<String>>[];
      var statusFetches = 0;
      debugPanCredentialStatusFetcher = () async {
        statusFetches++;
        // 第一次：未登录；登录成功之后：123 已登录
        if (statusFetches == 1) return accountsOnly123();
        return accountsOnly123(
          loggedIn: true,
          account: kAccount,
        );
      };
      debugPasswordLogin = (kind, account, password) async {
        calls.add(<String>[kind, account, password]);
        return PanPasswordLoginResult(ok: true, account: account);
      };

      await t.pumpWidget(host(const PanSettingsBody()));
      await t.pump();
      expect(statusFetches, 1, reason: '首屏读一次登录状态');

      await t.enterText(find.byKey(kAccountKey), kAccount);
      await t.enterText(find.byKey(kPasswordKey), kPassword);
      await t.tap(find.byKey(kSubmitKey));
      await t.pump();
      await t.pump();

      expect(calls.length, 1, reason: '★ 点一次只调一次');
      expect(calls.single[0], '123',
          reason: '★★★ kind 必须是 123（`PanKind::Pan123.code()`）');
      expect(calls.single[1], kAccount,
          reason: '★★★ 账号必须**逐字**传（界面不许 trim/改写）');
      expect(calls.single[2], kPassword,
          reason: '★★★ 密码必须**逐字**传（"$kPassword" 带空格与感叹号）');

      expect(find.byKey(kOkKey), findsOneWidget, reason: '★ 成功要有一句文案');
      expect(find.textContaining('登录成功'), findsOneWidget);
      expect(find.text('登录成功：$kAccount'), findsOneWidget,
          reason: '★ 成功文案带上账号名（用户要知道登的是哪个）');

      expect(statusFetches, 2,
          reason: '★★★ 成功后必须**就地刷新登录状态**（凭据已落盘，状态要读回来）；'
              '注入「成功后不调 _loadStatuses」本条立刻红');
      expect(find.byKey(const ValueKey<String>('pan-account-tier-123')),
          findsOneWidget);
      expect(
        t
            .widget<Text>(
                find.byKey(const ValueKey<String>('pan-account-tier-123')))
            .data,
        contains('已登录123 网盘'),
        reason: '★★ 刷新后这一行必须显示已登录（真状态来自钥匙串夹具，不是界面自说自话）',
      );
    });

    testWidgets('★★ 成功后密码框被清空（不在内存/界面里多留一份）', (t) async {
      debugPanCredentialStatusFetcher = () async => accountsOnly123();
      debugPasswordLogin = (kind, account, password) async =>
          PanPasswordLoginResult(ok: true, account: account);

      await t.pumpWidget(host(const PanSettingsBody()));
      await t.pump();
      await t.enterText(find.byKey(kAccountKey), kAccount);
      await t.enterText(find.byKey(kPasswordKey), kPassword);
      await t.tap(find.byKey(kSubmitKey));
      await t.pump();
      await t.pump();

      final field = t.widget<TextField>(find.byKey(kPasswordKey));
      expect(field.controller?.text, isEmpty,
          reason: '★ 成功后密码框要清空（与"别把密码留在内存里"同一条纪律）');
    });
  });

  // ───────────────────────────────────────────────────────────────
  //  ③ 失败 ⇒ 错误在按钮下方，且没有成功文案
  // ───────────────────────────────────────────────────────────────
  group('③ 失败文案', () {
    testWidgets('★★★ 登录失败 ⇒ 显示后端那句可读错误（在按钮下方），不显示成功',
        (t) async {
      debugPanCredentialStatusFetcher = () async => accountsOnly123();
      // Rust 侧失败是**抛**（错误里带 HTTP 码 + 响应摘要，不含密码）
      debugPasswordLogin = (kind, account, password) async =>
          throw SourinCoreException(
              '123 云盘账号密码登录没成功（两套报文都试过了）\n'
              '① passport（判定 message == "success"）：HTTP 401，响应：{"message":"密码错误"}\n'
              '② mail（判定 code == 200）：HTTP 200，响应：{"code":1001}',
              'other');

      await t.pumpWidget(host(const PanSettingsBody()));
      await t.pump();
      await t.enterText(find.byKey(kAccountKey), kAccount);
      await t.enterText(find.byKey(kPasswordKey), kPassword);
      await t.tap(find.byKey(kSubmitKey));
      await t.pump();
      await t.pump();

      final err = find.byKey(kErrorKey);
      expect(err, findsOneWidget,
          reason: '★★★ 失败必须显示原因；注入「catch 里吞掉异常」本条立刻红');
      final txt = t.widget<Text>(err).data ?? '';
      expect(txt, contains('HTTP 401'),
          reason: '★★ 后端给的 HTTP 码要透出来（否则用户只会看到一句废话）');
      expect(txt, contains('密码错误'), reason: '★ 服务端原话要透出来');
      expect(txt.contains(kPassword), isFalse,
          reason: '★★★ 错误文案里绝不许出现密码');

      expect(find.byKey(kOkKey), findsNothing, reason: '★ 失败时不许有成功文案');
      expect(find.textContaining('登录成功'), findsNothing);
    });

    testWidgets('★★ 空账号 / 空密码 ⇒ 不调命令，直接说缺什么', (t) async {
      var calls = 0;
      debugPanCredentialStatusFetcher = () async => accountsOnly123();
      debugPasswordLogin = (kind, account, password) async {
        calls++;
        return PanPasswordLoginResult(ok: true, account: account);
      };

      await t.pumpWidget(host(const PanSettingsBody()));
      await t.pump();

      // 账号空
      await t.tap(find.byKey(kSubmitKey));
      await t.pump();
      expect(calls, 0, reason: '★ 账号没填就不该发请求');
      expect(t.widget<Text>(find.byKey(kErrorKey)).data, contains('账号'));

      // 只填账号 ⇒ 密码空
      await t.enterText(find.byKey(kAccountKey), kAccount);
      await t.tap(find.byKey(kSubmitKey));
      await t.pump();
      expect(calls, 0, reason: '★ 密码没填也不该发请求');
      expect(t.widget<Text>(find.byKey(kErrorKey)).data, contains('密码'));
    });
  });

  // ───────────────────────────────────────────────────────────────
  //  ④ 源码门禁（命令名 / 注入点 / 不 import dart:io）
  // ───────────────────────────────────────────────────────────────
  group('④ 源码门禁', () {
    test('★★ 命令名 `pan_password_login` 与 Dart 封装在位', () {
      final api = File('lib/core/sourin_api.dart').readAsStringSync();
      expect(api.contains("'pan_password_login'"), isTrue,
          reason: '★★ 命令名必须逐字（Rust ffi.rs 的分派表认的就是这个串）');
      expect(api.contains('panPasswordLogin'), isTrue);
      for (final p in const ["'kind'", "'account'", "'password'"]) {
        expect(api.contains(p), isTrue, reason: '★ 参数名 $p 必须逐字（args 按名取）');
      }
    });

    test('★★ 注入点 `debugPasswordLogin` 在位，且生产路径走 SourinApi', () {
      final src =
          File('lib/ui/settings/pan_settings_page.dart').readAsStringSync();
      expect(src.contains('debugPasswordLogin'), isTrue,
          reason: '★ 门禁注入点必须能离线喂（flutter test 里没有 dll）');
      expect(src.contains('SourinApi.panPasswordLogin'), isTrue,
          reason: '★ 生产路径必须走真命令（替身为 null 时）');
      expect(src.contains('obscureText: true'), isTrue,
          reason: '★★ 密码框遮蔽是**源码级**要求（widget 断言之外的二道闸）');
    });

    test('★★ 页面不 import dart:io（凭据只进钥匙串，绝不落盘）', () {
      final src =
          File('lib/ui/settings/pan_settings_page.dart').readAsStringSync();
      expect(src.contains("import 'dart:io'"), isFalse,
          reason: '★★★ 本页不许碰文件系统 —— 数据目录会被备份/云同步，'
              'cookie 落盘就跟着到处跑');
    });
  });
}
