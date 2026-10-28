// ═══════════════════════════════════════════════════════════════════════
//  网盘源的「登录」必须是二维码弹窗，不能是空白
// ═══════════════════════════════════════════════════════════════════════
//
// # 由来（Owner 2026-10-28 逐字）
// ```text
// > 如果是需要网盘登录 应该提示 然后点击登录出现二维码进行登录，
// > 而不是 点击登录 出现空白
// ```
// 根因：`showProviderLoginDialog` 画的是「源自己声明的登录字段」，
// 网盘类 csp 源没有任何字段 ⇒ 弹出来是一片空白。
//
// # 判据
// ```text
// ① 8 个网盘源 id 必须映射到盘种 code；非网盘源必须返回 null（走原来那套）；
// ② 弹窗必须**有内容**：标题带盘种名、有二维码区（无核心层时降级成可读错误，
//    也不许空白）。
// ```
// 注入：把 `panKindOfProvider` 里 'csp-pan115' 那条删掉 ⇒ ① 红。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/ui/widgets/pan_qr_login_dialog.dart';

void main() {
  test('① 网盘源 id → 盘种 code（8 个）/ 非网盘 → null', () {
    const map = <String, String>{
      'csp-pan115': '115',
      'csp-pan123': '123',
      'csp-pan-ali': 'aliyun',
      'csp-pan-tianyi': 'tianyi',
      'csp-pan-xunlei': 'xunlei',
      'csp-pan-guangya': 'guangya',
      'csp-pan-share': 'uc',
      'csp-pan-uc': 'uc',
      'csp-pan-quark': 'quark',
    };
    map.forEach((id, kind) {
      expect(panKindOfProvider(id), kind, reason: '★ $id 必须映射到 $kind');
    });
    // 反空真/防误伤：普通源不许被当成网盘
    for (final id in <String>['csp-bili', 'csp-app99', 'tvbox_agg', 'demo']) {
      expect(panKindOfProvider(id), isNull,
          reason: '★ $id 不是网盘源，必须走原来的登录面板（否则普通源会弹出二维码）');
    }
  });

  test('② 盘种 code → 中文名（用户看得懂）', () {
    expect(panKindDisplay('115'), '115 网盘');
    expect(panKindDisplay('aliyun'), '阿里云盘');
    expect(panKindDisplay('guangya'), '光鸭云盘');
    // 认不出就原样显示，不许显示空
    expect(panKindDisplay('weird'), 'weird');
  });

  test('③ 登录入口按源 id 分流：网盘走扫码，其余走原面板', () {
    /*
     * 源码级判据（不是行为级）：这里守的是**分流顺序**——
     * 分流必须发生在 `ProviderLoginPanel(` 之前，否则网盘源还是会先画出那个空面板。
     * 行为级（弹窗真的画出来）在人工实机验证里做：那段需要核心层（qr start/poll），
     * `flutter test` 里没有 dll，硬造 fake 只能测到 fake 自己。
     */
    final src = File('lib/ui/widgets/provider_login_panel.dart').readAsStringSync();
    final branch = src.indexOf('panKindOfProvider(providerId)');
    // ⚠️ 不能取第一个 `ProviderLoginPanel(` —— 那是**构造函数定义**（文件前面），
    //    要取**分流之后**的那次使用。
    final panel = src.indexOf('ProviderLoginPanel(', branch);
    expect(branch, greaterThan(0), reason: '★ 登录入口必须按源 id 分流');
    expect(panel, greaterThan(0), reason: '★ 原面板必须还在（普通源仍走它）');
    expect(panel, greaterThan(branch));
    expect(branch, lessThan(panel),
        reason: '★★ 分流必须在画面板之前：否则网盘源先画出一个空面板（Owner 报的"空白"）');

    // 弹窗本身必须真的用扫码链路（不是又画一个空壳）
    final dlg = File('lib/ui/widgets/pan_qr_login_dialog.dart').readAsStringSync();
    expect(dlg.contains('pan_qr_login_start'), isTrue, reason: '★ 必须去要二维码');
    expect(dlg.contains('pan_qr_login_poll'), isTrue, reason: '★ 必须轮询扫码结果');
    expect(dlg.contains('QrView('), isTrue, reason: '★ 必须把二维码画出来（不是只显示一段文本）');
  });
}
