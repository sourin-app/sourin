// ═══════════════════════════════════════════════════════════════════════
//  T27-13 —— ★★★ 缺陷④ 门禁：降级横幅出现时顶栏/底栏必须联动（一起收）
//            + 看门狗「播放正常却提示无法显示」的自愈/防误报
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字，两段）
//
// > 你看播放正常还提示 无法显示，然后顶部的那个提示条显示了，
// > 底部的那个居然没有一起显示
//
// > 然后上面的标题条和下面的操作条，根本就没一起联动显示，
// > 他们是共用一块逻辑的！！
//
// # 两条子问题
//
//  (a) 画面在正常播放，却弹「这个视频的画面无法显示（本机图形输出层没能
//      初始化）」——不该出现（或条件太宽）。
//  (b) 该横幅出现时，顶栏显示了、底栏没显示 ⇒ 两条「共用一块逻辑」的栏
//      没有联动。
//
// # 根因（已核实行号，见下）
//
//  (b) 底栏门控比顶栏多带了
//        `_liveAudioOnlyNotice == null && !_videoOutputDead`
//      ⇒ 横幅出现时底栏被这两条拦掉、顶栏照常 ⇒ 没联动。
//      修法 = 让顶栏的正常支也 AND 上这两条（横幅替代 chrome，
//      两栏一起收；横幅自带「返回」按钮 ⇒ 不困住用户）。
//
//  (a) `_watchVideoOutput` 的判决**没有回头路**：立旗后只有换流才复位；
//      而它也不看 `_sawFirstFrame` ⇒ 只要 10 秒预算内 `vo-configured`
//      因时序抖动没读成 'yes'，出过画面的正常播放也会被立旗 ⇒ 横幅赖着不走。
//      修法 = ① 出过帧就不再立旗；② 出帧这一刻把误立的旗清掉（自愈）。
//
// # 为什么用静态契约（读生产源码 + 剥注释 + 字面断言）
//
// 本机 flutter_tester 加载 libmpv-2.dll 会 native 崩溃（见 dart_test.yaml），
// 真渲染测不了；本仓既有惯例即静态契约（t27_w2 / zz_cr_play_bottom_bar /
// t68_android_adapt 同款）。判据是**源码里那几行判据本身**，不是复刻。
//
// ⚠️ 不写 `@Tags(['native-media'])` —— 本文件**不挂 PlayerPage**，
//    不加载 libmpv，走默认套件即可（CI 会跑）。
// ═══════════════════════════════════════════════════════════════════════

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _pagePath = 'lib/ui/player_page.dart';

/// 剥掉 `//` 行注释、`///` 文档注释、`/* */` 块注释（保留字符串字面量）
/// —— 逐字照抄 t27_w9_bar_linkage_test.dart:69-110（已验证实现）。
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  String? quote;
  while (i < src.length) {
    final c = src[i];
    if (quote != null) {
      out.write(c);
      if (c == r'\' && i + 1 < src.length) {
        out.write(src[i + 1]);
        i += 2;
        continue;
      }
      if (c == quote) quote = null;
      i++;
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
      i += 2;
      while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
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

/// 取 start 之后第一个 open 到配平 close 的文本
String sliceBalanced(String src, int start, String open, String close) {
  final begin = src.indexOf(open, start);
  expect(begin, greaterThanOrEqualTo(0), reason: '找不到「$open」');
  var depth = 0;
  for (var i = begin; i < src.length; i++) {
    if (src.startsWith(open, i)) {
      depth++;
      i += open.length - 1;
      continue;
    }
    if (src.startsWith(close, i)) {
      depth--;
      if (depth == 0) return src.substring(begin, i + close.length);
      i += close.length - 1;
    }
  }
  fail('括号没配平：从 $begin 起');
}

void main() {
  final raw = File(_pagePath).readAsStringSync();
  final page = stripComments(raw);

  // ═══════════════════════════════════════════════════════════════════
  //  (b) 顶栏/底栏联动：降级横幅出现时两栏一起收
  // ═══════════════════════════════════════════════════════════════════

  test('B1 底栏门控仍带 !_videoOutputDead 与 _liveAudioOnlyNotice == null', () {
    // 底栏真源（真值表模型来源）—— 缺陷④**不**动它，两条降级判据留在底栏。
    expect(
      page.contains('!_videoOutputDead'),
      isTrue,
      reason: '底栏门控的 `!_videoOutputDead` 不许被删（那是"横幅替代底栏"的判据）',
    );
    expect(
      page.contains('_liveAudioOnlyNotice == null'),
      isTrue,
      reason: '底栏门控的 `_liveAudioOnlyNotice == null` 不许被删',
    );
  });

  test('B2 顶栏正常支与底栏**同源**：都读唯一真源 `_chromeVisible`', () {
    // ★ T27-13（Owner 第 3/5 条）：顶栏正常支**不再内联**那串判据，改为与
    //   底栏共读 `bool get _chromeVisible`（11 项）⇒ 从构造上不可能分裂。
    //   缺陷④ 修好的「两条降级判据同源」现在落在唯一真源里。
    expect(
      page.contains('visible: _chromeVisible || _canUseTopBarBack,'),
      isTrue,
      reason: '★ 顶栏 visible 必须 = `_chromeVisible || _canUseTopBarBack`'
          '（正常支读唯一真源；错误态返回口不动）',
    );
    final ci = page.indexOf('bool get _chromeVisible =>');
    expect(ci, greaterThanOrEqualTo(0),
        reason: '★★ 唯一真源 `_chromeVisible` 不见了 —— 顶/底栏又各算各的门控（T27-13 失效）');
    final chromeExpr = page.substring(ci, ci + 400);
    expect(chromeExpr.contains('!_videoOutputDead'), isTrue,
        reason: '★★ 唯一真源必须含 `!_videoOutputDead` —— 「画面无法显示」'
            '横幅出现时两栏必须一起收（Owner 缺陷④）');
    expect(chromeExpr.contains('_liveAudioOnlyNotice == null'), isTrue,
        reason: '★★ 唯一真源必须含 `_liveAudioOnlyNotice == null`（同一条纪律）');
    // 错误态返回口不动：`_canUseTopBarBack` 仍是互斥的 `||` 分支，不被并进真源。
    expect(page.contains('_canUseTopBarBack,'), isTrue,
        reason: '★ 错误态返回口（`_canUseTopBarBack`）必须保持 `||` 分支 —— '
            'AND 掉它会把"不能播放时左上角返回"也抹掉（Owner 2026-10-09 报过）');
    // 底栏渲染点也读同一真源。
    expect(page.contains('if (!_chromeVisible && !keepForFade) {'), isTrue,
        reason: '★ 底栏的显隐必须读唯一真源 `_chromeVisible`（与顶栏读同一真源）');
  });

  test('B3 顶栏 fade 在横幅出现时钉成 dismissed（visible=false 只挡指针）', () {
    // `visible:false` 只驱动 IgnorePointer；"看不看得见"由 fade(Opacity) 决定。
    // ⇒ 横幅出现时 fade 必须也归 0，否则顶栏会"看得见却点不动"。
    final i = page.indexOf('fade: _canUseTopBarBack');
    expect(i, greaterThanOrEqualTo(0),
        reason: '顶栏 fade 的判据字面不见了（task-7 的错误态钉死也在这条上）');
    final fadeExpr = page.substring(i, i + 400);
    expect(fadeExpr.contains('kAlwaysDismissedAnimation'), isTrue,
        reason: '★★ 横幅出现时顶栏 fade 必须钉 `kAlwaysDismissedAnimation`（value 恒 0）'
            '—— 只把 visible 设 false 不改透明度，顶栏会"看得见却点不动"');
    expect(fadeExpr.contains('_videoOutputDead'), isTrue);
    expect(fadeExpr.contains('_liveAudioOnlyNotice'), isTrue);
  });

  // ═══════════════════════════════════════════════════════════════════
  //  (a) 看门狗：出过画面不立旗 + 出帧即清旗（自愈）
  // ═══════════════════════════════════════════════════════════════════

  test('A1 _watchVideoOutput 里有 `_sawFirstFrame` 守卫（出过帧不立旗）', () {
    final i = page.indexOf('Future<void> _watchVideoOutput(int token) async {');
    expect(i, greaterThanOrEqualTo(0), reason: '`_watchVideoOutput` 不见了');
    final body = sliceBalanced(page, i, '{', '}');
    // 循环内 + 超时后各一条 ⇒ 至少 2 处。
    final matches =
        RegExp(r'if \(_sawFirstFrame\) return;').allMatches(body).length;
    expect(matches, greaterThanOrEqualTo(2),
        reason: '★★ 出过画面（_sawFirstFrame）就**不许**再立旗 —— 循环内与超时后'
            '各要一条；否则"播放正常却提示无法显示"（Owner 缺陷④-a）会复发');
    // 立旗那一步仍在（真失败仍然要报）。
    expect(body.contains('_videoOutputDead = true'), isTrue,
        reason: '真·输出层建不起来时仍必须立旗（不许把修复做成"永不告警"）');
  });

  test('A2 首帧监听里出帧即清 `_videoOutputDead`（自愈）+ 早退前提含它', () {
    final i = page.indexOf('_player.stream.width.listen((w) {');
    expect(i, greaterThanOrEqualTo(0), reason: '首帧监听不见了');
    final body = sliceBalanced(page, i, '{', '}');
    // ① 自愈：出帧 ⇒ 清旗
    expect(body.contains('_videoOutputDead = false'), isTrue,
        reason: '★★ 画面真的出帧了（stream.width>0）⇒ 输出层显然是活的 ⇒ '
            '必须清掉误立的 `_videoOutputDead`，否则横幅没有别的清除路径（只有换流）'
            '⇒「播放正常却提示无法显示」的横幅会一直压着画面');
    // ② 早退前提必须含 `!_videoOutputDead`，否则自愈那一行永远走不到。
    expect(
      RegExp(r'if \(_sawFirstFrame &&[\s\S]{0,120}?_videoOutputDead\)')
          .hasMatch(body),
      isTrue,
      reason: '★★ 「已是正常播放」的早退判据必须含 `!_videoOutputDead` —— '
          '否则误立旗时这里直接 return，上面那条自愈永远执行不到',
    );
  });
}
