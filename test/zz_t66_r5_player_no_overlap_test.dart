// ═══════════════════════════════════════════════════════════════════════
//  R5 — 直播页播放窗口「没契合」：内容溢出被裁
// ═══════════════════════════════════════════════════════════════════════
//
// # ★★★ 本文件推翻了上一轮的假设（先读这段，否则会重走弯路）
//
// 上一轮（`live-ux` / Lead）认定：`▶`/`🔇` 与 `lineSwitcher` 的 chip 重叠。
// **这个假设是错的。** 本轮用像素反解证明：
//
// ```text
// ① 那张"证据"截图里 chip 的文案是「次元城动画 / 哔哩哔哩 / 影视建安 /
//    360资源-采集 / 百度 / 光速资源(切) / 新浪资源(切) / 25 个源」
//    ⇒ 这是**首页的源切换条** `SourceBar`（`lib/ui/widgets/source_bar.dart`）。
//    ★ `lib/ui/live_page.dart` 里 `SourceBar` 出现 **0 次**（`grep -c` = 0）
//      ⇒ 直播页**不可能**画出那排 chip。
//
// ② 那张图的**播放窗口整体是半透明的**：纯黑卡片的实测像素是 (120,121,124)，
//    而页面底色是 (238,240,246)
//        ⇒ 黑色层的等效不透明度 = 1 − 120/238 = **0.4958 ≈ 50%**
//    ⇒ 它不是"稳态下控件被 chip 盖住"，而是**切页过渡途中**的一帧
//      （保活 Stack 交叉淡入：新页 enter + 旧页 leave，见 `shell.dart`
//       `_KeepAliveTransition` / `_leavingFade`）。
//
// ③ 定量验证（`.probe/r5_xfade_compare.png` 上下一半肉眼可对）：
//    用**同一台机器**自己拍的稳态两帧（home / live，900×600）按
//    `0.5·live + 0.5·(0.5·home + 0.5·bg)` 合成，与 Owner 那张裁片的
//    平均绝对误差 MAE = **12.9/255**；而「单页稳态」模型 MAE = **93~102**
//    ⇒ 只有"过渡叠加"能解释那张图。
// ```
//
// # ⇒ 所以真正的缺陷是：**播放窗口在 900×600 下装不下自己的内容**
//
// ```text
// 真机读数（`.probe/r5_live900.png`，900×600，稳态）：
//   播放窗口（黑卡）  x 24..555  y 154..509   = 532 × 356
//   视频（16:9）      532 × 299.3              （532×9/16 = 299.25 ✅）
//   ⇒ 只剩 356 − 299.3 = 56.7px 给线路 chip
//   ⇒ 而 chip 一行高 28 + padding 8 = 36px ⇒ **两行就要 72px**
//   ⇒ 两行以上时 Column 溢出 ⇒ 底部被 `ClipRRect` 裁掉
// ```
//
// 本轮实测（一次性探针，已删除）：
// ```text
// clip 532×356   n=2  ⇒ chip 317.6..345.6  ✅
// clip 532×356   n=4  ⇒ chip 307.3..371.3  ✗ 溢出 15.3px
// clip 532×356   n=8  ⇒ chip 307.3..407.3  ✗ 溢出 51.3px
// clip 1074×600  n=8  ⇒ chip 678.6..742.6  ✅  ← 这就是「1444 不复现」
// ```
//
// # 修法：`Flexible` 包住 `AspectRatio`
// ```text
// 让**视频**让出 chip 需要的高度（按 16:9 等比缩，实测 r 恒 = 1.778）
// ⇒ chip 永远完整可见；视频只变矮、不变形。
// ```
//
// # ★ 本门禁为什么用「复刻 + 源码契约」两条腿
// ```text
// 实测（`.probe/probe_tests/zz_r5_mount_test.dart`）：在 flutter_test 里挂
//   `LivePage` ⇒ 停在 loading（`_groups` 只由 FFI 填，`AspectRatio` 数=0）
//   ⇒ wide body **根本不会被构建** ⇒ 直接挂整页是**假绿**。
// ⇒ 几何断言只能用复刻；另用 R5-S 把复刻与实现钉在一起。
// ```
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/tokens.dart';

/// 播放窗口（黑卡）的**真实**实测尺寸 —— 不是算出来的
///
/// ```text
/// 900×600  : x 24..555 = 532 , y 154..509 = 356    ← `.probe/r5_live900.png`
/// 1444×845 : x 25..1099 = 1074, y 154..754 = 600   ← 同一次真机连拍
/// ```
const _clips = <({String label, Size size, int rep})>[
  // ⚠️ `rep` 必须够多，让 chip **折成 2 行**（1 行时修复前也不溢出，测不出缺陷）
  //    实测：clip 宽 532 下 4 条起折 2 行；这里用 9 条稳超。
  (label: '900x600', size: Size(532, 356), rep: 9),
  (label: '1444x845', size: Size(1074, 600), rep: 9),
];

/// `_EmbedBar` 的高度（`live_embedded_player.dart`：`Positioned(bottom:0)` +
/// Row 内 `_RoundBtn` = padding 6×2 + icon 20 = 32，外层 Container 竖向 padding 8×2）
const double _barH = 48;

/// 复刻「播放器」：一个铺满的深色底 + 贴底的控件条
Widget _player() => Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Color(0xFF0A0A0A)),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            key: const ValueKey('r5-bar'),
            height: _barH,
            color: const Color(0x66000000),
          ),
        ),
      ],
    );

/// 复刻「线路切换器」：**与实现同构** —— `Padding(top:8) > Wrap(spacing/runSpacing:8)`
///
/// ⚠️ chip 宽度取实测值：`_LineChip` 是 `ChoiceChip` + `padding horizontal 12`，
///    文案「高清/标清/备用」在 12px 字号下实宽约 92px（`.probe` 里量到的
///    `W=114` 含左右各 12 padding + 24 的 chip 内边距）。
///    这里用固定 110 宽 + 28 高的 `SizedBox` 包 `Chip`，只为**让 Wrap 的换行
///    行为与真实一致**（换行位置决定 chip 占几行，那是本缺陷的自变量）。
Widget _lineSwitcher(int n) => n <= 1
    ? const SizedBox.shrink()
    : Padding(
        padding: const EdgeInsets.only(top: Sp.x2),
        child: Wrap(
          key: const ValueKey('r5-lines'),
          spacing: Sp.x2,
          runSpacing: Sp.x2,
          children: [
            for (var i = 0; i < n; i++)
              SizedBox(
                height: 28,
                child: Chip(
                  label: Text('线路$i', style: const TextStyle(fontSize: 12)),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
          ],
        ),
      );

/// 复刻 `_buildWideBody` 的播放器那一栏
///
/// `flexed=false` ⇒ **修复前**的形状（`AspectRatio` 直接作为 Column 子项）
/// `flexed=true`  ⇒ **修复后**的形状（`Flexible` 包住 `AspectRatio`）
Widget _wideBody({
  required int lines,
  required Size clip,
  required bool flexed,
}) {
  final video = AspectRatio(
    key: const ValueKey('r5-video'),
    aspectRatio: 16 / 9,
    child: _player(),
  );

  return SizedBox(
    width: clip.width,
    height: clip.height,
    child: ClipRRect(
      key: const ValueKey('r5-clip'),
      borderRadius: Radii.rLg,
      child: ColoredBox(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (flexed) Flexible(child: video) else video,
              _lineSwitcher(lines),
            ],
          ),
        ),
      ),
    ),
  );
}

Widget _host(Widget body) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(body: Center(child: body)),
    );

/// 剥掉 `//` 与 `/* */` 注释（保留字符串字面量）
///
/// ★ 必须有：`_buildWideBody` 里有大段解释性注释，其中**故意**引用了
///   修复前的代码形状。不剥注释 ⇒ 结构断言会把注释里的反例当真代码。
String _stripComments(String s) {
  final out = StringBuffer();
  var i = 0;
  String? q;
  while (i < s.length) {
    final c = s[i];
    if (q != null) {
      out.write(c);
      if (c == r'\' && i + 1 < s.length) {
        out.write(s[i + 1]);
        i += 2;
        continue;
      }
      if (c == q) q = null;
      i++;
      continue;
    }
    if (c == "'" || c == '"') {
      q = c;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && i + 1 < s.length && s[i + 1] == '/') {
      while (i < s.length && s[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && i + 1 < s.length && s[i + 1] == '*') {
      i += 2;
      while (i + 1 < s.length && !(s[i] == '*' && s[i + 1] == '/')) {
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

/// 从**产品源码**读出「视频是否被 `Flexible` 包住」
///
/// ★ 这是本门禁的**锚**：几何断言用它决定复刻成哪一种形状。
///   这样产品一旦退回旧形状，R5-G 会**自己**红 —— 不靠 R5-S 兜底。
bool _implWrapsVideoInFlexible() {
  final src = File('lib/ui/live_page.dart').readAsStringSync();
  final i = src.indexOf('Widget _buildWideBody(');
  expect(i, greaterThan(0), reason: '找不到 `_buildWideBody`');
  final rest = src.substring(i);
  final end = rest.indexOf('\n  Widget ', 1);
  final body = _stripComments(end > 0 ? rest.substring(0, end) : rest);
  return RegExp(r'Flexible\(\s*child:\s*AspectRatio\(').hasMatch(body);
}

void main() {
  // ════════════════════════════════════════════════════════════════════
  //  R5-G：几何断言 —— 控件条与线路 chip 都必须完整落在播放窗口内
  //
  //  ★★ `flexed` **从产品源码读**，不是写死 true。
  //     写死 true 的话：产品被改回旧形状 ⇒ 本组仍然绿 ⇒ **假绿**（我实测确认过）。
  //     现在读源码 ⇒ 产品退回旧形状 ⇒ 本组**自己就红**，不必依赖 R5-S。
  // ════════════════════════════════════════════════════════════════════
  group('R5-G 播放窗口必须装得下自己（控件 + 线路 chip）', () {
    for (final c in _clips) {
      testWidgets('${c.label}：${c.rep} 条线路（2 行）也要完整可见', (t) async {
        t.view.physicalSize = const Size(1700, 1200);
        t.view.devicePixelRatio = 1.0;
        addTearDown(t.view.reset);

        await t.pumpWidget(_host(_wideBody(
          lines: c.rep,
          clip: c.size,
          flexed: _implWrapsVideoInFlexible(), // ← 从产品源码读
        )));
        await t.pump();
        await t.pump(const Duration(milliseconds: 60));

        final clip = t.getRect(find.byKey(const ValueKey('r5-clip')));
        final bar = t.getRect(find.byKey(const ValueKey('r5-bar')));
        final vid = t.getRect(find.byKey(const ValueKey('r5-video')));
        final lines = t.getRect(find.byKey(const ValueKey('r5-lines')));

        // ① 控件条必须完整在播放窗口内
        expect(
          bar.bottom,
          lessThanOrEqualTo(clip.bottom + 0.5),
          reason: '${c.label} ★★ 播放/静音控件条跑出了播放窗口！\n'
              '  控件条 bottom = ${bar.bottom.toStringAsFixed(1)}\n'
              '  播放窗口 bottom = ${clip.bottom.toStringAsFixed(1)}\n'
              '  超出 = ${(bar.bottom - clip.bottom).toStringAsFixed(1)}px\n'
              '  ⇒ 正是 Owner 说的「静音按钮一半没显示出来」。',
        );

        // ② 线路 chip 必须完整在播放窗口内（★ 这是修复前会红的那条）
        expect(
          lines.bottom,
          lessThanOrEqualTo(clip.bottom + 0.5),
          reason: '${c.label} ★★ 线路 chip 被播放窗口裁掉了！\n'
              '  chip bottom = ${lines.bottom.toStringAsFixed(1)}\n'
              '  播放窗口 bottom = ${clip.bottom.toStringAsFixed(1)}\n'
              '  被裁 = ${(lines.bottom - clip.bottom).toStringAsFixed(1)}px\n'
              '  ⇒ 根因：Column 里视频按满宽算高，chip 再往下排 ⇒ 溢出被裁。\n'
              '  ⇒ 修法：视频必须能被 Flexible 压缩（见 R5-S）。',
        );

        // ③ 视频仍然是 16:9（修法不许把画面拉变形）
        expect(
          vid.width / vid.height,
          closeTo(16 / 9, 0.01),
          reason: '${c.label} 视频比例被改坏了：'
              '${vid.width.toStringAsFixed(1)}x${vid.height.toStringAsFixed(1)}'
              ' = ${(vid.width / vid.height).toStringAsFixed(3)}（应为 1.778）',
        );
      });
    }
  });

  // ════════════════════════════════════════════════════════════════════
  //  R5-S：源码结构契约 —— 把「复刻」与「实现」钉在一起
  //
  //  ★ 复刻本身证明不了产品对。若有人把 `Flexible` 删了，复刻没删 ⇒
  //    R5-G 继续绿而产品坏掉。R5-S 就是堵这个洞。
  // ════════════════════════════════════════════════════════════════════
  group('R5-S `_buildWideBody` 结构契约', () {
    /// 取 `_buildWideBody` 的方法体（到下一个顶层方法为止）
    String wideBody() {
      final src = File('lib/ui/live_page.dart').readAsStringSync();
      final i = src.indexOf('Widget _buildWideBody(');
      expect(i, greaterThan(0), reason: '找不到 `_buildWideBody`');
      final rest = src.substring(i);
      // 方法体里一定有 `Row(` 与 `SizedBox(width: 300`
      final end = rest.indexOf('\n  Widget ', 1);
      return end > 0 ? rest.substring(0, end) : rest;
    }

    test('S1 ★ AspectRatio 必须被 Flexible 包住', () {
      final body = wideBody();

      /*
       * 契约（修复后的形状）：
       *   Column(children: [ Flexible(child: AspectRatio(...)), lineSwitcher ])
       * 反例（修复前）：
       *   Column(children: [ AspectRatio(...), lineSwitcher ])
       *
       * ★ 判据用"Flexible 与 AspectRatio 相邻"而不是"Flexible 存在"——
       *   后面 `SizedBox(width: 300...)` 之类也可能引入别的 Flexible，
       *   单纯 contains 会假绿。
       */
      final wrapped = RegExp(
        r'Flexible\(\s*child:\s*AspectRatio\(',
      ).hasMatch(body);
      expect(
        wrapped,
        isTrue,
        reason: '★★ `_buildWideBody` 里的视频没有 `Flexible(child: AspectRatio(...))`。\n'
            '  ⇒ 视频会按**满宽**把高度吃满，剩下给线路 chip 的空间不够\n'
            '  ⇒ Column 溢出 ⇒ 被 ClipRRect 裁 ⇒ chip/控件被裁一半（R5 复发）。\n'
            '  实测：900×600 下视频 299.3 + 两行 chip 72 > 可用高 356。',
      );
    });

    test('S2 ★ 不许退回"裸 AspectRatio 直接当 Column 子项"', () {
      /*
       * ⚠️ 这条必须**先剥注释**再判 —— 本仓惯例：`_buildWideBody` 里有
       *    大段解释性注释（含我写的反例代码片段），不剥会把注释里的
       *    `AspectRatio(` 数进去 ⇒ 假红。
       * ★ 上一版就是因为没剥注释、又把窗口写成固定 400 字符，
       *   结果在"注入返回旧形状"时**仍然是 false**（判据失效，我实测过）。
       */
      final body = _stripComments(wideBody());

      /*
       * 反例精确形态（修复前）：
       *   children: [
       *     AspectRatio(aspectRatio: 16 / 9, child: player),
       *     lineSwitcher,
       *   ]
       * 即：`children:` 之后、**遇到 `Flexible(` 之前**就出现了 `AspectRatio(`
       */
      final bare = RegExp(
        r'children:\s*\[((?:(?!Flexible\()[\s\S])*?)AspectRatio\(',
      ).hasMatch(body);
      expect(
        bare,
        isFalse,
        reason: '★★ `_buildWideBody` 的 Column children 里又出现**裸** AspectRatio 了。\n'
            '  ⇒ 它会与 lineSwitcher 抢 Column 的高度预算 ⇒ 溢出被裁。\n'
            '  修复后的形状必须是 `Flexible(child: AspectRatio(...))`。',
      );
    });

    test('S3 阴性自检：S1 的判据在"修复前形状"上必须为 false', () {
      // 这条**不读产品源码**，只证明判据本身有分辨力（否则 S1 可能恒真）。
      const before = '''
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AspectRatio(aspectRatio: 16 / 9, child: player),
            lineSwitcher,
          ],
        ),''';
      const after = '''
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: AspectRatio(aspectRatio: 16 / 9, child: player)),
            lineSwitcher,
          ],
        ),''';
      final re = RegExp(r'Flexible\(\s*child:\s*AspectRatio\(');
      expect(re.hasMatch(before), isFalse,
          reason: '★ 自检失败：判据在"修复前形状"上竟然是 true ⇒ S1 恒真 ⇒ 假绿');
      expect(re.hasMatch(after), isTrue,
          reason: '★ 自检失败：判据在"修复后形状"上是 false ⇒ S1 会假红');
    });

    test('S4 阴性自检：S2 的判据在"修复前形状"上必须为 true', () {
      /*
       * 与 S3 同族：证明 S2 的判据有分辨力。
       * ⚠️ 这里**不能**用 `wideBody()`，只能喂形状字符串 ——
       *    S2 读的是产品源码，而"修复前形状"只能靠构造。
       */
      const before = '''
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AspectRatio(aspectRatio: 16 / 9, child: player),
              lineSwitcher,
            ],
          ),''';
      const after = '''
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: AspectRatio(aspectRatio: 16 / 9, child: player),
              ),
              lineSwitcher,
            ],
          ),''';
      final re = RegExp(
        r'children:\s*\[((?:(?!Flexible\()[\s\S])*?)AspectRatio\(',
      );
      expect(re.hasMatch(before), isTrue,
          reason: '★ 自检失败：S2 的判据认不出"修复前形状" ⇒ S2 是假绿');
      expect(re.hasMatch(after), isFalse,
          reason: '★ 自检失败：S2 的判据把"修复后形状"也判成裸 AspectRatio ⇒ S2 假红');
    });

    test('S5 阴性自检：_stripComments 真的能剥掉注释里的旧写法', () {
      const withComment = '''
      Column(
        children: [
          // AspectRatio(aspectRatio: 16/9, child: player),
          lineSwitcher,
        ],
      )''';
      final stripped = _stripComments(withComment);
      expect(stripped.contains('AspectRatio('), isFalse,
          reason: '★ 自检失败：注释里的 AspectRatio 没被剥掉 ⇒ S2 会假红');
      expect(stripped.contains('lineSwitcher'), isTrue,
          reason: '剥注释不能把真代码也剥掉');
    });
  });

  // ════════════════════════════════════════════════════════════════════
  //  R5-N：阴性对照 —— 证明 R5-G 的判据不是恒真
  //
  //  ★ 必须用**修复前的形状**跑，判据必须**红**。
  //    上一轮的教训：它的阴性对照测的是"控件条 vs lineSwitcher 的重叠"，
  //    而修复前那两个**本来就不重叠** ⇒ 阴性对照红不了 ⇒ 那条判据测错了对象。
  //    本轮的判据是「chip 是否被播放窗口裁掉」，修复前**确实会裁**。
  // ════════════════════════════════════════════════════════════════════
  group('R5-N 阴性对照', () {
    testWidgets('修复前的形状（无 Flexible）⇒ chip 必须被裁（判据有效）', (t) async {
      t.view.physicalSize = const Size(1700, 1200);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      await t.pumpWidget(_host(_wideBody(
        lines: 9, // 900×600 下会折成 2 行
        clip: const Size(532, 356),
        flexed: false, // ← 故意用修复前的形状
      )));
      await t.pump();
      await t.pump(const Duration(milliseconds: 60));

      // 溢出会让 Flutter 抛 RenderFlex overflow —— 先把它吃掉，
      // 否则 `takeException` 会在别处炸（我们只想看几何）。
      final exc = t.takeException();

      final clip = t.getRect(find.byKey(const ValueKey('r5-clip')));
      final lines = t.getRect(find.byKey(const ValueKey('r5-lines')));

      // ignore: avoid_print
      print('[R5-N] 修复前结构：chip.bottom=${lines.bottom.toStringAsFixed(1)} '
          'clip.bottom=${clip.bottom.toStringAsFixed(1)} '
          '被裁=${(lines.bottom - clip.bottom).toStringAsFixed(1)}px '
          'overflow异常=${exc == null ? "无" : exc.runtimeType}');

      expect(
        lines.bottom,
        greaterThan(clip.bottom),
        reason: '★★ 阴性对照失败：修复前的形状竟然**没有**把 chip 裁掉。\n'
            '  ⇒ 说明复刻没有重现真机几何 ⇒ R5-G 的绿不可信（可能恒真）。\n'
            '  实测 chip.bottom=${lines.bottom}，clip.bottom=${clip.bottom}',
      );
    });
  });
}
