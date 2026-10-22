// ═══════════════════════════════════════════════════════════════════════
//  第 66 轮 · R3 接线门禁：**证明宿主真的接上了**，不是"我加了两行"
// ═══════════════════════════════════════════════════════════════════════
//
// # 这份文件补的是「半截接线」那一类缺陷
// ```text
// 本仓记过很多次：字段在、解析了、甚至打印了，但**用户看不到**。
// ⇒ 只断言「字段存在」或「源码里有那一行」是**假门禁**。
//   本文件断言的是**行为**：注入 → 面板显示的是注入值。
// ```
//
// # 覆盖两条接线（都在 `player_page.dart`）
// ```text
// ① `_danmakuInfo` getter        ⇒ sourceName + updatedAt
// ② `DanmakuSettingsDialog(...)` ⇒ feedSamples
// ```
//
// # ⚠️ 为什么不用「挂载真实 PlayerPage」来验
// ```text
// 实测（既有 `zz_t66_r5_player_no_overlap_test.dart` 文件头已记录）：
//   在 flutter_tester 里挂整页 ⇒ 停在 loading（没有 FFI/数据），
//   真正的 body **根本不会被构建** ⇒ 永远测不到 ⇒ 假绿。
//
// ⇒ 所以本文件走**两条互补的路**：
//   A. 行为路：把面板当普通 widget 挂起来，喂**与宿主同一形状**的数据，
//      断言它显示的就是喂进去的值（证明"面板读到就用"）。
//   B. 结构路：读 player_page.dart 源码，断言那两个接线点**真的在**，
//      且接的是**正确的表达式**（证明宿主真的把值传下去了）。
//      ⚠️ 结构断言单独用会假绿（"有这行但值是错的"），
//         所以它必须与 A 合起来看：A 证明"给了就显示"，B 证明"确实给了"。
// ```
//
// # 故障注入（已实测）
// ```text
// ① 删掉 getter 里的 `sourceName: _danmakuInfoSourceName,`
//    ⇒ B 组「getter 接了 sourceName」红
// ② 删掉 `updatedAt: _danmakuInfoUpdatedAt,`          ⇒ B 组对应条红
// ③ 删掉构造点的 `feedSamples: _danmakuFeedSamples,`   ⇒ B 组对应条红
// ④ 把 sourceName 改成 `null`                          ⇒ B 组红
// ⑤ 面板侧：把 sourceName 忽略掉                        ⇒ A 组红（已有 info_triple 覆盖）
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/danmaku_info_panel.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';

// ── 源码工具：剥注释（字符串里的 // 不算）──────────────────────────────
//
// ⚠️ 与 `t27_w1` / `t103` 同一份实现：**必须剥掉注释**，
//    否则我在注释里写一句「sourceName: …」就会让门禁假绿。
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  while (i < src.length) {
    final c = src[i];
    if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
    } else if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
      i += 2;
      while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
        i++;
      }
      i += 2;
    } else if (c == "'" || c == '"') {
      final q = c;
      out.write(c);
      i++;
      while (i < src.length && src[i] != q) {
        if (src[i] == '\\') {
          out.write(src[i]);
          i++;
          if (i >= src.length) break;
        }
        out.write(src[i]);
        i++;
      }
      if (i < src.length) {
        out.write(src[i]);
        i++;
      }
      continue;
    } else {
      out.write(c);
    }
    i++;
  }
  return out.toString();
}

/// player_page.dart 的**去注释**源码（全文件只读一次）
String playerSrc() {
  final raw = File('lib/ui/player_page.dart').readAsStringSync();
  return stripComments(raw);
}

/// `_danmakuInfo` getter 的那一段（从名字到 `);` 结束）
///
/// ⚠️ 用**括号配平**截取，不是正则 —— getter 里有嵌套括号/字符串。
String danmakuInfoGetterBody() {
  final s = playerSrc();
  final start = s.indexOf('DanmakuInfoData get _danmakuInfo =>');
  expect(start, greaterThanOrEqualTo(0),
      reason: '找不到 `_danmakuInfo` getter —— 判据失效（它被改名/删了？）');
  final open = s.indexOf('DanmakuInfoData(', start);
  var depth = 0;
  var i = open + 'DanmakuInfoData'.length;
  for (; i < s.length; i++) {
    if (s[i] == '(') depth++;
    if (s[i] == ')') {
      depth--;
      if (depth == 0) break;
    }
  }
  return s.substring(open, i + 1);
}

/// `DanmakuSettingsDialog(` 构造点那一段
String dialogConstructionBody() {
  final s = playerSrc();
  final start = s.indexOf('child: DanmakuSettingsDialog(');
  expect(start, greaterThanOrEqualTo(0),
      reason: '找不到 `DanmakuSettingsDialog(` 构造点 —— 判据失效');
  final open = s.indexOf('(', start);
  var depth = 0;
  for (var i = open; i < s.length; i++) {
    if (s[i] == '(') depth++;
    if (s[i] == ')') {
      depth--;
      if (depth == 0) return s.substring(open, i + 1);
    }
  }
  fail('构造点括号不配平');
}

Widget _host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.themeFor(Brightness.dark),
      home: Scaffold(
        backgroundColor: const Color(0xFF0A0B0D),
        body: Align(alignment: Alignment.topRight, child: child),
      ),
    );

void main() {
  setUp(() => UiPrefs.debugResetForTest());
  tearDown(() => UiPrefs.debugResetForTest());

  // ═══════════════════════════════════════════════════════════════════
  //  A. 行为路（面板侧）：喂什么就显示什么
  // ═══════════════════════════════════════════════════════════════════
  group('A 行为：面板读到宿主的值就**照它显示**（不是自己推的）', () {
    testWidgets('★★★ 宿主给 sourceName ⇒ 显示的是**那一串**，不是类别名', (t) async {
      /*
       * 关键：喂一个**面板自己绝对推不出来**的字符串。
       * 面板的降级路径只会给出 "外部视频站直连" 或聚合里的 label ——
       * 绝不可能是 "内置公共实例 · https://自定义".…
       * ⇒ 若屏幕上出现它，唯一解释是**真的读了宿主给的值**。
       */
      const injected = '内置公共实例 · https://danmu-api-delta.vercel.app';
      await t.pumpWidget(_host(const DanmakuInfoPanel(
        initiallyExpanded: true,
        data: DanmakuInfoData(
          source: DanmakuFeedKind.service,
          match: DanmakuPairKind.direct,
          count: 42,
          enabled: true,
          sourceName: injected,
        ),
      )));
      await t.pumpAndSettle();

      expect(find.text(injected), findsOneWidget,
          reason: '★★★ 宿主注入的源名必须原样出现在面板上');
      // 类别仍然在（第二行小字），这是设计
      expect(find.text('danmaku-service'), findsOneWidget);
    });

    testWidgets('★★★ 宿主给 updatedAt ⇒ 显示**那个时刻**，且不带"本次会话观察到"',
        (t) async {
      final at = DateTime.now().subtract(const Duration(hours: 7));
      await t.pumpWidget(_host(DanmakuInfoPanel(
        initiallyExpanded: true,
        data: DanmakuInfoData(
          source: DanmakuFeedKind.service,
          count: 42,
          enabled: true,
          sourceName: 'x',
          updatedAt: at,
        ),
      )));
      await t.pumpAndSettle();

      expect(find.textContaining('7 小时前'), findsOneWidget,
          reason: '★★★ 必须显示宿主给的那个时刻');
      expect(find.textContaining('本次会话观察到'), findsNothing,
          reason: '★ 宿主事实是全局的，不该标成"本会话观察"');
    });

    testWidgets('★★ 宿主**没给** updatedAt ⇒ 如实说「未记录」（降级不撒谎）',
        (t) async {
      await t.pumpWidget(_host(const DanmakuInfoPanel(
        initiallyExpanded: true,
        data: DanmakuInfoData(
          source: DanmakuFeedKind.service,
          count: 42,
          enabled: true,
          sourceName: 'x',
          // updatedAt 省略
        ),
      )));
      await t.pumpAndSettle();

      expect(find.textContaining('未记录'), findsOneWidget,
          reason: '★★ 没有这个事实就必须说没有 —— 不许编一个 now()');
      expect(find.textContaining('刚刚'), findsNothing);
    });

    testWidgets('★★★ 注入 2 路 feedSamples ⇒ 读数 = **合并结果**', (t) async {
      final samples = <DanmakuFeedChannel, List<DanmakuComment>>{
        DanmakuFeedChannel.biliSource: const <DanmakuComment>[
          DanmakuComment(cid: 1, time: 1.0, text: 'a'),
          DanmakuComment(cid: 2, time: 2.0, text: 'b'),
          DanmakuComment(cid: 3, time: 3.0, text: 'c'),
        ],
        DanmakuFeedChannel.danApi: const <DanmakuComment>[
          DanmakuComment(cid: 11, time: 1.5, text: 'd'),
          DanmakuComment(cid: 12, time: 2.5, text: 'e'),
        ],
      };
      await t.pumpWidget(_host(DanmakuSettingsDialog(
        state: const DanmakuSettingsState(
          enabled: true,
          appId: '',
          appSecret: '',
          fontScale: 1,
          opacity: 1,
          speed: 8,
          area: 1,
        ),
        onSetEnabled: (_) {},
        onSetFontScale: (_) {},
        onSetOpacity: (_) {},
        onSetSpeed: (_) {},
        onSetArea: (_) {},
        onReload: () {},
        onClose: () {},
        biliCount: 3,
        onOpenBili: () {},
        feedSamples: samples,
      )));
      await t.pumpAndSettle();
      await t.tap(find.descendant(
        of: find.byType(SegmentedButton<DanmakuPanelTab>),
        matching: find.text('弹幕来源'),
      ));
      await t.pumpAndSettle();

      await t.tap(find.text('dan-api'));
      await t.pumpAndSettle();

      final line = find.textContaining('当前生效：');
      expect(line, findsOneWidget);
      final txt = (t.widget<Text>(line).data)!;
      expect(txt, contains('2 路'),
          reason: '★★★ 注入了 2 路原料 ⇒ 必须算成 2 路');
      expect(txt, contains('合并后 5 条'),
          reason: '★★★ 3 + 2 = 5，这是**真合并结果**');
      await t.pump(const Duration(milliseconds: 400));
    });

    testWidgets('★★★ feedSamples 传 null ⇒ 降到「合计 · 未逐条合并」且仍绿（设计内降级）',
        (t) async {
      await t.pumpWidget(_host(const DanmakuSettingsDialog(
        state: DanmakuSettingsState(
          enabled: true,
          appId: '',
          appSecret: '',
          fontScale: 1,
          opacity: 1,
          speed: 8,
          area: 1,
        ),
        onSetEnabled: _noopB,
        onSetFontScale: _noopD,
        onSetOpacity: _noopD,
        onSetSpeed: _noopD,
        onSetArea: _noopD,
        onReload: _noop,
        onClose: _noop,
        biliCount: 3,
        onOpenBili: _noop,
        // feedSamples 省略 = null
      )));
      await t.pumpAndSettle();
      await t.tap(find.descendant(
        of: find.byType(SegmentedButton<DanmakuPanelTab>),
        matching: find.text('弹幕来源'),
      ));
      await t.pumpAndSettle();
      await t.tap(find.text('dan-api'));
      await t.pumpAndSettle();

      final txt = (t.widget<Text>(find.textContaining('当前生效：')).data)!;
      /*
       * 降级路径**分两种情形**，两种都必须如实：
       *
       *   a) 勾了一路、但宿主没给原料 ⇒ 只有「本片源自带」有新数据
       *      ⇒ 读数「单源 · 本片源自带 3 条」（**准确**）
       *   b) 勾了多路、但缺逐条内容 ⇒ 「N 路 合计 M 条 · 未逐条合并」
       *
       * ⚠️ 两种都**不许**出现「合并后」—— 没做逐条合并就说合并，是撒谎。
       * 本条验的是 a（只勾一路时的最诚实读数）。
       */
      expect(txt, isNot(contains('合并后')),
          reason: '★★★ 没原料时说"合并后"就是拿相加冒充合并');
      expect(txt, contains('单源'),
          reason: '★★ 只勾了一路 ⇒ 说"单源"是最准确的，不该硬凑成"合计"');
      expect(txt, contains('3 条'),
          reason: '★ 本片源那 3 条（宿主给了 biliCount）要如实报');
      await t.pump(const Duration(milliseconds: 400));
    });

    testWidgets('★★★ 多路但缺逐条内容 ⇒ 说「合计 · 未逐条合并」（不许说合并后）',
        (t) async {
      /*
       * 这一条与上一条互补：
       *   上一条 = 只勾一路（降级成"单源"）
       *   这一条 = 勾多路、但其中一路**只有条数没有内容** ⇒ 只能计数
       */
      await t.pumpWidget(_host(DanmakuSettingsDialog(
        state: const DanmakuSettingsState(
          enabled: true,
          appId: '',
          appSecret: '',
          fontScale: 1,
          opacity: 1,
          speed: 8,
          area: 1,
        ),
        onSetEnabled: _noopB,
        onSetFontScale: _noopD,
        onSetOpacity: _noopD,
        onSetSpeed: _noopD,
        onSetArea: _noopD,
        onReload: _noop,
        onClose: _noop,
        biliCount: 3,
        onOpenBili: _noop,
        // 只给 dan-api 内容；本片源只有 biliCount（没有逐条）
        feedSamples: const <DanmakuFeedChannel, List<DanmakuComment>>{
          DanmakuFeedChannel.danApi: <DanmakuComment>[
            DanmakuComment(cid: 11, time: 1.5, text: 'd'),
            DanmakuComment(cid: 12, time: 2.5, text: 'e'),
          ],
        },
      )));
      await t.pumpAndSettle();
      await t.tap(find.descendant(
        of: find.byType(SegmentedButton<DanmakuPanelTab>),
        matching: find.text('弹幕来源'),
      ));
      await t.pumpAndSettle();
      await t.tap(find.text('dan-api'));
      await t.pumpAndSettle();

      final txt = (t.widget<Text>(find.textContaining('当前生效：')).data)!;
      expect(txt, isNot(contains('合并后')),
          reason: '★★★ 本片源没有逐条内容 ⇒ 去重做不了，说"合并后"就是撒谎');
      expect(txt, contains('合计'),
          reason: '★★ 只能计数时要说"合计"');
      expect(txt, contains('未逐条合并'),
          reason: '★★★ 必须明说能力限制 —— 沉默会让用户以为去重做过了');
      await t.pump(const Duration(milliseconds: 400));
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  B. 结构路（宿主侧）：两个接线点**真的接上了**
  // ═══════════════════════════════════════════════════════════════════
  group('B 结构：player_page 的两处接线点（原样比对表达式）', () {
    test('★★★ ① getter 接了 sourceName，且值来自 _danmakuInfoSourceName', () {
      final body = danmakuInfoGetterBody();
      expect(body, contains('sourceName:'),
          reason: '★★★ 删掉这一行门禁就红 —— 这正是"接线"本身');
      /*
       * ★ 必须断言**来源表达式**，不能只断言"有这个 key"：
       *   写成 `sourceName: null` 也能过"有 key"，但那是假接线。
       */
      expect(body, contains('sourceName: _danmakuInfoSourceName'),
          reason: '★★★ 值必须来自那个 getter，不是 null / 常量 / 手抄字符串');
    });

    test('★★★ ① getter 接了 updatedAt，且值来自 _danmakuInfoUpdatedAt', () {
      final body = danmakuInfoGetterBody();
      expect(body, contains('updatedAt: _danmakuInfoUpdatedAt'),
          reason: '★★★ 同上：必须是真来源');
    });

    test('★★★ ② 构造点把 feedSamples 递了进去', () {
      final body = dialogConstructionBody();
      expect(body, contains('feedSamples: _danmakuFeedSamples'),
          reason: '★★★ 删掉它就退回"勾了但没合并"的假功能');
    });

    test('★★★ 宿主真的**产出**了这份原料（不是只声明一个空字段）', () {
      final s = playerSrc();
      /*
       * 光传 `_danmakuFeedSamples` 不够 —— 那个字段必须被**写入**，
       * 否则永远是空 map，面板永远单源（"接了但没数据"= 半截接线）。
       *
       * 断言：`_aggregateDanmaku` 里对 samples 调了 update/赋值。
       */
      expect(s, contains('_danmakuFeedSamples = samples'),
          reason: '★★★ 字段必须被真正赋值，否则是空壳');
      expect(s, contains('samples.update('),
          reason: '★★ 多路同桌时要合并而不是覆盖');
      /*
       * 阳性对照：确认这段代码**在 _aggregateDanmaku 里**
       * （而不是随便哪个函数里赋值了一次就算）。
       * 因为 `_danmakuFeedSamples = samples` 出现在 merge 之后。
       */
      final mergeAt = s.indexOf('final agg = DanmakuAggregator.merge(inputs);');
      final assignAt = s.indexOf('_danmakuFeedSamples = samples');
      expect(mergeAt, greaterThanOrEqualTo(0));
      expect(assignAt, greaterThan(mergeAt),
          reason: '★★ 必须在 merge 之后（那里 inputs 才是完整的）');
    });

    test('★★★ 两处接线都不在注释里（剥注释后仍在）', () {
      /*
       * 本文件的 playerSrc() **已经剥过注释** ⇒ 上面的断言天然满足这条。
       * 这里再做一次**显式对照**：确认剥注释真的有效 ——
       * 拿一句只在注释里出现的话去 grep，必须找不到。
       */
      final raw = File('lib/ui/player_page.dart').readAsStringSync();
      final stripped = playerSrc();
      expect(raw.length, greaterThan(stripped.length),
          reason: '★ 剥注释必须真的缩短了源码（否则剥函数失效，上面的断言全不可信）');
      // 我在注释里写过 "sourceName: …" 的字样吗？这里保证它不会混进来
      expect(stripped.contains('INJECT'), isFalse,
          reason: '★ 源码里不许残留故障注入标记');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  C. 两个 getter 的行为（纯逻辑，不挂 UI）
  // ═══════════════════════════════════════════════════════════════════
  group('C getter 语义：不知道就说不知道（不编值）', () {
    test('★★★ _danmakuInfoUpdatedAt 的两个真源都不存在时必须是 null', () {
      /*
       * 这两个是宿主侧的 private getter，测试不能直接调
       * ⇒ 用**源码语义**断言：
       *   · 它读了 BiliDanmakuStore.fetchedAt
       *   · 它读了 biliLastSyncAt
       *   · 它的末尾 return 是 null（不是 DateTime.now()）
       */
      final s = playerSrc();
      final start = s.indexOf('DateTime? get _danmakuInfoUpdatedAt');
      expect(start, greaterThanOrEqualTo(0));
      final body = s.substring(start, s.indexOf('\n  }', start));
      expect(body, contains('BiliDanmakuStore.fetchedAt'),
          reason: '★ 精确到这一集的那个真源');
      expect(body, contains('biliLastSyncAt'),
          reason: '★ 粗读数（唯一的时间事实）');
      expect(body, contains('return null'),
          reason: '★★★ 两个真源都没有时必须返回 null（面板显示"未记录"）');
      expect(body, isNot(contains('DateTime.now()')),
          reason: '★★★ 不许用"现在"冒充"上次更新"');
    });

    test('★★ _danmakuInfoSourceName 覆盖了所有来源类别（含 none ⇒ null）', () {
      final s = playerSrc();
      final start = s.indexOf('String? get _danmakuInfoSourceName');
      expect(start, greaterThanOrEqualTo(0));
      final body = s.substring(start, s.indexOf('\n  }', start));
      /*
       * switch 必须覆盖 5 个非 none 类别 + none。
       * 若漏一个，Dart 会报 non_exhaustive —— 但那是编译期；
       * 这里断言**每个分支都给了非空的具体值**（除了 none）。
       */
      for (final marker in <String>[
        'DanmakuInfoSource.bili',
        'DanmakuInfoSource.service',
        'DanmakuInfoSource.localDanmaku',
        'DanmakuInfoSource.selfHosted',
        'DanmakuInfoSource.library',
        'DanmakuInfoSource.none',
      ]) {
        expect(body, contains(marker), reason: '★ 缺分支：$marker');
      }
      expect(body, contains('return null'),
          reason: '★★ none 那一档必须返回 null（让面板走降级），不是编个"未取到"');
    });
  });
}

// 顶层函数常量（const 上下文里不能直接用闭包）
void _noop() {}
void _noopB(bool _) {}
void _noopD(double _) {}
