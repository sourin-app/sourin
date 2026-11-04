// ═══════════════════════════════════════════════════════════════════════
//  t1050：网盘账号配置页（N8b-3）—— 登录态 / 扫码 / 列目录 / 反假绿
// ═══════════════════════════════════════════════════════════════════════
//
// # 守什么
// ```text
// ① 分档纯函数：未登录先于过期（round33c 教训），文案与 Rust reason_text 逐字
// ② 登录状态列表：**只**用注入的钥匙串夹具驱动，"已登录"绝不能凭空出现；
//    登出只对有凭据的行出现，点了真会刷新
// ③ 反假绿：什么都不注入（flutter test 没有 dll）⇒ 页面如实报"没读到"，
//    **全页找不到"已登录"三个字** —— 把"没读到的状态冒充已登录"钉死
// ④ 扫码：QrView 复用（不是重造），pending→scanned→confirmed 走完，
//    confirmed 后真的重新拉一次登录状态；expired 是终态且给"重新获取"
// ⑤ 列目录：复用 PanShareListingSection，整页没有任何播放入口
// ⑥ 源码门禁：页面不 import dart:io（凭据绝不落盘）、注入点在位、入口函数在位
// ```
//
// # 注入纪律
// ```text
// 涉及"已登录"的用例全部走 debugPanCredentialStatusFetcher（钥匙串链路的替身）
// —— 不是把页面字段 setState 成"看起来登录了"。生产恒 null 的注入点，
// 生产路径走 pan_auth_status / pan_qr_login_* / pan_logout。
// ```
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/design/widgets/app_text_button.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings/pan_settings_page.dart';
import 'package:sourin_spike/ui/widgets/pan_share_dialog.dart'
    show PanShareListingSection;
import 'package:sourin_spike/ui/widgets/qr_view.dart';

/// 钥匙串夹具：三个盘三种档位（字段与 `pan_auth_status` 契约逐字对应）
List<PanAccountStatus> fixtureAccounts() => <PanAccountStatus>[
      const PanAccountStatus(
        kind: 'quark',
        kindName: '夸克网盘',
        loggedIn: true,
        expired: false,
        keyringAvailable: true,
        account: '小影',
      ),
      const PanAccountStatus(
        kind: 'uc',
        kindName: 'UC 网盘',
        loggedIn: true,
        expired: true,
        keyringAvailable: true,
        account: '小影',
      ),
      const PanAccountStatus(
        kind: 'baidu',
        kindName: '百度网盘',
        loggedIn: false,
        expired: false,
        keyringAvailable: true,
      ),
    ];

/// 一段能被 QrView 解析的最小二维码 SVG（结构与 qrcode crate 输出同形）
const String qrSvgFixture =
    '<svg viewBox="0 0 21 21"><rect width="21" height="21" fill="#ffffff"/>'
    '<path fill="#0b0d12" d="M0 0h1v1H0V1M2 0h1v1H2V1"/></svg>';

Widget host(Widget child) => MaterialApp(
      theme: AppTheme.themeFor(Brightness.dark),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  tearDown(() {
    debugPanCredentialStatusFetcher = null;
    debugPanQrLoginStarter = null;
    debugPanQrLoginPoller = null;
    debugPanLogoutCaller = null;
    debugPanIdentifyFetcher = null;
    SourinApi.debugPanListShareFetcher = null;
  });

  group('① 分档纯函数：顺序即优先级 + 文案逐字', () {
    test('★★★ 未登录必须先判（round33c 教训）：loggedIn=false 且 expired=true ⇒ 未登录',
        () {
      expect(
        panAccountTierOf(loggedIn: false, expired: true),
        PanAccountTier.needLogin,
        reason: '★★★ 从未登录过的盘不许报"已过期"——'
            '注入「把过期判断挪到未登录前面」本条立刻红',
      );
    });

    test('★★ 过期与已登录的判档', () {
      expect(panAccountTierOf(loggedIn: true, expired: true),
          PanAccountTier.expired);
      expect(panAccountTierOf(loggedIn: true, expired: false),
          PanAccountTier.loggedInNoDirectLink);
    });

    test('★★ 三档文案与 Rust pan::reason_text 的 ③④⑤ 档逐字一致', () {
      expect(panAccountTierText(PanAccountTier.needLogin, '夸克网盘'),
          '需要先登录夸克网盘');
      expect(panAccountTierText(PanAccountTier.expired, 'UC 网盘'),
          'UC 网盘的登录已过期，请重新登录');
      expect(
          panAccountTierText(
              PanAccountTier.loggedInNoDirectLink, '夸克网盘'),
          '已登录夸克网盘（应用已读取保存的凭据）');
    });
  });

  group('② 登录状态列表：注入夹具驱动，登出是真的', () {
    testWidgets('★★★ 三档逐字渲染；账号名透出；登出按钮只给有凭据的行',
        (t) async {
      debugPanCredentialStatusFetcher = () async => fixtureAccounts();
      await t.pumpWidget(host(const PanSettingsBody()));
      await t.pump();

      expect(find.byKey(const ValueKey<String>('pan-status-accounts')),
          findsOneWidget);
      // 三档逐字
      expect(
          find.text('已登录夸克网盘（应用已读取保存的凭据）'),
          findsOneWidget,
          reason: '已登录只表示应用读到了保存的凭据，不承诺远端会话有效');
      expect(find.text('UC 网盘的登录已过期，请重新登录'), findsOneWidget,
          reason: '★★④ 过期档如实报，不许冒充已登录');
      expect(find.text('需要先登录百度网盘'), findsOneWidget,
          reason: '★★③ 未登录档如实报');
      // 账号名（来自钥匙串元数据，不是伪造的）
      expect(find.text('账号：小影'), findsNWidgets(2),
          reason: '★ 夸克与 UC 都有账号名');

      // 登出按钮：有凭据的两行有，未登录的行**没有**（假入口比没有更糟）
      expect(find.byKey(const ValueKey<String>('pan-account-logout-quark')),
          findsOneWidget);
      expect(find.byKey(const ValueKey<String>('pan-account-logout-uc')),
          findsOneWidget);
      expect(find.byKey(const ValueKey<String>('pan-account-logout-baidu')),
          findsNothing,
          reason: '★★ 未登录的行不许有登出按钮（点了也没凭据可清）');
    });

    testWidgets('★★ 点登出 ⇒ 真调登出 + 重新拉状态，行从已登录变未登录',
        (t) async {
      var logoutCalls = <String>[];
      var statusFetches = 0;
      debugPanCredentialStatusFetcher = () async {
        statusFetches++;
        if (statusFetches == 1) return fixtureAccounts();
        // 登出之后：夸克那一行变成未登录
        return const <PanAccountStatus>[
          PanAccountStatus(
            kind: 'quark',
            kindName: '夸克网盘',
            loggedIn: false,
            expired: false,
            keyringAvailable: true,
          ),
        ];
      };
      debugPanLogoutCaller = (kind) async {
        logoutCalls.add(kind);
      };
      await t.pumpWidget(host(const PanSettingsBody()));
      await t.pump();
      expect(statusFetches, 1);

      await t.tap(find.byKey(const ValueKey<String>('pan-account-logout-quark')));
      await t.pump();
      await t.pump();

      expect(logoutCalls, ['quark'],
          reason: '★★ 登出必须带盘种（钥匙串按盘清，不许全清）');
      expect(statusFetches, 2, reason: '★★ 登出后必须重新拉登录状态');
      expect(find.text('需要先登录夸克网盘'), findsOneWidget,
          reason: '★★ 夹具说凭据没了 ⇒ 界面必须跟着变成未登录（不许停在"已登录"）');
      expect(find.byKey(const ValueKey<String>('pan-account-logout-quark')),
          findsNothing, reason: '★ 凭据没了，登出按钮必须消失');
    });

    testWidgets('★ 空列表 ⇒ "还没有登录任何网盘账号"（不是空白）', (t) async {
      debugPanCredentialStatusFetcher = () async => const <PanAccountStatus>[];
      await t.pumpWidget(host(const PanSettingsBody()));
      await t.pump();
      expect(find.text('还没有登录任何网盘账号'), findsOneWidget);
    });

    testWidgets('★ 钥匙串不可用 ⇒ 如实说，不许装作能登录', (t) async {
      debugPanCredentialStatusFetcher = () async => const <PanAccountStatus>[
            PanAccountStatus(
              kind: 'quark',
              kindName: '夸克网盘',
              loggedIn: false,
              expired: false,
              keyringAvailable: false,
            ),
          ];
      await t.pumpWidget(host(const PanSettingsBody()));
      await t.pump();
      expect(find.text('本机没有可用的系统钥匙串，登录状态存不住'), findsOneWidget,
          reason: '★★ 钥匙串不可用是"登录功能整体不可用"，必须说出来');
    });
  });

  group('③ 反假绿：什么都不注入 ⇒ 不许冒充已登录', () {
    testWidgets('★★★ 无凭据来源时全页找不到"已登录"三个字', (t) async {
      // 生产注入点全空（flutter test 里 FFI 调用不可达，页面停在"读取中"或错误态）
      await t.pumpWidget(host(const PanSettingsBody()));
      await t.pump();
      await t.pump();

      expect(find.textContaining('已登录'), findsNothing,
          reason: '★★★ 反假绿核心判据：没有任何凭据来源时，'
              '页面上不许出现"已登录"（冒一句都是伪造）；'
              '注入「initState 里塞一份已登录假状态」本条立刻红');
      expect(find.textContaining('登录成功'), findsNothing,
          reason: '★ 同理，扫码成功文案也不许凭空出现');
      await t.pump(const Duration(seconds: 16));
      await t.pump();
      expect(find.textContaining('已登录'), findsNothing,
          reason: '读取期限结束后仍不能凭空确认账号');
      expect(find.byKey(const ValueKey<String>('pan-status-error')),
          findsOneWidget, reason: '无响应的凭据链路必须有界进入错误态');
    });

    testWidgets('★★ 链路失败 ⇒ 如实显示错误，错误态里也不许出现"已登录"',
        (t) async {
      debugPanCredentialStatusFetcher =
          () async => throw Exception('模拟钥匙串链路失败');
      await t.pumpWidget(host(const PanSettingsBody()));
      await t.pump();
      await t.pump();

      final err = find.byKey(const ValueKey<String>('pan-status-error'));
      expect(err, findsOneWidget,
          reason: '★★★ 链路读不到登录态 ⇒ 必须显示错误；'
              '注入「catch 里把 accounts 填成已登录假数据」或「吞掉异常装没事」本条立刻红');
      expect(find.textContaining('已登录'), findsNothing,
          reason: '★★ 错误态是"没读到"，不是"已登录"');
    });
  });

  group('④ 扫码登录：QrView 复用 + 轮询终态', () {
    testWidgets('★★★ start 出码 → pending/scanned/confirmed 走完 → 状态刷新',
        (t) async {
      var startCalls = 0;
      final pollStatuses = <String>['pending', 'scanned', 'confirmed'];
      var pollCalls = 0;
      debugPanQrLoginStarter = (kind) async {
        startCalls++;
        expect(kind, 'quark', reason: '★ 默认盘种是夸克');
        return <String, dynamic>{
          'key': 'k1',
          'url': 'https://pan.quark.cn/qr/k1',
          'svg': qrSvgFixture,
        };
      };
      debugPanQrLoginPoller = (kind, key) async {
        expect(key, 'k1', reason: '★ 轮询必须带 start 给的 key');
        pollCalls++;
        return <String, dynamic>{'status': pollStatuses.first, 'message': ''};
      };
      var statusFetches = 0;
      debugPanCredentialStatusFetcher = () async {
        statusFetches++;
        return statusFetches == 1
            ? const <PanAccountStatus>[]
            : fixtureAccounts();
      };

      await t.pumpWidget(host(const PanSettingsBody()));
      await t.pump();

      await t.tap(find.byKey(const ValueKey<String>('pan-qr-start')));
      await t.pump();
      await t.pump();

      expect(startCalls, 1);
      expect(find.byType(QrView), findsOneWidget,
          reason: '★★★ 二维码必须用现成 QrView 渲染（复用，不是重造）；'
              '注入「自己画个方块冒充二维码」这条依旧绿但 ⑥ 的复用判据会红');
      expect(find.byKey(const ValueKey<String>('pan-qr-login-view')), findsOneWidget);

      // pending（轮询定时器 2 秒一跳）
      await t.pump(const Duration(seconds: 2));
      await t.pump();
      expect(find.text('等待扫码…'), findsOneWidget);

      // scanned
      pollStatuses.removeAt(0);
      await t.pump(const Duration(seconds: 2));
      await t.pump();
      expect(find.text('已扫码，请在手机上确认'), findsOneWidget);

      // confirmed ⇒ 终态停表 + 重新拉登录状态
      pollStatuses.removeAt(0);
      await t.pump(const Duration(seconds: 2));
      await t.pump();
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey<String>('pan-qr-login-view')), findsNothing);
      expect(statusFetches, 3,
          reason: '★★★ confirmed 后必须重新拉登录状态（否则列表停在"未登录"）');
      expect(pollCalls, 3, reason: '★ 三个状态各轮询一次');

      // 离开页面：定时器必须已停（confirmed 是终态）
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('★★ expired 是终态：停表 + 提示重新获取，绝不显示"登录成功"',
        (t) async {
      debugPanQrLoginStarter =
          (kind) async => <String, dynamic>{
                'key': 'k2',
                'url': 'https://pan.example/qr/k2',
                'svg': qrSvgFixture,
              };
      debugPanQrLoginPoller =
          (kind, key) async => <String, dynamic>{'status': 'expired'};
      debugPanCredentialStatusFetcher = () async => const <PanAccountStatus>[];

      await t.pumpWidget(host(const PanSettingsBody()));
      await t.pump();
      await t.tap(find.byKey(const ValueKey<String>('pan-qr-start')));
      await t.pump();
      await t.pump();
      await t.pump(const Duration(seconds: 2));
      await t.pump();

      expect(find.text('二维码已失效，请重新获取'), findsOneWidget);
      expect(find.textContaining('登录成功'), findsNothing,
          reason: '★★ 二维码过期了绝不能报"登录成功"（伪造登录态）');
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('★ 获取二维码失败 ⇒ 如实报错，不出现二维码', (t) async {
      debugPanCredentialStatusFetcher = () async => const <PanAccountStatus>[];
      debugPanQrLoginStarter =
          (kind) async => throw Exception('模拟二维码签发失败');
      await t.pumpWidget(host(const PanSettingsBody()));
      await t.pump();
      await t.tap(find.byKey(const ValueKey<String>('pan-qr-start')));
      await t.pump();
      await t.pump();
      expect(find.byKey(const ValueKey<String>('pan-qr-error')), findsOneWidget,
          reason: '★ 拿不到二维码要如实说');
      expect(find.byKey(const ValueKey<String>('pan-qr-view')), findsNothing,
          reason: '★ 没拿到二维码不许画一个占位框');
    });
  });

  group('⑤ 分享文件浏览：复用列目录组件，零播放入口', () {
    testWidgets('★★★ 识别 → 列出文件 → PanShareListingSection 渲染；整页无播放入口',
        (t) async {
      debugPanCredentialStatusFetcher = () async => const <PanAccountStatus>[];
      debugPanIdentifyFetcher = (text) async => const PanShareStatus(
            kind: 'quark',
            kindName: '夸克网盘',
            shareId: 'abc123',
            loggedIn: false,
            resolvable: false,
            reason: '需要先登录夸克网盘',
          );
      SourinApi.debugPanListShareFetcher = (text, pwd) async =>
          const PanShareListing(
            title: '示例合集',
            entries: <PanShareEntry>[
              PanShareEntry(name: '第 01 集.mp4', size: 734003200, isDir: false),
            ],
            note: '未登录时能列出 1 个文件，但取直链需要登录夸克网盘账号',
            resolvable: false,
          );

      await t.pumpWidget(host(const PanSettingsBody()));
      await t.pump();

      await t.enterText(
          find.byKey(const ValueKey<String>('pan-share-input')), '随便一段分享文字');
      await t.tap(find.byKey(const ValueKey<String>('pan-share-identify')));
      await t.pump();
      await t.pump();

      expect(find.byKey(const ValueKey<String>('pan-identify-result')),
          findsOneWidget);
      expect(find.text('需要先登录夸克网盘'), findsOneWidget,
          reason: '★★ 分层原因原样透出');
      expect(find.text('当前版本还不能用它播放（取直链需要登录账号）'),
          findsOneWidget,
          reason: '★★ 能力边界必须显式说（resolvable 恒 false）');

      // "列出分享里的文件"入口只在识别成功后出现
      final listBtn = find.byKey(const ValueKey<String>('pan-share-list'));
      expect(listBtn, findsOneWidget);
      await t.tap(listBtn);
      await t.pump();
      await t.pump();

      expect(find.byType(PanShareListingSection), findsOneWidget,
          reason: '★★★ 列目录必须复用现成组件（不是重造一份列表）');
      expect(find.text('示例合集'), findsOneWidget);
      expect(find.text('第 01 集.mp4'), findsOneWidget);

      // ★ 整页没有任何播放入口（旧35 纪律：可列不可播是诚实边界）
      expect(find.widgetWithText(AppTextButton, '播放'), findsNothing,
          reason: '★★★ 出现可点的"播放"就等于给了假入口');
      expect(find.widgetWithText(FilledButton, '播放'), findsNothing);
      expect(find.byIcon(Icons.play_arrow), findsNothing,
          reason: '★ 连播放图标也不许有');
    });
  });

  group('⑥ 源码门禁：凭据不落盘 + 复用判据 + 入口在位', () {
    // 照 zz_t1024 的同一条纪律：源码类判据**先剥注释**再扫，
    // 否则头注释里写着"本页不 import dart:io"这句话本身就会把门禁骗红。
    String stripComments(String src) {
      final out = StringBuffer();
      var i = 0;
      while (i < src.length) {
        final c = src[i];
        if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
          while (i < src.length && src[i] != '\n') {
            out.write(' ');
            i++;
          }
          continue;
        }
        if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
          while (i + 1 < src.length &&
              !(src[i] == '*' && src[i + 1] == '/')) {
            out.write(src[i] == '\n' ? '\n' : ' ');
            i++;
          }
          i += 2;
          continue;
        }
        out.write(c);
        i++;
      }
      return out.toString();
    }

    test('★★★ 页面实现里不许出现任何文件操作（凭据只走钥匙串）', () {
      final src = stripComments(
          File('lib/ui/settings/pan_settings_page.dart').readAsStringSync());
      for (final bad in const [
        'dart:io',
        'File(',
        'writeAsString',
        'writeAsBytes',
        'OpenOptions',
        'Directory(',
      ]) {
        expect(src.contains(bad), isFalse,
            reason: '★★★ 凭据绝不落盘：页面实现里出现了 `$bad` —— '
                '凭据只许走系统钥匙串链路（pan_auth 语义）');
      }
    });

    test('★★ 接线契约与注入点在位；入口函数存在；列目录是复用不是重造', () {
      final src = stripComments(
          File('lib/ui/settings/pan_settings_page.dart').readAsStringSync());
      // 生产命令契约（Rust 侧接线目标）
      for (final cmd in const [
        'pan_auth_status',
        'pan_qr_login_start',
        'pan_qr_login_poll',
        'pan_logout',
      ]) {
        expect(src.contains("'$cmd'"), isTrue, reason: '★ 缺命令 `$cmd` 的调用');
      }
      // 注入点（测试的合法入口；生产恒 null）
      for (final p in const [
        'debugPanCredentialStatusFetcher',
        'debugPanQrLoginStarter',
        'debugPanQrLoginPoller',
        'debugPanLogoutCaller',
        'debugPanIdentifyFetcher',
      ]) {
        expect(src.contains(p), isTrue, reason: '★ 缺注入点 `$p`');
      }
      // 一行式入口
      expect(src.contains('Future<void> showPanSettingsPage(BuildContext context)'),
          isTrue, reason: '★ 设置页接线要的就是一行式入口函数');
      // 复用判据
      expect(src.contains('PanShareListingSection'), isTrue,
          reason: '★★ 列目录必须复用 pan_share_dialog 的现成组件');
      expect(src.contains('showPanQrLoginDialog('), isTrue);
      final dialog =
          File('lib/ui/widgets/pan_qr_login_dialog.dart').readAsStringSync();
      expect(
        dialog.contains("import 'qr_view.dart'"),
        isTrue,
        reason: '独立扫码弹窗仍必须复用 qr_view',
      );
      // 注入点先于 FFI：fetcher 非 null 时不许碰 callAsync（照 panListShare 的写法）
      expect(
          src.indexOf('debugPanCredentialStatusFetcher') <
              src.indexOf("callAsync('pan_auth_status'"),
          isTrue,
          reason: '★★ 注入检查必须排在真命令之前（否则测试永远打不到替身）');
    });
  });
}
