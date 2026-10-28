// ═══════════════════════════════════════════════════════════════════════
//  N4-3 版面改版 · 八条判据（#2 #3 #4 #5 #6 #7 #8 #9）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这份门禁守什么
// ```text
// `.probe/n4-3-layout-baseline.md` 的问题清单里，#2/#3/#4/#5/#6/#7/#8/#9 都是
// **版面/信息层级**问题 —— 改之前"看着不对"，改之后必须"机器能判"，
// 否则下一轮重排又是靠肉眼复核。
//
// 每条判据都对着一个**可测量的量**（矩形、宽高、样式），不是"源码里出现过某串"：
//   #2 输入框有描边（border.width ≥ 1 且非全透明）+ 按钮宽度 < 输入框 75%
//   #3 输入框底 → 按钮顶的间距 ≥ 8，且两者同在一个 keyed 搜索组里
//   #4 说明文字在输入框**之上**（hint.bottom ≤ field.top）、字号 ≤ 12.5、色 = onSurfaceVariant
//   #5 条目里**没有**常驻「绑定当前集」按钮；打开条目菜单能绑（行为断言，不是文案断言）
//   #6 勾选框在标题**左侧**且间距 ≤ 60（原来是"最右、距文字 700+"）
//   #7 「对应本地」下拉有描边、触达高 ≥ 32，且真的能改值（行为断言）
//   #8 分组标题加粗，且标题与第一条结果之间**有 Divider**
//   #9 条目行左右留白对称（误差 ≤ 2px），右侧留白 ≤ 24（内容吃满）
// ```
//
// # 为什么每张图都要量 1280×800
// ```text
// 基线截图就是 1280 宽（`.probe/n4-3-layout/n4-3-wide-results.png`）。
// 在默认 800×600 的测试面上，"复选框距文字 700px"这种现象根本不会出现
// ⇒ 用小窗口量 #6 会得到"已经通过"的假绿。
// ```
//
// # 注入（每条都能真红，日志 `.probe/n4-3-redesign-inject.log`）
// ```text
// 见报告逐条列出：删描边 / 删 12px 间距 / 说明文字去掉弱化样式 /
// 把「绑定当前集」加回常驻按钮 / controlAffinity 改回 trailing /
// 去掉下拉描边 / 删掉标题下的 Divider / 左右 padding 改不对称。
// ```

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../lib/core/danmaku.dart';
import '../lib/ui/danmaku_search_page.dart';
import '../lib/ui/widgets/bili_import_dialog.dart';
import '../lib/ui/widgets/danmaku_settings_dialog.dart';

const String kHint = '搜索、启用、绑定与加载是不同状态';
const String kSearchButton = '搜索 dan-api 与视频站';
const String kGroupKey = 'danmaku-search-group';
const String kPickKey = 'danmaku-local-pick';

DanmakuSettingsState _state({bool stale = false, int count = 2}) =>
    DanmakuSettingsState(
      enabled: true,
      appId: '',
      appSecret: '',
      fontScale: 1,
      opacity: 1,
      speed: 1,
      area: 1,
      searchSearched: true,
      searchStale: stale,
      searchResults: <DanmakuMatch>[
        for (var i = 0; i < count; i++)
          DanmakuMatch(
            episodeId: 7 + i,
            animeTitle: i.isEven ? '作品甲' : '作品乙',
            episodeTitle: '第${i + 1}集',
          ),
      ],
    );

Future<void> _mount(
  WidgetTester t, {
  DanmakuSettingsState? state,
  ValueChanged<DanmakuMatch>? onPick,
  List<String> localTitles = const <String>['第1集', '第2集'],
}) async {
  // 1280×800 = 基线与截图同宽（见文件头"为什么必须 1280"）
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = const Size(1280, 800);
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    home: DanmakuSearchPage(
      state: state ?? _state(),
      biliState: const BiliImportState(),
      localTitles: localTitles,
      workTitle: '某部示例作品',
      onSearch: (_) {},
      onBiliSearch: (_) {},
      onPickMatch: onPick ?? (_) {},
      onBatchBind: (_) {},
      onBiliImport: (_) {},
      onBiliSelectPage: (_) {},
      onClose: () {},
    ),
  ));
  await t.pump();
}

void main() {
  testWidgets('N4-3 #2 输入框有可见描边，搜索按钮不通栏', (t) async {
    await _mount(t);
    final field = t.widget<TextField>(find.byType(TextField));
    final deco = field.decoration!;
    final border = deco.border;
    expect(border, isA<OutlineInputBorder>(),
        reason: '★★ 改前输入框是无边框文本行 —— 用户不知道这里能输入');
    final side = (border as OutlineInputBorder).borderSide;
    expect(side.width, greaterThanOrEqualTo(1), reason: '★ 描边要有实际宽度');
    expect(side.color.a, greaterThan(0), reason: '★ 描边不能是全透明（等于没有）');
    // enabledBorder 也必须显式给（否则失焦/聚焦状态一边有一边没有）
    expect(deco.enabledBorder, isA<OutlineInputBorder>(),
        reason: '★ 常态描边要与聚焦态一致（只给 focus 边框 = 平时仍然看不见）');

    final fieldRect = t.getRect(find.byType(TextField));
    final buttonRect = t.getRect(find.widgetWithText(FilledButton, kSearchButton));
    expect(buttonRect.width, lessThan(fieldRect.width * 0.75),
        reason: '★★ 改前按钮通栏（比输入框"重"三倍）⇒ 主次颠倒；现在必须收窄到内容宽');
    expect(buttonRect.left, closeTo(fieldRect.left, 0.5),
        reason: '★ 收窄后要左对齐，不许居中/右漂');
  });

  testWidgets('N4-3 #3 输入与按钮之间有分组间距，且同在一个搜索组里', (t) async {
    await _mount(t);
    final fieldRect = t.getRect(find.byType(TextField));
    final buttonRect = t.getRect(find.widgetWithText(FilledButton, kSearchButton));
    expect(buttonRect.top - fieldRect.bottom, greaterThanOrEqualTo(8),
        reason: '★★ 改前零间距 ⇒ 按钮像输入框的下边框；必须留出分组间距');

    final group = find.byKey(const ValueKey<String>(kGroupKey));
    expect(group, findsOneWidget, reason: '★ 两者要被同一个"搜索组"容器圈起来');
    expect(find.descendant(of: group, matching: find.byType(TextField)), findsOneWidget);
    expect(
      find.descendant(of: group, matching: find.widgetWithText(FilledButton, kSearchButton)),
      findsOneWidget,
    );
  });

  testWidgets('N4-3 #4 说明文案是"本段前置说明"（在输入之上 + 弱化）', (t) async {
    await _mount(t);
    final hint = find.textContaining(kHint);
    expect(hint, findsOneWidget, reason: '前置：这句说明必须还在（不是删掉了事）');
    final hintRect = t.getRect(hint);
    final fieldRect = t.getRect(find.byType(TextField));
    expect(hintRect.bottom, lessThanOrEqualTo(fieldRect.top),
        reason: '★★ 改前它在按钮下面 ⇒ 读作按钮副标题；现在是"这一段的前置说明"，必须在输入框之上');
    expect(fieldRect.top - hintRect.bottom, greaterThanOrEqualTo(4),
        reason: '★ 与输入框之间要留一点气口，否则又贴成一行');

    final style = t.widget<Text>(hint).style!;
    expect(style.fontSize ?? 14, lessThanOrEqualTo(12.5),
        reason: '★ 弱化：字号必须小于正文（改前与正文同号 ⇒ 抢注意力）');
    final ctx = t.element(find.byType(DanmakuSearchPage));
    expect(style.color, Theme.of(ctx).colorScheme.onSurfaceVariant,
        reason: '★ 弱化：用 onSurfaceVariant（与按钮同色系会把说明读成按钮的一部分）');
  });

  testWidgets('N4-3 #5 单条绑定收进条目菜单，且菜单里真的能绑', (t) async {
    final picked = <int>[];
    await _mount(t, onPick: (m) => picked.add(m.episodeId));

    // ① 收起态：条目里**没有**常驻的「绑定当前集」按钮（6 条 × 90px 的噪声消失）
    expect(find.widgetWithText(TextButton, '绑定当前集'), findsNothing,
        reason: '★★ 改前每条结果左侧都钉一个「绑定当前集」；现在必须收进条目菜单');
    // ② 批量入口保留（不是把功能删了）
    expect(find.text('预览批量绑定'), findsOneWidget,
        reason: '★ 单条动作收起来，但批量入口必须还在');

    // ③ 行为断言：点开菜单 ⇒ 有「绑定当前集」⇒ 点它真的回调
    await t.tap(find.byKey(const ValueKey<String>('danmaku-match-menu-7')));
    await t.pumpAndSettle();
    final item = t.widget<PopupMenuItem<String>>(
      find.widgetWithText(PopupMenuItem<String>, '绑定当前集'),
    );
    expect(item.enabled, isTrue, reason: '★ 正常态菜单项必须可用');
    await t.tap(find.text('绑定当前集').last);
    await t.pumpAndSettle();
    expect(picked, <int>[7],
        reason: '★★ 断言从"找到一个常驻按钮"改成"点开菜单能绑"——语义是行为，不是文案');
  });

  testWidgets('N4-3 #6 勾选框在条目左侧、紧邻文字（不再隔 700px）', (t) async {
    await _mount(t);
    final tileRect = t.getRect(find.byType(CheckboxListTile).first);
    final boxRect = t.getRect(find.byType(Checkbox).first);
    final titleRect = t.getRect(find.textContaining('作品甲').first);

    expect(boxRect.left, lessThan(titleRect.left),
        reason: '★★ 改前复选框在最右（距文字 700+px）⇒ 眼手分离；必须在文字左侧');
    expect(titleRect.left - boxRect.left, lessThanOrEqualTo(60),
        reason: '★ 勾选与标题要在同一个视觉组里（间距不许拉到"跨半屏"）');
    expect(titleRect.left - tileRect.left, lessThanOrEqualTo(80),
        reason: '★ 标题不许再有 ~200px 的左缩进（改前 x≈170）');
    // 反过来：勾选框不许跑到行外（左侧越界 = 被裁）
    expect(boxRect.left, greaterThanOrEqualTo(tileRect.left - 0.5));
  });

  testWidgets('N4-3 #7 「对应本地」是有描边、可点的下拉（且真能改）', (t) async {
    await _mount(t);
    final pick = find.byKey(const ValueKey<String>(kPickKey)).first;
    expect(pick, findsOneWidget, reason: '★ 下拉要被一个可识别的容器包住（描边/触达区）');
    final box = t.widget<Container>(pick);
    final deco = box.decoration;
    expect(deco, isA<BoxDecoration>(), reason: '★ 需要描边装饰，否则又像纯文本');
    expect((deco as BoxDecoration).border, isNotNull,
        reason: '★★ 改前「不绑定 ▾」没有边框 ⇒ 看起来像一句话，不知道能点');
    expect(t.getSize(pick).height, greaterThanOrEqualTo(32),
        reason: '★ 触达区至少 32 高（否则点不准）');

    // 行为：打开并选「第2集」⇒ 值真的变了
    await t.tap(find.byType(DropdownButton<int>).first);
    await t.pumpAndSettle();
    await t.tap(find.text('第2集').last);
    await t.pumpAndSettle();
    expect(t.widget<DropdownButton<int>>(find.byType(DropdownButton<int>).first).value, 1,
        reason: '★ 描边只是"看起来能点"，这条钉的是"真的能改"');
  });

  testWidgets('N4-3 #8 分组标题有层级差，且与条目之间有分隔', (t) async {
    await _mount(t);
    final header = find.text('dan-api 剧集');
    expect(header, findsOneWidget, reason: '前提：分区标题还在（文案逐字不变）');
    final style = t.widget<Text>(header).style!;
    expect((style.fontWeight ?? FontWeight.normal).index,
        greaterThanOrEqualTo(FontWeight.w600.index),
        reason: '★ 改前是默认字号的裸文本 ⇒ 读成"第 0 条"；标题必须更重');

    final headerRect = t.getRect(header);
    final tileRect = t.getRect(find.byType(CheckboxListTile).first);
    final dividers = find.byType(Divider);
    var between = false;
    for (var i = 0; i < dividers.evaluate().length; i++) {
      final r = t.getRect(dividers.at(i));
      if (r.top >= headerRect.bottom - 1 && r.bottom <= tileRect.top + 1) {
        between = true;
        break;
      }
    }
    expect(between, isTrue,
        reason: '★★ 改前标题与 6 条结果之间零分隔 ⇒ 读成一片；必须有 Divider 落在两者之间');
  });

  testWidgets('N4-3 #9 左右留白对称、内容吃满', (t) async {
    await _mount(t);
    final listRect = t.getRect(find.byType(SingleChildScrollView));
    final tileRect = t.getRect(find.byType(CheckboxListTile).first);
    final leftGap = tileRect.left - listRect.left;
    final rightGap = listRect.right - tileRect.right;
    expect((leftGap - rightGap).abs(), lessThanOrEqualTo(2),
        reason: '★★ 改前左右不对称（左缩进 ~200 / 右空 ~260）⇒ 版面偏在一边');
    expect(rightGap, lessThanOrEqualTo(24),
        reason: '★ 内容要吃满（右侧不许再留出一大块空白）');
    expect(leftGap, greaterThanOrEqualTo(8),
        reason: '★ 也别贴到窗口边（8~24 是留白，不是 0）');
  });

  // ══════════════════════════════════════════════════════════════════════
  //  复核后补的两条（Lead 2026-10-28 点名）
  // ══════════════════════════════════════════════════════════════════════

  testWidgets('N4-3 #2b 底部动作区与搜索按钮同一规范：内容宽、左对齐、不通栏', (t) async {
    await _mount(t);
    final viewport = t.getRect(find.byType(SingleChildScrollView));
    // 反空真：视口得先够宽，否则"小于 60%"这个阈值本身没有意义
    expect(viewport.width, greaterThan(700), reason: '前置：视口要够宽，阈值才有意义');

    final preview = find.widgetWithText(OutlinedButton, '预览批量绑定');
    final previewRect = t.getRect(preview);
    expect(previewRect.width, lessThan(viewport.width * 0.6),
        reason: '★★ 改前「预览批量绑定」通栏 ⇒ 用户把它读成"这一页的主按钮"，而它只是结果区的一步');
    expect(previewRect.left, closeTo(viewport.left + 16, 1.5),
        reason: '★ 内容宽 + 左对齐到内容左边线（与搜索按钮同一套规范）');

    // 打开预览 ⇒ 确认按钮必须也是同一规范
    await t.tap(find.byType(CheckboxListTile).first);
    await t.pump();
    await t.ensureVisible(preview);
    await t.pumpAndSettle();
    await t.tap(preview);
    await t.pump();

    final confirm = find.widgetWithText(FilledButton, '确认并交由播放器绑定');
    final confirmRect = t.getRect(confirm);
    expect(confirmRect.width, lessThan(viewport.width * 0.6),
        reason: '★★ 「确认并交由播放器绑定」同样是内容宽（改前 1200+ 通栏）');
    expect(confirmRect.left, closeTo(previewRect.left, 1.5),
        reason: '★ 两个动作的左边界必须齐（同一列）');
    expect(t.widget<FilledButton>(confirm).onPressed, isNotNull,
        reason: '★ 反空真：收窄之后它仍然是真的可点按钮，不是被挤成不可用');
  });

  testWidgets('N4-3 #9b 副标题铺满整行：中段落在带子里（不再是"文字+空洞+控件"）', (t) async {
    await _mount(t);
    final tileRect = t.getRect(find.byType(CheckboxListTile).first);
    final band = find.byKey(const ValueKey<String>('danmaku-subtitle-band-7'));
    expect(band, findsOneWidget,
        reason: '★★ 副标题要有一条满宽的底纹带；没有它，中段 ~500px 就是纯空白');

    final bandRect = t.getRect(band);
    expect(bandRect.width / tileRect.width, greaterThan(0.65),
        reason: '★★ 带子要占据行宽的大头（改前副标题只占 ~35%，其余是空白）');
    final mid = tileRect.left + tileRect.width / 2;
    expect(bandRect.left <= mid && mid <= bandRect.right, isTrue,
        reason: '★★★ 行的水平中点必须落在带子里 —— 这正是"中段空洞"的度量');

    final deco = t.widget<Container>(band).decoration;
    expect(deco, isA<BoxDecoration>(), reason: '★ 带子要有底色（否则还是一条看不见的空白）');
    expect((deco as BoxDecoration).color, isNotNull);

    // 下拉仍在带子内部靠右（控件没有被带子挤出去）
    final pick = t.getRect(find.byKey(const ValueKey<String>('danmaku-local-pick')).first);
    expect(pick.left, greaterThanOrEqualTo(bandRect.left));
    expect(pick.right, lessThanOrEqualTo(bandRect.right + 0.5));
    expect(pick.left, greaterThan(mid), reason: '★ 下拉仍在右半侧（不进入中间带，避免截走"点整行选中"）');
  });
}
