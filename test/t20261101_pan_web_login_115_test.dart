// ═══════════════════════════════════════════════════════════════════════
//  115 网页登录「没反应」修复门禁（2026-11-01）
// ═══════════════════════════════════════════════════════════════════════
//
// # 由来（Owner 报的 bug）
// ```text
// > 115 网盘点了「网页登录」，登录完成了但没反应
// ```
// 现场（ui-judge-window 07:00:53 截图存证）：弹窗「网页登录115 网盘」一直转圈、
// 零错误行；背后 WebView 标题「115科技官网_首页」= 停在官网首页没进登录页；
// 07:06 点取消后 115 行仍是「未登录」⇒ **全程没捕获到过登录态**。
//
// # 定性：这条路**架构上不通**，不是判据写错
// ```text
// ① 落盘形状过不了 Rust 侧判据（决定性）：
//    csp/pan115.rs is_logged(cookie) => cookie.contains("UID=")
//    （DEX 逐字 [logged]，测试钉住 is_logged("CID=abc; SEID=xyz") == false）
//    而网页登录落盘只 trim + 非空校验（pan_login.rs validate_web_login_credential），
//    没有任何键名映射 ⇒ 网页会话 cookie 不含 UID= ⇒ 存了也显示"未登录"。
// ② UID/CID/SEID/KID 的唯一来源是**扫码换 cookie 的响应体**
//    （pan115_cookie_from_body 从 POST .../login/qrcode/ 的 JSON 里拼出来），
//    不是浏览器 cookie store 的键 ⇒ 网页登录不可能产出它。
// ③ 入口 URL 也是错的：https://www.115.com/ 实测是 357 字节的 JS 跳壳页
//    （跳到 https://115.com/ 官网首页），首页上的登录只是 JS 弹层
//    （未登录时 window.USER_ID=''）⇒ 用户根本进不到登录页。
// ④ 115 网页版登录态的键名与域：**未取证到**（服务端 Set-Cookie 下发，
//    须真登录后才读得到；没有 Owner 账号也不该在空窗开 webview 打扰）
//    ⇒ 如实标注"未取证"，**绝不编造键名**（本门禁不含任何 115 键名断言）。
// ⇒ 修法：撤掉 115 的网页登录入口 + 如实说明 + 指路扫码；并修通用静默。
// ```
//
// # 本门禁钉什么
// ```text
// A. 115 已撤（没有 spec）+ 撤得**有理由**（人话说清为什么 + 指路扫码）；
// B. 静默已修：缺键提示 / 无 cookie 提示 / 超时终态 / 拼串失败，四条都是
//    **可行动**的人话，且键名只取自 spec.requiredKeys（客观事实）；
// C. 代码级：showPanWebLogin 的 spec==null 分支**不许**静默 return
//    （那是"点了没反应"的同款缺陷）⇒ 必须弹对话框；
// D. 注入证红：改坏判据 / 去掉反馈 / URL 退回官网首页 ⇒ 必须红。
// ```
//
// # 为什么不加 @Tags(['native-media'])
// ```text
// 全部是纯函数 + 源码级断言（不碰 WebView2 / 钥匙串 / 网络 / libmpv）
// ⇒ 默认全量 flutter test 就会真跑，不许躲进标签里。
// ```

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/ui/widgets/pan_web_login.dart';

CapturedCookie ck(String domain, String name, String value) =>
    CapturedCookie(domain: domain, name: name, value: value);

void main() {
  group('A. 115 网页登录已撤（撤 ≠ 消失，必须给替代路径）', () {
    test('A1 115 不再有网页登录配置（三家名单）', () {
      for (final kind in ['quark', 'uc', 'baidu']) {
        expect(PanWebLoginSpec.of(kind), isNotNull, reason: '$kind 仍应可用');
      }
      // ★★ 注入证红：把 115 的配置加回去 ⇒ 本条必须红
      expect(PanWebLoginSpec.of('115'), isNull,
          reason: '★ 115 已撤：网页 cookie 里拿不到含 UID= 的凭据，'
              '存进去也会被 is_logged 判为未登录（读数说谎）');
      // 其余盘仍然没有条目（放了就是假入口）
      for (final kind in ['aliyun', 'tianyi', '123', 'guangya', 'xunlei', 'nope']) {
        expect(PanWebLoginSpec.of(kind), isNull, reason: kind);
      }
    });

    test('A2 撤掉的原因必须说清「为什么」+「该用哪条路」（含扫码）', () {
      final reason = PanWebLoginSpec.panWebLoginUnsupportedReason('115');
      expect(reason, isNotNull, reason: '★ 115 撤了必须有原因，不许只剩"未登录"');
      expect(reason!.contains('115'), isTrue);
      expect(reason.contains('扫码'), isTrue,
          reason: '★ 必须指路扫码（可行动的替代路径）：$reason');
      expect(reason.contains('UID'), isTrue,
          reason: '★ 要说清凭据形状对不上（Rust 侧只认 UID=）：$reason');
      // 不许出现把责任推给时间的空话
      expect(reason.contains('稍后重试'), isFalse, reason: '不许空话：$reason');
    });

    test('A3 只有 115 标记为已撤；三家不许被误伤', () {
      expect(PanWebLoginSpec.panWebLoginRetired('115'), isTrue);
      for (final kind in ['quark', 'uc', 'baidu']) {
        expect(PanWebLoginSpec.panWebLoginRetired(kind), isFalse,
            reason: '★ $kind 仍能网页登录，不许被标成已撤');
        expect(PanWebLoginSpec.panWebLoginUnsupportedReason(kind), isNull);
      }
    });

    test('A4 ★ 入口 URL 不许退回 115 官网首页（注入证红）', () {
      // 现场根因之一：入口是官网首页（登录只是首页上的 JS 弹层）
      // ⇒ 任何一家都不许把首页/跳壳页当登录入口。
      final src = File('lib/ui/widgets/pan_web_login.dart').readAsStringSync();
      expect(src.contains("'https://www.115.com/'"), isFalse,
          reason: '★ www.115.com 实测只是 357 字节的 JS 跳壳页，不许再当登录入口');
      expect(src.contains("cookieDomainSuffix: '115.com'"), isFalse,
          reason: '★ 115 已撤，不许还留着它的域判据');
      expect(src.contains("requiredKeys: <String>['UID', 'CID', 'SEID']"), isFalse,
          reason: '★ UID/CID/SEID 是扫码协议产物，不许拿来判网页 cookie');
      // 三家入口仍是各自的登录页（不是首页）
      expect(PanWebLoginSpec.of('quark')!.loginUrl, 'https://pan.quark.cn/');
      expect(PanWebLoginSpec.of('uc')!.loginUrl, 'https://drive.uc.cn/');
      expect(PanWebLoginSpec.of('baidu')!.loginUrl,
          startsWith('https://passport.baidu.com/'));
    });
  });

  group('B. 静默已修：未捕获时要给可行动的反馈', () {
    final quark = PanWebLoginSpec.of('quark')!;

    test('B1 缺哪几个键 = 客观事实（只取自 spec.requiredKeys）', () {
      expect(
        panWebLoginMissingKeys([], quark),
        ['__pus', '__kps'],
      );
      expect(
        panWebLoginMissingKeys([ck('.quark.cn', '__pus', 'v')], quark),
        ['__kps'],
      );
      expect(
        panWebLoginMissingKeys(
          [ck('.quark.cn', '__pus', 'v'), ck('.quark.cn', '__kps', 'w')],
          quark,
        ),
        isEmpty,
        reason: '判据键全齐 ⇒ 缺键表为空',
      );
      // ★★ 注入证红：别的域上有同名键 ⇒ 仍算缺失
      expect(
        panWebLoginMissingKeys([ck('.evil.cn', '__pus', 'v')], quark),
        ['__pus', '__kps'],
        reason: '★ 多域混入：只认目标域，别的域上的同名键不算数',
      );
    });

    test('B2 目标域 cookie 计数（区分"没进登录页"与"键不全"）', () {
      expect(panWebLoginTargetCookieCount([], quark), 0);
      expect(panWebLoginTargetCookieCount([ck('.quark.cn', 'ctoken', 'a')], quark), 1);
      expect(panWebLoginTargetCookieCount([ck('.evil.cn', 'x', 'a')], quark), 0);
    });

    test('B3 缺键提示：说清等了多久 / 在哪个域 / 差什么', () {
      final hint = panWebLoginNotDetectedHint(
        quark,
        ['__kps'],
        waitedSeconds: 12,
      );
      expect(hint.contains('12s'), isTrue, reason: '★ 要报等待时长：$hint');
      expect(hint.contains('quark.cn'), isTrue, reason: '★ 要说在哪个域：$hint');
      expect(hint.contains('__kps'), isTrue, reason: '★ 要说差哪个键：$hint');
      expect(hint.contains('__pus'), isFalse, reason: '不该把已有的键也说成缺');
      // ★★ 注入证红：去掉等待时长 ⇒ 本条红（用户就不知道程序还活着）
      expect(hint.contains('已等待'), isTrue);
    });

    test('B4 目标域上一个 cookie 都没有 ⇒ 直说"多半没进登录页"', () {
      final hint = panWebLoginNoCookieHint(quark);
      expect(hint.contains('quark.cn'), isTrue);
      expect(hint.contains('没有拿到任何 cookie'), isTrue, reason: '$hint');
      expect(hint.contains('登录页'), isTrue,
          reason: '★ 115 那次的真实现象就是没进登录页，这句必须点到：$hint');
    });

    test('B5 超时终态：停止 + 明确下一步（不许停了还让人猜）', () {
      expect(panWebLoginTimeout.inSeconds, 90,
          reason: '★ 必须有等待上限，不许无限转圈');
      final t = panWebLoginTimeoutHint(quark, ['__kps']);
      expect(t.contains('已停止'), isTrue, reason: '★ 要明说已停止：$t');
      expect(t.contains('扫码登录'), isTrue, reason: '★ 要给下一步：$t');
      expect(t.contains('__kps'), isTrue, reason: '★ 要留最后缺的键：$t');
      expect(t.contains('90s'), isTrue, reason: '★ 要说等了多久才放弃：$t');
    });

    test('B6 反馈键名不许编造：115 未被取证 ⇒ 判据里零个 115 键名夹具', () {
      /*
       * 客观事实：115 网页版登录态键名**未取证到**（见本文件头 ④）
       * ⇒ **判据区**不许出现任何 115 的键名夹具 / 域夹具，否则就是编造。
       * 注：A2 里那条 `reason.contains('UID')` 查的是**原因文案**有没有说清
       * 凭据形状（Rust 侧只认 UID= 这个**已取证**的事实），不是判据键名
       * ⇒ 不冲突；这里钉的是"判据不许用 115 的键/域造夹具"。
       */
      final src = File('test/t20261101_pan_web_login_115_test.dart')
          .readAsStringSync();
      /*
       * ★ 只扫**夹具行**：本文件里那些"不许出现 115 URL"的负向断言
       *   （A4 的 contains("'https://www.115.com/'") 等）本身就带 115 字面量，
       *   把它们算进来会自己判自己红 ⇒ 只检查"造 cookie 夹具"的那些行。
       */
      final body = LineSplitter.split(src)
          .skipWhile((l) => !l.contains('void main()'))
          .where((l) => l.contains('ck('))
          .join('\n');
      expect(body.contains('115'), isFalse,
          reason: '★ 不许用 115 的域/键造判据夹具（键名未取证、该盘已撤）');
       // ★ 夹具级（ck 行已在上面整体查过 115 字面量）
    });
  });

  group('C. 代码级：点了不许没反应（spec==null 不许静默 return）', () {
    test('C1 showPanWebLogin 的 spec==null 分支必须弹对话框', () {
      /*
       * ★★★ 这是 Owner 报的"点了没反应"的**同款缺陷**：
       * 旧代码 `if (spec == null) return false;` —— 调用方拿到 false 什么都不做
       * ⇒ 用户什么反馈也没有。撤功能 ≠ 点了没反应。
       * 现在必须：spec == null 且该盘是被撤的盘 ⇒ 弹如实说明对话框。
       */
      final src = File('lib/ui/widgets/pan_web_login.dart').readAsStringSync();
      final head = src.indexOf('Future<bool> showPanWebLogin(');
      expect(head, greaterThan(0));
      final body = src.substring(head, src.indexOf('/// WebView2 Runtime 缺失'));
      final nullBranch = body.indexOf('if (spec == null) {');
      expect(nullBranch, greaterThan(0), reason: '★ spec==null 分支必须还在');
      final afterNull = body.substring(nullBranch);
      expect(afterNull.contains('showAppDialog'), isTrue,
          reason: '★★ 注入证红：把 showAppDialog 改回 `return false;` ⇒ 本条红 '
              '（这正是"点了没反应"的形态）');
      expect(afterNull.contains('panWebLoginUnsupportedReason'), isTrue,
          reason: '★ 弹窗内容必须取自那句如实原因（一处写、处处用）');
      // 静默 return 的那行不许还在
      expect(body.contains('if (spec == null) return false;'), isFalse,
          reason: '★ 旧的静默 return 必须已经改掉');
    });

    test('C2 等待弹窗必须真的显示 hint（去掉反馈 ⇒ 红）', () {
      final src = File('lib/ui/widgets/pan_web_login.dart').readAsStringSync();
      final dlg = src.indexOf('class _PanWebLoginWaitingDialogState');
      expect(dlg, greaterThan(0));
      final body = src.substring(dlg);
      // 三处反馈调用：缺键提示 / 无 cookie 提示 / 超时终态
      expect(body.contains('panWebLoginNotDetectedHint('), isTrue,
          reason: '★ 注入证红：删掉缺键提示 ⇒ 本条红（又变回只会转圈）');
      expect(body.contains('panWebLoginNoCookieHint('), isTrue);
      expect(body.contains('panWebLoginTimeoutHint('), isTrue);
      // 渲染：hint 必须真的挂到界面上（有 key 可查）
      expect(body.contains("ValueKey<String>('pan-web-login-hint')"), isTrue,
          reason: '★ hint 必须真的渲染出来（不是只在变量里）');
      // 超时必须停表 + 关窗（不许停了还继续转）
      expect(body.contains('_timer?.cancel();'), isTrue);
      expect(body.contains('widget.webview.close()'), isTrue);
    });

    test('C3 转圈不许在终态还出现（有错误还在转 = 假象）', () {
      final src = File('lib/ui/widgets/pan_web_login.dart').readAsStringSync();
      final dlg = src.indexOf('class _PanWebLoginWaitingDialogState');
      final body = src.substring(dlg, src.indexOf('class _PanWebLoginUnsupportedDialog') > dlg
          ? src.indexOf('class _PanWebLoginUnsupportedDialog')
          : src.length);
      // 转圈那一块必须被 `if (_error.isEmpty)` 包住
      final loading = body.indexOf('AppLoading()');
      expect(loading, greaterThan(0));
      final guard = body.lastIndexOf('if (_error.isEmpty)', loading);
      expect(guard, greaterThan(0),
          reason: '★ 转圈必须只在没有终态错误时出现');
      expect(guard, lessThan(loading));
    });
  });

  group('D. 判据与拼接的负例（守住原有语义不被这次改动带偏）', () {
    final quark = PanWebLoginSpec.of('quark')!;

    test('D1 多域混入只取目标域 / 拼接域不算', () {
      expect(
        panWebLoginCaptured(
          [ck('.evil.cn', '__pus', 'b'), ck('.evil.cn', '__kps', 'c')],
          quark,
        ),
        isFalse,
      );
      expect(
        panWebLoginCaptured(
          [ck('.evilquark.cn', '__pus', 'b'), ck('.evilquark.cn', '__kps', 'c')],
          quark,
        ),
        isFalse,
        reason: '★ label 边界：evilquark.cn 不是 quark.cn',
      );
      expect(
        panWebLoginCaptured(
          [ck('.baidu.com', '__pus', 'x'), ck('.quark.cn', '__pus', 'b'),
           ck('pan.quark.cn', '__kps', 'c')],
          quark,
        ),
        isTrue,
      );
    });

    test('D2 键在值空 ⇒ 未登录（且要出现在缺键表里）', () {
      final cookies = [ck('.quark.cn', '__pus', ''), ck('.quark.cn', '__kps', 'c')];
      expect(panWebLoginCaptured(cookies, quark), isFalse);
      expect(panWebLoginMissingKeys(cookies, quark), ['__pus'],
          reason: '★ 空值键也要算缺失（"见过名字"≠"登录态在手"）');
    });

    test('D3 注入键丢弃：name 带 = / ; / 空白、value 带 ; 或换行', () {
      final s = panWebBuildCookieString(
        [
          ck('.quark.cn', 'a=b', 'v'),
          ck('.quark.cn', 'a;b', 'v'),
          ck('.quark.cn', 'a b', 'v'),
          ck('.quark.cn', 'ok', 'v;w'),
          ck('.quark.cn', 'ok2', 'v\nw'),
          ck('.quark.cn', '__pus', 'b'),
        ],
        quark,
      );
      expect(s, '__pus=b', reason: '注入键一个都不许进串');
      // 全被丢弃 ⇒ null（不许用空串冒充成功）
      expect(panWebBuildCookieString([ck('.quark.cn', 'a=b', 'v')], quark), isNull);
      expect(panWebBuildCookieString([], quark), isNull);
    });

    test('D4 同名后到覆盖（与 Rust merge_cookie 同一语义）', () {
      expect(
        panWebBuildCookieString(
          [ck('.quark.cn', '__pus', 'old'), ck('pan.quark.cn', '__pus', 'new')],
          quark,
        ),
        '__pus=new',
      );
    });
  });

  group('E. 设置页：115 行必须有替代路径（不许只剩"未登录"）', () {
    test('E1 登录入口使用唯一真源 + 115 行渲染撤除原因', () {
      final src =
          File('lib/ui/settings/pan_settings_page.dart').readAsStringSync();
      expect(src.contains('static const Set<String> _webLoginKinds'), isFalse);
      expect(src.contains('PanWebLoginSpec.of(a.kind)'), isTrue);
      expect(PanWebLoginSpec.all.keys.toSet(), {'quark', 'uc', 'baidu'});
      expect(PanWebLoginSpec.of('115'), isNull);
      // 115 行的替代路径：必须引用那句原因（一处写、处处用）
      expect(
        src.contains('PanWebLoginSpec.panWebLoginRetired(a.kind)'),
        isTrue,
        reason: '★ 115 行必须显示撤除原因 + 指路扫码，不许只剩"未登录"',
      );
      expect(
        src.contains(
          "ValueKey<String>('pan-account-weblogin-retired-\${a.kind}')",
        ),
        isTrue,
      );
    });

    test('E2 ★ 已同步（N3a）：pan_qr_login_dialog 那份名单已改为读真源', () {
      /*
       * 前半批的"半边已知"已在 N3a 根治：扫码弹窗不再维护第二份手抄名单，
       * 改读 PanWebLoginSpec 真源，115 不再画按钮（改渲染撤除原因原句）。
       * 剥注释后的同真源断言（名单字面量零容忍 + 注入证红）在
       * test/t20261101_pan_qr_dialog_web_source_test.dart 的 N1。
       */
      final b = File('lib/ui/widgets/pan_qr_login_dialog.dart').readAsStringSync();
      expect(b.contains('static const Set<String> _webLoginKinds'), isFalse,
          reason: '★★ 注入证红：把手抄名单加回 pan_qr_login_dialog ⇒ 本条红');
      expect(b.contains('PanWebLoginSpec'), isTrue,
          reason: '★ 必须读真源（与设置页同源，才不会再漂）');
    });
  });
}
