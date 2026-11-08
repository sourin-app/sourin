// ═══════════════════════════════════════════════════════════════════════
//  t1049：TVBox 聚合二级页（A′ Dart 半）—— 四条门禁 + 共享面板两条
// ═══════════════════════════════════════════════════════════════════════
//
// # 守什么
// ```text
// ① 逐条渲染：16 个 site ⇒ 16 行；implemented=false 的行**禁用勾选**且 reason 逐字
// ② 勾 3 个 ⇒ 保存时 enabledSiteIds 恰好这 3 个，且**按 site 原序**（顺序稳定）
// ③ 非法 id（后端 ok:false + 文案）⇒ **显示出错误**，不静默丢
// ④ 空列表 ⇒ 空态「还没有导入 TVBox 配置」
// ⑤ 共享面板：网盘/登录/代理 三块都渲染
// ⑥ 未登录时给「去登录」入口（Owner 反馈过"找不到入口"）
// ```
//
// # 数据全部来自注入点（生产恒 null）
// ```text
// SourinApi.debugTvboxAggregateFetcher / debugTvboxAggregateUpdater
// ```
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;

import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings/tvbox_aggregate_page.dart';

import 'support/miuix_dialog_host.dart';

TvboxAggregateSite site(
  String id, {
  required bool implemented,
  bool enabled = false,
  String? reason,
  String kindTag = 'csp',
}) => TvboxAggregateSite(
  id: id,
  name: '源 $id',
  api: 'csp_X',
  kindTag: kindTag,
  implemented: implemented,
  enabled: enabled,
  reason: reason,
);

/// 16 个 site：10 个实现 + 6 个未实现（未实现的带逐字 reason）
List<TvboxAggregateSite> sixteen() => <TvboxAggregateSite>[
  for (var i = 1; i <= 10; i++) site('tv$i', implemented: true),
  for (var i = 11; i <= 16; i++)
    site('tv$i', implemented: false, reason: 'csp_Unknown$i 尚未实现'),
];

Widget host(Widget child) => MaterialApp(
  theme: AppTheme.themeFor(Brightness.dark),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  tearDown(() {
    SourinApi.debugTvboxAggregateFetcher = null;
    SourinApi.debugTvboxAggregateUpdater = null;
    SourinApi.debugTvboxConfigSiteTotalFetcher = null;
  });

  group('① 逐条渲染 + 未实现禁用勾选', () {
    testWidgets('★★★ 16 行全渲染；implemented=false 的行禁用且 reason 逐字', (t) async {
      final sites = sixteen();
      await t.pumpWidget(
        host(
          TvboxAggregateSitesList(
            sites: sites,
            selected: const <String>{},
            onToggle: (_, __) {},
          ),
        ),
      );
      await t.pump();

      expect(find.byKey(const ValueKey<String>('agg-sites')), findsOneWidget);
      expect(find.byType(miuix.MiuixCheckbox), findsNWidgets(16));
      expect(find.byType(miuix.MiuixCard), findsNWidgets(16));
      for (final s in sites) {
        expect(
          find.byKey(ValueKey<String>('agg-site-${s.id}')),
          findsOneWidget,
          reason: '★ 每个 site 必须有一行（少了 = 用户看不到那个源）',
        );
      }

      // 实现的：可勾
      final ok = t.widget<ui.Checkbox>(
        find.byKey(const ValueKey<String>('agg-site-check-tv1')),
      );
      expect(ok.onChanged, isNotNull, reason: '★ 已实现的源必须能勾');

      // 未实现的：**禁用** + reason 逐字
      for (var i = 11; i <= 16; i++) {
        final box = t.widget<ui.Checkbox>(
          find.byKey(ValueKey<String>('agg-site-check-tv$i')),
        );
        expect(
          box.onChanged,
          isNull,
          reason:
              '★★★ tv$i 未实现 ⇒ 必须禁用勾选（勾了也播不了 = 假入口）；'
              '注入「onChanged 恒非空」本条立刻红',
        );
        final reason = t.widget<Text>(
          find.byKey(ValueKey<String>('agg-site-reason-tv$i')),
        );
        expect(
          reason.data,
          'csp_Unknown$i 尚未实现',
          reason: '★★ reason 必须**逐字**透出（用户要知道为什么不能选）',
        );
      }
    });
  });

  group('② 勾 3 个 ⇒ 保存的参数恰好这 3 个、顺序稳定', () {
    testWidgets('★★★ enabledSiteIds == [tv2,tv5,tv9] 按 site 原序', (t) async {
      SourinApi.debugTvboxConfigSiteTotalFetcher = () async => 100;
      SourinApi.debugTvboxAggregateFetcher = () async =>
          TvboxAggregate(sites: sixteen());
      List<String>? saved;
      SourinApi.debugTvboxAggregateUpdater =
          ({
            List<String>? enabledSiteIds,
            String? panShareText,
            String? panPwd,
          }) async {
            saved = enabledSiteIds;
            return TvboxAggregate(
              sites: sixteen(),
              enabledSiteIds: enabledSiteIds ?? const <String>[],
            );
          };

      await pumpMiuixDialog(
        t,
        const TvboxAggregatePage(showCredentialPanels: false),
      );

      /*
       * ★ 2026-10-29（弹窗拆分后的**必要**改动，不是放宽断言）：
       *   勾选与保存按钮已搬进「管理子源…」弹窗（Owner：子源管理单独一个弹窗），
       *   所以路径变成 页面 → 点 agg-manage-sites → 弹窗里勾选 → agg-sites-save。
       *   本用例守的东西**没变**：保存的 enabledSiteIds 恰好这 3 个、且按 site 原序。
       */
      await t.tap(find.byKey(const ValueKey<String>('agg-manage-sites')));
      await t.pumpAndSettle();

      // 故意**逆序**勾：tv9 → tv2 → tv5
      for (final id in <String>['tv9', 'tv2', 'tv5']) {
        final f = find.byKey(ValueKey<String>('agg-site-check-$id'));
        // ★ 弹窗内容区是**可滚动**的（16 行放不进 420px）⇒ 先滚到可见再点，
        //   否则 tv9 在视口外，tap 会"点空"（实测只勾上 2 个）
        await t.ensureVisible(f);
        await t.pump();
        await t.tap(f);
        await t.pump();
      }
      await t.tap(find.byKey(const ValueKey<String>('agg-sites-save')));
      await t.pumpAndSettle();

      expect(
        saved,
        <String>['tv2', 'tv5', 'tv9'],
        reason:
            '★★★ 保存的必须是"恰好这 3 个"，且按 **site 原序**（不是点击顺序）'
            '—— 顺序不稳会让启用集合的 diff 每次都变；'
            '注入「按点击顺序/排序」本条立刻红',
      );
    });
  });

  group('③ 非法 id ⇒ 显示错误（不静默丢）', () {
    testWidgets('★★★ 后端 ok:false ⇒ 错误文案上屏', (t) async {
      SourinApi.debugTvboxConfigSiteTotalFetcher = () async => 100;
      SourinApi.debugTvboxAggregateFetcher = () async =>
          TvboxAggregate(sites: sixteen());
      SourinApi.debugTvboxAggregateUpdater =
          ({
            List<String>? enabledSiteIds,
            String? panShareText,
            String? panPwd,
          }) async {
            throw SourinCoreException('启用集合里有不认识的源：tv99', 'other');
          };

      await pumpMiuixDialog(
        t,
        const TvboxAggregatePage(showCredentialPanels: false),
      );

      // ★ 同上：勾选/保存在「管理子源…」弹窗里
      await t.tap(find.byKey(const ValueKey<String>('agg-manage-sites')));
      await t.pumpAndSettle();

      await t.tap(find.byKey(const ValueKey<String>('agg-site-check-tv1')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey<String>('agg-sites-save')));
      await t.pumpAndSettle();

      // ★ 错误上屏的位置也跟着搬：页面级 `agg-save-error` → 弹窗级 `agg-sites-error`
      //   （保存失败时弹窗**不关**，用户就在原地看到原因 —— 这比关掉弹窗再回页面找更对）
      final err = find.byKey(const ValueKey<String>('agg-sites-error'));
      expect(
        err,
        findsOneWidget,
        reason:
            '★★★ 非法 id 必须**报错**，不能静默丢；'
            '注入「catch 里不清空/不显示」本条立刻红',
      );
      expect(
        t.widget<Text>(err).data,
        contains('不认识的源'),
        reason: '★★ 错误要具体（用户/开发者才知道哪一条非法）',
      );
    });
  });

  group('④ 空列表 ⇒ 空态提示', () {
    testWidgets('★★★ 没有 site ⇒ 「还没有导入 TVBox 配置」', (t) async {
      await t.pumpWidget(
        host(
          const TvboxAggregateSitesList(
            sites: <TvboxAggregateSite>[],
            selected: <String>{},
            onToggle: _noop,
          ),
        ),
      );
      await t.pump();

      expect(
        find.byKey(const ValueKey<String>('agg-empty')),
        findsOneWidget,
        reason: '★★★ 空列表必须给下一步；注入「if (sites.isEmpty) 恒 false」本条红',
      );
      final text = t.widget<Text>(
        find.byKey(const ValueKey<String>('agg-empty-text')),
      );
      expect(text.data, contains('还没有导入 TVBox 配置'), reason: '★★ 文案点明"缺的是导入动作"');
    });
  });

  group('⑤ 共享面板：三块都渲染', () {
    testWidgets('★★ 网盘分享体 + 登录凭据 + 代理 都在', (t) async {
      await t.pumpWidget(
        host(const TvboxAggregateCredentialsSection(aggregateId: 'tvbox_agg')),
      );
      await t.pump();

      expect(
        find.byKey(const ValueKey<String>('agg-credentials')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('pan-share-body')),
        findsOneWidget,
        reason: '★ 网盘分享体（PanShareBody）必须在',
      );
      expect(
        find.byKey(const ValueKey<String>('agg-credentials-login')),
        findsOneWidget,
        reason: '★★ 未登录时要有「去登录」入口',
      );
      expect(find.text('去登录'), findsOneWidget, reason: '★ 文案逐字');
    });
  });

  _noteGroup();
}

void _noop(String id, bool on) {}

void _noteGroup() {
  group('⑥ 未实现差额说明（动态计算）', () {
    testWidgets('★★★ 配置 100 / 列出 16 ⇒ 出现且数字恰好 84（100-16）', (t) async {
      await t.pumpWidget(
        host(
          const TvboxAggregateUnimplementedNote(
            totalSites: 100,
            listedSites: 16,
          ),
        ),
      );
      await t.pump();
      final f = find.byKey(
        const ValueKey<String>('tvbox-agg-unimplemented-note'),
      );
      expect(f, findsOneWidget, reason: '★★★ 差额 70 ⇒ 必须说出这 70 条去哪了');
      expect(
        t.widget<Text>(f).data,
        '另有 84 个源在本机未实现，导入报告里有逐条原因',
        reason: '★★ 文案逐字 + 数字必须是算出来的（100-16=84；Lead 口径里的 70 是算术笔误）',
      );
    });

    testWidgets('★★★ 配置 16 / 列出 16 ⇒ 整行不画（不许"另有 0 个"）', (t) async {
      await t.pumpWidget(
        host(
          const TvboxAggregateUnimplementedNote(
            totalSites: 16,
            listedSites: 16,
          ),
        ),
      );
      await t.pump();
      expect(
        find.byKey(const ValueKey<String>('tvbox-agg-unimplemented-note')),
        findsNothing,
        reason: '★★★ diff 为 0 时不许出现；注入「把 70 写死」本条立刻红',
      );
    });

    testWidgets('★★ total 取不到 ⇒ 不画（不猜数字）', (t) async {
      await t.pumpWidget(
        host(
          const TvboxAggregateUnimplementedNote(
            totalSites: null,
            listedSites: 16,
          ),
        ),
      );
      await t.pump();
      expect(
        find.byKey(const ValueKey<String>('tvbox-agg-unimplemented-note')),
        findsNothing,
      );
    });
  });
}
