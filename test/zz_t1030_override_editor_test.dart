// ═══════════════════════════════════════════════════════════════════════
//  第 06 项 · 源个性化覆盖层 —— 可视化编辑器 UI 门禁
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件守什么
// ```text
// ① 打开即加载：已有覆盖层要**回显**到表单上（不是打开一张空表）
// ② 增删行：L1 / L2 各自可加可删，且删的是**那一行**
// ③ 保存结构：saveOverrideLayer 收到的 Map 必须与 overrides.rs 的
//    OverrideLayer **逐键对齐**（键名错一个 = Rust 侧整层 Broken = 静默不生效）
// ④ 恢复默认：真的调 deleteOverrideLayer，且表单回到"未个性化"
// ⑤ 非法输入被拦：空字段名 / 非整数 limit / 非法正则 —— 一律**不保存**
// ⑥ 外壳机制：走 AppGlassDialog（真 showAppDialog 路由），
//    内容区自带透明 Material 宿主（否则 TextField 在真路由里直接抛）
// ⑦ 真核心往返：真 sourin_core.dll + 真文件系统，证明键名真的能被 Rust 反序列化
// ```
//
// # 为什么每条都配一次故障注入（见 .probe/override-ui-inject.log）
// ```text
// 本仓记过多次「断言恒真 ⇒ 假绿」的教训。所以每条新断言都做过一次
// 反向实验：把被测的那一行代码改坏 ⇒ 断言必须变红。
// 注入的**原始输出**在 .probe/override-ui-inject.log，不是事后回忆。
// ```
//
// # 桩的边界（哪里能桩、哪里不许）
// ```text
// 允许桩：三个 FFI 边界函数（load / save / delete）—— 它们是文件/网络那一层。
// 禁止桩：状态机、校验、JSON 拼装、渲染。这些在下面每条用例里**都真跑**。
// ⇒ `OverrideEditorDialog` 的三个可选注入点只替换 FFI，不替换逻辑。
// ```

import 'dart:async';
import 'dart:io';

// 本仓 pubspec 没有直接声明 flutter_localizations（它是 SDK 包，随 flutter 提供）；
// 与 test/zz_t66_glass_dialog_test.dart 同一处境，这里显式豁免同一条 lint。
// ignore: depend_on_referenced_packages
import 'package:flutter_localizations/flutter_localizations.dart'
    show GlobalCupertinoLocalizations, GlobalWidgetsLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/design/widgets/app_glass_dialog.dart';
import 'package:sourin_spike/design/widgets/app_switch.dart';
import 'package:sourin_spike/design/widgets/app_text_button.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/overlay_motion.dart' show showAppDialog;
import 'package:sourin_spike/ui/widgets/override_editor_dialog.dart';

// ═══════════════════════════════════════════════════════════════════════
//  桩：只替换 FFI 边界
// ═══════════════════════════════════════════════════════════════════════

class _Hooks {
  _Hooks({
    this.layer,
    this.failLoad = false,
    this.deleteReturns = true,
  });

  /// `getOverrideLayer` 的返回值（null = 未个性化）
  Map<String, dynamic>? layer;

  /// true ⇒ 加载抛 SourinCoreException（验证错误文案走唯一入口）
  bool failLoad;

  /// `deleteOverrideLayer` 的返回值
  bool deleteReturns;

  /// 记录：收到的 targetId（加载 / 删除）
  final List<String> loadedIds = <String>[];
  final List<String> deletedIds = <String>[];

  /// 记录：保存收到的完整结构（null = 一次都没保存）
  Map<String, dynamic>? saved;
  int saveCalls = 0;

  Future<Map<String, dynamic>?> load(String id) async {
    loadedIds.add(id);
    if (failLoad) {
      throw SourinCoreException('覆盖层文件损坏，已按原始数据透出', 'other');
    }
    return layer;
  }

  Future<String> save(Map<String, dynamic> l) async {
    saveCalls += 1;
    saved = l;
    return 'C:/tmp/overrides/${l['target_id']}.json';
  }

  Future<bool> remove(String id) async {
    deletedIds.add(id);
    return deleteReturns;
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  挂载 / 弹出
// ═══════════════════════════════════════════════════════════════════════

/// 宿主：**零 Scaffold**。
///
/// # 为什么不能给 Scaffold（这不是洁癖）
/// ```text
/// Scaffold 会白送一个 Material 祖先 ⇒ 「内容区零 Material 宿主」这个前提
/// 在测试里被悄悄满足 ⇒ 我们会测出「TextField 能用」的**假结论**
/// （本仓 R4 那条改判记录就是踩了这个仪器问题）。
/// ⇒ 这里照产品形状：根下只有一个 SizedBox，弹窗走真 DialogRoute。
/// ```
Widget _host(GlobalKey<NavigatorState> key) => MaterialApp(
      navigatorKey: key,
      theme: AppTheme.themeFor(Brightness.dark),
      themeAnimationDuration: Duration.zero,
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const SizedBox(),
    );

/// 挂宿主，并把视口调大（弹窗内容会滚动，但横向要够宽才不折行）
Future<GlobalKey<NavigatorState>> _mount(WidgetTester t) async {
  t.view.physicalSize = const Size(1400, 1200);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  final key = GlobalKey<NavigatorState>();
  await t.pumpWidget(_host(key));
  return key;
}

/// 用**产品同款**方式弹出编辑器（真 showAppDialog 路由），等入场跑完
Future<void> _open(
  WidgetTester t,
  GlobalKey<NavigatorState> key,
  _Hooks h, {
  String targetId = 'p_demo',
  String sourceName = '演示源',
}) async {
  unawaited(
    showAppDialog<bool>(
      context: key.currentContext!,
      builder: (_) => OverrideEditorDialog(
        targetId: targetId,
        sourceName: sourceName,
        loadLayer: h.load,
        saveLayer: h.save,
        deleteLayer: h.remove,
      ),
    ),
  );
  await t.pump();
  await t.pump(const Duration(milliseconds: 800));
}

/// 点一下（先滚到可见 —— 弹窗内容区是会滚的）
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
  expect(f, findsOneWidget, reason: '找不到输入框 $key —— 判据本身失效了');
  await t.enterText(f, text);
  await t.pump();
}

/// 把某个下拉框切到指定 op
Future<void> _pickOp(WidgetTester t, String key, String label) async {
  await _tap(t, key);
  await t.pump(const Duration(milliseconds: 400));
  final item = find.text(label).last;
  expect(item, findsOneWidget, reason: '下拉框里找不到「$label」');
  await t.tap(item);
  await t.pump(const Duration(milliseconds: 400));
}

String _text(WidgetTester t, String key) {
  final f = find.byKey(ValueKey<String>(key));
  expect(f, findsOneWidget, reason: '找不到 $key');
  return t.widget<TextField>(f).controller!.text;
}

bool _switchValue(WidgetTester t, String key) {
  final f = find.byKey(ValueKey<String>(key));
  expect(f, findsOneWidget, reason: '找不到开关 $key');
  // AppSwitch 是自建开关（design/widgets/app_switch.dart），value 是它唯一的真源。
  // ⚠️ 不用 `as dynamic` 反射取值 —— 那样 value 改名后测试会**静默**炸在运行时
  //    而不是编译期；这里钉死类型，改名当场编译报错。
  return t.widget<AppSwitch>(f).value;
}

/// 当前下拉框选中的 op
String _opOf(WidgetTester t, String key) {
  final f = find.byKey(ValueKey<String>(key));
  expect(f, findsOneWidget, reason: '找不到下拉框 $key');
  return t.widget<DropdownButton<String>>(f).value!;
}

// ═══════════════════════════════════════════════════════════════════════
//  用例
// ═══════════════════════════════════════════════════════════════════════


/// 「缺件」还是「真失败」？—— 只有前者允许把用例降级成 skip
///
/// # 为什么必须分类（反假绿审计 B2/B3，task-15）
///
/// 改前是 `catch (_) { coreReady = false; }`：**任何**启动异常都被当成
/// 「这台机器没有 sourin_core.dll」⇒ 真缺陷（导出符号改名、bootstrap 报错、
/// FFI 契约破坏）会变成一行 skip —— 也就是**红变成不红**，比不做门禁更糟。
///
/// 判据只认**动态库加载失败**这一类：
/// ```text
/// ArgumentError: Failed to load dynamic library …（dlopen 失败）
/// undefined symbol / cannot open shared object / error code: 126 / 找不到指定的模块
/// ```
/// 其余一切（`SourinCoreException` = 核心自己报的错、IO 错误、断言失败）
/// **必须 fail** —— 那是"核心坏了"，不是"这台机器缺件"。
bool _isLibMissing(Object e) {
  final s = e.toString().toLowerCase();
  const marks = <String>[
    'failed to load dynamic library',
    'cannot open shared object',
    'the specified module could not be found',
    '找不到指定的模块',
    'undefined symbol',
    'error code: 126',
  ];
  return marks.any(s.contains);
}

void main() {
  // ─────────────────────────────────────────────────────────────────
  //  ① 打开即加载
  // ─────────────────────────────────────────────────────────────────
  group('① 打开时加载已有覆盖层', () {
    testWidgets('已有覆盖层 ⇒ 逐项回显（enabled / L1 / L2 / js_hook）', (t) async {
      final h = _Hooks(layer: <String, dynamic>{
        'target_id': 'p_demo',
        'enabled': false,
        'methods': <String>['search'],
        'mappings': <Map<String, dynamic>>[
          <String, dynamic>{'op': 'rename', 'from': 'title', 'to': 'name', 'keep': true},
          <String, dynamic>{'op': 'set', 'to': 'subtitle', 'value': '已个性化'},
        ],
        'transforms': <Map<String, dynamic>>[
          <String, dynamic>{'op': 'take_first', 'limit': 20},
        ],
        'js_hook': 'return data;',
        'note': '备注',
      });
      final key = await _mount(t);
      await _open(t, key, h);

      expect(h.loadedIds, <String>['p_demo'],
          reason: '★ 必须用传入的 targetId 去读，不能读死别的 id');

      // enabled=false 必须真的回显成关（不是默认 true）
      expect(_switchValue(t, 'ov-enabled'), isFalse,
          reason: '★ 覆盖层写着 enabled=false，开关却显示开着 ⇒ 用户一保存就把停用的层重新启用');

      // L1 第 0 行：rename + keep
      expect(_opOf(t, 'ov-map-0-op'), 'rename');
      expect(_text(t, 'ov-map-0-from'), 'title');
      expect(_text(t, 'ov-map-0-to'), 'name');
      expect(_switchValue(t, 'ov-map-0-keep'), isTrue);

      // L1 第 1 行：set 的常量值
      expect(_opOf(t, 'ov-map-1-op'), 'set');
      expect(_text(t, 'ov-map-1-to'), 'subtitle');
      expect(_text(t, 'ov-map-1-value'), '已个性化');

      // L2 第 0 行：take_first 的 limit（按 op 显示不同输入框）
      expect(_opOf(t, 'ov-tx-0-op'), 'take_first');
      expect(_text(t, 'ov-tx-0-limit'), '20');
      // ★ 关键：take_first 不该画出"字段名"框（那是别的 op 的输入框）
      expect(find.byKey(const ValueKey<String>('ov-tx-0-field')), findsNothing,
          reason: '★ take_first 没有 field 参数 —— 画出 field 框会让用户以为填了会生效');

      // L3
      expect(_text(t, 'ov-js-hook'), 'return data;');

      // 源名显示（用户要知道自己在改哪个源）
      expect(find.text('源：演示源'), findsOneWidget);
      expect(find.text('绑定 id：p_demo'), findsOneWidget);
    });

    testWidgets('未个性化（null）⇒ 空表单，且「保存」禁用', (t) async {
      final h = _Hooks();
      final key = await _mount(t);
      await _open(t, key, h);

      expect(find.byKey(const ValueKey<String>('ov-map-0-op')), findsNothing,
          reason: 'null ⇒ 不该凭空画出一行规则');
      expect(_text(t, 'ov-js-hook'), '');

      final save = t.widget<AppTextButton>(
        find.byKey(const ValueKey<String>('ov-save')),
      );
      expect(save.onPressed, isNull,
          reason: '★ 一条规则都没有时保存必须禁用 —— '
              '空覆盖层在 Rust 侧是 NotApplicable（永远不生效），存下去只会留一个死文件');
    });

    testWidgets('读取失败 ⇒ 显示人话，且不出现宿主类名', (t) async {
      final h = _Hooks(failLoad: true);
      final key = await _mount(t);
      await _open(t, key, h);

      final err = find.byKey(const ValueKey<String>('ov-load-error'));
      expect(err, findsOneWidget, reason: '★ 读失败必须让用户看见，不能静默当成"未个性化"');
      final text = t.widget<Text>(err).data ?? '';
      expect(text, contains('覆盖层文件损坏'),
          reason: '★ 核心原文要透出来（用户才知道是文件坏了）');
      expect(text, isNot(contains('SourinCoreException')),
          reason: '★ 不许把宿主类名塞给用户（门禁见 zz_t66_user_error_text_gate_test）');
      expect(find.byKey(const ValueKey<String>('ov-reload')), findsOneWidget,
          reason: '失败要能重试');
    });
  });

  // ─────────────────────────────────────────────────────────────────
  //  ② 增删行
  // ─────────────────────────────────────────────────────────────────
  group('② 增删行', () {
    testWidgets('L1：加三行、删中间那行，剩下的是对的那一行', (t) async {
      final h = _Hooks();
      final key = await _mount(t);
      await _open(t, key, h);

      // ★ 加三次 ⇒ 三行（下标 0/1/2）。只加两次却去点下标 2，
      //   测的就不是"删错行"，而是"那一行根本没建出来" —— 判据会假红。
      await _tap(t, 'ov-map-add');
      await _tap(t, 'ov-map-add');
      await _tap(t, 'ov-map-add');
      expect(find.byKey(const ValueKey<String>('ov-map-2-op')), findsOneWidget,
          reason: '阳性对照：三行都建出来了，后面的删除才有意义');

      // 三行填不同内容，删中间 ⇒ 若删错行，剩下的内容会露馅
      await _type(t, 'ov-map-0-from', 'aaa');
      await _type(t, 'ov-map-1-from', 'bbb');
      await _type(t, 'ov-map-2-from', 'ccc');

      await _tap(t, 'ov-map-1-del');
      await t.pump();

      expect(find.byKey(const ValueKey<String>('ov-map-2-op')), findsNothing,
          reason: '★ 删完只剩两行（下标 0/1）');
      expect(_text(t, 'ov-map-0-from'), 'aaa');
      expect(_text(t, 'ov-map-1-from'), 'ccc',
          reason: '★ 删的必须是第 2 行（bbb）—— 若删了最后一行，这里会是 bbb');
    });

    testWidgets('L2：加两行、删第一行', (t) async {
      final h = _Hooks();
      final key = await _mount(t);
      await _open(t, key, h);

      await _tap(t, 'ov-tx-add');
      await _tap(t, 'ov-tx-add');
      await _type(t, 'ov-tx-0-field', 'first');
      await _type(t, 'ov-tx-1-field', 'second');

      await _tap(t, 'ov-tx-0-del');
      await t.pump();

      expect(find.byKey(const ValueKey<String>('ov-tx-1-op')), findsNothing);
      expect(_text(t, 'ov-tx-0-field'), 'second',
          reason: '★ 删第一行后，原来的第二行要顶上来');
    });

    testWidgets('切换 op ⇒ 输入框跟着换（set 没有 from，sort_by 有 desc）', (t) async {
      final h = _Hooks();
      final key = await _mount(t);
      await _open(t, key, h);

      await _tap(t, 'ov-map-add');
      // 默认 rename ⇒ 有 from
      expect(find.byKey(const ValueKey<String>('ov-map-0-from')), findsOneWidget);

      await _pickOp(t, 'ov-map-0-op', '常量覆盖 set');
      expect(find.byKey(const ValueKey<String>('ov-map-0-from')), findsNothing,
          reason: '★ set 没有 from 参数 —— 留着那个框等于给用户一个假输入位');
      expect(find.byKey(const ValueKey<String>('ov-map-0-value')), findsOneWidget);

      await _tap(t, 'ov-tx-add');
      await _pickOp(t, 'ov-tx-0-op', '按字段排序 sort_by');
      expect(find.byKey(const ValueKey<String>('ov-tx-0-desc')), findsOneWidget,
          reason: '★ sort_by 才有 desc');
      expect(find.byKey(const ValueKey<String>('ov-tx-0-limit')), findsNothing);
    });
  });

  // ─────────────────────────────────────────────────────────────────
  //  ③ 保存结构
  // ─────────────────────────────────────────────────────────────────
  group('③ 保存后 saveOverrideLayer 收到正确结构', () {
    testWidgets('三种 L1 + 两种 L2 + js + enabled ⇒ 逐键对齐 overrides.rs', (t) async {
      final h = _Hooks();
      final key = await _mount(t);
      await _open(t, key, h);

      // L1 ① rename
      await _tap(t, 'ov-map-add');
      await _type(t, 'ov-map-0-from', 'title');
      await _type(t, 'ov-map-0-to', 'name');
      await _tap(t, 'ov-map-0-keep');

      // L1 ② set
      await _tap(t, 'ov-map-add');
      await _pickOp(t, 'ov-map-1-op', '常量覆盖 set');
      await _type(t, 'ov-map-1-to', 'subtitle');
      await _type(t, 'ov-map-1-value', '常量');

      // L1 ③ copy
      await _tap(t, 'ov-map-add');
      await _pickOp(t, 'ov-map-2-op', '路径取值 copy');
      await _type(t, 'ov-map-2-from', 'pager.total');
      await _type(t, 'ov-map-2-to', 'total');

      // L2 ① filter_contains
      await _tap(t, 'ov-tx-add');
      await _type(t, 'ov-tx-0-field', 'title');
      await _type(t, 'ov-tx-0-contains', '番剧');

      // L2 ② take_first
      await _tap(t, 'ov-tx-add');
      await _pickOp(t, 'ov-tx-1-op', '只留前 N 条 take_first');
      await _type(t, 'ov-tx-1-limit', '20');

      // L3
      await _type(t, 'ov-js-hook', 'return data;');

      await _tap(t, 'ov-save');
      await t.pump(const Duration(milliseconds: 400));

      expect(h.saveCalls, 1, reason: '★ 保存必须**只**调一次（双击不该写两遍）');
      expect(h.saved, isNotNull);

      expect(h.saved, <String, dynamic>{
        'target_id': 'p_demo',
        'enabled': true,
        'methods': <String>[],
        'mappings': <Map<String, dynamic>>[
          <String, dynamic>{'op': 'rename', 'from': 'title', 'to': 'name', 'keep': true},
          <String, dynamic>{'op': 'set', 'to': 'subtitle', 'value': '常量'},
          <String, dynamic>{'op': 'copy', 'from': 'pager.total', 'to': 'total'},
        ],
        'transforms': <Map<String, dynamic>>[
          <String, dynamic>{
            'op': 'filter_contains',
            'field': 'title',
            'contains': '番剧',
          },
          <String, dynamic>{'op': 'take_first', 'limit': 20},
        ],
        'js_hook': 'return data;',
        'note': '',
      }, reason: '★★ 键名必须与 overrides.rs 的 OverrideLayer **逐字一致**：'
          '错一个键 ⇒ Rust 侧 serde 用 default 兜底 ⇒ 该字段静默丢失'
          '（用户看到"设了没用"）。');

      // 保存成功 ⇒ 关窗（结果交给调用方）
      expect(find.byType(AppGlassDialog), findsNothing,
          reason: '★ 保存成功后弹窗要关掉，否则用户以为没生效会再点一次');
    });

    testWidgets('methods / note 原样带回（编辑器没有它们的界面，但不许清掉）', (t) async {
      final h = _Hooks(layer: <String, dynamic>{
        'target_id': 'p_demo',
        'enabled': true,
        'methods': <String>['search', 'detail'],
        'mappings': <Map<String, dynamic>>[
          <String, dynamic>{'op': 'copy', 'from': 'a.b', 'to': 'c'},
        ],
        'transforms': <Map<String, dynamic>>[],
        'js_hook': '',
        'note': '这是我自己写的备注',
      });
      final key = await _mount(t);
      await _open(t, key, h);

      // 只改一个字段名
      await _type(t, 'ov-map-0-to', 'cc');
      await _tap(t, 'ov-save');
      await t.pump(const Duration(milliseconds: 400));

      expect(h.saved!['methods'], <String>['search', 'detail'],
          reason: '★ 方法白名单必须原样带回 —— 用户只改了个字段名，'
              '不该顺手丢掉"只对这些方法生效"的配置');
      expect(h.saved!['note'], '这是我自己写的备注');
    });

    testWidgets('关掉启用开关 ⇒ enabled=false 进 JSON', (t) async {
      final h = _Hooks(layer: <String, dynamic>{
        'target_id': 'p_demo',
        'enabled': true,
        'mappings': <Map<String, dynamic>>[
          <String, dynamic>{'op': 'set', 'to': 'x', 'value': 'y'},
        ],
      });
      final key = await _mount(t);
      await _open(t, key, h);

      await _tap(t, 'ov-enabled');
      await _tap(t, 'ov-save');
      await t.pump(const Duration(milliseconds: 400));

      expect(h.saved!['enabled'], isFalse,
          reason: '★ 开关状态必须真的写进 JSON（Rust 侧 enabled=false 就整层不生效）');
    });
  });

  // ─────────────────────────────────────────────────────────────────
  //  ④ 恢复默认
  // ─────────────────────────────────────────────────────────────────
  group('④ 恢复默认', () {
    testWidgets('点恢复默认 ⇒ 二次确认 ⇒ 真的调 deleteOverrideLayer', (t) async {
      final h = _Hooks(layer: <String, dynamic>{
        'target_id': 'p_demo',
        'enabled': true,
        'mappings': <Map<String, dynamic>>[
          <String, dynamic>{'op': 'rename', 'from': 'title', 'to': 'name'},
        ],
        'js_hook': 'return data;',
      });
      final key = await _mount(t);
      await _open(t, key, h);

      // 第一下只展开确认（删除不可逆，不许一键就删）
      await _tap(t, 'ov-restore');
      expect(h.deletedIds, isEmpty,
          reason: '★ 第一下**不许**真的删 —— 删除是破坏性动作，必须二次确认');
      expect(find.byKey(const ValueKey<String>('ov-restore-confirm')), findsOneWidget);

      await _tap(t, 'ov-restore-confirm');
      await t.pump(const Duration(milliseconds: 400));

      expect(h.deletedIds, <String>['p_demo'],
          reason: '★ 必须用当前 targetId 调 deleteOverrideLayer（调错 id 会删到别的源的覆盖层）');

      // 表单回到"未个性化"
      expect(find.byKey(const ValueKey<String>('ov-map-0-op')), findsNothing,
          reason: '★ 删完表单要清空 —— 否则用户以为那层还在');
      expect(_text(t, 'ov-js-hook'), '');

      final status = find.byKey(const ValueKey<String>('ov-status'));
      expect(status, findsOneWidget, reason: '★ 要给一句"已恢复默认"的结果提示');
      expect((t.widget<Text>(status).data ?? ''), contains('已恢复默认'));
    });

    testWidgets('确认框里点取消 ⇒ 不删、表单不动', (t) async {
      final h = _Hooks(layer: <String, dynamic>{
        'target_id': 'p_demo',
        'mappings': <Map<String, dynamic>>[
          <String, dynamic>{'op': 'set', 'to': 'x', 'value': 'y'},
        ],
      });
      final key = await _mount(t);
      await _open(t, key, h);

      await _tap(t, 'ov-restore');
      await _tap(t, 'ov-restore-cancel');

      expect(h.deletedIds, isEmpty, reason: '★ 取消后**一次都不许**删');
      expect(find.byKey(const ValueKey<String>('ov-map-0-op')), findsOneWidget,
          reason: '★ 取消后表单必须原样留着');
      expect(find.byKey(const ValueKey<String>('ov-restore')), findsOneWidget,
          reason: '★ 确认行要收回去');
    });

    testWidgets('本来就没有覆盖层 ⇒ 删除也调了，提示说清"当前就是原插件行为"', (t) async {
      final h = _Hooks(layer: null, deleteReturns: false);
      final key = await _mount(t);
      await _open(t, key, h);

      await _tap(t, 'ov-restore');
      await _tap(t, 'ov-restore-confirm');
      await t.pump(const Duration(milliseconds: 400));

      expect(h.deletedIds, <String>['p_demo']);
      final status = t.widget<Text>(find.byKey(const ValueKey<String>('ov-status')));
      expect(status.data ?? '', contains('本来就没有覆盖层'),
          reason: '★ existed=false 时说"已恢复默认"会让用户以为刚删掉了什么东西');
    });
  });

  // ─────────────────────────────────────────────────────────────────
  //  ⑤ 非法输入被拦
  // ─────────────────────────────────────────────────────────────────
  group('⑤ 非法输入被拦（保存前）', () {
    testWidgets('rename 的 from 为空 ⇒ 不保存 + 红字说明', (t) async {
      final h = _Hooks();
      final key = await _mount(t);
      await _open(t, key, h);

      await _tap(t, 'ov-map-add');
      await _type(t, 'ov-map-0-to', 'name'); // from 故意留空
      await _tap(t, 'ov-save');
      await t.pump(const Duration(milliseconds: 200));

      expect(h.saveCalls, 0,
          reason: '★ 空字段名在 Rust 侧 `obj.get("")` 恒为 None ⇒ 规则静默不生效。'
              '必须在保存前拦住，而不是写一个永远不生效的文件');
      final status = t.widget<Text>(find.byKey(const ValueKey<String>('ov-status')));
      expect(status.data ?? '', contains('不能为空'));
      expect(status.data ?? '', contains('第 1 条'),
          reason: '★ 要指出是第几条 —— 有 20 条规则时用户找不到是哪条');
    });

    testWidgets('rename 的 from == to ⇒ 不保存（改名不会有任何效果）', (t) async {
      final h = _Hooks();
      final key = await _mount(t);
      await _open(t, key, h);

      await _tap(t, 'ov-map-add');
      await _type(t, 'ov-map-0-from', 'title');
      await _type(t, 'ov-map-0-to', 'title');
      await _tap(t, 'ov-save');
      await t.pump(const Duration(milliseconds: 200));

      expect(h.saveCalls, 0);
      expect(
        t.widget<Text>(find.byKey(const ValueKey<String>('ov-status'))).data ?? '',
        contains('相同'),
      );
    });

    testWidgets('take_first 的 limit 不是整数 ⇒ 不保存（Rust 侧会整层 Broken）', (t) async {
      final h = _Hooks();
      final key = await _mount(t);
      await _open(t, key, h);

      await _tap(t, 'ov-tx-add');
      await _pickOp(t, 'ov-tx-0-op', '只留前 N 条 take_first');
      await _type(t, 'ov-tx-0-limit', 'abc');
      await _tap(t, 'ov-save');
      await t.pump(const Duration(milliseconds: 200));

      expect(h.saveCalls, 0,
          reason: '★ limit 不是整数 ⇒ serde 解析 usize 失败 ⇒ 整份覆盖层 Broken ⇒ '
              '**连别的规则一起失效**。这是最重的一条，必须拦');
      expect(
        t.widget<Text>(find.byKey(const ValueKey<String>('ov-status'))).data ?? '',
        contains('整数'),
      );
    });

    testWidgets('非法正则 ⇒ 不保存（Rust 侧只会跳过这一条）', (t) async {
      final h = _Hooks();
      final key = await _mount(t);
      await _open(t, key, h);

      await _tap(t, 'ov-tx-add');
      await _pickOp(t, 'ov-tx-0-op', '正则保留 filter_regex');
      await _type(t, 'ov-tx-0-field', 'title');
      await _type(t, 'ov-tx-0-pattern', '([');
      await _tap(t, 'ov-save');
      await t.pump(const Duration(milliseconds: 200));

      expect(h.saveCalls, 0,
          reason: '★ 非法正则 Rust 侧只记日志跳过 ⇒ 用户看到"规则配了没生效"');
      expect(
        t.widget<Text>(find.byKey(const ValueKey<String>('ov-status'))).data ?? '',
        contains('正则不合法'),
      );
    });

    testWidgets('limit=0 是**合法**的（清空整个列表）—— 不许被误拦', (t) async {
      final h = _Hooks();
      final key = await _mount(t);
      await _open(t, key, h);

      await _tap(t, 'ov-tx-add');
      await _pickOp(t, 'ov-tx-0-op', '只留前 N 条 take_first');
      await _type(t, 'ov-tx-0-limit', '0');
      await _tap(t, 'ov-save');
      await t.pump(const Duration(milliseconds: 400));

      expect(h.saveCalls, 1,
          reason: '★ overrides.rs 明写 `limit=0 ⇒ 清空`，这是合法用法（"这个区块我不要"）');
      expect((h.saved!['transforms'] as List).first['limit'], 0);
    });
  });

  // ─────────────────────────────────────────────────────────────────
  //  ⑥ 外壳机制（真路由 / Material 宿主 / 安全提示）
  // ─────────────────────────────────────────────────────────────────
  group('⑥ 外壳与提示', () {
    testWidgets('真 showAppDialog 路由下不抛，且 TextField 有透明 Material 宿主', (t) async {
      final h = _Hooks(layer: <String, dynamic>{
        'target_id': 'p_demo',
        'mappings': <Map<String, dynamic>>[
          <String, dynamic>{'op': 'rename', 'from': 'a', 'to': 'b'},
        ],
      });
      final key = await _mount(t);
      await _open(t, key, h);

      expect(t.takeException(), isNull,
          reason: '★ 弹窗在真路由里抛了 —— 内容区没有 Material 宿主时 '
              'TextField 会抛 "No Material widget found"');

      // 结构判据：那个 TextField 的祖先里必须有 Material
      final field = find.byKey(const ValueKey<String>('ov-js-hook'));
      expect(field, findsOneWidget);
      final mat = find.ancestor(
        of: field,
        matching: find.byWidgetPredicate(
          (w) => w is Material && w.type == MaterialType.transparency,
        ),
      );
      expect(mat, findsWidgets,
          reason: '★ 内容区必须自带 `Material(type: MaterialType.transparency)` —— '
              '这是 AppGlassDialog 零 Material 宿主下的既定补法（见 zz_dialog18 仪器自检）');
    });

    testWidgets('多行 JS 框显式左对齐（外壳内容区写死 center）', (t) async {
      final h = _Hooks();
      final key = await _mount(t);
      await _open(t, key, h);

      final w = t.widget<TextField>(find.byKey(const ValueKey<String>('ov-js-hook')));
      expect(w.textAlign, TextAlign.left,
          reason: '★ 外壳内容区 DefaultTextStyle 是 textAlign:center ⇒ '
              '不显式写 left，用户写 JS 时每行都在中间');
      expect(w.maxLines, greaterThan(1), reason: '★ L3 必须是多行框');

      // 普通输入框同理（同一类缺陷，一起守）
      await _tap(t, 'ov-map-add');
      final f2 = t.widget<TextField>(find.byKey(const ValueKey<String>('ov-map-0-from')));
      expect(f2.textAlign, TextAlign.left);
    });

    testWidgets('安全提示与「恢复默认」按钮都在（不用滚也能看到标题）', (t) async {
      final h = _Hooks();
      final key = await _mount(t);
      await _open(t, key, h);

      expect(find.text('覆盖层不改原插件'), findsOneWidget,
          reason: '★ 用户对"个性化"最怕的就是"会不会把插件弄坏"，这句话必须在按下任何按钮之前就在');
      expect(
        t.widget<Text>(find.byKey(const ValueKey<String>('ov-safety-body'))).data ?? '',
        allOf(contains('overrides'), contains('完全恢复')),
        reason: '★ 要说清两件事：只写 overrides 目录 + 删除即完全恢复',
      );
      expect(find.byKey(const ValueKey<String>('ov-restore')), findsOneWidget);
    });

    test('结构对照：不许裸 AlertDialog / 裸 showDialog（§3.5 + AGENTS §4）', () {
      final src = File('lib/ui/widgets/override_editor_dialog.dart').readAsStringSync();
      final code = _stripComments(src);
      expect(RegExp(r'(?<![A-Za-z0-9_.])AlertDialog\(').hasMatch(code), isFalse,
          reason: '★ 弹窗必须走 AppGlassDialog（本仓规定）');
      expect(RegExp(r'(?<![A-Za-z0-9_.])showDialog\(').hasMatch(code), isFalse,
          reason: '★ 弹出必须走 showAppDialog（唯一入口，承载 animationStyle）');
      expect(code.contains('AppGlassDialog('), isTrue,
          reason: '★ 外壳必须是 AppGlassDialog —— 上面两条是"没违规"，这条是"真的用了"');
      // 反向对照：判据本身不是恒真
      expect(
        RegExp(r'(?<![A-Za-z0-9_.])AlertDialog\(')
            .hasMatch(_stripComments('final x = AlertDialog(title: t);')),
        isTrue,
        reason: '★ 判据自检：它对真实样本必须命中（否则上面那条恒为真）',
      );
      expect(
        RegExp(r'(?<![A-Za-z0-9_.])AlertDialog\(')
            .hasMatch(_stripComments('// 以前这里是 AlertDialog(title: t)')),
        isFalse,
        reason: '★ 剥注释要真的生效（注释里记的改前写法不算违规）',
      );
    });

    test('入口函数：showOverrideEditorDialog 走 showAppDialog 且带上两个入参', () {
      final code = _stripComments(
        File('lib/ui/widgets/override_editor_dialog.dart').readAsStringSync(),
      );
      expect(code.contains('showAppDialog<bool>('), isTrue);
      expect(code.contains('OverrideEditorDialog('), isTrue);
      expect(code.contains('targetId: targetId'), isTrue);
      expect(code.contains('sourceName: sourceName'), isTrue);
    });
  });

  // ─────────────────────────────────────────────────────────────────
  //  ⑦ 真核心往返（真 dll + 真文件系统，证明键名对得上）
  // ─────────────────────────────────────────────────────────────────
  group('⑦ 真核心往返：拼出来的结构 Rust 真的认得', () {
    late Directory dataDir;
    var coreReady = false;

    setUpAll(() async {
      dataDir = await Directory.systemTemp.createTemp('sourin_ovr_ui_');
      try {
        final r = await SourinCore.startAsync(dataDir.path);
        if (r['ok'] != true) {
          fail('核心启动返回 ok!=true（不是缺件）：$r');
        }
        coreReady = true;
      } catch (e, st) {
        // ★ 只有动态库加载失败才允许 skip（见文件头 _isLibMissing）
        if (!_isLibMissing(e)) {
          fail('核心启动失败（**不是**缺件 ⇒ 不许降级成 skip）：$e\n$st');
        }
        coreReady = false;
      }
      /*
       * ★ 断掉「局域网遥控」自启（反假绿审计：`startAsync` 会真的起 8642 端口的
       *   遥控服务，`[REMOTE] ★ 遥控自启成功：http://10.x.x.x:8642/`）。
       * Dart 不能改本进程环境变量 ⇒ 启动成功后立刻停 + 核对 running=false。
       * ⚠️ 放在 try 之外：`remote_stop` 失败是真缺陷，别被"启动失败"分支吃掉。
       */
      if (coreReady) {
        // ★ 只用 `remote_stop`：它**返回的就是** RemoteStatus（含 running），
        //   而 `remote_status` 这条命令在 FFI 层**还没接线**（实测报
        //   `命令 remote_status 尚未接入 FFI 层`）—— 用未接线的命令做判据等于把门禁
        //   建立在一条会抛异常的路上。
        final stopped = await SourinCore.callAsync('remote_stop');
        if (stopped is Map && stopped['running'] == true) {
          fail('遥控服务没停下来（remote_stop 返回 running=true）：$stopped');
        }
      }
    });

    tearDownAll(() async {
      try {
        await dataDir.delete(recursive: true);
      } catch (_) {}
    });

    test('buildOverrideLayer 的键名能被 Rust 反序列化并原样读回', () async {
      if (!coreReady) {
        // ★ 不静默通过：明确报出"这条没跑"，否则又是一个假绿
        // 环境缺件（本机没有 dll）⇒ 允许 skip，但必须点名缺什么 + 替代覆盖在哪
        markTestSkipped('环境缺件：缺 sourin_core.dll（本机 build 产物未就位）；'
            '替代覆盖：Rust 端 overrides 的 lib 单测 + 本文件 ①②③ 的结构断言');
        return;
      }
      const id = 'ui_roundtrip_src';
      final layer = buildOverrideLayer(
        targetId: id,
        enabled: true,
        methods: <String>['search'],
        mappings: <Map<String, dynamic>>[
          <String, dynamic>{'op': 'rename', 'from': 'title', 'to': 'name', 'keep': true},
          <String, dynamic>{'op': 'set', 'to': 'subtitle', 'value': '常量'},
          <String, dynamic>{'op': 'copy', 'from': 'pager.total', 'to': 'total'},
        ],
        transforms: <Map<String, dynamic>>[
          <String, dynamic>{'op': 'filter_contains', 'field': 'title', 'contains': '番剧'},
          <String, dynamic>{'op': 'filter_not_contains', 'field': 'title', 'contains': '预告'},
          <String, dynamic>{'op': 'filter_regex', 'field': 'title', 'pattern': r'^EP\d+$'},
          <String, dynamic>{'op': 'sort_by', 'field': 'n', 'desc': false},
          <String, dynamic>{'op': 'dedup_by', 'field': 'id'},
          <String, dynamic>{'op': 'take_first', 'limit': 20},
          <String, dynamic>{
            'op': 'replace_in_field',
            'field': 'title',
            'from': '【官方】',
            'to': '',
          },
        ],
        jsHook: 'return data;',
        note: 'ui 往返',
      );

      final path = await SourinApi.saveOverrideLayer(layer);
      expect(path, contains('overrides'), reason: '只能写到 overrides 目录');
      expect(File(path).existsSync(), isTrue, reason: '文件必须真的落盘');

      final got = await SourinApi.getOverrideLayer(id);
      expect(got, isNotNull, reason: '★ 存进去却读不出来 ⇒ 键名或类型对不上');
      expect(got!['target_id'], id);
      expect(got['enabled'], isTrue);
      expect(got['methods'], <String>['search']);
      expect(got['note'], 'ui 往返');

      final maps = got['mappings'] as List;
      expect(maps.length, 3, reason: '★ 三条 L1 必须完整往返');
      expect(maps[0]['op'], 'rename');
      expect(maps[0]['keep'], isTrue);
      expect(maps[2]['op'], 'copy');
      expect(maps[2]['from'], 'pager.total');

      final txs = got['transforms'] as List;
      expect(txs.length, 7, reason: '★ 七种 L2 变换必须**逐个**往返（少一个就是那个键名写错了）');
      expect(txs.map((e) => e['op']).toList(), <String>[
        'filter_contains',
        'filter_not_contains',
        'filter_regex',
        'sort_by',
        'dedup_by',
        'take_first',
        'replace_in_field',
      ]);
      expect(txs[3]['desc'], isFalse);
      expect(txs[5]['limit'], 20);
      expect(txs[6]['to'], '', reason: '★ to 允许空串（= 直接删掉这段字）');

      // 收尾：删掉，不留垃圾文件
      final removed = await SourinApi.deleteOverrideLayer(id);
      expect(removed, isTrue, reason: '删除必须真的删掉（否则留下一个永远生效的覆盖层）');
      expect(await SourinApi.getOverrideLayer(id), isNull);
    });

    test('js_hook：UI 一定送出去；dll 认不认这条单独取证', () async {
      /*
       * ★★★ 为什么这条要单独拆出来（2026-10-24 实测，不是防御性编程）
       *
       * ```text
       * 现场：仓库根的 sourin_core.dll 是 17:00 构建的，
       *       而 overrides.rs 里 `js_hook` 字段是 17:43 才加进模型（L3 阶段）。
       * 实测（.probe/ovr_keys_probe_test.dart）：
       *   存进去的 JSON 文件里 **没有** "js_hook" 键；
       *   get_override_layer 读回的 keys = [enabled, mappings, methods, note,
       *                                     target_id, transforms]
       * ⇒ 那个 dll **不认识** L3 字段（它按旧结构序列化，直接把它丢了）。
       * ```
       *
       * ⇒ 这不是 UI 的缺陷（UI 的 payload 里一定有 js_hook —— 见下面第一条断言），
       *   是**构建产物比源码旧**。所以：
       *   ① UI 侧断言**无条件**执行（它必须送出去，这是 UI 的责任）；
       *   ② dll 侧往返**按能力取证**：dll 认，就断言值一致；
       *      dll 不认，就**明确报出**"这个 dll 早于 L3"并跳过那一条 ——
       *      而不是把断言改软（改软会让真正丢字段的回归也变绿）。
       */
      final layer = buildOverrideLayer(
        targetId: 'ui_js_src',
        enabled: true,
        methods: const <String>[],
        mappings: const <Map<String, dynamic>>[],
        transforms: const <Map<String, dynamic>>[],
        jsHook: 'return data;',
        note: '',
      );
      // ① UI 侧：无条件
      expect(layer.containsKey('js_hook'), isTrue,
          reason: '★ UI 拼出来的结构必须带 js_hook 键 —— 少了它，用户写的 JS 根本到不了 Rust');
      expect(layer['js_hook'], 'return data;');

      if (!coreReady) {
        markTestSkipped('核心未启动（缺 sourin_core.dll），本组跳过');
        return;
      }

      const id = 'ui_js_src';
      final path = await SourinApi.saveOverrideLayer(layer);
      final onDisk = File(path).readAsStringSync();
      final dllKnowsJsHook = onDisk.contains('"js_hook"');

      // ② dll 侧：能力取证（这个读数本身就是要报出去的事实）
      // ignore: avoid_print
      print('OVERRIDE_UI|dll=${SourinCore.version}'
          '|knows_js_hook=$dllKnowsJsHook');

      if (!dllKnowsJsHook) {
        markTestSkipped(
          '★ 当前 sourin_core.dll（${SourinCore.version}）不认识 js_hook 字段'
          '（落盘 JSON 里没有该键）—— 该 dll 早于 overrides.rs 的 L3 阶段。'
          'UI 侧已断言 js_hook 一定被送出；往返断言待重新构建核心后再跑。',
        );
        await SourinApi.deleteOverrideLayer(id);
        return;
      }

      final got = await SourinApi.getOverrideLayer(id);
      expect(got, isNotNull);
      expect(got!['js_hook'], 'return data;',
          reason: '★ dll 认得 js_hook 却读不回原值 ⇒ 字段名或类型对不上');
      await SourinApi.deleteOverrideLayer(id);
    });
  });
}

// ═══════════════════════════════════════════════════════════════════════
//  工具：剥注释（与 zz_t66_r4_dialog_consistency_test 同一套规则）
// ═══════════════════════════════════════════════════════════════════════

/// 剥掉 `//` 行注释与 `/* */` 块注释，**不碰字符串字面量**
///
/// ★ 为什么必须剥：本文件（以及产品文件）里会**记录**改前写法，
///   不剥注释的话判据会对已经正确的文件报红，只能靠白名单消掉 ——
///   白名单一旦为了"修门禁"而加，门禁就失效了。
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
