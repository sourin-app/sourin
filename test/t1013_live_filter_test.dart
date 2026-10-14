// ═══════════════════════════════════════════════════════════════════════
//  task-1013：直播页「按源筛选」+「按分类筛选」（Owner 要求）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话
// ```text
// > 直播页面,支持一下按照源筛选,还有支持分类筛选
// ```
//
// # ★★★ 为什么这里测的是 `LiveChannelList` 而不是 `LivePage`（结构墙）
//
// ```text
// 与 `t48_live_page_all_channels_test.dart` 记的是**同一道墙**：
//   · `LivePageState._groups` 只由 `loadAll()` 从 FFI 填
//     （`live_page.dart` `SourinApi.getLiveChannels()`）——
//     `getLiveChannels` 直接 `SourinCore.callAsync('get_live_channels')`
//     ⇒ `flutter test` 里没有核心 DLL ⇒ 抛错被 catch ⇒ `_groups` **恒为空**
//   · 该命令**没有**测试注入点（全仓搜 `debugLiveChannelsFetcher` 零命中；
//     `getLiveChannels` 里也没有 `if (debug… != null)` 分支）
//   · `LivePage` 构造参数也不接受频道数据
// ⇒ 整页层面**没法喂数据** ⇒ 无法在 `LivePage` 上"真的渲染出频道行"。
//
// ★ 但**筛选逻辑本身**被抽到了**公开**的 `LiveChannelList`（构造接收
//   `providers` / `channels`）⇒ 本文件直接 pump 它、喂假频道，
//   就能**真的渲染**并断言筛选结果 —— 不是读源码字符串（铁律：不许假绿）。
// ```
//
// # 本文件钉住什么
// ```text
// ① 按源筛选：列表只含该源的频道（**真的渲染**断言，不是读源码）
// ② 按分类筛选：列表只含该分类的频道
// ③ 两者组合（AND）
// ④ 筛选为空 ⇒ **明确的空态文案**（不许一片空白）
// ⑤ ★★ 反向守卫：筛选**不得**改变 provider 的启用状态
//    —— 断言 `SourinApi.setProviderEnabled` **没被调用**
//    —— 这是 task-53 用户否定的那个形态，必须钉死
// ```
//
// # 每一步都能测出反面（红度实测见交付报告）
// ```text
// 去掉 `_filtered` 里的 `.where(...)` ⇒ ①②③ 立刻红。
// 把空态文案改回一句空白 ⇒ ④ 红。
// 在 `_pickSource` 里加一句 `setProviderEnabled` ⇒ ⑤ 红。
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/live_page.dart';

/// 与 `live_page_test.dart:106` 同一判据的剥注释（状态机版，避免假通过）
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  String? quote;
  while (i < src.length) {
    final c = src[i];
    final next = i + 1 < src.length ? src[i + 1] : '';
    if (quote != null) {
      if (c == r'\') {
        out.write(c);
        if (next.isNotEmpty) {
          out.write(next);
          i += 2;
          continue;
        }
      }
      if (c == quote) quote = null;
      out.write(c);
      i++;
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && next == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && next == '*') {
      i += 2;
      while (i < src.length &&
          !(src[i] == '*' && i + 1 < src.length && src[i + 1] == '/')) {
        if (src[i] == '\n') out.write('\n');
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

/// 真实壳（forui 主题 + material_ui 的 MaterialApp）—— 与 `live_page_test` 同款
Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    theme: theme,
    builder: (_, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: Scaffold(body: child),
  );
}

/// 造一个源分组
LiveGroup _group(String provider, String name, List<LiveChannel> channels) =>
    LiveGroup(provider: provider, providerName: name, channels: channels);

/// 造一个频道
LiveChannel _ch(String id, String name, {String? group}) =>
    LiveChannel(id: id, name: name, group: group);

/// 造一条平铺项（与 `_flatChannels` 同形）
LiveFlatEntry _entry(LiveChannel c, String provider, String tag) =>
    (channel: c, tag: tag, provider: provider);

/// ★ 点**筛选 chip**（不是频道行尾的 tag）
///
/// # 为什么不能直接 `t.tap(find.text('甲源'))`
/// ```text
/// 源名在**两处**出现：源筛选 chip + 频道行尾的来源 tag
/// ⇒ `find.text('甲源')` 会命中多个（1 chip + N 行 tag）⇒ `tap()` 报歧义。
/// ★ 所以生产代码给 chip 挂了稳定 `Key`（`sourceFilterChipKey`）——
///   本 helper 按 key 精确点 chip 本身，不"碰巧点到第一个同名文本"。
/// ```
Future<void> tapSource(WidgetTester t, String? provider) async {
  await t.tap(find.byKey(sourceFilterChipKey(provider)));
  await t.pumpAndSettle();
}

/// 点分类筛选 chip（按稳定 key —— 同理，分类名也可能与别处重名）
Future<void> tapGroup(WidgetTester t, String? group) async {
  await t.tap(find.byKey(groupFilterChipKey(group)));
  await t.pumpAndSettle();
}

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  夹具：两个源，各带分类
  // ═══════════════════════════════════════════════════════════════════
  //
  // ```text
  // 源 A（甲源）
  //   分类「新闻」：a-news-1 / a-news-2
  //   分类「影视」：a-movie-1
  // 源 B（乙源）
  //   分类「新闻」：b-news-1
  //   分类「体育」：b-sport-1
  // ⇒ 组合"甲源 ∩ 新闻" = 只有 a-news-1 / a-news-2（**能区分**源筛选是否生效）
  //   组合"甲源 ∩ 体育" = 空 ⇒ 用来看空态
  // ```
  final chA1 = _ch('a-news-1', '甲源新闻一', group: '新闻');
  final chA2 = _ch('a-news-2', '甲源新闻二', group: '新闻');
  final chA3 = _ch('a-movie-1', '甲源影视一', group: '影视');
  final chB1 = _ch('b-news-1', '乙源新闻一', group: '新闻');
  final chB2 = _ch('b-sport-1', '乙源体育一', group: '体育');

  final providers = [
    _group('jia', '甲源', [chA1, chA2, chA3]),
    _group('yi', '乙源', [chB1, chB2]),
  ];
  final channels = [
    _entry(chA1, 'jia', '甲源'),
    _entry(chA2, 'jia', '甲源'),
    _entry(chA3, 'jia', '甲源'),
    _entry(chB1, 'yi', '乙源'),
    _entry(chB2, 'yi', '乙源'),
  ];

  Widget build({Set<String>? enabled}) => _host(LiveChannelList(
        providers: providers,
        enabledProviders: enabled ?? {'jia', 'yi'},
        channels: channels,
        selectedId: null,
        onPickChannel: (_) {},
      ));

  // ═══════════════════════════════════════════════════════════════════
  //  ① 按源筛选
  // ═══════════════════════════════════════════════════════════════════
  group('① 按源筛选', () {
    testWidgets('★ 默认「全部源」⇒ 5 个频道全在', (t) async {
      await t.pumpWidget(build());
      await t.pumpAndSettle();
      for (final c in [chA1, chA2, chA3, chB1, chB2]) {
        expect(find.text(c.name), findsOneWidget, reason: '默认应看到全部频道');
      }
    });

    testWidgets('★★ 点「甲源」⇒ 只剩甲源的频道（乙源全部消失）', (t) async {
      await t.pumpWidget(build());
      await t.pumpAndSettle();

      await tapSource(t, 'jia');

      // ★ 真的渲染：甲源的 3 个在
      expect(find.text('甲源新闻一'), findsOneWidget);
      expect(find.text('甲源新闻二'), findsOneWidget);
      expect(find.text('甲源影视一'), findsOneWidget);
      // ★ 乙源的 2 个**真的没渲染**（不是读源码，是查 widget 树）
      expect(find.text('乙源新闻一'), findsNothing,
          reason: '★ 按源筛选后，别的源的频道不该在树里');
      expect(find.text('乙源体育一'), findsNothing,
          reason: '★ 同上 —— 这是"筛选真的生效"的判据');
    });

    testWidgets('★ 点「全部源」⇒ 回到全部', (t) async {
      await t.pumpWidget(build());
      await t.pumpAndSettle();
      await tapSource(t, 'jia');
      expect(find.text('乙源新闻一'), findsNothing);

      await tapSource(t, null);
      expect(find.text('乙源新闻一'), findsOneWidget, reason: '回到全部源后应重新出现');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 按分类筛选
  // ═══════════════════════════════════════════════════════════════════
  group('② 按分类筛选', () {
    testWidgets('★ 分类列表从**当前频道**动态收集（不硬编码）', (t) async {
      await t.pumpWidget(build());
      await t.pumpAndSettle();
      // 夹具里出现的分类（去重）：新闻 / 影视 / 体育
      expect(find.text('新闻'), findsOneWidget, reason: '分类 chip 动态出现');
      expect(find.text('影视'), findsOneWidget);
      expect(find.text('体育'), findsOneWidget);
      // 夹具里**没有**的分类不许凭空出现（用一个绝不会被硬编码的假分类名）
      expect(find.text('不存在的分类'), findsNothing,
          reason: '★ 分类只从频道数据收集 ⇒ 没出现过的分类名不该凭空出现');
    });

    testWidgets('★★ 点「新闻」⇒ 只剩新闻分类的频道（跨源）', (t) async {
      await t.pumpWidget(build());
      await t.pumpAndSettle();

      await tapGroup(t, '新闻');

      expect(find.text('甲源新闻一'), findsOneWidget);
      expect(find.text('甲源新闻二'), findsOneWidget);
      expect(find.text('乙源新闻一'), findsOneWidget,
          reason: '新闻分类跨两个源 ⇒ 两个源的这个分类都在');
      expect(find.text('甲源影视一'), findsNothing, reason: '影视分类应被筛掉');
      expect(find.text('乙源体育一'), findsNothing, reason: '体育分类应被筛掉');
    });

    testWidgets('★ 点「全部分类」⇒ 回到全部', (t) async {
      await t.pumpWidget(build());
      await t.pumpAndSettle();
      await tapGroup(t, '新闻');
      expect(find.text('甲源影视一'), findsNothing);

      await tapGroup(t, null);
      expect(find.text('甲源影视一'), findsOneWidget);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 组合（源 ∩ 分类，AND）
  // ═══════════════════════════════════════════════════════════════════
  group('③ 源 ∩ 分类', () {
    testWidgets('★★ 甲源 + 新闻 ⇒ 只剩甲源的新闻（乙源新闻被 AND 掉）', (t) async {
      await t.pumpWidget(build());
      await t.pumpAndSettle();

      await tapSource(t, 'jia');
      await tapGroup(t, '新闻');

      expect(find.text('甲源新闻一'), findsOneWidget);
      expect(find.text('甲源新闻二'), findsOneWidget);
      expect(find.text('乙源新闻一'), findsNothing,
          reason: '★★ AND：既是甲源、又是新闻 —— 乙源新闻不满足源条件');
      expect(find.text('甲源影视一'), findsNothing,
          reason: '★ AND：甲源影视不满足分类条件');
    });

    testWidgets('★ 分类条是**全局词汇表**（不随源塌缩）—— 两个维度正交', (t) async {
      await t.pumpWidget(build());
      await t.pumpAndSettle();
      // 全部源下：新闻 / 影视 / 体育
      expect(find.text('体育'), findsOneWidget);

      await tapSource(t, 'jia');
      // ★ 甲源自己没有「体育」分类，但分类条**仍列出它** ——
      //   否则"源 ∩ 分类"永远选不出空集，AND 无意义。
      expect(find.text('体育'), findsOneWidget,
          reason: '★ 分类从**全部可见频道**收集（全局词汇表）⇒ 不随源塌缩');
      expect(find.text('新闻'), findsOneWidget);
      expect(find.text('影视'), findsOneWidget);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ 空态
  // ═══════════════════════════════════════════════════════════════════
  group('④ 筛选为空的明确空态', () {
    testWidgets('★★ 甲源 + 体育 ⇒ 空集 ⇒ 有**明确空态文案**（不许一片空白）', (t) async {
      /*
       * 夹具：甲源 = {新闻, 影视}，乙源 = {新闻, 体育}
       * ⇒ 甲源 ∩ 体育 = **空**（甲源没有体育分类）
       * ★ 两个筛选各自**都有效**（甲源在源列表里、体育在分类列表里）
       *   ⇒ 不会被 `didUpdateWidget` 清掉 ⇒ 空态**真实可达**。
       */
      await t.pumpWidget(build());
      await t.pumpAndSettle();

      await tapSource(t, 'jia');
      await tapGroup(t, '体育');

      // 甲源的频道全被分类筛掉
      expect(find.text('甲源新闻一'), findsNothing);
      expect(find.text('甲源影视一'), findsNothing);
      expect(find.text('乙源体育一'), findsNothing);

      // ★ 必须有**明确文案**（否则用户以为坏了）
      expect(
        find.textContaining('这个筛选下没有频道'),
        findsOneWidget,
        reason: '★★ 筛选为空必须有明确空态文案 —— 不许只画一片空白'
            '（用户会以为源坏了/功能坏了）',
      );
      // ★ 文案里要**告诉怎么退出**（点「全部源」/「全部分类」）
      expect(
        find.textContaining('全部源'),
        findsWidgets,
        reason: '★ 空态应引导用户怎么回到全部（否则他只会以为坏了）',
      );
    });

    testWidgets('★★ 频道全被外部剔除（未筛选）⇒ 显示原"没有可播放画面"空态', (t) async {
      // 模拟"可用性探测把频道全删了"：channels 为空、也没有筛选
      await t.pumpWidget(_host(LiveChannelList(
        providers: const [],
        enabledProviders: const {},
        channels: const [],
        selectedId: null,
        onPickChannel: (_) {},
      )));
      await t.pumpAndSettle();
      expect(
        find.textContaining('没有可播放的画面'),
        findsOneWidget,
        reason: '★ 空列表必须有**明确文案**，不许一片空白（用户会以为坏了）',
      );
      // ★ 未筛选时**不该**说"这个筛选下没有频道"（那是误导）
      expect(
        find.textContaining('这个筛选下没有频道'),
        findsNothing,
        reason: '★ 没有筛选生效时，空态不应归咎于"筛选"',
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑤ ★★ 反向守卫：筛选**不得**改 provider 启用状态（task-53 那个坑）
  // ═══════════════════════════════════════════════════════════════════
  group('⑤ ★★ 反向守卫：筛选不碰启用状态', () {
    testWidgets('★★ 点源 chip 不会调用 SourinApi.setProviderEnabled', (t) async {
      /*
       * 这是本文件**最重要**的一条 —— task-53 用户否定的正是
       * "点 tag 就去启停源"那个形态。筛选与启停**必须**是两件事。
       *
       * 做法：装一个探针，统计 `setProviderEnabled` 被调次数。
       * ⚠️ 它走 FFI（真实实现会抛）—— 但**只要筛选不调它**，就永远不会走到。
       *   所以「没有异常 + 计数为 0」双重证明"筛选没碰它"。
       */
      var enableCalls = 0;
      final orig = SourinApi.debugProviderEnabledHook;
      SourinApi.debugProviderEnabledHook = (id, enabled) async {
        enableCalls++;
        return true;
      };
      addTearDown(() => SourinApi.debugProviderEnabledHook = orig);

      await t.pumpWidget(build());
      await t.pumpAndSettle();

      // 点一圈：源、分类、全部 —— 全方位试
      await tapSource(t, 'jia');
      await tapGroup(t, '新闻');
      await tapSource(t, null);
      await tapGroup(t, null);

      expect(
        enableCalls,
        0,
        reason: '★★★ 筛选**绝不能**调用 setProviderEnabled —— '
            '那正是 task-53 用户否定的"点 tag 启停源"形态。'
            '筛选=只改视图；启停=改配置（只在设置页）。',
      );
    });

    testWidgets('★ 筛选只改视图：enabledProviders 集合原样不变', (t) async {
      // 传入的启用集合是 {'jia','yi'}；点筛选后组件**不该**要求外部改它。
      // 做法：给一个**只读** view 传入，并在 rebuild 时校验仍是那两个。
      const enabled = {'jia', 'yi'};
      await t.pumpWidget(_host(LiveChannelList(
        providers: providers,
        enabledProviders: enabled,
        channels: channels,
        selectedId: null,
        onPickChannel: (_) {},
      )));
      await t.pumpAndSettle();

      await tapSource(t, 'jia');
      await tapGroup(t, '新闻');

      // 传进去的集合对象内容不变
      expect(enabled, {'jia', 'yi'},
          reason: '★ 筛选是**只读**视图操作，不该改动传入的启用集合');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑥ 切筛选**不停播放**（用户要求"保留播放"）
  // ═══════════════════════════════════════════════════════════════════
  group('⑥ 切筛选保留播放', () {
    testWidgets('★★ 切筛选不触发 onPickChannel（也就不会切台/停播）', (t) async {
      /*
       * 用户要求：切源/切分类不要停掉正在播的频道。
       * ★ 本组件**只**通过 `onPickChannel` 通知"用户点了某一频道" ——
       *   筛选点击**绝不**走它 ⇒ 播放状态不受影响。
       * 断言：点一圈筛选后，`onPickChannel` **一次都没被调**。
       */
      var picks = 0;
      await t.pumpWidget(_host(LiveChannelList(
        providers: providers,
        enabledProviders: {'jia', 'yi'},
        channels: channels,
        // 假装乙源第一个频道正在播
        selectedId: 'b-news-1',
        onPickChannel: (_) => picks++,
      )));
      await t.pumpAndSettle();

      await tapSource(t, 'jia'); // 筛到甲源 ⇒ 正在播的乙源频道被"筛掉"
      await tapGroup(t, '新闻');
      await tapSource(t, null);
      await tapGroup(t, null);

      expect(picks, 0,
          reason: '★★ 筛选**不得**触发切台回调 —— 否则正在播的频道会被停掉。'
              '（即使当前频道被筛掉，也只是**不显示**，不改变播放。）');
    });

    testWidgets('★ 正在播的频道被筛掉时只是不渲染，selectedId 语义不变', (t) async {
      // 选中 b-news-1（乙源）→ 筛到甲源 ⇒ 它不在列表里，但组件**没有**
      // 任何"停播"的概念（停不停由 LivePage 决定）——
      // 这里断言组件**不会**把 selectedId 改掉/通知外部。
      var picks = 0;
      await t.pumpWidget(_host(LiveChannelList(
        providers: providers,
        enabledProviders: {'jia', 'yi'},
        channels: channels,
        selectedId: 'b-news-1',
        onPickChannel: (_) => picks++,
      )));
      await t.pumpAndSettle();

      await tapSource(t, 'jia');
      await t.pumpAndSettle();

      expect(find.text('乙源新闻一'), findsNothing, reason: '乙源频道被筛掉（不显示）');
      expect(picks, 0, reason: '★ 组件不因"当前频道被筛掉"而改选/停播');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑦ 静态契约（剥注释后）—— 防将来有人把筛选改回"开关"
  // ═══════════════════════════════════════════════════════════════════
  group('⑦ 静态契约', () {
    late String code;
    setUpAll(() {
      code = stripComments(File('lib/ui/live_page.dart').readAsStringSync());
    });

    test('★★ LiveChannelList 及其 State 的**代码里**不出现 setProviderEnabled', () {
      /*
       * ★ 反向守卫的**静态**那一半：
       * `LiveChannelList` / `LiveChannelListState` 里**不该**有任何对
       * `setProviderEnabled` 的调用（连标识符都不该出现）—— 机器可验。
       * ⚠️ 剥注释后再查（注释里会**解释**这件事，提到标识符名不算）。
       * ⚠️ 范围必须**同时覆盖 State 类** —— 点击处理（`_pickSource`）在
       *    `LiveChannelListState` 里，只扫 widget 类会漏掉真正的注入点
       *    （实测：只扫 `class LiveChannelList` 时，往 `_pickSource` 里加
       *     `setProviderEnabled` **不会**变红 —— 那是个假绿）。
       */
      final start = code.indexOf('class LiveChannelList');
      expect(start, greaterThan(0), reason: '前置：类必须存在');
      // ★ 取到 `_FilterChip` 之前（即覆盖 LiveChannelList + LiveChannelListState）
      final end = code.indexOf('class _FilterChip');
      expect(end, greaterThan(start), reason: '前置：范围终点必须存在');
      final body = code.substring(start, end);
      // ★ 阳性对照：这段范围里**确实**有筛选实现（否则"没匹配到"可能只是剥空了）
      expect(body.contains('_pickSource'), isTrue,
          reason: '★ 阳性对照：范围内要有筛选点击处理（否则范围取错了 ⇒ 假绿）');
      expect(
        body.contains('setProviderEnabled'),
        isFalse,
        reason: '★★ LiveChannelList(+State) 内不许出现 setProviderEnabled —— '
            '筛选只改视图（_sourceFilter/_groupFilter），启停只在设置页。'
            '若它出现 ⇒ 有人把 task-53 那个被否定的形态加回来了。',
      );
    });

    test('★ 筛选状态是纯内存字段（不落盘、不调 API）', () {
      expect(code.contains('String? _sourceFilter'), isTrue,
          reason: '源筛选状态应在组件内自持');
      expect(code.contains('String? _groupFilter'), isTrue,
          reason: '分类筛选状态应在组件内自持');
    });

    test('★ 分类从频道动态收集（不硬编码分类名）', () {
      // `_groups` getter 必须从 `e.channel.group` 收集
      expect(code.contains('e.channel.group'), isTrue,
          reason: '★ 分类必须从 `LiveChannel.group` 动态收集');
    });
  });
}
