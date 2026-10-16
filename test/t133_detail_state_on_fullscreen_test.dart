// ═══════════════════════════════════════════════════════════════════════
//  Owner 第 3 条门禁：全屏切换后**详情区**也必须保住 State
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要有这条（本仓的既有门禁只守了一半）
//   `t58_embed_layout_test.dart:222` 已经钉了「全屏切换 ⇒ **播放器** initState 只跑一次」。
//   但同一次切换里，**详情区**那一支当时写的是
//       if (!fullscreen) SizedBox(width: detailW, child: detailPanel)
//   —— 条件子节点 ⇒ 全屏时 Element 被**卸载** ⇒ `DetailPage` State 重建
//   ⇒ `initState`（detail_page.dart:1265）里的 `_init()` 再跑一次
//   ⇒ 再发一次 `SourinApi.getDetail`（:1792）+ `_loadEpisodes`（:1848）
//   ⇒ 用户报的「全屏退回后右侧详情区重载数据」。
//
//   ★ 播放器那一半有人守、详情区这一半没人守 —— 这正是 bug 溜过去的原因。
//
// # 本文件与 `.probe/.../zz_detail_reload_rootcause_probe_test.dart` 的分工
//   探针版：用与生产**逐字同构**的布局复现，并带 Offstage 反面对照（取证用）。
//   本文件：直接钉**生产源码的接线**（静态），确保以后没人把它改回条件子节点。
//   ⚠️ 两者都不实例化真 `MediaPage` —— 它一构建就造 `Player`（要 mpv + 网络），
//      仓内既有测试（`t58_media_page_test.dart:20`）也刻意不实例化它。
//      ⇒ 本门禁的强度如实标注为「**接线级**」：它保证写法正确，
//        行为级证据在探针文件里。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final src = File('lib/ui/media_page.dart').readAsStringSync();

  /// 剥注释（与 t27_w17 / t27_w9 同一套口径，防注释假绿）
  String strip(String s) {
    s = s.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
    s = s.replaceAll(RegExp(r'//[^\n]*'), '');
    return s;
  }

  test('★★★ 详情区必须是 Offstage（留在树上），不许用条件子节点摘掉', () {
    final s = strip(src);
    expect(s.contains('offstage: fullscreen,'), isTrue,
        reason: '★★★ 详情区必须靠 Offstage 留在树上。改回条件子节点 ⇒ '
            '全屏切换会卸载 DetailPage ⇒ 它的 initState 再跑 ⇒ 重新请求详情'
            '（用户报的「重载数据」）。');
    expect(s.contains('if (!fullscreen)'), isFalse,
        reason: '★★★ 不许再出现 if (!fullscreen) 这种条件子节点写法 —— '
            '那正是本 bug 的根因（Element 被卸载而不是隐藏）。');
  });

  test('★ player 仍是 Row 的第 0 个 child（Offstage 必须是并列的第二个）', () {
    final s = strip(src);
    final row = s.indexOf('crossAxisAlignment: CrossAxisAlignment.stretch,');
    expect(row, greaterThanOrEqualTo(0), reason: '找不到那个 Row');
    final iPlayer = s.indexOf('child: player,', row);
    final iOffstage = s.indexOf('offstage: fullscreen,', row);
    expect(iPlayer, greaterThan(row));
    expect(iOffstage, greaterThan(iPlayer),
        reason: '★ Offstage 必须在 player **之后** ⇒ player 仍是第 0 个 child '
            '（media_page.dart:1940 的硬约束：位置变了 Player 会被重建、视频被打断）');
  });

  test('★ 反面对照：本条门禁的扫描器确实能抓到被改坏的写法', () {
    /*
     * 铁律：判据测不出反面 ⇒ 结论作废。
     * 这里喂一份**故意改坏**的假源码（条件子节点写法），
     * 断言上面那两条判据会红。
     * ⚠️ 喂假输入而不是真去改生产文件 —— 后者会污染工作区。
     */
    const broken = 'children: ['
        '  Expanded(flex: fullscreen ? 1 : 3, child: player),'
        '  if (!fullscreen) SizedBox(width: detailW, child: detailPanel),'
        ']';
    expect(broken.contains('offstage: fullscreen,'), isFalse,
        reason: '★ 阳性对照：改坏的写法必须**不含** offstage ⇒ 判据①会红');
    expect(broken.contains('if (!fullscreen)'), isTrue,
        reason: '★ 阳性对照：改坏的写法必须**含** if (!fullscreen) ⇒ 判据②会红');
  });
}
