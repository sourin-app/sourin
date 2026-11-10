// ═══════════════════════════════════════════════════════════════════════
//  R1：跨源同名频道**不许撞 key**（task-17 / 复核 task-7 的 R1）
// ═══════════════════════════════════════════════════════════════════════
//
// # 缺陷形态（为什么这是真风险，不是洁癖）
// ```text
// 列表是**跨源平铺**的（task-42：左侧不再分组，直接平铺）。
// 而频道 id 只保证**源内**唯一 —— 两个源都有 `cctv1` 是常态
// （`_visibleChannels` **不按 id 去重**）。
// ⇒ 行 key 若只拼 `channel.id`，兄弟节点出现两个相同 key。
//   `ListView(children:)` 不会触发 Duplicate keys 断言（那是 MultiChildRenderObject
//   的事，sliver 里是 SliverChildListDelegate 逐个 build），
//   但 sliver 的 key→element 匹配会歧义：
//     · 焦点节点可能落到"另一行的同一个 id"上（焦点串槽）
//     · `find.byKey` 多命中 ⇒ `getRect` 直接抛 "Too many elements"
//     · 极端情况下行状态（选中/高亮）串槽到同 id 的另一源行
// ```
//
// # 判据（本文件）
// ```text
// ① 两行的 key **互不相同**（且都按 `provider:id` 拼 —— 与生产同一个函数）
// ② `find.byKey` 各命中 **恰好 1 个**
// ③ 点击 A 行只回调 A 的频道对象、点 B 行只回调 B 的（不串台）
// ④ 渲染不抛异常（防"重复 key 引发的运行时断言"在别的形态下冒出来）
// ```
//
// # 为什么测 `LiveChannelList` 而不是 `LivePage`
// ```text
// 与 `t1013_live_filter_test` / `t48_live_page_all_channels_test` 同一道墙：
// `LivePageState._groups` 只由 FFI 填，隔离环境恒为空。
// `LiveChannelList` 是公开组件、频道由构造参数传入 ⇒ 能真的渲染出两行同 id。
// ```
//
// # ⚠️ 本文件**不覆盖**的相邻风险（如实记录，别当成已修）
// ```text
// 选中身份仍是 **id**：`LiveChannelList.selectedId` 只带 id
// ⇒ 跨源同 id 时**两行会同时高亮**（本文件第 ③ 条按现状钉住），
//   而 `LivePageState._providerOf(ch)` 也是**按 id 扫 `_groups`**
//   ⇒ 两个源有同 id 时"这一行属于哪个源"在**选中链路**上仍然有歧义。
// R1 只修了**行身份（key）**这一层；选中链路的歧义是另一件事，未修、未宣称。
// ```

// # 注入证据（红/绿读数见交付说明）
// ```text
// 把 `liveChannelTileKey`/`liveChannelHighlightKey` 里的 provider 去掉
// ⇒ ② 的 findsOneWidget 变 findsNWidgets(2)（或 getRect 抛 Too many elements）
// ⇒ 本文件红。
// ```

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/disk_cache.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/live_page.dart';
import 'package:sourin_spike/ui/widgets/live_embedded_player.dart';

Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    theme: theme,
    builder: (_, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: Scaffold(body: child),
  );
}

const _pA = 'iptv';
const _pB = 'other';
/// 两个源里**同一个**频道 id —— 这就是撞 key 的触发条件
const _sameId = 'cctv1';

/// Actual selected semantics and the Miuix surface painted inside every row.
/// Neutral cards also have colors, so color presence alone is not selection.
Set<String> _paintedHighlightedRows(WidgetTester tester) {
  const prefix = 'live-channel-highlight-';
  final selected = <String>{};
  var rows = 0;
  for (final element in find.byType(miuix.MiuixCard).evaluate()) {
    final key = element.widget.key;
    if (key is! ValueKey<String> || !key.value.startsWith(prefix)) continue;
    rows++;
    bool? active;
    element.visitAncestorElements((ancestor) {
      final widget = ancestor.widget;
      if (widget is Semantics && widget.properties.selected != null) {
        active = widget.properties.selected;
        return false;
      }
      return true;
    });
    expect(active, isNotNull, reason: 'Each painted live row exposes selection');
    final palette = miuix.MiuixTheme.of(element).colors;
    final expected = active!
        ? palette.primary.withValues(alpha: .12)
        : palette.surfaceContainer;
    final surface = find.descendant(
      of: find.byKey(key),
      matching: find.byWidgetPredicate((widget) =>
          widget is DecoratedBox &&
          widget.decoration is ShapeDecoration &&
          (widget.decoration as ShapeDecoration).color == expected),
    );
    expect(surface, findsOneWidget,
        reason: 'The selected and neutral rows paint their actual Miuix colors');
    if (active!) selected.add(key.value.substring(prefix.length));
  }
  expect(rows, greaterThan(0), reason: 'Do not accept a missing-row empty result');
  return selected;
}

Widget _twoSourcesSayingTheSameId({
  ValueChanged<LiveChannel>? onPick,
}) {
  const a = LiveChannel(id: _sameId, name: '一套（IPTV 源）');
  const b = LiveChannel(id: _sameId, name: '一套（另一源）');
  return _host(SizedBox(
    width: 420,
    height: 400,
    child: LiveChannelList(
      providers: const [
        LiveGroup(provider: _pA, providerName: 'IPTV 直播', channels: [a]),
        LiveGroup(provider: _pB, providerName: '某平台', channels: [b]),
      ],
      enabledProviders: const {_pA, _pB},
      channels: const [
        (channel: a, tag: 'IPTV 直播', provider: _pA),
        (channel: b, tag: '某平台', provider: _pB),
      ],
      selectedId: _sameId,
      onPickChannel: onPick ?? (_) {},
    ),
  ));
}

void main() {
  testWidgets('① 两行 key 互不相同，且拼法与生产同一个函数', (t) async {
    await t.pumpWidget(_twoSourcesSayingTheSameId());
    await t.pump();

    // 前提：两行**真的**都渲染出来了（否则下面的断言恒真）
    expect(find.text('一套（IPTV 源）'), findsOneWidget);
    expect(find.text('一套（另一源）'), findsOneWidget);

    final keyA = liveChannelTileKey(_pA, _sameId);
    final keyB = liveChannelTileKey(_pB, _sameId);
    expect(keyA, isNot(keyB),
        reason: '★★★ 同 id 跨源两行拿到了同一个 key ⇒ 兄弟 key 重复（R1）');
    expect(liveChannelRowKey(_pA, _sameId), '$_pA:$_sameId',
        reason: '★ key 必须是 provider:id 的组合拼法（单点定义）');
    expect(liveChannelRowKey(_pA, _sameId),
        isNot(liveChannelRowKey(_pB, _sameId)));

    // key 里必须带 provider（不是只有 id）
    expect((keyA as ValueKey<String>).value, contains(_pA));
    expect((keyB as ValueKey<String>).value, contains(_pB));
  });

  testWidgets('② find.byKey 各命中恰好 1 个（不歧义）', (t) async {
    await t.pumpWidget(_twoSourcesSayingTheSameId());
    await t.pump();

    expect(find.byKey(liveChannelTileKey(_pA, _sameId)), findsOneWidget,
        reason: '★★★ 一个 key 命中多行 ⇒ sliver 的 key→element 匹配歧义'
            '（焦点/高亮会串槽）');
    expect(find.byKey(liveChannelTileKey(_pB, _sameId)), findsOneWidget);
    expect(find.byKey(liveChannelHighlightKey(_pA, _sameId)), findsOneWidget);
    expect(find.byKey(liveChannelHighlightKey(_pB, _sameId)), findsOneWidget);

    // 两行是**不同**的几何位置（不是同一行被数了两遍）
    final ra = t.getRect(find.byKey(liveChannelTileKey(_pA, _sameId)));
    final rb = t.getRect(find.byKey(liveChannelTileKey(_pB, _sameId)));
    expect(ra, isNot(rb), reason: '★ 两行矩形相同 ⇒ 只渲染了一行');
    expect(ra.overlaps(rb), isFalse,
        reason: '★ 两行矩形相交 ⇒ 点击热区重叠，点哪一台不可预测');

    expect(t.takeException(), isNull, reason: '★ 渲染不许抛异常（重复 key）');
  });

  testWidgets('③ 点击互不串台（各自回调自己的频道对象）', (t) async {
    final picked = <String>[];
    await t.pumpWidget(_twoSourcesSayingTheSameId(
      onPick: (c) => picked.add(c.name),
    ));
    await t.pump();

    await t.tap(find.byKey(liveChannelTileKey(_pA, _sameId)),
        kind: PointerDeviceKind.mouse);
    await t.pump();
    expect(picked, ['一套（IPTV 源）'],
        reason: '★★★ 点 IPTV 源那一行却回调了另一个源的频道 ⇒ 串台（R1 的直接后果）');

    await t.tap(find.byKey(liveChannelTileKey(_pB, _sameId)),
        kind: PointerDeviceKind.mouse);
    await t.pump();
    expect(picked, ['一套（IPTV 源）', '一套（另一源）']);

    // （老 API `selectedId` 只带 id ⇒ 两行都会高亮；这是**旧行为**，
    //   下面的 ④ 用新 API `selectedRow` 证明它已被修掉。）
    expect(find.byKey(liveChannelHighlightKey(_pA, _sameId)), findsOneWidget);
    expect(find.byKey(liveChannelHighlightKey(_pB, _sameId)), findsOneWidget);
  });

  // ══════════════════════════════════════════════════════════════════
  //  ④ 选中身份（provider:id）—— 第 15 项的最后一个缺口
  // ══════════════════════════════════════════════════════════════════
  //
  // # 缺口原文
  // ```text
  // 行 key 已带 provider，但**选中仍然只记 id**：
  //   `LiveChannelList.selectedId` 只带 id ⇒ 两个源同 id 时**两行同时高亮**
  //   `_providerOf` 按 id 扫 `_groups` 取第一个命中 ⇒ 换台可能取错源
  // ```
  testWidgets('④ 选中身份：点哪一行**只有那一行**高亮（同 id 跨源不再一起亮）',
      (t) async {
    // 用 `selectedRow` + `onPickEntry`：宿主自己维护"选中身份"
    var selectedRow = liveChannelRowKey(_pA, _sameId);
    const a = LiveChannel(id: _sameId, name: '一套（IPTV 源）');
    const b = LiveChannel(id: _sameId, name: '一套（另一源）');

    Widget build() => _host(SizedBox(
          width: 420,
          height: 400,
          child: StatefulBuilder(
            builder: (ctx, setSt) => LiveChannelList(
              providers: const [
                LiveGroup(provider: _pA, providerName: 'IPTV 直播', channels: [a]),
                LiveGroup(provider: _pB, providerName: '某平台', channels: [b]),
              ],
              enabledProviders: const {_pA, _pB},
              channels: const [
                (channel: a, tag: 'IPTV 直播', provider: _pA),
                (channel: b, tag: '某平台', provider: _pB),
              ],
              selectedId: _sameId, // 老字段仍在（兼容），但应被 selectedRow 覆盖
              selectedRow: selectedRow,
              onPickChannel: (_) => fail('不该走不带源的回调'),
              onPickEntry: (e) => setSt(
                () => selectedRow = liveChannelRowKey(e.provider, e.channel.id),
              ),
            ),
          ),
        ));

    await t.pumpWidget(build());
    await t.pump();

    Set<String> highlightedRows() => _paintedHighlightedRows(t);

    // 初始：只有 A 行高亮（旧 API 会让两行都亮 —— 这条是修复的直接判据）
    expect(highlightedRows(), {'$_pA:$_sameId'},
        reason: '★★★ 两个源同 id 时两行一起高亮 ⇒ 选中身份仍然只带 id（第 15 项缺口）');

    // 点 B 行 ⇒ 只有 B 行高亮
    await t.tap(find.byKey(liveChannelTileKey(_pB, _sameId)),
        kind: PointerDeviceKind.mouse);
    await t.pump();

    expect(selectedRow, '$_pB:$_sameId',
        reason: '★ 点 B 行必须把选中身份切到 B（回调必须带 provider）');
    expect(highlightedRows(), {'$_pB:$_sameId'},
        reason: '★★★ 点了 B 行却两行都亮（或亮的还是 A）⇒ 选中身份没修好');
  });

  // ── ⑤ _providerOf 不再取"第一个命中"（用真实的播放页交接验证） ──────
  testWidgets('⑤ 选中模型的 provider 必须正确（交接给全屏时传对源）', (t) async {
    const a1 = LiveChannel(id: _sameId, name: 'A 一套');
    const b1 = LiveChannel(id: _sameId, name: 'B 一套');
    LivePageState.debugLiveGroupsFetcher = () async => const [
          LiveGroup(provider: _pA, providerName: 'IPTV 直播', channels: [a1]),
          LiveGroup(provider: _pB, providerName: '某平台', channels: [b1]),
        ];
    addTearDown(() => LivePageState.debugLiveGroupsFetcher = null);

    String? seenProvider;
    String? seenId;
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1000, 680);
    addTearDown(() {
      t.view.resetPhysicalSize();
      t.view.resetDevicePixelRatio();
    });

    await t.pumpWidget(_host(LivePage(
      onWatchLivePlayback: (provider, id, name, snap) async {
        seenProvider = provider;
        seenId = id;
        return snap;
      },
    )));
    await t.pump();
    await t.pump();

    final page = t.state<LivePageState>(find.byType(LivePage));
    // 明确选"另一个源"的那个同 id 频道
    await page.selectChannelForProbe(b1, provider: _pB);
    await t.pump();
    await t.pump();

    await page.watchLiveForProbe(LiveRoundtripReceipt());
    await t.pump();

    expect(seenId, _sameId);
    expect(seenProvider, _pB,
        reason: '★★★ 交接传的是 $seenProvider —— 说明 `_providerOf` 还是"按 id 取第一个命中"，'
            '用户选的另一源同 id 台会被当成第一个源（取错流）');

    await t.pumpWidget(const SizedBox.shrink());
  });

  // ── ⑥ 键盘 ↓ 不许跨源跳（同 id 时按身份定位） ────────────────────────
  testWidgets('⑥ 键盘 ↓/↑ 在**同一源内**走（不许因为 id 相同而跳源）', (t) async {
    final previousTransport = SourinCore.debugCallAsyncTransport;
    final previousStreamFetcher = SourinApi.debugLiveStreamFetcher;
    final previousGroupsFetcher = LivePageState.debugLiveGroupsFetcher;
    final previousDirectory = DiskCache.dataDir;
    final previousSkipPlayer = debugSkipPlayerCreation;
    final unexpected = <String>[];
    final requested = <String>[];
    DiskCache.debugResetForTest();
    UiPrefs.debugResetForTest(<String, String>{});
    SourinApi.debugClearLiveStreamCache();
    SourinApi.debugLiveStreamFetcher = null;
    debugSkipPlayerCreation = true;
    SourinCore.debugCallAsyncTransport = (command, args) async {
      if (command == 'get_live_stream') {
        requested.add('${args!['provider']}:${args['channel_id']}');
        return <dynamic>[];
      }
      unexpected.add(command);
      throw StateError('Unexpected duplicate-channel fixture command: $command');
    };
    addTearDown(() {
      SourinCore.debugCallAsyncTransport = previousTransport;
      SourinApi.debugLiveStreamFetcher = previousStreamFetcher;
      LivePageState.debugLiveGroupsFetcher = previousGroupsFetcher;
      SourinApi.debugClearLiveStreamCache();
      DiskCache.debugResetForTest(previousDirectory);
      UiPrefs.debugResetForTest(<String, String>{});
      debugSkipPlayerCreation = previousSkipPlayer;
      expect(unexpected, isEmpty);
    });
    const a1 = LiveChannel(id: _sameId, name: 'A 一套');
    const a2 = LiveChannel(id: 'cctv2', name: 'A 二套');
    const b1 = LiveChannel(id: _sameId, name: 'B 一套');
    const b2 = LiveChannel(id: 'cctv2', name: 'B 二套');
    LivePageState.debugLiveGroupsFetcher = () async => const [
          LiveGroup(provider: _pA, providerName: 'IPTV 直播', channels: [a1, a2]),
          LiveGroup(provider: _pB, providerName: '某平台', channels: [b1, b2]),
        ];
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1000, 680);
    addTearDown(() {
      t.view.resetPhysicalSize();
      t.view.resetDevicePixelRatio();
    });

    await t.pumpWidget(_host(const LivePage()));
    addTearDown(() async {
      await t.pumpWidget(const SizedBox.shrink());
      await t.pump();
    });
    await t.pump();
    await t.pump();

    final page = t.state<LivePageState>(find.byType(LivePage));
    await page.selectChannelForProbe(a1, provider: _pA);
    await t.pump();
    await t.pump();

    Set<String> highlightedRows() => _paintedHighlightedRows(t);

    expect(highlightedRows(), {'$_pA:$_sameId'},
        reason: '前提：选中的是 A 源那一台');

    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.pump();

    /*
     * 列表顺序是 A 源两行 → B 源两行。
     * 按 id 定位（旧实现）会在 `indexWhere((c) => c.id == cur.id)` 上
     * 永远命中**第一个** `cctv1` ⇒ 按 ↓ 变成"从 A 一套跳到 A 一套"（看起来没反应）
     * 或跳源。按身份定位必须落到 `iptv:cctv2`。
     */
    expect(highlightedRows(), {'$_pA:cctv2'},
        reason: '★★★ 按 ↓ 没走到同一源的下一台 ⇒ 切台仍按 id 定位（第 15 项缺口）');
    expect(requested.last, '$_pA:cctv2',
        reason: 'The real key path must request the same provider/native channel');

    await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await t.pump();
    expect(highlightedRows(), {'$_pA:$_sameId'});
    expect(requested.last, '$_pA:$_sameId');

    await t.pumpWidget(const SizedBox.shrink());
  });
}
