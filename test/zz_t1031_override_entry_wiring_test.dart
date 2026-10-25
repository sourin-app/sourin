import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings_page.dart';

/// 第 06 项：源个性化覆盖层**入口接线**的行为门禁
///
/// # 为什么必须有这一条
/// `t94_emby_entry_test` 只验"类名被外部引用"，`zz_t1030` 只验"编辑器组件
/// 自己能渲染"。**"点菜单真的会调 `onOverride`"这条中间链路**两者都覆盖不到 ——
/// 而它正是本轮接线最容易接错的地方（我第一版就把插入点放进了三元表达式中间，
/// 8 个编译错误）。
///
/// # 判据
/// 挂真实 `_ProviderCard`（走 `settingsProviderCardForTest`，与生产同构）→
/// 点开 ⋮ 菜单 → 点「个性化覆盖层…」→ 断言回调**恰好被调一次**。
/// 同时验阴性对照：`onOverride == null` 时菜单里**不出现**该项。
void main() {
  ProviderManifest manifest() => ProviderManifest.fromJson(const {
        'id': 'probe_src',
        'name': '探针源',
        'kind': 'js',
        'enabled': true,
        'builtin': false,
      });

  Future<void> pumpCard(
    WidgetTester t, {
    VoidCallback? onOverride,
    void Function()? onEdit,
  }) async {
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(900, 700);
    addTearDown(() {
      t.view.resetPhysicalSize();
      t.view.resetDevicePixelRatio();
    });
    await t.pumpWidget(MaterialApp(
      theme: AppTheme.themeFor(Brightness.dark),
      themeAnimationDuration: Duration.zero,
      home: Scaffold(
        body: SingleChildScrollView(
          child: settingsProviderCardForTest(
            provider: manifest(),
            onToggle: () {},
            onEdit: onEdit ?? () {},
            onOverride: onOverride,
          ),
        ),
      ),
    ));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
  }

  /// 打开 ⋮ 菜单（AppMenuButton 的 tooltip 是「更多操作」）
  Future<void> openMenu(WidgetTester t) async {
    final more = find.byTooltip('更多操作');
    expect(more, findsOneWidget, reason: '前提：卡片上有 ⋮ 菜单');
    await t.tap(more);
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
  }

  testWidgets('点「个性化覆盖层…」会调用 onOverride（恰好一次）', (t) async {
    var calls = 0;
    await pumpCard(t, onOverride: () => calls++);

    await openMenu(t);
    final item = find.text('个性化覆盖层…');
    expect(item, findsOneWidget, reason: '菜单里必须有这个入口');

    await t.tap(item);
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));

    expect(calls, 1, reason: '★★ 点一次必须恰好调一次 onOverride');
  });

  testWidgets('onOverride 为 null 时不画该菜单项（不做假按钮）', (t) async {
    await pumpCard(t, onOverride: null);
    await openMenu(t);

    expect(find.text('个性化覆盖层…'), findsNothing,
        reason: '★★ 没有真实能力就不画入口，与 onPluginUpdate 同一条纪律');
    // 阴性对照：菜单本身仍然正常（说明是"少一项"而不是"菜单坏了"）
    expect(find.text('编辑'), findsOneWidget, reason: '对照：其它项仍应在');
  });

  testWidgets('点「编辑」不会误调到 onOverride（互不串台）', (t) async {
    var overrideCalls = 0;
    var editCalls = 0;
    await pumpCard(
      t,
      onOverride: () => overrideCalls++,
      onEdit: () => editCalls++,
    );

    await openMenu(t);
    await t.tap(find.text('编辑'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));

    expect(editCalls, 1, reason: '「编辑」应调到 onEdit');
    expect(overrideCalls, 0, reason: '★★ 不许串台到 onOverride');
  });
}
