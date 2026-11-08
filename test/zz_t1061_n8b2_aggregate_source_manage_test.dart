// ═══════════════════════════════════════════════════════════════════════
//  t1061：N8b-2 聚合源管理面板（链接可改 / 测试连通 / 立即更新）
// ═══════════════════════════════════════════════════════════════════════
//
// # 守什么
// ```text
// ① 三态判据（纯函数）：null ⇒ noLink / !ok ⇒ failed(带原因) / ok ⇒ ok
//    ★ 核心：**失败绝不显示成"能用"**（本功能唯一不能犯的错）
// ② 阴性对照：noLink ≠ failed（"没有链接"与"连不上"是两件事，
//    布尔会把它们挤成一件）
// ③ 归组：**按订阅链接**归组（命令层按链接去重 ⇒ 一行 = 一条链接）
// ④ 三个操作**逐操作驱动真行为**：点保存 ⇒ 调用发出去了；
//    点测试 ⇒ 真发请求；点更新 ⇒ 真更新；且**调用参数正确**
// ⑤ 阴性对照：没有链接时「测试连通」必须**禁用**（不许假入口）
// ⑥ 「名字可改」缺口：如实说明存在，且**没有**假入口
// ```
//
// # 为什么三个操作必须"逐操作驱动"
// ```text
// 断言"按钮存在"是伪判据 —— 它抓不到"点了没接上"（本轮缺陷的形态正是
// 「Rust 说了、Dart 没接」）。所以每个操作都注入替身、**真点按钮**、
// 断言替身收到的参数。
// ```
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;

import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings/tvbox_aggregate_page.dart';
import 'package:sourin_spike/ui/widgets/tvbox_source_panel.dart';

TvboxUpdateItem item({
  bool ok = true,
  String? error,
  bool multiRepo = false,
  int convertible = 0,
  int added = 0,
  int changed = 0,
}) => TvboxUpdateItem(
  sourceUrl: 'https://example.com/tvbox.json',
  ids: const <String>['sub1'],
  ok: ok,
  error: error,
  multiRepo: multiRepo,
  remoteConvertible: convertible,
  added: List<TvboxRemoteSite>.generate(added, (i) => TvboxRemoteSite()),
  changed: List<TvboxSiteChange>.generate(changed, (i) => TvboxSiteChange()),
);

TvboxSourceInfo info(String id, String? url) =>
    TvboxSourceInfo(id: id, name: id, api: 'csp_X', sourceUrl: url);

TvboxAggregateSite site(String id, {String name = ''}) => TvboxAggregateSite(
  id: id,
  name: name.isEmpty ? id : name,
  api: 'csp_X',
  kindTag: 'csp',
  implemented: true,
);

Widget host(Widget child) => MaterialApp(
  theme: AppTheme.themeFor(Brightness.dark),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  group('① 三态判据（纯函数）', () {
    test('★★★ null ⇒ noLink（"没链接"不是"坏掉了"）', () {
      final r = tvboxProbeOf(null);
      expect(
        r.state,
        TvboxProbeState.noLink,
        reason:
            '★★★ 没有任何检测结果 ⇒ 没有链接；'
            '注入「与 failed 合并」本条立刻红',
      );
      expect(r.unusable, isTrue, reason: '★ noLink 要用户补链接 ⇒ unusable');
    });

    test('★★★ !ok ⇒ failed 且**带后端给的原因**（不许显示成能用）', () {
      final r = tvboxProbeOf(item(ok: false, error: '连接超时'));
      expect(r.state, TvboxProbeState.failed);
      expect(
        r.text.contains('连接超时'),
        isTrue,
        reason: '★★★ 失败必须带具体原因；注入「失败也返回能用」本条红',
      );
      expect(r.unusable, isTrue);
    });

    test('★★ 后端没给原因时如实说"没给"，不编一个', () {
      final r = tvboxProbeOf(item(ok: false, error: null));
      expect(r.state, TvboxProbeState.failed);
      expect(
        r.text.contains('后端没有给出原因'),
        isTrue,
        reason: '★★ 不许编造原因（仓库既有原则：宁可不说，不说假的）',
      );
      expect(r.detail, isNull, reason: '★ 没给就是 null，不塞空串冒充有');
    });

    test('★★ multiRepo（多仓）⇒ failed，不算"能用"', () {
      final r = tvboxProbeOf(item(multiRepo: true));
      expect(r.state, TvboxProbeState.failed, reason: '★★ 多仓配置不能直接用 ⇒ 不许判成 ok');
      expect(r.unusable, isTrue);
    });

    test('★★★ ok ⇒ 能用；有变化时把变化量报出来', () {
      final r = tvboxProbeOf(item(convertible: 100));
      expect(r.state, TvboxProbeState.ok);
      expect(r.unusable, isFalse, reason: '★ 能用 ⇒ unusable 必须 false');
      expect(r.text.contains('100'), isTrue, reason: '★ 报远端可转换站点数');

      final r2 = tvboxProbeOf(item(convertible: 100, added: 3, changed: 2));
      expect(r2.state, TvboxProbeState.ok);
      expect(r2.text.contains('新增 3'), isTrue);
      expect(r2.text.contains('变更 2'), isTrue);
    });

    test('★★ 阴性对照：noLink 与 failed **不是同一态**', () {
      /*
       * 布尔化的实现会把这两态挤成一态 ⇒ 界面就**无法如实告诉用户**
       * "是没链接还是连不上"（一个要补链接、一个要重试）。
       */
      final a = tvboxProbeOf(null);
      final b = tvboxProbeOf(item(ok: false, error: 'x'));
      expect(
        a.state == b.state,
        isFalse,
        reason: '★★ 注入「把 null 也判成 failed」本条立刻红',
      );
    });
  });

  group('② 归组：按订阅链接（命令层按链接去重 ⇒ 一行 = 一条链接）', () {
    test('★★★ 同链接的多个子站归成**一行**', () {
      final sites = [site('a'), site('b'), site('c')];
      final subs = {
        'a': info('a', 'https://x/1.json'),
        'b': info('b', 'https://x/1.json'),
        'c': info('c', 'https://x/1.json'),
      };
      final g = groupSitesBySourceUrl(sites, (id) => subs[id]);
      expect(g.length, 1, reason: '★★★ 一条链接 = 一行；注入「按子站铺开」⇒ 会变成 3 行，本条立刻红');
      expect(g['https://x/1.json']!.length, 3);
    });

    test('★★ 不同链接归不同行；无链接的自成一组（null 键）', () {
      final sites = [site('a'), site('b'), site('c')];
      final subs = {
        'a': info('a', 'https://x/1.json'),
        'b': info('b', 'https://x/2.json'),
        'c': info('c', null),
      };
      final g = groupSitesBySourceUrl(sites, (id) => subs[id]);
      expect(g.length, 3);
      expect(
        g.keys.contains(null),
        isTrue,
        reason: '★ 无链接的子站必须**仍然显示**（能补填链接），自成一组',
      );
    });

    test('★★ 空串链接 == 无链接（不许出现两个"无链接"组）', () {
      final sites = [site('a'), site('b')];
      final subs = {'a': info('a', ''), 'b': info('b', null)};
      final g = groupSitesBySourceUrl(sites, (id) => subs[id]);
      expect(g.length, 1, reason: '★ 空串与 null 归一化（否则两个空组）');
      expect(g[null]!.length, 2);
    });

    test('★ 后端不认识这个 id ⇒ 当无链接（不崩）', () {
      final sites = [site('a')];
      final g = groupSitesBySourceUrl(sites, (id) => null);
      expect(g[null]!.length, 1);
    });
  });

  group('③ 三个操作逐操作驱动（真点按钮 + 断言参数）', () {
    testWidgets('★★★ 点「填入/保存」⇒ set 收到 (id, url)', (t) async {
      String? seenId, seenUrl;
      await t.pumpWidget(
        host(
          TvboxSourceManagePanel(
            id: 'sub1',
            name: '示例',
            sourceUrl: null,
            linkSaver: (id, url) async {
              seenId = id;
              seenUrl = url;
            },
            // 保存成功后会自动测一次 ⇒ 给个不会走网络的替身
            probeRunner: (_) async => const TvboxUpdateCheck(),
          ),
        ),
      );
      await t.pump();

      await t.enterText(
        find.byKey(const ValueKey<String>('tvbox-manage-link-input')),
        'https://example.com/tvbox.json',
      );
      await t.tap(find.byKey(const ValueKey<String>('tvbox-manage-link-save')));
      await t.pumpAndSettle();

      expect(seenId, 'sub1', reason: '★★★ id 必须逐字传给命令');
      expect(
        seenUrl,
        'https://example.com/tvbox.json',
        reason: '★★★ url 必须逐字传给命令（注入「不传 url」本条红）',
      );
    });

    testWidgets('★★★ 点「测试连通」⇒ 真发一次请求（probeRunner 被调到）', (t) async {
      var probes = 0;
      String? probedId;
      await t.pumpWidget(
        host(
          TvboxSourceManagePanel(
            id: 'sub1',
            name: '示例',
            sourceUrl: 'https://example.com/tvbox.json',
            probeRunner: (id) async {
              probes++;
              probedId = id;
              return TvboxUpdateCheck(items: [item(convertible: 42)]);
            },
          ),
        ),
      );
      await t.pump();

      await t.tap(find.byKey(const ValueKey<String>('tvbox-manage-probe')));
      await t.pumpAndSettle();

      expect(probes, 1, reason: '★★★ 必须真发一次请求；注入「不调命令」本条红');
      expect(probedId, 'sub1');
      final shown = t.widget<Text>(
        find.byKey(const ValueKey<String>('tvbox-manage-probe-result')),
      );
      expect(
        shown.data!.contains('42'),
        isTrue,
        reason: '★★ 三态结果必须上屏（42 个可转换站点）',
      );
    });

    testWidgets('★★★ 三态上屏：失败显示具体原因（不是"能用"）', (t) async {
      await t.pumpWidget(
        host(
          TvboxSourceManagePanel(
            id: 'sub1',
            name: '示例',
            sourceUrl: 'https://example.com/tvbox.json',
            probeRunner: (_) async =>
                TvboxUpdateCheck(items: [item(ok: false, error: '连接超时')]),
          ),
        ),
      );
      await t.pump();
      await t.tap(find.byKey(const ValueKey<String>('tvbox-manage-probe')));
      await t.pumpAndSettle();

      final shown = t.widget<Text>(
        find.byKey(const ValueKey<String>('tvbox-manage-probe-result')),
      );
      expect(
        shown.data!.contains('连接超时'),
        isTrue,
        reason: '★★★ 失败必须带原因上屏；注入「失败也显示能用」本条红',
      );
      expect(
        shown.data!.contains('能用'),
        isFalse,
        reason: '★★★ 失败**绝不许**显示成"能用"（本功能唯一不能犯的错）',
      );
    });

    testWidgets('★★★ 点「立即更新」⇒ update 收到 (id, applyNew, deleteMissing)', (
      t,
    ) async {
      String? seenId;
      bool? seenApplyNew, seenDeleteMissing;
      await t.pumpWidget(
        host(
          TvboxSourceManagePanel(
            id: 'sub1',
            name: '示例',
            sourceUrl: 'https://example.com/tvbox.json',
            probeRunner: (_) async =>
                TvboxUpdateCheck(items: [item(convertible: 10)]),
            updater: (id, {applyNew = true, deleteMissing = false}) async {
              seenId = id;
              seenApplyNew = applyNew;
              seenDeleteMissing = deleteMissing;
              return const TvboxSourceUpdate(updated: false, reason: '远端与本地一致');
            },
          ),
        ),
      );
      await t.pump();
      // 先测 ⇒ 「立即更新」才出现（没有连通结论时画更新按钮是假入口）
      await t.tap(find.byKey(const ValueKey<String>('tvbox-manage-probe')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey<String>('tvbox-manage-update')));
      await t.pumpAndSettle();

      expect(seenId, 'sub1', reason: '★★★ id 逐字传');
      expect(seenApplyNew, isTrue, reason: '★ 默认最保守的另一侧：新增站一起注册');
      expect(
        seenDeleteMissing,
        isFalse,
        reason: '★★★ 默认**不删**（静默删用户本地数据是不可逆伤害）',
      );
    });

    testWidgets('★★★ 阴性对照：没有链接 ⇒ 「测试连通」禁用（不画假入口）', (t) async {
      await t.pumpWidget(
        host(
          const TvboxSourceManagePanel(id: 'sub1', name: '示例', sourceUrl: null),
        ),
      );
      await t.pump();
      final btn = t.widget<ui.FilledButton>(
        find.byKey(const ValueKey<String>('tvbox-manage-probe')),
      );
      expect(
        btn.onPressed,
        isNull,
        reason: '★★★ 没链接时测试按钮必须**禁用**（点了必然报"没有找到"= 假入口）',
      );
      // 阴性对照的另一半：**不允许**出现"立即更新"（没有结论就画更新 = 假入口）
      expect(
        find.byKey(const ValueKey<String>('tvbox-manage-update')),
        findsNothing,
        reason: '★★ 还没测出"能用"就不许画更新按钮',
      );
    });

    testWidgets('★★ 还没测过 ⇒ 如实说"还没测过"，不显示成失败', (t) async {
      await t.pumpWidget(
        host(
          const TvboxSourceManagePanel(
            id: 'sub1',
            name: '示例',
            sourceUrl: 'https://example.com/tvbox.json',
          ),
        ),
      );
      await t.pump();
      final idle = t.widget<Text>(
        find.byKey(const ValueKey<String>('tvbox-manage-probe-idle')),
      );
      expect(
        idle.data!.contains('还没测过'),
        isTrue,
        reason: '★★ "没测过"与"测了失败"是两回事（不许一上来就红）',
      );
      expect(
        find.byKey(const ValueKey<String>('tvbox-manage-probe-result')),
        findsNothing,
      );
    });
  });

  group('④ 名字可改：如实说明缺口，不画假入口', () {
    testWidgets('★★★ 缺口说明存在（Rust 侧无改名命令）', (t) async {
      await t.pumpWidget(
        host(
          const TvboxSourceManagePanel(
            id: 'sub1',
            name: '示例',
            sourceUrl: 'https://example.com/tvbox.json',
          ),
        ),
      );
      await t.pump();
      final note = find.byKey(
        const ValueKey<String>('tvbox-manage-rename-note'),
      );
      expect(
        note,
        findsOneWidget,
        reason:
            '★★★ 做不了的能力必须**如实说**（"不告知"是本仓修过 4 处的缺陷）；'
            '注入「删掉说明」本条红',
      );
      expect(t.widget<Text>(note).data!.contains('改名暂未开放'), isTrue);
    });

    testWidgets('★★★ 不许有**假**改名入口（输入框/按钮都不许）', (t) async {
      await t.pumpWidget(
        host(
          const TvboxSourceManagePanel(
            id: 'sub1',
            name: '示例',
            sourceUrl: 'https://example.com/tvbox.json',
          ),
        ),
      );
      await t.pump();
      /*
       * 真改名需要 Rust 侧命令（本批没有）——
       * 画一个点了没反应的输入框比"说做不了"**更糟**。
       * 判据：面板里**只有订阅链接那一个** ui.TextField。
       * ★ 反面：加一个名字 ui.TextField ⇒ 本条红。
       */
      final fields = find.byType(ui.TextField).evaluate().length;
      expect(
        fields,
        1,
        reason:
            '★★★ 只许有「订阅链接」那一个输入框；'
            '注入「加一个名字输入框」⇒ 2 个 ⇒ 本条立刻红（那是假 UI）',
      );
    });
  });
}
