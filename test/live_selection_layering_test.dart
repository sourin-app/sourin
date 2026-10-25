// ═══════════════════════════════════════════════════════════════════════
//  第 15 项验收：直播选中效果**错层遮挡**
// ═══════════════════════════════════════════════════════════════════════
//
// # 计划原文（判据）
// ```text
// 15 直播选中效果错层遮挡：区分频道高亮、焦点环、筛选浮层；
//    选中只作用于目标项，不遮文字/按钮/相邻元素，不留透明拦截层。
//    鼠标选择、键盘切换、展开筛选、滚动后都要成立。
// ```
//
// # 这三层必须**不是同一件东西**（本文件的第一组判据）
// ```text
// ① 频道高亮 = `_ChannelTile` 里那个 `Container.decoration`
//    ⇒ 画在**本行自己的盒子内部**（文字是它的 child，后画 ⇒ 结构上压不到字）
// ② 焦点环   = `InkWell` 的 focusNode（键盘/遥控用）
//    ⇒ 与高亮**可分别观测**：高亮看 decoration，焦点看 hasFocus
// ③ 筛选浮层 = `MenuAnchor` 的 overlay（`live-bar-*` 下拉）
//    ⇒ 在 Overlay 层，**不是**列表里的透明层
// ```
//
// # 反例（判据要能测出的坏形态 —— 实测跑红记录见交付说明）
// ```text
// · 高亮改成 `Stack` + `Positioned.fill` 盖在内容上 ⇒ ③ 的"高亮容器内无 Stack"红
//   （那种形态色块画在文字**之后**，会把字糊掉）
// · 高亮挂在**整张列表**上 ⇒ ①「其余行没有高亮装饰」红
// · 高亮块比行大 / 行与行热区重叠 ⇒ ② 红
// · 展开筛选后留一个 `ModalBarrier` 不收 ⇒ ⑥ 红
// · 换选时不清旧行 ⇒ ⑤ 的「旧行仍在高亮」红
// ```
//
// # ⚠️ 为什么测 `LiveChannelList` 而不是 `LivePage`
// ```text
// 与 `t1013_live_filter_test.dart` / `t48_live_page_all_channels_test.dart`
// 记的是**同一道墙**：`LivePageState._groups` 只由 FFI 填，
// 隔离环境没有核心 DLL ⇒ 恒为空 ⇒ 整页层面喂不进频道。
// `LiveChannelList` 是**公开**组件、频道由构造参数传入
// ⇒ 能**真的渲染**出多行并断言几何/命中（不是读源码字符串）。
// ```

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/live_page.dart';

/// 真实壳（forui 主题 + material_ui 的 MaterialApp）—— 与 `t1013_live_filter_test` 同款
Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    theme: theme,
    builder: (_, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: Scaffold(body: child),
  );
}

LiveChannel _ch(String id, String name, {String? group}) =>
    LiveChannel(id: id, name: name, group: group);

LiveFlatEntry _entry(String provider, String tag, LiveChannel ch) =>
    (channel: ch, tag: tag, provider: provider);

/// 与 `LiveChannelList` 的 `c1`/`c2` 同一个源（key 的一半）
const _pA = 'iptv';
const _pB = 'other';

/// 测试里按行 id 反查源（c1/c2 来自 iptv，c3 来自 other）
String _providerOfRow(String id) => id == 'c3' ? _pB : _pA;

/// 三行频道 + 两个可筛的源 + 一个可筛的分类
class _Fixture {
  static const providerA = 'iptv';
  static const providerB = 'other';

  static final channels = <LiveFlatEntry>[
    _entry(providerA, 'IPTV 直播', _ch('c1', '频道一', group: '央视')),
    _entry(providerA, 'IPTV 直播', _ch('c2', '频道二', group: '央视')),
    _entry(providerB, '某平台', _ch('c3', '频道三', group: '卫视')),
  ];

  static final providers = <LiveGroup>[
    LiveGroup(
      provider: providerA,
      providerName: 'IPTV 直播',
      channels: [channels[0].channel, channels[1].channel],
    ),
    LiveGroup(
      provider: providerB,
      providerName: '某平台',
      channels: [channels[2].channel],
    ),
  ];
}

Widget _list({
  String? selectedId,
  ValueChanged<LiveChannel>? onPick,
  ValueChanged<String?>? onPickProvider,
}) =>
    _host(SizedBox(
      width: 420,
      height: 520,
      child: LiveChannelList(
        providers: _Fixture.providers,
        enabledProviders: const {_Fixture.providerA, _Fixture.providerB},
        channels: _Fixture.channels,
        selectedId: selectedId,
        onPickChannel: onPick ?? (_) {},
        onPickProvider: onPickProvider,
      ),
    ));

/// 某一行的**高亮装饰**（`Container.decoration`）
///
/// ★ R1 之后 key 带 provider（`provider:id`）⇒ 测试也必须用**生产的同一个**
///   builder（`liveChannelHighlightKey`），不许在这里再拼一遍字符串：
///   两处各拼一次的话，改一处忘一处门禁照样绿（假绿）。
BoxDecoration? _highlight(WidgetTester t, String id, {String provider = _pA}) {
  final f = find.byKey(liveChannelHighlightKey(provider, id));
  if (f.evaluate().isEmpty) return null;
  final box = t.widget<Container>(f);
  return box.decoration as BoxDecoration?;
}

/// 某一行的**点击热区**（`InkWell`）
InkWell _tileInk(WidgetTester t, String id, {String provider = _pA}) =>
    t.widget<InkWell>(find.byKey(liveChannelTileKey(provider, id)));

/// 当前**挂了高亮的行 id 集合**（扫 key，不依赖任何内部字段）
Set<String> _highlightedRows() {
  const prefix = 'live-channel-highlight-';
  final out = <String>{};
  for (final e in find.byType(Container).evaluate()) {
    final w = e.widget;
    if (w is! Container) continue;
    final d = w.decoration;
    if (d is! BoxDecoration || d.color == null) continue;
    final k = w.key;
    if (k is! ValueKey<String>) continue;
    if (!k.value.startsWith(prefix)) continue;
    final row = k.value.substring(prefix.length);
    // ★ R1 之后 key = `<prefix><provider>:<id>` ⇒ 取 id 那一半
    out.add(row.contains(':') ? row.split(':').last : row);
  }
  return out;
}

void main() {
  // ────────────────────────────────────────────────────────────────
  // ① 结构：高亮是**本行自己的背景**，不是盖在列表上的层
  // ────────────────────────────────────────────────────────────────
  testWidgets('① 选中只作用于目标项 —— 其余行没有高亮装饰', (t) async {
    await t.pumpWidget(_list(selectedId: 'c2'));
    await t.pump();

    expect(_highlight(t, 'c2'), isNotNull,
        reason: '选中行必须**有**高亮装饰（否则"选中效果"根本不存在）');
    expect(_highlight(t, 'c2')!.color, isNotNull,
        reason: '选中行的高亮必须真的着色（decoration 存在但 color=null = 假高亮）');

    for (final id in ['c1', 'c3']) {
      expect(_highlight(t, id)?.color, isNull,
          reason: '★ 未选中的 $id 也着了色 ⇒ 选中效果越界到了相邻项 '
              '（计划第 15 条的"选中只作用于目标项"）');
    }
  });

  // ────────────────────────────────────────────────────────────────
  // ② 高亮不越出本行：几何包含 + 相邻不相交
  // ────────────────────────────────────────────────────────────────
  testWidgets('② 高亮矩形不越出目标行、不与相邻行相交', (t) async {
    await t.pumpWidget(_list(selectedId: 'c2'));
    await t.pump();

    final hl = t.getRect(find.byKey(liveChannelHighlightKey(_pA, 'c2')));
    final row = t.getRect(find.byKey(liveChannelTileKey(_pA, 'c2')));
    final prev = t.getRect(find.byKey(liveChannelHighlightKey(_pA, 'c1')));
    final next = t.getRect(find.byKey(liveChannelHighlightKey(_pB, 'c3')));

    /*
     * 高亮盒 = 行的盒子减掉 2px 下边距：它必须**严格**落在本行矩形里
     * （可以更小，绝不能更大）。越界 1px 就能盖到相邻行。
     */
    expect(_contains(row, hl), isTrue,
        reason: '高亮 $hl 越出本行 $row ⇒ 会盖到相邻行/容器边框');

    expect(hl.overlaps(prev), isFalse,
        reason: '高亮与上一行 $prev 相交 ⇒ 错层遮挡');
    expect(hl.overlaps(next), isFalse,
        reason: '高亮与下一行 $next 相交 ⇒ 错层遮挡');

    // 行与行之间的**点击热区**也不许重叠（否则点哪一台不可预测）
    expect(row.overlaps(prev), isFalse,
        reason: '本行与上一行的点击热区重叠 ⇒ 点哪一行不可预测');
    expect(row.overlaps(next), isFalse,
        reason: '本行与下一行的点击热区重叠 ⇒ 点哪一行不可预测');
  });

  // ────────────────────────────────────────────────────────────────
  // ③ 高亮不遮文字：文字在本行内，且高亮是背景不是覆盖层
  // ────────────────────────────────────────────────────────────────
  testWidgets('③ 频道名文字完整落在本行内、高亮不是盖在内容上的层', (t) async {
    await t.pumpWidget(_list(selectedId: 'c2'));
    await t.pump();

    final row = t.getRect(find.byKey(liveChannelTileKey(_pA, 'c2')));
    final text = t.getRect(find.text('频道二'));

    expect(text.width, greaterThan(0));
    expect(text.height, greaterThan(0));
    expect(_contains(row, text), isTrue,
        reason: '★ 文字 $text 跑出本行 $row ⇒ 被裁 / 被遮挡');

    /*
     * 再钉"高亮的绘制层在文字之下"：文字必须是高亮 `Container` 的**后代**
     * （同一棵子树、先装饰后内容），且这个容器里不许有 `Stack` 之类的叠层。
     * ★ 若有人把高亮改成 `Stack(children:[内容, Positioned.fill(色块)])`，
     *   下面第二条会红 —— 那种色块画在内容**之后**，会糊住文字。
     */
    final hlFinder = find.byKey(liveChannelHighlightKey(_pA, 'c2'));
    expect(
      find.descendant(of: hlFinder, matching: find.text('频道二')),
      findsOneWidget,
      reason: '文字不在高亮容器内部 ⇒ 高亮是另起一层盖在内容上（会遮字）',
    );
    expect(
      find.descendant(of: hlFinder, matching: find.byType(Stack)),
      findsNothing,
      reason: '★ 高亮容器里出现了 Stack ⇒ "高亮"变成了叠在内容上的层；'
          '正确形态是 Container.decoration（背景先画、内容后画）',
    );
  });

  // ────────────────────────────────────────────────────────────────
  // ④ 不留透明拦截层：鼠标点击真的落到目标行
  // ────────────────────────────────────────────────────────────────
  testWidgets('④ 选中行与相邻行都可命中（没有透明层吃掉点击）', (t) async {
    final picked = <String>[];
    await t.pumpWidget(_list(selectedId: 'c2', onPick: (c) => picked.add(c.id)));
    await t.pump();

    for (final id in ['c1', 'c2', 'c3']) {
      /*
       * `hitTestable()` 会真的把这个点喂进 hitTest：
       * 任何 `IgnorePointer`/`AbsorbPointer`/`Opacity(0)` 覆盖层都会让它红。
       */
      expect(find.byKey(liveChannelTileKey(_providerOfRow(id), id)).hitTestable(),
          findsOneWidget,
          reason: '★ $id 在中心点**不可命中** ⇒ 有透明层挡在上面');
    }

    // 鼠标点击（PC 端的主要输入来源）
    await t.tap(find.byKey(liveChannelTileKey(_pA, 'c2')),
        kind: PointerDeviceKind.mouse);
    await t.pump();
    expect(picked, ['c2'], reason: '点选中行必须回调本行频道，不得串到相邻行');

    await t.tap(find.byKey(liveChannelTileKey(_pB, 'c3')),
        kind: PointerDeviceKind.mouse);
    await t.pump();
    expect(picked, ['c2', 'c3'], reason: '点相邻行必须回调它自己');
  });

  // ────────────────────────────────────────────────────────────────
  // ⑤ 三层可区分：焦点环跟着选中走（键盘切换）
  // ────────────────────────────────────────────────────────────────
  testWidgets('⑤ 键盘切换：焦点环跟着新选中行，旧行失焦且不再高亮', (t) async {
    await t.pumpWidget(_list(selectedId: 'c2'));
    await t.pumpAndSettle();

    /*
     * 首次挂载（active 没发生 false→true 跳变 ⇒ `didUpdateWidget` 不跑，
     * 不会 requestFocus）。这里钉的是"不许有**第二个**选中"：
     * 高亮只许在 c2，且**任何其它行都不许持有焦点**。
     */
    expect(_highlight(t, 'c2')!.color, isNotNull);
    for (final id in ['c1', 'c3']) {
      expect(_tileInk(t, id, provider: _providerOfRow(id)).focusNode!.hasFocus,
          isFalse,
          reason: '★ 未选中行 $id 在首次挂载时持有焦点 ⇒ 焦点环与高亮分家'
              '（用户看到两处"选中"）');
      expect(_highlight(t, id, provider: _providerOfRow(id))?.color, isNull);
    }

    // 换选：c2 → c3（= 用户按键切到下一个台的结果）
    await t.pumpWidget(_list(selectedId: 'c3'));
    await t.pumpAndSettle();

    expect(_tileInk(t, 'c3', provider: _pB).focusNode!.hasFocus, isTrue,
        reason: '★ 切换后焦点必须落到新的选中行 —— 否则高亮在 A、能回车的是 B'
            '（正是计划第 15 条要区分的错层）');
    expect(_highlight(t, 'c3', provider: _pB)!.color, isNotNull);
    expect(_highlight(t, 'c2')?.color, isNull,
        reason: '★ 旧行仍在高亮 ⇒ 一次选中留下两个高亮（错层）');
    expect(_tileInk(t, 'c2').focusNode!.hasFocus, isFalse,
        reason: '★ 旧行仍持有焦点 ⇒ 焦点环与高亮分离');
  });

  // ────────────────────────────────────────────────────────────────
  // ⑥ 筛选浮层：收起后零残留拦截层，列表恢复可点
  // ────────────────────────────────────────────────────────────────
  testWidgets('⑥ 筛选浮层展开/收起：收起后无残留拦截层、列表恢复可点', (t) async {
    final picked = <String>[];
    final providerPicks = <String?>[];
    await t.pumpWidget(_list(
      selectedId: 'c2',
      onPick: (c) => picked.add(c.id),
      onPickProvider: (p) => providerPicks.add(p),
    ));
    await t.pumpAndSettle();

    /*
     * ★ 用**相对**读数而不是"必须 0"：
     *   浮层展开期间框架可能给它挂自己的遮罩（那是菜单的常规交互），
     *   计划第 15 条禁止的是**残留**的透明拦截层（收起后还挡着）。
     *   ⇒ 基线 B0 → 展开 → 收起后必须回到 B0。
     */
    int blockers() => find.byType(ModalBarrier).evaluate().length;
    final b0 = blockers();
    debugPrint('[15] 展开前 ModalBarrier = $b0');

    final sourceBtn = find.descendant(
      of: find.byKey(const ValueKey('live-bar-source')),
      matching: find.byType(InkWell),
    );
    expect(sourceBtn, findsOneWidget);

    await t.tap(sourceBtn.first, kind: PointerDeviceKind.mouse);
    await t.pumpAndSettle();

    expect(find.byKey(const ValueKey('live-bar-opt-other')), findsOneWidget,
        reason: '下拉必须真的展开（否则本用例什么都没验到）');
    debugPrint('[15] 展开后 ModalBarrier = ${blockers()}');

    // 点选项：筛选生效 + 浮层收起
    await t.tap(find.byKey(const ValueKey('live-bar-opt-other')),
        kind: PointerDeviceKind.mouse);
    await t.pumpAndSettle();
    expect(providerPicks, ['other'], reason: '选源必须真的走 onPickSource');
    expect(find.byKey(const ValueKey('live-bar-opt-other')), findsNothing,
        reason: '★ 选完必须收起（收不起 ⇒ 残留浮层继续压着列表）');

    // ★ 核心判据：收起后拦截层数量回到基线
    expect(blockers(), b0,
        reason: '★ 浮层收起后仍有 ${blockers()} 个 ModalBarrier（基线 $b0）'
            '⇒ 留下透明拦截层：视觉上看不出、点起来点不到');

    // 列表只剩该源频道，且能命中、点击真的到位
    expect(find.text('频道三'), findsOneWidget);
    expect(find.text('频道一'), findsNothing);
    expect(find.byKey(liveChannelTileKey(_pB, 'c3')).hitTestable(),
        findsOneWidget,
        reason: '★ 收起浮层后 c3 仍不可命中 ⇒ 有残留层挡着');
    await t.tap(find.byKey(liveChannelTileKey(_pB, 'c3')),
        kind: PointerDeviceKind.mouse);
    await t.pump();
    expect(picked, ['c3'], reason: '收起浮层后点击必须恢复正常');

    // 被筛掉的行不许留一个"选中但看不见"的高亮块
    expect(_highlight(t, 'c1'), isNull);
    expect(_highlight(t, 'c2'), isNull,
        reason: '★ 被筛掉的选中行仍留着高亮盒 ⇒ 高亮挂在不存在的行上（错层）');
  });

  // ────────────────────────────────────────────────────────────────
  // ⑦ 滚动后仍成立：高亮不漂到别的行，滚回可视区后可点
  // ────────────────────────────────────────────────────────────────
  testWidgets('⑦ 长列表滚动后：高亮仍只在目标行、滚回可视区后可点', (t) async {
    final many = <LiveFlatEntry>[
      for (var i = 0; i < 40; i++)
        _entry(_Fixture.providerA, 'IPTV 直播', _ch('n$i', '频道$i')),
    ];
    final picked = <String>[];

    Widget build(String selected) => _host(SizedBox(
          width: 420,
          height: 320,
          child: LiveChannelList(
            providers: [
              LiveGroup(
                provider: _Fixture.providerA,
                providerName: 'IPTV 直播',
                channels: [for (final e in many) e.channel],
              ),
            ],
            enabledProviders: const {_Fixture.providerA},
            channels: many,
            selectedId: selected,
            onPickChannel: (c) => picked.add(c.id),
          ),
        ));

    await t.pumpWidget(build('n0'));
    await t.pumpAndSettle();
    expect(find.byType(ListView), findsOneWidget);
    expect(_highlightedRows(), {'n0'});

    // 鼠标滚轮往下滚（计划要求的"滚动后"）
    await t.drag(find.byType(Scrollable).first, const Offset(0, -600),
        kind: PointerDeviceKind.mouse);
    await t.pumpAndSettle();

    /*
     * ★ 滚动后**必须仍然只有一个**高亮行，而且只能是 n0。
     *   坏形态：高亮是浮在列表上的层 ⇒ 滚上去以后它贴在视口某一行的位置，
     *   看起来"选中跑到了别的台"。
     */
    expect(_highlightedRows(), {'n0'},
        reason: '★ 滚动后高亮行 = ${_highlightedRows()}，期望 {n0} ⇒ 高亮漂移（错层）');

    // 若 n0 还挂载着，它必须仍在本行盒子里（不许越出行）
    final n0 = find.byKey(liveChannelHighlightKey(_pA, 'n0'));
    if (n0.evaluate().isNotEmpty) {
      final row = t.getRect(find.byKey(liveChannelTileKey(_pA, 'n0')));
      expect(_contains(row, t.getRect(n0)), isTrue,
          reason: '★ 滚动后高亮越出本行 ⇒ 高亮块是浮层而非行内背景');
    }

    // 滚回顶部：目标行重新可见且可点
    await t.drag(find.byType(Scrollable).first, const Offset(0, 900),
        kind: PointerDeviceKind.mouse);
    await t.pumpAndSettle();

    expect(n0, findsOneWidget, reason: '滚回顶部后 n0 必须重新挂载');
    final listRect = t.getRect(find.byType(ListView));
    final n0Rect = t.getRect(n0);
    expect(n0Rect.top, greaterThanOrEqualTo(listRect.top - 1),
        reason: '★ 滚回顶部后选中行 $n0Rect 不在列表可视区 $listRect 内');
    expect(n0Rect.bottom, lessThanOrEqualTo(listRect.bottom + 1),
        reason: '★ 滚回顶部后选中行 $n0Rect 不在列表可视区 $listRect 内');
    expect(find.byKey(liveChannelTileKey(_pA, 'n0')).hitTestable(),
        findsOneWidget,
        reason: '★ 滚动后选中行不可命中 ⇒ 有东西压在上面');

    await t.tap(find.byKey(liveChannelTileKey(_pA, 'n0')),
        kind: PointerDeviceKind.mouse);
    await t.pump();
    expect(picked, ['n0'], reason: '滚动后点击必须仍落到目标行');

    // 换选到一个**已挂载**的远处行：高亮 + 焦点环都要落在它身上
    /*
     * ⚠️ 不能硬编码 n12 —— `ListView(children:)` 的 Element 是**惰性挂载**的，
     *   滚到哪个偏移才让 n12 进树取决于行高与 drag 距离。
     *   ⇒ 这里按当前**真的挂着**的行里挑一个，选它再断言"高亮/焦点都只落在它"。
     *   ★ 这比猜一个 id 更严格：无论滚到哪里，判据都必须成立。
     */
    final mountedIds = <String>[
      for (var i = 0; i < 40; i++)
        if (find
            .byKey(liveChannelHighlightKey(_pA, 'n$i'))
            .evaluate()
            .isNotEmpty)
          'n$i',
    ];
    expect(mountedIds.length, greaterThan(1),
        reason: '滚到中段后必须有多行挂载（否则这条用例什么都没验到）');
    // 挑一个**不是当前选中**的行（换选才有意义）
    final target = mountedIds.firstWhere((id) => id != 'n0');
    await t.pumpWidget(build(target));
    await t.pumpAndSettle();
    expect(_highlightedRows(), {target},
        reason: '★ 换选到 $target 后高亮 = ${_highlightedRows()} ⇒ '
            '旧行高亮没清掉 / 高亮没落到目标行');
    expect(_tileInk(t, target).focusNode!.hasFocus, isTrue,
        reason: '★ 换选后焦点没跟到 $target ⇒ 焦点环与高亮错位');
  });

  // ★ 已知边界（不在本文件里断言，写进交付说明）：
  //   选中**未挂载**的远处行时，那一行没有 State ⇒ 既没有高亮也没有焦点环
  //   （`_ChannelTile.didUpdateWidget` 的长注释已记录）。它与"错层遮挡"无关，
  //   但会让"键盘连按到很远的台"看不到选中效果 —— 本轮没有修，不宣称已覆盖。
}

/// `outer` 是否完整包含 `inner`（容差 0.5px，抗浮点抖动）
bool _contains(Rect outer, Rect inner) =>
    inner.left >= outer.left - 0.5 &&
    inner.top >= outer.top - 0.5 &&
    inner.right <= outer.right + 0.5 &&
    inner.bottom <= outer.bottom + 0.5;
