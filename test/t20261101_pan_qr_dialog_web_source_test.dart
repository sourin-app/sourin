// ═══════════════════════════════════════════════════════════════════════
//  N3a：扫码弹窗的「网页登录」按钮与设置页同真源（2026-11-01）
// ═══════════════════════════════════════════════════════════════════════
//
// # 由来（上批留下的"半边未同步"）
// ```text
// 115 网页登录被撤（commit 90dce6d）时只改了两处名单：
//   pan_web_login.dart 的 PanWebLoginSpec.all（已去 115）
//   pan_settings_page.dart 的 _webLoginKinds（已去 115）
// 但 lib/ui/widgets/pan_qr_login_dialog.dart:144 还有第三份同名
// _webLoginKinds 仍含 '115' ⇒ 扫码弹窗里 115 的「网页登录」按钮还在。
// 有兜底（showPanWebLogin 的 spec==null 弹如实说明）保证点了有反馈，
// 但按钮本身该消失 —— N3a 把弹窗改为读真源，根治"两道闸门只改一道"。
// ```
//
// # 本门禁钉什么
// ```text
// N1 ★ 同真源：剥注释后，弹窗源码不许再有任何「盘种名单字面量」
//      （集合/列表字面量里出现盘种 code 即第二份手抄名单），
//      且必须读 PanWebLoginSpec 真源；
//      注入证红：把 `Set<String> _webLoginKinds = <String>{'quark','uc','baidu','115'}`
//      加回弹窗 ⇒ N1 红。
// N2 115 按钮不在 + 改渲染撤除原因原句（直接读
//      panWebLoginUnsupportedReason('115')，不复制文案）；
// N3 quark/uc/baidu 三家的按钮与行为零变化（按钮 key/置灰判据/回调链路原样）。
// ```
//
// # 为什么是源码级断言而不是 widget 测试
// ```text
// 仓库根目录有 sourin_core.dll（见 lib/core/ffi.dart 头注释）：弹窗 initState
// 会真调 pan_qr_login_start（FFI）—— flutter test 里碰真 FFI 是本仓明令
// 禁止的假绿/假红形态（zz_t1050 同理走注入，但本弹窗没有注入点）。
// 故按钮的"有无"由真源函数（PanWebLoginSpec.of / panWebLoginRetired）在
// 本测试里直接判，渲染条件用源码级断言钉（与 t20261101_pan_web_login_115_test
// 的 C1/E1 同一风格）。
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/ui/widgets/pan_web_login.dart';

/// 剥掉 Dart 注释（行注释 + 块注释），正确跳过字符串字面量
/// （URL 里的 `//`、含 `/*` 的文案都不许误伤）——供 N1 做剥注释比对。
String stripDartComments(String src) {
  final out = StringBuffer();
  var i = 0;
  String? quote;
  while (i < src.length) {
    final c = src[i];
    final next = i + 1 < src.length ? src[i + 1] : '';
    if (quote != null) {
      out.write(c);
      if (c == r'\' && next.isNotEmpty) {
        out.write(next);
        i += 2;
        continue;
      }
      if (c == quote) quote = null;
      i += 1;
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
      i += 1;
      continue;
    }
    if (c == '/' && next == '/') {
      while (i < src.length && src[i] != '\n') {
        i += 1;
      }
      continue;
    }
    if (c == '/' && next == '*') {
      i += 2;
      while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
        i += 1;
      }
      i += 2;
      continue;
    }
    out.write(c);
    i += 1;
  }
  return out.toString();
}

/// 盘种 code 词表（与 Rust `PanKind::code()` 同一套词）
const _panKinds = <String>[
  '115',
  '123',
  'quark',
  'uc',
  'baidu',
  'aliyun',
  'tianyi',
  'xunlei',
  'guangya',
];

String _qrDialogSrc() => stripDartComments(
    File('lib/ui/widgets/pan_qr_login_dialog.dart').readAsStringSync());

void main() {
  test('N1 ★ 同真源：剥注释后弹窗源码不许有任何盘种名单字面量', () {
    final src = _qrDialogSrc();
    // 任何 <String>{...} / <String>[...] 字面量里出现盘种 code
    // ⇒ 就是第二份手抄名单（注定与 PanWebLoginSpec.all 漂移）。
    final literals =
        RegExp(r'<String>[\{\[]([^}\]]*)[\}\]]').allMatches(src);
    for (final m in literals) {
      final hits = _panKinds.where(m.group(1)!.contains).toList();
      expect(hits, isEmpty,
          reason: '★★ 注入证红：把手抄名单（如 '
              '<String>{\'quark\',\'uc\',\'baidu\',\'115\'}) 加回弹窗 ⇒ 本条红；'
              '字面量体：${m.group(1)}');
    }
    // 必须读真源：按钮有无由 PanWebLoginSpec 决定，不靠本地名单
    expect(src.contains('PanWebLoginSpec.of(widget.kind)'), isTrue,
        reason: '★ 按钮有无必须读 PanWebLoginSpec 真源（与设置页同源）');
    expect(src.contains('static const Set<String> _webLoginKinds'), isFalse,
        reason: '★ 手抄名单声明本身也不许再出现');
  });

  test('N2 115 按钮不在，改渲染撤除原因原句（不复制文案）', () {
    final src = _qrDialogSrc();
    // 115 没有按钮资格（真源判据本体）
    expect(PanWebLoginSpec.of('115'), isNull,
        reason: '★ 115 已撤：网页 cookie 产不出含 UID= 的凭据（is_logged 只认 UID=）');
    // 但必须渲染原因：直接读 panWebLoginUnsupportedReason，原句显示
    final reason = PanWebLoginSpec.panWebLoginUnsupportedReason('115');
    expect(reason, isNotNull);
    expect(reason!.contains('扫码'), isTrue, reason: '★ 原因必须指路扫码：$reason');
    expect(src.contains('panWebLoginUnsupportedReason(widget.kind)'), isTrue,
        reason: '★ 原因必须从真源函数取（一处写、处处用）');
    expect(src.contains("ValueKey<String>('pan-qr-login-web-retired')"), isTrue,
        reason: '★ 原因必须真的渲染出来（有 key 可查）');
    // 不许把文案复制进弹窗（文案只活在 pan_web_login.dart 一处）
    expect(src.contains('UID/CID/SEID'), isFalse,
        reason: '★ 撤除文案不许在弹窗里另写一份（改一处漏一处的老坑）');
  });

  test('N3 quark/uc/baidu 三家的按钮与行为零变化', () {
    // 真源：三家都有 spec ⇒ 按钮仍画；且都没被标成已撤
    for (final kind in ['quark', 'uc', 'baidu']) {
      expect(PanWebLoginSpec.of(kind), isNotNull, reason: '$kind 仍应可用');
      expect(PanWebLoginSpec.panWebLoginRetired(kind), isFalse,
          reason: '$kind 不许被误伤成已撤');
    }
    final src = _qrDialogSrc();
    // 渲染与行为链路原样保留：按钮 key / 置灰判据 / 回调链路 / 按钮文案
    expect(src.contains("ValueKey<String>('pan-qr-login-web')"), isTrue,
        reason: '★ 按钮必须还在（三家零变化）');
    expect(src.contains('panWebviewRuntimeAvailable()'), isTrue,
        reason: '★ Runtime 探测还在（缺失 ⇒ 置灰）');
    expect(src.contains('_webLoginAvailable == false ? null : _openWebLogin'),
        isTrue, reason: '★ 置灰判据原样（不许点了没反应）');
    expect(src.contains('showPanWebLogin(context, kind: widget.kind)'), isTrue,
        reason: '★ 点击回调仍走 showPanWebLogin');
    expect(src.contains("Text('网页登录')"), isTrue, reason: '★ 按钮文案不变');
  });
}
