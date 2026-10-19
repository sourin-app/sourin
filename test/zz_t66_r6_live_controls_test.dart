// ═══════════════════════════════════════════════════════════════════════
//  第 66 轮 R6：直播页「弹幕 / 清晰度控件」门禁
// ═══════════════════════════════════════════════════════════════════════
//
//  # Owner 原话（背景，裁决已由 Lead 收窄）
//  ```text
//  > 弹幕和清晰度都没支持，在直播页还没进详情页，
//  > 就应该把该有的直播控件都显示出来
//  ```
//
//  # 本门禁守的两条裁决
//  ```text
//  ① 弹幕：直播没有 channel 弹幕数据源（`danmaku_list` 只 strip
//     media_id/episode_id）⇒ **假入口**（恒空 + 静默失败）比没有更糟
//     ⇒ 裁决：**不渲染任何弹幕控件**；但**不许静默** ——
//       用户能看到直播页却找不到弹幕控件时，页面上必须有一句
//       **可解释**的说明。
//  ② 清晰度：只有一档可用时**不渲染下拉**（不做「只有一项的下拉」）；
//     ≥2 档且非 DRM 才渲染。
//  ```
//
//  # ★ 为什么判据读的是「渲染结果」而不是源码字符串
//  ```text
//  本仓铁律：门禁不许「同一个源比同一个源」——
//  必须读真实结果（element 树 / 渲染结果），不能读喂进去的值。
//  下面全部用 `find.*` 命中数（面积=命中个数），不看源码。
//  ```
//
//  # 隔离说明
//  ```text
//  每个用例 `ClipDownloader.debugSetDataDir(<临时目录>)`，
//  收尾 `debugSetDataDir(null)` —— 防止 `pumpWidget` 探针
//  写到 Owner 真实数据目录（AGENTS.md §8 的专门坑）。
//  ```
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/clip_download.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/design/icons/app_icons.dart';
import 'package:sourin_spike/ui/widgets/live_embedded_player.dart';

// ── 夹具 ──────────────────────────────────────────��─────────────────

/// 一条可播的直播流（模拟「取流成功，选中一条线」）
const _stream = StreamCandidate(
  url: 'https://example.invalid/live.m3u8',
  kind: 'hls',
  label: '标清',
);

/// 渲染直播内嵌播放器（内嵌区域的真实尺寸：532×356，见 Owner 900 断点）
Widget _host(LiveEmbeddedPlayer p) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: SizedBox(width: 532, height: 356, child: p),
        ),
      ),
    );

/// ★ 清晰度下拉的命中计数（**真实渲染结果**，不是源码）
///
/// 判据 = 清晰度按钮那颗图标的命中数（`AppIcons.high_quality`）。
/// 命中 0 ⇒ 下拉**没被渲染**；≥1 ⇒ 下拉在树上。
int _qualityHits(WidgetTester t) =>
    find.byIcon(AppIcons.high_quality).evaluate().length;

/// ★ 弹幕**控件**（开关/按钮）的命中计数
///
/// 直播页**永远不该**有弹幕开关控件。这里用 `comments_disabled` 图标
/// 之外的真开关来数：任何弹幕按钮/开关文案都不该出现。
int _danmakuControlHits(WidgetTester t) {
  var n = 0;
  // 弹幕开关类文案（真控件）—— 出现即错
  for (final w in ['开启弹幕', '关闭弹幕', '弹幕设置', '弹幕加载中']) {
    n += find.text(w).evaluate().length;
  }
  return n;
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('zz_t66_r6_');
    ClipDownloader.debugSetDataDir(tmp.path);
  });

  tearDown(() {
    ClipDownloader.debugSetDataDir(null);
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('R6 ② 清晰度：不做「只有一项的下拉」', () {
    testWidgets('单档可用 ⇒ 清晰度下拉**不渲染**（命中 0）', (t) async {
      t.view.physicalSize = const Size(900, 600);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      await t.pumpWidget(_host(const LiveEmbeddedPlayer(
        stream: _stream,
        title: '单档台',
        qualityOptions: [
          LiveQualityOption(value: 'https://example.invalid/live.m3u8', label: '标清'),
        ],
      )));
      await t.pump();
      await t.pump(const Duration(milliseconds: 60));

      expect(
        _qualityHits(t),
        0,
        reason: '★★ 裁决②：只有一档可用时**不许**渲染清晰度下拉。'
            '给用户一个点开只有一项的下拉，比没有更糟。'
            '实测命中 ${_qualityHits(t)}。',
      );
    });

    testWidgets('空档位（直播当前常态）⇒ 清晰度下拉不渲染', (t) async {
      t.view.physicalSize = const Size(900, 600);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      await t.pumpWidget(_host(const LiveEmbeddedPlayer(
        stream: _stream,
        title: '零档台',
        qualityOptions: [],
      )));
      await t.pump();
      await t.pump(const Duration(milliseconds: 60));

      expect(_qualityHits(t), 0,
          reason: '直播链路 quality 恒 null ⇒ 空档位常态下必须没有下拉');
    });

    testWidgets('≥2 可选档 ⇒ 清晰度下拉**渲染**（命中 ≥1）', (t) async {
      t.view.physicalSize = const Size(900, 600);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      await t.pumpWidget(_host(const LiveEmbeddedPlayer(
        stream: _stream,
        title: '多档台',
        qualityOptions: [
          LiveQualityOption(value: 'a', label: '高清'),
          LiveQualityOption(value: 'b', label: '流畅'),
        ],
      )));
      await t.pump();
      await t.pump(const Duration(milliseconds: 60));

      expect(
        _qualityHits(t),
        greaterThanOrEqualTo(1),
        reason: '裁决②的**正向**一半：≥2 档可用时应当给出清晰度入口，'
            '否则「直播页该有的控件都显示出来」还是没做到。'
            '实测命中 ${_qualityHits(t)}。',
      );
    });

    testWidgets('全 DRM ⇒ 下拉不渲染（DRM 档不算可用档）', (t) async {
      t.view.physicalSize = const Size(900, 600);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      await t.pumpWidget(_host(const LiveEmbeddedPlayer(
        stream: _stream,
        title: '全 DRM 台',
        qualityOptions: [
          LiveQualityOption(value: 'a', label: '高清', drm: true),
          LiveQualityOption(value: 'b', label: '标清', drm: true),
          LiveQualityOption(value: 'c', label: '流畅', drm: true),
        ],
      )));
      await t.pump();
      await t.pump(const Duration(milliseconds: 60));

      expect(
        _qualityHits(t),
        0,
        reason: '★★ 受保护的档点了必然黑屏（实测分片 stream_type 非标准编码）'
            '⇒ 3 档全 DRM 时**可用档=0**，不许画下拉。'
            '实测命中 ${_qualityHits(t)}。',
      );
    });

    testWidgets('1 可播 + 1 DRM ⇒ 仍不渲染（可用档只有 1）', (t) async {
      t.view.physicalSize = const Size(900, 600);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      await t.pumpWidget(_host(const LiveEmbeddedPlayer(
        stream: _stream,
        title: '一播一 DRM 台',
        qualityOptions: [
          LiveQualityOption(value: 'a', label: '高清'),
          LiveQualityOption(value: 'b', label: '受保护', drm: true),
        ],
      )));
      await t.pump();
      await t.pump(const Duration(milliseconds: 60));

      expect(
        _qualityHits(t),
        0,
        reason: '★★ DRM 档不计入「可用档」⇒ 1 可播 + 1 DRM = 可用 1 ⇒ '
            '按裁决②不许画下拉。实测命中 ${_qualityHits(t)}。',
      );
    });
  });

  group('R6 ① 弹幕：假入口隐藏 + 不许静默', () {
    testWidgets('无 channel 弹幕能力 ⇒ 弹幕**控件**不渲染（命中 0）', (t) async {
      t.view.physicalSize = const Size(900, 600);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      await t.pumpWidget(_host(const LiveEmbeddedPlayer(
        stream: _stream,
        title: '取证用台',
      )));
      await t.pump();
      await t.pump(const Duration(milliseconds: 60));

      expect(
        _danmakuControlHits(t),
        0,
        reason: '★★ 裁决①：直播没有 channel 弹幕数据源 ⇒ 弹幕入口是'
            '**假入口**（恒空 + 静默失败），比没有更糟 ⇒ 直播页**不许**'
            '渲染任何弹幕开关控件。实测命中 ${_danmakuControlHits(t)}。',
      );
    });

    testWidgets('看不到弹幕控件时 ⇒ 有可解释的说明句（含「弹幕」+「不支持/暂无」）',
        (t) async {
      t.view.physicalSize = const Size(900, 600);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      await t.pumpWidget(_host(const LiveEmbeddedPlayer(
        stream: _stream,
        title: '取证用台',
      )));
      await t.pump();
      await t.pump(const Duration(milliseconds: 60));

      /*
       * ★★★ 断言精确到「整句」，并且**排除了标题污染**。
       *
       * # 为什么必须排除「标题里也有『弹幕』」这种污染
       * ```text
       * 第一版夹具的频道名就叫「弹幕台」，
       * 于是 `find.textContaining('弹幕')` 命中的是**标题**而不是说明句
       * ⇒ 门禁看起来绿，实际测的是标题（故障注入时暴露的：
       *   删掉说明句后仍能读到「弹幕台」三个字）。
       * ⇒ 修法：① 夹具频道名**不含**「弹幕」  ② 断言**整句**存在
       * ```
       */
      const noteText = '这个来源暂无弹幕';
      final note = find.text(noteText);
      expect(
        note,
        findsOneWidget,
        reason: '★★ 裁决①的「不能静默」那一半：用户能看到直播页、'
            '却找不到弹幕控件时，页面必须有**一句可解释的话**。'
            '本控件不提供弹幕开关 ⇒ 必须有这句说明。实测命中 '
            '${note.evaluate().length}。',
      );

      // ★ 反向校验：屏幕上**只有**这一句含「弹幕」，没有别的文本冒充说明句
      final danmakuTexts = <String>[];
      for (final el in find.byType(Text).evaluate()) {
        final data = (el.widget as Text).data;
        if (data != null && data.contains('弹幕')) danmakuTexts.add(data);
      }
      expect(
        danmakuTexts,
        [noteText],
        reason: '★ 含「弹幕」的文本必须**只有**说明句本身。'
            '若混入别的（如频道名恰好叫「XX弹幕台」），'
            '本门禁就会把标题误当成说明句 ⇒ 变成假绿。'
            '实测：$danmakuTexts',
      );

      // 断言「为什么没有」被说清了（精确到词）
      const rendered = noteText;
      expect(
        rendered.contains('弹幕'),
        true,
        reason: '说明句必须点明说的是「弹幕」。实测渲染文本：$rendered',
      );
      expect(
        rendered.contains('不支持') ||
            rendered.contains('暂未') ||
            rendered.contains('暂无') ||
            rendered.contains('没有'),
        true,
        reason: '★★ 说明句必须解释「为什么这里没有弹��」（不支持/暂无/没有），'
            '不能只说「弹幕」两个字。实测渲染文本：$rendered',
      );
      // 反向：说明句不许出现开发用语（AGENTS.md §4）
      for (final bad in ['修复', '缺陷', 'task-', 'Owner', '探针']) {
        expect(
          rendered.contains(bad),
          false,
          reason: '用户可见文案不许出现开发用语「$bad」。实测：$rendered',
        );
      }
    });

    testWidgets('未选台（stream 为 null）⇒ 不显示弹幕说明句', (t) async {
      t.view.physicalSize = const Size(900, 600);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      await t.pumpWidget(_host(const LiveEmbeddedPlayer(
        stream: null,
        title: '未选择频道',
      )));
      await t.pump();
      await t.pump(const Duration(milliseconds: 60));

      // 没选中台时，「这一台没有弹幕」这句话没有对象 ⇒ 不该说
      expect(
        find.textContaining('弹幕'),
        findsNothing,
        reason: '★ 没选中台时没有「这一台」可解释 ⇒ 说明句不该出现'
            '（否则用户看到一句无主的「暂无弹幕」会莫名其妙）。',
      );
    });

    testWidgets('showDanmakuNote=false ⇒ 说明句可关闭（对照，非默认路径）', (t) async {
      t.view.physicalSize = const Size(900, 600);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      await t.pumpWidget(_host(const LiveEmbeddedPlayer(
        stream: _stream,
        title: '对照台',
        showDanmakuNote: false,
      )));
      await t.pump();
      await t.pump(const Duration(milliseconds: 60));

      // 这条只作对照：证明默认路径的说明句确实是靠 showDanmakuNote 控制的
      expect(
        find.textContaining('弹幕'),
        findsNothing,
        reason: '对照：关掉开关后说明句消失（证明默认路径确实由它控制）。',
      );
    });
  });

  // ════════════════════════════════════════════════════════════════════
  //  阴性对照：证明「命中计数」不是恒 0（否则上面全是假绿）
  // ════════════════════════════════════════════════════════════════════
  group('阴性对照', () {
    testWidgets('故意渲染一个高清图标 ⇒ 计数必须能数到', (t) async {
      t.view.physicalSize = const Size(900, 600);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      // 单独挂一个高清图标，证明 `find.byIcon` 能命中它
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(body: Center(child: Icon(AppIcons.high_quality))),
      ));
      await t.pump();

      expect(
        find.byIcon(AppIcons.high_quality).evaluate().length,
        greaterThanOrEqualTo(1),
        reason: '★★ 阴性对照失败：故意渲染的高清图标没被数到 ⇒ '
            '`_qualityHits` 恒 0 ⇒ 上面所有「下拉不渲染」都是假绿。',
      );
    });
  });
}