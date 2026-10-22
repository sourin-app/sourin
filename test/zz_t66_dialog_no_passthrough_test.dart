// ═══════════════════════════════════════════════════════════════════════
//  R3-④ 弹窗遮罩双击的**落点必须无害**
// ═══════════════════════════════════════════════════════════════════════
//
// # 背景：为什么不是"不许透传"，而是"落点必须无害"
//
// ```text
// 我先试图让外壳**完全不透传**，两条路都实测不成立
// （详见 .probe/t66_r3_listener_attempt.md）：
//   ① 遮罩注册 DoubleTapGestureRecognizer
//      ⇒ 透传修好了，但遮罩**单击关窗**要等 300ms 双击窗口
//        ⇒ 每次点遮罩都变卡（高频主路径受损，t99/t70 各红一条）
//   ② Listener 在指针层自己判双击
//      ⇒ 关窗那一刻面板就被调用方 setState 移除
//        ⇒ 任何"关窗后屏障"都活不过它（实测 below=1）
// ⇒ 二者不可兼得，这是时序上的必然。
// ```
//
// ⇒ 换方向：**接受透传，但保证落点无害**。
//   本轮在 `player_page.dart` 的播放区补了守卫：
//   ```dart
//   onTap: _anySheetOpen ? null : _togglePlay,
//   ```
//   面板开着时，第 2 击落到播放区**什么也不做**。
//
// # 本文件守什么
//
// ```text
// ① 面板关时，单击播放区 ⇒ onTap 正常触发（不许修坏）
// ② 面板开时，单击播放区 ⇒ onTap **不**触发
// ③ 面板开时，遮罩双击 ⇒ 第 2 击即使落地，落点也必须无害
// ④ closeEnabled=false 时同样成立
// ```
//
// ⚠️ 本文件**不测**外壳层"完全不透传" —— 那条已被证明不可行，
//    硬测它只会逼后来的人去改坏外壳（又回到 300ms 延迟）。

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/app_dialog_shell.dart';

/// 复刻播放页的守卫口径 + **关窗后的 350ms 守卫保持**。
///
/// ★ 刻意**复制**语义而不是 import 真页面 ——
///   真播放页依赖 libmpv / FFI，测试环境挂不起来。
///
/// ⚠️⚠️ **这个复制品有假绿风险，已由第 ⑤ 条源码级断言 + 第 ⑥ 条对照兜住**：
///   实测过——把产品代码的守卫删掉后，本文件的行为断言③**仍然是绿的**
///   （它测的是这个复制品），只有源码级断言⑤变红。
///   ⇒ ③ 证明机理对，⑤ 证明产品真的用了这个机理，⑥ 证明③不是恒真。
class _FakePlayer extends StatefulWidget {
  const _FakePlayer({
    required this.panelOpen,
    required this.onTogglePlay,
    this.onPanelClosed,
    this.holdGuardAfterClose = true,
  });

  final bool panelOpen;
  final VoidCallback onTogglePlay;

  /// 面板从开到关的那一刻回调（产品里是 `_holdSheetGuard()` 的挂点）
  final VoidCallback? onPanelClosed;

  /// 关窗后是否让守卫多站 350ms。
  ///
  /// ★ 传 `false` 用来**复现**那个不生效的旧修法
  ///   （`_anySheetOpen ? null : _togglePlay`）—— 见断言 ⑥。
  final bool holdGuardAfterClose;

  @override
  State<_FakePlayer> createState() => _FakePlayerState();
}

class _FakePlayerState extends State<_FakePlayer> {
  bool _guardHold = false;

  @override
  void didUpdateWidget(_FakePlayer old) {
    super.didUpdateWidget(old);
    // ★ 复刻 `_holdSheetGuard()`：面板刚关 ⇒ 守卫多站 350ms
    if (old.panelOpen && !widget.panelOpen && widget.holdGuardAfterClose) {
      widget.onPanelClosed?.call();
      setState(() => _guardHold = true);
      Future<void>.delayed(const Duration(milliseconds: 350), () {
        if (mounted) setState(() => _guardHold = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final guarded = widget.panelOpen || _guardHold;
    return m.GestureDetector(
      behavior: m.HitTestBehavior.opaque,
      // ★ 与 player_page.dart 的播放区 onTap 同一口径：
      //   `(_anySheetOpen || _sheetGuardHold) ? null : _togglePlay`
      onTap: guarded ? null : widget.onTogglePlay,
      child: const m.ColoredBox(color: m.Color(0xFF101418)),
    );
  }
}

void main() {
  group('R3-④ 遮罩双击的落点必须无害', () {
    testWidgets('★★★ ① 面板关 ⇒ 单击播放区仍能暂停/播放（不许修坏）',
        (t) async {
      t.view.physicalSize = const Size(900, 700);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      var toggles = 0;
      await t.pumpWidget(m.MaterialApp(
        theme: AppTheme.themeFor(Brightness.dark),
        themeAnimationDuration: Duration.zero,
        home: m.Material(
          child: _FakePlayer(panelOpen: false, onTogglePlay: () => toggles++),
        ),
      ));
      await t.pump();

      await t.tapAt(const Offset(450, 350));
      await t.pump();

      expect(toggles, 1,
          reason: '★★★ 面板没开时，单击画面必须能播放/暂停 —— '
              '这是最高频的播放操作，绝不能被这次的守卫弄坏');
    });

    testWidgets('★★★ ② 面板开 ⇒ 单击播放区**不**暂停', (t) async {
      t.view.physicalSize = const Size(900, 700);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      var toggles = 0;
      await t.pumpWidget(m.MaterialApp(
        theme: AppTheme.themeFor(Brightness.dark),
        themeAnimationDuration: Duration.zero,
        home: m.Material(
          child: m.Stack(children: [
            Positioned.fill(
              child: _FakePlayer(panelOpen: true, onTogglePlay: () => toggles++),
            ),
            Positioned.fill(
              child: AppDialogShell(
                title: '弹幕设置',
                onClose: () {},
                fill: false,
                motion: true,
                child: const m.SizedBox(height: 260),
              ),
            ),
          ]),
        ),
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));

      // 点遮罩区（卡片外，屏幕顶部）
      await t.tapAt(const Offset(20, 20));
      await t.pump(const Duration(milliseconds: 400));

      expect(toggles, 0,
          reason: '★★★ 面板开着时，点遮罩关闭**不许**顺手把视频暂停 —— '
              '用户此刻在调设置，不是在看画面');
    });

    testWidgets('★★★ ③ 面板开 ⇒ 遮罩双击 ⇒ 第 2 击落地也无害', (t) async {
      /*
       * ★ 这条就是用户报的缺陷场景本身。
       *
       * 注意断言的是 **toggles == 0**，不是"没有透传" ——
       * 因为透传是**已知且接受**的（外壳层修不掉，见文件头）。
       * 我们要保证的是：透传落下去的那一下**没有副作用**。
       */
      t.view.physicalSize = const Size(900, 700);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      var toggles = 0;
      var panelOpen = true;
      late StateSetter ss;

      await t.pumpWidget(m.MaterialApp(
        theme: AppTheme.themeFor(Brightness.dark),
        themeAnimationDuration: Duration.zero,
        home: m.Material(
          child: StatefulBuilder(builder: (ctx, s) {
            ss = s;
            return m.Stack(children: [
              Positioned.fill(
                child: _FakePlayer(
                  panelOpen: panelOpen,
                  onTogglePlay: () => toggles++,
                  // ★ 复刻产品里 `_holdSheetGuard()` 的挂点
                  onPanelClosed: () {},
                ),
              ),
              if (panelOpen)
                Positioned.fill(
                  child: AppDialogShell(
                    title: '弹幕设置',
                    onClose: () => ss(() => panelOpen = false),
                    fill: false,
                    motion: true,
                    child: const m.SizedBox(height: 260),
                  ),
                ),
            ]);
          }),
        ),
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));

      // ★ 遮罩区双击（用户报的那个动作）
      await t.tapAt(const Offset(20, 20));
      await t.pump(const Duration(milliseconds: 40));
      await t.tapAt(const Offset(20, 20));
      await t.pump(const Duration(milliseconds: 400));

      expect(panelOpen, isFalse, reason: '前提：第 1 击确实关窗了');
      expect(toggles, 0,
          reason: '★★★ 双击关窗时，第 2 击落到播放区**不许暂停视频** —— '
              '这是本轮要修的缺陷本身');
    });

    testWidgets('★★ ④ closeEnabled=false ⇒ 双击既不关窗也不暂停', (t) async {
      t.view.physicalSize = const Size(900, 700);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      var toggles = 0;
      await t.pumpWidget(m.MaterialApp(
        theme: AppTheme.themeFor(Brightness.dark),
        themeAnimationDuration: Duration.zero,
        home: m.Material(
          child: m.Stack(children: [
            Positioned.fill(
              child: _FakePlayer(panelOpen: true, onTogglePlay: () => toggles++),
            ),
            Positioned.fill(
              child: AppDialogShell(
                title: '忙碌中',
                closeEnabled: false,
                onClose: () {},
                fill: false,
                motion: true,
                child: const m.SizedBox(height: 260),
              ),
            ),
          ]),
        ),
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));

      await t.tapAt(const Offset(20, 20));
      await t.pump(const Duration(milliseconds: 40));
      await t.tapAt(const Offset(20, 20));
      await t.pump(const Duration(milliseconds: 400));

      expect(find.byType(AppDialogShell), findsOneWidget,
          reason: '★★ closeEnabled=false ⇒ 不许关窗');
      expect(toggles, 0, reason: '★★ 也不许因此暂停视频');
    });

    // ══════════════════════════════════════════════════════════════════
    //  ⑤ ★ 源码级：把产品代码的守卫口径钉死
    // ══════════════════════════════════════════════════════════════════
    test('★★★ ⑤ 产品代码里播放区的 onTap 必须带 _anySheetOpen 守卫', () {
      /*
       * ★ 为什么需要这条：
       *   上面 4 条用的是 `_FakePlayer`（**复制**了守卫口径），
       *   因为真播放页依赖 libmpv / FFI，测试环境挂不起来。
       *   ⇒ 若将来有人把 `player_page.dart` 的守卫**改回去/改错**，
       *     上面 4 条**仍然是绿的**（它们测的是复制品）⇒ 假绿。
       *   ⇒ 这条源码级断言补上那处缺口：
       *     直接读产品文件，确认口径就是 `_anySheetOpen ? null : _togglePlay`。
       */
      final src = File('lib/ui/player_page.dart').readAsStringSync();
      expect(
        RegExp(r'onTap:\s*\(_anySheetOpen\s*\|\|\s*_sheetGuardHold\)'
                r'\s*\?\s*null\s*:\s*_togglePlay')
            .hasMatch(src),
        isTrue,
        reason: '★★★ 播放区的 onTap 必须写成 '
            '`(_anySheetOpen || _sheetGuardHold) ? null : _togglePlay` —— '
            '只写 _anySheetOpen **不够**（第 1 击就把面板关掉了，'
            '第 2 击到达时守卫已撤），必须靠 _sheetGuardHold 多站 350ms。',
      );
      // 衰减挂点必须真的接到关闭路径上
      expect(
        RegExp(r'_holdSheetGuard\(\);').allMatches(src).length,
        greaterThanOrEqualTo(2),
        reason: '★★★ `_holdSheetGuard()` 必须接在弹幕设置面板与导入面板的 '
            'onClose 上（至少 2 处）',
      );
      // 反向：不许再出现无守卫的裸 `onTap: _togglePlay,`
      expect(
        RegExp(r'onTap:\s*_togglePlay\s*,').hasMatch(src),
        isFalse,
        reason: '★★★ 不许再有裸的 `onTap: _togglePlay,`（无守卫版）',
      );
    });

    // ══════════════════════════════════════════════════════════════════
    //  ⑥ ★★★ 反向验证：复现"只写 _anySheetOpen"的旧修法 ⇒ 必须红
    // ══════════════════════════════════════════════════════════════════
    testWidgets('★★★ ⑥ 旧修法（关窗即撤守卫）必须被抓到', (t) async {
      /*
       * ★ 这条是本门禁的**自证**，证明 ③ 不是恒真。
       *
       * 我实测过：把产品代码的守卫删掉后，③ **仍然是绿的**
       * （因为 ③ 测的是 `_FakePlayer` 复制品，不是产品代码），
       * 那次注入只有源码级 ⑤ 变红。
       *
       * ⇒ 补这一条：让"旧修法"的机理（关窗后**不**保持守卫）
       *   在同一个复制品上跑，断言它**必然暂停视频**。
       *   ③（新机理 ⇒ 不暂停）与 ⑥（旧机理 ⇒ 暂停）构成对照，
       *   证明 ③ 测的确实是那个 350ms 保持。
       */
      t.view.physicalSize = const Size(900, 700);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      var toggles = 0;
      var panelOpen = true;
      late StateSetter ss;

      await t.pumpWidget(m.MaterialApp(
        theme: AppTheme.themeFor(Brightness.dark),
        themeAnimationDuration: Duration.zero,
        home: m.Material(
          child: StatefulBuilder(builder: (ctx, s) {
            ss = s;
            return m.Stack(children: [
              Positioned.fill(
                child: _FakePlayer(
                  panelOpen: panelOpen,
                  onTogglePlay: () => toggles++,
                  // ★ 旧修法：关窗后**不**保持守卫
                  holdGuardAfterClose: false,
                ),
              ),
              if (panelOpen)
                Positioned.fill(
                  child: AppDialogShell(
                    title: '弹幕设置',
                    onClose: () => ss(() => panelOpen = false),
                    fill: false,
                    motion: true,
                    child: const m.SizedBox(height: 260),
                  ),
                ),
            ]);
          }),
        ),
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));

      await t.tapAt(const Offset(20, 20));
      await t.pump(const Duration(milliseconds: 40));
      await t.tapAt(const Offset(20, 20));
      await t.pump(const Duration(milliseconds: 400));

      expect(toggles, 1,
          reason: '★★★ 旧修法**必须**复现缺陷（暂停 1 次）—— '
              '若这里变 0，说明 ③ 的对照失效、门禁是假绿');
    });
  });
}
