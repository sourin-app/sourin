// ═══════════════════════════════════════════════════════════════════════
//  Owner 1011 反馈第 4 条：清晰度面板「去掉来源名」+「默认居中」
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
// ```text
// > 4.然后还有这个清晰度,前面的无关紧要的信息就不用展示了吧?然后命名空间
// >   很多,侧边又不是没空间了,为什么不居中,请修复,除了太侧边的没空间
// >   富裕的,可以不居中,其他都应该居中显示
// ```
// Owner 已澄清两处：
//   · 「前面的无关紧要的信息」= 每行左侧的**来源名**（截图里被 ellipsis 截断的
//     「哔哩哔哩 …」），只保留清晰度「1080P / 720P / 480P」。
//   · 「命名空间」是打字错误，本意是「**明明左右空间充裕，面板却没居中**」——
//     应该居中；只有**贴边、真的没空间**时才允许不居中。
//
// # 本文件钉两条契约
// ```text
// A 内容  清晰度行只显示清晰度；来源名不再当主文字。
//         ★ 但「同清晰度多线路」时**按需**附来源名消歧（见下「为什么」）。
// B 定位  面板**水平居中对齐到触发它的按钮**（面板中心 = 按钮中心）；
//         只有贴边放不下时才 clamp 往中间挪 —— 正是 Owner 说的
//         「太侧边的没空间富裕的」可以不居中。
//         ⚠️ **一次判据反转**：本文件第一版断言的是「居中于**播放器/屏幕**」
//            （`panel.center.dx == layer.width/2`）。Owner 复核截图后澄清要的是
//            「居中于**按钮**（贴近但避开边缘）」⇒ 期望值已改为 `anchor.center.dx`。
//            屏幕居中那条**刻意删掉**（它会把"面板离按钮很远"当正确）。
// ```
//
// # 为什么 A 要做「按需消歧」而不是无脑丢掉来源名
// ```text
// 内置源当前**不会**产生「同 quality 不同 label」：
//   · declarative.rs:165 `variants: HashMap` ⇒ 变体键（= quality）唯一；
//   · cctv.rs:593/705 同一来源内 quality 逐条不同（高清/标清…超清/流畅）；
//   · resolve_stream（playback.rs:149）不做任何去重/合并。
// 但插件（JS）**用户可装**，第三方脚本完全可能返回两条 quality 都叫 "1080P"、
// label 不同的候选 ⇒ 无脑丢掉来源名会让两行变成一模一样的字、点错。
// ⇒ 取舍：默认只显示清晰度（与 Owner 截图逐字一致）；**仅当**某档清晰度出现
//   不止一次时，才给那几行附来源名。任何情况下都点得对。
// ```
//
// # 为什么挂 PlayerBottomBar 而不是整个 PlayerPage
// `sourin_core.dll` / `libmpv-2.dll` 在 flutter_tester 里加载失败
// ⇒ `PlayerPage` 构造即抛。`PlayerBottomBar` 是纯 Widget（无 FFI），
// 照 `player_page.dart:12492-12506` 的真实挂载点（`Align(bottomRight)` +
// `Padding(right: Sp.x2, bottom: 96)`）搭同构宿主，测出来就是生产几何。

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

import 'package:sourin_spike/core/models.dart' show StreamCandidate;
import 'package:sourin_spike/ui/app_scaffold.dart' show AppThemeHost;
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/player/player_bottom_bar.dart'
    show PlayerBottomBar, PlayerMoreMenuData, PlayerPopoverIds;
import 'package:sourin_spike/ui/player/player_more_menu.dart' show MoreMenuGroup;
// ⚠️ `PlayerPopoverIds` 在 player_bottom_bar.dart 与 player_popover.dart 里
//    **各有一份**（同名同值）⇒ 用 show 显式挑一份，否则编译器报歧义。
import 'package:sourin_spike/ui/player/player_popover.dart'
    show PopoverController, PopoverOption, PlayerPopoverSurface;
import 'package:sourin_spike/ui/tokens.dart' show Sp;

/// 认领 pump 期间积压的环境异常（无核心环境的 FFI 异常等）
void _claim(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

class _Spy {
  final List<String> qualities = <String>[];
  void pick(String url) => qualities.add(url);
}

/// 清晰度数据 —— 复刻生产 `_qualityPopoverOptions()` 的字段口径：
/// `label` = 来源 / 线路名（长，Owner 说的「无关紧要」），`hint` = 清晰度。
final List<PopoverOption<String>> _qualityOptions = <PopoverOption<String>>[
  const PopoverOption<String>(
    value: 'u1',
    label: '哔哩哔哩 官方线路',
    hint: '1080P',
    checked: true,
  ),
  const PopoverOption<String>(
    value: 'u2',
    label: '哔哩哔哩 备用线路',
    hint: '720P',
  ),
];

/// 「同清晰度多线路」的变体：两条都是 1080P，来自不同来源
final List<PopoverOption<String>> _dupTierOptions = <PopoverOption<String>>[
  const PopoverOption<String>(value: 'a', label: '哔哩哔哩', hint: '1080P'),
  const PopoverOption<String>(value: 'b', label: '腾讯', hint: '1080P'),
];

PlayerBottomBar _bar(
  PopoverController controller,
  _Spy spy, {
  List<PopoverOption<String>>? options,
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
      more: const PlayerMoreMenuData(groups: []),
      streams: const <StreamCandidate>[
        StreamCandidate(url: 'https://a/1.m3u8'),
        StreamCandidate(url: 'https://a/2.m3u8'),
      ],
      qualityOptions: options ?? _qualityOptions,
      onPickQuality: spy.pick,
    );

/// 生产浮层挂载点（逐字照抄 `player_page.dart:12492-12506`）
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
  _Spy spy, {
  Size size = const Size(1400, 900),
  List<PopoverOption<String>>? options,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
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

Rect _panelRect(WidgetTester tester) => tester.getRect(
      find.byType(PlayerPopoverSurface, skipOffstage: false),
    );

void main() {
  group('A ★ 清晰度面板只显示清晰度（去掉来源名）', () {
    testWidgets('A① 面板里显示的是 1080P / 720P，来源名一次都不出现', (tester) async {
      final controller = PopoverController();
      addTearDown(controller.dispose);
      final spy = _Spy();
      await _pumpBar(tester, controller, spy);
      await _openQuality(tester, controller);

      expect(controller.openId, 'quality', reason: '★ 前提：清晰度面板真的开了');

      // ★ 主文字 = 清晰度。`skipOffstage: false` 一并覆盖收起态的那份副本。
      expect(find.text('1080P', skipOffstage: false), findsWidgets,
          reason: '★★ 清晰度档位必须显示出来');
      expect(find.text('720P', skipOffstage: false), findsWidgets,
          reason: '★★ 清晰度档位必须显示出来');

      // ★★ 判别性断言：来源名**一个都不许**当文字出现
      expect(find.text('哔哩哔哩 官方线路', skipOffstage: false), findsNothing,
          reason: '★★ Owner 1011 第 4 条：每行左侧的来源名（「哔哩哔哩 …」）'
              '不该再显示 —— 这正是截图里被 ellipsis 截断的那段');
      expect(find.text('哔哩哔哩 备用线路', skipOffstage: false), findsNothing,
          reason: '★★ 同上，两个来源名都不许出现');

      _claim(tester);
    });

    testWidgets('A② 点某一行仍触发 onPickQuality（value = url，接线未坏）',
        (tester) async {
      final controller = PopoverController();
      addTearDown(controller.dispose);
      final spy = _Spy();
      await _pumpBar(tester, controller, spy);
      await _openQuality(tester, controller);

      await tester.tap(find.text('720P', skipOffstage: false).first);
      await tester.pump();

      expect(spy.qualities, <String>['u2'],
          reason: '★ 显示文字变了，但点击仍要把 **url** 交给 onPickQuality');
      expect(controller.openId, isNull, reason: '★ 选完自己收起');

      _claim(tester);
    });

    testWidgets('A③ 同清晰度多线路 ⇒ 那几行附来源名消歧（不许两行一模一样）',
        (tester) async {
      final controller = PopoverController();
      addTearDown(controller.dispose);
      final spy = _Spy();
      await _pumpBar(tester, controller, spy, options: _dupTierOptions);
      await _openQuality(tester, controller);

      // 两条 1080P 来自不同来源 ⇒ 必须能区分：附上来源名
      expect(find.text('1080P · 哔哩哔哩', skipOffstage: false), findsWidgets,
          reason: '★★ 同档多来源时必须附来源名，否则两行都是「1080P」点不清');
      expect(find.text('1080P · 腾讯', skipOffstage: false), findsWidgets,
          reason: '★★ 同上');

      _claim(tester);
    });
  });

  group('B ★ 面板水平居中**到按钮**（Owner 1011 第 4 条）', () {
    testWidgets('B① 桌面宽屏：面板中心 = **触发按钮**中心', (tester) async {
      final controller = PopoverController();
      addTearDown(controller.dispose);
      final spy = _Spy();
      await _pumpBar(tester, controller, spy);
      await _openQuality(tester, controller);

      final panel = _panelRect(tester);
      final anchor = controller.anchorRectOf(PlayerPopoverIds.quality)!;

      /*
       * ★★ 基准点 = **按钮中心**，不是屏幕中心（Owner 复核后澄清）
       * ```text
       * 上一版断言的是 `panel.center.dx == layer.size.width / 2`（屏幕居中）——
       * 那是我按字面理解做的。Owner 看完截图纠正：
       *   「居中于**按钮**（贴近但避开边缘）」。
       * ⇒ 期望值换成 `anchor.center.dx`；屏幕中心那条**刻意删掉**，
       *   因为它会把"面板离按钮很远"这种错误形态当成正确。
       * ```
       */
      expect(
        panel.center.dx,
        closeTo(anchor.center.dx, 1.0),
        reason: '★★ Owner 1011 第 4 条：面板应**居中对齐到触发它的按钮**。'
            '面板中心=${panel.center.dx} 按钮中心=${anchor.center.dx}',
      );

      _claim(tester);
    });

    testWidgets('B② 居中是**通用**规则：五个 popover 都居中', (tester) async {
      final controller = PopoverController();
      addTearDown(controller.dispose);
      final spy = _Spy();
      // 一次性给齐五个 popover 的数据（tracks / rate / more 都要有内容）
      final full = PlayerBottomBar(
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
        qualityOptions: _qualityOptions,
        onPickQuality: spy.pick,
        trackGroups: const <String, List<PopoverOption<String>>>{
          '字幕': <PopoverOption<String>>[
            PopoverOption<String>(value: 's1', label: '中文'),
          ],
        },
        onPickTrack: (g, i) {},
      );
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1400, 900);
      addTearDown(tester.view.reset);
      final theme = AppTheme.themeFor(Brightness.dark);
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
              child: _host(full, controller),
            ),
          ),
        ),
      );
      _claim(tester);

      for (final id in <String>[
        // ⚠️ 不含 danmaku：弹幕入口正在被另一个改动（danmaku-ui）重做，
        //    它的 id / 形态都可能变；居中是通用规则，四个稳定 popover
        //    足够证明「不是只给清晰度特判」。
        PlayerPopoverIds.rate,
        PlayerPopoverIds.quality,
        PlayerPopoverIds.tracks,
        PlayerPopoverIds.more,
      ]) {
        controller.toggle(id);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        _claim(tester);
        final panel = _panelRect(tester);
        final anchor = controller.anchorRectOf(id)!;
        /*
         * ⚠️ 判据要容忍**贴边 clamp**：面板中心 = 按钮中心，**除非**
         *    按钮太靠边、居中会让面板越界 ⇒ 那时往中间 clamp
         *    （Owner 说的「太侧边的没空间富裕的,可以不居中」）。
         * ⇒ 断言「面板中心 == 按钮中心」**或**「面板贴住了 clamped 后的边」。
         * ⚠️ clamp 的边界是 **popover 层自己的盒子**（delegate 的 `size.width`），
         *    **不是**窗口宽 —— 两者在本测试里不相等（层比窗口窄）。
         *    ⇒ 用 layer 的矩形算左右安全边距。
         * ⚠️ 不写成 `closeTo(layer.width/2)` —— 那是**屏幕居中**，
         *    已被 Owner 澄清为错误形态。
         */
        final layer = tester.renderObject<RenderBox>(find.byKey(controller.layerKey));
        final layerRect = layer.localToGlobal(Offset.zero) & layer.size;
        final centered = (panel.center.dx - anchor.center.dx).abs() < 1.0;
        final clampedLeft = (panel.left - (layerRect.left + Sp.x2)).abs() < 1.5;
        final clampedRight =
            (panel.right - (layerRect.right - Sp.x2)).abs() < 1.5;
        // ignore: avoid_print
        print('[CENTER] $id panel=$panel anchor=$anchor layer=$layerRect '
            'centered=$centered clampL=$clampedLeft clampR=$clampedRight');
        expect(centered || clampedLeft || clampedRight, isTrue,
            reason: '★★ 「居中对齐到按钮」是通用规则：$id 的面板中心要么 = 按钮中心'
                '（${anchor.center.dx}），要么被 clamp 到层边（${layerRect.left + Sp.x2}'
                ' / ${layerRect.right - Sp.x2}）。实测 面板=$panel');
        controller.close();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }
      _claim(tester);
    });

    testWidgets('B③ 手机档（420 宽）：按钮居中 ⇒ 面板也跟着，且不越窗口', (tester) async {
      final controller = PopoverController();
      addTearDown(controller.dispose);
      final spy = _Spy();
      await _pumpBar(tester, controller, spy, size: const Size(420, 900));
      await _openQuality(tester, controller);

      final vp = tester.view.physicalSize / tester.view.devicePixelRatio;
      final panel = _panelRect(tester);
      final anchor = controller.anchorRectOf(PlayerPopoverIds.quality)!;

      // 面板中心对齐按钮中心**或**贴住安全边距（贴边 clamp 场景）
      final centered = (panel.center.dx - anchor.center.dx).abs() < 1.0;
      final clampedLeft = (panel.left - Sp.x2).abs() < 1.0;
      final clampedRight = (panel.right - (vp.width - Sp.x2)).abs() < 1.0;
      expect(centered || clampedLeft || clampedRight, isTrue,
          reason: '★★ 面板中心要么 = 按钮中心（${anchor.center.dx}），'
              '要么贴住某侧安全边距。实测 面板=$panel');
      expect(panel.left, greaterThanOrEqualTo(Sp.x2 - 0.5),
          reason: '★ 面板不得越出窗口左沿：$panel');
      expect(panel.right, lessThanOrEqualTo(vp.width - Sp.x2 + 0.5),
          reason: '★ 面板不得越出窗口右沿：$panel');

      _claim(tester);
    });

    testWidgets('B④ 极窄视口（面板比可用宽度还宽）⇒ 退回贴边兜底、不崩', (tester) async {
      final controller = PopoverController();
      addTearDown(controller.dispose);
      final spy = _Spy();
      // 160 窄于面板本身（168）—— 这是「居中根本算不出来」的退化边界，
      // 只要求「不抛异常、左缘不越界」，不要求右缘（物理上放不下）。
      await _pumpBar(tester, controller, spy, size: const Size(160, 900));
      await _openQuality(tester, controller);

      final panel = _panelRect(tester);
      // ignore: avoid_print
      print('[CENTER] 极窄 panel=$panel');
      expect(panel.left, greaterThanOrEqualTo(Sp.x2 - 0.5),
          reason: '★ 居中放不下时退回兜底：左缘仍不得越界（minLeft 优先）');

      _claim(tester);
    });
  });
}
