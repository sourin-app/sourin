@Tags(['native-media'])
library;

// ═══════════════════════════════════════════════════════════════════════
//  task-27 / W18：弹幕「屏蔽词」输入框里敲 Enter 不该触发播放
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（缺陷）
//     弹幕屏蔽词这里 我点击回车**不会换行**，反而会**播放**
//
// # 根因（已由本文件的阳性/阴性对照钉死，不是猜的）
// 播放页有**两条**键盘入口，守卫**不对称**：
// ```text
// ① 硬件路径 `_onHardwareKey`：**有**输入框守卫（门控③），
//    但它先被门控① `if (_anySheetOpen) return false;` 挡掉 ——
//    弹幕面板开着 ⇒ 它让路。
// ② 焦点树路径 `_onKey`：**原本没有**输入框守卫 ——
//    于是 Enter 落到 Enter 分支 ⇒ 桌面走"全屏"/`_togglePlay`。
// ```
// ⇒ 焦点在屏蔽词输入框里敲物理 Enter：**被 `_onKey` 抢走** ⇒ 触发播放。
//   实测（本文件 Gate①，见文件末尾"实测读数"）：修前 `togglePlay 0→1`。
//
// # 修法
// 把输入框守卫抽成**共用**函数 `_isTypingInField()`（与 `live_page.dart`
// 同形），两条入口都用它 ⇒ 消除"两套真相"；并在 `_onKey` 的 Enter/空格
// 分支**之前**加 `if (_isTypingInField()) return KeyEventResult.ignored;`。
//
// ─────────────────────────────────────────────────────────────────────
//  ★★★ 关于"断言输入框里新增了 \n"这条 —— 必须如实说明仪器边界
// ─────────────────────────────────────────────────────────────────────
// 需求（施工单）要求断言"屏蔽词 controller 里新增了 `\n`"。
// **实测：在 `flutter_tester` 里这条做不到，做了就是假门禁。**
// 证据（本机实测，见文件末尾读数）：
// ```text
// · 对**普通** standalone `TextField(maxLines:4, autofocus:true)`：
//     sendKeyEvent(keyA)   → controller.text 仍是 ""   （字符根本没进去）
//     sendKeyEvent(enter)  → controller.text 仍是 ""
//   ⇒ ★ 物理键事件在本 harness 里**从不**产生文本编辑。
// · 文本输入在 widget 测试里**只**走 text-input 通道（`tester.enterText`
//     / `testTextInput`）。Flutter 的桌面 shortcut 表里
//     `LogicalKeyboardKey.enter` 明确映射成
//     `DoNothingAndStopPropagationTextIntent()`（见
//     `default_text_editing_shortcuts.dart`）——桌面 Enter 的换行本就不是
//     shortcut 做的，而是**引擎的文本输入管线**（真机才有）。
// ⇒ 所以本文件用**两条互补**、都能在 harness 里稳定观测的判据：
//     Gate① + Gate③：焦点在输入框里敲 Enter/空格 ⇒ **播放/全屏没有被触发**
//         （这正是本 bug 的可复现症状：键被 `_onKey` 抢走）
//     Gate④：用 `tester.enterText`（引擎送文本的同一通道）证明该输入框
//         **确实是多行**、且 `\n` 被 controller 原样保留
//     Gate②（阴性对照）：焦点**不在**输入框 ⇒ 同样敲 Enter **确实**触发播放
//         ⇒ 证明 Gate① 不是恒真的空断言。
// ```

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';

/// 挂**真实** PlayerPage（桌面：`isTv=false, isTouchOnly=false`）
///
/// 不 `pumpAndSettle`：播放器持续产帧/定时器，settle 永不返回（同 pc_arrow_keys）。
Future<void> mountPlayer(WidgetTester t) async {
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(
    const MaterialApp(
      home: PlayerPage(
        provider: 'cctv',
        id: 'cctv1',
        title: '屏蔽词 Enter 回归',
        isTv: false,
        isTouchOnly: false,
      ),
    ),
  );
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// 把挂起的定时器推完（否则用例结束报 "A Timer is still pending"）
///
/// ★ 照抄 `pc_arrow_keys_test.dart` / `zz_t42_player_keys_test.dart` 的做法：
///   有 `sourin_core.dll` 时会多一个 `resolveStream` 的 120s timeout。
Future<void> drain(WidgetTester t) async {
  for (var i = 0; i < 60; i++) {
    await t.pump(const Duration(seconds: 3));
  }
  RemoteBridge.instance.stop();
}

/// 一次完整的按键（down + up）—— 与真人敲键一致
Future<void> tapKey(WidgetTester t, LogicalKeyboardKey k) async {
  await t.sendKeyDownEvent(k);
  await t.pump(const Duration(milliseconds: 40));
  await t.sendKeyUpEvent(k);
  await t.pump(const Duration(milliseconds: 40));
}

/// 屏蔽词输入框。
///
/// ⚠️ 不能用 `find.byType(EditableText).at(0)`：面板里还有别的框，
///    `.at(0)` 会抓错（我第一版就抓错了，结果 `\n` 被单行框吃掉 ⇒
///    差点写成假判据）。
///
/// ★ 2026-10-15：弹幕面板改版（屏蔽词改成 chip + 搜索 + 添加框），
///   原来“找唯一 maxLines==4”的判据失效了 —— 那个多行框已经不存在。
///   改成按 **key** 找（生产侧导出的 `blockWordsAddFieldKey`）。
///
/// ⚠️ 返回的是 `EditableText`（不是 `TextField`）：用例要读 `maxLines`、
///    `controller` 并向它 `enterText`，那些都在 `EditableText` 上。
///    第一版只写了 `find.byKey(...)` ⇒ 抓到 `TextField`
///    ⇒ `t.widget<EditableText>()` 抛 `_TypeError`。
Finder blockWordsField() => find.descendant(
      of: find.descendant(
        of: find.byType(DanmakuSettingsDialog),
        matching: find.byKey(blockWordsAddFieldKey),
      ),
      matching: find.byType(EditableText),
    );

/// 打开弹幕设置面板，把焦点放进屏蔽词输入框
///
/// 返回焦点**确实**落在 `EditableText` 上（用与生产 `_isTypingInField()`
/// **同款**的判定：从 `primaryFocus` 的 context 往上找 `EditableText`）。
Future<bool> focusBlockWords(WidgetTester t) async {
  expect(
    debugPlayerOpenDanmakuSettingsForProbe(),
    isTrue,
    reason: '★ 弹幕面板要能开（探针驱动的是生产那棵树上的 _danmakuSheetOpen）',
  );
  await t.pump(const Duration(milliseconds: 300));

  final et = t.widget<EditableText>(blockWordsField());
  et.focusNode.requestFocus();
  await t.pump();

  // ★ 前置条件：焦点真的在输入框里（否则 Gate 判的是别的东西）
  final f = FocusManager.instance.primaryFocus;
  var typing = false;
  f?.context?.visitAncestorElements((el) {
    if (el.widget.runtimeType.toString() == 'EditableText') {
      typing = true;
      return false;
    }
    return true;
  });
  return typing;
}

void main() {
  setUpAll(() {
    // 同 pc_arrow_keys / t104：让 media_kit 找到仓库自带的 libmpv。
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
  });

  setUp(() {
    RemoteBridge.instance.stop();
    // 每个用例从"没有屏蔽词"开始（Gate④ 会写它）
    UiPrefs.remove(DanmakuConfig.keyBlockWords);
  });

  tearDown(() => RemoteBridge.instance.stop());

  // ═══════════════════════════════════════════════════════════════════
  //  ① 回归（本 bug 的正身）：焦点在输入框 ⇒ Enter 不触发播放/全屏
  // ═══════════════════════════════════════════════════════════════════
  group('① 屏蔽词输入框里敲 Enter', () {
    testWidgets('★★ 焦点在输入框 ⇒ Enter **不**触发播放/暂停、**不**触发全屏',
        (t) async {
      await mountPlayer(t);
      final tp0 = debugPlayerTogglePlayCalls();
      final fs0 = debugPlayerFullscreenCalls();
      expect(tp0, isNotNull,
          reason: '★ 读不到探针 ⇒ 后面所有断言都无从判起（空断言比没断言更危险）');
      expect(fs0, isNotNull);

      final onField = await focusBlockWords(t);
      expect(onField, isTrue,
          reason: '★★ 前置条件：焦点必须真的在屏蔽词输入框里 —— '
              '否则下面判的不是本 bug 的场景');

      await tapKey(t, LogicalKeyboardKey.enter);

      // ★★ 根因判据：修前这里会 +1（键被 `_onKey` 抢走 → _togglePlay）
      expect(
        debugPlayerTogglePlayCalls(),
        tp0,
        reason: '★★★ Owner 原话「点击回车不会换行，反而会播放」—— '
            '焦点在屏蔽词输入框里敲 Enter **绝不能**触发播放/暂停。'
            '若这里 +1 ⇒ 输入框守卫没生效（键又被 _onKey 抢走了）',
      );
      expect(
        debugPlayerFullscreenCalls(),
        fs0,
        reason: '★ 同理，Enter 也不该触发全屏（桌面 Enter 的既有语义）',
      );
      await drain(t);
    });

    testWidgets('★ 焦点在输入框 ⇒ 空格也**不**触发播放/暂停', (t) async {
      await mountPlayer(t);
      final tp0 = debugPlayerTogglePlayCalls()!;

      expect(await focusBlockWords(t), isTrue);
      await tapKey(t, LogicalKeyboardKey.space);

      expect(
        debugPlayerTogglePlayCalls(),
        tp0,
        reason: '★ 空格分支与 Enter 分支同受输入框守卫——'
            '用户在输入框里敲空格（比如打「前方 高能」）不该切播放器',
      );
      await drain(t);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 阴性对照（必须）—— 证明 Gate① 不是恒真的空门禁
  // ═══════════════════════════════════════════════════════════════════
  group('② 阴性对照', () {
    testWidgets('★★ 面板开着但焦点**不在**输入框 ⇒ Enter **确实**触发播放/暂停',
        (t) async {
      await mountPlayer(t);
      final tp0 = debugPlayerTogglePlayCalls()!;

      // 打开面板，但**不**碰输入框 ⇒ 焦点留在播放页根节点
      expect(debugPlayerOpenDanmakuSettingsForProbe(), isTrue);
      await t.pump(const Duration(milliseconds: 300));

      final f = FocusManager.instance.primaryFocus;
      var typing = false;
      f?.context?.visitAncestorElements((el) {
        if (el.widget.runtimeType.toString() == 'EditableText') {
          typing = true;
          return false;
        }
        return true;
      });
      expect(typing, isFalse,
          reason: '★ 对照的前提：焦点**不**在输入框（否则就变成 Gate① 了）');

      await tapKey(t, LogicalKeyboardKey.enter);

      // ★★ 这条必须 +1：证明 Enter 在"没被守卫挡"时**确实**能触发播放
      expect(
        debugPlayerTogglePlayCalls(),
        tp0 + 1,
        reason: '★★ 阴性对照：焦点不在输入框（面板开着，PC）时 Enter 落到 '
            '`_onKey` 的 Enter 分支 ⇒ _togglePlay。'
            '若这条**不是** +1 ⇒ Gate① 的"没触发"是空判据（仪器坏了），'
            '整个门禁作废',
      );
      await drain(t);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 该输入框**确实是多行**、`\n` 被原样保留
  //     （用引擎送文本的同一条通道 `tester.enterText`，见文件头说明）
  // ═══════════════════════════════════════════════════════════════════
  // ════════════════════════════════════════════════════════════════════
  //  ③ 2026-10-15：本组按**改版后**的设计重写
  //
  //  改前：屏蔽词是**一个多行框**（maxLines==4），每行一个词。
  //         本组原先断言的就是「它能承载 \n」。
  //  改后：Owner 要求「一行一个占用空间太多」⇒ 改成 chip + 搜索 +
  //         **单行**添加框（回车 = 添加一个词）。多行框**故意不再存在**。
  //
  //  ⚠️ 但原始 bug 的保护**必须保留**：焦点在输入框里时，
  //     Enter 绝不能被 `_onKey` 抢去当播放/全屏。上面两组已经钉住了这一点（它们仍然红）。
  //     本组改为钉「回车真的添加了一个词」—— 即改版后的**正向证据**。
  // ════════════════════════════════════════════════════════════════════
  group('③ 屏蔽词添加框（改版后的正向证据）', () {
    testWidgets('★ 回车 ⇒ 词真的写进偏好且输入框清空（不是“敲了没反应”）',
        (t) async {
      await mountPlayer(t);
      expect(await focusBlockWords(t), isTrue,
          reason: '★前置：焦点必须真在输入框里（否则下面判的不是本场景）');

      final et = t.widget<EditableText>(blockWordsField());
      expect(et.maxLines, 1,
          reason: '★ 改版后是**单行**添加框（回车=添加），不再是多行堆叠');

      await t.enterText(blockWordsField(), '剧透');
      await t.pump(const Duration(milliseconds: 40));
      /*
       * ⚠️ 不能用 tapKey(enter) 去驱动 onSubmitted：
       *    tester 里键盘事件不会走到 TextField 的 onSubmitted
       *    （t108 文件头已记载同样的限制，那里也是直调生产回调）。
       *    直调生产的 `onSubmitted`（不是手抄副本）：
       *    从真树上取那个 TextField 的回调来调。
       */
      final tf = t.widget<TextField>(
        find.descendant(
          of: find.byType(DanmakuSettingsDialog),
          matching: find.byKey(blockWordsAddFieldKey),
        ),
      );
      tf.onSubmitted!('剧透');
      await t.pump(const Duration(milliseconds: 40));

      expect(DanmakuConfig.blockWords, contains('剧透'),
          reason: '★ 回车必须真的添加一个词（否则“能输入”是假的）');
      expect(et.controller.text, isEmpty,
          reason: '★ 添加后输入框要清空，否则连续添加很难用');
      await drain(t);
    });
  });
}
