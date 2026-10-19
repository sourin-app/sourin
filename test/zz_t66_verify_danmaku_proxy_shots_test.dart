// ══════════════════════════════════════════════════════════════════════
//  zz_t66_verify_danmaku_proxy_shots —— 弹幕源「网络代理」真机等价取证
// ══════════════════════════════════════════════════════════════════════
//
// # 它补的是哪个洞（verify-e2e 复核 6222428 时发现的）
//
// ```text
// 已有的 zz_t66_danmaku_proxy_a11y_test.dart 渲染的是一个 **`_Probe` 副本**
// （文件内自己搭的同构三态），不是产品页 `DanmakuSourcePage`。
//   ⇒ 它证明「三个 RadioListTile 的高度/焦点正常」，
//     但**证明不了产品页里那段真的渲染出来了**。
//
// 而 6222428 的 UI 部分恰恰是整段新写的（lib/ui/settings/danmaku_source_page.dart
// 里那个 `SettingsBlock(title: '网络代理')`）。
// 「门禁绿 + 产品页没渲染」和「门禁红」是两回事 —— 前者更危险。
// ```
//
// # 为什么用 flutter_test 而不是起进程截屏
//
// ```text
// 铁律 ②：绝不 CopyFromScreen（会拍到 Owner 桌面）。
// 唯一允许的两种取图：
//   ① SOURIN_SHOT=1  ⇒ 进程内 RenderRepaintBoundary（要真机起进程）
//   ② flutter_test 渲染 ⇒ 本文件
// 设置页的二级页没有深链入参，起进程后**无法用键盘走到**那一页
// （桌面端 Device.needsFocusRing=false ⇒ 空间导航关闭；
//  PostMessage 的 WM_LBUTTONDOWN 也进不到 Flutter，实测 0 次 [NAV]）。
// ⇒ 目标层的取图只能走 ②。
// ```
//
// # 判据（每条都是可观察的事实）
//
// ```text
// ① 产品页里**真的**有三个选项，文案逐字为：直连 / 跟随系统代理 / 自定义代理
// ② 三种模式各自渲染出的 PNG 落盘，且**三张互不相同**（选中态真的变了）
// ③ custom 模式下**出现**代理地址输入框；direct / system 下**没有**
//    （源码注释明说"其它模式留着它会让用户以为填了就生效"，这是个行为断言）
// ④ 诊断行文案随模式变化，且与 resolveDanmakuFindProxy 的实际结果一致
// ```
//
// 产物：`.probe/e2e/danmaku-proxy-<mode>.png`
//
// ⚠️ 本文件不改产品代码，只读页面 + 落盘截图。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings/danmaku_source_page.dart';

/// 产品页需要 UiPrefs 已加载（它 initState 直接读内存缓存）
///
/// ⚠️ 这里**只初始化内存**，不读真实数据目录。`UiPrefs.load()` 才碰磁盘，
///    本文件不调它 ⇒ 与 Owner 的真实收藏/进度完全隔离。
void _seedPrefs({required String mode, String url = ''}) {
  UiPrefs.setDanmakuProxy(mode: mode, url: url);
}

/// 把产品页滚到底 —— 代理区块**不在首屏**（它在「连接」块之后）
///
/// ★ 这条本身就是一个发现：`SettingsSubPage` 用的是 `CustomScrollView`，
///   代理三态在懒构建的尾部。先前那版 `_Probe` 副本测试永远看不到这个
///   "需要滚动才能到达"的事实 ⇒ 它测的控件存在，但没测"用户在页面上找得到"。
Future<void> _scrollToProxyBlock(WidgetTester t) async {
  final sv = find.byType(CustomScrollView).first;
  await t.drag(sv, const Offset(0, -3000));
  await t.pumpAndSettle();
}

const String _kTestFont = 'CjkTest';

/// 给测试注入一个**真实的中文字体** —— 否则 PNG 里全是豆腐块
///
/// # 为什么必须做
/// ```text
/// flutter_test 的默认字体（Ahem/Roboto 回退）**没有 CJK 字形**
/// ⇒ `toImage()` 出来的图里每个汉字都画成 □
/// ⇒ 图虽然"存在且非空"，却**证明不了任何文案**（等于假证据）。
///
/// 第一次跑本文件时就是这样：12736 B 的 PNG 看着正常，
/// 打开全是方块 —— 而这种图最危险：它看起来像通过了的证据。
/// ```
/// 用系统自带的 SimHei（9.7 MB，Win 自带，不改仓库、不加依赖）。
Future<void> _loadCjkFont() async {
  for (final path in [
    r'C:\Windows\Fonts\simhei.ttf',
    r'C:\Windows\Fonts\msyh.ttc',
  ]) {
    final f = File(path);
    if (!await f.exists()) continue;
    final bytes = await f.readAsBytes();
    final loader = FontLoader(_kTestFont)
      ..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
    return;
  }
}

Widget _host(Widget child) {
  var theme = AppTheme.themeFor(Brightness.light);
  /*
   * ★ 把整个主题的字体族换成已加载的 SimHei。
   *
   * 只 `FontLoader('Roboto')` 是**不够的** —— 本仓主题没有显式 fontFamily，
   * Flutter 会走平台默认族名，测试环境里那个族名与 'Roboto' 不一定同名
   * ⇒ 字形仍然回退到只有 □ 的测试字体。
   * ⇒ 显式 `apply(fontFamily: ...)` 才是真正把样式指到已加载字体上。
   */
  theme = theme.copyWith(
    textTheme: theme.textTheme.apply(fontFamily: _kTestFont),
    primaryTextTheme: theme.primaryTextTheme.apply(fontFamily: _kTestFont),
  );
  return MaterialApp(
    theme: theme,
    builder: (context, c) =>
        AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: DefaultTextStyle.merge(
      style: const TextStyle(fontFamily: _kTestFont),
      child: child,
    ),
  );
}

/// 把整页光栅化并落盘
Future<({int w, int h, int bytes})> _shoot(WidgetTester tester, String outPath) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byType(RepaintBoundary).first,
  );
  late int w = 0, h = 0, n = 0;
  await tester.runAsync(() async {
    final img = await boundary.toImage(pixelRatio: 1.0);
    final bd = await img.toByteData(format: ui.ImageByteFormat.png);
    w = img.width;
    h = img.height;
    n = bd!.lengthInBytes;
    final f = File(outPath);
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bd.buffer.asUint8List(), flush: true);
    img.dispose();
  });
  return (w: w, h: h, bytes: n);
}

void main() {
  const outDir = '.probe/e2e';

  setUpAll(() async {
    // 落盘目录（幂等）
    Directory(outDir).createSync(recursive: true);
    // ★ 不装字体 ⇒ 图里全 □ ⇒ 那不是证据，是假象
    await _loadCjkFont();
  });

  testWidgets('① 产品页真的渲染出「网络代理」三态（不是副本）', (t) async {
    _seedPrefs(mode: 'direct');
    await t.pumpWidget(_host(const DanmakuSourcePage()));
    await t.pumpAndSettle();
    await _scrollToProxyBlock(t);

    // ── 逐字断言三条文案 ──
    expect(find.text('直连'), findsOneWidget, reason: '产品页必须有「直连」选项');
    expect(find.text('跟随系统代理'), findsOneWidget,
        reason: '产品页必须有「跟随系统代理」选项');
    expect(find.text('自定义代理'), findsOneWidget,
        reason: '产品页必须有「自定义代理」选项');

    // ── 控件级断言：三个 RadioListTile，且都挂在产品的 RadioGroup 下 ──
    final tiles = find.byType(RadioListTile<DanmakuProxyMode>);
    expect(tiles, findsNWidgets(3), reason: '三态必须正好三个');
    expect(find.byType(RadioGroup<DanmakuProxyMode>), findsOneWidget,
        reason: 'three tiles must be inside ONE RadioGroup (deprecation migration)');

    // ── 落盘（对照图）──
    final r = await _shoot(t, '$outDir/danmaku-proxy-direct.png');
    // ignore: avoid_print
    print('[SHOT] danmaku-proxy-direct.png  ${r.w}x${r.h}  ${r.bytes} B');
    expect(r.w, greaterThan(300));
    expect(r.h, greaterThan(300));
    expect(r.bytes, greaterThan(1000));
  });

  testWidgets('② 三种模式三张图互不相同（选中态真的变了）', (t) async {
    final sizes = <String, int>{};
    final hashes = <String, String>{};

    for (final mode in ['direct', 'system', 'custom']) {
      _seedPrefs(mode: mode, url: mode == 'custom' ? 'http://127.0.0.1:7890' : '');
      /*
       * ★ 必须先 pump 一个**空** widget 再 pump 产品页。
       *
       * `pumpWidget` 对**同类型** widget 是"更新"而不是"重建" ——
       * State 会保留，`initState` 不再执行 ⇒ `_proxyMode` 永远停在第一次的
       * 值，三张图会**字节相同**，而断言"三张不同"就会假红/假绿。
       * 这里插一帧空树，强制 State dispose，下一次就是真正的首次挂载。
       */
      await t.pumpWidget(const SizedBox.shrink());
      await t.pump();

      await t.pumpWidget(_host(const DanmakuSourcePage()));
      await t.pumpAndSettle();
      await _scrollToProxyBlock(t);

      final p = '$outDir/danmaku-proxy-$mode.png';
      final r = await _shoot(t, p);
      sizes[mode] = r.bytes;

      /*
       * ⚠️ 读文件必须在 `runAsync` 里 —— 与 `toImage` 同一条纪律。
       *    widget 测试默认跑在 **fake-async zone**：真实的 `File.readAsBytes`
       *    future 由**真实** event loop 完成，而 fake clock 不会推进它
       *    ⇒ 直接 `await File(...).readAsBytes()` 会**永远挂住**
       *    （第一次写本文件时就挂到 3 分钟超时）。
       */
      var fp = 0;
      await t.runAsync(() async {
        final bytes = await File(p).readAsBytes();
        fp = _fnv1a(bytes);
      });
      hashes[mode] = fp.toRadixString(16);
      // ignore: avoid_print
      print('[SHOT] danmaku-proxy-$mode.png  ${r.w}x${r.h}  ${r.bytes} B  fp=${hashes[mode]}');
      expect(r.bytes, greaterThan(1000), reason: '$mode 的图为空');
    }

    expect(hashes['direct'], isNot(hashes['system']),
        reason: 'direct 与 system 渲染完全一致 ⇒ 选中态没变（RadioGroup 没接线）');
    expect(hashes['system'], isNot(hashes['custom']),
        reason: 'system 与 custom 渲染完全一致 ⇒ 选中态没变');
    expect(hashes['direct'], isNot(hashes['custom']),
        reason: 'direct 与 custom 渲染完全一致');
  });

  testWidgets('③ 代理地址框只在 custom 下出现（防止"填了却不生效"）', (t) async {
    // direct：没有地址框
    _seedPrefs(mode: 'direct');
    await t.pumpWidget(_host(const DanmakuSourcePage()));
    await t.pumpAndSettle();
    await _scrollToProxyBlock(t);
    expect(find.widgetWithText(TextField, '代理地址'), findsNothing,
        reason: 'direct 下留着地址框会让用户以为填了就生效');

    // system：没有地址框
    _seedPrefs(mode: 'system');
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump();
    await t.pumpWidget(_host(const DanmakuSourcePage()));
    await t.pumpAndSettle();
    await _scrollToProxyBlock(t);
    expect(find.widgetWithText(TextField, '代理地址'), findsNothing,
        reason: 'system 下留着地址框会让用户以为填了就生效');

    // custom：必须有一个
    _seedPrefs(mode: 'custom', url: 'http://127.0.0.1:7890');
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump();
    await t.pumpWidget(_host(const DanmakuSourcePage()));
    await t.pumpAndSettle();
    await _scrollToProxyBlock(t);
    expect(find.widgetWithText(TextField, '代理地址'), findsOneWidget,
        reason: 'custom 下必须能填地址，否则这个模式没法用');
  });

  testWidgets('④ 诊断行与 resolveDanmakuFindProxy 的实际结果一致', (t) async {
    /*
     * # 这条在验什么
     * ```text
     * 设置页显示的那句「当前：…」必须是 resolve 的**真实结果**，
     * 而不是另一套自己拼的文案 —— 否则会出现
     *   「页面写着走代理 127.0.0.1:7890，实际下发的是 DIRECT」
     * 那种"界面撒谎"，正是本轮 R2 那个 bug 的同型错误。
     * ```
     */
    final cases = <({String mode, String url, String expectInHint})>[
      (mode: 'direct', url: '', expectInHint: '直连'),
      (mode: 'system', url: '', expectInHint: '跟随系统代理'),
      (mode: 'custom', url: 'http://127.0.0.1:7890', expectInHint: 'PROXY 127.0.0.1:7890'),
      // socks 必须给**专门**文案，而不是笼统的"地址无效"
      (mode: 'custom', url: 'socks5://127.0.0.1:1080', expectInHint: '不支持 socks'),
    ];

    for (final c in cases) {
      _seedPrefs(mode: c.mode, url: c.url);
      final m = c.mode == 'system'
          ? DanmakuProxyMode.system
          : (c.mode == 'custom' ? DanmakuProxyMode.custom : DanmakuProxyMode.direct);
      final hint = diagnoseDanmakuProxy(mode: m, url: c.url);

      // ── 页面真的把那句话画出来了吗 ──
      await t.pumpWidget(const SizedBox.shrink());
      await t.pump();
      await t.pumpWidget(_host(const DanmakuSourcePage()));
      await t.pumpAndSettle();
      await _scrollToProxyBlock(t);
      final rendered = find.textContaining(c.expectInHint);
      expect(rendered, findsWidgets,
          reason: '${c.mode}(${c.url}) 的诊断行应含「${c.expectInHint}」，'
              '实际 diagnose=$hint');
      // ignore: avoid_print
      print('[DIAG] ${c.mode} url="${c.url}" => $hint');
    }
  });
}

/// FNV-1a 32 位指纹（只用于"两张图是否逐字节相同"的廉价比较）
int _fnv1a(List<int> bytes) {
  var h = 0x811c9dc5;
  for (final b in bytes) {
    h ^= b;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}
