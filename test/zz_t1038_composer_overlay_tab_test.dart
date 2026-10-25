// ═══════════════════════════════════════════════════════════════════════
//  P5 · 统一「源个性化编排」面板 + 第 07 项卡片展开 —— 行为门禁
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
// ```text
// > js插件也要支持,你想想方案吧,必须全部都可以,比如 只是链接,可以对数据
// > 二次编排修改,或者做劫持；js,可视化可自由编辑支持的,但不能影响原有插件本身,
// > 属于是个性化；声明式还是一样,不修改本身；可视化编排还是属于二次修改劫持的产物需求
// > 那个编排面板也要支持
// ```
//
// # 这个文件守什么（每条都对着一条硬约束）
// ```text
// ① 编排面板**能读/写 L1+L2+L3**：页签切过去就是那份表单，保存走 saveOverrideLayer，
//    收到的结构里 target_id 必须是**这个源**（不是别的 id）；
// ② 硬约束 1：覆盖层这一路**只写 overrides** —— 不许出现 writePlugin/installPlugin；
// ③ 硬约束 2：删除覆盖层 = 完全恢复（真的调 deleteOverrideLayer，表单清空）；
// ④ 硬约束 4（第 07 项）：卡片正文可点展开/收起、按钮区不误触、
//    `_panels()` 按展开态渲染、**不做默认全展开**、展开态由**宿主 Set**持有；
// ⑤ 既有编排器行为零回归：没绑 id 时**不出现**页签（树与改前一致）。
// ```
//
// # 为什么每条都配一次故障注入
// ```text
// 本仓记过多次「断言恒真 ⇒ 假绿」的教训（见 zz_t1030 的同类注释）。
// 本轮每条新断言都做过一次反向实验，读数记在 .probe/composer-fault-*.log，
// 交付说明里逐条列出"改坏哪一行 → 哪条变红"。
// ```
//
// # 桩的边界（哪里能桩、哪里不许）
// ```text
// 允许桩：三个 FFI 边界（get/save/delete override layer）—— 那是文件层。
// 禁止桩：页签切换、校验、JSON 拼装、渲染、展开态切换 —— 这些在下面每条里**都真跑**。
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/ffi.dart' show SourinCoreException;
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/design/icons/app_icons.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings_page.dart';
import 'package:sourin_spike/ui/widgets/override_editor_dialog.dart';
import 'package:sourin_spike/ui/widgets/plugin_speedtest.dart';
import 'package:sourin_spike/ui/widgets/proxy_panel.dart';
import 'package:sourin_spike/ui/widgets/source_composer_dialog.dart';

// ═══════════════════════════════════════════════════════════════════════
//  桩：只替换覆盖层 FFI 边界
// ═══════════════════════════════════════════════════════════════════════

class _OvHooks {
  _OvHooks({this.layer});

  Map<String, dynamic>? layer;

  /// `deleteOverrideLayer` 的返回值（true = 真的删掉了一份）
  bool deleteReturns = true;

  /// 非 null ⇒ `save` 抛这个异常（验"保存失败"的用户可见回显）
  Object? failSaveWith;

  /// 非 null ⇒ `remove` 抛这个异常（验"删除失败"的回显与"不清空表单"）
  Object? failDeleteWith;

  final List<String> loadedIds = <String>[];
  final List<String> deletedIds = <String>[];
  Map<String, dynamic>? saved;
  int saveCalls = 0;

  Future<Map<String, dynamic>?> load(String id) async {
    loadedIds.add(id);
    return layer;
  }

  Future<String> save(Map<String, dynamic> l) async {
    saveCalls += 1;
    if (failSaveWith != null) throw failSaveWith!;
    saved = l;
    return 'C:/tmp/overrides/${l['target_id']}.json';
  }

  Future<bool> remove(String id) async {
    deletedIds.add(id);
    if (failDeleteWith != null) throw failDeleteWith!;
    return deleteReturns;
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  挂载 / 操作工具
// ═══════════════════════════════════════════════════════════════════════

Widget _host(Widget child, {double width = 900, double height = 1100}) =>
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.themeFor(Brightness.dark),
      themeAnimationDuration: Duration.zero,
      home: Scaffold(
        body: Center(
          child: SizedBox(width: width, height: height, child: child),
        ),
      ),
    );

/// 把弹窗内容区滚到能看见，再点
Future<void> _tap(WidgetTester t, String key) async {
  final f = find.byKey(ValueKey<String>(key));
  expect(f, findsOneWidget, reason: '找不到 $key —— 判据本身失效了');
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
  await t.pump();
}

Future<void> _type(WidgetTester t, String key, String text) async {
  final f = find.byKey(ValueKey<String>(key));
  expect(f, findsOneWidget, reason: '找不到输入框 $key');
  await t.ensureVisible(f);
  await t.pump();
  await t.enterText(f, text);
  await t.pump();
}

String _text(WidgetTester t, String key) {
  final f = find.byKey(ValueKey<String>(key));
  expect(f, findsOneWidget, reason: '找不到 $key');
  return t.widget<TextField>(f).controller!.text;
}

/// 挂上编排器（带覆盖层页签），等异步加载跑完
Future<void> _pumpComposer(
  WidgetTester t,
  _OvHooks h, {
  bool overridesOnly = false,
}) async {
  await t.pumpWidget(_host(SourceComposerDialog(
    overridesTargetId: 'p_tab',
    overridesSourceName: '页签源',
    overridesOnly: overridesOnly,
    loadOverrideLayer: h.load,
    saveOverrideLayer: h.save,
    deleteOverrideLayer: h.remove,
  )));
  await t.pump();
  await t.pump(const Duration(milliseconds: 100));
}

// ═══════════════════════════════════════════════════════════════════════
//  源码工具：剥注释（判据不许被注释里的"改前写法"误伤）
// ═══════════════════════════════════════════════════════════════════════

String _read(String path) => File(path).readAsStringSync();

String _stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  var inLine = false;
  var inBlock = false;
  var inString = false;
  String? quote;
  while (i < src.length) {
    final c = src[i];
    final next = i + 1 < src.length ? src[i + 1] : '';
    if (inLine) {
      if (c == '\n') {
        inLine = false;
        out.write(c);
      }
      i++;
      continue;
    }
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
    if (inString) {
      out.write(c);
      if (c == r'\') {
        if (next.isNotEmpty) {
          out.write(next);
          i += 2;
          continue;
        }
      }
      if (c == quote) inString = false;
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
    if (c == '"' || c == "'") {
      inString = true;
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

// ═══════════════════════════════════════════════════════════════════════
//  用例
// ═══════════════════════════════════════════════════════════════════════

void main() {
  // ─────────────────────────────────────────────────────────────────
  //  ① 页签：默认落在「源定义」，切过去才是覆盖层
  // ─────────────────────────────────────────────────────────────────
  group('① 编排面板 = 源定义 + 个性化覆盖 两个页签', () {
    testWidgets('绑定了源 id ⇒ 出现两个页签，且**默认不落在**覆盖层页', (t) async {
      final h = _OvHooks();
      await _pumpComposer(t, h);

      expect(find.byKey(const ValueKey<String>('composer-tab-0')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('composer-tab-1')), findsOneWidget);

      // 默认页 = 源定义：三块都在
      expect(find.textContaining('① 站点'), findsOneWidget,
          reason: '★ 打开就该看到源定义（用户点的是「编辑」这个源）');
      // 覆盖层页**没挂出来**（Offstage 的不算：默认 finder 跳过 offstage）
      expect(find.byKey(const ValueKey<String>('ov-map-add')), findsNothing,
          reason: '★ 不做"默认全展示"：覆盖层是第二个页签，不该抢源定义的位置');

      // 加载读数：绑定的是**传入的那个 id**
      expect(h.loadedIds, <String>['p_tab'],
          reason: '★ 必须读这个源的覆盖层（读错 id 会让用户看到别人的规则）');
    });

    testWidgets('点「② 个性化覆盖」⇒ L1/L2/L3 表单出现，源定义区收起', (t) async {
      final h = _OvHooks();
      await _pumpComposer(t, h);

      await _tap(t, 'composer-tab-1');
      await t.pump(const Duration(milliseconds: 100));

      expect(find.byKey(const ValueKey<String>('ov-map-add')), findsOneWidget,
          reason: '★ L1 必须有入口');
      expect(find.byKey(const ValueKey<String>('ov-tx-add')), findsOneWidget,
          reason: '★ L2 必须有入口');
      expect(find.byKey(const ValueKey<String>('ov-js-hook')), findsOneWidget,
          reason: '★ L3 必须有入口');
      expect(find.textContaining('① 站点'), findsNothing,
          reason: '★ 切到覆盖层页后，源定义区不该还占着位置（Offstage 不参与命中）');
    });

    testWidgets('切页签**不丢**已填的规则（Offstage 保住状态）', (t) async {
      final h = _OvHooks();
      await _pumpComposer(t, h);

      await _tap(t, 'composer-tab-1');
      await t.pump(const Duration(milliseconds: 100));
      await _tap(t, 'ov-map-add');
      await _type(t, 'ov-map-0-from', 'keepme');

      await _tap(t, 'composer-tab-0');
      await t.pump(const Duration(milliseconds: 100));
      await _tap(t, 'composer-tab-1');
      await t.pump(const Duration(milliseconds: 100));

      expect(_text(t, 'ov-map-0-from'), 'keepme',
          reason: '★★ 切一下页签就把用户填的规则清空 = 数据丢失；'
              '页签必须用 Offstage 保状态，而不是 if 重建');
    });

    testWidgets('没绑源 id ⇒ **不出现**页签（既有编排器零回归）', (t) async {
      await t.pumpWidget(_host(const SourceComposerDialog()));
      await t.pumpAndSettle();

      expect(find.byKey(const ValueKey<String>('composer-tab-0')), findsNothing,
          reason: '★ 新建源还没有 id，无处挂覆盖层 ⇒ 不许凭空多出页签');
      expect(find.textContaining('① 站点'), findsOneWidget);
      expect(find.textContaining('实时预览'), findsOneWidget);
    });
  });

  // ─────────────────────────────────────────────────────────────────
  //  ② 保存：只写 overrides，结构对着 overrides.rs
  // ─────────────────────────────────────────────────────────────────
  group('② 在编排面板里保存覆盖层', () {
    testWidgets('L1 + L2 + L3 ⇒ saveOverrideLayer 收到这个源的完整结构', (t) async {
      final h = _OvHooks();
      await _pumpComposer(t, h);
      await _tap(t, 'composer-tab-1');
      await t.pump(const Duration(milliseconds: 100));

      // L1：改名 title -> name
      await _tap(t, 'ov-map-add');
      await _type(t, 'ov-map-0-from', 'title');
      await _type(t, 'ov-map-0-to', 'name');

      // L2：只留前 20 条
      await _tap(t, 'ov-tx-add');
      await t.pump();
      await _tap(t, 'ov-tx-0-op');
      await t.pump(const Duration(milliseconds: 400));
      await t.tap(find.text('只留前 N 条 take_first').last);
      await t.pump(const Duration(milliseconds: 400));
      await _type(t, 'ov-tx-0-limit', '20');

      // L3
      await _type(t, 'ov-js-hook', 'return data;');

      await _tap(t, 'ov-save');
      await t.pump(const Duration(milliseconds: 200));

      expect(h.saveCalls, 1, reason: '★ 保存必须**只**调一次');
      expect(h.saved!['target_id'], 'p_tab',
          reason: '★★ 写错 id 就会把覆盖层存到别的源头上（用户会看到"设了没用"）');
      expect(h.saved!['mappings'], <Map<String, dynamic>>[
        <String, dynamic>{'op': 'rename', 'from': 'title', 'to': 'name', 'keep': false},
      ]);
      expect(h.saved!['transforms'], <Map<String, dynamic>>[
        <String, dynamic>{'op': 'take_first', 'limit': 20},
      ]);
      expect(h.saved!['js_hook'], 'return data;');
      expect(h.saved!.containsKey('js_hook'), isTrue,
          reason: '★ 少了 js_hook 键，用户写的 JS 根本到不了 Rust');
    });

    testWidgets('保存在编排面板里**不关面板**（只更新状态行）', (t) async {
      final h = _OvHooks(layer: <String, dynamic>{
        'target_id': 'p_tab',
        'mappings': <Map<String, dynamic>>[
          <String, dynamic>{'op': 'set', 'to': 'x', 'value': 'y'},
        ],
      });
      await _pumpComposer(t, h);
      await _tap(t, 'composer-tab-1');
      await t.pump(const Duration(milliseconds: 100));

      await _tap(t, 'ov-save');
      await t.pump(const Duration(milliseconds: 200));

      expect(find.byType(SourceComposerDialog), findsOneWidget,
          reason: '★ 编排面板不该像独立弹窗那样保存即关 —— 用户可能还要回去改源定义');
      final status = find.byKey(const ValueKey<String>('ov-status'));
      expect(status, findsOneWidget);
      expect((t.widget<Text>(status).data ?? ''), contains('已保存'),
          reason: '★ 用户必须看到"存下去了"的实证，而不是"点了没反应"');
    });

    testWidgets('独立弹窗这条老路仍然可用（重构后外壳没坏）', (t) async {
      final h = _OvHooks(layer: <String, dynamic>{
        'target_id': 'p_dlg',
        'mappings': <Map<String, dynamic>>[
          <String, dynamic>{'op': 'set', 'to': 'x', 'value': 'y'},
        ],
      });
      await t.pumpWidget(_host(OverrideEditorDialog(
        targetId: 'p_dlg',
        sourceName: '弹窗源',
        loadLayer: h.load,
        saveLayer: h.save,
        deleteLayer: h.remove,
      )));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));

      expect(find.text('覆盖层不改原插件'), findsOneWidget,
          reason: '★ 安全提示是硬要求（用户按下任何按钮之前就要读到）');
      expect(find.byKey(const ValueKey<String>('ov-map-0-op')), findsOneWidget,
          reason: '★ 读到的规则要回显 —— 否则用户会以为没配过，重复配一遍');
    });
  });

  // ─────────────────────────────────────────────────────────────────
  //  ③ 删除 = 完全恢复
  // ─────────────────────────────────────────────────────────────────
  group('③ 删除覆盖层 ⇒ 完全恢复默认', () {
    testWidgets('二次确认后真的调 deleteOverrideLayer，表单清空并给出提示', (t) async {
      final h = _OvHooks(layer: <String, dynamic>{
        'target_id': 'p_tab',
        'mappings': <Map<String, dynamic>>[
          <String, dynamic>{'op': 'rename', 'from': 'a', 'to': 'b'},
        ],
        'js_hook': 'return data;',
      });
      await _pumpComposer(t, h);
      await _tap(t, 'composer-tab-1');
      await t.pump(const Duration(milliseconds: 100));

      await _tap(t, 'ov-restore');
      expect(h.deletedIds, isEmpty,
          reason: '★ 第一下**不许**真删 —— 破坏性动作必须二次确认');

      await _tap(t, 'ov-restore-confirm');
      await t.pump(const Duration(milliseconds: 200));

      expect(h.deletedIds, <String>['p_tab'],
          reason: '★ 删除必须落到**这个源**上');
      expect(find.byKey(const ValueKey<String>('ov-map-0-op')), findsNothing,
          reason: '★★ 删除后表单必须清空 —— 否则用户以为那层还在（"删了没用"）');
      expect(_text(t, 'ov-js-hook'), '');
      final status = t.widget<Text>(find.byKey(const ValueKey<String>('ov-status')));
      expect(status.data ?? '', contains('已恢复默认'),
          reason: '★ 要如实告诉用户"原插件行为已完全恢复"');
    });
  });

  // ─────────────────────────────────────────────────────────────────
  //  ④ JS 插件入口：overridesOnly（只有一个页签）
  // ─────────────────────────────────────────────────────────────────
  group('④ JS 插件那条入口（overridesOnly）', () {
    testWidgets('直接落在覆盖层页，没有源定义页签、没有"创建/保存"提交按钮', (t) async {
      final h = _OvHooks();
      await _pumpComposer(t, h, overridesOnly: true);

      expect(find.byKey(const ValueKey<String>('composer-tab-0')), findsNothing,
          reason: '★ JS 插件没有声明式 JSON 可编 —— 画「① 源定义」是假入口');
      expect(find.byKey(const ValueKey<String>('composer-tab-1')), findsNothing,
          reason: '★ 只有一个页时不该再画页签条');
      expect(find.byKey(const ValueKey<String>('ov-map-add')), findsOneWidget,
          reason: '★★ 点「配置」必须真的能配 L1 —— 改前只弹一句话，什么都没打开');
      expect(find.text('创建'), findsNothing,
          reason: '★ 没有源定义可提交 ⇒ 不画提交按钮（点了只会写出半份 JSON）');
    });
  });

  // ─────────────────────────────────────────────────────────────────
  //  ⑤ 硬约束 1/3 的源码判据：只写 overrides
  // ─────────────────────────────────────────────────────────────────
  group('⑤ 硬约束：覆盖层只写 overrides（不改原件）', () {
    test('覆盖层这条链上不出现 写插件 / 装插件 的调用', () {
      for (final path in <String>[
        'lib/ui/widgets/composer_overrides_tab.dart',
        'lib/ui/widgets/override_editor_dialog.dart',
      ]) {
        final code = _stripComments(_read(path));
        for (final banned in <String>[
          'writePlugin',
          'installPlugin',
          'removePlugin',
          'pluginConfigSet',
        ]) {
          expect(code.contains(banned), isFalse,
              reason: '★★ $path 里出现了 `$banned` —— 覆盖层只允许写 overrides/<id>.json，'
                  '碰插件文件就违反"不影响原有插件本身"');
        }
      }

      /*
       * 正向判据：三条命令必须真的被用上。
       * ⚠️ 只在**页签文件**上判 —— P5 之后 `override_editor_dialog.dart` 是纯外壳，
       *    它一个 FFI 都不直接调（全部经 `ComposerOverridesTab`）。
       *    在那边判"必须含 getOverrideLayer"会变成对架构的误判（第一版就red在这）。
       *    外壳那边改判"必须真的把页签挂上去"，见下一条 expect。
       */
      final tab = _stripComments(_read('lib/ui/widgets/composer_overrides_tab.dart'));
      expect(tab.contains('getOverrideLayer'), isTrue,
          reason: '★ 不读就回显不出已有规则');
      expect(tab.contains('saveOverrideLayer'), isTrue,
          reason: '★ 不写就存不下去');
      expect(tab.contains('deleteOverrideLayer'), isTrue,
          reason: '★ 不删就做不到"删除即完全恢复"');

      final shell = _stripComments(_read('lib/ui/widgets/override_editor_dialog.dart'));
      expect(shell.contains('ComposerOverridesTab('), isTrue,
          reason: '★ 独立弹窗必须复用同一个页签（否则又是两套会漂移的实现）');
    });

    test('新页签文件不许绕过统一弹窗外壳（门禁口径同 zz_t1030 ⑥）', () {
      final code = _stripComments(_read('lib/ui/widgets/composer_overrides_tab.dart'));
      expect(RegExp(r'(?<![A-Za-z0-9_.])AlertDialog\(').hasMatch(code), isFalse);
      expect(RegExp(r'(?<![A-Za-z0-9_.])showDialog\(').hasMatch(code), isFalse,
          reason: '★ 页签本身不弹窗；万一将来要弹，必须走 showAppDialog');
      // 判据自检：同一个正则对真实样本必须命中（否则上面两条恒真）
      expect(
        RegExp(r'(?<![A-Za-z0-9_.])AlertDialog\(')
            .hasMatch(_stripComments('final x = AlertDialog(title: t);')),
        isTrue,
        reason: '★ 判据自检失败 ⇒ 上面那条"没出现"是恒真',
      );
    });
  });

  // ─────────────────────────────────────────────────────────────────
  //  ⑥ 第 07 项：卡片正文展开 / 收起（宿主 Set 持有）
  // ─────────────────────────────────────────────────────────────────
  group('⑥ 第 07 项：卡片正文点击展开', () {
    ProviderManifest manifest() => const ProviderManifest(
          id: 'exp-t1038',
          name: '展开探针源',
          kind: 'js',
        );

    Future<void> pumpCard(WidgetTester t, {VoidCallback? onOverride}) async {
      t.view.physicalSize = const Size(1000, 1600);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: AppTheme.themeFor(Brightness.dark),
        themeAnimationDuration: Duration.zero,
        home: Scaffold(
          body: SingleChildScrollView(
            child: Center(
              child: SizedBox(
                width: 700,
                child: settingsProviderCardForTest(
                  provider: manifest(),
                  cellWidth: 700,
                  onToggle: () {},
                  onEdit: () {},
                  onOverride: onOverride,
                ),
              ),
            ),
          ),
        ),
      ));
      await t.pump();
    }

    testWidgets('进入页面**不展开**；点正文展开；再点收起', (t) async {
      await pumpCard(t);

      expect(find.byType(ProxyPanel), findsNothing,
          reason: '★★ 硬约束 4：不做默认全展开（26 张卡全展开会同时挂 26 份网络面板）');

      await t.tap(find.text('展开探针源'));
      await t.pump();
      expect(find.byType(ProxyPanel), findsOneWidget,
          reason: '★ 点正文必须真的把 `_panels()` 挂出来');

      await t.tap(find.text('展开探针源'));
      await t.pump();
      expect(find.byType(ProxyPanel), findsNothing,
          reason: '★ 必须是**双向**开关（只能开不能关 = 用户只能重进页面才收起来）');
    });

    testWidgets('按钮区/菜单不误触：点「更多操作」→「编辑」都不改变展开态', (t) async {
      var overrides = 0;
      await pumpCard(t, onOverride: () => overrides++);

      await t.tap(find.text('展开探针源'));
      await t.pump();
      expect(find.byType(ProxyPanel), findsOneWidget);

      final more = find.byTooltip('更多操作');
      expect(more, findsOneWidget, reason: '前提：卡片上有 ⋮ 菜单');
      await t.tap(more);
      await t.pumpAndSettle();
      expect(find.byType(ProxyPanel), findsOneWidget,
          reason: '★ 点 ⋮ 不该收起详情');

      await t.tap(find.text('个性化覆盖层…'));
      await t.pumpAndSettle();
      expect(overrides, 1, reason: '★ 菜单项必须真的调到宿主回调');
      expect(find.byType(ProxyPanel), findsOneWidget,
          reason: '★★ 按钮区点击不该改变展开态（误触判据）');
    });

    test('源码判据：展开态由**宿主 Set** 持有，卡片仍是 StatelessWidget', () {
      final code = _stripComments(_read('lib/ui/settings_page.dart'));

      expect(code.contains('_expandedProviderIds'), isTrue,
          reason: '★ 展开态必须由宿主 `Set<String>` 持有（硬约束 4）');
      expect(
        RegExp(r'expanded:\s*_expandedProviderIds\.contains\(').hasMatch(code),
        isTrue,
        reason: '★★ 卡片必须从宿主读展开态 —— 找不到这行说明它又在卡片内部自己 setState 了',
      );
      expect(
        RegExp(r'class _ProviderDetailsScope').hasMatch(code),
        isFalse,
        reason: '★ 改前那套"每张卡内部 StatefulWidget 记展开态"必须已被移除',
      );
    });
  });

  // ─────────────────────────────────────────────────────────────────
  //  ⑦ 第 07 项：命中区**几何**判据（补 task-28 查出的盲点 A）
  // ─────────────────────────────────────────────────────────────────
  //
  // ★ 为什么必须有几何判据（文本级推演，见 task-28 交付）
  // ```text
  // ⑥ 那条"点 ⋮ → 点菜单项 → 详情还在"是**行为**判据，但它抓不到
  // "把 GestureDetector 从 Expanded(正文) 提到整个 Row 外面"这个回归：
  //   两层 TapGestureRecognizer 同时进竞技场时，**内层先夺冠** ⇒ 菜单照常开、
  //   外层 onTap 不触发 ⇒ ⑥ 依然全绿，而用户点图标/拖把手/空白都会莫名展开。
  // ⇒ 只能量**矩形**：命中区若真的长到按钮上，几何关系立刻不成立 ——
  //   这与手势竞技场的实现细节无关。
  // ```
  group('⑦ 第 07 项：正文点击区与按钮区**几何不相交**', () {
    ProviderManifest manifest() => const ProviderManifest(
          id: 'geo-t1038',
          name: '几何探针源',
          kind: 'js',
        );

    Future<void> pumpCard(WidgetTester t) async {
      t.view.physicalSize = const Size(1200, 1600);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: AppTheme.themeFor(Brightness.dark),
        themeAnimationDuration: Duration.zero,
        home: Scaffold(
          body: SingleChildScrollView(
            child: Center(
              child: SizedBox(
                width: 700,
                child: settingsProviderCardForTest(
                  provider: manifest(),
                  cellWidth: 700,
                  onToggle: () {},
                  onEdit: () {},
                ),
              ),
            ),
          ),
        ),
      ));
      await t.pump();
    }

    /// 正文那一格的 GestureDetector —— 从源名往上找**最近的**那个可点层
    ///
    /// ⚠️ 必须用"源名的祖先"而不是 `find.byWidgetPredicate` 全树扫：
    ///    卡片里还有别的 GestureDetector（菜单项、图标按钮内部），
    ///    全树扫会取到随机一个，矩形就不是正文那一格了。
    Finder bodyTapLayer() => find
        .ancestor(
          of: find.text('几何探针源'),
          matching: find.byWidgetPredicate(
            (w) => w is GestureDetector && w.onTap != null,
          ),
        )
        .first;

    testWidgets('★★★ 正文命中矩形与「更多操作」「上移」按钮**不相交**', (t) async {
      await pumpCard(t);

      final body = t.getRect(bodyTapLayer());
      final more = t.getRect(find.byTooltip('更多操作'));
      /*
       * ⚠️ 按钮区里最左那个按钮**不能用 byTooltip 找**：
       *   `AppIconButton` 没包 Material 的 Tooltip（见 app_icon_button.dart:88-97
       *   的 TODO），它把提示文本挂在 `Semantics.label` 上 ⇒ byTooltip 找不到。
       *   ⇒ 用图标找（`上移一位` 的箭头图标在禁用时也照样渲染）。
       */
      final firstAction = t.getRect(find.byIcon(AppIcons.keyboard_arrow_up).first);

      expect(body.overlaps(more), isFalse,
          reason: '★★★ 正文点击区与 ⋮ 按钮矩形相交 ⇒ 点菜单会顺带展开/收起详情'
              '（矩形 $body vs $more）。这条与手势竞技场无关，改坏了必红。');
      expect(body.overlaps(firstAction), isFalse,
          reason: '★★★ 正文点击区与「上移」按钮矩形相交（$body vs $firstAction）');
      // 几何方向也钉住：正文格必须在按钮区**左侧**，而不是把它包住
      expect(body.right, lessThanOrEqualTo(firstAction.left + 0.01),
          reason: '★★ 正文右边缘 ${body.right} 越过了按钮区左边缘 ${firstAction.left} '
              '⇒ GestureDetector 包住了按钮区');
      // 阳性对照：正文矩形必须**真的是**一段有面积的区域（防"量到零尺寸"让上面的断言恒真）
      expect(body.width, greaterThan(40));
      expect(body.height, greaterThan(10));
    });

    testWidgets('★★ 点在「正文与按钮之间那 8px 间隙」不改变展开态', (t) async {
      await pumpCard(t);

      final body = t.getRect(bodyTapLayer());
      final firstAction = t.getRect(find.byIcon(AppIcons.keyboard_arrow_up).first);
      final gapX = (body.right + firstAction.left) / 2;
      expect(firstAction.left - body.right, greaterThan(2),
          reason: '前提：正文与按钮之间**确实有**一段间隙（否则这条测不到东西）');

      expect(find.byType(ProxyPanel), findsNothing, reason: '前提：初始是收起的');

      await t.tapAt(Offset(gapX, body.center.dy));
      await t.pump();
      expect(find.byType(ProxyPanel), findsNothing,
          reason: '★★ 点间隙就展开了 ⇒ 命中区越界（这正是"整卡可点"的早期形态）');

      // 阳性对照：点正文**必须**能展开，否则上面那条"点间隙没反应"可能只是因为整页不可点
      await t.tap(bodyTapLayer());
      await t.pump();
      expect(find.byType(ProxyPanel), findsOneWidget,
          reason: '★ 阳性对照：正文确实可点（不然"间隙不响应"是空断言）');
    });
  });

  // ─────────────────────────────────────────────────────────────────
  //  ⑧ 页签门控：必须按 **id** 判，不许按 name（补盲点 B）
  // ─────────────────────────────────────────────────────────────────
  //
  // ★ 盲点原样（task-28）
  // ```text
  // 旧的 ① 组只测了"两个都不传 ⇒ 没页签"。
  // 把门控从 `overridesTargetId != null` 改成 `overridesSourceName != null`，
  // 那一组**依旧全绿**；而 `_withTabs` 里用的是 `widget.overridesTargetId!`
  // ⇒ 只传 name 时会 **null 崩**（用户点"配置"直接白屏）。
  // ```
  group('⑧ 页签门控只认 `overridesTargetId`（不认 name）', () {
    testWidgets('★★★ 只传 name（不传 id，且 overridesOnly）⇒ 不出页签、也不崩', (t) async {
      await t.pumpWidget(_host(const SourceComposerDialog(
        overridesSourceName: '只有名字',
        overridesOnly: true,
      )));
      await t.pumpAndSettle();

      expect(t.takeException(), isNull,
          reason: '★★★ 抛异常了 ⇒ 门控用了 name 却拿 `overridesTargetId!` 解包'
              '（这正是盲点 B 描述的 null 崩）');
      expect(find.byKey(const ValueKey<String>('composer-tab-0')), findsNothing,
          reason: '★★ 没有 id 就没有覆盖层可挂 —— 页签不许出现（哪怕给了名字）');
      expect(find.byKey(const ValueKey<String>('composer-tab-1')), findsNothing);
      // 退化成"只有源定义"，而不是空白面板
      expect(find.textContaining('① 站点'), findsOneWidget,
          reason: '★ 没有 id 时应照常显示源定义编排（不许空白）');
    });

    testWidgets('★★ 只传 id（不传 name）⇒ 出现页签，且覆盖层页用 id 当源名', (t) async {
      final h = _OvHooks();
      await t.pumpWidget(_host(SourceComposerDialog(
        overridesTargetId: 'only-id',
        loadOverrideLayer: h.load,
        saveOverrideLayer: h.save,
        deleteOverrideLayer: h.remove,
      )));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));

      expect(find.byKey(const ValueKey<String>('composer-tab-0')), findsOneWidget,
          reason: '★★ 有 id 就该出现页签（门控看的就是 id）');
      await _tap(t, 'composer-tab-1');
      await t.pump(const Duration(milliseconds: 100));

      final name = find.byKey(const ValueKey<String>('ov-source-name'));
      expect(name, findsOneWidget);
      expect(t.widget<Text>(name).data ?? '', contains('only-id'),
          reason: '★ 没给显示名时退回 id（`?? overridesTargetId!`），不许显示空');
      expect(h.loadedIds, <String>['only-id'],
          reason: '★ 必须用 id 去读覆盖层');
    });

    test('源码判据：门控 getter 只引用 `overridesTargetId`', () {
      final code = _stripComments(_read('lib/ui/widgets/source_composer_dialog.dart'));
      final start = code.indexOf('bool get _hasOverrides');
      expect(start, greaterThan(-1), reason: '找不到门控 getter —— 判据本身失效');
      final end = code.indexOf('}', start);
      final body = code.substring(start, end);
      expect(body.contains('overridesTargetId'), isTrue,
          reason: '★★ 门控必须按 id 判（页签内 `overridesTargetId!` 解包，靠它兜住）');
      expect(body.contains('overridesSourceName'), isFalse,
          reason: '★★ 门控不许看 name：只传 name 时会解包 null 崩（盲点 B）');
    });
  });

  // ─────────────────────────────────────────────────────────────────
  //  ⑨ 失败回显 + 多卡独立（补盲点 C）
  // ─────────────────────────────────────────────────────────────────
  group('⑨ 失败路径的用户可见回显 + 多卡展开互相独立', () {
    testWidgets('★★ 保存失败 ⇒ 状态行给核心原文（不含类名）、规则不清空', (t) async {
      final h = _OvHooks();
      h.failSaveWith = SourinCoreException('磁盘已满，写不进去', 'other');
      await _pumpComposer(t, h);
      await _tap(t, 'composer-tab-1');
      await t.pump(const Duration(milliseconds: 100));

      await _tap(t, 'ov-map-add');
      await _type(t, 'ov-map-0-from', 'title');
      await _type(t, 'ov-map-0-to', 'name');
      await _tap(t, 'ov-save');
      await t.pump(const Duration(milliseconds: 200));

      final status = find.byKey(const ValueKey<String>('ov-status'));
      expect(status, findsOneWidget,
          reason: '★★ 保存失败必须让用户看见 —— 静默失败会让用户以为存上了');
      final text = t.widget<Text>(status).data ?? '';
      expect(text, contains('磁盘已满'),
          reason: '★ 核心原文要透出来（用户才知道是磁盘满了，还是没权限）');
      expect(text, isNot(contains('SourinCoreException')),
          reason: '★ 不许把宿主类名塞给用户（门禁见 zz_t66_user_error_text_gate）');
      expect(_text(t, 'ov-map-0-from'), 'title',
          reason: '★★ 失败后用户填的规则必须还在（清空 = 白填一遍）');
    });

    testWidgets('★★ 删除失败 ⇒ 状态行给原因、表单**不清空**', (t) async {
      final h = _OvHooks(layer: <String, dynamic>{
        'target_id': 'p_tab',
        'mappings': <Map<String, dynamic>>[
          <String, dynamic>{'op': 'set', 'to': 'x', 'value': 'y'},
        ],
      });
      h.failDeleteWith = SourinCoreException('文件被占用，删不掉', 'other');
      await _pumpComposer(t, h);
      await _tap(t, 'composer-tab-1');
      await t.pump(const Duration(milliseconds: 100));

      await _tap(t, 'ov-restore');
      await _tap(t, 'ov-restore-confirm');
      await t.pump(const Duration(milliseconds: 200));

      final status = find.byKey(const ValueKey<String>('ov-status'));
      expect(status, findsOneWidget);
      final text = t.widget<Text>(status).data ?? '';
      expect(text, contains('删不掉'), reason: '★ 失败原因要透出来');
      expect(find.byKey(const ValueKey<String>('ov-map-0-op')), findsOneWidget,
          reason: '★★ 删除失败却把表单清空了 ⇒ 用户以为已恢复默认，实际那层还在生效');
    });

    testWidgets('★★★ 两张卡：展开 A 不影响 B，收起 A 也不影响 B', (t) async {
      t.view.physicalSize = const Size(1200, 1600);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: AppTheme.themeFor(Brightness.dark),
        themeAnimationDuration: Duration.zero,
        home: Scaffold(
          body: SingleChildScrollView(
            child: settingsProviderCardsForTest(
              providers: const <ProviderManifest>[
                ProviderManifest(id: 'geo-a', name: '卡甲'),
                ProviderManifest(id: 'geo-b', name: '卡乙'),
              ],
              cellWidth: 700,
            ),
          ),
        ),
      ));
      await t.pump();

      expect(find.byType(ProxyPanel), findsNothing,
          reason: '前提：两张卡初始都收起（不做默认全展开）');

      await t.tap(find.text('卡甲'));
      await t.pump();
      expect(find.byType(ProxyPanel), findsOneWidget,
          reason: '★ 展开甲 ⇒ 只有一份详情面板');
      expect(find.byType(PluginSpeedTestPanel), findsOneWidget,
          reason: '★ 甲的详情区（测速面板）挂了，乙的不该挂');

      await t.tap(find.text('卡乙'));
      await t.pump();
      expect(find.byType(ProxyPanel), findsNWidgets(2),
          reason: '★★ 展开乙之后两份都在（乙的展开不该把甲收起来）');

      await t.tap(find.text('卡甲'));
      await t.pump();
      expect(find.byType(ProxyPanel), findsOneWidget,
          reason: '★★★ 收起甲只影响甲 —— 若宿主用一个全局 bool（而不是按 id 的 Set），'
              '这里两个会一起收起/一起展开，数量永远不可能是 1');
    });
  });
}
