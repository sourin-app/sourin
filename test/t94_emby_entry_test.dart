// ═══════════════════════════════════════════════════════════════════════
//  t94：Emby 二级页的**入口接线**守卫（task-33 ⑦）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这条守卫针对的**真缺陷**（不是防将来，是修当下）
// ```text
// lib/ui/settings/emby_page.dart 有 700+ 行、EmbySettingsPage 写完了，
// 但全仓 grep EmbySettingsPage 只命中它**自己那个文件** ⇒
// 用户**没有任何路径**能进入这个页面。
// ```
// ★ 这与本仓记过的 task-18 老坑**完全同型**：
//   > 两个二级页都写好了，一级页一行入口都没有 ⇒ 功能对用户完全不可见。
//
// # 为什么用**静态契约**（而不是 widget 测试）
// ```text
// 与 task43_plugins_subpage_test.dart 同一个理由：
// SettingsPage 的宿主在 flutter test 里挂不上 ——
//   build() 里 SourinApi.version → SourinCore.version →
//   DynamicLibrary.open('sourin_core.dll')
// 测试环境没有那个 DLL ⇒ 子树被换成 ErrorWidget。
// ⇒ 能守的是「接线是否存在」，行为层（真机点进去）另做。
// ```
//
// # ★★★ 本文件最后一条是**通用**守卫（比 Emby 本身更重要）
// ```text
// 「lib/ui 整棵树里每个公开的 *Page / *Panel / *Sheet / *Dialog 类，
//   都必须被自己文件之外引用至少一次」
// ⇒ 将来任何人再写一个二级页/浮层却忘了接入口，这条会**当场报红**，
//   不用等到用户来报「点不进去」。
//
// ⚠️ 2026-10：扫描范围从只有 lib/ui/settings/ + *SettingsPage，
//   扩到 lib/ui 整棵树 + 四类后缀。旧范围有**系统性盲区** ——
//   widgets/ cast/ player/ subtitle/ 下的浮层完全不在射程，
//   而这正是「二级页写好没入口」第二次犯案的地方。
//   私有类（前导 `_`）不进守卫：本文件之外物理上引用不到。
//   真·漏接 ⇒ 报红；合法例外（Owner 要求删的功能、探针专用件）
//   ⇒ 逐条白名单 + 理由，**不用宽泛正则整类放过**（那是假门禁）。
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 去注释（状态机，处理字符串里的 // 与块注释）
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  var inLine = false;
  var inBlock = false;
  String? quote;

  while (i < src.length) {
    final c = src[i];
    final next = i + 1 < src.length ? src[i + 1] : '';

    if (inBlock) {
      if (c == '*' && next == '/') {
        inBlock = false;
        i += 2;
        continue;
      }
      if (c == '\n') out.write(c);
      i++;
      continue;
    }
    if (inLine) {
      if (c == '\n') {
        inLine = false;
        out.write(c);
      }
      i++;
      continue;
    }
    if (quote != null) {
      if (c == '\\') {
        out.write(c);
        if (next.isNotEmpty) out.write(next);
        i += 2;
        continue;
      }
      if (c == quote) quote = null;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && next == '/') {
      inLine = true;
      i += 2;
      continue;
    }
    if (c == '/' && next == '*') {
      inBlock = true;
      i += 2;
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

void main() {
  final raw = File('lib/ui/settings_page.dart').readAsStringSync();
  final code = stripComments(raw);

  group('t94 Emby 入口接线', () {
    test('★ 一级页 import 了 emby_page.dart', () {
      expect(
        code.contains("import 'settings/emby_page.dart';"),
        isTrue,
        reason: '★ 没有 import 就调不到 EmbySettingsPage（编译不过）',
      );
    });

    test('★★ 有一行 SettingsEntryRow 指向 EmbySettingsPage', () {
      expect(
        code.contains('onTap: () => _openSubPage(const EmbySettingsPage()),'),
        isTrue,
        reason: '★★ 只有 import 不够 —— 必须有可点的入口行，否则页面仍然不可达（这正是本缺陷的形态）',
      );
    });

    test('★ 入口标题是 Emby，且副标题说清里面有什么', () {
      expect(code.contains("title: 'Emby',"), isTrue,
          reason: '★ 入口标题必须与页面名一致，否则用户找不到');
      expect(
        code.contains("subtitle: '媒体服务器 · 安装插件 / 服务器地址 / 连接自检',"),
        isTrue,
        reason: '★ 副标题按本页规矩写清里面有什么（同 JS 插件那条）',
      );
    });

    test('★ 入口落在「内容源与插件」分组内（不是散落别处）', () {
      // ★ 2026-10-10：组名从「内容源」改成「内容源与插件」——
      //   这一组里除了 JS 插件还有 Emby 源，原名盖不住。
      //   判据（同语义，只是锚点字符串跟着改）：Emby 必须在该组标签与
      //   下一个组标签「播放与观看」**之间**。
      final group =
          code.indexOf("SettingsGroupLabel(text: '内容源与插件')");
      final entry = code.indexOf("title: 'Emby',");
      final nextGroup = code.indexOf("SettingsGroupLabel(text: '播放与观看')");
      expect(group > 0 && entry > 0 && nextGroup > 0, isTrue,
          reason: '★ 前置：三个锚点都必须找得到');
      expect(group < entry && entry < nextGroup, isTrue,
          reason: '★ Emby 是内容源（JS 插件形态）⇒ 必须落在「内容源与插件」组里',
      );
    });

    test('★★★ 通用守卫：每个 *Page/*Panel/*Sheet/*Dialog 都必须被外部引用（防下一个漏接）', () {
      /*
       * ★ 这条比 Emby 本身重要：它把「二级页写完了但没接入口」
       *   从「等用户报」变成「测试当场报红」。
       *
       * ⚠️ 只在 lib/ui 整棵树（含 widgets / cast / player / subtitle 子目录）下扫
       *   「页面/浮层类」（*Page / *Panel / *Sheet / *Dialog），
       *   不扫 _Hint / _Bullet 这类私有部件（它们本就不该被外部引用）。
       * ⚠️ 引用计数排除**定义它自己那个文件** ——
       *   类名在自身文件里当然出现，那不是接线。
       */
      final pageRe = RegExp(
        r'^\s*(?:final |abstract |sealed )?class (\w+(?:Page|Panel|Sheet|Dialog))'
        r' extends (?:StatefulWidget|StatelessWidget)',
        multiLine: true,
      );
      final dir = Directory('lib/ui');
      final unreachable = <String>[];
      var scanned = 0;

      // ★ 每进一次循环重读全仓一次太贵 —— 先把 lib/ 下所有 .dart 的
      //   去注释源码读进来缓存，再对每个类做内存扫描。
      final sources = <String, String>{};
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        sources[f.path.replaceAll(r'\', '/')] = stripComments(f.readAsStringSync());
      }

      // ★ 白名单：**公开**类，但故意不被外部引用。每条都要写清理由 ——
      //   ⚠️ 严禁用宽泛正则把整类放过（那等于假门禁）。加新条目必须先在
      //   全仓 grep 确认"真的没人接"，且原因属于下面三类之一。
      final whitelist = <String, String>{
        // Owner 明确要求删掉的功能 —— 组件源码留着（单测还直接挂它），
        // 但**故意**没有任何宿主再构造它。见 lib/shell.dart:4683 与
        // lib/ui/live_page.dart:1782 的说明（2026-09-26）。
        'EpgPanel': 'Owner 2026-09-26 要求删除节目单 ⇒ 故意没人接（源码留、单测直挂）',
        // 探针专用件 —— 只有 lib/probe_cast.dart（诊断探针）用它，
        // 正式宿主故意不接。见 test/t80_cast_wiring_test.dart B④。
        'CastStatusBar': '仅诊断探针 probe_cast.dart 用；正式界面故意不接（t80 B④ 已如实记录）',
      };

      for (final e in dir.listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        final path = e.path.replaceAll(r'\', '/');
        final src = sources[path]!;
        for (final m in pageRe.allMatches(src)) {
          final cls = m.group(1)!;
          scanned++;
          // ★ 私有类（前导 `_`）在 Dart 里**本文件之外物理上引用不到**，
          //   不进这个守卫 —— 这与旧守卫排除 `_Hint`/`_Bullet` 同一条理由。
          //   （旧正则只匹配 `\w+...`，前导 `_` 会被 `\w` 吃掉，所以这里
          //   显式排除才能与旧行为等价。）
          if (cls.startsWith('_')) continue;
          if (whitelist.containsKey(cls)) continue;
          var refs = 0;
          for (final ent in sources.entries) {
            if (ent.key == path) continue;
            if (ent.value.contains(cls)) refs++;
          }
          if (refs == 0) unreachable.add('$cls ($path)');
        }
      }

      expect(scanned, greaterThanOrEqualTo(10),
          reason: '★ 前置：至少要扫到 10 个页面/浮层类，否则是扫描口径坏了');
      expect(
        unreachable, isEmpty,
        reason: '★★★ 这些二级页写完了却没有任何入口 ⇒ 用户点不进去（task-18 / Emby 同型）',
      );
    });
  });
}
