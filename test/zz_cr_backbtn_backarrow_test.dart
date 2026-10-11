// ═══════════════════════════════════════════════════════════════════════
//  zz_cr_backbtn_backarrow_test.dart
//  「原本的播放控件消失之后，你有一个返回的控件一直在显示不消失」
// ═══════════════════════════════════════════════════════════════════════
//
//  # 根因（实测得出，不是推测）
//  ```text
//  `bool get _canUseTopBarBack => Device.isDesktop && _error != null && !_anySheetOpen;`
//  （lib/ui/player_page.dart:8028-8029，task-7 引入）
//  ⇒ 桌面端一旦 `_error != null`，它恒为 true ⇒ 顶栏挂载点被钉死：
//      visible: (_controlsVisible && _error == null) || _canUseTopBarBack  →  恒 true
//      fade:    _canUseTopBarBack ? kAlwaysCompleteAnimation : _controlsFade → opacity 恒 1.0
//  ⇒ 而底栏整条被 `_error == null` 那一半门控**整个卸下**（未挂载）。
//  ⇒ 结果：底部控件一条不剩，左上角那枚箭头**满不透明、且参与命中测试**，
//          鼠标不动也一直在 —— 与业主截图逐字吻合。
//  ```
//
//  ⚠️ Lead 交办的线索是 `_FloatingBackButton` 里 `(1.0 - f.value)` 与调用点语义不匹配。
//     **那个类已在 2026-10-09 被 task-16 删除**（本文件末尾「STATIC ③」是逐字证据），
//     透明度算式随之消失（计数 = 0）。真正的残留控件是**顶栏自己**那枚箭头。
//
//  # 判据为什么落在「真被测的行为」上（上一版判据的教训）
//  ```text
//  旧教训：判据数的是某张表的 isActive 条目，而被测函数是「先移出表项、后取消」，
//          两者之间没有观察点 ⇒ 撤掉修复仍然全绿。
//  本文件：观察点 = **动画跑到完全隐藏那一端之后**（_controlsFade.value == 0.0 且
//          _controlsVisible == false），此时读的是箭头**祖先链上的 Opacity 读数**与
//          **一次真实 hitTestOnBinding 的命中路径** —— 二者都直接由
//          `_canUseTopBarBack` 决定，撤掉修复立刻变红（见报告里的负对照）。
//  ```
@Tags(['native-media'])
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/player/player_bottom_bar.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

/// 挂一个真实 `PlayerPage`（与 test/t118_control_bars_link_test.dart 的 `_mount` 逐字同源）
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
        title: '返回键回归',
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
   * ★ 必须显式置 `_playing = true`：`_autoHideNow()` 的第一条判据就是 `_playing`，
   *   而 flutter_tester 里没有真网络 ⇒ 起播必然失败 ⇒ 不置位则「自动隐藏」这条
   *   路径在测试里根本走不到（与 t118 同一条纪律）。
   */
  if (playing) debugPlayerSetPlayingForProbe(true);
  await t.pump();
}

/// 把淡出/淡入动画跑到停（多给一帧余量）
Future<void> _settleMotion(WidgetTester t) async {
  for (var i = 0; i < 12; i++) {
    await t.pump(const Duration(milliseconds: 40));
  }
}

/// 箭头这一帧的全部读数（一次性量齐，供 expect 与报告共用）
class _Arrow {
  _Arrow(this.rect, this.opacity, this.ignoring, this.inHitPath);

  /// 箭头祖先链上最近的那个 `Opacity` 的读数（= 画出来有多深）
  final double? opacity;

  /// 祖先链上是否存在 `IgnorePointer(ignoring: true)`
  final bool ignoring;

  /// 从箭头中心打一次**真实** hitTest，路径里有没有箭头自己的 RenderBox
  final bool inHitPath;
  final Rect? rect;

  /// `gone`：与业主判据同义的「彻底不见了」
  ///
  /// ⚠️ Lead 给的那条 `gone = opacity <= 0.001` 属于已删除的 `_FloatingBackButton`；
  ///   这里在**顶栏自己那枚箭头**上重建同一条判据 —— 不透明度归零，
  ///   且不参与命中测试（两者都要，缺一都可能被 IgnorePointer 单方面「假装」藏掉）。
  bool get gone => (opacity ?? 1.0) <= 0.001 && !inHitPath;

  @override
  String toString() =>
      'opacity=$opacity ignoring=$ignoring inHitPath=$inHitPath gone=$gone';
}

_Arrow _readArrow(WidgetTester t) {
  final p = debugPlayerTopBarBackProbe();
  final rect = p?.$1;
  if (rect == null || rect.width <= 0) {
    return _Arrow(null, p?.$2, p?.$3 ?? false, false);
  }
  /*
   * ★ 判据 `inHitPath` 为什么用「几何相同」而不是「找某个 widget」：
   *   `Opacity` 与 `IgnorePointer` **都不改布局** ⇒ 箭头那块矩形永远在那儿，
   *   所以判据必须是「那个位置**真的有东西接得住命中测试**」。
   *   做法：从箭头中心打一次**真实** hitTestOnBinding，看路径里有没有一个
   *   RenderBox，它的全局矩形与箭头矩形逐点相同。
   */
  final hit = t.hitTestOnBinding(rect.center);
  var inHitPath = false;
  for (final entry in hit.path) {
    final target = entry.target;
    if (target is RenderBox && target.attached && target.hasSize) {
      final r = target.localToGlobal(Offset.zero) & target.size;
      if ((r.left - rect.left).abs() < 0.5 &&
          (r.top - rect.top).abs() < 0.5 &&
          (r.width - rect.width).abs() < 0.5 &&
          (r.height - rect.height).abs() < 0.5) {
        inHitPath = true;
        break;
      }
    }
  }
  return _Arrow(rect, p?.$2, p?.$3 ?? false, inHitPath);
}

/// 底栏是否挂在树上（真实观察点：`PlayerBottomBar` 是**公开类**，测试可 import）
int _bottomBarCount() => find.byType(PlayerBottomBar).evaluate().length;

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
/// ★★ 跨平台候选（2026-10-11，task-53 / CR-16 修）：原来这里写死
/// `build/windows/x64/libmpv/libmpv-2.dll` **一条**路径 ⇒ 在 macOS 上
/// **永远探不到**（即使夹具真的在：Makefile 把它塞进 app 包的
/// `Contents/Frameworks/`）⇒ 本文件 ①②③ 三条**行为**用例在 macOS 上恒
/// `markTestSkipped`（这条门禁在 macOS 上等于不存在），而
/// `SOURIN_REQUIRE_LIBMPV=1` 的严格跑法又会硬失败。候选列表与
/// `test/zz_cr_panel_notch_test.dart:83-112`（以及
/// `test/t61_panel_radius_test.dart:167-200`）逐条一致 —— 本仓既有约定。
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
  //   (`_libmpvDll.existsSync()` × 2)，这正是 CR-16 要修的第二半。
  setUpAll(_prepareLibmpvFixture);
  setUp(() => RemoteBridge.instance.stop());
  tearDown(() => RemoteBridge.instance.stop());

  group('★ 控制条收起后，左上角返回箭头必须跟着消失', () {
    testWidgets('① 错误态：自动隐藏跑到底 ⇒ gone == true 且不参与命中测试',
        (t) async {
      if (!_requireLibmpv()) return;
      await _mount(t);

      // 先把 flutter_tester 天然的「起播失败」清掉，再复现业主那条路径：
      // 错误态 + 播放中（`_playing == true` ⇒ 3 秒规则**会**收控制条）。
      expect(debugPlayerForceBarsForShot(), isTrue, reason: '★ 截图探针没生效');
      await _settleMotion(t);
      debugPlayerInjectStreamErrorForProbe('起播失败：回归测试');
      await _settleMotion(t);

      // ── 前提 1：底栏已被 `_error == null` 那一半门控整个卸下（业主截图的底色）
      expect(
        _bottomBarCount(),
        0,
        reason: '★ 前提不成立：底栏还在树上 ⇒ 复现的不是业主那条状态',
      );

      // ── 前提 2：错误态下那枚箭头此刻**是**可见可点的（task-7 的业主要求，
      //    顺带证明「顶栏没被整体卸下」）
      final shown = _readArrow(t);
      expect(shown.inHitPath, isTrue, reason: '★ 前提不成立：错误态下箭头本该可点');

      // ── 动作：走生产那条「停手 3 秒」规则，把控制条收到底
      expect(
        debugPlayerAutoHideControlsForProbe(),
        isTrue,
        reason: '★ `_autoHideNow()` 没生效（它要求 `_playing`）',
      );
      await _settleMotion(t);

      // ── 观察点必须真的落在「动画到达完全隐藏那一端」之后（见文件头的教训段）
      expect(
        debugPlayerControlsVisibleForProbe(),
        isFalse,
        reason: '★ 前提不成立：`_controlsVisible` 还是 true ⇒ 观察点没落在隐藏之后',
      );
      expect(
        debugPlayerControlBarsOpacity()!.$1,
        0.0,
        reason: '★ 前提不成立：淡出动画还没跑到 0 ⇒ 观察点没落在隐藏端',
      );

      // ── ★★★ 判据本体：这才是业主报的缺陷
      final after = _readArrow(t);
      print('① 隐藏到底后箭头读数 = $after');
      expect(
        after.opacity,
        0.0,
        reason:
            '★★ 底部控件已经全部收起，左上角那枚返回箭头却**满不透明**。根因：'
            '`_canUseTopBarBack` 在错误态恒为 true ⇒ 顶栏的 `fade` 被钉成 '
            '`kAlwaysCompleteAnimation`（不透明度恒 1.0），'
            '它把「控制条已收起」这个状态整个绕过去了。',
      );
      expect(
        after.inHitPath,
        isFalse,
        reason:
            '★★ 箭头在控制条收起后**仍然参与命中测试** ⇒ 画面上那个常驻控件'
            '不只是看得见，还点得动（业主原话「一直在显示不消失」）。',
      );
      expect(
        after.gone,
        isTrue,
        reason: '★★ gone 必须为 true（不透明度归零 + 不参与命中测试）',
      );
    });

    testWidgets('② 对照：鼠标一动，箭头必须立刻回来（不许被我一并修掉）', (t) async {
      if (!_requireLibmpv()) return;
      await _mount(t);
      expect(debugPlayerForceBarsForShot(), isTrue);
      await _settleMotion(t);
      debugPlayerInjectStreamErrorForProbe('起播失败：回归测试');
      await _settleMotion(t);

      debugPlayerAutoHideControlsForProbe();
      await _settleMotion(t);
      expect(_readArrow(t).gone, isTrue, reason: '★ 前提：先藏干净');

      expect(debugPlayerHoverControlsForProbe(), isTrue, reason: '★ hover 没把控制条叫回来');
      await _settleMotion(t);

      final back = _readArrow(t);
      print('② 鼠标一动后箭头读数 = $back');
      expect(
        back.opacity,
        1.0,
        reason:
            '★★ 收起时不该有箭头，一动就该满不透明地回来（业主第 3 条的'
            '「鼠标悬浮即全部显示」不许被这次修复破坏）。',
      );
      expect(
        back.inHitPath,
        isTrue,
        reason: '★★ 鼠标一动之后返回箭头必须重新可点（否则用户回不去）',
      );
    });

    testWidgets('③ 对照：无错误路径的「收起即消失」不许回归', (t) async {
      if (!_requireLibmpv()) return;
      await _mount(t);
      expect(debugPlayerForceBarsForShot(), isTrue);
      await _settleMotion(t);
      expect(debugPlayerErrorForProbe(), isNull, reason: '★ 前提：此刻没有错误');

      final shown = _readArrow(t);
      expect(shown.opacity, 1.0, reason: '★ 前提：控件显示时箭头是满的');
      expect(shown.inHitPath, isTrue, reason: '★ 前提：控件显示时箭头可点');

      expect(debugPlayerAutoHideControlsForProbe(), isTrue);
      await _settleMotion(t);

      final after = _readArrow(t);
      print('③ 无错误·隐藏到底后箭头读数 = $after');
      expect(after.gone, isTrue, reason: '★ 无错误路径本来就该消失，不许回归');
    });

    test('④ 静态：`_canUseTopBarBack` 必须受 `_controlsVisible` 约束', () {
      final src = File('lib/ui/player_page.dart').readAsStringSync();
      final i = src.indexOf('bool get _canUseTopBarBack =>');
      expect(i, greaterThan(0), reason: '★ `_canUseTopBarBack` 不见了');
      final def = src.substring(i, i + 200);
      /*
       * ★ 为什么要有这条静态守卫：① ③ 是行为判据，但如果有人把顶栏改成
       *   「整体在 `_controlsVisible` 为假时挂一个 `if`」也能让 ① 变绿，
       *   而那会让**错误态下**顶栏整棵被卸下（task-7 的业主要求回归）。
       * ⇒ 因此额外要求：错误态那条分支**本身**也要看 `_controlsVisible`。
       */
      expect(
        def.contains('_controlsVisible'),
        isTrue,
        reason:
            '★★ `_canUseTopBarBack` 不看 `_controlsVisible` ⇒ 桌面端错误态下'
            '顶栏被钉成常显 ⇒ 「控制条收起后仍有残留控件」必然复发。',
      );
      // 阴性对照：互斥性与浮层纪律不许被顺手删掉（t118 ⑧ 也盯着这两条）
      expect(def.contains('_error != null'), isTrue, reason: '★ 必须与前半段互斥');
      expect(def.contains('!_anySheetOpen'), isTrue, reason: '★ 浮层打开时不许抢返回');
    });

    test('⑤ STATIC lead 线索已被删除 —— 真正的残留控件是顶栏自己那枚', () {
      final src = File('lib/ui/player_page.dart').readAsStringSync();
      expect(
        RegExp(r'class _FloatingBackButton').allMatches(src).length,
        0,
        reason: '★ `_FloatingBackButton` 应已被 task-16 删除（若它回来，本文件判据要重做）',
      );
      expect(
        RegExp(r'1\.0 - f\.value').allMatches(src).length,
        0,
        reason: '★ Lead 引用的那条透明度算式已随该类删除 ⇒ 线索指向的类不存在',
      );
      // 阳性对照：左上角**唯一**那枚箭头仍属于顶栏（真正的被测对象）
      expect(
        RegExp(r'Icons\.arrow_back').allMatches(src).length,
        1,
        reason: '★ 玩家页只应有顶栏这一枚返回箭头',
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  //  ★ 夹具探测的**两态**（纯函数级 —— 不挂播放器、不需要真夹具）
  // ══════════════════════════════════════════════════════════════════════
  //
  // 为什么抽 `_probeLibmpvPath(候选)` 出来：CR-16 要证明「缺件 ⇒ skip」这一态
  // 真的成立，而**不许**去 move / rename / delete `build/` 下的任何 dll
  // （那是别人的构建产物）⇒ 注入候选列表即可把「缺件」钉死。
  //
  // 真夹具两态的**端到端**复现（不碰 build/）：
  //   PowerShell: `$env:SOURIN_LIBMPV_PATH='build/__no_such__.dll'` 然后
  //   `flutter test test/zz_cr_backbtn_backarrow_test.dart --run-skipped --tags native-media`
  //   ⇒ 打印「夹具**缺失**」+ ①②③ 三条行为用例 markTestSkipped；
  //   再加 `$env:SOURIN_REQUIRE_LIBMPV='1'` ⇒ 那 3 条 `fail`（硬失败开关仍在）。
  group('★ 夹具探测两态（纯函数，不需要真夹具）', () {
    test('⑥ 候选里没有真文件 ⇒ 探不到（缺件态）', () {
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

    test('⑦ 候选里有真文件 ⇒ 命中，且返回的是**绝对**路径', () {
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
