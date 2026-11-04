// ═══════════════════════════════════════════════════════════════════════
//  t1062：R2-#2 聚合源**随时可达的入口** + R2-#3 网盘扫码**如实说明**
// ═══════════════════════════════════════════════════════════════════════
//
// # 这两条都是 Owner 2026-10-27 当场实测抓出来的（原话逐字）
// ```text
// 2. 看到了,但是对于tvbox聚合源 还是不能编辑链接
// 3. 网盘账号无法登陆,点击获取二维码 报错
// ```
//
// # 本文件守什么（每条都配一个能红的机器判据）
// ```text
// ① #2 的**根因**钉死：Owner 真数据下三条入口全不可达（入口可达数 == 0）。
//    这不是"我猜的" —— `.probe/r2-n8b2-entry-recon.log` 是起真核心读真数据算出来的。
//    ⇒ 判据必须能证明"修前 0 个入口、修后 ≥1 个"，否则改了也不知道有没有用。
// ② #2 的**修法**：`SourceClassHeader` 必须真的接上 `onConfigure`（聚合源那一类），
//    且**这一类存在就一定可达**（不受 hidden / 折叠影响）。
// ③ #3 的**根因**：`panCommandMissing` 必须能认出"命令没接线"这个档，
//    且**不能**把普通失败也认成"能力缺失"（否则一次网络抖动就会把整区永久关掉）。
// ④ #3 的**修法**：点了之后本区**如实说明**，不画"点了只会报错"的假入口。
// ```
//
// # 为什么 ③ 要写负面对照
// ```text
// 本仓反复记录过"判据太松 ⇒ 恒真"（我本批在 task-6 刚复核过一例）。
// ⇒ 若 `panCommandMissing` 写成 `return true`（或 `e is Object`），
//   ④ 的"如实说明"就会**永远显示**，而门禁全绿。
//   ⇒ 所以这里必须同时钉：
//     · unsupported ⇒ true（能力缺失）
//     · network/other  ⇒ false（这次失败，入口要留着让人重试）
// ```
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings/pan_settings_page.dart';
import 'package:sourin_spike/ui/settings_page.dart';

Widget host(Widget child) => MaterialApp(
      theme: AppTheme.themeFor(Brightness.dark),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

ProviderManifest p(String id, String kind) => ProviderManifest(
      id: id,
      name: id,
      version: '1',
      kind: kind,
    );

void main() {
  tearDown(() {
    debugPanCredentialStatusFetcher = null;
    debugPanQrLoginStarter = null;
    debugPanQrLoginPoller = null;
    debugPanLogoutCaller = null;
  });

  // ───────────────────────────────────────────────────────────────
  //  ① #2 根因：Owner 真数据下入口可达数 == 0（真数据判据）
  // ───────────────────────────────────────────────────────────────
  group('① #2 根因：条目在但入口不在', () {
    test('★★★ Owner 真数据的形态：tvboxDirect == 0 + 列表非空 ⇒ 两条旧入口都不可达', () {
      /*
       * 这是**真数据的形态**（`.probe/r2-n8b2-entry-recon.log` 实测）：
       *   五分类 = {js:32, tvboxAggregate:1, other:4}，**tvboxDirect = 0**
       *   （16 个 csp 子站全 hidden，被 `visibleProviders` 先滤掉了）。
       *
       * 旧的两条入口判据分别是：
       *   SourcesEmptyState :5224      `if (!isEmpty) return SizedBox.shrink()`
       *   TvboxGroupHeader  :4407      `if (tvboxGroupCount(list) > 0)`
       * ⇒ 本用例把这两条的**输入条件**算出来，断言它们在这个形态下都不可达。
       */
      final real = <ProviderManifest>[
        p('cycani', 'js'),
        p(kTvboxAggregateId, 'tvbox'),
        p('m3ulive-x', 'm3u_live'),
      ];
      final visible = visibleProviders(real);
      expect(visible.isNotEmpty, isTrue, reason: '★ 真数据里列表非空（37 条可见）');

      // 旧入口 A：空态
      expect(visible.isEmpty, isFalse,
          reason: '★★ 列表非空 ⇒ SourcesEmptyState 零尺寸 ⇒ 入口 A 不可达');

      // 旧入口 B：TVBox 折叠组头 —— ⚠️ 它的**渲染条件不是 `tvboxGroupCount > 0`**，
      //   而是"`cls == SourceClass.tvboxDirect` 这一分类非空"（见 settings_page.dart:4402）
      //   `tvboxGroupCount` 只是它**内部**再判一次（那个数用 `kind=='tvbox'`，**含** tvbox_agg）。
      //   ★ 这个区别正是坑所在：只有 tvbox_agg 时 `tvboxGroupCount == 1`，
      //     但 tvboxDirect 分类为空 ⇒ 整个 `if` 分支不执行 ⇒ 组头照样不画。
      final tvboxDirect =
          visible.where((e) => sourceClassOf(e) == SourceClass.tvboxDirect);
      expect(tvboxDirect, isEmpty,
          reason: '★★★ 真数据里 tvboxDirect == 0（子站全 hidden）'
              '⇒ `if (cls == tvboxDirect)` 分支不执行 ⇒ 入口 B 不可达');
      expect(tvboxGroupCount(visible), greaterThan(0),
          reason: '★★ 反面对照：`tvboxGroupCount` **确实 > 0**（它数 kind==tvbox，'
              '含 tvbox_agg 那条）—— 若有人以为"count>0 就会有入口"，本条说明为什么没有：'
              '组头嵌在 tvboxDirect 分支里，外层的分类为空 ⇒ 根本没走到那个判断');

      // 但聚合源这一类**确实存在** ⇒ 展示与入口的错配正是 Owner 看到的现象
      final aggGroups =
          groupSourcesByClass(visible).where((g) => g.$1 == SourceClass.tvboxAggregate);
      expect(aggGroups, isNotEmpty,
          reason: '★★ 聚合源那一类非空 ⇒ 用户**看得见**卡片，却没有任何入口 ⇒ '
              '正是「看到了，但是…还是不能编辑链接」');
    });

    test('★★ 折叠不影响「TVBox 聚合源」这一类（入口必须与折叠无关）', () {
      final real = <ProviderManifest>[
        p(kTvboxAggregateId, 'tvbox'),
        p('t1', 'tvbox'),
      ];
      final groups = groupSourcesByClass(real);
      final agg = groups.firstWhere((g) => g.$1 == SourceClass.tvboxAggregate).$2;
      expect(agg.length, 1, reason: '★ 聚合源那一类恰好 1 个成员（只有 tvbox_agg）');
      expect(sourceClassOf(agg.first), SourceClass.tvboxAggregate);
      // 折叠只作用在 tvboxDirect 那类的**条目**上（`tvboxGroupOrder`），
      // 聚合源这一类从不经过它 ⇒ 入口恒在。
      final direct = groups.firstWhere((g) => g.$1 == SourceClass.tvboxDirect).$2;
      expect(tvboxGroupOrder(direct, expanded: false), isEmpty,
          reason: '★ 折叠确实清空了 tvboxDirect 的**条目**（对照组）');
    });
  });

  // ───────────────────────────────────────────────────────────────
  //  ② #2 修法：组头真的带 onConfigure，且点了真的进得了聚合页
  // ───────────────────────────────────────────────────────────────
  group('② #2 修法：聚合源组头有随时可达的入口', () {
    testWidgets('★★★ onConfigure 非空 ⇒ 画「配置」按钮；点击真的回调宿主', (t) async {
      var taps = 0;
      await t.pumpWidget(host(const SourceClassHeader(
        label: 'TVBox 聚合源',
        count: 1,
        onConfigure: null,
      )));
      await t.pump();
      /*
       * ⚠️ 负面对照放在最前：`onConfigure: null` 时**不许**出现「配置」。
       *    若实现写成"无条件画按钮"，下面那条就成了恒真（假绿）。
       */
      expect(find.byKey(const ValueKey<String>('source-class-configure')), findsNothing,
          reason: '★ 没给回调就不许画入口（否则是假入口）');
      expect(find.text('TVBox 聚合源（1 个源）'), findsOneWidget,
          reason: '★ 文案逐字：分类名 + 条目数');

      await t.pumpWidget(host(SourceClassHeader(
        label: 'TVBox 聚合源',
        count: 1,
        onConfigure: () => taps++,
      )));
      await t.pump();
      final btn = find.byKey(const ValueKey<String>('source-class-configure'));
      expect(btn, findsOneWidget, reason: '★★ 给了回调必须画出来');
      expect(find.text('配置'), findsOneWidget, reason: '★ 按钮文案与既有组头逐字一致（「配置」）');
      await t.tap(btn);
      await t.pump();
      expect(taps, 1, reason: '★★★ 点了必须真的回调（假按钮钉死在这里）');
    });

    testWidgets('★★ 无 onConfigure 的其他类：版式与既有 SettingsGroupLabel 一致', (t) async {
      await t.pumpWidget(host(const SourceClassHeader(label: 'JS 插件', count: 32)));
      await t.pump();
      expect(find.text('JS 插件（32 个源）'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('source-class-configure')), findsNothing,
          reason: '★ 其余四类不该被顺手加上第二入口');
    });

    test('★★★ 源码锚点：聚合源那一类**真的**把 onConfigure 接上了', () {
      final src = File('lib/ui/settings_page.dart').readAsStringSync();
      // 只有 tvboxAggregate 那类传 onConfigure（其余传 null）
      expect(
        RegExp(r'onConfigure:\s*cls == SourceClass\.tvboxAggregate')
            .hasMatch(src),
        isTrue,
        reason: '★★★ 修法本体的锚点：必须**按分类**给入口，而不是所有类都加。'
            '注入「把判断去掉」⇒ 本条立刻红',
      );
      // 入口必须指向聚合二级页
      expect(
        RegExp(r'onConfigure:\s*cls == SourceClass\.tvboxAggregate[\s\S]{0,220}?'
                r'const TvboxAggregatePage\(\)')
            .hasMatch(src),
        isTrue,
        reason: '★★ 入口必须打开聚合二级页（那才是"链接可改"的地方）',
      );
      // 源码注释剥离后仍能匹配（防"只写在注释里"）
      expect(
        RegExp(r'SourceClassHeader\(\s*label: cls\.label')
            .hasMatch(src.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')),
        isTrue,
        reason: '★ 组头调用本身还在（不是只把判断写进了注释）',
      );
    });
  });

  // ───────────────────────────────────────────────────────────────
  //  ③ #3 根因判据：panCommandMissing 分档（含负面对照）
  // ───────────────────────────────────────────────────────────────
  group('③ #3 根因：区分「能力缺失」与「这次失败」', () {
    test('★★★ unsupported + 「还没有接入」⇒ true（能力缺失）', () {
      final e = SourinCoreException(
        '这个功能（`pan_qr_login_start`）在当前版本还没有接入，请更新到较新版本；'
        '若一直如此，请把日志发给我们。',
        'unsupported',
      );
      expect(panCommandMissing(e), isTrue,
          reason: '★★ 这是 `.probe/r2-pan-qr-reading.log` 的**真实字样**（真核心实测）');
    });

    test('★★★ 负面对照：普通失败 ⇒ false（不许一次抖动就关掉整区）', () {
      /*
       * 若实现写成 `return true`，本组四条全是 true ⇒ 界面**永远**显示"不会有二维码"，
       * 而 ④ 的门禁全绿。⇒ 这组负面对照是 ④ 有意义的前提。
       */
      for (final e in <Object>[
        SourinCoreException('网络不可用', 'network'),
        SourinCoreException('需要先登录', 'unauthorized'),
        SourinCoreException('没有找到该网盘', 'not_found'),
        StateError('boom'),
        'plain string',
      ]) {
        expect(panCommandMissing(e), isFalse,
            reason: '★ 非"未接线"档不许被认成能力缺失：$e');
      }
    });

    test('★★ 只有 kind=unsupported **或** 文案含「还没有接入」才算（两条各自独立）', () {
      // 只有 kind
      expect(panCommandMissing(SourinCoreException('随便什么原因', 'unsupported')),
          isTrue);
      // 只有文案（老核心可能只给文案不给 kind）
      expect(
        panCommandMissing(SourinCoreException('这个功能还没有接入', 'other')),
        isTrue,
        reason: '★ 老核心只给文案时也要能认出（否则会退化成"点了报错"）',
      );
    });
  });

  // ───────────────────────────────────────────────────────────────
  //  ④ #3 修法：真点过之后本区变成「如实说明」，不留假入口
  // ───────────────────────────────────────────────────────────────
  group('④ #3 修法：命令缺失 ⇒ 如实说明，不留只会报错的入口', () {
    testWidgets('★★★ 生产路径拿到 unsupported ⇒ 二维码区整块变成说明，入口消失', (t) async {
      /*
       * ★ 走**生产路径**：不注入 `debugPanQrLoginStarter`。
       *   真核心下 `pan_qr_login_start` 回 unsupported（`.probe/r2-pan-qr-reading.log`）。
       *
       * ⚠️⚠️ 这里必须用 `t.runAsync` 而不是裸 `t.pump()` —— 实测（`.probe/r2-widget-real-ffi-timing.dart`）：
       * ```text
       * 仅 pump()      ⇒ unavailable=0 error=0 start=1   （回调**没完成**，停在 busy）
       * runAsync(200ms)⇒ unavailable=1 error=0 start=0   （回调完成，如实说明出现）
       * ```
       * 原因：`callAsync` 的回包走**原生回调**（真异步），而 widget test 默认假时钟
       * ⇒ 裸 `pump()` 不推进它、Future 永不完成。本仓既有用例都靠**注入**绕开这一点，
       *   而本条要的恰恰是"真命令真返回"，所以必须 `runAsync` 让真异步跑起来。
       */
      debugPanCredentialStatusFetcher = () async => const <PanAccountStatus>[];
      await t.pumpWidget(host(const PanSettingsBody()));
      await t.pump();

      // 首屏：还没探测过 ⇒ 入口照常画（否则后端接上那天就恢复不了）
      expect(find.byKey(const ValueKey<String>('pan-qr-start')), findsOneWidget,
          reason: '★ 首屏必须画入口 —— 判据来自**真命令返回**，不是写死的常量');

      await t.tap(find.byKey(const ValueKey<String>('pan-qr-start')));
      await t.pump();
      await t.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      /*
       * ⚠️ `runAsync` 之后还要**再 pump 两次** —— 实测（`.probe/r2-diag-unavailable.dart`）：
       * ```text
       * runAsync 后第 1 次 pump ⇒ 可见 = [pan-qr-start]        （setState 还没落地）
       * 再 pump 两次          ⇒ 可见 = [pan-qr-unavailable]    （如实说明出现）
       * ```
       * 原因：`callAsync` 的回包在 runAsync 里完成 → 触发 `setState` → 需要下一帧才反映到树上。
       */
      await t.pump();
      await t.pump();
      await t.pump();

      // 拿到 unsupported ⇒ 换成如实说明
      expect(find.byKey(const ValueKey<String>('pan-qr-unavailable')), findsOneWidget,
          reason: '★★★ 命令缺失必须变成一句实话（注入「不置 _qrBackendAvailable」⇒ 本条红）');
      expect(
        find.byKey(const ValueKey<String>('pan-qr-unavailable-text')),
        findsOneWidget,
      );
      final txt = t
          .widget<Text>(find.byKey(const ValueKey<String>('pan-qr-unavailable-text')))
          .data;
      expect(txt, contains('还没有接入'),
          reason: '★★ 文案要如实说"没接入"（与 pan_auth.rs 头部自述同口径）');
      // 不留假入口
      expect(find.byKey(const ValueKey<String>('pan-qr-start')), findsNothing,
          reason: '★★★ 点了只会报错的入口不许留着（本仓对假入口的纪律，先例 t1061 ④）');
      expect(find.byKey(const ValueKey<String>('pan-qr-view')), findsNothing,
          reason: '★ 没拿到二维码不许画占位框');
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('★★★ 负面对照：真实网络失败 ⇒ **保留**入口（可重试），不许变成"没接入"',
        (t) async {
      debugPanCredentialStatusFetcher = () async => const <PanAccountStatus>[];
      debugPanQrLoginStarter =
          (kind) async => throw SourinCoreException('网络不可用', 'network');
      await t.pumpWidget(host(const PanSettingsBody()));
      await t.pump();
      await t.tap(find.byKey(const ValueKey<String>('pan-qr-start')));
      await t.pump();
      await t.pump();

      expect(find.byKey(const ValueKey<String>('pan-qr-unavailable')), findsNothing,
          reason: '★★★ 网络失败**不是**"能力缺失" —— 误判会把这一区永久关掉，'
              '而用户只需要重试（注入「panCommandMissing 恒 true」⇒ 本条红）');
      expect(find.byKey(const ValueKey<String>('pan-qr-start')), findsOneWidget,
          reason: '★★ 入口必须留着让人重试');
      expect(find.byKey(const ValueKey<String>('pan-qr-error')), findsOneWidget,
          reason: '★ 如实报这次失败');
      await t.pumpWidget(const SizedBox());
    });
  });

  // ───────────────────────────────────────────────────────────────
  //  ⑤ 诚实边界：断言里不许出现"支持扫码"这类承诺（#3 的根本）
  // ───────────────────────────────────────────────────────────────
  group('⑤ #3 页面文案不许再暗示「能扫码」', () {
    test('★★ 源码里不再有"以实际结果为准"这种把能力说成可用的措辞', () {
      final src =
          File('lib/ui/settings/pan_settings_page.dart').readAsStringSync();
      expect(
        src.contains('各网盘是否支持扫码以实际结果为准'),
        isFalse,
        reason: '★★★ 改前这句读起来像"可以扫码，只是看盘支不支持" ⇒ '
            '用户点了才撞 unsupported。注入「把这句改回去」⇒ 本条红',
      );
      expect(
        src.contains('showPanQrLoginDialog('),
        isTrue,
        reason: '扫码必须走独立弹窗，不再常驻显示历史未接入文案',
      );
    });

    test('★★ 命令名一个都没删（后端接上时能自动恢复）', () {
      final src = File('lib/ui/settings/pan_settings_page.dart').readAsStringSync();
      for (final cmd in const [
        'pan_auth_status',
        'pan_qr_login_start',
        'pan_qr_login_poll',
        'pan_logout',
      ]) {
        expect(src.contains("'$cmd'"), isTrue,
            reason: '★ 命令调用必须留着（删掉就等于永久放弃这条能力）`$cmd`');
      }
    });
  });
}