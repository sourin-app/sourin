// ══════════════════════════════════════════════════════════════════════
//  T27-14（w14-barform）门禁：弹幕控件 = B 站那种形态
//                          「一个开关,一个设置,弹出来面板直接操作」
// ══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字，2026-10-11 反馈第 1 条）
// ```text
// > 1.弹幕按照b站这种做,一个开关,一个设置,弹出来面板直接操作的
// ```
//
// # 改前（被 Owner 嫌的**两层**结构）
// ```text
// 底栏「弹幕」那枚是 popover 入口
//   点开 ⇒ 小菜单 [ 关闭弹幕 ] ── [ 弹幕设置 ]
//                          ↑ 点了才打开真正的设置面板（第三层）
// ⇒ 开关弹幕要「点开菜单 → 再点一下」；进设置要「点开菜单 → 再点一下」
//   —— 两次点击才到目的地，正是 Owner 要砍的那个形态。
// ```
//
// # 改后（本文件钉死的新形态，选项 (a) 两枚独立按钮）
// ```text
// 底栏两枚直连按钮：
//   ① 开关（subtitles / subtitles_off 图标）—— 点一下**直接**开关弹幕
//      （onTap: onDanmakuToggle，不再是 popoverId）
//   ② 设置（Icons.settings 齿轮，2026-10-15 换成齿轮）—— 点一下**一次**打开可直接操作的面板
//      （onTap: onDanmakuSettings → DanmakuSettingsDialog：滑杆直接拖）
// ```
//   ★ 为什么是 (a) 两枚按钮而不是 (b) 一枚按钮弹「开关+设置」面板：
//     Owner 字面就是「一个开关,一个设置」；B 站底栏也是**两枚**（弹幕开关
//     与齿轮分开）。且 (a) 让「开关」这一最高频动作**零层级**（B 站的开关
//     就是一键，不弹任何东西）—— 用 (b) 反而把开关又关回面板里，与
//     Owner「开关」二字相悖。
//
// # 门禁口径
//   A 源码契约（player_bottom_bar.dart，剥注释）
//     A1 `_danmakuPanel()`（两层菜单本体）**已不存在**
//     A2 开关那枚 `_BarAction` 是 `onTap: onDanmakuToggle`（不是 popoverId）
//     A3 设置那枚 `_BarAction` 是 **popover 入口**（`popoverId:
//         PlayerPopoverIds.danmakuQuick`）—— 点它弹 B 站那种**轻量悬浮窗**
//         （★ 1011 复审改判：不再直连大卡片；见 # 1011 复审说明）
//     A4 轻量悬浮窗里有「高级设置」一行，点它才进全屏大卡片
//     A5 `DanmakuSettingsDialog` 目标文件里仍有 4 根滑杆（字号/透明度/速度/占用区域）
//     A6 轻量悬浮窗自带 4 根**可直接拖**的滑杆（字号/不透明度/速度/显示区域）
//   B 行为契约（真挂 `PlayerBottomBar`，纯 widget 无 FFI）
//     B1 点开关 ⇒ 回调 onDanmakuToggle 恰好一次，且**不开任何 popover**
//     B2 点设置 ⇒ 打开 `danmakuQuick` popover（不再直连 onDanmakuSettings）
//     B3 底栏上有 `danmakuQuick` 的 popover 锚点（五枚 popover）
//
// # ★ 1011 复审（本文件的判据反转，别照着上一版回退）
// ```text
// 上一轮（w14 初版）把弹幕做成「开关 + 设置」两枚**直连**按钮，
//   设置那枚 `onTap: onDanmakuSettings` **直接**进全屏大卡片 ⇒
//   于是断言「设置枚没有 popoverId」。
// 1011 Owner 复审后的原话要的是 B 站那种**贴按钮的轻量悬浮窗**：
//   点齿轮 ⇒ 弹出「按类型过滤 + 四个可拖滑杆 + 高级设置」；
//   最后一行「高级设置」⇒ 才进全屏大卡片。
// ⇒ 设置那枚**必须**重新变成 popover 入口，判定随之反转为
//   「popoverId == danmakuQuick」。这是有意改判，不是把门禁改宽。
// ```
//
// # 为什么不做真 PlayerPage 渲染测
//   本机无 libmpv-2.dll ⇒ 构造 PlayerPage 即抛（dart_test.yaml）。但
//   `PlayerBottomBar` 是**纯 widget**（无 FFI），可直接挂载 —— 与
//   test/t27_w2_progress_thumb_test.dart 同款挂法。
//
// ⚠️ 不写 @Tags(['native-media']) —— 本文件不挂 PlayerPage，走默认套件即可。
// ══════════════════════════════════════════════════════════════════════

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

import 'package:sourin_spike/core/models.dart' show StreamCandidate;
import 'package:sourin_spike/ui/app_scaffold.dart' show AppThemeHost;
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/player/player_bottom_bar.dart';
import 'package:sourin_spike/ui/player/player_popover.dart';

// ═══════════════════════════════════════════════════════════════════════
//  源码切片工具（stripComments 逐字照抄 t27_w13_defect4_bar_linkage_test）
// ═══════════════════════════════════════════════════════════════════════

/// 剥掉 `//` 行注释、`/* */` 块注释（保留字符串字面量）
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

const String _barPath = 'lib/ui/player/player_bottom_bar.dart';

/// 取从 [anchor] 起、到下一个 `_BarAction(` 之前的片段 —— 用来确认某一枚
/// `_BarAction(...)` 的字段（key/anchor 都排在 `icon:` 之前，故锚在 key 上，
/// 这样 key/onTap/popoverId 全在窗口里）。
String _actionSlice(String stripped, String anchor) {
  final i = stripped.indexOf(anchor);
  expect(i, greaterThan(0), reason: '找不到 `$anchor`');
  // 往前退到本枚 _BarAction( 的开头，保证 key 字段也在窗口里
  final start = stripped.lastIndexOf('_BarAction(', i);
  final next = stripped.indexOf('_BarAction(', i + anchor.length);
  return stripped.substring(start < 0 ? i : start, next < 0 ? stripped.length : next);
}

// ═══════════════════════════════════════════════════════════════════════
//  纯 widget 夹具（照 t27_w2 的挂法）
// ═══════════════════════════════════════════════════════════════════════

class _Spy {
  int toggles = 0;
  int settings = 0;
  int fontScaleCalls = 0;
  int showScrollCalls = 0;
}

/// ★ 1011 复审：轻量悬浮窗的数据（值 + 回调）—— 复刻宿主传进来的那份
DanmakuQuickPanelData _quick(_Spy spy) => DanmakuQuickPanelData(
      fontScale: 1.0,
      opacity: 1.0,
      speed: 8.0,
      area: 1.0,
      showScroll: true,
      showTop: true,
      showBottom: true,
      colorOnly: false,
      onSetFontScale: (_) => spy.fontScaleCalls++,
      onSetOpacity: (_) {},
      onSetSpeed: (_) {},
      onSetArea: (_) {},
      onSetShowScroll: (_) => spy.showScrollCalls++,
      onSetShowTop: (_) {},
      onSetShowBottom: (_) {},
      onSetColorOnly: (_) {},
      onOpenAdvanced: () => spy.settings++,
    );

PlayerBottomBar _bar(_Spy spy, PopoverController controller) => PlayerBottomBar(
      controller: controller,
      playing: true,
      positionListenable: ValueNotifier<Duration>(Duration.zero),
      duration: const Duration(minutes: 24),
      isLive: false,
      rate: 1.0,
      volume: 60,
      muted: false,
      fullscreen: false,
      onTogglePlay: () {},
      onSeek: (_) {},
      onVolume: (_) {},
      onToggleMute: () {},
      onRate: (_) {},
      onToggleFullscreen: () {},
      onEpisodes: () {},
      hasEpisodes: false,
      showEpisodeNav: false,
      onNext: () {},
      hasNext: false,
      more: const PlayerMoreMenuData(groups: []),
      streams: const <StreamCandidate>[
        StreamCandidate(url: 'https://a/1.m3u8'),
        StreamCandidate(url: 'https://a/2.m3u8'),
      ],
      qualityOptions: const <PopoverOption<String>>[
        PopoverOption<String>(value: 'q1', label: '1080P', checked: true),
        PopoverOption<String>(value: 'q2', label: '720P'),
      ],
      onPickQuality: null,
      trackGroups: const <String, List<PopoverOption<String>>>{
        '字幕': <PopoverOption<String>>[
          PopoverOption<String>(value: 's1', label: '中文', checked: true),
        ],
      },
      onPickTrack: null,
      danmakuEnabled: false,
      danmakuBusy: false,
      onDanmakuToggle: () => spy.toggles++,
      onDanmakuSettings: () => spy.settings++,
      // ★ 1011 复审：传了它 ⇒ 齿轮才是 popover 入口（不传则退回旧行为）
      danmakuQuick: _quick(spy),
    );

Future<void> _pump(
  WidgetTester tester,
  _Spy spy,
  PopoverController controller,
) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1400, 900);
  addTearDown(tester.view.reset);
  final theme = AppTheme.themeFor(mui.Brightness.dark);
  final bar = _bar(spy, controller);
  await tester.pumpWidget(
    mui.MaterialApp(
      theme: theme,
      builder: (context, child) => AppThemeHost(
        data: theme,
        child: child ?? const SizedBox(),
      ),
      home: mui.Scaffold(
        body: mui.Material(
          type: mui.MaterialType.transparency,
          /*
           * ★ 1011 复审：浮层与底栏是**兄弟**（照生产 player_page 的整屏 Stack）。
           *   底栏自己返回 `Positioned` ⇒ 必须是 Stack 的直接子件，故内层再包
           *   一层 Stack；浮层挂在 `controller` 的 ListenableBuilder 下 ——
           *   与生产逐字同款，B2 才能真的看到悬浮窗画出来。
           */
          child: Stack(
            children: <Widget>[
              Stack(children: <Widget>[bar]),
              ListenableBuilder(
                listenable: controller,
                builder: (context, _) => Positioned.fill(
                  child: Align(
                    alignment: Alignment.bottomRight,
                    child: bar.buildPopoverLayer(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  /*
   * ★ 这里原来有一句 `while (tester.takeException() != null) {}` —— 已删。
   *
   * 那正是 `CONTRIBUTING.md`「⑥ 规矩二」要防的形态：把**失败静默吞掉**。
   * 夹具构建（挂底栏 + 悬浮层）若抛错，异常被这里丢弃 ⇒ 下面各测试的回调
   * 断言（toggles/settings/openId）**仍可能通过** ⇒ 门禁漏报。
   * 本夹具不挂 PlayerPage（`PlayerBottomBar` 是纯 widget，无 FFI、无 libmpv）
   * ⇒ **没有任何已知的原生异常需要放行**。构建期若抛错，就让它抛出来。
   */
}

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  A：源码契约（两层菜单已拆、两枚直连按钮就位）
  // ═══════════════════════════════════════════════════════════════════

  test('A1 两层弹幕菜单（_danmakuPanel）已不存在', () {
    final bar = stripComments(File(_barPath).readAsStringSync());
    expect(bar.contains('_danmakuPanel'), isFalse,
        reason: '★ 两层菜单本体必须删掉 —— 留着它就等于弹幕又回到「点开菜单再点一下」');
    // 改前那条判据的两行字面（「关闭弹幕/开启弹幕」+「弹幕设置」行）也不该有
    expect(bar.contains("label: danmakuEnabled ? '关闭弹幕' : '开启弹幕'"), isFalse,
        reason: '★ 那个「关闭弹幕」菜单行必须消失');
  });

  test('A2 开关那枚直连 onDanmakuToggle（不是 popoverId）', () {
    final bar = stripComments(File(_barPath).readAsStringSync());
    final slice = _actionSlice(bar, 'key: danmakuToggleKey');
    expect(slice.contains('onTap: onDanmakuToggle,'), isTrue,
        reason: '★ 开关必须**直接**开关弹幕（Owner：一个开关）');
    expect(slice.contains('popoverId:'), isFalse,
        reason: '★★ 开关这枚不许再挂 popover —— 一挂就回到两层结构');
    expect(slice.contains('key: danmakuToggleKey'), isTrue,
        reason: '★ 开关必须带 danmakuToggleKey（门禁抓手）');
    /*
     * ★ 2026-10-15（Owner：「弹幕设置的 icon 不符，找一下有没有跟弹幕类似的 icon」）
     *   从 subtitles/subtitles_off（**字幕**图标）换成 comment/comments_disabled
     *   （**弹幕气泡**）—— 弹幕是飘过去的评论，不是字幕，
     *   字幕图标是那个“圆角方框+几道横线”的闭幕形状。
     *   钉住的**语义**没变：图标随开关态切换（开/关 各一枚）。
     */
    expect(slice.contains('icon: danmakuEnabled ? Icons.comment'), isTrue,
        reason: '★ 开关图标随开关态切换（开=comment / 关=comments_disabled）');
  });

  test('A3 设置那枚是 popover 入口（弹轻量悬浮窗，不再直连大卡片）', () {
    final bar = stripComments(File(_barPath).readAsStringSync());
    final slice = _actionSlice(bar, 'key: danmakuSettingsKey');
    // ★ 1011 复审改判：设置这枚 = 轻量悬浮窗入口（popoverId）
    expect(slice.contains('popoverId:'), isTrue,
        reason: '★★ 设置必须弹 popover 小窗（Owner 要 B 站那种悬浮窗）');
    expect(slice.contains('PlayerPopoverIds.danmakuQuick'), isTrue,
        reason: '★ 入口 id = danmakuQuick');
    // ★ 2026-10-15（Owner：「弹旁边加一个设置的齿轮」）—— tune（滑杆图标）→ settings（齿轮）
    expect(slice.contains('icon: Icons.settings,'), isTrue,
        reason: '★ 设置图标 = 齿轮（与弹幕开关配成一对）');
  });

  test('A4 轻量悬浮窗有「高级设置」一行 ⇒ 回到全屏大卡片', () {
    final bar = stripComments(File(_barPath).readAsStringSync());
    expect(bar.contains("label: '高级设置'"), isTrue,
        reason: '★★ 悬浮窗最后一行必须是「高级设置」（Owner：高级设置入口）');
    expect(bar.contains('onTap: d.onOpenAdvanced'), isTrue,
        reason: '★ 那一行的动作 = 打开全屏大卡片（宿主 onDanmakuSettings）');
    expect(bar.contains('PlayerPopoverIds.danmakuQuick'), isTrue,
        reason: '★ 悬浮窗的 popover id = danmakuQuick（不再是旧的 danmaku）');
  });

  test('A5 全屏大卡片「直接操作」：4 根显示滑杆仍在 DanmakuSettingsDialog 里', () {
    final dlg = File('lib/ui/widgets/danmaku_settings_dialog.dart')
        .readAsStringSync();
    // 高级设置这一条路的终点 —— 大卡片能力一个没丢
    for (final label in const ['字号', '透明度', '速度', '显示区域']) {
      expect(dlg.contains("'$label'"), isTrue,
          reason: '★「$label」滑杆必须仍在大卡片里（高级设置路可达）');
    }
    expect(dlg.contains('Slider('), isTrue, reason: '★ 滑杆本体');
  });

  test('A6 轻量悬浮窗自带 4 根可直接拖的滑杆 + 3 枚类型开关', () {
    final bar = stripComments(File(_barPath).readAsStringSync());
    // 四根滑杆（直接拖 = 直接操作）
    for (final t in const ['字号', '不透明度', '速度', '显示区域']) {
      expect(bar.contains("label: '$t'"), isTrue,
          reason: '★ 悬浮窗里「$t」滑杆必须在（Owner：弹出来面板直接操作）');
    }
    // 三枚类型开关：滚动 / 顶部 / 底部
    for (final t in const ['滚动', '顶部', '底部']) {
      expect(bar.contains("label: '$t'"), isTrue,
          reason: '★「$t」类型开关必须在');
    }
    expect(bar.contains('Slider('), isTrue, reason: '★ 滑杆本体在底栏文件里');
  });

  // ═══════════════════════════════════════════════════════════════════
  //  B：行为契约（真挂 PlayerBottomBar）
  // ═══════════════════════════════════════════════════════════════════

  testWidgets('B1 点开关 ⇒ onDanmakuToggle 恰好一次，且不开 popover', (t) async {
    final spy = _Spy();
    final controller = PopoverController();
    addTearDown(controller.dispose);
    await _pump(t, spy, controller);

    final toggle = find.byKey(PlayerBottomBar.danmakuToggleKey);
    expect(toggle, findsOneWidget, reason: '★ 开关那枚必须在底栏上');

    await t.tap(toggle);
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));

    expect(spy.toggles, 1, reason: '★★ 点一下开关必须直接开关弹幕（一层）');
    expect(spy.settings, 0, reason: '★ 点开关不该顺带开设置面板');
    expect(controller.openId, isNull,
        reason: '★★ 点开关**不许**弹任何 popover —— 弹了就回到两层结构');
  });

  testWidgets('B2 点设置 ⇒ 打开 danmakuQuick 轻量悬浮窗（不直连大卡片）', (t) async {
    final spy = _Spy();
    final controller = PopoverController();
    addTearDown(controller.dispose);
    await _pump(t, spy, controller);

    final settings = find.byKey(PlayerBottomBar.danmakuSettingsKey);
    expect(settings, findsOneWidget, reason: '★ 设置那枚必须在底栏上');

    await t.tap(settings);
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));

    expect(controller.openId, 'danmakuQuick',
        reason: '★★ 点设置必须弹出轻量悬浮窗（Owner：B 站那种）');
    expect(spy.settings, 0,
        reason: '★ 点齿轮**不直接**进大卡片 —— 先弹小窗（高级设置那行才进）');
    expect(spy.toggles, 0, reason: '★ 点设置不该顺带开关弹幕');

    // 悬浮窗本体真的画出来了（是「一次点开可操作」的判据）
    expect(find.byKey(PlayerBottomBar.danmakuQuickPanelKey), findsOneWidget,
        reason: '★ 轻量悬浮窗面板必须可见');
  });

  testWidgets('B3 底栏上有 danmakuQuick 的 popover 锚点（五枚 popover）', (t) async {
    final spy = _Spy();
    final controller = PopoverController();
    addTearDown(controller.dispose);
    await _pump(t, spy, controller);

    final anchors = find.byWidgetPredicate(
      (w) => w is PopoverAnchorButton,
    );
    final ids = <String>{
      for (final w in anchors.evaluate())
        if (w.widget is PopoverAnchorButton)
          (w.widget as PopoverAnchorButton).id,
    };
    expect(ids.contains('danmakuQuick'), isTrue,
        reason: '★★ 底栏必须有 danmakuQuick 的 popover 锚点（弹幕轻量悬浮窗）');
    // 阳性对照：其余四枚仍在（没有误删别的入口）
    for (final id in const ['rate', 'quality', 'tracks', 'more']) {
      expect(ids.contains(id), isTrue,
          reason: '★ $id 的 popover 锚点必须还在（本轮只动弹幕）');
    }
  });
}
