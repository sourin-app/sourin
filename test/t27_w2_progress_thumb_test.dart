// ═══════════════════════════════════════════════════════════════════════
//  T27-02：进度条白色定位点（thumb）—— 回归门禁
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
//
// > 2.进度条这里的白色那个定位的没了
//
// # 取证（png_probe 复核 .probe/ops/fb/fig2.png，996x49）
//
//     --find 255 255 255 12 → n=80 bbox=(5,24)-(981,32)：亮像素全部落在
//     左右两端的时间文字上；--crop 120 10 700 30（进度条中段）→ 全暗。
//     代码侧：lib/ui/player/player_bottom_bar.dart 的 PlayerProgressSlider
//     Stack 只有 轨道(white24)/缓冲(white38)/已播(#32C7FF) 三层
//     —— 不是「画了被盖住」，是从来没画。
//
// # 门禁口径（任务书 ④）
//
//     A 源码断言：PlayerProgressSlider 的 Stack children 里存在 thumb 元素
//       （Positioned + 圆形 BoxDecoration，常量收口 thumbDiameter/thumbColor/thumbKey）
//     B 渲染断言：挂载生产 PlayerBottomBar（isLive=false），pump 后
//       (thumbX, centerY) 的 hitTest 命中路径里有 thumb 的 RenderObject，
//       且颜色不透明、relative luminance > 0.5
//     C 行为断言：拖动 → onSeek 收到对应时长；position notifier 更新 →
//       thumb 中心移动到新比例位置（证明 thumb 与进度同一条重建路径：
//       PlayerBottomBar._progressRow 的 ValueListenableBuilder<Duration>）
//     D 直播对照：isLive=true 不渲染 _progressRow ⇒ 无 thumb（行为不变）
//
// ★ 为什么挂整条 PlayerBottomBar 而不是裸挂 PlayerProgressSlider：
//   任务书要求「确认 thumb 在同一重建路径里」—— 底栏的 _progressRow 用
//   ValueListenableBuilder<Duration> 驱动 PlayerProgressSlider.position，
//   只有挂真底栏 + 改真 notifier 才能证明这一点（自证裸件不算实测）。
//   PlayerBottomBar 是纯 Widget（无 FFI），挂法照
//   test/zz_cr_play_bottom_bar_test.dart 的既有先例。
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

import 'package:sourin_spike/core/models.dart' show StreamCandidate;
import 'package:sourin_spike/ui/app_scaffold.dart' show AppThemeHost;
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/player/player_bottom_bar.dart';
import 'package:sourin_spike/ui/player/player_popover.dart';

/// ★ thumb 的 key 在修复前不存在 —— 源码断言用字符串 key 常量对齐
///（实现里是 ValueKey<String>('t27-progress-thumb')），渲染断言也用
/// Key('t27-progress-thumb') 构造等价 key 去 find，这样修复前能编译、
/// 断言真正跑起来后**红在断言**（thumb 缺失），而不是红在编译错误。
const String kThumbKeyId = 't27-progress-thumb';
Key get kThumbKey => const ValueKey<String>(kThumbKeyId);

/// 读生产源码并剥掉注释（本仓惯例：注释里常引用旧写法，不剥会假红/假绿）
String _src(String path) {
  final raw = File(path).readAsStringSync();
  return raw
      .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), ' ')
      .replaceAll(RegExp(r'//[^\n]*'), ' ');
}

class _Spy {
  final List<Duration> seeks = <Duration>[];
  void onSeek(Duration d) => seeks.add(d);
}

const Duration _kTotal = Duration(minutes: 24);

PopoverController _newController() => PopoverController();

PlayerBottomBar _bar(_Spy spy, ValueNotifier<Duration> position,
        {bool isLive = false}) =>
    PlayerBottomBar(
      controller: _newController(),
      playing: true,
      positionListenable: position,
      duration: _kTotal,
      isLive: isLive,
      rate: 1.0,
      volume: 60,
      muted: false,
      fullscreen: false,
      onTogglePlay: () {},
      onSeek: spy.onSeek,
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
      streams: const <StreamCandidate>[],
      qualityOptions: const <PopoverOption<String>>[],
      onPickQuality: null,
      trackGroups: const <String, List<PopoverOption<String>>>{},
      onPickTrack: null,
    );

/// 挂载环境照抄 test/zz_cr_play_bottom_bar_test.dart：
/// ⚠️ 必须自己补一层 Material（IconButton/PopoverRow 需要 Material 祖先）。
Future<void> _pump(
  WidgetTester tester,
  _Spy spy,
  ValueNotifier<Duration> position, {
  bool isLive = false,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1400, 900);
  addTearDown(tester.view.reset);
  final theme = AppTheme.themeFor(mui.Brightness.dark);
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
          child: _bar(spy, position, isLive: isLive),
        ),
      ),
    ),
  );
  while (tester.takeException() != null) {}
}

/// thumb 所在的那条 18px 高的进度 Stack（= slider 自身的 bounds）
Rect _sliderRect(WidgetTester t) => t.getRect(
      find
          .ancestor(
            of: find.byKey(kThumbKey),
            matching: find.byType(Stack),
          )
          .first,
    );

void main() {
  testWidgets('A+B：thumb 存在、位于内缩端点处、命中不透明亮色',
      (tester) async {
    final pos = ValueNotifier<Duration>(const Duration(minutes: 6)); // 0.25
    addTearDown(pos.dispose);
    await _pump(tester, _Spy(), pos);

    final thumb = tester.getRect(find.byKey(kThumbKey));
    final slider = _sliderRect(tester);
    /*
     * ★★★ Owner 1011 反馈②：thumb 中心**不再**跑满 slider.width
     * ```text
     * 修前：center = slider.left + ratio*slider.width
     *        ⇒ ratio=0 时中心落在左边界上 ⇒ 圆的左半边被 Stack 裁掉
     *          （Owner 原话「进度条的圆圈在初始阶段被截掉了半个」）。
     * 修后：中心在 [left+r, right-r] 这段里跑（r = thumbDiameter/2）
     *        ⇒ 圆在两端都**完整可见**。
     * ```
     * ⇒ 期望值必须跟着改成内缩公式，否则这条门禁会把**缺陷几何**当成正确。
     */
    const r = 6.0; // PlayerProgressSlider.thumbDiameter / 2
    final expectedCx = slider.left + r + 0.25 * (slider.width - 2 * r);
    expect((thumb.center.dx - expectedCx).abs(), lessThan(1.5),
        reason: 'thumb 中心 x 应 = left+r+ratio*(w-2r)（内缩端点公式）');
    expect((thumb.center.dy - slider.center.dy).abs(), lessThan(1.5),
        reason: 'thumb 应垂直居中于进度条');

    /*
     * ★ 本缺陷的**直接判据**：thumb 完整落在 slider 内（左右都不越界）。
     *   修前 ratio=0 ⇒ thumb.left = slider.left - 6 ⇒ 越界 6px 被裁掉半个。
     */
    expect(thumb.left, greaterThanOrEqualTo(slider.left - 0.5),
        reason: '★ thumb 不许越出左边界（修前 ratio=0 时 left=-6 被裁半个）');
    expect(thumb.right, lessThanOrEqualTo(slider.right + 0.5),
        reason: '★ thumb 不许越出右边界');

    // 不透明的亮色（key 在 Positioned 上，颜色读它子孙里的 DecoratedBox）
    final box = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byKey(kThumbKey),
        matching: find.byType(DecoratedBox),
      ),
    );
    final c = (box.decoration as BoxDecoration).color!;
    expect(c.alpha, 0xFF, reason: 'thumb 必须完全不透明（业主要的是「白色定位点」）');
    expect(c.computeLuminance(), greaterThan(0.5), reason: 'thumb 亮度必须够');

    // (thumbX, centerY) 的真实 hitTest 命中路径里必须有 thumb 本体
    final hit = tester.hitTestOnBinding(thumb.center);
    final thumbRender =
        tester.renderObject(find.byKey(kThumbKey));
    expect(
      hit.path.any((e) => identical(e.target, thumbRender)),
      isTrue,
      reason: '(thumbX, centerY) 必须命中 thumb 的 RenderObject',
    );
  });

  testWidgets('C：拖动 → onSeek；notifier 更新 → thumb 移动（同一重建路径）',
      (tester) async {
    final pos = ValueNotifier<Duration>(const Duration(minutes: 6)); // 0.25
    addTearDown(pos.dispose);
    final spy = _Spy();
    await _pump(tester, spy, pos);

    final before = tester.getRect(find.byKey(kThumbKey));
    final slider = _sliderRect(tester);

    // 从 thumb 上起手向右拖 120px：应触发 onSeek，且 seek 到比 6min 晚的时刻
    await tester.drag(
        find.byKey(kThumbKey), const Offset(120, 0));
    await tester.pump();
    expect(spy.seeks, isNotEmpty, reason: '拖动必须触发 onSeek');
    final seeked = spy.seeks.last;
    expect(seeked, greaterThan(const Duration(minutes: 6)));

    // 生产里 seek 后由播放器把真实位置写回 notifier（同一 ValueListenable）：
    // 这里走同一条路径，thumb 必须跟到 seeked 对应的比例位置
    pos.value = seeked;
    await tester.pump();

    final after = tester.getRect(find.byKey(kThumbKey));
    expect(after.center.dx, greaterThan(before.center.dx),
        reason: 'position 更新后 thumb 必须向右移动');
    final ratio = seeked.inMilliseconds / _kTotal.inMilliseconds;
    // ★ Owner 1011 反馈②：与上面那条同一套**内缩端点**公式
    const r = 6.0;
    final expected = slider.left + r + ratio * (slider.width - 2 * r);
    expect((after.center.dx - expected).abs(), lessThan(1.5),
        reason: 'thumb 应停在 seeked 对应比例位置（内缩端点公式）');
  });

  testWidgets('D：isLive=true 不渲染进度行 ⇒ 无 thumb（直播行为不变）',
      (tester) async {
    final pos = ValueNotifier<Duration>(const Duration(minutes: 6));
    addTearDown(pos.dispose);
    await _pump(tester, _Spy(), pos, isLive: true);

    expect(find.byType(PlayerProgressSlider), findsNothing);
    expect(find.byKey(kThumbKey), findsNothing);
  });

  test('A：源码断言 —— PlayerProgressSlider 的 Stack children 里有 thumb 元素',
      () {
    final all = _src('lib/ui/player/player_bottom_bar.dart');
    final start = all.indexOf('class PlayerProgressSlider');
    expect(start, greaterThan(0), reason: '找不到 PlayerProgressSlider 类');
    final src = all.substring(start);

    // 常量收口（实现与门禁同源，不许散落写死）
    expect(src, contains('static const double thumbDiameter = 12;'));
    expect(
      RegExp(r'static const Color thumbColor = Colors\.white;').hasMatch(src),
      isTrue,
    );
    expect(
      RegExp(r'static const Key thumbKey = ValueKey<String>\(').hasMatch(src),
      isTrue,
    );

    // Stack children 里的 thumb：圆形、不透明白、中心走**内缩端点**区间
    expect(RegExp(r'child: const DecoratedBox\(').hasMatch(src), isTrue);
    expect(src, contains('key: thumbKey,'));
    expect(src, contains('shape: BoxShape.circle,'));
    expect(src, contains('color: thumbColor,'));
    /*
     * ★★★ Owner 1011 反馈②（这条判据的方向**被本轮改动反转了**，别照着旧注释回退）
     * ```text
     * 修前钉的是：left = (pos/total)*w - thumbDiameter/2
     *   —— 那正是「初始阶段被截掉半个」的缺陷几何（ratio=0 ⇒ left=-6）。
     * 修后：中心必须先内缩一个半径（centerX(ratio) = r + ratio*trackW），
     *   再由中心反推 left ⇒ 圆在两端都完整可见。
     * ```
     * ⚠️ 断言「存在内缩区间」而不是钉死一整行字面量 —— 后者会让任何
     *    等价重写都假红（本仓反复踩过这个形态）。
     */
    expect(RegExp(r'final trackW = \(w - thumbDiameter\)').hasMatch(src), isTrue,
        reason: '必须存在内缩后的行进区间 trackW = w - thumbDiameter');
    expect(RegExp(r'double centerX\(double ratio\) => r \+ ratio \* trackW;')
            .hasMatch(src),
        isTrue,
        reason: 'thumb 中心必须走内缩端点公式 centerX(ratio) = r + ratio*trackW');
    expect(RegExp(r'left: centerX\(pos / total\) - r,').hasMatch(src), isTrue,
        reason: 'thumb 的 left 必须由 centerX 反推（保证两端不越界）');
    expect(
        RegExp(r'left:\s*\(pos / total\) \* w\s*-\s*thumbDiameter / 2')
            .hasMatch(src),
        isFalse,
        reason: '★ 旧缺陷几何（中心跑满 w）**不许**再出现 —— 它会让两端各裁半个圆');
  });
}