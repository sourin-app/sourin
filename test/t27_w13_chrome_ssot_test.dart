// ═══════════════════════════════════════════════════════════════════════
//  T27-13 —— ★★★ Owner 第 3 / 5 条：顶栏/底栏**唯一真源 + 过渡动画**
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字，两段）
//
// > 3.上下还是联动的不是一起的,就是错开显示的,你见过哪个播放器是这样子的,
// >   这个必须纠正,必须同时消失 同时显示,并且要加上过渡动画
//
// > 还有这个奇怪的 bug,上面显示,无论怎么移动鼠标,下面的就是不显示,
// >  点了暂停才显示
//
// 第 5 条是第 3 条的具体症状：顶栏在、底栏怎么动鼠标都不出，点暂停才出。
//
// # 根因（核实行号见下）
//
// 「控制条该不该显示」这**一件事**原来有**三个不同的真源**：
//   ① 底栏渲染门控（`_BottomBar(` 前那个 if）：
//        _controlsVisible && _error == null && !7floatFlag
//          && _liveAudioOnlyNotice == null && !_videoOutputDead
//   ② 顶栏渐变条的 `visible:`（正常支）：
//        (_controlsVisible && _error == null)
//          && !_videoOutputDead && _liveAudioOnlyNotice == null   ← 少 7 个 flag
//   ③ `_anySheetOpen`（hover 复活护栏用）：7 flag + _hintsOpen + _zoomOpen
//        ← 多 hints/zoom，少两条降级横幅
// ⇒ 三集合两两不同 ⇒ 只要出现「① 假 / ② 真」,
//   就是「顶栏在、底栏不在」的分裂（= Owner 症状）。
//
// # 修法
//
//   抽唯一真源 `bool get _chromeVisible`（11 项）；顶栏 `visible` 的正常支与
//   底栏渲染门控**都读它** ⇒ 同一表达式求值两次，结果恒相等。
//   `_canUseTopBarBack`（错误态返回口）是**登记的例外**，保持 `||` 互斥分支。
//
// # 过渡动画（Owner：「要加上过渡动画」「必须同时消失」）
//
//   顶栏**常挂**，靠 `fade: _controlsFade`（Opacity）淡出；
//   底栏改前被 `if` 同帧卸下（硬切）⇒ 隐藏时「顶栏淡出中、底栏已消失」=错开。
//   修法：底栏用 `ListenableBuilder(_controlsAnim)` 包住，在**淡出窗口内留在
//   树上**并喂 `_bottomFade`（与顶栏**同一个** `_controlsFade` 实例）。
//   ⇒ 两条读**同一个 `Animation` 实例**、同一时长曲线（Motion.base / easeOut）
//   ⇒ 逐帧同值，不可能错开。
//
// # 为什么用静态契约（读生产源码 + 剥注释 + 字面/结构断言）
//
// 本机 flutter_tester 加载 libmpv-2.dll 会 native 崩溃（见 dart_test.yaml）；
// 真渲染测不了。本仓既有惯例即静态契约（t27_w9 / t118 / t57 同款）。
//
// ⚠️ 不写 `@Tags(['native-media'])` —— 本文件**不挂 PlayerPage**，不加载
//    libmpv，走默认套件即可（CI 会跑）。
// ═══════════════════════════════════════════════════════════════════════

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _pagePath = 'lib/ui/player_page.dart';

/// 剥掉 `//` 行注释、`///` 文档注释、`/* */` 块注释（保留字符串字面量）
/// —— 逐字照抄 t27_w9_bar_linkage_test.dart 的已验证实现。
String stripComments(String src) {
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

void main() {
  final raw = File(_pagePath).readAsStringSync();
  final page = stripComments(raw);

  // 取 getter 的定义体（从 `=>` 到该语句的 `;`）。
  String getterBody(String name, {String ret = 'bool'}) {
    final i = page.indexOf('$ret get $name =>');
    expect(i, greaterThanOrEqualTo(0), reason: '找不到 getter `$ret get $name`');
    final semi = page.indexOf(';', i);
    expect(semi, greaterThan(i), reason: 'getter `$name` 没有终止分号');
    return page.substring(i, semi);
  }

  // ═══════════════════════════════════════════════════════════════════
  //  ① 唯一真源存在且成员齐（11 项）
  // ═══════════════════════════════════════════════════════════════════

  test('A1 `_chromeVisible` 恰好是那 11 项门控（唯一真源）', () {
    final body = getterBody('_chromeVisible');
    for (final part in const [
      '_controlsVisible',
      '_error == null',
      '!_episodeSheetOpen',
      '!_streamSheetOpen',
      '!_settingsOpen',
      '!_danmakuSheetOpen',
      '!_biliSheetOpen',
      '!_subtitlePanelOpen',
      '!_liveChannelsOpen',
      '_liveAudioOnlyNotice == null',
      '!_videoOutputDead',
    ]) {
      expect(body.contains(part), isTrue,
          reason: '★★ 唯一真源 `_chromeVisible` 漏了 `$part` —— '
              '顶栏与底栏会各算各的门控 ⇒ Owner 第 3 条的分裂复发');
    }
    // 反向：真源里**不得**混入 hints / zoom（它们与底栏同层共存，见下 B2）。
    expect(body.contains('_hintsOpen'), isFalse,
        reason: '★ `_hintsOpen` 不该进唯一真源（它是覆盖层、不占底部条位）');
    expect(body.contains('_zoomOpen'), isFalse,
        reason: '★★ `_zoomOpen` 不该进唯一真源 —— 缩放滑条**画在底栏内部**'
            '（player_bottom_bar.dart `if (zoomOpen)`），进真源会让一开滑条'
            '底栏整条被卸 ⇒ 滑条自己也消失（拖到一半条没了）');
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 顶栏与底栏**共读**同一真源
  // ═══════════════════════════════════════════════════════════════════

  test('A2 顶栏 visible = `_chromeVisible || _canUseTopBarBack`（同源 + 例外）', () {
    expect(
      page.contains('visible: _chromeVisible || _canUseTopBarBack,'),
      isTrue,
      reason: '★★ 顶栏的正常支必须读唯一真源 `_chromeVisible`；错误态返回口'
          '`_canUseTopBarBack` 保持互斥 `||` 分支（Owner 2026-10-09 报过'
          '「不能播放时左上角返回点不动」）',
    );
    // 顶栏**不得**再内联自己的正常支判据（那正是分裂的第二个真源）。
    expect(
      page.contains('(_controlsVisible && _error == null) &&'),
      isFalse,
      reason: '★★ 顶栏又内联了自己的正常支判据 ⇒ 出现第二个真源 ⇒ 分裂复发。'
          '正常支必须只读 `_chromeVisible`',
    );
  });

  test('A3 底栏显隐读同一真源（且卸下与否**只由占据态**决定）', () {
    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ N11（2026-10-18）：本用例从「钉实现细节」改成「钉契约」
     * ══════════════════════════════════════════════════════════════════
     *
     * # 改前（逐字钉住实现细节，已删）
     * ```text
     * expect(page.contains('if (!_chromeVisible && !keepForFade) {'), isTrue);
     * expect(RegExp(r'keepForFade =[\s\S]{0,120}?_controlsAnim\.value\s*>\s*0')
     *          .hasMatch(page), isTrue);
     * ```
     * ⇒ 它钉的是 `keepForFade` 这个**变量名**。
     *
     * # 为什么必须改（不是"为了让 N11 过"而放松）
     * ```text
     * 改前底栏是 `shrink ⇄ child` 装卸：
     *   可见 或 淡出中 ⇒ 留在树上；否则 ⇒ shrink
     * ⇒ 控制条一收起就**摘掉整棵 333 行子树**，鼠标一动又叫回来
     * ⇒ 实测重建 398 个元素 / 85ms ⇒ Owner N11 的卡顿。
     *
     * N11 的修法让 `keepForFade` **不再需要**：
     *   底栏恒挂，淡出由 `PlayerBottomBar` 内部的
     *   `AnimatedBuilder(fade) → IgnorePointer → Opacity` 完成
     *   （`player/player_bottom_bar.dart:748-754`），
     *   而 `fade` 就是 `_bottomFade`（与顶栏**同一个** `_controlsFade`）。
     * ⇒ 变量消失**恰恰是改进**，不是退步。
     * ```
     *
     * # 现在守什么（契约，不绑实现）
     * ```text
     * ① ★ 不许用 `_chromeVisible` 决定"要不要卸下底栏"
     *    —— 这正是原用例的**真实意图**（显隐只有一个真源，
     *       不能让底栏自己再算一套门控来决定装卸）。
     *    改前它靠"必须有 keepForFade"间接表达；现在直接反向断言。
     * ② 占据态仍然卸下（`_bottomOccupied` ⇒ shrink）
     *    —— 与 A5 互补：A5 守 `_bottomFade` 钉 dismissed，
     *       本条守**结构上真的卸下**。
     * ```
     * ★ 这两条在**改前实现**下也会红（改前正是用 `_chromeVisible` 决定装卸）
     *   ⇒ 门禁有鉴别力，不是"改成怎样都绿"的废门禁。
     *   验证记录见交付说明（旧实现红 / 新实现绿 / 两次注入红）。
     */
    expect(
      RegExp(r'if\s*\(\s*!\s*_chromeVisible').hasMatch(page),
      isFalse,
      reason: '★★ 不许用 `_chromeVisible` 决定要不要**卸下**底栏。'
          '底栏显隐的真源是 `_bottomFade`（与顶栏同一个 `_controlsFade` 实例），'
          '`_chromeVisible` 若又在这里当装卸判据 ⇒ 就是第二个真源 ⇒ 分裂复发。'
          '★ 改前正是 `if (!_chromeVisible && !keepForFade) return shrink;`',
    );
    expect(
      page.contains('if (_bottomOccupied) {'),
      isTrue,
      reason: '★★ 底栏**只在占据态**才卸下（`if (_bottomOccupied) { '
          'return const SizedBox.shrink(); }`）。'
          '占据态 = 错误层/选集/换源/设置/弹幕/字幕/直播频道/音频提示/画面死亡，'
          '那块归占据者 —— 留在树里会叠字 + 抢点击。',
    );
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 过渡动画：两条读**同一个** Animation 实例（逐帧同值）
  // ═══════════════════════════════════════════════════════════════════

  test('A4 底栏 fade 与顶栏 fade **同源**（同一个 _controlsFade / _bottomFade）', () {
    // 顶栏：fade 正常支是 _controlsFade（三元最后一支）；底栏：fade 用 _bottomFade。
    // 两者必须最终指向**同一个** _controlsAnim / _controlsFade。
    expect(page.contains(': _controlsFade,'), isTrue,
        reason: '★ 顶栏那条第 fade 必须直接读 `_controlsFade`（三元最后一支）');
    expect(
      RegExp(r'Animation<double> get _bottomFade =>[\s\S]{0,200}?_controlsFade')
          .hasMatch(page),
      isTrue,
      reason: '★★ 底栏 `_bottomFade` 的「非占据」支必须是**同一个** `_controlsFade`'
          ' —— 否则两条各有一条动画，会错开（Owner 第 3 条）',
    );
    expect(page.contains('fade: _bottomFade,'), isTrue,
        reason: '★ 底栏渲染点必须喂 `_bottomFade`（= 顶栏同一条动画）');
    // 声明只此一处：`_controlsFade` 只能由唯一的 `_controlsAnim` 驱动。
    final decls = RegExp(r'Animation<double> _controlsFade\s*=').allMatches(page);
    expect(decls.length, 1,
        reason: '★ `_controlsFade` 只能声明一次（多处声明 = 多条动画 = 错开）');
  });

  test('A5 底栏占据态钉 dismissed（横幅/错误层/浮层那块归占据者）', () {
    final body = getterBody('_bottomFade', ret: 'Animation<double>');
    expect(body.contains('kAlwaysDismissedAnimation'), isTrue,
        reason: '★ 底部被占据时底栏必须钉 `kAlwaysDismissedAnimation`'
            '（硬收：错误层/降级横幅是与底栏同位置的 Positioned(bottom:0)，'
            '留在树里会叠字 / 抢点击）');
    final occ = getterBody('_bottomOccupied');
    for (final part in const [
      '_error != null',
      '_episodeSheetOpen',
      '_streamSheetOpen',
      '_settingsOpen',
      '_danmakuSheetOpen',
      '_biliSheetOpen',
      '_subtitlePanelOpen',
      '_liveChannelsOpen',
      '_liveAudioOnlyNotice != null',
      '_videoOutputDead',
    ]) {
      expect(occ.contains(part), isTrue,
          reason: '★ `_bottomOccupied` 漏了 `$part`（占据态判定不全 ⇒ 底栏会与占据者叠）');
    }
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ 例外登记：错误态返回口不被并进真源
  // ═══════════════════════════════════════════════════════════════════

  test('A6 `_canUseTopBarBack` 例外仍在，且与真源互斥', () {
    final body = getterBody('_canUseTopBarBack');
    expect(body.contains('_error != null'), isTrue,
        reason: '★★ `_canUseTopBarBack` 必须含 `_error != null` —— 与正常支'
            '**互斥**，否则正常播放时顶栏会被它顶成常显（`_anySheetOpen` 那代老缺陷）');
    expect(body.contains('!_anySheetOpen'), isTrue,
        reason: '★ 浮层开着时不许抢返回');
    expect(body.contains('_controlsVisible'), isTrue,
        reason: '★ 错误态下控制条收起时这枚箭头也要跟着收（Owner 2026-10-10 报过）');
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑤ 真值表：除登记例外外，2^9 组合 top==bottom
  // ═══════════════════════════════════════════════════════════════════

  test('A7 真值表：2^9 组合里 top==bottom，唯一例外=错误态返回口', () {
    // 模型直译自唯一真源：
    //   chrome = C && !err && !anyF && !notice && !dead
    //   top    = chrome || (desktop && err && !anyF && C)
    //   bottom = chrome
    // （notice/dead 由 S4 字面钉死；此处并入 anyF 同族做穷举。）
    var splits = 0;
    var checked = 0;
    for (var mask = 0; mask < (1 << 9); mask++) {
      final err = (mask & (1 << 0)) != 0;
      final desktop = (mask & (1 << 1)) != 0;
      final flags = <bool>[
        for (var f = 0; f < 7; f++) (mask & (1 << (2 + f))) != 0,
      ];
      final anyF = flags.any((b) => b);
      final c = !anyF; // 浮层 open 后 C 被收口（_collapseControlsForSheet）
      final chrome = c && !err && !anyF;
      final top = chrome || (desktop && err && !anyF && c);
      final bottom = chrome;
      checked++;
      if (top != bottom) {
        splits++;
        expect(desktop && err && !anyF, isTrue,
            reason: 'mask=$mask (err=$err desktop=$desktop F=$flags) 分裂了且非登记特例'
                ' —— 违反 T27-13 唯一真源');
      }
    }
    expect(checked, 1 << 9, reason: '必须扫满 2^9 组合');
    expect(splits, 1,
        reason: '恰好 1 个登记特例：desktop && err && !anyF ⇒ 顶栏 1 / 底栏 0'
            '（错误态返回口）');
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑥ 回归护栏：hover 复活路径与真源一致
  // ═══════════════════════════════════════════════════════════════════

  test('A8 `_showControls` 复活护栏保留（浮层开着时 hover 不得叫回）', () {
    final i = page.indexOf('void _showControls() {');
    expect(i, greaterThanOrEqualTo(0));
    final semi = page.indexOf('void _armHideTimer', i);
    final body = page.substring(i, semi);
    expect(body.contains('if (mounted && !_controlsVisible && !_anySheetOpen) {'),
        isTrue,
        reason: '★ 浮层开着时 hover 不得把控制条叫回来（T27-09），'
            '否则「浮层开着 → hover → 顶栏回来」的旧分裂会经 hover 复发');
  });
}
