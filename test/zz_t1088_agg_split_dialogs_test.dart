// ═══════════════════════════════════════════════════════════════════════
//  t1088：聚合源编辑弹窗拆分 + 备注 + 去重（2026-10-29 Owner 那三条）
// ═══════════════════════════════════════════════════════════════════════
//
// # 守什么（对应 Lead 给的四条门禁）
// ```text
// ① 「编辑链接」弹窗**只有**链接 / 备注两个输入：Checkbox 0 个、网盘凭据区不存在
// ② 「管理子源」弹窗里有子源列表（含勾选）+ 去重按钮
// ③ 点去重 ⇒ 调 `tvbox_aggregate_dedupe_sites`（注入点，**绝不真打核心**）+ 文案
// ④ 备注保存时 `note` **逐字**传下去，且回到页面上能回填显示
// ```
//
// # 为什么每条都要"注入红"的证据
// ```text
// 门禁只绿不红 = 它没在测东西。每条断言我都真删过一次对应实现，
// 把红的原始输出抄在交付说明里（见 `send_message`），不是"我觉得它会红"。
// ```
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings/tvbox_aggregate_page.dart';

TvboxAggregateSite site(
  String id, {
  String? name,
  bool implemented = true,
  bool enabled = true,
  String api = 'csp',
}) =>
    TvboxAggregateSite(
      id: id,
      name: name ?? '源 $id',
      api: api,
      kindTag: 'csp',
      implemented: implemented,
      enabled: enabled,
    );

TvboxAggregate agg({
  String note = '',
  bool solo = false,
  List<TvboxAggregateSite>? sites,
}) =>
    TvboxAggregate(
      note: note,
      solo: solo,
      sites: sites ??
          <TvboxAggregateSite>[
            site('tv1'),
            site('tv2'),
            site('tv3'),
          ],
    );

Widget host(Widget child) => MaterialApp(
      theme: AppTheme.themeFor(Brightness.dark),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  tearDown(() {
    SourinApi.debugTvboxAggregateFetcher = null;
    SourinApi.debugTvboxAggregateUpdater = null;
    SourinApi.debugTvboxAggregateDedupe = null;
    SourinApi.debugTvboxConfigSiteTotalFetcher = null;
  });

  group('① 编辑链接弹窗：只有链接 + 备注（多一样东西就红）', () {
    testWidgets('★★★ 两个输入框 / 零勾选框 / 零网盘凭据', (t) async {
      await t.pumpWidget(host(TvboxAggregateLinkDialog(
        aggregate: agg(note: '老舅专用源'),
        repId: 'tv1',
        currentLink: 'https://example.com/sub.json',
      )));
      await t.pump();

      expect(find.byKey(const ValueKey<String>('agg-link-dialog')),
          findsOneWidget);

      // 恰好两个输入：订阅链接 + 备注
      expect(find.byType(TextField), findsNWidgets(2),
          reason: '★★★ 「编辑链接」弹窗只该有 订阅链接 + 备注 两个输入；'
              '多一个输入（比如网盘分享框）本条立刻红');
      expect(find.byKey(const ValueKey<String>('agg-link-input')),
          findsOneWidget);
      final noteField = t.widget<TextField>(
          find.byKey(const ValueKey<String>('agg-note-input')));
      expect(noteField.decoration?.labelText, '备注（用于区分多个聚合源）',
          reason: '★★ 标签逐字（Owner 指定的文案）');

      // 备注回填：打开时就是当前值
      expect(noteField.controller?.text, '老舅专用源',
          reason: '★★ 回填：已有备注必须显在输入框里，不是空白重打一遍');

      // ★ 不许有子源勾选
      expect(find.byType(Checkbox), findsNothing,
          reason: '★★★ 子源勾选属于「管理子源…」弹窗；这里出现一个勾选框本条立刻红');

      // ★ 不许有网盘与凭据区（本页已把该区移除）
      expect(find.byKey(const ValueKey<String>('agg-credentials')), findsNothing,
          reason: '★★★ 「网盘与凭据」区已拆成公用配置，聚合源弹窗里必须不存在');
      expect(find.text('网盘与凭据'), findsNothing);
      expect(find.byKey(const ValueKey<String>('pan-share-body')), findsNothing,
          reason: '★★ 网盘分享体不许挂回来（挂回来 = 这一区又回到聚合源编辑里）');
      expect(find.text('登录凭据'), findsNothing);
      expect(find.text('代理'), findsNothing);
    });
  });

  group('② 管理子源弹窗：列表 + 去重按钮都在', () {
    testWidgets('★★★ agg-sites 列表 + agg-dedupe 按钮 + 管理区', (t) async {
      await t.pumpWidget(host(TvboxAggregateSitesDialog(
        aggregate: agg(),
        sourceOf: (_) => null,
        // 测试缝：不画真面板（它会打 FFI），但仍要证明"管理区在这一块里"
        panelBuilder: (id, name, url) =>
            Text('panel:$id', key: ValueKey<String>('stub-panel-$id')),
      )));
      await t.pump();

      expect(find.byKey(const ValueKey<String>('agg-sites-dialog')),
          findsOneWidget);
      expect(find.byKey(const ValueKey<String>('agg-sites')), findsOneWidget,
          reason: '★★★ 子源列表必须在这个弹窗里（搬走 = 用户找不到勾选）');
      for (final id in <String>['tv1', 'tv2', 'tv3']) {
        expect(find.byKey(ValueKey<String>('agg-site-check-$id')),
            findsOneWidget);
      }
      expect(find.byKey(const ValueKey<String>('agg-dedupe')), findsOneWidget,
          reason: '★★★ 去重按钮必须在这里；删掉它本条立刻红');
      expect(find.byKey(const ValueKey<String>('stub-panel-tv1')),
          findsOneWidget,
          reason: '★ 链接/测试/更新 那一块也跟着搬进来了（这里用 stub 证明它被渲染）');
    });
  });

  group('③ 去重：调注入点 + 文案 + 刷新列表', () {
    testWidgets('★★★ duplicates=3 ⇒ 「已停用 3 个重复子源」且重新读了配置',
        (t) async {
      var dedupeCalls = 0;
      var getCalls = 0;
      SourinApi.debugTvboxAggregateDedupe = () async {
        dedupeCalls++;
        return const TvboxDedupeResult(
          duplicates: 3,
          disabled: <String>['tv2', 'tv3', 'tv4'],
          kept: 1,
        );
      };
      SourinApi.debugTvboxAggregateFetcher = () async {
        getCalls++;
        // 去重后：只剩 tv1 还是启用的（tv2/tv3 被停用）
        return TvboxAggregate(
          sites: <TvboxAggregateSite>[
            site('tv1'),
            site('tv2', enabled: false),
            site('tv3', enabled: false),
          ],
        );
      };

      await t.pumpWidget(host(TvboxAggregateSitesDialog(
        aggregate: agg(),
        sourceOf: (_) => null,
        panelBuilder: (id, name, url) => const SizedBox.shrink(),
      )));
      await t.pump();

      // 点之前**不许**先出现结论（"没有重复子源"不能是默认值）
      expect(find.byKey(const ValueKey<String>('agg-dedupe-result')),
          findsNothing);

      await t.tap(find.byKey(const ValueKey<String>('agg-dedupe')));
      await t.pumpAndSettle();

      expect(dedupeCalls, 1, reason: '★★★ 必须真的调 dedupe（注入点计数）');
      expect(getCalls, 1, reason: '★★ 去重成功后必须重新读配置刷新列表');
      final msg = t.widget<Text>(
          find.byKey(const ValueKey<String>('agg-dedupe-result')));
      expect(msg.data, '已停用 3 个重复子源',
          reason: '★★ 文案逐字（N 来自响应字段，不是本地猜的）');

      // 刷新后 tv2 变成未勾选（停用 ≠ 删除：行还在）
      final box = t.widget<Checkbox>(
          find.byKey(const ValueKey<String>('agg-site-check-tv2')));
      expect(box.value, isFalse,
          reason: '★★ 停用的子源必须显示成未勾选，但**行不能消失**');
    });

    testWidgets('★★ duplicates=0 ⇒ 「没有重复子源」', (t) async {
      SourinApi.debugTvboxAggregateDedupe =
          () async => const TvboxDedupeResult(duplicates: 0, kept: 3);
      SourinApi.debugTvboxAggregateFetcher = () async => agg();

      await t.pumpWidget(host(TvboxAggregateSitesDialog(
        aggregate: agg(),
        sourceOf: (_) => null,
        panelBuilder: (id, name, url) => const SizedBox.shrink(),
      )));
      await t.pump();
      await t.tap(find.byKey(const ValueKey<String>('agg-dedupe')));
      await t.pumpAndSettle();

      expect(
          t.widget<Text>(find.byKey(const ValueKey<String>('agg-dedupe-result')))
              .data,
          '没有重复子源');
    });
  });

  group('④ 备注：逐字传下去 + 页面上回填显示', () {
    testWidgets('★★★ page → 编辑链接 → 输入备注 → 保存 ⇒ note 逐字 + 页面显示',
        (t) async {
      String? sentNote;
      var noteCalls = 0;
      SourinApi.debugTvboxConfigSiteTotalFetcher = () async => 3;
      SourinApi.debugTvboxAggregateFetcher = () async => agg();
      SourinApi.debugTvboxAggregateUpdater =
          ({List<String>? enabledSiteIds, String? panShareText, String? panPwd, String? note}) async {
        noteCalls++;
        sentNote = note;
        return agg(note: note ?? '');
      };

      await t.pumpWidget(host(const TvboxAggregatePage()));
      await t.pumpAndSettle();

      // 页面上两个入口
      expect(find.byKey(const ValueKey<String>('agg-edit-link')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('agg-manage-sites')),
          findsOneWidget);

      await t.tap(find.byKey(const ValueKey<String>('agg-edit-link')));
      await t.pumpAndSettle();

      await t.enterText(
          find.byKey(const ValueKey<String>('agg-note-input')), '老舅专用源');
      await t.tap(find.byKey(const ValueKey<String>('agg-link-save')));
      await t.pumpAndSettle();

      expect(noteCalls, 1, reason: '★★★ 保存必须调一次 tvbox_aggregate_set');
      expect(sentNote, '老舅专用源',
          reason: '★★★ 备注必须**逐字**传下去（多一个空格/少一个字都算错）；'
              '把 `note: _note.text.trim()` 删成本条立刻红');

      // 回填：页面头部的备注行 + 与 IdentityBlock 的 key
      final shown = t.widget<Text>(find.byKey(const ValueKey<String>('agg-note')));
      expect(shown.data, '老舅专用源',
          reason: '★★ 保存后页面必须显示备注（不是只在弹窗里能看到）');
    });

    testWidgets('★★ 备注为空 ⇒ 页面不画备注行（不出现空槽位）', (t) async {
      SourinApi.debugTvboxConfigSiteTotalFetcher = () async => 3;
      SourinApi.debugTvboxAggregateFetcher = () async => agg(note: '');

      await t.pumpWidget(host(const TvboxAggregatePage()));
      await t.pumpAndSettle();

      expect(find.byKey(const ValueKey<String>('agg-note')), findsNothing,
          reason: '★★ 空备注不画；画了就是每个源都多一行灰字');
      expect(find.byKey(const ValueKey<String>('agg-counts')), findsOneWidget);
    });
  });

  group('⑤ 页面本身不再挂网盘凭据区', () {
    testWidgets('★★★ 聚合二级页上没有「网盘与凭据」', (t) async {
      SourinApi.debugTvboxConfigSiteTotalFetcher = () async => 3;
      SourinApi.debugTvboxAggregateFetcher = () async => agg(note: 'x');

      await t.pumpWidget(host(const TvboxAggregatePage()));
      await t.pumpAndSettle();

      expect(find.byKey(const ValueKey<String>('agg-credentials')), findsNothing,
          reason: '★★★ 该区已拆成公用配置（网盘账号页）；这里挂回来本条立刻红');
      expect(find.text('网盘与凭据'), findsNothing);
      expect(find.byKey(const ValueKey<String>('pan-share-body')), findsNothing);
    });
  });

  group('⑥ solo 开关（只显示聚合源·测试用）', () {
    testWidgets('★★★ 回显来自 solo 字段（true ⇒ 开关是开）', (t) async {
      await t.pumpWidget(host(TvboxAggregateSitesDialog(
        aggregate: agg(solo: true),
        sourceOf: (_) => null,
        panelBuilder: (id, name, url) => const SizedBox.shrink(),
      )));
      await t.pump();

      final sw = t.widget<SwitchListTile>(
          find.byKey(const ValueKey<String>('agg-solo')));
      expect(sw.value, isTrue,
          reason: '★★★ 开关必须回显后端 `solo` 字段；'
              '把初值写成写死 false 本条立刻红');
      expect(find.text('只显示聚合源（测试用）'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('agg-solo-hint')), findsOneWidget,
          reason: '★ 必须有那句"子站仍参与搜索，只是列表里不显示"'
              '（solo 最容易被误解成"把子站关掉"）');
    });

    testWidgets('★★★ 点开关 ⇒ solo 传参逐字 true / false', (t) async {
      final seen = <bool?>[];
      SourinApi.debugTvboxAggregateUpdater =
          ({List<String>? enabledSiteIds, String? panShareText, String? panPwd, String? note, bool? solo}) async {
        seen.add(solo);
        return agg(solo: solo ?? false);
      };

      await t.pumpWidget(host(TvboxAggregateSitesDialog(
        aggregate: agg(solo: false),
        sourceOf: (_) => null,
        panelBuilder: (id, name, url) => const SizedBox.shrink(),
      )));
      await t.pump();

      await t.tap(find.byKey(const ValueKey<String>('agg-solo')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey<String>('agg-solo')));
      await t.pumpAndSettle();

      expect(seen, <bool?>[true, false],
          reason: '★★★ 开关必须把 solo 逐字传下去（true 再 false）；'
              '把 `solo: v` 删成 `solo: null` 或写死 true 本条立刻红');
      final sw = t.widget<SwitchListTile>(
          find.byKey(const ValueKey<String>('agg-solo')));
      expect(sw.value, isFalse, reason: '★ 回滚/回显：连点两次回到关');
    });
  });
}
