// task-66 任务 B-3：**弹幕信息面板玻璃化**门禁
//
// # 钉什么
// ```text
// ① 玻璃材质真的在（GlassContainer 在树上，且包住面板内容）
// ② 四个信息形态一个不少（收起 / 展开 / 失败 / season 兜底）
// ③ 透明度确实降了（不再是 90% 不透明的实色）
//    ★ 这条是"玻璃化"的**实质判据**，不是外观偏好：
//      90% 不透明下玻璃与实色在视觉上无法区分，材质等于没做。
// ```
//
// # 故障注入（两条，都已实测）
// ```text
// ① 去掉 GlassContainer  ⇒ 第①组红
// ② 把底色调回 0xE6（90%）⇒ 第③组红
// ```
//
// ══════════════════════════════════════════════════════════════════════
// ★★★ 为什么第③组（透明度数值）比第①组（组件存在）更重要
// ══════════════════════════════════════════════════════════════════════
// ```text
// 「只断言组件存在」是**深度太浅**的假绿：
//   如果里面还盖着 90% 实色，GlassContainer 再多也看不出来，
//   但"组件在树上"这条断言照样绿。
//
// ⇒ 必须**同时**断言它真的透得出来（alpha < 0xE6）。
// ⇒ 这是"有没有"与"有没有用"的区别。
// ```
// 与另一类问题（断言**范围**太大，比如量总间隙时混入别人的 padding）
// 正好相反：那是范围太宽，这是深度太浅。
//
// ## 渲染环境限制
// ```text
// 只在 `flutter_tester` 软件渲染中验证，**未经真窗口验证**（本机环境限制）。
// 玻璃的可见性还**取决于背景**：纯色底上玻璃与实色几乎逐像素一致
// ⇒ 所以本文件判"结构 + 数值"，不判像素。
// ```
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassContainer;
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/ui/widgets/danmaku_info_panel.dart';

DanmakuInfoData _loaded() => const DanmakuInfoData(
      source: DanmakuFeedKind.bili,
      match: DanmakuPairKind.autoSearch,
      count: 1200,
      title: '鬼灭之刃 柱训练篇',
      cid: 1602741036,
      enabled: true,
    );

/// 一路失败（排查场景的核心：失败原因必须读得出来）
DanmakuInfoData _failed() => DanmakuInfoData(
      source: DanmakuFeedKind.bili,
      match: DanmakuPairKind.autoSearch,
      count: 0,
      title: '',
      cid: 0,
      enabled: true,
      aggregate: <DanmakuAggregateFeed>[
        DanmakuAggregateFeed(
          label: 'dan-api',
          count: 0,
          loaded: false,
          error: '连接被拒绝',
        ),
      ],
    );

Widget _host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        backgroundColor: const Color(0xFF1A2030),
        body: Align(alignment: Alignment.topRight, child: child),
      ),
    );

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ① 玻璃材质
  // ═══════════════════════════════════════════════════════════════════
  group('① 玻璃材质', () {
    testWidgets('★★★ 展开态有 GlassContainer', (t) async {
      await t.pumpWidget(_host(
        DanmakuInfoPanel(data: _loaded(), initiallyExpanded: true),
      ));
      await t.pumpAndSettle();

      expect(find.byType(GlassContainer), findsWidgets,
          reason: '★★★ Owner 要玻璃材质 —— 信息面板必须真的玻璃化');
    });

    testWidgets('★★ 收起态也有玻璃（两种形态都要）', (t) async {
      await t.pumpWidget(_host(DanmakuInfoPanel(data: _loaded())));
      await t.pumpAndSettle();

      expect(find.byType(GlassContainer), findsWidgets,
          reason: '★★ 收起态是用户最常看到的形态（默认收起）—— 不能漏');
    });

    testWidgets('★★ 玻璃**包住**内容（不是摆旁边）', (t) async {
      await t.pumpWidget(_host(
        DanmakuInfoPanel(data: _loaded(), initiallyExpanded: true),
      ));
      await t.pumpAndSettle();

      final inner = find.descendant(
        of: find.byType(GlassContainer),
        matching: find.text('已载入'),
      );
      expect(inner, findsOneWidget,
          reason: '★★ 内容必须在玻璃**内部**');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 信息形态一个不少（玻璃化不许弄丢事实）
  // ═══════════════════════════════════════════════════════════════════
  group('② 信息形态保留', () {
    testWidgets('★★★ 展开态：来源 / 条数 / 匹配 都在', (t) async {
      await t.pumpWidget(_host(
        DanmakuInfoPanel(data: _loaded(), initiallyExpanded: true),
      ));
      await t.pumpAndSettle();

      expect(find.text('已载入'), findsOneWidget, reason: '② 条数标签');
      expect(find.textContaining('1200'), findsWidgets, reason: '② 条数真值');
      expect(find.text('匹配'), findsOneWidget, reason: '③ 匹配标签');
      expect(find.textContaining('1602741036'), findsOneWidget, reason: 'cid');
    });

    testWidgets('★★★ 失败原因仍然读得出来（这面板存在的理由）', (t) async {
      await t.pumpWidget(_host(
        DanmakuInfoPanel(data: _failed(), initiallyExpanded: true),
      ));
      await t.pumpAndSettle();

      /*
       * ★ 这条是 Owner 原话的直接要求：
       *   「在播放页面右侧显示加载了哪些弹幕,方便排查问题」
       * ⇒ 失败原因原文必须照透，玻璃化不许把它吃掉。
       */
      expect(find.textContaining('连接被拒绝'), findsOneWidget,
          reason: '★★★ 失败原因必须显示 —— 这是这个面板存在的理由');
    });

    testWidgets('★★ 收起态只显示条数（不泄漏详情）', (t) async {
      await t.pumpWidget(_host(DanmakuInfoPanel(data: _loaded())));
      await t.pumpAndSettle();

      expect(find.textContaining('1200'), findsOneWidget);
      expect(find.text('已载入'), findsNothing,
          reason: '★ 收起态不该有"已载入"那一行');
    });

    testWidgets('★★ 点一下能展开（玻璃没挡住点击）', (t) async {
      await t.pumpWidget(_host(DanmakuInfoPanel(data: _loaded())));
      await t.pumpAndSettle();

      /*
       * ⚠️ 这里**不能**用 `find.byType(InkWell)` —— 本面板 2026-10-17 起
       *    改用 `AppInkWell`（去 Material 自绘高亮），树上没有框架 InkWell。
       *    `t139:70` 那条断言至今仍写着 InkWell，是**既存缺陷**
       *    （在 HEAD 上就红，与玻璃化无关，已单独报给 Lead）。
       *    本门禁按**行为**点（点面板本身），不依赖具体点击组件：
       *    这样换任何点击实现都不会假红。
       */
      await t.tap(find.byType(DanmakuInfoPanel));
      await t.pumpAndSettle();

      expect(find.text('已载入'), findsOneWidget,
          reason: '★★ 玻璃层不该吃掉点击');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 透明度真的降了（玻璃化的实质判据）
  // ═══════════════════════════════════════════════════════════════════
  group('③ 不再是 90% 不透明实色', () {
    testWidgets('★★★ 底色 alpha 明显低于改前的 0xE6', (t) async {
      await t.pumpWidget(_host(
        DanmakuInfoPanel(data: _loaded(), initiallyExpanded: true),
      ));
      await t.pumpAndSettle();

      /*
       * # 为什么这条是实质判据
       * ```text
       * 改前 `_scrim = Color(0xE6101216)` —— alpha = 0xE6 = 230/255 ≈ 90%。
       * 那个不透明度下，**玻璃和实色在视觉上无法区分**（实测截图几乎逐像素相同）。
       * ⇒ 只断言"有 GlassContainer"是不够的：
       *   如果里面还盖着 90% 的实色，玻璃就是个摆设（假绿）。
       * ⇒ 必须同时断言"透得出来"。
       * ```
       * 判据：找面板里那层 DecoratedBox 的 BoxDecoration.color.alpha
       * 必须 **< 0xE6**（严格小于，不接受相等）。
       */
      final decorations = t
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .whereType<DecoratedBox>()
          .map((w) => w.decoration)
          .whereType<BoxDecoration>()
          .where((d) => d.color != null && d.border != null)
          .toList();

      expect(decorations, isNotEmpty,
          reason: '找不到面板那层带描边的底色 —— 判据失效，需人工复核');

      final alphas = decorations.map((d) => d.color!.a).toList();
      // d.color!.a 是 0..1 的 double（Flutter 3.27+ 的 Color.a）
      final minAlpha = alphas.reduce((a, b) => a < b ? a : b);
      expect(minAlpha, lessThan(0xE6 / 255),
          reason: '★★★ 底色必须比改前的 90% 更透明 —— '
              '否则玻璃只是摆设（90% 实色下看不出任何材质）');
    });
  });
}
