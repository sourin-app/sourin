// task-66 轨道 I：**弹幕面板语义重构**（Owner 亲自截图四条反馈）
//
// # 这份门禁钉的是 Owner 那四条，不是"我改了什么"
// ```text
// Owner 原话（2026-10-18 亲自截图）：
//   ① 「bilibili的弹幕设置怎么没了」
//   ② 「插件提供是什么? 我说的插件提供意思是,比如某个视频源 它本身视频源
//       每一集都有对应的弹幕数据,那么就默认导入他自身的就行了」
//   ③ 「dan-api只有测试,都没测试」
//   ④ 「这个官方兜底也不知道是啥东西」
// ```
//
// # 为什么是源码契约 + 行为断言两层
// ```text
// · 行为层：面板能建起来、三个页签在、四行来源在、文案对
// · 源码层：`_sourceSection` / `_credentialsSection` 必须**不可达**
//   （Lead 裁决：保留代码但不许被调用 —— 删掉容易重写难）
// ```
//
// # 故障注入（每条都实测过，见各 test 的 reason）
// ```text
// ① 把页签改回旧的四页签            ⇒ ①②③ 组红
// ② 把「弹幕来源」里那个源那行删掉   ⇒ ①组红（Owner 第 1 条）
// ③ 把 `_sourceSection` 加回调用点   ⇒ ④组红（官方兜底复活）
// ④ 把 canSendDanmaku 那行说明删掉   ⇒ ⑤组红（能看/能发没区分）
// ```
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';

const String _dialogPath = 'lib/ui/widgets/danmaku_settings_dialog.dart';

/// 剥掉 `//` 与 `/* */` 注释（照抄 t73 的 stripComments，逐字一致）
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

DanmakuSettingsState _state({
  int count = 0,
  String searchKeyword = '',
}) =>
    DanmakuSettingsState(
      enabled: true,
      appId: '',
      appSecret: '',
      fontScale: 1.0,
      opacity: 0.9,
      speed: 1.0,
      area: 0.5,
      count: count,
      lanes: 6,
      dropped: 0,
      searchKeyword: searchKeyword,
    );

Widget _host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.themeFor(Brightness.dark),
      home: Scaffold(body: child),
    );

Widget _panel({
  DanmakuSettingsState? state,
  int? biliCount,
  VoidCallback? onOpenBili,
  bool canSendDanmaku = true,
}) =>
    DanmakuSettingsDialog(
      state: state ?? _state(),
      onSetEnabled: (_) {},
      onSetFontScale: (_) {},
      onSetOpacity: (_) {},
      onSetSpeed: (_) {},
      onSetArea: (_) {},
      onReload: () {},
      onClose: () {},
      biliCount: biliCount,
      onOpenBili: onOpenBili,
      canSendDanmaku: canSendDanmaku,
      fill: false,
    );

Future<void> _tapTab(WidgetTester t, String label) async {
  await t.tap(find.descendant(
    of: find.byType(SegmentedButton<DanmakuPanelTab>),
    matching: find.text(label),
  ));
  await t.pumpAndSettle();
}

void main() {
  setUp(() => UiPrefs.debugResetForTest(<String, String>{}));
  tearDown(() => UiPrefs.debugResetForTest(<String, String>{}));

  // ═══════════════════════════════════════════════════════════════════
  //  ① Owner 第 1 条：那个视频站的弹幕设置**必须可见**
  // ═══════════════════════════════════════════════════════════════════
  group('① Owner「某个视频站的弹幕设置怎么没了」', () {
    testWidgets('★★★ 面板里有**独立的**「弹幕来源」页签（不是藏在别的页签里）',
        (t) async {
      await t.pumpWidget(_host(_panel(biliCount: 1200, onOpenBili: () {})));
      await t.pumpAndSettle();

      final seg = find.byType(SegmentedButton<DanmakuPanelTab>);
      /*
       * ⚠️ 必须把 find.text 限定在 SegmentedButton **内部**：
       *    「显示」这个词同时是**页签名**和**区块标题**（`_sectionTitle('显示')`），
       *    不加限定会数到 2 个 ⇒ 假红。
       *    （我第一版就是这么错的，实测 Found 2 widgets）
       */
      expect(
        find.descendant(of: seg, matching: find.text('弹幕来源')),
        findsOneWidget,
        reason: '★★★ Owner 第 1 条的核心修复：那个源必须在**一眼可见**的位置。'
            '第三版把它藏成「插件提供」里一枚叫「外部弹幕…」的按钮 ⇒ '
            '减少点击层数 ≠ 提高可发现性',
      );
      expect(find.descendant(of: seg, matching: find.text('显示')),
          findsOneWidget);
      expect(find.descendant(of: seg, matching: find.text('高级')),
          findsOneWidget);
    });

    testWidgets('★★★ 打开「弹幕来源」⇒ 那个源是**平级的一行**，且有「打开…」',
        (t) async {
      await t.pumpWidget(_host(_panel(biliCount: 1200, onOpenBili: () {})));
      await t.pumpAndSettle();
      await _tapTab(t, '弹幕来源');

      /*
       * ⚠️ 这里断言"四行来源都在"，用的是**可见文字**而不是类型 ——
       *    与 task41 那条教训一致（换实现类不该让断言静默通过）。
       */
      expect(find.text('本片源自带'), findsOneWidget,
          reason: '★ 插件随片提供的那条（Owner 第 2 条的新语义）');
      expect(find.text('打开…'), findsOneWidget,
          reason: '★★★ Owner 第 1 条：那个源的入口必须在这里');
      expect(find.text('dan-api'), findsOneWidget,
          reason: '★ Owner 第 3 条：dan-api 与它**平级**');
      expect(find.text('本机服务'), findsOneWidget);
    });

    testWidgets('★★ 点「打开…」真的会回调宿主（不是画了个死按钮）', (t) async {
      var opened = 0;
      await t.pumpWidget(_host(_panel(
        biliCount: 1200,
        onOpenBili: () => opened++,
      )));
      await t.pumpAndSettle();
      await _tapTab(t, '弹幕来源');
      await t.tap(find.text('打开…'));
      await t.pumpAndSettle();
      expect(opened, 1, reason: '★★ 画了按钮就得能点');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② Owner 第 2 条：「本片源自带」的语义
  // ═══════════════════════════════════════════════════════════════════
  group('② Owner「插件提供是什么」⇒ 语义改成「本片源自带」', () {
    testWidgets('★★★ 不再出现「插件提供」这个用户看不懂的词', (t) async {
      await t.pumpWidget(_host(_panel(biliCount: 1200, onOpenBili: () {})));
      await t.pumpAndSettle();
      await _tapTab(t, '弹幕来源');

      expect(find.textContaining('插件提供'), findsNothing,
          reason: '★★★ Owner 第 2 条：他明确说了这个词他不懂。'
              '语义是"视频源插件随片自带每一集的弹幕" ⇒ 叫「本片源自带」');
    });

    testWidgets('★★★ 「本片源自带」有数据时**默认勾上**（自动，不用用户操作）',
        (t) async {
      await t.pumpWidget(_host(_panel(biliCount: 1200, onOpenBili: () {})));
      await t.pumpAndSettle();
      await _tapTab(t, '弹幕来源');

      /*
       * Owner 第 2 条原话：「那么就默认导入他自身的就行了」
       * ⇒ 默认勾上 = 自动导入，用户什么都不用做。
       */
      expect(find.text('本片源自带'), findsOneWidget);
      expect(find.textContaining('可看'), findsWidgets,
          reason: '★ 明确它是"能看"的（与"能发"是两件事，见第 ⑤ 组）');
      expect(find.text('默认'), findsOneWidget,
          reason: '★★ 必须标出它是默认来源 —— 否则用户不知道现在用的是哪条');
    });

    testWidgets('★★ 没有弹幕时如实说「本片源没有提供」（不假装有）', (t) async {
      await t.pumpWidget(_host(_panel(biliCount: null, onOpenBili: () {})));
      await t.pumpAndSettle();
      await _tapTab(t, '弹幕来源');

      expect(find.text('本片源没有提供'), findsOneWidget,
          reason: '★ 如实 —— 不能显示"0 条"（0 是"供了但为空"，语义不同）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ Owner 第 3 条：dan-api 不能只有"测试连接"
  // ═══════════════════════════════════════════════════════════════════
  group('③ Owner「dan-api只有测试」', () {
    testWidgets('★★★ dan-api 那一行带「搜索…」（不再只有测试连接）', (t) async {
      /*
       * ⚠️ 必须同时给 `onSearch` **和** `onPickMatch`：
       *    `_showSearchSection` 是两者的**与**（只给一个会画出
       *    "列表画得出来、点一条却没反应"的假 UI）。
       *    我第一版只给了 onSearch ⇒ 找不到「搜索…」，实测假红。
       */
      await t.pumpWidget(_host(DanmakuSettingsDialog(
        state: _state(),
        onSetEnabled: (_) {},
        onSetFontScale: (_) {},
        onSetOpacity: (_) {},
        onSetSpeed: (_) {},
        onSetArea: (_) {},
        onReload: () {},
        onClose: () {},
        biliCount: 1200,
        onOpenBili: () {},
        onSearch: (_) {},
        onPickMatch: (_) {},
        fill: false,
      )));
      await t.pumpAndSettle();
      await _tapTab(t, '弹幕来源');

      expect(find.text('dan-api'), findsOneWidget,
          reason: '★★★ Owner 第 3 条：dan-api 必须能搜、能选、能绑，'
              '而不只是一个"测试连接"按钮');
      expect(find.text('搜索…'), findsOneWidget,
          reason: '★★ dan-api 的搜索入口（宿主给 onSearch + onPickMatch 时才画）');
    });

    testWidgets('★★ 点「搜索…」把关键词交给宿主（面板自己不发请求）', (t) async {
      final seen = <String>[];
      await t.pumpWidget(_host(DanmakuSettingsDialog(
        state: _state(searchKeyword: '测试番剧'),
        onSetEnabled: (_) {},
        onSetFontScale: (_) {},
        onSetOpacity: (_) {},
        onSetSpeed: (_) {},
        onSetArea: (_) {},
        onReload: () {},
        onClose: () {},
        biliCount: 1200,
        onOpenBili: () {},
        onSearch: seen.add,
        onPickMatch: (_) {},
        fill: false,
      )));
      await t.pumpAndSettle();
      await _tapTab(t, '弹幕来源');
      await t.tap(find.text('搜索…'));
      await t.pumpAndSettle();

      expect(seen, <String>['测试番剧'],
          reason: '★★ 面板只把关键词递出去 —— 请求由宿主发（本文件的分工）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ Owner 第 4 条：官方兜底已删除，且代码**不可达**
  // ═══════════════════════════════════════════════════════════════════
  group('④ Owner「官方兜底也不知道是啥东西」', () {
    testWidgets('★★★ 界面上不再有「官方兜底」页签', (t) async {
      await t.pumpWidget(_host(_panel(biliCount: 1200, onOpenBili: () {})));
      await t.pumpAndSettle();

      expect(find.text('官方兜底'), findsNothing,
          reason: '★★★ Owner 第 4 条：内部概念不该泄漏到 UI，且本构建无内置'
              '凭证、这条边必然失败 ⇒ 整个页签删除');
    });

    test('★★★ `_sourceSection` / `_credentialsSection` 保留但**不可达**', () {
      /*
       * Lead 裁决：「删掉签名逻辑容易，重写难。但**必须确保它不可达**」。
       *
       * # 判据为什么这么写（我第一版错过两次，都记下来）
       * ```text
       * 错法①：数 `'_sourceSection()'.allMatches(src)` ⇒ 定义行
       *        `Widget _sourceSection() {` **本身也含**那个子串 ⇒ 恒为 1 ⇒ 假红。
       * 错法②：注释里写 `_group(_sourceSection())` 当"怎么恢复"的说明
       *        ⇒ stripComments 剥掉注释后确实没了，但我第一版把那段写成
       *        裸字面量放在 `///` 里，某些剥法会漏 ⇒ 假红。
       * ```
       * # 正确判据：数**调用形态**，排除定义行
       * ```text
       * 调用形态：`_group(_sourceSection())` / `_sourceSection()` 前面不是 `Widget `
       * 定义形态：`Widget _sourceSection(`
       * ⇒ 用「定义处出现次数」减去「总出现次数」= 调用点数。
       * ```
       */
      final src = stripComments(File(_dialogPath).readAsStringSync());

      int callSites(String name) {
        final total = '$name()'.allMatches(src).length;
        final defs = 'Widget $name('.allMatches(src).length;
        // 定义行 `Widget name() {` 里也含 `name()` ⇒ 减去定义数
        return total - defs;
      }

      expect(src.contains('Widget _sourceSection('), isTrue,
          reason: '★ 方法本身要保留（将来接官方开放平台可复用）');
      expect(src.contains('Widget _credentialsSection('), isTrue,
          reason: '★ 同上');

      expect(callSites('_sourceSection'), 0,
          reason: '★★★ 它必须**不可达** —— 有调用点就是"官方兜底"复活了');
      expect(callSites('_credentialsSection'), 0,
          reason: '★★★ 同上');

      /*
       * 阳性对照：`_selfHostedSection` 是**在**用的（高级页签），
       * 证明这个"数调用点"的判据本身有效，不是恒真。
       */
      expect(callSites('_selfHostedSection'), greaterThan(0),
          reason: '阳性对照：在用的方法必须数得到 —— 否则上面的 0 是恒真假绿');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑤ 「能看」与「能发」是两件事（Lead 追加口径）
  // ═══════════════════════════════════════════════════════════════════
  group('⑤ 能看 / 能发 必须分开说', () {
    testWidgets('★★★ 不支持发送时，面板里有**一行说明**（不是静默）',
        (t) async {
      await t.pumpWidget(_host(_panel(
        biliCount: 1200,
        onOpenBili: () {},
        canSendDanmaku: false,
      )));
      await t.pumpAndSettle();
      await _tapTab(t, '弹幕来源');

      /*
       * # 这条为什么重要
       * ```text
       * 两个插件都没声明 danmakuSend ⇒ 发送输入框整条不渲染
       * （Owner 第 1 条「不支持就不显示」，宿主判得对）。
       * 但用户看到「本片源自带 1200 条」却没有发送框 ⇒ 他会以为坏了。
       * ⇒ 输入框仍然不显示，但这里要明说一句。
       * ```
       * ⚠️ 这与 Owner 第 1 条**不矛盾**：
       *    那条禁的是"显示发送输入框"，不是"不许解释为什么没有"。
       */
      expect(find.textContaining('不支持发送弹幕'), findsOneWidget,
          reason: '★★★ 必须解释，否则用户以为功能坏了');
      expect(find.textContaining('只能看'), findsWidgets,
          reason: '★ 说清"能看不能发"这个状态');
    });

    testWidgets('★★ 支持发送时**不出现**那行说明（不制造噪声）', (t) async {
      await t.pumpWidget(_host(_panel(
        biliCount: 1200,
        onOpenBili: () {},
        canSendDanmaku: true,
      )));
      await t.pumpAndSettle();
      await _tapTab(t, '弹幕来源');

      expect(find.textContaining('不支持发送弹幕'), findsNothing,
          reason: '★★ 能发的时候说"不支持"就是错误信息');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑥ 页面结构：三个页签，一个都不许挤掉
  // ═══════════════════════════════════════════════════════════════════
  group('⑥ 三个页签', () {
    testWidgets('★★★ 恰好三个，且都不是某一家服务的名字', (t) async {
      await t.pumpWidget(_host(_panel(biliCount: 1200, onOpenBili: () {})));
      await t.pumpAndSettle();

      final seg = find.byType(SegmentedButton<DanmakuPanelTab>);
      expect(seg, findsOneWidget);
      for (final label in <String>['显示', '弹幕来源', '高级']) {
        expect(
          find.descendant(of: seg, matching: find.text(label)),
          findsOneWidget,
          reason: '★ 页签「$label」不见了',
        );
      }
      // 旧的四个都不该在
      for (final old in <String>['配置', 'dan-api', '插件提供', '官方兜底']) {
        expect(
          find.descendant(of: seg, matching: find.text(old)),
          findsNothing,
          reason: '★★ 旧页签「$old」不该还在（Owner 四条已否掉那套切法）',
        );
      }
    });

    testWidgets('★★ 默认落在「显示」（与来源无关的中立落点）', (t) async {
      await t.pumpWidget(_host(_panel(biliCount: 1200, onOpenBili: () {})));
      await t.pumpAndSettle();
      /*
       * 来源之间可以叠加（Owner 第 11 条「同时加载并合并」），
       * 默认勾哪一个都等于替用户做选择 ⇒ 默认落在「显示」。
       */
      expect(find.text('显示弹幕'), findsOneWidget,
          reason: '★ 默认页签是「显示」（它有那个开关）');
    });
  });
}
