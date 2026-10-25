import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import '../lib/core/danmaku.dart';
import '../lib/core/ui_prefs.dart';
import '../lib/ui/widgets/danmaku_settings_dialog.dart';

/// 第 09 项验收：小窗口 + **长错误文本**下，最后一行与操作按钮**可滚动到达**
///
/// # 改前这份门禁缺什么（如实记录，不弱化）
/// ```text
/// 旧版本只有一条：小窗口 → 有滚动区 → drag(-500) → takeException() 为 null。
/// 它证明的是"拖动不炸"，**没有**证明"最后一行真的能到达"：
///   · 没设长错误文本（底部那两块 `_hintSection` / 「查看请求与服务端详情」
///     在旧用例里压根不存在）
///   · 没滚到底（drag -500 之后滚动位置在哪、有没有到 maxScrollExtent，都没断）
///   · 没断"到达"的可操作判据（可见 + 可点）
/// ⇒ 计划原文要的是「最后一行与操作按钮均可滚动到达，无溢出异常」。
/// ```

/// 长文本要长到"一定得滚"的程度（不是刚好一屏）
final String _longText =
    List<String>.filled(40, '这一段是很长的错误说明，用来把小窗口撑到必须滚动。')
        .join();

DanmakuSettingsState _stateWithLongError() => DanmakuSettingsState(
      enabled: true,
      appId: '',
      appSecret: '',
      fontScale: 1,
      opacity: 0.9,
      speed: 1,
      area: 0.5,
      error: DanmakuException(
        '凭证校验失败（401）',
        statusCode: 401,
        body: _longText,
        hint: DanmakuHint(title: '这一类错误的下一步', text: _longText),
      ),
    );

Widget _host(DanmakuSettingsState state) => MaterialApp(
    home: Scaffold(body: DanmakuSettingsDialog(
  state: state,
  onSetEnabled: (_) {},
  onSetFontScale: (_) {},
  onSetOpacity: (_) {},
  onSetSpeed: (_) {},
  onSetArea: (_) {},
  onReload: () {},
  onClose: () {},
  onOpenSearch: () {},
  fill: false,
)));

ScrollPosition _positionOf(WidgetTester tester) {
  final scroll = find.byKey(const ValueKey('danmaku-settings-scroll'));
  return tester.state<ScrollableState>(find.descendant(
    of: scroll,
    matching: find.byType(Scrollable),
  ).first).position;
}

Future<void> _dragToBottom(WidgetTester tester, String tag) async {
  final scroll = find.byKey(const ValueKey('danmaku-settings-scroll'));
  final pos = _positionOf(tester);
  var guard = 0;
  while (pos.pixels < pos.maxScrollExtent && guard < 40) {
    await tester.drag(scroll, const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull,
        reason: '★ 滚动过程中不许冒溢出异常（$tag guard=$guard）');
    guard++;
  }
  expect(pos.maxScrollExtent, greaterThan(0),
      reason: '★★ 内容没比视口长 ⇒ 下面"到达底部"是恒真的假绿（$tag）');
  expect(pos.pixels, pos.maxScrollExtent,
      reason: '★★★ 没滚到底：还有 ${pos.maxScrollExtent - pos.pixels} px 够不着（$tag）');
}

void main() {
  setUp(() => UiPrefs.debugResetForTest(<String, String>{}));
  tearDown(() => UiPrefs.debugResetForTest(<String, String>{}));

  testWidgets('small window bounds settings and keeps advanced content scrollable',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 360);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DanmakuSettingsDialog(
      state: const DanmakuSettingsState(enabled: true, appId: '', appSecret: '',
        fontScale: 1, opacity: 0.9, speed: 1, area: 0.5),
      onSetEnabled: (_) {}, onSetFontScale: (_) {}, onSetOpacity: (_) {},
      onSetSpeed: (_) {}, onSetArea: (_) {}, onReload: () {}, onClose: () {},
      onOpenSearch: () {}, fill: false,
    ))));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final scroll = find.byKey(const ValueKey('danmaku-settings-scroll'));
    expect(scroll, findsOneWidget);
    expect(tester.getSize(scroll).height, lessThanOrEqualTo(360));
    await tester.ensureVisible(find.text('高级').first);
    await tester.tap(find.text('高级').first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.drag(scroll, const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  // ══════════════════════════════════════════════════════════════════════
  //  ★★★ 长错误 + 小窗口：最后一行与操作按钮必须**真的能到达**
  // ══════════════════════════════════════════════════════════════════════
  testWidgets('★★★ 长错误文本 + 小窗口：最后一行可滚动到达，且无溢出异常',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 360);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(_stateWithLongError()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '★ 首帧不许有溢出异常');

    await tester.ensureVisible(find.text('高级').first);
    await tester.tap(find.text('高级').first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await _dragToBottom(tester, '长错误 1.0×');

    // ★ 最后一行：底部那枚导航按钮（它在滚动内容的**最末尾**）
    final lastLine = find.text('查看请求与服务端详情');
    expect(lastLine, findsOneWidget);
    final lastRect = tester.getRect(lastLine);
    /*
     * ★★ 2026-10-25（审计自查）：原来判的是 `lastRect.bottom <= 屏幕高`。
     *    那是**过宽**的窗口 —— 屏幕比滚动视口大，而弹窗在屏幕里是居中的、
     *    上下都有留白 ⇒ 一个"落在滚动视口之外、但仍在屏幕之内"的元素也能满足它，
     *    「滚到底能看见最后一行」这件事就没被真正钉住。
     * ⇒ 改成与**滚动视口自己的矩形**求包含关系：那才是"用户真的看得到这一行"。
     */
    final viewport =
        tester.getRect(find.byKey(const ValueKey('danmaku-settings-scroll')));
    expect(viewport.contains(lastRect.topLeft), isTrue,
        reason: '★★★ 滚到底后最后一行仍不在**滚动视口**内'
            '（item.top=${lastRect.top} 视口=${viewport.top}..${viewport.bottom}）');
    expect(lastRect.bottom, lessThanOrEqualTo(viewport.bottom),
        reason: '★★★ 最后一行下半截被视口裁掉了'
            '（item.bottom=${lastRect.bottom} > viewport.bottom=${viewport.bottom}）');
    // 屏幕级上界保留作双重保险（视口本身必须在屏幕内）
    final viewHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(lastRect.bottom, lessThanOrEqualTo(viewHeight));
    expect(lastRect.top, greaterThanOrEqualTo(0));
    // ★ 可操作判据：不只是"画在屏幕上"，还要**点得到**
    expect(lastLine.hitTestable(), findsOneWidget,
        reason: '★★★ 最后一行被别的层挡住/被裁剪 ⇒ 用户点不到');

    // ★ 操作按钮：高级页签里的「测试连接」也必须能滚动到达
    final action = find.text('测试连接');
    expect(action, findsOneWidget);
    await tester.ensureVisible(action);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(action.hitTestable(), findsOneWidget,
        reason: '★★★ 操作按钮必须可达可点（计划原文的第二半句）');
  });

  // ══════════════════════════════════════════════════════════════════════
  //  ★★ 文字放大 1.3× + 长错误：同样不许溢出、同样要能到底
  // ══════════════════════════════════════════════════════════════════════
  testWidgets('★★ 文字放大 1.3× + 小窗口：无溢出且仍能滚到底', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 360);
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(_host(_stateWithLongError()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '★ 1.3× 文字下首帧不许溢出');

    await tester.ensureVisible(find.text('高级').first);
    await tester.tap(find.text('高级').first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await _dragToBottom(tester, '长错误 1.3×');
  });
}
