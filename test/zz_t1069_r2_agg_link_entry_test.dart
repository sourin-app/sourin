// ═══════════════════════════════════════════════════════════════════════
//  R2-#2 聚合源「编辑链接」入口可达性（**Owner 第二次反馈后补的判据**）
// ═══════════════════════════════════════════════════════════════════════
//
// 跑法：flutter test --concurrency=1 test/zz_t1069_r2_agg_link_entry_test.dart
//
// # ★★★ 为什么要有这条（前一次的门禁 +26 全绿，而 Owner 说"还是编辑不了"）
// ```text
// R1 的修法只给**聚合源那类的组头**加了入口，门禁也钉了那条 ⇒ 全绿。
// 但 Owner **第二次**反馈 ⇒ 他点的是**卡片自己的操作菜单**：
//   菜单里只有「个性化覆盖层…」+「移除这个源」两项。
//
// 顺着那张截图查菜单项的门控，发现**三处门控同时把聚合源排除在外**：
//   ① 「编辑」   ← `_canEdit`（只认 declarative / http / js）
//   ② 「配置」   ← `onConfig` = `_configOf(id)`，而它对 `tvbox_agg` **返回 null**
//        （它既不是 declarative，也没有插件条目 ⇒ 走到 `_pluginOf(id) == null`）
//   ③ 外层菜单门 ← `_canEdit || _isThirdParty || onOverride != null`
//        （聚合源三项全不满足 ⇒ **整个菜单都不画**）
// ⇒ 而聚合源是**内置 Rust 实现**（`kind` 空）⇒ ①③ 天然不成立。
//
// ★ 教训（本批母题第 N 例）：**"入口存在"与"入口可达"是两件事**。
//   R1 的门禁验的是"那个入口画得出来"（它确实画得出来 —— 在**组头**上），
//   而 Owner 的操作路径是**卡片菜单** ⇒ 门禁**打在了另一个对象上**。
//   ⇒ 本条的判据必须钉"**卡片菜单那一项在聚合源上是否可用**"。
// ```
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _src() => File('lib/ui/settings_page.dart').readAsStringSync();

/// 剥行注释与块注释（**必须剥** —— 否则本文件自己写的解释文字会被当成代码，
/// 本批已两次踩："写规则的人被规则绊"）。
String _codeOnly(String src) {
  final b = StringBuffer();
  var inBlock = false;
  for (final line in src.split('\n')) {
    var t = line;
    if (inBlock) {
      final p = t.indexOf('*/');
      if (p >= 0) {
        inBlock = false;
        t = t.substring(p + 2);
      } else {
        continue;
      }
    }
    // 去掉块注释起点（同行闭合则保留后半段）
    while (true) {
      final s = t.indexOf('/*');
      if (s < 0) break;
      final e = t.indexOf('*/', s + 2);
      if (e >= 0) {
        t = t.substring(0, s) + t.substring(e + 2);
      } else {
        t = t.substring(0, s);
        inBlock = true;
        break;
      }
    }
    final d = t.indexOf('//');
    if (d >= 0) t = t.substring(0, d);
    b.writeln(t);
  }
  return b.toString();
}

void main() {
  group('R2-#2 · 聚合源「编辑链接」入口在三处门控上都必须可达', () {
    late final String raw;
    late final String code;
    setUpAll(() {
      raw = _src();
      code = _codeOnly(raw);
    });

    test('★★★ ① `_configOf` 对聚合源必须**返回非 null**（不是走到 _pluginOf==null）', () {
      /*
       * 判据形态：取 `_configOf` 的函数体，断言它在 "declarative 分派" **之前**
       * 有一条针对 `kTvboxAggregateId` 的分派。
       * ⚠️ 顺序也判 —— 因为放到声明式分支之后就等于没有（聚合源不是 declarative）。
       */
      final start = code.indexOf('VoidCallback? _configOf(');
      expect(start >= 0, isTrue, reason: '★ 找不到 `_configOf`');
      final body = code.substring(start, start + 1200);
      final aggIdx = body.indexOf('kTvboxAggregateId');
      final declIdx = body.indexOf("kind == 'declarative'");
      expect(
        aggIdx >= 0,
        isTrue,
        reason: '★★★ `_configOf` 必须**显式分派聚合源** —— '
            '否则它走到 `_pluginOf(id) == null` 返回 null ⇒ 「配置」与「编辑链接…」都不可用',
      );
      expect(
        aggIdx < declIdx,
        isTrue,
        reason: '★ 该分派必须在 `declarative` 分支**之前**（聚合源不是 declarative，放后面等于没有）',
      );
    });

    test('★★★ ② 卡片菜单必须有「编辑链接…」项，且**不受 `_canEdit` 门控**', () {
      final i = code.indexOf("label: '编辑链接…'");
      expect(i >= 0, isTrue, reason: '★★★ 卡片菜单里必须有「编辑链接…」项');
      // 该项所在的那段（往前 200 字符）必须是 `provider.id == kTvboxAggregateId` 条件，
      // 而不是 `_canEdit`。
      final ctx = code.substring((i - 260).clamp(0, code.length), i);
      expect(
        ctx.contains('kTvboxAggregateId'),
        isTrue,
        reason: '★ 该项的**门控**必须是 `provider.id == kTvboxAggregateId`（正向列举，按 id）—— '
            '不许写成 `_canEdit`（那会把它也一起关掉：聚合源的 kind 为空）',
      );
    });

    test('★★★ ③ 外层菜单门控必须覆盖聚合源（否则整个菜单都不画）', () {
      /*
       * 这一条是"**我差点只改一处**"的教训：
       * 只加菜单项、不改外层门控 ⇒ 外层 `if` 为假 ⇒ 整块菜单仍不画 ⇒ 用户什么也看不到。
       *
       * ⚠️ 锚点必须唯一 —— 我第一版踩了两次：
       *   · `AppMenuButton<String>` 出现 **2 次** ⇒ `indexOf` 取到**别处**那一个；
       *   · 改成从本项往前找 `if (_canEdit` 后，找到的是**本项自己那一行的门控**
       *     （`if (_canEdit)` 包着「编辑」项），**不是**外层那道
       *     （`if (_canEdit || _isThirdParty || onOverride != null || …)`）。
       *   ⇒ ★ 这正是本批"**判据打在了错误的对象上**"：两者都是 `if (_canEdit…`，
       *     但一个管**单项**、一个管**整块菜单** ⇒ 看代码形状分不出，必须按**位置**锚定。
       * ⇒ 正解：先找**包含本项的那个** `AppMenuButton`，再从它**往前**找门控
       *   （外层门控一定在 AppMenuButton **之外、之前**）。
       */
      final itemIdx = code.indexOf("label: '编辑链接…'");
      expect(itemIdx >= 0, isTrue, reason: '★ 找不到该项（见 ② 的失败信息）');

      // 包含本项的那个 AppMenuButton（往前找最近的一个）
      final menuIdx = code.substring(0, itemIdx).lastIndexOf('AppMenuButton<String>');
      expect(menuIdx >= 0, isTrue, reason: '★ 找不到本项所在的 AppMenuButton');

      // 外层门控：从 AppMenuButton **之前**再往前找最近的 `if (_canEdit`
      final beforeMenu = code.substring(0, menuIdx);
      final gateIdx = beforeMenu.lastIndexOf('if (_canEdit');
      expect(gateIdx >= 0, isTrue, reason: '★ 找不到外层门控那一行');
      final gateLine = beforeMenu.substring(gateIdx).split('\n').first;
      expect(
        gateLine.contains('kTvboxAggregateId'),
        isTrue,
        reason: '★★★ 外层门控必须含 `|| provider.id == kTvboxAggregateId` —— '
            '聚合源的 `_canEdit`/`_isThirdParty` 都是 false ⇒ 不改这行，菜单整个不画。'
            '实际那一行是：$gateLine',
      );
      // 反空真：确认它确实是"外层"那道（AppMenuButton 与它之间没有别的 AppMenuButton）
      expect(
        beforeMenu.substring(gateIdx).contains('AppMenuButton'),
        isFalse,
        reason: '★ 取到的门控与 AppMenuButton 之间**不该**再夹一个 AppMenuButton '
            '（否则说明取到的是内层/别处的门控）',
      );
    });

    test('★★ ④ 菜单项必须**真的被接线**（只加 label 不算）', () {
      // ⚠️ 同样必须用唯一锚点：`onSelected: (v)` 也出现 2 次。
      // ⇒ 从本项所在的那个 AppMenuButton 往后找它**自己**的 onSelected。
      final itemIdx = code.indexOf("label: '编辑链接…'");
      expect(itemIdx >= 0, isTrue, reason: '★ 找不到该项');
      final menuIdx = code.substring(0, itemIdx).lastIndexOf('AppMenuButton<String>');
      // 取到该 AppMenuButton 的结尾（下一个 `AppMenuButton<String>` 或文件尾）
      final nextMenu = code.indexOf('AppMenuButton<String>', menuIdx + 1);
      final blockEnd = nextMenu > 0 ? nextMenu : code.length;
      final block = code.substring(menuIdx, blockEnd);
      expect(
        block.contains("v == 'aggregateLink'"),
        isTrue,
        reason: '★★ 本项所在的 AppMenuButton 的 `onSelected` 必须处理 `aggregateLink` —— '
            '否则菜单项点了**什么都不发生**（"看起来有入口"的第二种形态）',
      );
      expect(
        block.contains('onConfig?.call()'),
        isTrue,
        reason: '★ 它应当复用 `onConfig`（= 打开聚合管理页），不要另造一条路径',
      );
    });

    test('★★ ⑤ 判据卡"三处门控"不是"某一处"（反部分修复）', () {
      // 汇总：三处必须**同时**成立 —— 少一处就不可达（这正是 R1 只修一处失效的原因）。
      final i = code.indexOf('VoidCallback? _configOf(');
      final cfgBody = code.substring(i, i + 1200);
      final hasCfg = cfgBody.contains('kTvboxAggregateId') &&
          cfgBody.indexOf('kTvboxAggregateId') < cfgBody.indexOf("kind == 'declarative'");
      final itemIdx = code.indexOf("label: '编辑链接…'");
      final hasItem = itemIdx >= 0;
      final menuIdx =
          hasItem ? code.substring(0, itemIdx).lastIndexOf('AppMenuButton<String>') : -1;
      final beforeMenu = menuIdx > 0 ? code.substring(0, menuIdx) : '';
      final g = beforeMenu.lastIndexOf('if (_canEdit');
      final hasGate = g >= 0 &&
          beforeMenu.substring(g).split('\n').first.contains('kTvboxAggregateId');
      final hasWire = hasItem &&
          code.substring(menuIdx).contains("v == 'aggregateLink'") &&
          code.indexOf("v == 'aggregateLink'") < code.indexOf("v == 'aggregateLink'") + 1;
      // 精确判 wire：在**本项所在块**里找
      final nextMenu = hasItem ? code.indexOf('AppMenuButton<String>', menuIdx + 1) : -1;
      final block = hasItem
          ? code.substring(menuIdx, nextMenu > 0 ? nextMenu : code.length)
          : '';
      final wireOk = block.contains("v == 'aggregateLink'") && block.contains('onConfig?.call()');
      expect(
        hasCfg && hasItem && hasGate && wireOk,
        isTrue,
        reason: '★★★ **三处门控 + 接线必须同时成立**（R1 只修一处 ⇒ 全绿但不可达）：'
            'configOf=$hasCfg item=$hasItem outerGate=$hasGate wire=$wireOk '
            '（辅助 hasWire=$hasWire）',
      );
    });
  });
}