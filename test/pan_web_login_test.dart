// ═══════════════════════════════════════════════════════════════════════
//  网页登录（W1）纯函数门禁 —— cookie 捕获判据 / 域过滤 / 拼接
// ═══════════════════════════════════════════════════════════════════════
//
// # 只测纯函数（不碰 WebView2 / 钥匙串 / 网络）
// ```text
// webview 窗口与 FFI 落盘都是**真机路径**（flutter test 里没有 dll、也不该出网），
// 门禁钉的是判据本体：域后缀边界、键存在性、多域过滤、拼接形状与注入防御。
// ```

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/ui/widgets/pan_web_login.dart';

CapturedCookie ck(String domain, String name, String value) =>
    CapturedCookie(domain: domain, name: name, value: value);

void main() {
  group('每盘配置表（判据来源 = Lead 批复 + 扫码链路实测基线）', () {
    test('只有三家有网页登录配置（115 已撤，2026-11-01）', () {
      for (final kind in ['quark', 'uc', 'baidu']) {
        expect(PanWebLoginSpec.of(kind), isNotNull, reason: kind);
      }
      /*
       * ★★ 115 已撤（Owner 报"点了网页登录没反应"的根因）：
       * 115 的登录态 UID/CID/SEID/KID 是**扫码协议**从服务端响应体下发的，
       * 网页 cookie 里没有；而 Rust 侧 is_logged 只认 cookie 含不含 UID=
       * ⇒ 网页登录存进去也会被显示成未登录（读数说谎）⇒ 撤，不硬凑判据。
       * 完整论证见 test/t20261101_pan_web_login_115_test.dart 文件头。
       */
      expect(PanWebLoginSpec.of('115'), isNull,
          reason: '★ 115 已撤：网页 cookie 拿不到含 UID= 的凭据');
      // 其余盘必须没有条目（放了就是假入口：Rust 白名单会拒，但按钮根本不该出现）
      for (final kind in ['aliyun', 'tianyi', '123', 'guangya', 'xunlei', 'nope']) {
        expect(PanWebLoginSpec.of(kind), isNull, reason: kind);
      }
    });

    test('登录态键逐字对齐批复判据', () {
      // ★ 注入验证：把 quark 的 __pus 换成 ctoken ⇒ 本条红
      //   （ctoken 是 pre-login 页面就种的键 —— 2026-10-31 真开页面取证，
  //     拿它判登录 = 未登录也假绿）
      expect(PanWebLoginSpec.of('quark')!.requiredKeys, ['__pus', '__kps']);
      expect(PanWebLoginSpec.of('uc')!.requiredKeys, ['__pus', '__kps']);
      expect(PanWebLoginSpec.of('baidu')!.requiredKeys, ['BDUSS']);
      // 115 已撤 ⇒ 不再有键名判据（它那四个键是扫码协议产物，不是网页 cookie）
    });

    test('登录入口 URL 与目标域逐字对齐取证', () {
      final quark = PanWebLoginSpec.of('quark')!;
      expect(quark.loginUrl, 'https://pan.quark.cn/');
      expect(quark.cookieDomainSuffix, 'quark.cn');
      final uc = PanWebLoginSpec.of('uc')!;
      expect(uc.loginUrl, 'https://drive.uc.cn/');
      expect(uc.cookieDomainSuffix, 'uc.cn');
      final baidu = PanWebLoginSpec.of('baidu')!;
      expect(baidu.loginUrl, startsWith('https://passport.baidu.com/'));
      expect(baidu.cookieDomainSuffix, 'baidu.com');
      // 115 已撤 ⇒ 没有登录入口 URL / 域判据（见上面两条的说明）
    });
  });

  group('域后缀匹配（label 边界）', () {
    test('带点前缀与主机域都命中目标后缀', () {
      expect(panWebCookieDomainMatches('.quark.cn', 'quark.cn'), isTrue);
      expect(panWebCookieDomainMatches('pan.quark.cn', 'quark.cn'), isTrue);
      expect(panWebCookieDomainMatches('quark.cn', 'quark.cn'), isTrue);
      // 大小写不敏感（WebView2 返回的域大小写不应影响判据）
      expect(panWebCookieDomainMatches('.QUARK.CN', 'quark.cn'), isTrue);
    });

    test('★ 拼接域不许混进目标域（注入证红）', () {
      expect(panWebCookieDomainMatches('evilquark.cn', 'quark.cn'), isFalse,
          reason: '后缀必须落在 label 边界，notquark/evilquark 这类域不许命中');
      expect(panWebCookieDomainMatches('quark.cn.evil.com', 'quark.cn'), isFalse);
      expect(panWebCookieDomainMatches('', 'quark.cn'), isFalse);
      expect(panWebCookieDomainMatches('quark.cn', ''), isFalse);
    });
  });

  group('登录判据（目标域 + 登录态键全存在且值非空）', () {
    final quark = PanWebLoginSpec.of('quark')!;

    test('目标域上判据键齐全 ⇒ 已登录', () {
      final cookies = [
        ck('.quark.cn', 'ctoken', 'a'),
        ck('.quark.cn', '__pus', 'b'),
        ck('.quark.cn', '__kps', 'c'),
      ];
      expect(panWebLoginCaptured(cookies, quark), isTrue);
    });

    test('缺一个判据键 ⇒ 未登录', () {
      final cookies = [
        ck('.quark.cn', '__pus', 'b'),
      ];
      expect(panWebLoginCaptured(cookies, quark), isFalse);
    });

    test('键在值空 ⇒ 未登录', () {
      final cookies = [
        ck('.quark.cn', '__pus', ''),
        ck('.quark.cn', '__kps', 'c'),
      ];
      expect(panWebLoginCaptured(cookies, quark), isFalse);
    });

    test('★★ 多域混入：同名键长在别的域上不许算数', () {
      final cookies = [
        ck('.evil.cn', '__pus', 'b'),
        ck('.evil.cn', '__kps', 'c'),
      ];
      expect(panWebLoginCaptured(cookies, quark), isFalse,
          reason: '判据只认目标域（quark.cn）上的键');
    });

    test('★★ 拼接域混入（label 边界）不许算数', () {
      final cookies = [
        ck('.evilquark.cn', '__pus', 'b'),
        ck('.evilquark.cn', '__kps', 'c'),
      ];
      expect(panWebLoginCaptured(cookies, quark), isFalse);
    });

    test('目标域 + 别的域混合：只看目标域', () {
      final cookies = [
        ck('.baidu.com', '__pus', 'x'),
        ck('.quark.cn', '__pus', 'b'),
        ck('pan.quark.cn', '__kps', 'c'),
      ];
      expect(panWebLoginCaptured(cookies, quark), isTrue);
    });
  });

  group('拼接（k=v; … 形状）', () {
    final quark = PanWebLoginSpec.of('quark')!;

    test('只取目标域，形状是 k=v; k=v', () {
      final cookies = [
        ck('.baidu.com', 'BDUSS', 'z'),
        ck('.quark.cn', 'ctoken', 'a'),
        ck('.quark.cn', '__pus', 'b'),
        ck('.quark.cn', '__kps', 'c'),
      ];
      final s = panWebBuildCookieString(cookies, quark);
      expect(s, 'ctoken=a; __pus=b; __kps=c');
    });

    test('同名后到覆盖（与 Rust merge_cookie 同一语义）', () {
      final cookies = [
        ck('.quark.cn', '__pus', 'old'),
        ck('pan.quark.cn', '__pus', 'new'),
      ];
      expect(panWebBuildCookieString(cookies, quark), '__pus=new');
    });

    test('★★ 注入键丢弃：name 带 = / ; / 空白、value 带 ; 或换行', () {
      final cookies = [
        ck('.quark.cn', 'a=b', 'v'), // name 含 =
        ck('.quark.cn', 'a;b', 'v'), // name 含 ;
        ck('.quark.cn', 'a b', 'v'), // name 含空格
        ck('.quark.cn', 'ok', 'v;w'), // value 含 ;
        ck('.quark.cn', 'ok2', 'v\nw'), // value 含换行
        ck('.quark.cn', '__pus', 'b'),
      ];
      final s = panWebBuildCookieString(cookies, quark);
      expect(s, '__pus=b', reason: '注入键一个都不许进串，合法键照常保留');
    });

    test('全被丢弃 / 空输入 ⇒ null（不许返回空串冒充成功）', () {
      expect(panWebBuildCookieString([], quark), isNull);
      expect(panWebBuildCookieString([ck('.quark.cn', 'a=b', 'v')], quark), isNull);
      expect(
        panWebBuildCookieString([ck('.evil.cn', 'x', 'v')], quark),
        isNull,
        reason: '只有别的域的 cookie ⇒ null',
      );
    });

    test('值的内部等号保留（base64 形值的形状不许破坏）', () {
      final cookies = [ck('.quark.cn', '__pus', 'ab==')];
      final s = panWebBuildCookieString(cookies, quark);
      expect(s, '__pus=ab==');
    });
  });
}