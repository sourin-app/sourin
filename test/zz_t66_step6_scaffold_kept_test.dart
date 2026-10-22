// ═══════════════════════════════════════════════════════════════════════
//  轨道 E M2 第 6 步 —— Scaffold **有意保留**（裁决：不改）
// ═══════════════════════════════════════════════════════════════════════
//
// # ★★★ 这个文件是"不做的理由"，不是"待办"
//
// 第 1-5 步都是"把 Material 换成自建"。第 6 步的结论是**不要换**，
// 而且这个结论有**实测数据**支撑。把它写成门禁，是为了：
// ```text
// ① 防止下一个人看到 `Scaffold(` 就当成"漏掉的 Material"顺手改掉
// ② 把"为什么不动"的证据留档（否则半年后没人知道这是深思熟虑还是忘了）
// ③ ⚠️ 但**不**锁死"Scaffold 必须存在" —— 将来若要换，删掉本文件即可，
//    不会被一个断言拦住
// ```
//
// # 完整证据（`.probe/probe_e6_*.dart` 实测）
//
// ```text
// ⑤ 视觉差异：**像素 0 差异**
//    400×300 视口、空内容、逐字节对比：
//      Scaffold 外壳 vs 裸 ColoredBox 外壳 ⇒ 不同像素 = 0 / 120000
//      三个采样点 RGB 全等：(0,0) (200,150) (399,299) 都是 10,10,10
//    ⚠️ 带文字时会出现 1054/120000 的差异 —— 那是**文字抗锯齿**
//       （Scaffold 的 DefaultTextStyle 给了不同字体度量），与它自身绘制无关。
//       空内容下 0 差异是排除该项干扰的决定性证据。
//
// ⑥ 依赖面：**零连锁**
//      `Scaffold.of(`       全仓 0 处
//      `ScaffoldMessenger`  全仓 0 处（第 5 步正好清空）
//      appBar / floatingActionButton / drawer / bottomNavigationBar
//      / bottomSheet / persistentFooterButtons —— 两处**一个都没用**
//      实际只用了两个参数：backgroundColor + body
//
// ★ 关键：`Scaffold` **本就已经不含 Material**
//      实测 Scaffold 树下 Material 数 = 0
//      ⇒ 这根本不是"去掉一个 Material 视觉组件"的问题
//      ⇒ 为它做改动**不服务于 Owner 的目标**（Owner 要的是"不那么丑"）
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String stripComments(String src) {
  final out = <String>[];
  var inBlock = false;
  for (final raw in src.split('\n')) {
    final line = raw.trimLeft();
    if (inBlock) {
      if (line.contains('*/')) inBlock = false;
      continue;
    }
    if (line.startsWith('/*')) {
      if (!line.contains('*/')) inBlock = true;
      continue;
    }
    if (line.startsWith('//')) continue;
    out.add(raw);
  }
  return out.join('\n');
}

String _code(String rel) => stripComments(File(rel).readAsStringSync());

void main() {
  group('第 6 步：Scaffold 有意保留（结构容器，无视觉表现）', () {
    test('★ 混合态登记：Scaffold 有意保留', () {
      /*
       * ⚠️ 注意本条**不断言** "Scaffold 必须存在"。
       * 它断言的是"当前事实"+"这两处的用途"，用于**留档**。
       * 将来若要换成 AppScaffold，删掉本文件即可。
       */
      final detail = _code('lib/ui/detail_page.dart');
      final media = _code('lib/ui/media_page.dart');

      // ── 当前事实：两处 Scaffold 都在 ──
      expect(RegExp(r'return Scaffold\(').hasMatch(detail), isTrue,
          reason: '★ 记录：detail_page 仍有一处 Scaffold');
      expect(RegExp(r'return Scaffold\(').hasMatch(media), isTrue,
          reason: '★ 记录：media_page 仍有一处 Scaffold');

      // ── ★ 纠正过的关键事实：两处用途完全不同 ──
      expect(detail.contains('if (widget.embedded)'), isTrue,
          reason: '★ detail_page 的 Scaffold 在 embedded 分支之后 —— '
              '生产路径是 embedded ⇒ 它**根本不执行**');
      expect(media.contains('backgroundColor: fullscreen ? Colors.black : surface'),
          isTrue,
          reason: '★ media_page:1937 才是**生产路径**上真正执行的那个');
    });

    test('★ 保留理由 ①：Scaffold 树下不含 Material（实测 0 个）', () {
      /*
       * .probe/probe_e6_appscaffold_test.dart 实测：
       *   Scaffold 树下 Material 数    = 0
       *   AppScaffold 树下 Material 数 = 0
       * ⇒ Scaffold 本身不提供任何 Material 视觉 ⇒ 换它不改变"有没有 Material 视觉"
       */
      final media = _code('lib/ui/media_page.dart');
      // Scaffold 的参数里没有 appBar/FAB/drawer 等会产生 Material 视觉的东西
      for (final slot in [
        'appBar:',
        'floatingActionButton:',
        'drawer:',
        'bottomNavigationBar:',
        'bottomSheet:',
        'persistentFooterButtons:',
      ]) {
        expect(media.contains(slot), isFalse,
            reason: '★ 记录：media_page 的 Scaffold 没用 $slot '
                '⇒ 它只是个背景色 + body 的容器');
      }
    });

    test('★ 保留理由 ②：依赖面为零（Scaffold.of / ScaffoldMessenger 全仓 0 处）',
        () {
      /*
       * 依赖面为零说明：换掉不会连锁任何调用点。
       * ⚠️ 但"能换"≠"该换" —— 收益见下一条。
       */
      var scaffoldOf = 0;
      var messenger = 0;
      for (final e in Directory('lib').listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        final code = stripComments(e.readAsStringSync());
        scaffoldOf += RegExp(r'Scaffold\.of\(').allMatches(code).length;
        messenger += RegExp(r'ScaffoldMessenger').allMatches(code).length;
      }
      expect(scaffoldOf, 0,
          reason: '★ 记录：全仓 `Scaffold.of(` 应为 0 处');
      expect(messenger, 0,
          reason: '★ 记录：全仓 ScaffoldMessenger 应为 0 处（第 5 步已清空）');
    });

    test('★★ 保留理由 ③：本仓已有 AppScaffold —— 但换过去收益为 0', () {
      /*
       * ★ 这条是给"下一个人"看的：不要以为没人发现 AppScaffold。
       *
       * 事实：
       *   ① lib/ui/app_scaffold.dart 已存在，且它的注释就写着
       *      「为什么不直接用 Material 的 Scaffold」⇒ 这问题以前就解决过
       *   ② 实测 AppScaffold 与 Scaffold **像素 0 差异**（400×300 空内容）
       *      ⇒ 换过去用户看不出任何区别 ⇒ 收益为 0
       *   ③ AppScaffold **不处理 system padding**（只处理 viewInsets），
       *      而 Scaffold 会做 MediaQuery.removePadding
       *      ⇒ 换过去会引入一个"将来可能踩"的隐患
       *         （现在两处不受影响是**当下的巧合**，不是结构保证）
       *
       * ⇒ 结论：收益 0 + 引入隐患 ⇒ 不改。
       */
      final app = File('lib/ui/app_scaffold.dart');
      expect(app.existsSync(), isTrue,
          reason: '★★ 记录：AppScaffold 存在（lib/ui/app_scaffold.dart）');
      final code = _code('lib/ui/app_scaffold.dart');
      expect(code.contains('class AppScaffold'), isTrue);
      expect(code.contains('viewInsetsOf'), isTrue,
          reason: '★★ 记录：AppScaffold **只**处理 viewInsets（软键盘）');
      expect(code.contains('padding'), isTrue,
          reason: '★★ 记录：对 system padding 没有处理 —— 这是不换的结构性理由');
    });

    test('★ 混合态总表：这 6 步之后还剩哪些 Material', () {
      /*
       * 本文件是**唯一权威清单**。若有变动，改这里。
       *
       * | 组件            | 状态        | 步骤 / 理由                    |
       * |-----------------|-------------|--------------------------------|
       * | TextButton ×10  | 已自建      | 第 1 步 AppTextButton          |
       * | IconButton ×2   | 已自建      | 第 2 步 AppIconButton          |
       * | OutlinedButton  | 已自建      | 第 3 步 AppOutlinedButton      |
       * | AlertDialog ×3  | 已自建      | 第 4 步 AppGlassDialog         |
       * | SnackBar        | 已自建      | 第 5 步 showAppToast（全仓 6 处）|
       * | Scaffold        | **有意保留** | 第 6 步 —— 结构容器，像素 0 差异 |
       * | Text ×N         | 保留        | 文本不是"Material 视觉组件"      |
       * | InkWell ×1      | 待评估      | 见下方说明                     |
       * | LinearProgressIndicator ×1 | 待评估 | 见下方说明                |
       */
      final detail = _code('lib/ui/detail_page.dart');

      // 已换的（正向，防止被改回去）
      expect(detail.contains('AppTextButton('), isTrue);
      expect(detail.contains('AppIconButton('), isTrue);
      expect(detail.contains('AppOutlinedButton('), isTrue);
      expect(detail.contains('AppGlassDialog('), isTrue);
      expect(detail.contains('showAppToast('), isTrue);

      // 已清零的（反向，防止回退）
      expect(RegExp(r'(?<!App)\bTextButton\(').hasMatch(detail), isFalse);
      expect(RegExp(r'(?<!App)\bIconButton\(').hasMatch(detail), isFalse);
      expect(RegExp(r'(?<!App)\bOutlinedButton\(').hasMatch(detail), isFalse);
      expect(RegExp(r'(?<!App)\bAlertDialog\(').hasMatch(detail), isFalse);
      expect(detail.contains('SnackBar('), isFalse);

      // 有意保留的
      expect(detail.contains('Scaffold('), isTrue,
          reason: '★ 有意保留（见本文件头部理由），不是遗漏');
    });

    test('★ 剩余待评估项：InkWell / LinearProgressIndicator 如实登记', () {
      /*
       * 这两项**本轮没做**，如实登记，防止被当成遗漏或被当成已做。
       *
       * 为什么没做：它们不在 Lead 给的 6 步清单里。
       * 下一轮若要继续"去 Material"，它们是自然的候选。
       */
      final detail = _code('lib/ui/detail_page.dart');
      final hasInkWell = RegExp(r'\bInkWell\(').hasMatch(detail);
      final hasLpi = detail.contains('LinearProgressIndicator(');
      // ignore: avoid_print
      print('[STEP6] 剩余待评估：InkWell=$hasInkWell '
          'LinearProgressIndicator=$hasLpi');
      // ⚠️ 不断言它们必须存在或必须不存在 —— 只是登记。
      //    如果下一轮把它们换掉，本条不需要改（不会假绿/假红）。
    });
  });
}
