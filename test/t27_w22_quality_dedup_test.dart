// ═══════════════════════════════════════════════════════════════════════
//  T27-W22 —— ★ 清晰度面板「消歧失败 ⇒ 折叠」门禁
//            （Owner 1011 复报：怎么有三个一模一样的 1080P?）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
// ```text
// > 卡顿已经好很多了,但是这里怎么有三个 1080 清晰度?
// ```
// （截图：`1080P · 哔哩哔...` ×3，然后 720P、480P）
//
// # 根因（两处共同造成；本门禁只看 UI 侧那一处）
// ```text
// Part 1（数据侧，不在本仓、也不该改）：用户的第三方插件 bilibili.js 把
//   best + 全部 backupUrl 都作为独立候选输出，quality 全等于 1080P，
//   来源名也几乎相同（「哔哩哔哩 1080P」/「…备用」）。
//
// Part 2（★ 本门禁钉的那处）：player_bottom_bar.dart 的 _qualityRows() 旧判据
//   只检查「同 tier 出现 >1」就附来源名消歧，**没检查消歧后各行是否真的不同**。
//   上面那种数据里 3 条的 label 几乎一样 ⇒ 附上后仍是三行重复字 ⇒ 消歧失败，
//   用户仍不知道该点哪个。
// ```
// ⇒ 修法：**消歧后文字确实互不相同**才展开成多行；做不到就**折叠**成一条，
//   保留「正在播放的那条（checked）」否则「第一条」。
//
// # 本文件钉 5 条契约（A 是主门禁：修前红 / 修后绿）
// ```text
// A 同 quality 同 label ×3 ⇒ 只显示一行（修前红：三行都写「1080P · 哔哩哔哩 1080P」）
// B 同 quality 不同 label  ⇒ 仍展开多行且带来源名（防改过头；修前绿）
// C 正常三档各一条         ⇒ 恰好三行、且**不带**来源名（防破坏 Owner 1011 第 4 条）
// D 阴性对照：某档只有一条 ⇒ 不得被折叠逻辑误伤（仍显示）
// E 正在播放那条必须保住：折叠后选中标记仍在、点它仍触发正确 value
// ```
//
// # 为什么挂 PlayerBottomBar 而不是整个 PlayerPage
// `libmpv-2.dll` 在 flutter_tester 里加载失败 ⇒ `PlayerPage` 构造即抛。
// `PlayerBottomBar` 是纯 Widget（无 FFI）⇒ 照 t27_w13_quality_center_test.dart
// 的真实挂载点搭同构宿主，测出来就是生产几何、读的是**真实渲染出来的行文字**
// （遵守 CONTRIBUTING 规矩二：读 element 树 / 渲染结果，不读源码字符串）。
//
// ⚠️ 断言一律遍历 `PopoverRow`（skipOffstage:false 覆盖收起态那份副本）
//    读 `label`，不写「源码含某字符串」那种恒真门禁。

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

import 'package:sourin_spike/core/models.dart' show StreamCandidate;
import 'package:sourin_spike/ui/app_scaffold.dart' show AppThemeHost;
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/player/player_bottom_bar.dart'
    show PlayerBottomBar, PlayerMoreMenuData, PlayerPopoverIds;
import 'package:sourin_spike/ui/player/player_more_menu.dart' show MoreMenuGroup;
import 'package:sourin_spike/ui/player/player_popover.dart'
    show PopoverController, PopoverOption, PopoverRow;
import 'package:sourin_spike/ui/tokens.dart' show Sp;

/// 认领 pump 期间积压的环境异常（无核心环境的 FFI 异常等）
void _claim(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

class _Spy {
  final List<String> qualities = <String>[];
  void pick(String url) => qualities.add(url);
}

/// 读**真实渲染出来的清晰度行文字**（label），按视觉顺序（y 升序）返回。
///
/// ★ 这是本门禁的判据来源 —— 不是源码字符串，是渲染结果。
List<String> _rowLabels(WidgetTester tester) {
  final widgets = tester
      .widgetList<PopoverRow>(find.byType(PopoverRow, skipOffstage: false))
      .toList();
  final found = <(double, String)>[];
  for (final w in widgets) {
    final e = find.byWidget(w, skipOffstage: false);
    final rect = tester.getRect(e);
    found.add((rect.top, w.label));
  }
  found.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final f in found) f.$2];
}

PlayerBottomBar _bar(
  PopoverController controller,
  _Spy spy, {
  required List<PopoverOption<String>> options,
}) =>
    PlayerBottomBar(
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
      more: const PlayerMoreMenuData(groups: <MoreMenuGroup>[]),
      streams: const <StreamCandidate>[
        StreamCandidate(url: 'https://a/1.m3u8'),
        StreamCandidate(url: 'https://a/2.m3u8'),
      ],
      qualityOptions: options,
      onPickQuality: spy.pick,
    );

/// 生产浮层挂载点（照 t27_w13_quality_center_test.dart，源自 player_page 真实挂载）
Widget _host(PlayerBottomBar bar, PopoverController controller) => Stack(
      children: <Widget>[
        bar,
        ListenableBuilder(
          listenable: controller,
          builder: (context, _) => Positioned.fill(
            child: Align(
              alignment: Alignment.bottomRight,
              child: Padding(
                padding: const EdgeInsets.only(right: Sp.x2, bottom: 96),
                child: bar.buildPopoverLayer(),
              ),
            ),
          ),
        ),
      ],
    );

/// ⚠️ 必须补一层 `Material`：`PopoverRow` 内部是 `InkWell`，没有 Material
///    祖先时面板一打开就抛 "No Material widget found"（环境问题，非缺陷）。
Future<void> _pumpBar(
  WidgetTester tester,
  PopoverController controller,
  _Spy spy,
  List<PopoverOption<String>> options,
) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1400, 900);
  addTearDown(tester.view.reset);
  final theme = AppTheme.themeFor(Brightness.dark);
  final bar = _bar(controller, spy, options: options);
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
          child: _host(bar, controller),
        ),
      ),
    ),
  );
  _claim(tester);
}

Future<void> _openQuality(WidgetTester tester, PopoverController controller) async {
  controller.toggle('quality');
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  _claim(tester);
}

/// 打开面板 → 收集行文字 → 关闭。
Future<List<String>> _render(
  WidgetTester tester,
  PopoverController controller,
  _Spy spy,
  List<PopoverOption<String>> options,
) async {
  await _pumpBar(tester, controller, spy, options);
  await _openQuality(tester, controller);
  expect(controller.openId, PlayerPopoverIds.quality,
      reason: '★ 前提：清晰度面板真的开了');
  final rows = _rowLabels(tester);
  // ignore: avoid_print
  print('[DEDUP] rows=$rows');
  return rows;
}

void main() {
  // ── 数据形态 1 ★ 主门禁：同 quality 同 label ×3（bilibili.js 那三行） ──
  final dupSameLabel = <PopoverOption<String>>[
    const PopoverOption<String>(
        value: 'u1', label: '哔哩哔哩 1080P', hint: '1080P', checked: true),
    const PopoverOption<String>(
        value: 'u2', label: '哔哩哔哩 1080P 备用', hint: '1080P'),
    const PopoverOption<String>(
        value: 'u3', label: '哔哩哔哩 1080P 备用', hint: '1080P'),
  ];

  // ── 数据形态 2 同 quality 不同 label（真能消歧） ──
  final dupDiffLabel = <PopoverOption<String>>[
    const PopoverOption<String>(
        value: 'a', label: '官方 HLS', hint: '1080P', checked: true),
    const PopoverOption<String>(value: 'b', label: 'CDN 直连', hint: '1080P'),
  ];

  // ── 数据形态 3 正常三档（每档一条） ──
  final normal = <PopoverOption<String>>[
    const PopoverOption<String>(
        value: 'q1', label: '腾讯 1080P', hint: '1080P', checked: true),
    const PopoverOption<String>(value: 'q2', label: '腾讯 720P', hint: '720P'),
    const PopoverOption<String>(value: 'q3', label: '腾讯 480P', hint: '480P'),
  ];

  testWidgets('A ★ 三个同 quality 同 label ⇒ 只显示一行（消歧失败则折叠）',
      (tester) async {
    final controller = PopoverController();
    addTearDown(controller.dispose);
    final spy = _Spy();
    final rows = await _render(tester, controller, spy, dupSameLabel);

    // ★ 主判据：三行重复字被折叠成一行。
    //   修前这里是 ['1080P · 哔哩哔哩 1080P','1080P · 哔哩哔哩 1080P 备用',
    //                '1080P · 哔哩哔哩 1080P 备用'] ⇒ 3 行 ⇒ 红。
    expect(rows.length, 1,
        reason: '★★ 同档三条消歧后仍分不开 ⇒ 必须折叠成一行。实测$rows');
    expect(rows, <String>['1080P'],
        reason: '★★ 折叠后保留的是「正在播放」那条 ⇒ 只显示清晰度「1080P」。实测$rows');

    // 判别性：三行重复字一个都不许出现（修前必然出现）
    expect(find.text('1080P · 哔哩哔哩 1080P', skipOffstage: false), findsNothing);
    expect(find.text('1080P · 哔哩哔哩 1080P 备用', skipOffstage: false),
        findsNothing);
    _claim(tester);
  });

  testWidgets('B 同 quality 不同 label ⇒ 仍展开多行且带来源名（防改过头）',
      (tester) async {
    final controller = PopoverController();
    addTearDown(controller.dispose);
    final spy = _Spy();
    final rows = await _render(tester, controller, spy, dupDiffLabel);

    expect(rows, <String>['1080P · 官方 HLS', '1080P · CDN 直连'],
        reason: '★★ 真能消歧（文字确实不同）⇒ 必须保留展开，别改过头。实测$rows');
    expect(find.text('1080P · CDN 直连', skipOffstage: false), findsWidgets);
    _claim(tester);
  });

  testWidgets('C 正常三档各一条 ⇒ 恰好三行、且不带来源名（Owner 1011 第 4 条）',
      (tester) async {
    final controller = PopoverController();
    addTearDown(controller.dispose);
    final spy = _Spy();
    final rows = await _render(tester, controller, spy, normal);

    expect(rows, <String>['1080P', '720P', '480P'],
        reason: '★★ 每档一条 ⇒ 逐字与旧行为一致：只显示清晰度、无来源名。实测$rows');
    // 来源名一个都不许出现
    expect(find.text('腾讯 1080P', skipOffstage: false), findsNothing);
    expect(find.text('腾讯 720P', skipOffstage: false), findsNothing);
    expect(find.text('腾讯 480P', skipOffstage: false), findsNothing);
    _claim(tester);
  });

  testWidgets('D ★ 阴性对照：某档只有一条 ⇒ 不被折叠逻辑误伤（仍显示）',
      (tester) async {
    final controller = PopoverController();
    addTearDown(controller.dispose);
    final spy = _Spy();
    // 1080P 三条（会被折叠）+ 该档只有一条的 720P（单条必须原样留存）
    final mixed = <PopoverOption<String>>[
      const PopoverOption<String>(
          value: 'u1', label: '哔哩哔哩 1080P', hint: '1080P', checked: true),
      const PopoverOption<String>(
          value: 'u2', label: '哔哩哔哩 1080P 备用', hint: '1080P'),
      const PopoverOption<String>(
          value: 'u3', label: '哔哩哔哩 1080P 备用', hint: '1080P'),
      const PopoverOption<String>(value: 'u4', label: '某源 720P', hint: '720P'),
    ];
    final rows = await _render(tester, controller, spy, mixed);

    expect(rows, <String>['1080P', '720P'],
        reason: '★★ 单条档（720P）绝不能被折叠逻辑牵连丢掉。实测$rows');
    _claim(tester);
  });

  testWidgets('E ★ 正在播放那条必须保住：折叠后选中标记仍在、点它触发正确 value',
      (tester) async {
    final controller = PopoverController();
    addTearDown(controller.dispose);
    final spy = _Spy();
    // 正在播的恰是「将被折叠」的那条（u2）
    final playingIsFolded = <PopoverOption<String>>[
      const PopoverOption<String>(
          value: 'u1', label: '哔哩哔哩 1080P', hint: '1080P'),
      const PopoverOption<String>(
          value: 'u2', label: '哔哩哔哩 1080P 备用', hint: '1080P',
          checked: true),
      const PopoverOption<String>(
          value: 'u3', label: '哔哩哔哩 1080P 备用', hint: '1080P'),
    ];
    await _render(tester, controller, spy, playingIsFolded);

    // ① 折叠后那一行的选中标记仍在（checked == true）
    final checked = tester
        .widgetList<PopoverRow>(find.byType(PopoverRow, skipOffstage: false))
        .where((r) => r.checked)
        .toList();
    expect(checked.length, 1,
        reason: '★★ 绝不能把正在播放那条折叠掉 ⇒ 对勾/高亮必须还在');
    expect(checked.single.label, '1080P',
        reason: '★★ 保留下来的应是「正在播放」的那条');

    // ② 点它仍触发正确 value（保留项自己的 value，不是被丢掉那条的）
    await tester.tap(find.text('1080P', skipOffstage: false).first);
    await tester.pump();
    expect(spy.qualities, <String>['u2'],
        reason: '★★ 折叠后 onTap 必须把**保留下来的那条**的 value 交回 onPickQuality');
    expect(controller.openId, isNull, reason: '★ 选完自己收起');
    _claim(tester);
  });
}
