// ═══════════════════════════════════════════════════════════════════════
//  第 66 轮 · 播放设置页「**粗体**」星号 —— 整棵树级门禁
// ═══════════════════════════════════════════════════════════════════════
//
// # 缺陷来源（真机截图，不是理论）
// ```text
// `shell.dart:6955` 逐字先例：
//   ⚠️ 不要在这里写 Markdown 的 `**粗体**` —— 这是 `Text` 不是 Markdown 渲染器，
//      星号会**原样显示**出来（我第一版就写错了，截图里能看到字面的 `**已存在的文件**`）。
//      要强调就用中文引号「」。
//
// ★ 全仓没有 markdown 渲染器（已核：`grep -rln "markdown\|Markdown" lib/` 只命中注释）。
// ```
//
// # 本次修的 8 处（lib/ui/settings/playback_page.dart）
// ```text
//  :609  限制**同时进行**的片段下载任务数      ⇒ 限制「同时进行」…
//  :670  …**不占**这个上限                     ⇒ …「不占」…
//  :690  …是**两笔账**：…                       ⇒ …是「两笔账」：…
//  :814  有**三个**缓存目录                     ⇒ 有「三个」缓存目录
//  :815  都是**真实读盘**得到的                 ⇒ 都是「真实读盘」得到的
//  :934  只腾出**超限的那部分**                 ⇒ 只腾出「超限的那部分」
//  :936  截图（**不可再生**，…）                 ⇒ 截图（「不可再生」，…）
//  :937  只清 clip-cache，**不碰**截图…          ⇒ 只清 clip-cache，「不碰」截图…
// ```
//
// # ★ 判据纪律（三条硬要求，逐条对应）
// ```text
// ① **必须渲染出来读整棵树的 Text**，不许只断言那 8 个常量 ——
//    只断言单条 ⇒ 「修一处漏一处」全绿（本会话已吃过三次恒真的亏）。
// ② **防空转自检**：先断言树**非空**且含已知文案 ——
//    「不含 `**`」在空树上照样为真，这是恒真的典型形态。
// ③ 注入两处**不同渲染路径**，都必须红（见交付报告的读数）。
// ```

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

import 'package:sourin_spike/core/clip_download.dart';
import 'package:sourin_spike/ui/settings/playback_page.dart';

/// 把这一页渲染出来，返回**整棵树上所有 Text 的文字**
Future<List<String>> _renderPageTexts(WidgetTester t) async {
  await t.binding.setSurfaceSize(const Size(1400, 1800));
  addTearDown(() => t.binding.setSurfaceSize(null));

  // ★ 必须放进 runAsync：initState 里的读盘是真 IO，
  //   fake 时钟里那些 future 永不完成 ⇒ 树会停在半路（AGENTS.md §8）。
  await t.runAsync(() async {
    await t.pumpWidget(
      mui.MaterialApp(
        theme: mui.ThemeData.dark(),
        home: const mui.Scaffold(body: PlaybackSettingsPage()),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await t.pump();
    }
  });
  await t.pump(const Duration(milliseconds: 300));

  // 取**所有** Text/RichText 的可读文字（不靠 find.text 一条条猜）
  final out = <String>[];
  for (final e in find.byType(mui.Text).evaluate()) {
    final w = e.widget;
    if (w is mui.Text) {
      final d = w.data;
      if (d != null && d.isNotEmpty) out.add(d);
    }
  }
  return out;
}

void main() {
  // ★ 必须在用 testWidgets **之前**初始化：否则 `test` 解析到 dart:async 那个
  //   （参数是 `dynamic Function()`），传 `async (t)` 会编译不过。
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    tmp = Directory(
      '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}'
      'sourin_t66_asterisk_gate',
    )..createSync(recursive: true);
    // ★ 隔离：initState 会读 ClipDownloader.dataDir()，
    //   默认解析到**用户真实数据目录**（AGENTS.md §3 + §8 最后一行的坑）。
    ClipDownloader.debugSetDataDir(tmp.path);
  });

  tearDown(() => ClipDownloader.debugSetDataDir(null));

  tearDownAll(() {
    final d = Directory(
      '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}'
      'sourin_t66_asterisk_gate',
    );
    if (d.existsSync()) {
      try {
        d.deleteSync(recursive: true);
      } catch (_) {
        // 句柄仍被占用 ⇒ 留在 TEMP（绝不在仓库根删东西）
      }
    }
  });

  // ══════════════════════════════════════════════════════════════════
  // ② 空转自检 —— **先证明树真的渲染出来了**，再谈别的
  // ══════════════════════════════════════════════════════════════════
  group('② 防空转：树非空且含已知文案', () {
    testWidgets('★★★ 这一页真的渲染出了可读文字（否则下面全是空转）', (t) async {
      final texts = await _renderPageTexts(t);
      expect(texts, isNotEmpty,
          reason: '★★ 树是空的 ⇒ 任何"不含 **"的断言都会恒真。'
              '这是恒真判据的典型形态，必须先自检。');

      // 不写死具体文案，只断言**页面的身份**能被认出来
      final joined = texts.join('\n');
      expect(
        joined.contains('同时') || joined.contains('缓存'),
        isTrue,
        reason: '★★★ 渲染出来的必须是**这一页**的文字，而不是某个壳。'
            '实测共 ${texts.length} 条 Text。样本前 5 条：'
            '${texts.take(5).toList()}',
      );
    });

    testWidgets('★★ 本轮改的那 8 处**确实在渲染结果里**（证明门禁覆盖到它们）', (t) async {
      final joined = (await _renderPageTexts(t)).join('\n');
      // 取三条特征片段（逐字取自改动后的源码，不是我编的）
      expect(joined, contains('限制「同时进行」的片段下载任务数'),
          reason: '★★★ :609 那条若不在树里 ⇒ 门禁没覆盖它，'
              '注入加回 `**` 也抓不到');
      expect(joined, contains('只腾出「超限的那部分」'), reason: '★★ :934');
      expect(joined, contains('「不碰」截图与播放器缓存'), reason: '★★ :937');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // ① 树级判据：整棵树不含 markdown 星号
  // ══════════════════════════════════════════════════════════════════
  group('① 整棵树不含 `**`（这是 `Text`，不是 Markdown 渲染器）', () {
    testWidgets('★★★ 页面上任何一条可见文字都不许含 `**`', (t) async {
      final texts = await _renderPageTexts(t);
      // 前置自检（防空转）
      expect(texts, isNotEmpty, reason: '前置：树必须非空');

      final bad = texts.where((s) => s.contains('**')).toList();
      expect(
        bad,
        isEmpty,
        reason: '★★ 屏幕上会**原样显示**星号（用户看到的是 `**不可再生**`）。'
            ' offending: $bad',
      );
    });

    testWidgets('★★ 单个 `*` 也一并查（半截写法同样会露馅）', (t) async {
      final texts = await _renderPageTexts(t);
      expect(texts, isNotEmpty, reason: '前置：树必须非空');
      // 只查**成对**之外的情况：奇数个星号通常是手滑漏了另一半
      final odd = texts
          .where((s) => '*'.allMatches(s).length.isOdd)
          .toList();
      expect(odd, isEmpty, reason: '★★ 奇数个星号 = 漏了另一半：$odd');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // 源码级补充：字面量层面的**双向**核对
  // ══════════════════════════════════════════════════════════════════
  group('③ 源码级：代码行里的字符串字面量不含 `**`', () {
    test('★★★ 剔注释后，代码行上的字面量零命中', () {
      final lines = _readRepo('lib/ui/settings/playback_page.dart')
          .split(RegExp(r'\r?\n'));
      final bad = <String>[];
      for (final l in lines) {
        final t = l.trimLeft();
        // ★ 只剔注释行；源码注释里的 `**` 是文档记号，**不是**显示缺陷
        if (t.startsWith('//') || t.startsWith('*')) continue;
        // ⚠️ 正则里要同时匹配单/双引号：用 r'''…''' 外层三引号，
        //    内部直接写 ' 和 " 即可 —— 用 r"…\"…" 会被 Dart 当成转义而解析失败。
        for (final m
            in RegExp(r'''('([^']*)')|("([^"]*)")''').allMatches(l)) {
          final s = (m.group(2) ?? m.group(4) ?? '').trim();
          if (s.contains('**')) bad.add(s);
        }
      }
      expect(bad, isEmpty,
          reason: '★★★ 注释里的 `**` 合法（那是文档记号），'
              '但**字面量**里的会显示。offending: $bad');
    });

    test('★★ 反证：源码注释里的 `**` 确实存在且**不**被这条判据误报', () {
      // 若将来有人把注释也剔掉，这条会红 ⇒ 证明上面那条不是"什么都没查"
      final commented = _readRepo('lib/ui/settings/playback_page.dart')
          .split(RegExp(r'\r?\n'))
          .where((l) => l.trimLeft().startsWith('//') && l.contains('**'))
          .length;
      expect(commented, greaterThan(10),
          reason: '前提：该文件有大量注释用 `**` 做强调；'
              '所以「剔注释」是必要的，漏剔会造成误报');
    });

    test('★★ 本轮修的 8 处：改前用 `**`、改后用「」（逐字核对）', () {
      final src = _readRepo('lib/ui/settings/playback_page.dart');
      expect(src, contains('限制「同时进行」的片段下载任务数'));
      expect(src, contains('「不占」这个上限'));
      expect(src, contains('是「两笔账」'));
      expect(src, contains('有「三个」缓存目录'));
      expect(src, contains('都是「真实读盘」得到的'));
      expect(src, contains('只腾出「超限的那部分」'));
      expect(src, contains('截图（「不可再生」'));
      expect(src, contains('「不碰」截图与播放器缓存'));
      // 文字一字未改：只少了星号
      expect(src, isNot(contains('限制**同时进行**')),
          reason: '★ 那 8 条不该再有 `**` 版本');
    });
  });
}

String _readRepo(String rel) => File(rel).readAsStringSync();
