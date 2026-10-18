@Tags(['native-media'])
// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 2026-10-08（Owner 追加）顶栏与底栏的**显隐联动**
// ═══════════════════════════════════════════════════════════════════════
//
// 用户原话（逐字，附截图）：
// > 现在下面的底栏的会遵循我说的逻辑隐藏了,但是上面的这个也是一样的规则,
// > 而且上面的这个跟下面的 是要联动的,隐藏一起隐藏,
// > 我说的触发条件 触发了,然后也要显示,知道吧
//
// # 改前的两个缺陷（两个都要修，只修一个仍然不联动）
// ```text
// ① 顶栏**从不消失** —— 外层判据是
//      `if (_controlsVisible || _canUseFloatingBack)`
//    而 `_canUseFloatingBack`（player_page.dart:6992）=
//      `Device.isDesktop && _error == null && !_anySheetOpen`
//    ⇒ 桌面端正常播放时**恒为 true** ⇒ 顶栏无条件渲染。
//
// ② 就算把它卸下来，那条渐变条也**不会淡** ——
//    `_applyControlsMotion()` 原来只在 `_showControls()` 里被调，
//    隐藏路径（_armHideTimer 的 Timer 回调）里没人调它
//    ⇒ `_controlsFade.value` 恒 = 1.0
//    ⇒ `Opacity(opacity: 1.0)` 画得和"显示"时**一模一样**。
// ```
//
// # 修法与「联动」的实现
// ```text
// ① `_armHideTimer()` 的隐藏回调里补上 `_applyControlsMotion()`
//    ⇒ 隐藏时动画真的往 0 走；
// ② 顶栏**常挂**（去掉外层 `if`），渐变条的 `visible` 改成
//    `_controlsVisible && _error == null` —— 与底栏**同一个真源**；
// ③ 两条读的是**同一个** `_controlsFade` 实例（宿主传下去）
//    ⇒ 数值必然相等 ⇒ 「隐藏一起隐藏、显示一起显示」是**结构性**保证，
//      不是靠两处各写一遍判据碰巧一致。
// ```
//
// # 为什么「悬浮返回键」不参与联动（有意，不是漏了）
// ```text
// 它是为另一个缺陷加的：控制条藏起来后屏幕上**没有返回口**
// （见 `_FloatingBackButton` 的长注释）。
// ⇒ 它的显隐由 `if (!visible && onFloatingBack != null)` **单独**决定，
//   与那条渐变条解耦 —— 否则「藏了就没法返回」会立刻回归。
// ```
//
// ⚠️ 本文件用**探针**驱动（`debugPlayerHoverControlsForProbe` /
//    `debugPlayerAutoHideControlsForProbe`）而不是 `t.tap`：
//    flutter_tester 里 PlayerPage 整棵树的指针回调都不被调用
//    （见 test/t98 文件头），tap 驱动不了这条路径。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/player/player_bottom_bar.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

/// 挂一个真实 `PlayerPage`（与 t72_jank_test.dart 逐字同源）
Future<void> _mount(WidgetTester t, {bool playing = true}) async {
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  const eps = <Episode>[
    Episode(id: 'ep1', title: '第1集', url: 'https://x.invalid/1.m3u8'),
    Episode(id: 'ep2', title: '第2集', url: 'https://x.invalid/2.m3u8'),
  ];
  await t.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        provider: 'cctv',
        id: 'cctv1',
        title: '联动测试',
        episodes: eps,
        episodeIndex: 0,
        episodeId: eps.first.id,
        episodeTitle: eps.first.title,
        isTv: false,
        isTouchOnly: false,
      ),
    ),
  );
  await t.pump();
  await t.pump();
  /*
   * ★★★ 2026-10-12（fix/bottom-bar-opacity）：必须**先清 `_error`** 底栏才挂得上。
   *
   * flutter_tester 里没有 `sourin_core.dll` / 真网络 ⇒ `_load()` 必然抛错
   * ⇒ `_error != null` ⇒ `_chromeVisible` 恒 false ⇒ 底栏被宿主
   * `ListenableBuilder` 卸成 `SizedBox.shrink()`（顶栏是**常挂**的，所以顶栏有值、
   * 底栏整条不在树上）。`debugPlayerForceBarsForShot()` 清 `_error`/`_errorKind`、
   * 置 `_playing`/`_controlsVisible` 为 true ⇒ 底栏才真的进入 element 树。
   *
   * ⚠️ 少了这一步，本文件所有「底栏读数」都只能是 `null` —— 而改前的假探针
   *    （`return (v, v)`）会把这个 `null` 掩盖成两个相等的数 ⇒ 永远绿。
   *    这正是本次要替换掉的假绿的一环。
   */
  debugPlayerForceBarsForShot();
  await t.pump();
  if (playing) debugPlayerSetPlayingForProbe(true);
  await t.pump();
}

/// 从 element 树读**真实渲染出来的** bar `Opacity`（祖先链含 [isBar] 命中的那个）
///
/// ★ 与 `debugPlayerControlBarsOpacity()` 的分工：
///   · 本函数在**测试侧**独立实现一遍，用 `runtimeType.toString()` 判 `_TopBar`
///     （它是**私有类**，测试 import 不到）⇒ 即使生产探针被改坏，
///     测试这一份仍是独立的真值来源（探针与断言不该共用同一段可能出错的代码）；
///   · `debugPlayerControlBarsOpacity()` 已在 2026-10-12 同步改成读真实渲染值，
///     两处互为对照。
///
/// 返回 `null` = 那条 bar 的 `Opacity` 不在树上（被卸下）。
double? _renderedBarOpacity(WidgetTester t, bool Function(Element) isBar) {
  double? found;
  void walk(Element e) {
    if (found != null) return;
    if (e.widget is Opacity) {
      var hit = false;
      e.visitAncestorElements((a) {
        if (isBar(a)) {
          hit = true;
          return false;
        }
        return true;
      });
      if (hit) {
        found = (e.widget as Opacity).opacity;
        return;
      }
    }
    e.visitChildren(walk);
  }

  walk(t.binding.rootElement!);
  return found;
}

double? _renderedTop(WidgetTester t) =>
    _renderedBarOpacity(t, (e) => e.widget.runtimeType.toString() == '_TopBar');

double? _renderedBottom(WidgetTester t) =>
    _renderedBarOpacity(t, (e) => e.widget.runtimeType.toString() == 'PlayerBottomBar');

/// 底栏是否在 element 树上（真实渲染出的 `PlayerBottomBar` 实例数）
int _bottomBarInTree() => find.byType(PlayerBottomBar).evaluate().length;

/// 把淡出/淡入动画跑到停（260ms 的 token 值，多给一帧余量）
Future<void> _settleMotion(WidgetTester t) async {
  for (var i = 0; i < 12; i++) {
    await t.pump(const Duration(milliseconds: 40));
  }
}

/// 剥掉注释的最小实现（与 `t68_android_adapt_test.dart` 同算法）
///
/// ★ 为什么需要：本文件有几条判据是「**代码里**不该再有 X」，
///   而历史注释为了解释「改前是什么样」会反复提到 X —— 用原文断言必假红。
String _stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  String? quote;
  while (i < src.length) {
    final c = src[i];
    if (quote != null) {
      out.write(c);
      if (c == r'\' && i + 1 < src.length) {
        out.write(src[i + 1]);
        i += 2;
        continue;
      }
      if (c == quote) quote = null;
      i++;
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
      i += 2;
      while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
        i++;
      }
      i += 2;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

/// 依赖真播放器的 libmpv 夹具（与 `test/t61_panel_radius_test.dart` 的
/// `_requireLibmpv()` 同一形状）。
///
/// ★ 为什么缺件时**默认跳过**而不是 `fail`（2026-10-10，task-37 / T11 裁决）：
///   `@Tags(['native-media'])` 让本文件在 CI 上根本不跑（CI 是裸 `flutter test`），
///   而本文件里还有**静态**判据（读 `lib/ui/player_page.dart` 源码），
///   完全不需要 libmpv ⇒ 让整个文件在「合法地没有夹具」的机器上红，既拦不住
///   CI 的回归，又把本机 `--run-skipped --tags native-media` 的例行 sweep 变成
///   假红。缺件是**环境事实**，不是被测代码的缺陷。
///   需要严格时用 `SOURIN_REQUIRE_LIBMPV=1` 一键要回硬失败。
/// ★★ 跨平台候选（2026-10-11，task-53 / CR-15 修）：原来这里写死
/// `build/windows/x64/libmpv/libmpv-2.dll` **一条**路径 ⇒ 在 macOS 上
/// **永远探不到**（即使夹具真的在：Makefile 把它塞进 app 包的
/// `Contents/Frameworks/`）⇒ 本文件 6 条行为用例在 macOS 上恒
/// `markTestSkipped`（门禁在 macOS 上等于不存在），而
/// `SOURIN_REQUIRE_LIBMPV=1` 的严格跑法又会硬失败。候选列表与
/// `test/t61_panel_radius_test.dart:167-200` 逐条一致（本仓既有约定，
/// 见 t61 文件头「为什么必须给显式路径」）。
///
/// ★ `SOURIN_LIBMPV_PATH`：显式指定夹具路径时**只认它** ⇒ 指向不存在的
///   路径就能在**不碰 `build/`** 的前提下真实复现「缺件」那一态
///   （两态实测命令见文件末尾「夹具探测两态」组的注释）。
const String _kLibmpvPathVar = 'SOURIN_LIBMPV_PATH';

/// libmpv 的候选路径（**跨平台** —— 别只写 Windows 那一条）
List<String> _libmpvCandidates() {
  final explicit = Platform.environment[_kLibmpvPathVar];
  if (explicit != null && explicit.isNotEmpty) {
    // ★ 显式指定 ⇒ **只认它**：否则指向不存在的路径也探得到候选里的真夹具，
    //   「缺件」那一态就永远复现不出来。
    return <String>[explicit];
  }
  if (Platform.isWindows) {
    return <String>[
      r'build\windows\x64\libmpv\libmpv-2.dll',
      r'build\windows\x64\runner\Release\libmpv-2.dll',
    ];
  }
  if (Platform.isMacOS) {
    final out = <String>[
      // pod 的 vendored framework（`pod install` 之后）
      'macos/Pods/media_kit_libs_macos_video/Frameworks/'
          'Mpv.xcframework/macos-arm64_x86_64/libmpv-2.dylib',
      'macos/Pods/media_kit_libs_macos_video/Frameworks/'
          'Mpv.xcframework/macos-arm64/libmpv-2.dylib',
    ];
    // `flutter build macos` 之后 libmpv 就在 app 包里
    // （★ app 名不一定是 `sourin_spike` —— 发布版是中文「源影」⇒ 扫目录）
    for (final cfg in const <String>['Release', 'Debug', 'Profile']) {
      final dir = Directory('build/macos/Build/Products/$cfg');
      if (!dir.existsSync()) continue;
      for (final e in dir.listSync()) {
        if (e is Directory && e.path.endsWith('.app')) {
          out.add('${e.path}/Contents/Frameworks/libmpv-2.dylib');
        }
      }
    }
    return out;
  }
  // Linux / 其它：libmpv 由系统包管理器提供
  return <String>[
    '/usr/lib/x86_64-linux-gnu/libmpv.so.2',
    '/usr/lib/libmpv.so.2',
  ];
}

/// 从候选里挑第一个**存在**的文件，返回其**绝对**路径；都没有 ⇒ `null`。
///
/// 纯函数（候选由参数给）⇒ 文件末尾「夹具探测两态」组可以**注入空列表**
/// 把「缺件」态钉死，**不需要**去 move / rename / delete `build/` 下的任何 dll。
String? _probeLibmpvPath(List<String> candidates) {
  for (final rel in candidates) {
    final f = File(rel);
    if (f.existsSync()) return f.absolute.path;
  }
  return null;
}

/// 探测到的 libmpv **绝对**路径；`null` = 夹具缺失
String? _libmpv;

/// 夹具准备（`setUpAll` 用）：探到就初始化 MediaKit，探不到**什么都不做**。
///
/// ⚠️ 探不到时这里**绝不 fail** —— 理由见上面的注释块；守卫下沉到
///   `_requireLibmpv()`，由每个**依赖播放器**的用例自己调（静态判据照常跑）。
void _prepareLibmpvFixture() {
  final candidates = _libmpvCandidates();
  final found = _probeLibmpvPath(candidates);
  if (found == null) {
    // ignore: avoid_print
    print('[LIBMPV] 夹具**缺失** ⇒ 依赖播放器的用例将 markTestSkipped；'
        '候选 = $candidates');
    return;
  }
  _libmpv = found;
  MediaKit.ensureInitialized(libmpv: found);
  // ignore: avoid_print
  print('[LIBMPV] 夹具 = $found');
}

/// 依赖真播放器的用例开头调用：`if (!_requireLibmpv()) return;`
///
/// 返回 `true` = 夹具就绪可继续；`false` = **已标记跳过，调用方必须 return**
/// （`markTestSkipped` 只打标记，**不会**中断当前函数 —— 本地实测：标记之后的
/// 代码照常执行，所以必须紧跟 `return`）。
///
/// 硬失败开关：环境变量 `SOURIN_REQUIRE_LIBMPV=1` ⇒ 缺件时 `fail(...)`。
bool _requireLibmpv() {
  if (_libmpv != null) return true;
  if (Platform.environment['SOURIN_REQUIRE_LIBMPV'] == '1') {
    fail(
      'libmpv 夹具缺失：${File(_libmpvCandidates().first).absolute.path} 不存在'
      '（被 SOURIN_REQUIRE_LIBMPV=1 要求为硬失败）',
    );
  }
  markTestSkipped(
    'libmpv 夹具缺失 ⇒ 依赖播放器的用例无从断言。'
    '手动跑：先 `flutter build windows`（macOS 上 `flutter build macos`）；'
    '候选路径 = ${_libmpvCandidates()}；'
    '要把缺件当失败跑：设 SOURIN_REQUIRE_LIBMPV=1',
  );
  return false;
}

void main() {
  // 夹具准备：探到就 MediaKit.ensureInitialized(同一个已找到的文件)，
  // 探不到**不 fail**；守卫下沉到 `_requireLibmpv()`，由每个**依赖播放器**
  // 的用例自己调（静态判据照常跑）。
  // ★ 初始化与守卫读的是**同一个** `_libmpv` —— 原来两处各算一次
  //   (`_libmpvDll.existsSync()` × 2)，这正是 CR-15 要修的第二半。
  setUpAll(_prepareLibmpvFixture);
  setUp(() => RemoteBridge.instance.stop());
  tearDown(() => RemoteBridge.instance.stop());

  group('★ 顶栏 / 底栏 显隐联动', () {
    /*
     * ★★★ 2026-10-12（fix/bottom-bar-opacity）：本组原来的读数是**假绿**。
     *
     * # 改前的两层假绿
     * ```text
     * ① 探针 `debugPlayerControlBarsOpacity()` 返回 `(v, v)`（两个分量同一个
     *    源）⇒ `o.$1 == o.$2` 从构造上恒真 ⇒ ①②④ 永远绿。
     * ② 底栏在 flutter_tester 里因 `_error != null` 根本不在树上
     *    （`_chromeVisible` 恒 false）—— 但 ① 照样绿（假探针不看树）。
     * ```
     * # 改后
     * ```text
     * · 探针重写成「读 element 树里**真实渲染出来**的 Opacity.opacity」；
     * · `_mount` 补一步 `debugPlayerForceBarsForShot()`（清 `_error`）⇒ 底栏
     *   真的挂上树，读数才可能是 `null` ⇒ 断言才有意义；
     * · 断言补上「底栏 Opacity 非 null 且等于顶栏」⇒ 底栏一旦被冻结成
     *   build 期快照（1.0 / 0.0），本条立刻红。
     * ```
     */
    testWidgets('① ★ 两条控制条**真实渲染**的 Opacity 相等（结构性联动）', (t) async {
      if (!_requireLibmpv()) return;
      await _mount(t);
      // ★ 底栏必须在树上 —— 否则"两条相等"的断言退化成"两条都 null"
      expect(
        _bottomBarInTree(),
        1,
        reason: '★ 前提不成立：底栏不在树上（`_error` 没清干净？）——'
            '那样底栏读数是 null，联动断言无从谈起',
      );
      final top = _renderedTop(t);
      final bottom = _renderedBottom(t);
      expect(top, isNotNull, reason: '★ 顶栏真实渲染的 Opacity 拿不到');
      expect(
        bottom,
        isNotNull,
        reason: '★★ 底栏真实渲染的 Opacity 拿不到 —— 它必须在树上（前提）',
      );
      expect(
        bottom,
        top,
        reason:
            '★★★ 顶栏与底栏**真实渲染**的不透明度必须相等。'
            '不等 ⇒ 有一条把 `fade.value` 冻结成了 build 期快照'
            '（改前底栏就是：恒 1.0 或恒 0.0）—— 这正是 Owner 报的'
            '「错开显示 / 底栏不出现」。',
      );
      expect(top, 1.0, reason: '★ 刚挂载时控制条应当是完全显示的');
    });

    testWidgets('② ★ 触发隐藏条件 ⇒ 两条**真实渲染**的 Opacity 一起淡到 0', (t) async {
      if (!_requireLibmpv()) return;
      await _mount(t);
      expect(_renderedTop(t), 1.0, reason: '前提：先完全显示');

      final hid = debugPlayerAutoHideControlsForProbe();
      expect(
        hid,
        isTrue,
        reason:
            '★ 探针没生效 —— 它要求 _playing==true；'
            '若这里就是 false，后面的读数全部无意义',
      );
      await _settleMotion(t);

      expect(_renderedTop(t), 0.0, reason: '★★ 顶栏没有淡出 —— 这正是用户报的「上面的不消失」');
      // ★ 隐藏到底后底栏可能已被宿主整条卸下（`keepForFade` 窗口走完）
      //   ⇒ 读数允许为 null（= 真的不在了）；若还在树上则必须是 0.0
      //   （不能是 1.0 —— 那正是改前的"维持不透明到最后硬卸载"）。
      final bottom = _renderedBottom(t);
      expect(
        bottom == null || bottom == 0.0,
        isTrue,
        reason:
            '★★ 底栏没有淡出：读数 = $bottom。'
            '改前它在这里恒为 1.0（build 期快照）直到整条被硬卸载；'
            '修后要么已淡到 0 后卸载（null）、要么是 0.0。',
      );
    });

    testWidgets('③ ★ 触发显示条件 ⇒ 两条**真实渲染**的 Opacity 一起回到 1', (t) async {
      if (!_requireLibmpv()) return;
      await _mount(t);
      debugPlayerAutoHideControlsForProbe();
      await _settleMotion(t);
      expect(_renderedTop(t), 0.0, reason: '前提：先藏起来');

      final shown = debugPlayerHoverControlsForProbe();
      expect(shown, isTrue, reason: '★ 晃动应当把 _controlsVisible 翻回 true');
      await _settleMotion(t);

      expect(_renderedTop(t), 1.0, reason: '★★ 顶栏没有回来');
      expect(
        _bottomBarInTree(),
        1,
        reason: '★★ 底栏必须回到树上',
      );
      expect(
        _renderedBottom(t),
        1.0,
        reason:
            '★★ 底栏没有回来：真实渲染的 Opacity = ${_renderedBottom(t)}。'
            '改前它停在 0.0 永不回来（build 期快照 = 隐藏时最后一次整页 build 的值）'
            '—— 这正是 Owner 报的「第二次只出现顶部」。',
      );
    });

    testWidgets('④ ★ 来回切换多轮：两条**真实渲染**的读数每一帧都相等', (t) async {
      if (!_requireLibmpv()) return;
      await _mount(t);
      for (var round = 0; round < 3; round++) {
        debugPlayerAutoHideControlsForProbe();
        // 不 settle 到底，中途也要采样 —— 抓"一个先动、一个后动"
        for (var i = 0; i < 4; i++) {
          await t.pump(const Duration(milliseconds: 20));
          final top = _renderedTop(t);
          final bottom = _renderedBottom(t);
          expect(
            top,
            isNotNull,
            reason: '★ 第 $round 轮隐藏中顶栏读数没了（前提：顶栏常挂）',
          );
          expect(
            bottom,
            isNotNull,
            reason: '★★ 第 $round 轮隐藏中底栏**不在树上**（读数 null）—— '
                '淡出窗口还没走完它就该留着（keepForFade）。顶栏=$top',
          );
          expect(
            bottom,
            top,
            reason:
                '★★★ 第 $round 轮隐藏过程中顶/底**真实渲染**的不透明度不一致'
                '（top=$top, bottom=$bottom）—— 说明有一条是 build 期快照。',
          );
        }
        await _settleMotion(t);
        expect(_renderedTop(t), 0.0);

        debugPlayerHoverControlsForProbe();
        for (var i = 0; i < 4; i++) {
          await t.pump(const Duration(milliseconds: 20));
          final top = _renderedTop(t);
          final bottom = _renderedBottom(t);
          expect(
            bottom,
            top,
            reason: '★★★ 第 $round 轮显示过程中顶/底不一致（top=$top, bottom=$bottom）',
          );
        }
        await _settleMotion(t);
        expect(_renderedTop(t), 1.0);
      }
    });

    testWidgets('⑤ 联动是**动画**不是硬切（存在中间帧）', (t) async {
      if (!_requireLibmpv()) return;
      await _mount(t);
      debugPlayerAutoHideControlsForProbe();
      /*
       * ★ 两次 pump 缺一不可：
       *   AnimationController 的 ticker 在**第一次** tick 上取基准时间
       *   （elapsed 从 0 起算）⇒ 只 pump 一次的话读数仍是起始值 1.0，
       *   会被误判成「动画没被驱动」。
       *   （这正是我第一版的红 —— 假红，不是产品缺陷。）
       */
      await t.pump();
      await t.pump(const Duration(milliseconds: 60));
      final mid = _renderedTop(t);
      expect(
        mid,
        greaterThan(0.0),
        reason: '★ 60ms 就归零 ⇒ 这是**硬切**，不是淡出（用户要求"要有动画"）',
      );
      expect(mid, lessThan(1.0), reason: '★ 60ms 还没开始动 ⇒ 动画没被驱动');
      await _settleMotion(t);
      expect(_renderedTop(t), 0.0);
    });

    // ══════════════════════════════════════════════════════════════════
    //  ★★★ 2026-10-12 新增三条（fix/bottom-bar-opacity）
    //  改前全部**红**，修后全部**绿**（撤销验证读数见交付报告）。
    // ══════════════════════════════════════════════════════════════════

    /// ⑭ 底栏淡出过程中必须**有中间帧**（≥1 个 0<o<1 的采样），
    ///     而不是「恒 1.0 后突然整条卸载」。
    ///
    /// 改前：底栏 Opacity 在隐藏全程恒 1.0（build 期快照），到 fade 归零那一帧
    ///      才被宿主整条卸下 ⇒ 采样里**一个**中间值都没有 ⇒ 本条红。
    /// 修后：底栏与顶栏同步逐帧下降 ⇒ 采到中间值 ⇒ 绿。
    testWidgets('⑭ ★ 底栏淡出**有中间帧**（不是「恒 1.0 后硬卸载」）', (t) async {
      if (!_requireLibmpv()) return;
      await _mount(t);
      expect(_renderedBottom(t), 1.0, reason: '前提：底栏先完全显示');

      debugPlayerAutoHideControlsForProbe();
      await t.pump(); // ticker 取基准时间
      final samples = <double?>[];
      for (var i = 0; i < 12; i++) {
        await t.pump(const Duration(milliseconds: 30));
        samples.add(_renderedBottom(t));
        if (_renderedBottom(t) == null) break; // 已卸载，停止采样
      }
      final mids = samples.whereType<double>().where((v) => v > 0.0 && v < 1.0);
      expect(
        mids.length,
        greaterThanOrEqualTo(1),
        reason:
            '★★★ 底栏淡出过程**没有一个中间帧**（采样=$samples）。'
            '改前就是「恒 1.0 → 突然 null（整条卸载）」⇒ 底栏要么满不透明、'
            '要么消失，没有过渡 —— 正是 Owner 说的"错开显示"。',
      );
    });

    /// ⑮ 底栏淡出过程的不透明度必须**单调不增**（逐帧现读的另一个侧面：
    ///     不能忽高忽低，也不能先不变再跳）。
    ///
    /// 改前：全程 = 1.0（不变）然后 null ⇒ 严格来说"不增"也成立，
    ///       所以本条单独不能红 —— 但它与 ⑭ 联合起来把「恒 1.0 后硬卸载」
    ///       这一态的**两头**都堵死（⑭ 要求有中间值、⑮ 要求不乱跳）。
    /// 真正能红的是 ⑭；⑮ 是防回归（例如有人把动画改成先升后降）。
    testWidgets('⑮ ★ 底栏淡出读数**单调不增**', (t) async {
      if (!_requireLibmpv()) return;
      await _mount(t);
      debugPlayerAutoHideControlsForProbe();
      await t.pump();
      var prev = _renderedBottom(t) ?? 1.0;
      for (var i = 0; i < 12; i++) {
        await t.pump(const Duration(milliseconds: 30));
        final cur = _renderedBottom(t);
        if (cur == null) break; // 卸载
        expect(
          cur,
          lessThanOrEqualTo(prev + 1e-9),
          reason: '★★ 底栏淡出读数**回升**了（$prev → $cur）—— 淡出必须是单调下降',
        );
        prev = cur;
      }
    });

    /// ⑯ 显示到底后**真实渲染**的底栏可见（Opacity ≥ 0.99）且底栏在树上。
    ///
    /// 改前：底栏停在 0.0（build 期快照 = 隐藏时最后一次整页 build 的值）
    ///       ⇒ 读数 < 0.99 ⇒ 本条红。
    /// 修后：走完 `Motion.base` ⇒ 回到 1.0 ⇒ 绿。
    /// 这正是 Owner 的「第二次只出现顶部 / 点暂停才出现」症状的定点回归。
    testWidgets('⑯ ★ 显示到底后**底栏可见**（渲染 Opacity ≥ 0.99 且在树上）', (t) async {
      if (!_requireLibmpv()) return;
      await _mount(t);
      debugPlayerAutoHideControlsForProbe();
      await _settleMotion(t);
      expect(_renderedTop(t), 0.0, reason: '前提：先藏到底');

      debugPlayerHoverControlsForProbe();
      await _settleMotion(t); // 走完 Motion.base

      expect(_bottomBarInTree(), 1, reason: '★★ 底栏必须回到树上');
      final bottom = _renderedBottom(t);
      expect(
        bottom,
        isNotNull,
        reason: '★★ 底栏在树上却拿不到渲染的 Opacity（探针坏了）',
      );
      expect(
        bottom,
        greaterThanOrEqualTo(0.99),
        reason:
            '★★★ 底栏显示到底后**真实渲染**仍不透明（读数=$bottom）。'
            '改前它停在 0.0 永不回来 —— 用户看到「只有顶栏回来、底栏不见」。',
      );
      expect(
        bottom,
        _renderedTop(t),
        reason: '★★ 显示到底后两条必须同时满不透明',
      );
    });

    test('⑪ task-16 定案：独立悬浮返回键已删除（改前它会常驻在画面上）', () {
      final src = File('lib/ui/player_page.dart').readAsStringSync();
      expect(
        src.contains('class _FloatingBackButton'),
        isFalse,
        reason:
            '★★ `_FloatingBackButton` 必须**不存在** —— 它就是 Owner 报的'
            '「全屏左上角这个单独的返回icon,还没消失」那一枚。'
            'lead 定案：控制条收起时它跟着一起淡出；鼠标一动，顶栏连同'
            '**它自己的**返回箭头一起回来。半成品方案 `(1 - f) × 指针在页内` '
            '在全屏下无效（全屏时指针恒在页内）。',
      );
      // ⚠️ 判据对象必须是**剥掉注释后**的源码：那段历史注释里反复提到
      //   `onFloatingBack`（解释「改前是什么样」），用原文断言会假红。
      expect(
        _stripComments(src).contains('onFloatingBack'),
        isFalse,
        reason:
            '★ `onFloatingBack` 是那枚悬浮键的入口，删了它才真的删干净。'
            '（剥注释后仍出现 ⇒ 代码里还有引用没删干净）',
      );
      // ★ 阴性对照：顶栏**自己**的返回箭头必须还在（错误态下还要常显可点）
      expect(
        src.contains('_canUseTopBarBack'),
        isTrue,
        reason:
            '★★ 错误态下顶栏那枚箭头必须仍可用（Owner 专门报过「不能播放时'
            '左上角的返回点不动」）。删悬浮键**不能**连这条一起删掉。',
      );
    });

    test('⑦ 顶栏**不再**被 `|| _canUseFloatingBack` 顶成常显（旧写法已消失）', () {
      final src = File('lib/ui/player_page.dart').readAsStringSync();
      expect(
        src.contains('if (_controlsVisible || _canUseFloatingBack)'),
        isFalse,
        reason:
            '★★ 这就是「上面的这个一直不消失」的那一行 —— 它回来了。'
            '`_canUseFloatingBack` 在桌面端恒 true ⇒ 顶栏无条件渲染。'
            '正确做法：顶栏常挂（去掉外层 if），渐变条看 visible。',
      );
      // 顶栏的挂载点必须**没有**外层 if —— 否则隐藏时它整棵被卸下，
      // 260ms 的淡出根本没机会播（一帧硬切）。
      final i = src.indexOf('                    _TopBar(');
      expect(i, greaterThan(0), reason: '★ `_TopBar(` 的挂载点缩进变了（找不到）');
      final before = src.substring(i - 400, i);
      expect(
        before.contains('if ('),
        isFalse,
        reason:
            '★★ `_TopBar(` 前面又出现了 if —— 那会让顶栏在隐藏时被'
            '整个卸下（硬切，没有淡出动画），用户要求的是要有动画。',
      );
    });

    test('⑧ 顶栏渐变条的 visible 与底栏同源（都是 _controlsVisible）', () {
      final src = File('lib/ui/player_page.dart').readAsStringSync();
      /*
       * ★★★ 2026-10-09 更新（task-7 / Owner 新增缺陷：错误态返回箭头不可点）
       *
       * # 为什么原断言（`visible: _controlsVisible && _error == null,` 单行）必须改
       * ```text
       * 单行形态在错误态下恒 false ⇒ IgnorePointer 挡住顶栏 ⇒ 箭头点不动，
       * 那正是 Owner 报的新缺陷。修法 = 追加一个**互斥**分支：
       *   visible = (_controlsVisible && _error == null) || _canUseTopBarBack
       * 其中 `_canUseTopBarBack` = `_error != null && ...`，与前半段**不可能同时为真**。
       * ```
       * ⇒ 断言改成**等价的多行形态**，判据不变：
       *   ① 顶栏 visible 仍以 `_controlsVisible && _error == null` 为主真源（逐字要求还在）；
       *   ② 追加分支必须是 `_canUseTopBarBack`（**不是**写死 true、不是其它字段）。
       * ⚠️ 若有人把 ① 拿掉（写死 true 或换成别的），本条立刻红 —— 联动保护不丢。
       */
      /*
       * ★★★ T27-13（Owner 第 3 / 5 条「上下栏必须同时消失/显示」）更新
       *
       * # 为什么又改
       * ```text
       * 缺陷④ 之后顶栏正常支仍**内联**自己的判据：
       *   visible = ((_controlsVisible && _error == null)
       *              && !_videoOutputDead && _liveAudioOnlyNotice == null)
       *             || _canUseTopBarBack
       * 而底栏门控是 11 项（多 7 个 !_xSheetOpen）⇒ 两栏各算各的，会分裂。
       * 修法 = 抽 `bool get _chromeVisible`（11 项），顶栏正常支与底栏门控
       *       共读它。判据的**实质不变**：顶栏显隐仍由「控制条总开关」主导，
       *       错误态返回口 `|| _canUseTopBarBack` 仍是互斥分支。
       * ```
       * ⇒ 断言从「顶栏内联的 11 项字面」改为「顶栏读唯一真源 `_chromeVisible`」，
       *   并把 11 项门控的**字面**钉在 `_chromeVisible` 上（不再是渲染点 if）。
       */
      expect(
        src.contains('visible: _chromeVisible || _canUseTopBarBack,'),
        isTrue,
        reason:
            '★ 顶栏 visible 必须 = `_chromeVisible || _canUseTopBarBack` ——'
            '正常支读与底栏**同一个**真源（T27-13），错误态返回口仍是互斥分支。'
            '（改成别的判据、或把 11 项内联回来，本条红。）',
      );
      expect(
        src.contains('_canUseTopBarBack,'),
        isTrue,
        reason:
            '★ task-7 追加的错误态分支必须还是 `_canUseTopBarBack`（互斥分支），'
            '不许换成写死 true 或别的字段',
      );
      // ★ T27-13：唯一真源 `_chromeVisible` 必须存在且含那两条降级判据。
      final iChrome = src.indexOf('bool get _chromeVisible =>');
      expect(iChrome, greaterThanOrEqualTo(0),
          reason: '★ 唯一真源 `_chromeVisible` 不见了（顶/底栏又各算各的门控了）');
      final chromeExpr = src.substring(iChrome, iChrome + 400);
      expect(chromeExpr.contains('!_videoOutputDead'), isTrue,
          reason: '★★ 唯一真源必须含 `!_videoOutputDead` ——'
              '否则「画面无法显示」横幅出现时两栏会分裂（Owner 缺陷④）');
      expect(chromeExpr.contains('_liveAudioOnlyNotice == null'), isTrue,
          reason: '★★ 唯一真源必须含 `_liveAudioOnlyNotice == null`'
              '（同一条"两条横幅都替代底栏"的纪律）');
      expect(chromeExpr.contains('_controlsVisible'), isTrue,
          reason: '★ 唯一真源必须仍以 `_controlsVisible`（控制条总开关）为主真源');
      final iTop = src.indexOf('bool get _canUseTopBarBack =>');
      expect(iTop, greaterThan(0), reason: '★ `_canUseTopBarBack` 不见了');
      final topDef = src.substring(iTop, iTop + 200);
      expect(
        topDef.contains('_error != null'),
        isTrue,
        reason:
            '★★ `_canUseTopBarBack` 必须与前半段**互斥**（含 `_error != null`）——'
            '否则正常播放时它也会让顶栏常显，顶栏就再也不消失了',
      );
      expect(
        topDef.contains('!_anySheetOpen'),
        isTrue,
        reason: '★★ 浮层打开时不许抢返回（与 `_canUseFloatingBack` 同一条纪律）',
      );
      /*
       * ★★★ 2026-10-18（N11 ddb0794 之后修判据）：
       *
       * ```text
       * 原断言：expect(src.contains('if (!_chromeVisible && !keepForFade) {'), isTrue)
       * **已过时** —— N11 把 `keepForFade` 按设计删掉了
       * （职责被 `_bottomOccupied` + ListenableBuilder 吸收）。
       * 实测 grep -c ⇒ 0，唯一出现处是注释。
       *
       * ⚠️ 本文件整个被 skip（dart_test.yaml 的 native-media 标签），
       * 所以这处过时**默认暴露不出来**：
       *   单独跑 ⇒ `+0 ~1: All tests skipped.`（有大字提示）
       *   全量跑 ⇒ grep "All tests skipped" = **0**，只体现为 `~N` 计数器 +1
       * ⇒ 比"红"更隐蔽：红会被人看见，skip 不会。
       *
       * 实证（`--run-skipped --plain-name "⑧"`）：
       *   Expected: true  Actual: <false>
       *   t118_control_bars_link_test.dart 745:7
       * ⇒ **确定过时 + 确定会红**，不是"可能过时"。
       * ```
       *
       * ⇒ 照 `t27_w13_chrome_ssot_test.dart:216-228` 的正确范本改成两条：
       *   ① 反向断言：不许用 `_chromeVisible` 决定卸下底栏（否则第二个真源）
       *   ② 实质断言：只在占据态才卸下
       * 守的是**安全属性**，实现再换写法也不红。
       *
       * ★ 验证方式（默认命令跑不到）：
       *   flutter test test/t118_control_bars_link_test.dart \
       *     --run-skipped --plain-name "⑧" --concurrency=1
       */
      /*
       * ⚠️ 必须**先剥注释**再断言 —— 否则会命中 player_page.dart:15391 的
       * 那行注释（它记录了「改前是什么」，是历史记录，**不该删**）。
       *
       * ★ 我第一次写这条时忘了剥注释，结果反向断言命中注释里的
       *   `if (!_chromeVisible && !keepForFade) return shrink` ⇒ 假红。
       *   这本轮已有同族教训（"命中注释"是 AGENTS.md §8 记的坑之一），
       *   我自己又踩了一次。
       */
      String stripComments(String s) {
        final buf = StringBuffer();
        for (final line in s.split('\n')) {
          final t = line.trimLeft();
          if (t.startsWith('*') ||
              t.startsWith('//') ||
              t.startsWith('/*') ||
              t.startsWith('*/')) {
            continue;
          }
          buf.writeln(line);
        }
        return buf.toString();
      }

      final codeOnly = stripComments(src);

      expect(
        RegExp(r'if\s*\(\s*!\s*_chromeVisible').hasMatch(codeOnly),
        isFalse,
        reason: '★★ 不许用 `_chromeVisible` 决定要不要**卸下**底栏。'
            '底栏显隐的真源是 `_bottomFade`，`_chromeVisible` 若又当装卸判据 '
            '⇒ 就是第二个真源 ⇒ 分裂复发。',
      );
      expect(codeOnly.contains('if (_bottomOccupied) {'), isTrue,
          reason: '★★ 底栏**只在占据态**才卸下。'
              '占据态那块归占据者 —— 留在树里会叠字 + 抢点击。');
    });

    test('⑨ 隐藏路径真的驱动动画（_autoHideNow 里必须调 _applyControlsMotion）', () {
      final src = File('lib/ui/player_page.dart').readAsStringSync();
      final i = src.indexOf('void _autoHideNow() {');
      expect(i, greaterThan(0), reason: '★ `_autoHideNow` 不见了（被改名/删掉）');
      final body = src.substring(i, i + 1600);
      expect(
        body.contains('setState(() => _controlsVisible = false);'),
        isTrue,
        reason: '★ 隐藏动作本身不见了',
      );
      expect(
        body.contains('_applyControlsMotion();'),
        isTrue,
        reason:
            '★★ 隐藏路径没有驱动动画 —— 这正是本次的根因：'
            '`_applyControlsMotion()` 原来只在 `_showControls()` 里调，'
            '⇒ `_controlsFade.value` 恒 1.0 ⇒ 顶栏永远不淡出。',
      );
      expect(
        body.indexOf('_applyControlsMotion();'),
        greaterThan(body.indexOf('setState(() => _controlsVisible = false);')),
        reason:
            '★★ `_applyControlsMotion()` 写在了 setState 之前 ——'
            '它读的是 `_controlsVisible` 的当前值，写在前面会读到旧值 ⇒ 反向。',
      );
    });

    test('⑩ 两条读的是**同一个** _controlsFade 实例（不是各开一条）', () {
      final src = File('lib/ui/player_page.dart').readAsStringSync();
      /*
       * ★★★ 2026-10-09 更新（task-7）：计数口径改成「**引用** `_controlsFade`」
       *
       * # 为什么
       * ```text
       * 改前两处都是裸的 `fade: _controlsFade,`。task-7 后顶栏那两处变成三元：
       *   fade: _canUseTopBarBack ? kAlwaysCompleteAnimation : _controlsFade,
       *   floatingFade: _canUseTopBarBack ? kAlwaysCompleteAnimation : _controlsFade,
       * ⇒ `indexOf('fade: _controlsFade,')` 一处都匹配不到（实测 0，原来断言 2）。
       * ```
       * ★ 判据的**实质**没变：两条必须读**同一个** `_controlsFade` 实例。
       *   现在数的是「`._controlsFade` 的引用次数」= 顶栏 2（fade + floatingFade）
       *   + 底栏 1 = 3；且**声明只有一处**（下一条断言照旧）。
       * ⚠️ 引用次数少于 3 说明有人给某条换了独立动画源 ⇒ 联动失效 ⇒ 本条红。
       */
      final refs = RegExp(r'_controlsFade').allMatches(src).length;
      /*
       * ★★★ 2026-10-10 更新（task-16 定案）：下界从 3 降到 **2**
       * ```text
       * 改前引用点：顶栏 fade + 顶栏 floatingFade + 底栏 fade = 3 处。
       * task-16 定案删掉了「独立悬浮返回键」⇒ floatingFade 那个引用点没了
       * （lead 裁决：控制条收起时悬浮键一起淡出，鼠标一动顶栏连同它自己的
       *   返回箭头一起回来 ⇒ 独立悬浮键已无存在理由）。
       * ⇒ 现在是 顶栏 fade + 底栏 fade = 2 处，**仍然是同一个实例**。
       * ```
       * ★ 判据的**实质**没变：两条必须读**同一个** `_controlsFade` 实例。
       * ⚠️ 红度证明：把顶栏那一处换成 `kAlwaysCompleteAnimation`（或删掉）
       *   ⇒ 引用数掉到 1 ⇒ 本条立刻红。
       */
      expect(
        refs,
        greaterThanOrEqualTo(2),
        reason:
            '★ 顶栏 + 底栏 至少要引用同一个 `_controlsFade` 2 次，'
            '实测 $refs 次。只有同一个实例才能保证两条**每一帧**的不透明度都相等。',
      );
      expect(
        src.contains('fade: _canUseTopBarBack'),
        isTrue,
        reason: '★ task-7 的错误态分支必须仍在（把 fade 钉成常量动画）',
      );
      expect(
        src.contains(': _controlsFade,'),
        isTrue,
        reason:
            '★ 正常态必须**回落到** `_controlsFade`（不是写死常量）——'
            '否则控制条隐藏时顶栏不会淡出，缺陷 2 会回归',
      );
      final decl = RegExp(r'late final Animation<double> _controlsFade =')
          .allMatches(src)
          .length;
      expect(decl, 1, reason: '★ `_controlsFade` 的声明应当只有一处，实测 $decl 处');
    });

    testWidgets('⑥ 静止鼠标**不再**让控制条复活（原缺陷：hover 每帧续命）', (t) async {
      if (!_requireLibmpv()) return;
      await _mount(t);
      debugPlayerAutoHideControlsForProbe();
      await _settleMotion(t);
      final before = debugPlayerControlBarsOpacity()?.$1;
      // 只推进时间，**不**调用任何 hover 探针
      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      final after = debugPlayerControlBarsOpacity()?.$1;
      expect(after, before, reason: '★ 没有任何交互却自己变回来了（$before → $after）');
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  //  ★ 夹具探测的**两态**（纯函数级 —— 不挂播放器、不需要真夹具）
  // ══════════════════════════════════════════════════════════════════════
  //
  // 为什么抽 `_probeLibmpvPath(候选)` 出来：CR-15 要证明「缺件 ⇒ skip」这一态
  // 真的成立，而**不许**去 move / rename / delete `build/` 下的任何 dll
  // （那是别人的构建产物）⇒ 注入候选列表即可把「缺件」钉死。
  //
  // 真夹具两态的**端到端**复现（不碰 build/）：
  //   PowerShell: `$env:SOURIN_LIBMPV_PATH='build/__no_such__.dll'` 然后
  //   `flutter test test/t118_control_bars_link_test.dart --run-skipped --tags native-media`
  //   ⇒ 打印「夹具**缺失**」+ 6 条行为用例 markTestSkipped；
  //   再加 `$env:SOURIN_REQUIRE_LIBMPV='1'` ⇒ 那 6 条 `fail`（硬失败开关仍在）。
  group('★ 夹具探测两态（纯函数，不需要真夹具）', () {
    test('⑫ 候选里没有真文件 ⇒ 探不到（缺件态）', () {
      expect(
        _probeLibmpvPath(const <String>[]),
        isNull,
        reason: '★ 空候选必须探不到 —— 这就是「夹具缺失」那一态的定义',
      );
      expect(
        _probeLibmpvPath(const <String>['build/__no_such_libmpv__.dll']),
        isNull,
        reason: '★ 候选写了但不存在的文件不算命中（否则缺件态会被假命中掩盖）',
      );
    });

    test('⑬ 候选里有真文件 ⇒ 命中，且返回的是**绝对**路径', () {
      final tmp = Directory.systemTemp.createTempSync('libmpv_probe_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final fake = File('${tmp.path}/libmpv-2.dll')..writeAsStringSync('x');
      final hit = _probeLibmpvPath(<String>[
        '${tmp.path}/__nope__.dll',
        fake.path,
      ]);
      expect(hit, isNotNull, reason: '★ 真文件在候选里却探不到 ⇒ 探测函数坏了');
      expect(
        hit,
        fake.absolute.path,
        reason:
            '★ 必须返回**绝对**路径 —— `MediaKit.ensureInitialized(libmpv:)` 收的就是'
            '绝对路径（相对路径在别的 cwd 下会失效）',
      );
    });
  });
}
