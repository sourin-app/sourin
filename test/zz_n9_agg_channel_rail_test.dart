// ═══════════════════════════════════════════════════════════════════════
//  N9 门禁：首页聚合源**二级横向渠道条 + 分批加载**（UI 层）
// ═══════════════════════════════════════════════════════════════════════
//
// # 权威依据
// `.probe/plan-2026-10-27-owner-9items.md` N9 小节（修法方向 2/3/4）+
// `.probe/n8b0-spec-audit.md` §5（形态裁定）。
//
// # Owner 原话
// ```text
// > 首页的 tvbox 聚合源，本身是一个多渠道的，支持有二级横向渠道，
// > 不然一次性加载太多非常卡顿
// ```
//
// # 本文件守的四件事（对应任务书第 1~3 条）
// ```text
// ① 结构：聚合区块真的画了一条**横向渠道条**，且**复用 SourinHorizontalRail**
//          （不许造第二套横向选择条 —— 判据是"包裹写法"，不是"数够几个"）
// ② 懒加载：请求数 == **已看过的渠道数**
//          首屏 1 次（只有第一个渠道被看过）；点第 2 个 ⇒ 2 次；
//          切回第 1 个 ⇒ **仍是 2 次**（不重发）
// ③ 换子树：切渠道 ⇒ 新请求发出 + **旧渠道内容被替换**（不是叠加）
//          且**只重建本区块** —— HomePageState.build 不跑
// ④ 分流：聚合区块按 `source.key` 走渠道条，**不是**被当成直播条吞掉
//          （漏了这条 ⇒ 整块静默消失，不报任何错）
// ```
//
// # 两条故障注入（证明判据有牙，日志落 `.probe/n9-ui-inject-*.log`）
// ```text
// A. 把懒加载改成"进区块就全量扇出全部渠道"
//    ⇒ ② 的**请求数断言**必须红（红的是那一条，不是别的）
// B. 把渠道条整段去掉（内容照画）
//    ⇒ ① / ④ 的**结构判据**必须红
// ```
//
// # ⚠️ 接口依赖（**如实标注，不许假装已联通**）
// ```text
// 本文件用的是 `debugSetAggChannelFetchers` 门禁注入点（生产恒 null）——
// 与 `debugHomeFetcher` / `debugListFetcher` **同一条纪律**。
// · Rust 侧 `channels()` / `channel_home()`：tvbox-rust 正在做（尚未落盘）
// · ffi.rs 接线（`tvbox_agg_channels` / `tvbox_agg_channel_home`）：归 Lead
// ⇒ **生产路径**是 `SourinCore.callAsync('tvbox_agg_channels')`，
//   接口没接上时会抛 ffi.rs 默认分支的 `unsupported`（"还没有接入"）,
//   界面**如实显示原因**而不是画一个假渠道条（那条另有断言）。
// ⇒ 本文件验的是**UI 层的懒加载契约**：在数据层就绪的前提下，
//   请求次数与"已看过的渠道数"是否恒等。数据层联通后**不需要改本文件**，
//   只需让 Lead 复跑一遍（见交付说明"复跑清单"）。
//
// Flutter SDK：flutter（3.47.5）
// 跑法：flutter test --concurrency=1 test/zz_n9_agg_channel_rail_test.dart
// ⚠️ 收尾必须 `debugSetAggChannelFetchers()` 置空恢复 —— 否则注入点会
//    泄漏给同一进程里后面跑的文件（本仓踩过同类：真机探针进程级注入）。

import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/ffi.dart' show SourinCore, SourinCoreException;
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/home_page.dart';
import 'package:sourin_spike/ui/widgets/poster_card.dart';
import 'package:sourin_spike/ui/widgets/sourin_scroll_behavior.dart';

import 'support/core_gate.dart';

// ═══════════════════════════════════════════════════════════════════════
//  夹具（全离线：不碰真网络、不碰真 FFI）
// ═══════════════════════════════════════════════════════════════════════

/// 造一个渠道
AggChannel _ch(String id) => AggChannel.fromJson({'id': id, 'name': '子站$id'})!;

/// 造一个"某渠道的某个区块"——形状逐字对齐契约
/// （`id = "sub1::电影"`、`title = "子站sub1 · 电影"`、
///  `source = Category{category_id:"sub1::电影"}`）
Section _sec(String channelId, String catId, String title) => Section(
      id: '$channelId::$catId',
      title: '子站$channelId · $title',
      source: SectionSource(type: 'category', categoryId: '$channelId::$catId'),
    );

/// 造一条卡片
MediaItem _item(String id) => MediaItem(
      id: 'tvbox_agg::$id',
      title: id,
      cover: 'https://example.invalid/$id.jpg',
    );

/// 一个**真会数请求**的假数据层
///
/// # 为什么它同时记"次数"和"渠道顺序"
/// ```text
/// 只记次数 ⇒ 分不清"拉了第 1 个渠道两次"与"拉了 1、2 两个渠道各一次"
///   —— 而后者才是懒加载对的形状。
/// ⇒ 记**渠道 id 序列**，次数 = 序列长度（判据与被测属性同源）。
/// ```
class _FakeAgg {
  _FakeAgg({required this.channels});

  final List<AggChannel> channels;

  /// 按渠道取数的**调用记录**（本文件的核心读数）
  final List<String> homeCalls = <String>[];

  /// 每个渠道的区块（写死 ⇒ 断言"切渠道换了内容"时无需猜）
  ///
  /// ⚠️ 两个渠道给**不同**的区块 id 与分类名 ⇒ 能证明"旧内容被替换"
  List<Section> sectionsOf(String id) => switch (id) {
        'sub1' => <Section>[_sec('sub1', '电影', '电影')],
        'sub2' => <Section>[_sec('sub2', '剧集', '剧集')],
        'sub3' => <Section>[_sec('sub3', '综艺', '综艺')],
        // 契约里渠道不存在/未启用 ⇒ Rust 侧返回可读错误
        _ => const <Section>[],
      };

  /// 每个区块给几条卡片（同一渠道的每个区块给 2 条，够断言"画出来了"）
  List<MediaItem> itemsOf(String sectionId) => <MediaItem>[
        _item('$sectionId-a'),
        _item('$sectionId-b'),
      ];

  /// 装上注入点
  void install({bool throwOnChannels = false}) {
    debugSetAggChannelFetchers(
      channels: () async {
        if (throwOnChannels) {
          throw SourinCoreException('这个功能（`tvbox_agg_channels`）在当前版本还没有接入', 'unsupported');
        }
        return AggChannelsPayload(ok: true, channels: channels);
      },
      channelHome: (channelId) async {
        homeCalls.add(channelId);
        final secs = sectionsOf(channelId);
        if (secs.isEmpty) {
          throw SourinCoreException('找不到渠道 $channelId（可能已被移除或未启用）', 'other');
        }
        return AggChannelHome(
          ok: true,
          channelId: channelId,
          channelName: '子站$channelId',
          sections: secs,
        );
      },
    );
  }
}

/// 挂 `AggChannelsBlock`（真挂载），并把 items 落进一张**测试自己的表**
///
/// ⚠️ 这里**不挂 HomePage**（它会 `listProviders()` → 真 FFI → 无核心必抛）。
///    而本文件的判据（请求数 / 切渠道换子树 / 结构）**都在区块自己这一层**
///    ⇒ 挂区块就是"判据的对象"，不存在"仪器与被测对象不同源"。
///    ★ HomePage 那一层的**分流**（key 而非 type）另有静态判据守（见下面 ④ 组）。
Future<void> _pumpBlock(
  WidgetTester tester,
  _FakeAgg fake, {
  int channelCount = 2,
}) async {
  final itemsTable = <String, List<MediaItem>>{};
  final loadedSectionIds = <String>[];

  await tester.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    MaterialApp(
      // ★ 必须有 Scaffold（= Material 祖先）：渠道条的药丸（2026-10-31 起
      //   与源条统一用 `SourcePill`，其 InkWell 与改前的 `ActionChip` 一样）
      //   要求上方有 Material —— 生产里这个祖先由
      //   `shell.dart` 的 Scaffold 提供。夹具缺了它 ⇒ 报的是**夹具**的错
      //   （"No Material widget found"），不是被测对象的错。
      home: Scaffold(
        body: SingleChildScrollView(
          child: AggChannelsBlock(
            provider: kTvboxAggregateId,
            onOpenDetail: (_) {},
            itemsOf: (provider, sectionId) =>
                itemsTable['$provider::$sectionId'] ?? const <MediaItem>[],
            loadItems: (Section s) async {
              loadedSectionIds.add(s.id);
              // ★ 走**同一个键格式**（`provider::sectionId`）—— 与首页同源
              itemsTable['${kTvboxAggregateId}::${s.id}'] = fake.itemsOf(s.id);
            },
          ),
        ),
      ),
    ),
  );
  // 两次 pump：一次让 initState 的 async 起步，一次让清单+首渠道落地
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
  await tester.pump(const Duration(milliseconds: 20));
}

/// 当前渲染出的**海报卡片标题**（用来证明"哪张渠道的内容在屏幕上"）
///
/// 卡片是 `PosterCard`（`_Rail` 里）—— 它的标题是唯一能区分渠道的文本。
List<String> _visibleCardTitles(WidgetTester tester) {
  final out = <String>[];
  for (final w in tester.widgetList<PosterCard>(find.byType(PosterCard))) {
    out.add(w.title);
  }
  return out;
}

void main() {
  // ★ 每个用例收尾都要把注入点置空（进程级，泄漏会影响别的文件）
  tearDown(() {
    debugSetAggChannelFetchers();
    debugClearAggChannelReadouts();
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 懒加载：**请求数 == 已看过的渠道数**（本任务的核心判据）
  // ═══════════════════════════════════════════════════════════════════
  group('★ N9 ② 懒加载：请求数 == 已看过的渠道数', () {
    testWidgets('进入聚合区块 ⇒ 只发 1 个渠道的请求（不是 N 个）', (tester) async {
      final fake = _FakeAgg(channels: [_ch('sub1'), _ch('sub2'), _ch('sub3')]);
      fake.install();

      await _pumpBlock(tester, fake, channelCount: 3);

      // ★ 三个渠道可用，但**只拉了第一个**
      expect(
        fake.homeCalls,
        <String>['sub1'],
        reason: '★★★ 首屏必须**只发 1 个渠道**的请求 —— '
            '拉了 3 个就是"一次性加载太多"（Owner 抱怨的那件事原样回归）。',
      );
      // 判据同源：探针读数与上面那个数组是**同一次调用**记下的
      expect(debugAggChannelHomeCalls, <String>['sub1']);
    });

    testWidgets('点第 2 个渠道 ⇒ 该渠道发出请求，第 1 个**不重发**', (tester) async {
      final fake = _FakeAgg(channels: [_ch('sub1'), _ch('sub2'), _ch('sub3')]);
      fake.install();
      await _pumpBlock(tester, fake, channelCount: 3);
      expect(fake.homeCalls, <String>['sub1']);

      // 点「子站sub2」
      await tester.tap(find.text('子站sub2'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 20));

      expect(
        fake.homeCalls,
        <String>['sub1', 'sub2'],
        reason: '★★ 切渠道要发**那一个**渠道的请求，且**不重发**已看过的 sub1',
      );
      expect(debugHomeAggRailSelections, contains('sub2'));
    });

    testWidgets('★ 切回已看过的渠道 ⇒ 一个请求都不发（缓存命中）', (tester) async {
      final fake = _FakeAgg(channels: [_ch('sub1'), _ch('sub2'), _ch('sub3')]);
      fake.install();
      await _pumpBlock(tester, fake, channelCount: 3);

      Future<void> tap(String name) async {
        await tester.tap(find.text(name));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 20));
      }

      await tap('子站sub2');
      await tap('子站sub3');
      expect(fake.homeCalls, <String>['sub1', 'sub2', 'sub3']);

      // ★ 切回 sub1 —— 已看过 ⇒ 必须 0 请求
      await tap('子站sub1');
      expect(
        fake.homeCalls,
        <String>['sub1', 'sub2', 'sub3'],
        reason: '★★★ 切回已看过的渠道**不许重发** —— 这就是"已看过的渠道缓存"。\n'
            '（同 task-11 的 stale-while-revalidate：命中就不发请求。）\n'
            '实际调用序列：${fake.homeCalls}',
      );
      // 不变式总结：请求数 == 已看过的渠道数
      expect(fake.homeCalls.length, 3);
      expect(fake.homeCalls.toSet().length, 3, reason: '每个渠道最多被拉一次');
    });

    testWidgets('★★ 请求数 == 已看过的渠道数（不变式，跨 3 个渠道）', (tester) async {
      final fake = _FakeAgg(channels: [_ch('sub1'), _ch('sub2'), _ch('sub3')]);
      fake.install();
      await _pumpBlock(tester, fake, channelCount: 3);

      Future<void> tap(String name) async {
        await tester.tap(find.text(name));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 20));
      }

      // 逐轮验"请求数 == 已看过的渠道数"
      var seen = <String>{'sub1'};
      expect(fake.homeCalls.length, seen.length);

      await tap('子站sub2');
      seen = {'sub1', 'sub2'};
      expect(fake.homeCalls.length, seen.length);

      await tap('子站sub3');
      seen = {'sub1', 'sub2', 'sub3'};
      expect(fake.homeCalls.length, seen.length);

      // 回头再点一遍（全都不该重发）
      await tap('子站sub1');
      await tap('子站sub2');
      expect(
        fake.homeCalls.length,
        seen.length,
        reason: '★★★ 不变式：请求数必须恒等于**已看过的渠道数**。\n'
            '大于它 = 有渠道被重复拉（缓存失效/扇出回归）；\n'
            '小于它 = 有渠道被看了却没拉（内容不可能画出来）。\n'
            '实际序列：${fake.homeCalls}',
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 换子树：切渠道 ⇒ 旧内容被**替换**（不是叠加）
  // ═══════════════════════════════════════════════════════════════════
  group('★ N9 ③ 切渠道换的是"当前渠道那一棵子树"', () {
    testWidgets('首屏画的是第 1 个渠道的内容（不是全部渠道拼一起）', (tester) async {
      final fake = _FakeAgg(channels: [_ch('sub1'), _ch('sub2'), _ch('sub3')]);
      fake.install();
      await _pumpBlock(tester, fake, channelCount: 3);

      final titles = _visibleCardTitles(tester);
      expect(titles, isNotEmpty, reason: '首个渠道的内容必须真的画出来');
      expect(
        titles.every((t) => !t.contains('季集')),
        isTrue,
        reason: '★ 首屏只该有 sub1 的卡片 —— 出现别的渠道的卡片就是"铺开"了',
      );
      expect(
        _visibleCardTitles(tester).where((t) => t.contains('sub2')).isEmpty,
        isTrue,
        reason: '★★ sub2 没被看过 ⇒ 它的卡片一张都不该在（懒加载）',
      );
    });

    testWidgets('切渠道 ⇒ 旧渠道内容消失、新渠道内容出现（替换而非叠加）', (tester) async {
      final fake = _FakeAgg(channels: [_ch('sub1'), _ch('sub2'), _ch('sub3')]);
      fake.install();
      await _pumpBlock(tester, fake, channelCount: 3);

      final before = _visibleCardTitles(tester);
      expect(before.any((t) => t.contains('电影')), isTrue,
          reason: 'sub1 的内容带"电影"标记');

      await tester.tap(find.text('子站sub2'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 20));

      final after = _visibleCardTitles(tester);
      expect(
        after.any((t) => t.contains('剧集')),
        isTrue,
        reason: '★★ 新渠道（sub2）的内容必须出现',
      );
      expect(
        after.any((t) => t.contains('电影')),
        isFalse,
        reason: '★★★ 旧渠道（sub1）的内容必须**被替换掉** —— '
            '两张渠道的内容同时留在屏幕上就是"叠加"，'
            '那就是 Owner 抱怨的"一次性加载太多"的另一半。',
      );
    });

    testWidgets('切渠道**不整页 setState**：只重建本区块，不重建父级', (tester) async {
      final fake = _FakeAgg(channels: [_ch('sub1'), _ch('sub2'), _ch('sub3')]);
      fake.install();

      // 用一个**会记 build 次数**的父级包住区块
      var parentBuilds = 0;
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final table = <String, List<MediaItem>>{};
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setParent) {
                parentBuilds++;
                return SingleChildScrollView(
                  child: AggChannelsBlock(
                    provider: kTvboxAggregateId,
                    onOpenDetail: (_) {},
                    itemsOf: (p, id) =>
                        table['$p::$id'] ?? const <MediaItem>[],
                    loadItems: (Section s) async {
                      table['${kTvboxAggregateId}::${s.id}'] =
                          fake.itemsOf(s.id);
                    },
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 20));

      final buildsBefore = parentBuilds;
      await tester.tap(find.text('子站sub2'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 20));

      expect(
        parentBuilds,
        buildsBefore,
        reason: '★★★ 切渠道**不许整页 setState** —— 父级 build 次数必须不变。\n'
            '（判据口径：切渠道时只允许 AggChannelsBlock 自己重建；\n'
            ' 父级跟着重建意味着整页 ListView 全部重算 —— 那正是"卡"的第二个来源。）\n'
            '父级 build：$buildsBefore → $parentBuilds',
      );
      // 反空真：父级**确实**在这期间能重建成（不是"死活不重建"）
      expect(parentBuilds, greaterThan(0));
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ① 结构：横向渠道条 + 复用 SourinHorizontalRail（不造第二套）
  // ═══════════════════════════════════════════════════════════════════
  group('★ N9 ① 结构：横向渠道条复用 SourinHorizontalRail', () {
    testWidgets('聚合区块真的画出了渠道条（探针读数 channels > 0）', (tester) async {
      final fake = _FakeAgg(channels: [_ch('sub1'), _ch('sub2'), _ch('sub3')]);
      fake.install();
      await _pumpBlock(tester, fake, channelCount: 3);

      final last = debugHomeAggChannelRenderLast;
      expect(last, isNotNull, reason: '渲染路径必须上报读数');
      expect(
        last!.channels,
        3,
        reason: '★★★ 结构判据：渠道条真的渲染了 3 个渠道。\n'
            '把渠道条去掉 ⇒ 这里恒 0 ⇒ 本条红（注入 B）。',
      );
      expect(last.current, 'sub1');
      expect(last.sections, 1, reason: '当前渠道有 1 个区块（内容真的换上了）');
    });

    testWidgets('渠道条**复用** SourinHorizontalRail（包裹写法，行为同款）', (tester) async {
      final fake = _FakeAgg(channels: [_ch('sub1'), _ch('sub2'), _ch('sub3')]);
      fake.install();
      await _pumpBlock(tester, fake, channelCount: 3);

      /*
       * ★ 判据要**指名道姓**地抓住"渠道条那一条轨道" ——
       *   不能只 `find.byType(SourinHorizontalRail)` 数个数：
       *   本块下半部分还会为**每个 section** 画 `_Rail`，
       *   而 `_Rail` 自己也包 rail ⇒ 总数是 2（渠道条 1 + 内容 1）。
       * ```text
       * 弱判据 `findsOneWidget`          ⇒ 会因内容轨道而误红（实测抓到）
       * 弱判据 `findsWidgets`（>0）      ⇒ 假绿：内容是 0 时渠道条照样有，
       *                                    分不清"哪一条"是渠道条
       * ⇒ 正确形状：**以渠道药丸为锚**，找它的 rail 祖先（恰好 1 条）
       * ```
       */
      final channelRail = find.ancestor(
        of: find.text('子站sub1'),
        matching: find.byType(SourinHorizontalRail),
      );
      expect(
        channelRail,
        findsOneWidget,
        reason: '★★★ 渠道条必须复用 `SourinHorizontalRail`'
            '（N9 修法方向 4：与 source_bar / 旧04 共享同一套横向轨道，'
            '**不许造第二套**）—— 判据是"药丸被这个 rail 包住"，不是"数够几个"',
      );

      /*
       * ⚠️ 取**渠道条那个 ListView 自己的 element**（不是 rail 的 element）——
       *   `SourinHorizontalRail` 是**把 ScrollConfiguration 建在 child 之上**，
       *   从 rail 自身的 context 查 `ScrollConfiguration.of` 拿到的是**父级**
       *   的那一份（没有 mouse）。这与 `zz_t1026` 的做法一致
       *   （那里也是用 rail **内部** ListView 的 element）。
       */
      final innerList = find.descendant(
        of: channelRail,
        matching: find.byType(ListView),
      );
      final local = ScrollConfiguration.of(tester.element(innerList));
      expect(
        local.dragDevices,
        contains(PointerDeviceKind.mouse),
        reason: '★★ 复用 rail 的意义就在这里：鼠标拖拽横滑（旧04 的既有行为）',
      );

      // ★ 真的能拖（不是"包了个壳但拖不动"）
      await tester.drag(channelRail, const Offset(-120, 0),
          kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('渠道条是**横向**列表（不是纵向、不是下拉）', (tester) async {
      final fake = _FakeAgg(channels: [_ch('sub1'), _ch('sub2'), _ch('sub3')]);
      fake.install();
      await _pumpBlock(tester, fake, channelCount: 3);

      // ★ 同上一组的形状：以渠道药丸为锚找它所在的那个 ListView
      final chipRailList = find.ancestor(
        of: find.text('子站sub1'),
        matching: find.byType(ListView),
      );
      expect(chipRailList, findsWidgets, reason: '渠道条必须是一个滚动列表');
      final dirs = tester
          .widgetList<ListView>(chipRailList)
          .map((w) => w.scrollDirection)
          .toList();
      expect(
        dirs,
        contains(Axis.horizontal),
        reason: '★ Owner 要的是"二级**横向**渠道"（实际方向：$dirs）',
      );
      // 反空真：这个锚点确实能定位到唯一一条渠道条（不是把内容轨道也圈进来）
      expect(
        tester
            .widgetList<ListView>(
              find.ancestor(
                of: find.text('子站sub1'),
                matching: find.byType(ListView),
              ),
            )
            .where((w) => w.scrollDirection == Axis.horizontal)
            .length,
        1,
        reason: '药丸的祖先里应当恰有 1 条横向列表（就是渠道条自己）',
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ 分流：按 `source.key` 走渠道条，**不是**被当成直播条吞掉
  // ═══════════════════════════════════════════════════════════════════
  group('★ N9 ④ 分流：聚合区块按 key 分流（否则整块静默消失）', () {
    late String home;

    setUpAll(() {
      home = File('lib/ui/home_page.dart').readAsStringSync();
    });

    /// 剥掉注释（本仓 t1014 / t66 / tcache3 同款做法）
    ///
    /// ⚠️ **必须剥**：本文件的注释里**故意**写着 `src.type == 'custom'`
    ///    这些词当反例（解释分流为什么要按 key）—— 不剥就会被注释骗成绿。
    String stripComments(String s) {
      var out = s.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
      out = out.replaceAll(RegExp(r'//[^\n]*'), '');
      return out;
    }

    test('★★★ 分流判据用的是 `source.key`，不是 `type`', () {
      final code = stripComments(home);
      expect(
        code.contains("kTvboxAggChannelsKey"),
        isTrue,
        reason: '★★★ 聚合区块必须按 `key == kTvboxAggChannelsKey` 分流。\n'
            '只按 `type == "custom"` 分流 ⇒ 聚合区块走直播条那条路 ⇒\n'
            '  `_LiveStrip(liveStrip: 空)` ⇒ 零尺寸 ⇒ **整块消失且不报错**。',
      );
      // 阳性对照：判据确实能看见 key
      expect("'tvbox_agg_channels'".contains('tvbox_agg_channels'), isTrue);
    });

    test('★★★ 聚合源**不许**触发直播条探测（真机抓到的 8 次白请求）', () {
      /*
       * # 这条守的是真机验收抓到的缺陷（不是推测）
       *
       * `.probe/n9-ui-real-20261027-090846/stderr.log` 原文：
       * ```text
       * [LIVE-PROBE] 探测失败 tvbox_agg/srclchild: 该源不支持直播
       * … 共 8 条（= kLivePreview 长度），首屏就发出去了
       * ```
       * 原因：`_maybeProbeLiveStrip` 只判 `type == 'custom'`，
       *   而聚合渠道条区块**正是** custom ⇒ 聚合源被当成"有直播条的源"。
       * ⇒ 8 次必然失败的请求（与本任务要消灭的"请求放大"同类）。
       */
      final code = stripComments(home);
      final i = code.indexOf('void _maybeProbeLiveStrip()');
      expect(i, greaterThan(0), reason: '前提：这个方法还在');
      // 取函数体（到下一个 "if (!hasCustom) return;" 之后一段）
      final body = code.substring(i, (i + 900).clamp(0, code.length));
      expect(
        body.contains('_isAggChannelsSection'),
        isTrue,
        reason: '★★★ 直播条探测的判据必须排除聚合渠道条（同一个 key 判据）。\n'
            '不排除 ⇒ 首屏白打 8 个 `srcl*` 取流请求，全部失败。\n'
            '实测日志：`.probe/n9-ui-real-20261027-090846/stderr.log`',
      );
    });

    test('★★★ 两个分流判据**同源**（标题行与内容区不许各判一套）', () {
      /*
       * ══════════════════════════════════════════════════════════════════
       * ⚠️ 2026-10-27（**交叉复核 D2 修复**，复核者 tvbox-rust）：
       *    本条原先是**计数阈值** `allMatches(...).length >= 3`，被实测判为
       *    **中危假绿**（余量只有 1）。复核者的决定性实验：
       * ```text
       * 把**内容区**那处消费点改成 `if (false)`（**注释里什么都不留**）
       *   ⇒ stripComments 后计数 = 3  ⇒ 断言 PASS
       *   flutter test test/zz_n9_agg_channel_rail_test.dart ⇒ +23 **全绿**
       * 而这个注入是**真功能坏**：内容区分流失效 ⇒ 不走 AggChannelsBlock
       *   ⇒ 落到 `else if (src.type == 'custom')` ⇒ `_LiveStrip(liveStrip: 空)`
       *   ⇒ 零尺寸 ⇒ **聚合区块整块静默消失、不报任何错**。
       * ⇒ ④组对"整块静默消失"的覆盖**只到计数层，不到语义层**；
       * ```
       *
       * # 修法（三层源码文本判据 + 一层"条件闭合"；**行为级兜底未做**）
       * ```text
       * ① **语义位置**：不只数次数，还要断言**内容区那一处**的消费点
       *    真的在 `AggChannelsBlock(` **紧邻之前**的分流位置上。
       * ② **肯定形态**：断言是 `if (_isAggChannelsSection(...))` 而不是 `if (!…)`
       *    —— 否则"名字在、语义反"，① 与旧判据**都会绿**。
       * ③ **反向对照**：断言未剥注释的原文里确实含 `src.type == 'custom'`
       *    ⇒ 证明 `stripComments` 真起作用（否则注释里那些反例会让本组被注释满足）。
       * ④ **条件闭合**（复核者第二轮构造的绕过逼出来的，见下）：
       *    断言 `if (` 里**只有判据自身**，封死 AND/OR 附加条件。
       * ```
       *
       * ## ⚠️ ④ 的由来：① ② ③ 三层**都能被一个 AND 项绕过**（复核者实测）
       * ```text
       * 复核者构造并实测：`if (_isAggChannelsSection(section) && _bypassNever())`
       *   （`_bypassNever()` 恒 false）
       *   ⇒ 判据名在窗口里（① 过）、形态是肯定（② 过）、条件闭合前多一项（③ 无关）
       *   ⇒ **+23 全绿**，而聚合区块**实际不走** `AggChannelsBlock`
       *      ⇒ 落到 `else if (src.type == 'custom')` ⇒ `_LiveStrip(空)`
       *      ⇒ **整块静默消失**（正是本条要防的那件事）。
       * ★ 根因：①②③ 都是**源码文本判据**，**都不问"这个判断的**结果**是什么"**。
       *   加一个 AND 项**不改变任何文本特征**⇒ 三层全通过。
       *   而且这不是刻意作弊：`if (x && 某开关)` 是后来的人加条件时**顺手就会写**的形态。
       * ★ ④ 的代价（**故意的**）：将来真要在该处加合法条件 ⇒ 必须同批改这条断言。
       *   那**正是我们想要的** —— 那是个语义变更，就该被门禁看见。
       * ```
       *
       * ## ★ 行为级兜底**未做**（如实登记，别被本文件的注释误导）
       * ```text
       * 真正**封闭**的形态是行为级：喂一个 `source.key == kTvboxAggChannelsKey`
       * 的 section 进 `_SectionBlock`，断言树上出现 `ValueKey('home-agg-channels')`
       * —— 它只看**结果**、不看文本，①②③④ 全绕过也躲不过。
       * **本轮没做**，原因是 `_SectionBlock` 是**私有类**（`home_page.dart:2723`），
       * 要挂它得给生产文件开 `@visibleForTesting` 缝。
       * ⚠️ 复核者指出（我认账）：`home_page.dart` **本批已由 home-ui 开了 4 处同类缝**
       *    （`:860/:864/:868/:912`）⇒ 成本很低、本批有先例。
       *    所以准确说法是「**本轮没做到**」，**不是**「技术上做不到」或「不在本批范围」。
       * ⇒ 记为**下批加固项**；在此之前，①②③④ 封的是**源码文本特征**，
       *   `_bypassNever()` 那种 AND 绕过由 ④ 挡住，但④ 仍是文本判据。
       * ```
       *
       * ★ 通则（本批同族第四次）：**判据的数量/文本特征 ≠ 判断的结果**。
       *   先例：`.probe/t66-scanner-blockcomment-scope.md`（对象选宽）、
       *   t94 的词边界守卫（引用**形态**决定判据成不成立）、
       *   t1053 的 N6-host 组（不剥注释 ⇒ 删代码留注释仍绿）。
       */
      final code = stripComments(home);

      // ① 定义必须在位（前提，不是判据本身）
      expect(
        code.contains('_isAggChannelsSection(Section s)'),
        isTrue,
        reason: '★ 前提：判据函数必须先被定义（`_SectionBlock._isAggChannelsSection`）',
      );

      // ② ★ 语义位置：内容区那一处消费点必须在 `AggChannelsBlock(` **紧邻之前**
      final blockAt = code.indexOf('AggChannelsBlock(');
      expect(blockAt, greaterThan(0),
          reason: '★ 前提：内容区必须真的构造 `AggChannelsBlock`');
      /*
       * ⚠️ 取"紧邻之前的窗口"，而不是"全文任意位置" —— 后者正是原判据
       *    （数次数）被绕过的地方：把消费点改成 `if (false)` 后，
       *    这个窗口里的 `_isAggChannelsSection` 就**没了**，而全文计数仍 >= 3。
       */
      final gate =
          code.substring((blockAt - 260).clamp(0, code.length), blockAt);
      expect(
        gate.contains('_isAggChannelsSection'),
        isTrue,
        reason: '★★★ 内容区**紧邻** `AggChannelsBlock(` 之前必须是同源判据分流。\n'
            '注入「把那处改成 `if (false)`（注释不留）」⇒ 本条立刻红 —— '
            '而原计数判据（>= 3）**照样绿**（D2 实测）。\n'
            '窗口内容：$gate',
      );
      /*
       * ⚠️ 再堵一层：**取反**式绕过。
       * ```text
       * 只断言"窗口里出现过这个名字"还有个缺口：
       *   `if (!_isAggChannelsSection(section))` —— 名字在、语义反
       *   ⇒ 旧判据与上面那条**都会绿**，而聚合区块照样走直播条那条路。
       * ⇒ 必须断言它出现在**肯定形态**里（`if (` 之后紧跟调用名）。
       * ★ 这就是 D2 的教训本身：数量/存在 ≠ 语义位置。
       * ```
       */
      final positiveForm =
          RegExp(r'if\s*\(\s*_SectionBlock\._isAggChannelsSection\(')
              .hasMatch(gate);
      expect(
        positiveForm,
        isTrue,
        reason: '★★★ 内容区的同源判据必须是**肯定形态**（`if (_isAggChannelsSection(...))`）。\n'
            '取反（`if (!…)`）会让名字仍在、语义翻转 ⇒ 聚合区块静默消失而本条仍绿。\n'
            '窗口内容：$gate',
      );

      /*
       * ⚠️ ④ **条件闭合**：①②③ 三层都被一个 AND 项绕过（复核者实测，见本条文件头说明）。
       * ```text
       * 复核者构造：`if (_isAggChannelsSection(section) && _bypassNever())`
       *   （`_bypassNever()` 恒 false）⇒ **+23 全绿**，而聚合区块实际不走
       *   `AggChannelsBlock` ⇒ 落到直播条那条路 ⇒ 整块静默消失。
       * 根因：①②③ 都是**源码文本判据**，都不问"这个判断的**结果**是什么"，
       *   而加一个 AND 项**不改变任何文本特征**。
       * ```
       * ⇒ 断言 `if (` 里**只有判据自身**（可带自己的 `)`），不许再接 `&&` / `||`。
       * ⚠️ 代价是**故意的**：将来真要在该处加合法条件 ⇒ 必须同批改这条断言 ——
       *    那是个语义变更，就该被门禁看见。
       *
       * ## ⚠️ 代价的**完整范围**（复核者第 3 轮实测，比"加条件"更宽 —— 别只看这一层）
       * ```text
       * 复核者用真门禁逐条跑（.probe/t7-d2-cost-matrix.log），实测：
       *   · AND 绕过 / 取反        ⇒ RED ✓（**第 4 层与第 2 层确实挡住了**）
       *   · **多余括号** `if ((…))`  ⇒ **RED（误红）** —— 零语义变化，不该校验
       *   · **去掉外层 class 前缀**  ⇒ **RED（误红）** —— 同文件内合法重构
       * ★ 且误红**不是只长在这一层**：复核者第一版把"多余括号"归给第 4 层，
       *   把第 4 层正则放宽后**仍然红** ⇒ 追查才定位真凶是**第 2 层「肯定形态」**
       *   那条（`:705`）**也不容忍 `if ((`**。
       *   ⇒ **第 2 层与第 4 层各管一部分，只改最后一层不解决问题。**
       * ★ 复核者复盘：他第二轮逐层单独验"第 2 层有效 / 第 4 层有效"时，
       *   **从没验过层与层的代价叠加** —— 代价不止长在最后加的那层上。
       * ```
       * **遇到误红怎么办**：按"**改断言**"处理（把两层正则一起放宽到容忍等价括号），
       * **不要怀疑实现坏了** —— 这两条正则封的是**文本特征**，它们对"等价改写"天然敏感。
       * ⚠️ 放宽时**必须逐条跑真门禁**（复核者自己就因"只推演没实测"归错过一次层）。
       * 根治方向见下（行为级兜底：它只看结果，既不误红也不被 AND 绕过）。
       */
      final closedForm =
          RegExp(r'if\s*\(\s*_SectionBlock\._isAggChannelsSection\([^)]*\)\s*\)')
              .hasMatch(gate);
      expect(
        closedForm,
        isTrue,
        reason: '★★★ 内容区的同源判据必须是**条件闭合**形态：\n'
            r'`if (_SectionBlock._isAggChannelsSection(...))`' '\n'
            '**不许**再接 `&&` / `||` 附加条件 —— 例如\n'
            '  `if (_isAggChannelsSection(section) && _bypassNever())`（恒假）\n'
            '判据名还在窗口里、形态也是肯定 ⇒ ①②③ **全过**，\n'
            '而聚合区块**实际不走** `AggChannelsBlock` ⇒ 落到直播条那条路 ⇒ 整块静默消失。\n'
            '★ 根因：①②③ 都只看**源码文本**，不问判断的**结果**；加 AND 项不改文本特征。\n'
            '★ 代价是故意的：真要加合法条件 ⇒ 同批改这条断言（那是个语义变更，该被看见）。\n'
            '⚠️ **代价范围比"加条件"宽**：语义等价的改写（多余括号 `if ((…))`、'
            '去掉外层 class 前缀）**也会红**，且**第 2 层与第 4 层各管一部分** —— '
            '遇到时按"改断言"处理，不必怀疑实现坏了（见本条文件头的代价说明）。\n'
            '窗口内容：$gate',
      );

      // ③ 标题行那一处也要同源（保留旧断言的**语义**部分）
      expect(
        code.contains('!_SectionBlock._isAggChannelsSection(section)'),
        isTrue,
        reason: '★★ 标题行「去直播」分流也必须走同一个判据 —— '
            '只改一处会出现"标题行给它「去直播」、内容区却给它渠道条"的自相矛盾',
      );

      // ④ 反向对照：`stripComments` 真的起作用（不是形同虚设）
      expect(
        home.contains("src.type == 'custom'"),
        isTrue,
        reason: '★ 反向对照：**未剥注释**的原文里确实有 `src.type == \'custom\'` '
            '这些词（本文件注释里**故意**写的反例）⇒ 证明上面的 `stripComments` '
            '真的剥掉了它们，否则那些注释会让本组多条断言被注释满足',
      );
    });

    test('★★ 聚合渠道条区块**不给**「去直播」按钮', () {
      final code = stripComments(home);
      expect(
        code.contains("src.type == 'custom' &&"),
        isTrue,
        reason: '★ 旧代码按 `type == custom` 一律给「去直播」—— '
            '聚合渠道条不是直播，点它会去直播页（完全不相干）。\n'
            '必须排除渠道条那一条。',
      );
    });

    test('★ home 每条可交互横向轨道都包了 SourinHorizontalRail（守恒律）', () {
      final code = stripComments(home);
      final offenders = <String>[];
      var interactive = 0;
      for (final m
          in RegExp(r'scrollDirection: Axis\.horizontal').allMatches(code)) {
        final line = code.substring(0, m.start).split('\n').length;
        final ahead =
            code.substring(m.start, (m.start + 300).clamp(0, code.length));
        final isSkeleton = ahead.contains('NeverScrollableScrollPhysics');
        final behind =
            code.substring((m.start - 400).clamp(0, code.length), m.start);
        final wrapped = behind.contains('SourinHorizontalRail(');
        if (!isSkeleton) {
          interactive++;
          if (!wrapped) offenders.add('line $line');
        }
      }
      expect(interactive, greaterThan(0), reason: '反空真：必须扫到可交互轨道');
      expect(
        offenders,
        isEmpty,
        reason: '★★ N9 新增的渠道条也必须包 `SourinHorizontalRail`。违约：$offenders',
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  ⑥ 真核心往返（**不是替身**）：命令名/参数名/返回形状与 Dart 解析对得上
  // ═══════════════════════════════════════════════════════════════════════
  //
  // # 这一组补的是"契约只在替身上验过"的缺口
  // ```text
  // 上面 ①~⑤ 全在 `debugSetAggChannelFetchers` 替身上跑 ⇒ 它们证明的是
  //   "UI 在那份形状下行为对"，**不能**证明"命令名字符串/参数名/Dart 解析
  //   与真核心对得上"。本仓为此单独有 `zz_t66_cs1_real_core_e2e_test.dart`
  //   （"写了没调用"的同类缺口）。
  // ⇒ 这里让**真核心**（`sourin_core.dll`）跑一遍：
  //     ① `tvbox_agg_channels` 真能调用且**不报错**
  //     ② 导出一份**只有一个子站**的最小 TVBox 配置 ⇒
  //        `channels()` 真的把该子站列出来（证明清单来源是 registry+配置）
  //     ③ `tvbox_agg_channel_home(channel_id)` 真能调用，
  //        且错误形态与契约一致（未实现类 ⇒ 可读的 not_found/other）
  // ```
  //
  // # 为什么**不**断言"渠道里有几个"（那不是本文件能决定的）
  // ```text
  // 渠道数取决于数据目录里已导入的 TVBox 订阅 —— 隔离目录里通常是 0。
  // ⇒ 本组只断言"命令通、形状对、错误可读"，**不断言业务数量**。
  // ```
  //
  // ⚠️ 隔离纪律：全部写进**系统临时目录**下的沙盒，收尾删除；
  //    绝不碰开发者的真实数据目录。
  group('★ N9 ⑥ 真核心往返：命令名/参数名/形状对得上', () {
    late Directory sandbox;

    /// 一个**真的可探测**的苹果CMS端点（回环 HTTP，不是 mock 类）
    ///
    /// # 为什么必须真起一个（而不是写 `example.invalid`）
    /// ```text
    /// `import_tvbox_config` 对 type:1 的站点会先**真探测**：
    ///   `?ac=list`      ⇒ 必须有非空 `class` 数组
    ///   `?ac=videolist&pg=1` ⇒ 必须有非空 `list`
    /// 两道关都过才注册成 provider（见 tvbox.rs probe_apple_cms）。
    /// 起一个不可达的地址 ⇒ 站点进 skipped（stage=probe）⇒ 永远进不了
    /// registry ⇒ `channels()` 当然是空的 —— 那是**正确行为**，
    /// 但会让"渠道条列得出子站"这条断言变成**假红**。
    /// ⇒ 本组用一个真回环端点，把探测两道关喂过。
    /// ```
    /// ⚠️ 不用 mock HTTP 类：dart:io 3.x 的 HttpClient 是 interface class
    ///    （见 `test/support/zz_cr_upd_origin.dart` 的说明）。
    late HttpServer origin;

    Future<void> startOrigin() async {
      origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      origin.listen((req) async {
        final r = req.response;
        r.headers.contentType = ContentType.json;
        String body;
        if (req.uri.queryParameters['ac'] == 'list') {
          // 分类接口：非空 class
          body = '{"class":[{"type_id":"1","type_name":"电影"},'
              '{"type_id":"2","type_name":"电视剧"}]}';
        } else {
          // 列表接口：非空 list
          body = '{"total":2,"list":[{"vod_id":1,"vod_name":"甲片"},'
              '{"vod_id":2,"vod_name":"乙片"}]}';
        }
        r.write(body);
        await r.close();
      });
    }

    String originApi() =>
        'http://${InternetAddress.loopbackIPv4.address}:${origin.port}/api.php/provide/vod/';

    setUp(() async {
      if (!requireCoreFiles(<String>['sourin_core.dll'],
          notVerified: 'N9 渠道命令的真核心往返（@visibleForTesting 于本文件）')) {
        sandbox = Directory.systemTemp.createTempSync('n9-bogus');
        return;
      }
      sandbox = Directory.systemTemp.createTempSync('n9-core-');
      try {
        await SourinCore.startAsync(sandbox.path);
      } catch (e, st) {
        coreStartFailedThenSkip(e, st, notVerified: 'N9 渠道命令的真核心往返');
        return;
      }
      await startOrigin();
    });

    tearDown(() async {
      try {
        await origin.close(force: true);
      } catch (_) {}
      try {
        if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('★★★ `tvbox_agg_channels` 真能调用（命令名对得上、不返回未接入）', () async {
      // ★ 走**生产路径**（不经替身）：`fetchAggChannels` 在替身为 null 时
      //   调的就是 `SourinCore.callAsync('tvbox_agg_channels')`
      final payload = await fetchAggChannels();
      // 到这里没抛 = 命令存在且返回可解析的 JSON
      expect(payload.ok, isTrue);
      expect(payload.channels, isA<List<AggChannel>>());
    });

    test('★★★ 导入一个子站后 `channels()` 真的列出它（清单来源=registry+配置）', () async {
      final cfg = '{"sites":[{"key":"sub1","name":"子站甲","type":1,'
          '"api":"${originApi()}","searchable":1}]}';
      final r = await SourinApi.importTvboxConfig(cfg);
      expect(
        r.imported,
        isNotEmpty,
        reason: '★ 前提：真回环端点必须让探测两道关都过。'
            '实际 skipped=${r.skipped.map((s) => s.reason).toList()}',
      );

      /*
       * ⚠️ **不要**假设渠道 id == 配置里的 `key`（我第一版就这么写，实测红）
       * ```text
       * 实测：配置 key='sub1' ⇒ channels() 返回 id='127'
       * 原因：Rust 侧 `unique_id`/`to_id` 生成的是**行号派生的 id**
       *   （`127` 那种形态），不是配置 key —— 契约也说
       *   "id 与 MediaId.provider 同一字符串"，没说过它等于 key。
       * ⇒ 判据必须按**真返回**来写：数一数"导入成功几个 ⇒ 清单里就有几个"，
       *   而不是把我猜的 id 写死（写死就是拿我的假设当契约）。
       * ```
       */
      final payload = await fetchAggChannels();
      expect(
        payload.channels.length,
        r.imported.length,
        reason: '★★★ 导入成功 ${r.imported.length} 个子站 ⇒ 渠道清单必须恰好有这么多。\n'
            '实际：${payload.channels.map((c) => "${c.id}/${c.name}").toList()}\n'
            '（若为空 ⇒ channels() 没读 registry/配置；若偏多 ⇒ 清单串了别的源）',
      );
      // 名字要能对上导入时的 name（证明清单没张冠李戴）
      expect(
        payload.channels.map((c) => c.name).toList(),
        contains('子站甲'),
        reason: '★ 渠道名必须来自 manifest.name（导入时就写进去的那个）',
      );
    });

    test('★★★ `tvbox_agg_channel_home` 参数名对得上（channel_id 逐字）', () async {
      // 不存在的渠道 ⇒ 契约里是"可读错误"（不是崩溃、也不是静默空）
      Object? err;
      try {
        await fetchAggChannelHome('no-such-channel-xyz');
      } catch (e) {
        err = e;
      }
      expect(
        err,
        isNotNull,
        reason: '★★★ 契约：渠道不存在/未启用 ⇒ 返回错误 '
            '`找不到渠道 <id>（可能已被移除或未启用）`。\n'
            '**什么都没抛**说明参数名没对上（Rust 侧收到了空 channel_id'
            '却仍返回 ok）—— 那是"参数名漂了但没人发现"的典型形态。',
      );
      expect(
        err.toString(),
        contains('找不到渠道'),
        reason: '★★ 错误形态要与 tvbox-rust 冻结的契约逐字一致（实际：$err）',
      );
    });

    test('★★★ 已导入的渠道：`channel_home` 返回**该渠道**的区块（真网络回环）', () async {
      final cfg = '{"sites":[{"key":"sub2","name":"子站乙","type":1,'
          '"api":"${originApi()}","searchable":1}]}';
      final r = await SourinApi.importTvboxConfig(cfg);
      expect(r.imported, isNotEmpty, reason: '前提：子站要真的注册进来');

      // ★ 用**真返回的 id**（不是配置 key —— 见上一条用例那段说明）
      final payload = await fetchAggChannels();
      expect(payload.channels, isNotEmpty);
      final chId = payload.channels.first.id;

      final home = await fetchAggChannelHome(chId);
      expect(home.channelId, chId,
          reason: '契约：channelId 要回显**请求的那个 id**');
      expect(
        home.sections,
        isNotEmpty,
        reason: '★★★ 回环端点已给出非空 class ⇒ 该渠道必须有区块。\n'
            '空 sections 说明按渠道取数没接上（或 home 收敛把区块丢了）。',
      );
      for (final s in home.sections) {
        expect(
          s.id.startsWith('$chId::'),
          isTrue,
          reason: '★ 契约：区块 id 必须是 `<渠道id>::<原区块 id>`（$s.id）\n'
              '—— 这个前缀就是既有 `child::category` 路由的键，零新代码那条。',
        );
        // source 的 category_id 也带前缀（list 路由靠它）
        if (s.source.isCategory) {
          expect(s.source.categoryId, startsWith('$chId::'));
        }
      }
    });
  });

  group('★ N9 ⑤ 两种"空"必须分得开（不许合成一个静默）', () {
    testWidgets('① `ok:true` + 空清单 ⇒ 说"还没有导入"（用户可行动）', (tester) async {
      final fake = _FakeAgg(channels: const <AggChannel>[]);
      fake.install();
      await _pumpBlock(tester, fake);

      expect(
        find.textContaining('还没有导入'),
        findsOneWidget,
        reason: '★★ `ok:true` + `channels: []` 是"命令通了但用户还没导入聚合源"——\n'
            '这是**用户可行动**的状态，必须给出这句提示。\n'
            '整块零尺寸（`SizedBox.shrink`）会让它变成纯静默，'
            '用户无从知道该去导入。',
      );
      // 结构读数：没有渠道条（0 个渠道 ⇒ 条不该画）
      expect(
        debugHomeAggChannelRenderLast,
        isNull,
        reason: '零渠道 ⇒ 渠道条不该渲染（没有可点药丸）',
      );
    });

    testWidgets('② `unsupported` ⇒ 说"还没有接入"（功能没接线，与①分开）', (tester) async {
      final fake = _FakeAgg(channels: [_ch('sub1')]);
      fake.install(throwOnChannels: true);
      await _pumpBlock(tester, fake);

      expect(
        find.textContaining('还没有接入'),
        findsOneWidget,
        reason: '★★ 与 ① **逐字不同**：这是"功能没接线"，成因与用户该做的事'
            '（更新版本 vs 去导入）完全不同 ⇒ 不许合成一个静默。',
      );
      expect(
        find.textContaining('还没有导入'),
        findsNothing,
        reason: '★★★ 两种成因不许混淆 —— 这条是"接口没接上"，'
            '不是"用户没导入"。文案互串会让排障方向完全错。',
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑤b 接口未联通时不许画假条 / 不许静默消失
  // ═══════════════════════════════════════════════════════════════════
  group('★ N9 ⑤ 接口未就绪时如实报错', () {
    testWidgets('取清单失败 ⇒ 画出原因（不是空条、不是假装没内容）', (tester) async {
      final fake = _FakeAgg(channels: [_ch('sub1')]);
      fake.install(throwOnChannels: true);
      await _pumpBlock(tester, fake);

      // ★ 用户可见的原因里必须能看出"没接入"（而不是"暂无内容"那种含糊话）
      expect(
        find.textContaining('还没有接入'),
        findsOneWidget,
        reason: '★★ 数据层未联通时必须**如实**说"这个功能还没有接入"。\n'
            '画一条空渠道条（看起来像"源里没有渠道"）或整块消失都是假绿。',
      );
      // ★ 结构读数必须是"**没有读数**"（渠道条压根没进树）—— 与上面那条一起构成"如实"。
      //
      // ⚠️ 判据口径（注入 B 校准出来的）：读数由**渠道条自己**的 build 写
      //（`_AggChannelRail.build`）。条不在树上 ⇒ 这一轮没有人写读数 ⇒
      //  last 为 null。**不是**"channels == 0"那种弱口径 —— 那种在
      //  "数据在、条被删掉"时仍是 3（假绿，实测抓到过）。
      expect(
        debugHomeAggChannelRenderLast,
        isNull,
        reason: '★★ 取清单失败 ⇒ 渠道条不该被画出来。读数"有值且 channels>0"'
            '就说明条还在（假绿）。',
      );
    });

    testWidgets('单渠道失败**不连坐**：挂在那个渠道上，不吞异常', (tester) async {
      final fake = _FakeAgg(channels: [_ch('sub1'), _ch('ghost')]);
      fake.install();
      await _pumpBlock(tester, fake);

      // sub1 正常
      expect(_visibleCardTitles(tester), isNotEmpty);
      // 点一个"会被 Rust 侧拒绝"的渠道
      await tester.tap(find.text('子站ghost'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 20));

      expect(
        find.textContaining('找不到渠道'),
        findsOneWidget,
        reason: '★★ 失败原因必须**可见**（不许吞异常装没事）—— '
            '文案就是契约里那句 Rust 侧错误。',
      );
      // 渠道条**仍然在**（失败没把整块带走）
      expect(debugHomeAggChannelRenderLast!.channels, 2,
          reason: '★ 单渠道失败不许把渠道条一起抹掉（聚合源"单站失败隔离"纪律）');
    });
  });
}