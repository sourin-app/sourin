// ═══════════════════════════════════════════════════════════════════════
//  源个性化 · 覆盖层页签（L1 / L2 / L3）—— 编排器与独立弹窗**共用同一份**
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么把这块从 override_editor_dialog.dart 搬出来
// ```text
// Owner 原话（逐字）：
// > js插件也要支持,你想想方案吧,必须全部都可以,比如 只是链接,可以对数据
// > 二次编排修改,或者做劫持；js,可视化可自由编辑支持的,但不能影响原有插件本身,
// > 属于是个性化；声明式还是一样,不修改本身；可视化编排还是属于二次修改劫持的产物需求
// > 那个编排面板也要支持
//
// 改前是**两套互不相通**的界面：
//   source_composer_dialog.dart  声明式源的 JSON 编排（拼 endpoints / map）
//   override_editor_dialog.dart  L1 字段映射 / L2 数据变换 / L3 JS 片段
// 用户要"对数据二次编排"，得先知道该点哪个入口 —— 而两个入口都不提对方。
// ⇒ 把 L1/L2/L3 收成一个**可嵌入的页签**：
//   ① 独立弹窗（OverrideEditorDialog）= 本组件 + 玻璃外壳（行为一字不变）
//   ② 编排器（SourceComposerDialog）**同一个页签**，与源定义并排
//   两条路走的是**同一份状态机与同一份校验**，不可能漂移。
// ```
//
// # 它**不做**什么（这条比上面那条更重要）
// ```text
// ✗ 不解析插件、不跑 JS、不应用规则 —— 全部在 Rust 侧（rust/sourin_core/src/overrides.rs）
// ✗ 不改插件与声明式源文件 —— 只写 <数据目录>/overrides/<id>.json
// ✗ 不自己造数据模型 —— 字段名/取值域与 overrides.rs 的 serde 结构**逐字对齐**
// ```
//
// # 为什么字段名必须与 Rust 逐字对齐
// ```text
// Rust 侧是 `#[serde(tag = "op", rename_all = "snake_case")]` 的**内部标签枚举**：
//   {"op":"rename","from":..,"to":..,"keep":..}
//   {"op":"set","to":..,"value":..}
//   {"op":"copy","from":..,"to":..}
// 名字写错一个字母 ⇒ 序列化成功、反序列化失败 ⇒ 该源整层覆盖**静默不生效**
// （Rust 侧 Broken 分支只记日志、原样透出数据 —— 用户看到的是"设了没用"）。
// ⇒ 本文件里所有 op / 字段名都直接抄 overrides.rs 的枚举变体，不另起别名。
// ```
//
// # 三段式（与 Rust 的执行顺序一一对应）
// ```text
// L1 字段映射 mappings    逐条改字段：rename / set / copy
// L2 数据变换 transforms  改整个集合：过滤 / 排序 / 去重 / 截断 / 替换
// L3 JS 片段  js_hook     最后一道；只能操作 data，没有网络权限
// ⇒ 顺序是 L1 → L2 → L3，界面也按这个顺序排 —— 用户看到的顺序就是执行顺序。
// ```
//
// # 沙箱纪律（第 03 条硬约束，界面必须如实说）
// ```text
// L3 片段**没有**网络权限、**没有** host.store：不注入 fetch / XMLHttpRequest /
// host.store，且 2s 熔断由 Rust 侧保证。这句提示必须写在输入框上方，
// 不能只写在文档里 —— 用户对"能不能偷偷联网"是敏感的。
// ```

import 'package:material_ui/material_ui.dart';

import '../../core/ffi.dart' show userErrorText;
import '../../core/sourin_api.dart';
import '../../design/icons/app_icons.dart';
import '../../design/widgets/app_icon_button.dart';
import '../../design/widgets/app_switch.dart';
import '../../design/widgets/app_text_button.dart';
import '../tokens.dart';
import 'app_inline_spinner.dart';

// ═══════════════════════════════════════════════════════════════════════
//  取值域（与 overrides.rs 的枚举变体逐个对应）
// ═══════════════════════════════════════════════════════════════════════

/// L1 支持的三种动作 —— 顺序 = 界面上下拉框的顺序
const List<String> kMapOps = <String>['rename', 'set', 'copy'];

/// L1 三种动作的中文标签
///
/// ⚠️ 标签里**保留英文 op 名**：用户排查时能在 JSON 里对上号，
///    否则「改名」和 `rename` 是两套词，两边永远对不上。
const Map<String, String> kMapOpLabels = <String, String>{
  'rename': '改名 rename',
  'set': '常量覆盖 set',
  'copy': '路径取值 copy',
};

/// L2 支持的七种变换 —— 顺序 = 界面上下拉框的顺序
const List<String> kTransformOps = <String>[
  'filter_contains',
  'filter_not_contains',
  'filter_regex',
  'sort_by',
  'dedup_by',
  'take_first',
  'replace_in_field',
];

/// L2 七种变换的中文标签
const Map<String, String> kTransformOpLabels = <String, String>{
  'filter_contains': '保留包含 filter_contains',
  'filter_not_contains': '排除包含 filter_not_contains',
  'filter_regex': '正则保留 filter_regex',
  'sort_by': '按字段排序 sort_by',
  'dedup_by': '按字段去重 dedup_by',
  'take_first': '只留前 N 条 take_first',
  'replace_in_field': '字段内替换 replace_in_field',
};

// ═══════════════════════════════════════════════════════════════════════
//  纯函数：草稿校验
// ═══════════════════════════════════════════════════════════════════════

/// 校验一份**待保存**的草稿；返回 `null` = 可以保存，否则是一句给用户看的原因。
///
/// # 为什么抽成纯函数
/// ```text
/// ① 界面里那套「红字提示 + 不调保存」必须**可单独验证** —— 挂在树上测
///    只能证明"点了没保存"，证明不了"是因为这条原因没保存"。
/// ② 校验规则会被 UI 与将来的批量导入共用，两处各写一遍必然漂移
///    （本仓 `save_hook` 就有"两条路径发散"的实测教训）。
/// ```
///
/// # 为什么这些规则（每条都对着 Rust 侧的真实后果）
/// ```text
/// · 空字段名：Rust 侧 `obj.get("")` 恒为 None ⇒ 规则**静默不生效**，
///   用户以为设了，其实什么都没发生 ⇒ 必须在保存前拦住。
/// · rename 的 from == to：Rust 侧 `obj.insert(to, val)` 后 `from == to`
///   不删原键 ⇒ 等于什么都没做。放行只会让用户以为自己配好了。
/// · 非法正则：Rust 侧 `Regex::new` 失败 ⇒ 该条规则被跳过并记日志
///   ⇒ 同样是"设了没用"。正则在这里先编译一次，能当场报出来。
/// · take_first 的 limit 不是整数：serde 解析 `usize` 失败 ⇒ 整个覆盖层
///   变成 Broken ⇒ **原样透出**（连别的规则也一起失效）。这条最重。
/// ```
String? validateOverrideDraft({
  required List<Map<String, dynamic>> mappings,
  required List<Map<String, dynamic>> transforms,
}) {
  for (var i = 0; i < mappings.length; i++) {
    final m = mappings[i];
    final n = i + 1;
    final op = '${m['op'] ?? ''}';
    if (op == 'rename') {
      if (_blank(m['from'])) return '第 $n 条字段映射：源字段（from）不能为空';
      if (_blank(m['to'])) return '第 $n 条字段映射：目标字段（to）不能为空';
      if ('${m['from']}'.trim() == '${m['to']}'.trim()) {
        return '第 $n 条字段映射：源字段与目标字段相同，改名不会有任何效果';
      }
    } else if (op == 'set') {
      if (_blank(m['to'])) return '第 $n 条字段映射：目标字段（to）不能为空';
    } else if (op == 'copy') {
      if (_blank(m['from'])) return '第 $n 条字段映射：源路径（from）不能为空';
      if (_blank(m['to'])) return '第 $n 条字段映射：目标字段（to）不能为空';
    } else {
      return '第 $n 条字段映射：不认识的动作「$op」';
    }
  }

  for (var i = 0; i < transforms.length; i++) {
    final t = transforms[i];
    final n = i + 1;
    final op = '${t['op'] ?? ''}';
    if (op == 'filter_contains' || op == 'filter_not_contains') {
      if (_blank(t['field'])) return '第 $n 条数据变换：字段名不能为空';
      if (_blank(t['contains'])) return '第 $n 条数据变换：要匹配的文字不能为空';
    } else if (op == 'filter_regex') {
      if (_blank(t['field'])) return '第 $n 条数据变换：字段名不能为空';
      final pattern = '${t['pattern'] ?? ''}'.trim();
      if (pattern.isEmpty) return '第 $n 条数据变换：正则不能为空';
      try {
        RegExp(pattern);
      } catch (_) {
        // Rust 侧遇到非法正则会**跳过这一条**（只记日志）⇒ 用户看到的是
        // "规则配了却没生效"。所以这里当场拦住，把原因说清楚。
        return '第 $n 条数据变换：正则不合法（$pattern）';
      }
    } else if (op == 'sort_by' || op == 'dedup_by') {
      if (_blank(t['field'])) return '第 $n 条数据变换：字段名不能为空';
    } else if (op == 'take_first') {
      final limit = t['limit'];
      if (limit is! int) return '第 $n 条数据变换：数量必须是整数（0 表示全部清空）';
      if (limit < 0) return '第 $n 条数据变换：数量不能是负数';
    } else if (op == 'replace_in_field') {
      if (_blank(t['field'])) return '第 $n 条数据变换：字段名不能为空';
      // ⚠️ 只拦 from：`to` 允许为空串（那就是"把这段字删掉"，是合法用法，
      //    overrides.rs 的例子 `{"from":"【官方】","to":""}` 正是这个）。
      if (_blank(t['from'])) return '第 $n 条数据变换：要替换的文字不能为空';
    } else {
      return '第 $n 条数据变换：不认识的动作「$op」';
    }
  }

  return null;
}

bool _blank(Object? v) => v == null || '$v'.trim().isEmpty;

/// 拼出一份**完整**的覆盖层 JSON（字段与 `overrides.rs` 的 `OverrideLayer` 逐字对齐）
///
/// # 为什么抽成顶层纯函数（而不是留在 State 里）
/// ```text
/// ① 字段名对齐是**整条链最脆的地方**：Rust 侧 serde 认不出一个键就整层 Broken
///    （只记日志、原样透出 ⇒ 用户看到"设了没用"）。这条只能用**真核心往返**证明，
///    而真核心往返是普通 test（不是 testWidgets）—— 它拿不到 State 的私有方法。
/// ② UI 与"导入/预设"将来都要拼同一份结构，两处各写一遍必然漂移。
/// ```
/// ⚠️ `methods` / `note` 原样带回：编辑器没有它们的界面，但**不许清掉**
///    （用户只是改了个字段名，不该顺手丢掉方法白名单与备注）。
Map<String, dynamic> buildOverrideLayer({
  required String targetId,
  required bool enabled,
  required List<String> methods,
  required List<Map<String, dynamic>> mappings,
  required List<Map<String, dynamic>> transforms,
  required String jsHook,
  required String note,
}) {
  return <String, dynamic>{
    'target_id': targetId,
    'enabled': enabled,
    'methods': methods,
    'mappings': mappings,
    'transforms': transforms,
    'js_hook': jsHook,
    'note': note,
  };
}

// ═══════════════════════════════════════════════════════════════════════
//  行状态（控制器随行生灭 —— 用控制器而不是每次 build 重新解析字符串，
//  否则用户打字时每次 setState 都会把光标弹回行尾）
// ═══════════════════════════════════════════════════════════════════════

class _MapRow {
  _MapRow({this.op = 'rename'});

  String op;
  bool keep = false;
  final TextEditingController from = TextEditingController();
  final TextEditingController to = TextEditingController();
  final TextEditingController value = TextEditingController();

  void dispose() {
    from.dispose();
    to.dispose();
    value.dispose();
  }
}

class _TxRow {
  _TxRow({this.op = 'filter_contains'});

  String op;
  bool desc = false;
  final TextEditingController field = TextEditingController();
  final TextEditingController contains = TextEditingController();
  final TextEditingController pattern = TextEditingController();
  final TextEditingController limit = TextEditingController();
  final TextEditingController from = TextEditingController();
  final TextEditingController to = TextEditingController();

  void dispose() {
    field.dispose();
    contains.dispose();
    pattern.dispose();
    limit.dispose();
    from.dispose();
    to.dispose();
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  组件
// ═══════════════════════════════════════════════════════════════════════

/// 覆盖层编辑页签（L1 + L2 + L3 + 启用开关 + 恢复默认 + 保存）
///
/// # 两种宿主
/// ```text
/// ① OverrideEditorDialog（玻璃弹窗）：onSaved 里 pop(true) ⇒ 弹窗关掉
/// ② SourceComposerDialog（编排器页签）：onSaved 里只更新状态行 ⇒ 面板不关
/// ```
/// 两种宿主的**状态机、校验、JSON 拼装完全一样** —— 这正是本组件存在的理由。
///
/// ⚠️ 内容区自己带一层 `Material(type: MaterialType.transparency)` 吗？
///    **不带**：本组件既可能落在零 Material 的玻璃外壳里，也可能落在编排器
///    （外壳自带 Material）里。宿主要求谁提供宿主，就由谁在**外面**包一层，
///    见 `override_editor_dialog.dart` 与 `source_composer_dialog.dart`。
class ComposerOverridesTab extends StatefulWidget {
  const ComposerOverridesTab({
    super.key,
    required this.targetId,
    required this.sourceName,
    this.loadLayer,
    this.saveLayer,
    this.deleteLayer,
    this.onSaved,
    this.compact = false,
  });

  /// 绑定的源 id（插件 @id 或声明式源 id）—— 写进 `target_id`，也是文件名
  final String targetId;

  /// 源名（只用于界面显示，不参与任何逻辑）
  final String sourceName;

  /// ── 测试注入口（生产路径**永不为 null**）──────────────────────────
  ///
  /// 三个 FFI 边界函数可以替换，为的是在 `flutter test` 里不必起真核心也能
  /// 验证**界面逻辑**（加载回显 / 增删行 / 结构拼装 / 校验拦截 / 删除）。
  ///
  /// ⚠️ 被替换的**只有 FFI 边界**：状态机、校验、JSON 拼装、渲染全部真跑。
  ///    「桩掉被测逻辑」是被禁止的，这里桩的是文件/网络那一层。
  final Future<Map<String, dynamic>?> Function(String id)? loadLayer;
  final Future<String> Function(Map<String, dynamic> layer)? saveLayer;
  final Future<bool> Function(String id)? deleteLayer;

  /// 保存成功后的回调（宿主决定"关窗"还是"只提示"）
  final void Function()? onSaved;

  /// 嵌在编排器里时用：字号/间距略收，避免与外层面板抢视觉层级
  final bool compact;

  @override
  State<ComposerOverridesTab> createState() => ComposerOverridesTabState();
}

/// ⚠️ State 类型是**公开**的：编排器的「保存」按钮要能在页签外触发保存
///    （`GlobalKey<ComposerOverridesTabState>`），否则会出现两个保存按钮。
class ComposerOverridesTabState extends State<ComposerOverridesTab> {
  bool _loading = true;
  String? _loadError;
  String? _status;
  bool _statusIsError = false;
  bool _busy = false;
  bool _confirmRestore = false;

  bool _enabled = true;

  /// 方法白名单 —— 本编辑器**不编辑**它，但必须原样带回
  ///
  /// ```text
  /// 覆盖层 JSON 里 methods 是"只对这些方法生效"的白名单（空 = 全部）。
  /// 编辑器没有这条的界面（不在本次需求内），但**保存时不能把它清掉** ——
  /// 那等于用户只是改了个字段名，就把自己原来配的方法白名单悄悄丢了。
  /// ```
  List<String> _methods = const <String>[];

  /// 备注 —— 同上：不编辑，原样带回
  String _note = '';

  final List<_MapRow> _maps = <_MapRow>[];
  final List<_TxRow> _txs = <_TxRow>[];
  final TextEditingController _jsCtrl = TextEditingController();

  /// 宿主（编排器）可读：现在有没有东西可保存
  bool get canSave =>
      _maps.isNotEmpty || _txs.isNotEmpty || _jsCtrl.text.trim().isNotEmpty;
  bool get busy => _busy;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final r in _maps) {
      r.dispose();
    }
    for (final r in _txs) {
      r.dispose();
    }
    _jsCtrl.dispose();
    super.dispose();
  }

  // ── 读 ────────────────────────────────────────────────────────────

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final loader = widget.loadLayer ?? SourinApi.getOverrideLayer;
      final layer = await loader(widget.targetId);
      if (!mounted) return;
      setState(() {
        _applyLayer(layer);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // ★ 用户可见文案走唯一入口（不许 `'$e'` —— 那会把宿主类名塞给用户，
        //   门禁见 test/zz_t66_user_error_text_gate_test.dart）
        _loadError = userErrorText(e, fallback: '读取覆盖层失败，请稍后重试');
        _loading = false;
      });
    }
  }

  /// 把一份 JSON 灌进表单；`null` ⇒ 清空成"未个性化"的初始态
  void _applyLayer(Map<String, dynamic>? layer) {
    for (final r in _maps) {
      r.dispose();
    }
    _maps.clear();
    for (final r in _txs) {
      r.dispose();
    }
    _txs.clear();
    _jsCtrl.text = '';
    _enabled = true;
    _methods = const <String>[];
    _note = '';
    // 重新加载 ⇒ 上一次的提示/确认态不该留着（否则用户会看到一条
    // 与当前数据无关的红字，或一个"确认恢复"按钮莫名其妙已经展开）
    _status = null;
    _statusIsError = false;
    _confirmRestore = false;

    if (layer == null) return;

    _enabled = layer['enabled'] is bool ? layer['enabled'] as bool : true;
    final methods = layer['methods'];
    if (methods is List) {
      _methods = <String>[
        for (final m in methods)
          if (m != null) '$m',
      ];
    }
    if (layer['note'] != null) _note = '${layer['note']}';

    final mappings = layer['mappings'];
    if (mappings is List) {
      for (final raw in mappings) {
        if (raw is! Map) continue;
        final op = '${raw['op'] ?? ''}';
        // 不认识的 op 不画（Rust 侧也只认这几种）—— 但**不静默吞掉**：
        // 这种情况下保存会把它丢掉，所以状态行要如实说一句。
        if (!kMapOps.contains(op)) {
          _status = '有一条第 L1 规则的动作不认识（$op），已跳过，保存会丢掉它';
          _statusIsError = true;
          continue;
        }
        final row = _MapRow(op: op);
        row.from.text = '${raw['from'] ?? ''}';
        row.to.text = '${raw['to'] ?? ''}';
        final v = raw['value'];
        row.value.text = v == null ? '' : '$v';
        row.keep = raw['keep'] == true;
        _maps.add(row);
      }
    }

    final transforms = layer['transforms'];
    if (transforms is List) {
      for (final raw in transforms) {
        if (raw is! Map) continue;
        final op = '${raw['op'] ?? ''}';
        if (!kTransformOps.contains(op)) {
          _status = '有一条第 L2 规则的动作不认识（$op），已跳过，保存会丢掉它';
          _statusIsError = true;
          continue;
        }
        final row = _TxRow(op: op);
        row.field.text = '${raw['field'] ?? ''}';
        row.contains.text = '${raw['contains'] ?? ''}';
        row.pattern.text = '${raw['pattern'] ?? ''}';
        final limit = raw['limit'];
        row.limit.text = limit == null ? '' : '$limit';
        row.from.text = '${raw['from'] ?? ''}';
        row.to.text = '${raw['to'] ?? ''}';
        row.desc = raw['desc'] == true;
        _txs.add(row);
      }
    }

    final js = layer['js_hook'];
    if (js != null) _jsCtrl.text = '$js';
  }

  // ── 拼装 ──────────────────────────────────────────────────────────

  List<Map<String, dynamic>> _buildMappings() {
    final out = <Map<String, dynamic>>[];
    for (final r in _maps) {
      if (r.op == 'rename') {
        out.add(<String, dynamic>{
          'op': 'rename',
          'from': r.from.text.trim(),
          'to': r.to.text.trim(),
          'keep': r.keep,
        });
      } else if (r.op == 'set') {
        out.add(<String, dynamic>{
          'op': 'set',
          'to': r.to.text.trim(),
          // ⚠️ value 不 trim：常量可能就是"一个空格"或者前后有意留白
          'value': r.value.text,
        });
      } else if (r.op == 'copy') {
        out.add(<String, dynamic>{
          'op': 'copy',
          'from': r.from.text.trim(),
          'to': r.to.text.trim(),
        });
      }
    }
    return out;
  }

  List<Map<String, dynamic>> _buildTransforms() {
    final out = <Map<String, dynamic>>[];
    for (final r in _txs) {
      if (r.op == 'filter_contains') {
        out.add(<String, dynamic>{
          'op': 'filter_contains',
          'field': r.field.text.trim(),
          'contains': r.contains.text,
        });
      } else if (r.op == 'filter_not_contains') {
        out.add(<String, dynamic>{
          'op': 'filter_not_contains',
          'field': r.field.text.trim(),
          'contains': r.contains.text,
        });
      } else if (r.op == 'filter_regex') {
        out.add(<String, dynamic>{
          'op': 'filter_regex',
          'field': r.field.text.trim(),
          'pattern': r.pattern.text.trim(),
        });
      } else if (r.op == 'sort_by') {
        out.add(<String, dynamic>{
          'op': 'sort_by',
          'field': r.field.text.trim(),
          'desc': r.desc,
        });
      } else if (r.op == 'dedup_by') {
        out.add(<String, dynamic>{
          'op': 'dedup_by',
          'field': r.field.text.trim(),
        });
      } else if (r.op == 'take_first') {
        out.add(<String, dynamic>{
          'op': 'take_first',
          // null ⇒ 校验会拦（不是 0）—— 0 是合法值（清空整个列表）
          'limit': int.tryParse(r.limit.text.trim()),
        });
      } else if (r.op == 'replace_in_field') {
        out.add(<String, dynamic>{
          'op': 'replace_in_field',
          'field': r.field.text.trim(),
          'from': r.from.text,
          'to': r.to.text,
        });
      }
    }
    return out;
  }

  Map<String, dynamic> _buildLayer(
    List<Map<String, dynamic>> mappings,
    List<Map<String, dynamic>> transforms,
  ) {
    return buildOverrideLayer(
      targetId: widget.targetId,
      enabled: _enabled,
      methods: _methods,
      mappings: mappings,
      transforms: transforms,
      jsHook: _jsCtrl.text,
      note: _note,
    );
  }

  // ── 写 ────────────────────────────────────────────────────────────

  /// 保存（宿主也可以在页签外调这个 —— 见 [ComposerOverridesTabState] 的注释）
  Future<void> save() async {
    final mappings = _buildMappings();
    final transforms = _buildTransforms();
    final problem = validateOverrideDraft(
      mappings: mappings,
      transforms: transforms,
    );
    if (problem != null) {
      setState(() {
        _status = problem;
        _statusIsError = true;
      });
      return;
    }

    setState(() {
      _busy = true;
      _status = null;
      _statusIsError = false;
    });
    try {
      final saver = widget.saveLayer ?? SourinApi.saveOverrideLayer;
      await saver(_buildLayer(mappings, transforms));
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '已保存到 overrides/${widget.targetId}.json'
            '（只写覆盖层，原插件/原声明式源未改动）';
        _statusIsError = false;
      });
      widget.onSaved?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = userErrorText(e, fallback: '保存覆盖层失败，请稍后重试');
        _statusIsError = true;
      });
    }
  }

  Future<void> _restoreDefault() async {
    setState(() {
      _busy = true;
      _confirmRestore = false;
      _status = null;
      _statusIsError = false;
    });
    try {
      final deleter = widget.deleteLayer ?? SourinApi.deleteOverrideLayer;
      final existed = await deleter(widget.targetId);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _applyLayer(null);
        _statusIsError = false;
        _status = existed
            ? '已恢复默认：覆盖层文件已删除，原插件行为完全恢复'
            : '本来就没有覆盖层，当前就是原插件行为';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = userErrorText(e, fallback: '删除覆盖层失败，请稍后重试');
        _statusIsError = true;
      });
    }
  }

  void _addMap() {
    setState(() {
      _maps.add(_MapRow());
      _status = null;
    });
  }

  void _removeMap(int i) {
    setState(() {
      _maps.removeAt(i).dispose();
      _status = null;
    });
  }

  void _addTx() {
    setState(() {
      _txs.add(_TxRow());
      _status = null;
    });
  }

  void _removeTx(int i) {
    setState(() {
      _txs.removeAt(i).dispose();
      _status = null;
    });
  }

  // ── 画 ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return _content(context);
  }

  Widget _content(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          '源：${widget.sourceName}',
          key: const ValueKey<String>('ov-source-name'),
          textAlign: TextAlign.left,
          style: TextStyle(
            fontSize: FontSizes.sm,
            fontWeight: FontWeight.w600,
            color: cs.onSurface,
          ),
        ),
        const SizedBox(height: Sp.x1),
        Text(
          '绑定 id：${widget.targetId}',
          textAlign: TextAlign.left,
          style: TextStyle(
            fontSize: FontSizes.cap,
            color: cs.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: Sp.x3),
        _safetyCard(cs),
        const SizedBox(height: Sp.x3),
        _enableRow(cs),
        if (_loading) ...<Widget>[
          const SizedBox(height: Sp.x4),
          Row(
            children: <Widget>[
              AppInlineSpinner(size: 14, color: cs.onSurfaceVariant),
              const SizedBox(width: Sp.x2),
              Text(
                '正在读取覆盖层…',
                textAlign: TextAlign.left,
                style: TextStyle(
                  fontSize: FontSizes.cap,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ] else if (_loadError != null) ...<Widget>[
          const SizedBox(height: Sp.x3),
          Text(
            _loadError!,
            key: const ValueKey<String>('ov-load-error'),
            textAlign: TextAlign.left,
            style: TextStyle(fontSize: FontSizes.cap, color: cs.error),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: AppTextButton(
              key: const ValueKey<String>('ov-reload'),
              onPressed: _busy ? null : _load,
              child: const Text('重试'),
            ),
          ),
        ] else ...<Widget>[
          const SizedBox(height: Sp.x4),
          _section(
            cs,
            'L1 · 字段映射',
            '按顺序逐条改字段：改名 / 覆盖成常量 / 从别的路径取值。'
            '作用在列表里的每一条，也作用在详情页那一个对象上。',
          ),
          for (var i = 0; i < _maps.length; i++) _mapCard(cs, i, _maps[i]),
          Align(
            alignment: Alignment.centerLeft,
            child: AppTextButton(
              key: const ValueKey<String>('ov-map-add'),
              onPressed: _busy ? null : _addMap,
              child: const Text('＋ 添加字段映射'),
            ),
          ),
          const SizedBox(height: Sp.x3),
          _section(
            cs,
            'L2 · 数据变换',
            '在 L1 之后对整个列表做过滤 / 排序 / 去重 / 截断 / 替换。'
            '顺序就是执行顺序。',
          ),
          for (var i = 0; i < _txs.length; i++) _txCard(cs, i, _txs[i]),
          Align(
            alignment: Alignment.centerLeft,
            child: AppTextButton(
              key: const ValueKey<String>('ov-tx-add'),
              onPressed: _busy ? null : _addTx,
              child: const Text('＋ 添加数据变换'),
            ),
          ),
          const SizedBox(height: Sp.x3),
          _section(
            cs,
            'L3 · JS 片段（可选）',
            // ★ 这句是需求里点名要的提示，逐字保留
            '只能操作 data 变量，没有网络权限：不能发请求、不能读文件、'
            '不能访问 host.store。片段是语句体，return 的值就是最终数据；'
            '不 return（或返回 undefined）视为不改。',
          ),
          const SizedBox(height: Sp.x2),
          TextField(
            key: const ValueKey<String>('ov-js-hook'),
            controller: _jsCtrl,
            // ★ 机制⑤：玻璃外壳内容区 DefaultTextStyle 是 center，
            //   多行框必须显式左对齐，否则用户写 JS 时每行都在中间
            textAlign: TextAlign.left,
            minLines: 3,
            maxLines: 8,
            style: TextStyle(
              fontSize: FontSizes.cap,
              height: 1.4,
              color: cs.onSurface,
            ),
            decoration: InputDecoration(
              isDense: true,
              hintText: '例如：\n// return data.filter(x => x.title.includes("番剧"));',
              hintStyle: TextStyle(
                fontSize: FontSizes.cap,
                color: cs.onSurfaceVariant,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: Sp.x3,
                vertical: Sp.x2,
              ),
              border: OutlineInputBorder(
                borderRadius: Radii.rSm,
                borderSide: BorderSide(color: cs.outlineVariant),
              ),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
        if (_status != null) ...<Widget>[
          const SizedBox(height: Sp.x3),
          Text(
            _status!,
            key: const ValueKey<String>('ov-status'),
            textAlign: TextAlign.left,
            style: TextStyle(
              fontSize: FontSizes.cap,
              height: 1.4,
              color: _statusIsError ? cs.error : cs.primary,
            ),
          ),
        ],
        /*
         * ★ 保存按钮放在**页签内容底部**（不是弹窗外壳的 actions）。
         *
         * # 为什么必须这样（不是为了好看）
         * ```text
         * 本组件有两个宿主：玻璃弹窗（外壳 actions 在弹窗外）与编排器页签
         * （外壳 actions 属于"保存声明式源"，语义完全不同）。
         * 若保存按钮挂在弹窗 actions 上，它就得靠外部知道本组件的 _canSave ——
         * 那是把状态机拆成两半，两侧必然漂移（本仓 save_hook 的实测教训）。
         * ⇒ 按钮跟着状态机走，状态机在哪个组件，按钮就在哪个组件。
         * ```
         */
        const SizedBox(height: Sp.x3),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            AppTextButton(
              key: const ValueKey<String>('ov-save'),
              onPressed: (canSave && !_busy && !_loading) ? save : null,
              foregroundColor: cs.primary,
              child: const Text('保存覆盖层'),
            ),
          ],
        ),
      ],
    );
  }

  /// 安全提示卡 —— 用户按下任何按钮**之前**就该读到的那句话
  Widget _safetyCard(ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.all(Sp.x3),
      decoration: BoxDecoration(
        borderRadius: Radii.rSm,
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(AppIcons.info_outline, size: 16, color: cs.primary),
              const SizedBox(width: Sp.x2),
              Expanded(
                child: Text(
                  '覆盖层不改原插件',
                  key: const ValueKey<String>('ov-safety-title'),
                  textAlign: TextAlign.left,
                  style: TextStyle(
                    fontSize: FontSizes.sm,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Sp.x2),
          Text(
            '它只写 <数据目录>/overrides/<源 id>.json，插件与声明式源文件一个字节都不动。'
            '删除即完全恢复：点下面的「恢复默认」删掉这层文件，行为立刻回到原插件。',
            key: const ValueKey<String>('ov-safety-body'),
            textAlign: TextAlign.left,
            style: TextStyle(
              fontSize: FontSizes.cap,
              height: 1.45,
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Sp.x2),
          if (!_confirmRestore)
            Align(
              alignment: Alignment.centerLeft,
              child: AppTextButton(
                key: const ValueKey<String>('ov-restore'),
                onPressed:
                    _busy ? null : () => setState(() => _confirmRestore = true),
                foregroundColor: cs.error,
                child: const Text('恢复默认'),
              ),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '确定删除这层覆盖层？删除后这个源立刻回到原插件行为。',
                  key: const ValueKey<String>('ov-restore-confirm-text'),
                  textAlign: TextAlign.left,
                  style: TextStyle(fontSize: FontSizes.cap, color: cs.onSurface),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    AppTextButton(
                      key: const ValueKey<String>('ov-restore-confirm'),
                      onPressed: _busy ? null : _restoreDefault,
                      foregroundColor: cs.error,
                      child: const Text('确认恢复'),
                    ),
                    const SizedBox(width: Sp.x1),
                    AppTextButton(
                      key: const ValueKey<String>('ov-restore-cancel'),
                      onPressed: _busy
                          ? null
                          : () => setState(() => _confirmRestore = false),
                      child: const Text('取消'),
                    ),
                  ],
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _enableRow(ColorScheme cs) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            '启用这层覆盖（关掉 = 完全不生效，但文件保留）',
            textAlign: TextAlign.left,
            style: TextStyle(fontSize: FontSizes.cap, color: cs.onSurfaceVariant),
          ),
        ),
        const SizedBox(width: Sp.x2),
        AppSwitch(
          key: const ValueKey<String>('ov-enabled'),
          value: _enabled,
          onChanged: _busy ? null : (v) => setState(() => _enabled = v),
        ),
      ],
    );
  }

  Widget _section(ColorScheme cs, String title, String hint) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          title,
          textAlign: TextAlign.left,
          style: TextStyle(
            fontSize: FontSizes.sm,
            fontWeight: FontWeight.w600,
            color: cs.onSurface,
          ),
        ),
        const SizedBox(height: Sp.x1),
        Text(
          hint,
          textAlign: TextAlign.left,
          style: TextStyle(
            fontSize: FontSizes.cap,
            height: 1.4,
            color: cs.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _card(ColorScheme cs, List<Widget> children) {
    return Container(
      margin: const EdgeInsets.only(top: Sp.x2),
      padding: const EdgeInsets.all(Sp.x3),
      decoration: BoxDecoration(
        borderRadius: Radii.rSm,
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  Widget _field(
    ColorScheme cs,
    String label,
    TextEditingController c,
    String keyName, {
    String? hint,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: Sp.x2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            label,
            textAlign: TextAlign.left,
            style: TextStyle(fontSize: FontSizes.cap, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 2),
          TextField(
            key: ValueKey<String>(keyName),
            controller: c,
            textAlign: TextAlign.left,
            style: TextStyle(fontSize: FontSizes.sm, color: cs.onSurface),
            decoration: InputDecoration(
              isDense: true,
              hintText: hint,
              hintStyle: TextStyle(
                fontSize: FontSizes.cap,
                color: cs.onSurfaceVariant,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: Sp.x2,
                vertical: Sp.x2,
              ),
              border: OutlineInputBorder(
                borderRadius: Radii.rSm,
                borderSide: BorderSide(color: cs.outlineVariant),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _boolRow(
    ColorScheme cs,
    String label,
    bool value,
    String keyName,
    ValueChanged<bool> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.only(top: Sp.x2),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              textAlign: TextAlign.left,
              style: TextStyle(fontSize: FontSizes.cap, color: cs.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: Sp.x2),
          AppSwitch(
            key: ValueKey<String>(keyName),
            value: value,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _opDropdown(
    ColorScheme cs,
    String keyName,
    String value,
    List<String> ops,
    Map<String, String> labels,
    ValueChanged<String> onChanged,
  ) {
    return DropdownButton<String>(
      key: ValueKey<String>(keyName),
      value: value,
      isExpanded: true,
      isDense: true,
      underline: const SizedBox.shrink(),
      dropdownColor: cs.surfaceContainerHighest,
      borderRadius: Radii.rSm,
      icon: Icon(AppIcons.arrow_drop_down, size: 20, color: cs.onSurfaceVariant),
      style: TextStyle(fontSize: FontSizes.sm, color: cs.onSurface),
      items: <DropdownMenuItem<String>>[
        for (final op in ops)
          DropdownMenuItem<String>(value: op, child: Text(labels[op] ?? op)),
      ],
      onChanged: _busy
          ? null
          : (v) {
              if (v != null) onChanged(v);
            },
    );
  }

  Widget _mapCard(ColorScheme cs, int i, _MapRow r) {
    return _card(cs, <Widget>[
      Row(
        children: <Widget>[
          Expanded(
            child: _opDropdown(
              cs,
              'ov-map-$i-op',
              r.op,
              kMapOps,
              kMapOpLabels,
              (v) => setState(() => r.op = v),
            ),
          ),
          AppIconButton(
            key: ValueKey<String>('ov-map-$i-del'),
            icon: const Icon(AppIcons.delete_outline),
            iconSize: 18,
            tooltip: '删除这条字段映射',
            onPressed: _busy ? null : () => _removeMap(i),
          ),
        ],
      ),
      if (r.op == 'rename' || r.op == 'copy')
        _field(
          cs,
          r.op == 'copy' ? '源路径 from（支持点号，如 pager.total）' : '源字段 from（如 title）',
          r.from,
          'ov-map-$i-from',
          hint: r.op == 'copy' ? 'pager.total' : 'title',
        ),
      if (r.op == 'set')
        _field(cs, '目标字段 to（如 subtitle）', r.to, 'ov-map-$i-to', hint: 'subtitle'),
      if (r.op == 'rename' || r.op == 'copy')
        _field(cs, '目标字段 to', r.to, 'ov-map-$i-to', hint: 'name'),
      if (r.op == 'set')
        _field(cs, '常量值 value', r.value, 'ov-map-$i-value', hint: '写什么就变成什么'),
      if (r.op == 'rename')
        _boolRow(
          cs,
          '保留原字段（keep = true 时 from 也留着）',
          r.keep,
          'ov-map-$i-keep',
          (v) => setState(() => r.keep = v),
        ),
    ]);
  }

  Widget _txCard(ColorScheme cs, int i, _TxRow r) {
    return _card(cs, <Widget>[
      Row(
        children: <Widget>[
          Expanded(
            child: _opDropdown(
              cs,
              'ov-tx-$i-op',
              r.op,
              kTransformOps,
              kTransformOpLabels,
              (v) => setState(() => r.op = v),
            ),
          ),
          AppIconButton(
            key: ValueKey<String>('ov-tx-$i-del'),
            icon: const Icon(AppIcons.delete_outline),
            iconSize: 18,
            tooltip: '删除这条数据变换',
            onPressed: _busy ? null : () => _removeTx(i),
          ),
        ],
      ),
      if (r.op == 'filter_contains' || r.op == 'filter_not_contains') ...<Widget>[
        _field(cs, '字段名 field（如 title）', r.field, 'ov-tx-$i-field', hint: 'title'),
        _field(
          cs,
          '包含的文字 contains',
          r.contains,
          'ov-tx-$i-contains',
          hint: r.op == 'filter_contains' ? '番剧' : '预告',
        ),
      ],
      if (r.op == 'filter_regex') ...<Widget>[
        _field(cs, '字段名 field', r.field, 'ov-tx-$i-field', hint: 'title'),
        _field(cs, '正则 pattern', r.pattern, 'ov-tx-$i-pattern', hint: r'^EP\d+$'),
      ],
      if (r.op == 'sort_by') ...<Widget>[
        _field(cs, '字段名 field（如 n）', r.field, 'ov-tx-$i-field', hint: 'n'),
        _boolRow(
          cs,
          '降序（desc）',
          r.desc,
          'ov-tx-$i-desc',
          (v) => setState(() => r.desc = v),
        ),
      ],
      if (r.op == 'dedup_by')
        _field(cs, '字段名 field（如 id）', r.field, 'ov-tx-$i-field', hint: 'id'),
      if (r.op == 'take_first')
        _field(
          cs,
          '只留前 N 条 limit（0 = 全部清空）',
          r.limit,
          'ov-tx-$i-limit',
          hint: '20',
        ),
      if (r.op == 'replace_in_field') ...<Widget>[
        _field(cs, '字段名 field（如 title）', r.field, 'ov-tx-$i-field', hint: 'title'),
        _field(cs, '要替换的文字 from', r.from, 'ov-tx-$i-from', hint: '【官方】'),
        _field(
          cs,
          '替换成 to（留空 = 直接删掉这段字）',
          r.to,
          'ov-tx-$i-to',
          hint: '留空即可删除',
        ),
      ],
    ]);
  }
}
