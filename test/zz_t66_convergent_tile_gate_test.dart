// ═══════════════════════════════════════════════════════════════════════
//  T66 · ListTile 祖先门禁 v3 —— **收敛式**符号解析
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么还要 v3（v2 = zz_t64_listtile_ancestor_gate_test.dart 仍然保留并在跑）
//
// v2 的判据是：wrapper 的 `child:` 表达式里**直接**出现 tile 家族，
// 或者**引用了一个「函数体里直接含 tile」的符号**（一层污染集）。
//
// 它有两个盲区，我都实际踩到了：
// ```text
// ① 形参传递：
//      Widget _card({required List<Widget> children}) => Material(child: Column(children: children));
//      ... _card(children: [CheckboxListTile(...)])
//    ⇒ _card 体里没有 tile 字面量 ⇒ v2 判它干净。
//      实际 :482 有 CheckboxListTile（source_composer_dialog）。
//
// ② 多跳调用：
//      Material(child: ... _switchSection() ...)
//        _switchSection() → _switchRow() → SwitchListTile
//    ⇒ 两跳以上，v2 的一层污染集追不到。
//      实际 danmaku_settings_dialog 就是这条路径（我上一轮判错过一次）。
// ```
//
// # 本门禁怎么解
// ```text
// · 从 wrapper 的 child 表达式出发，收集其中的符号
// · 对每个符号**递归**进它的定义体（同文件优先，再全仓）
// · 记已访问集合防环；深度上限 6、符号上限 200
// · 路径上出现 tile 家族 ⇒ 报警（并打印完整跳数路径）
// · ★ **追不到定义 ⇒ 必须打印「未判定」**，绝不静默当成干净
// · ★ 形参：若 wrapper 是**方法**且 tile 可能在调用方实参里，
//      反向找它的调用点，把实参也纳入检查
// ```
//
// # 为什么会「追到收敛」而不是「追几层」
// ```text
// 实测：_group → _switchSection → _switchRow → SwitchListTile 是**三跳**。
// 我按「两跳」写过一版，当场漏掉 danmaku 那一处。
// ⇒ 固定深度必然要么漏、要么浪费；收敛（追到解析不出新符号）才是对的。
// ```

// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// ListTile 家族 —— 这些控件**要求** Material 祖先（画底色/水波）
///
/// 判据来源：Flutter 的 `ListTile` 在 build 里断言「最近的 Material 不是
/// 一个带底色的中间层」，否则报
/// `ListTile background color or ink splashes may be invisible.`
const _tiles = <String>[
  'ListTile',
  'CheckboxListTile',
  'SwitchListTile',
  'RadioListTile',
  'ExpansionTile',
];

/// 会「盖住」ListTile 的中间层类型
const _wrappers = <String>[
  'AppSurface(',
  'DecoratedBox(',
  'Material(',
  // ★ 从 v2 移植：ColoredBox 也是带底色的中间层，
  //   Flutter 的 _findIntermediateWidget 一样会因它挡住 ListTile 而断言。
  //   实测仓库里 ColoredBox( 出现 85 次。
  'ColoredBox(',
];

/// 剥注释 —— 注释里的举例不是代码
///
/// ★ **保留换行**（把注释替换成等量换行，而不是删掉）：
/// 这样剥离后的行号 == 原文行号。
///
/// # 为什么必须这样
/// ```text
/// 白名单按「文件:行号」记豁免。若剥离时把注释整体删掉，行号会往前漂，
/// 实测 player_settings_sheet 的真实行是 776，剥离后算成 680/697 ——
/// 差 96 行。白名单用它 ⇒ 永远匹配不上 ⇒ 豁免形同虚设。
/// ```
String _strip(String s) {
  // 块注释 → 等量换行（保留行数）
  final noBlock = s.replaceAllMapped(
    RegExp(r'/\*.*?\*/', dotAll: true),
    (m) => '\n' * (m.group(0)!.split('\n').length - 1),
  );
  // 行注释 → 留空行（保留行数）
  return noBlock.replaceAll(RegExp(r'//[^\n]*'), '');
}

/// 括号配平。**必须跳过字符串字面量里的括号**。
///
/// ⚠️ 第一版没跳，实测 player_page 某个 ColoredBox 的块被撑到 3357 字符 ——
///    因为块内有 ')' 这样的字符串，配平提前/延后，把后面几百行都吃进来了。
String _block(String s, int start) {
  var d = 0;
  var seen = false;
  var i = start;
  while (i < s.length) {
    final c = s[i];
    // 跳过字符串字面量（单引号 / 双引号，含三引号块）
    if (c == "'" || c == '"') {
      final triple = s.startsWith(c * 3, i);
      final quote = triple ? c * 3 : c;
      var j = i + quote.length;
      while (j < s.length) {
        // 用 codeUnit 判断反斜杠：raw string 里 r + 两个反斜杠 = 两个字符，永远不等单个
        if (s.codeUnitAt(j) == 92) {
          j += 2;
          continue;
        }
        if (s.startsWith(quote, j)) {
          j += quote.length;
          break;
        }
        j++;
      }
      i = j;
      continue;
    }
    if (c == '(') {
      d++;
      seen = true;
    } else if (c == ')') {
      d--;
      if (seen && d == 0) return s.substring(start, i + 1);
    }
    i++;
  }
  return s.substring(start);
}

/// 这个 wrapper 是否真有"会盖住 ListTile"的背景色
///
/// 对齐 Flutter 判据（list_tile.dart:_findIntermediateWidget）：
///   ColoredBox 看 color；DecoratedBox 看 decoration 里的 color
///   且 alpha 必须 > 0
bool _hasOpaqueBackground(String blk, String wrapper) {
  // ⚠️ 注意：blk 是从 wrapper 的 "(" **之后**开始截的，
  //    所以块内**不含**组件名。组件名必须由调用方传进来。
  //    （第一版靠 blk.contains('AppSurface(') 判定，永远 false ⇒ 假绿）
  if (wrapper.startsWith('DecoratedBox')) {
    final dm = RegExp(r'decoration\s*:\s*BoxDecoration\(').firstMatch(blk);
    if (dm == null) return false;
    final seg = blk.substring(dm.end, (dm.end + 260).clamp(0, blk.length));
    final cm = RegExp(r'(?:^|[,{(\s])color\s*:\s*([^,\n]+)').firstMatch(seg);
    if (cm == null) return false;
    return !_isTransparent(cm.group(1)!);
  }
  /*
   * ★ `Material` 特例：**没有 color 参数 ⇒ 仍然算「有绘制面」**
   *
   * # 为什么这里不能沿用 v2 的 `cm == null ⇒ return false`
   * ```text
   * v2 只扫 AppSurface/DecoratedBox/ColoredBox —— 这三者都必须显式给色，
   * 「没给色」等价于「没底色」⇒ 放过是**对的**。
   *
   * 但 `Material` 不一样：
   *     Material(type: MaterialType.transparency, child: SwitchListTile(...))
   * 它**没有 color 参数**，可它**仍然是一个 Material 面** ——
   * ListTile 的水波就画在它身上，删了照样断言。
   * 实例：lib/ui/settings/emby_page.dart:985（代码注释自己就写着
   *      「必须自己包一层透明 Material，否则 flutter 断言」）。
   *
   * ⇒ 移植 v2 判据时如果照抄 `cm == null ⇒ false`，
   *    会把 emby:985 这类**真实必须留**的 Material 误放行。
   *    我实测撞到过：移植后命中数 11→26，但 emby:985 **消失了**。
   * ```
   */
  if (wrapper.startsWith('Material')) {
    // Material 只要存在就是一个绘制面；color 只影响它是**不透明**还是**透明**，
    // 而两种都能承接 ListTile 的水波。
    return true;
  }

  // ColoredBox 与 AppSurface：直接取 color 参数
  final cm = RegExp(r'color\s*:\s*([^,\n]+)').firstMatch(blk);
  if (cm == null) return false;
  return !_isTransparent(cm.group(1)!);
}

/// 粗略判断颜色表达式是否透明
bool _isTransparent(String expr) {
  final e = expr.trim();
  if (e.contains('Colors.transparent')) return true;
  final am = RegExp(r'withValues\s*\(\s*alpha\s*:\s*([0-9.]+)').firstMatch(e);
  if (am != null) {
    final a = double.tryParse(am.group(1)!) ?? 1;
    return a <= 0;
  }
  final wm = RegExp(r'withOpacity\s*\(\s*([0-9.]+)').firstMatch(e);
  if (wm != null) {
    final a = double.tryParse(wm.group(1)!) ?? 1;
    return a <= 0;
  }
  // 0x00RRGGBB
  final hm = RegExp(r'0x([0-9A-Fa-f]{8})').firstMatch(e);
  if (hm != null) {
    return hm.group(1)!.substring(0, 2) == '00';
  }
  return false;
}

/// 取顶层 `child:` 之后、同层逗号之前的表达式
String _childExpr(String blk) {
  final m = RegExp(r'child\s*:').firstMatch(blk);
  if (m == null) return '';
  final st = m.end;
  var d = 0;
  for (var i = st; i < blk.length; i++) {
    final c = blk[i];
    if (c == '(' || c == '[' || c == '{') d++;
    if (c == ')' || c == ']' || c == '}') {
      // 走到 blk 自己的收尾时停下（d 会变负）
      if (d == 0) return blk.substring(st, i);
      d--;
    }
    if (c == ',' && d == 0) return blk.substring(st, i);
  }
  return blk.substring(st);
}

/// `child:` 之后表达式在 [blk] 里的起始偏移（取不到 ⇒ -1）
int _childStart(String blk) {
  final m = RegExp(r'child\s*:').firstMatch(blk);
  return m == null ? -1 : m.end;
}

/// ★ 形态校验：「换一种写法也能过」不算命中 —— 必须真有一层 `Material(` 承接
///
/// # 为什么光有「文件:行号」不够（2026-10-20 故障注入暴露的盲区）
/// ```text
/// 判据原来只问「这个位置是不是有底色 wrapper 且子树里有 tile」。
/// 把白名单那处 984 的 `Material(type: transparency)` 换成**不透明**
/// ColoredBox（运行期必抛 "ink splashes may be invisible"）⇒ 门禁 EXIT=0。
/// ⇒ 违例出现在已豁免的行号上时看不见：白名单条目里的理由只是文档，
///   不是被机器验证的约束。
/// ```
///
/// 现在的判据（对齐 Flutter 的 `_findIntermediateWidget`）：
///   tile（或它的调用点）必须被 wrapper 块内的**一层 `Material(` 的括号范围**
///   包住；或者 wrapper 本身就是 `Material(`。否则记入 formBad ⇒ **红**，
///   白名单也压不住。
String? _shapeProblem(String blk, String wrapper, Iterable<int> probes) {
  final ps = probes.where((p) => p >= 0).toList();
  if (ps.isEmpty) return null;
  if (wrapper.startsWith('Material')) return null;
  final spans = <List<int>>[];
  var i = 0;
  while (true) {
    i = blk.indexOf('Material(', i);
    if (i < 0) break;
    spans.add(<int>[i, i + 8 + _block(blk, i + 8).length]);
    i += 8;
  }
  for (final p in ps) {
    if (!spans.any((s) => p >= s[0] && p < s[1])) {
      return '不在 wrapper 块内的 Material( 之下（wrapper=' +
          wrapper.replaceAll('(', '') +
          '，块内 Material( ' +
          spans.length.toString() +
          ' 个）';
    }
  }
  return null;
}

/// 「未判定」的自动初判（三处人工核对见 docs/notes/round-66-n15.md §11）
String _unknownKind(String src, int idx, String name) {
  final from = (idx - 400).clamp(0, src.length);
  final head = src.substring(from, idx);
  if (RegExp(r'[(,]\s*' + name + r'\s*[,)]').hasMatch(head)) {
    return '形参：自动初判命中函数/闭包形参表，实参由调用方决定 ⇒ 静态不可追';
  }
  if (RegExp(r'\b(?:final|late\s+final)\s+Widget\??\s*' + name + r'\s*;')
      .hasMatch(src)) {
    return '形参：自动初判命中控件字段，实参由构造调用方决定 ⇒ 静态不可追';
  }
  return '解析不到定义（既非局部变量，也看不到形参声明）';
}

class _Method {
  _Method(this.file, this.owner, this.params, this.body);
  final String file;

  /// ★ 所在**类**名（空 = 顶层函数）
  ///
  /// # 为什么必须有这个
  /// ```text
  /// 私有方法名在不同类里**大量重名**：_play / _add / _build / _row / _header ...
  /// 第一版按名字全局合并 ⇒ 追 _bodyEpisodes 会跳到别的类的 _play，
  /// 再跳到 _add、_probe、_fmt ⇒ 129 处假命中，门禁变噪声。
  /// ⇒ 必须限定「同一个类或它的祖先链里找」，不能全仓按名找。
  /// ```
  final String owner;
  final String params;
  final String body;
}

/// 提取文件内所有方法/函数定义：名字 → (形参表, 函数体)
///
/// ⚠️ 正则刻意宽松：返回类型可能是 `Widget` / `void` / `List<X>` / 可空类型。
///    只用「行首缩进 + 标识符 + ( ... ) + {」作判据，够用且不易漏。
Map<String, List<_Method>> _methods(String file, String s) {
  final out = <String, List<_Method>>{};
  final re = RegExp(r'\n\s{2,}[\w<>,\?\s]*?\b(_[A-Za-z][A-Za-z0-9]*)\s*\(');
  for (final m in re.allMatches(s)) {
    final name = m.group(1)!;
    /*
     * ⚠️ Dart 的 `Match` 与 JS 不同：`start` / `end` 是**属性**，不是方法。
     *    没有 `m.start(n)` / `m.end(n)` ⇒ 写了两版都编译不过。
     */
    final nameAt = m.start + m.group(0)!.indexOf(name);
    final po = s.indexOf('(', nameAt + name.length);
    if (po < 0) continue;
    final params = _block(s, po);
    final braceAt = s.indexOf('{', po + params.length);
    if (braceAt < 0) continue;
    final body = _block(s, braceAt);
    // ★ 找这个名字之前最近的 `class X` —— 那就是它所属的类
    final before = s.substring(0, nameAt);
    final cm = RegExp(r'\bclass\s+(_?[A-Za-z][A-Za-z0-9_]*)').allMatches(before);
    final owner = cm.isEmpty ? '' : cm.last.group(1)!;
    out.putIfAbsent(name, () => []).add(_Method(file, owner, params, body));
  }
  return out;
}

/// 结果分类
class _Verdict {
  _Verdict(this.kind, this.where, this.path);
  final String kind; // hit | undecided
  final String where;
  final String path;
}

/// 在 [owner] 类里找局部变量 [name] 的赋值表达式
///
/// 支持 `final x = ...;` / `var x = ...;` / `Widget x = ...;` 三种写法。
/// 返回 null 表示「不是局部变量」⇒ 调用方应报「未判定」。
String? _localAssign(String src, String owner, String name) {
  // 限定在 owner 类的范围内找（避免跨类同名）
  var from = 0;
  if (owner.isNotEmpty) {
    final ci = src.indexOf('class ' + owner);
    if (ci >= 0) from = ci;
  }
  final re = RegExp(r'\b' + RegExp.escape(name) + r'\s*=\s*');
  for (final m in re.allMatches(src.substring(from))) {
    // 前面必须是声明（final/var/类型名），不能是 `x = 5` 这种重新赋值
    final head = src.substring(from + m.start - 40 < 0 ? 0 : from + m.start - 40,
        from + m.start);
    if (!RegExp(r'(final|var|late|const|[A-Z][A-Za-z0-9_<>?]*)\s+$')
        .hasMatch(head)) {
      continue;
    }
    // 取右侧表达式到同层分号
    final st = from + m.end;
    var d = 0;
    for (var i = st; i < src.length; i++) {
      final c = src[i];
      if (c == '(' || c == '[' || c == '{') d++;
      if (c == ')' || c == ']' || c == '}') d--;
      if (c == ';' && d <= 0) return src.substring(st, i);
    }
  }
  return null;
}

/// 在 [src] 的 [at] 位置往前找最近的 `class X` —— 判断这段代码属于哪个类
String _ownerAt(String src, int at) {
  final before = src.substring(0, at.clamp(0, src.length));
  final cm = RegExp(r'\bclass\s+(_?[A-Za-z][A-Za-z0-9_]*)').allMatches(before);
  return cm.isEmpty ? '' : cm.last.group(1)!;
}

/// 「未判定」收集器 —— 与「确认命中」**必须分开**
///
/// ⚠️ 我第一版把两者都塞进同一个 List，结果：
///    129 处「命中」里绝大多数是「无定义 / 超上限」⇒ 门禁变成噪声。
final _undecided = <String>[];

/// ★ 收敛式解析：从 [name] 出发，追到「解析不出新符号」为止
///
/// [fromFile] / [fromOwner]：调用方所在的文件与类。**只在这两个范围内找定义**。
/// 不限定时，`_play` / `_add` 这类重名会把人带到完全无关的代码里（实测 129 处假命中）。
void _converge({
  required String name,
  required Map<String, List<_Method>> all,
  required Set<String> seen,
  required String path,
  required int depth,
  required String where,
  required List<_Verdict> out,
  required String fromFile,
  required String fromOwner,
}) {
  final key = fromFile + '#' + fromOwner + '#' + name;
  if (seen.contains(key)) return;
  // ★ 上限：超了必须报「未判定」，不能静默
  if (depth > 6 || seen.length > 200) {
    // ★ 必须进 undecided，**不能**进 out（out 是「确认命中」）
    _undecided.add(where + '  ' + path + ' -> ' + name + '（超上限）');
    return;
  }
  seen.add(key);

  /*
   * ★ 候选筛选顺序：
   *   ① 同文件 + 同类            ← 绝大多数情况
   *   ② 同文件 + 任意类          （State 类调 Widget 的方法）
   *   ③ 全仓 + 同类              （跨文件的 Widget 类）
   * ⇒ 三条都空才判「未判定」。
   */
  final raw = all[name] ?? const <_Method>[];
  var defs = raw
      .where((d) => d.file == fromFile && d.owner == fromOwner)
      .toList();
  if (defs.isEmpty) {
    defs = raw.where((d) => d.file == fromFile).toList();
  }
  if (defs.isEmpty && fromOwner.isNotEmpty) {
    defs = raw.where((d) => d.owner == fromOwner).toList();
  }
  if (defs.isEmpty) {
    // ★ 解析不到定义 ⇒ 明确「未判定」，**不混进命中清单**
    _undecided.add(where + '  ' + path + ' -> ' + name + '（无定义）');
    return;
  }

  for (final d in defs) {
    // ① 函数体里直接有 tile 吗
    for (final t in _tiles) {
      if (RegExp(r'\b' + t + r'\s*\(').hasMatch(d.body)) {
        out.add(_Verdict('hit', where, path + ' -> ' + name + ' [' + t + ']'));
        return;
      }
    }
    // ② 继续追函数体里调用的本仓方法
    for (final sm in RegExp(r'\b(_[A-Za-z][A-Za-z0-9]*)\s*\(').allMatches(d.body)) {
      final sub = sm.group(1)!;
      if (sub == name) continue;
      _converge(
        name: sub,
        all: all,
        seen: seen,
        path: path + ' -> ' + name,
        depth: depth + 1,
        where: where,
        out: out,
        fromFile: d.file,
        fromOwner: d.owner,
      );
    }
  }
}

/// ★★★ 主扫描 —— **唯一实现**
///
/// # 为什么必须抽出来（2026-10-20，Lead 点出的假绿）
/// ```text
/// 阳性对照 C 原来**自己复制了一份**「收敛 + 形态」逻辑
/// （final formBad = <_Verdict>[] + 自己 _converge + 自己 _shapeProblem）。
/// ⇒ 它测的是**复制品**，不是被测的主扫描：
///   把主扫描里的 `formBad.add(...)` 删掉（判据失效）⇒ 主扫描不再报违例，
///   而 C 的复制品照样报 ⇒ **C 仍然绿**。
///   这是「同一个源比同一个源」的典型形态，只是发生在**测试内部**。
/// ```
/// ⇒ 现在主测试与阳性对照 C **共用本函数**：改坏它，两边一起红。
///
/// # 返回
/// ```text
/// hits       有 tile + 有不透明 wrapper（诊断用，行号只出现在报错文本里）
/// undecided  child 是裸标识符但解析不到定义/形参 ⇒ **不是干净，需人看**
/// formBad    有 tile、块内没有 Material( 承接 ⇒ **红**（任何豁免都压不住）
/// ```
({List<_Verdict> hits, List<_Verdict> undecided, List<_Verdict> formBad})
    scan(Map<String, String> sources, {bool verbose = true}) {
  // 符号表**从传入的 sources 建** —— 这样阳性对照塞假源码时，
  // 收敛追踪看到的也只有假源码里的定义（不会跑去真仓里找同名函数）。
  final all = <String, List<_Method>>{};
  for (final e in sources.entries) {
    _methods(e.key, e.value)
        .forEach((k, v) => all.putIfAbsent(k, () => []).addAll(v));
  }

  final hits = <_Verdict>[];
  final undecided = <_Verdict>[];
  /*
   * ★ 形态不成立的命中（2026-10-20 新增）
   *
   * 与 `hits` **分开**：hits 是「这里有 tile + 有底色 wrapper」（行号可豁免），
   * formBad 是「tile 但**没有** Material 承接」（**任何豁免都压不住**）。
   * 形状对不上时仍记 hits（否则会被判成白名单 GONE，报错方向误导）。
   */
  final formBad = <_Verdict>[];

  for (final entry in sources.entries) {
    final file = entry.key;
    if (file.contains('/design/')) continue;
    final src = entry.value;

    for (final w in _wrappers) {
      var idx = 0;
      while (true) {
        idx = src.indexOf(w, idx);
        if (idx < 0) break;
        final blk = _block(src, idx + w.length - 1);
        final line = '\n'.allMatches(src.substring(0, idx)).length + 1;
        final where = file + ':' + line.toString();

        /*
         * ★ 从 v2 移植：只有「有实际背景色且 alpha > 0」的中间层才报警
         *
         * # 为什么这条必须有（v3 原来没有，是退步）
         * ```text
         * `AppSurface(color: Colors.transparent, child: ListTile(...))`
         * 这层是**透明**的 ⇒ 它挡不住 ListTile 的水波 ⇒ **不该报警**。
         * 实测：v2 放行（正确），v3 误报。
         * ⇒ 误报会让门禁变噪声，噪声多了人就不看，等于没门禁。
         * ```
         *
         * 判据对齐 Flutter 的 `list_tile.dart:_findIntermediateWidget`：
         * 它只沿着「有背景色」的中间层往上找，透明的继续往上看。
         */
        if (!_hasOpaqueBackground(blk, w)) {
          idx += w.length;
          continue;
        }

        final child = _childExpr(blk);

        // 直接命中
        var direct = false;
        final cs = _childStart(blk);
        for (final t in _tiles) {
          final tm = RegExp(r'\b' + t + r'\s*\(').allMatches(child).toList();
          if (tm.isNotEmpty) {
            hits.add(_Verdict('hit', where, '直接含 ' + t));
            // ★ 形态：每一处 tile 都必须被块内一层 Material( 包住
            final bad =
                _shapeProblem(blk, w, tm.map((m) => cs < 0 ? -1 : cs + m.start));
            if (bad != null) {
              formBad.add(_Verdict('undecided', where, 'tile ⇒ ' + bad));
            }
            direct = true;
            break;
          }
        }
        if (!direct) {
          // 收敛追踪 child 里出现的所有私有符号
          for (final sm
              in RegExp(r'\b(_[A-Za-z][A-Za-z0-9]*)\s*\(').allMatches(child)) {
            /*
             * ★★★ 2026-10-20（修误报）：形态判据只对**真的追到 tile** 的符号生效。
             *
             * # 改前为什么错（17 处误报，逐条实测过）
             * ```text
             * 改前：`child` 里**每一个** `_foo(...)` 调用点都要求
             *       「块内必须有 Material(」—— 不管 _foo 内部有没有 tile。
             *
             * 实测 17 处违例涉及的 13 个函数，内部 tile 家族控件数量**全部为 0**：
             *   _titleBarRow / _TitleBarHost / _openMenu / _moreButtonCenter /
             *   _EmbedLoading / _EmbedError / _AudioOnlyBadge / _EmbedVideoOutputDead /
             *   _RoundBtn / _EmbedBar / _DanmakuUnavailableNote / _handle / _loadingHint
             * ⇒ 它们全是 Icon / Text / Container / Row 一类**不依赖 Material** 的控件。
             *
             * 运行期实证（一次性探针，已删）：
             *   ListTile        无 Material ⇒ FlutterError   ← 真会抛
             *   SwitchListTile  无 Material ⇒ FlutterError   ← 真会抛
             *   ColoredBox>ListTile 无 Material ⇒ FlutterError
             *   Row(Icon, Text) 无 Material ⇒ **exception=Null**  ← 不抛
             * ⇒ 「没有 Material」本身不是缺陷；**只有 tile 家族需要它**。
             * ```
             *
             * # 改后
             * ```text
             * 先收敛追踪（_converge 会把命中的 tile 写进 hits），
             * 再判断「这一跳有没有产出 tile」：
             *   · 产出了 ⇒ 才检查调用点是否在 Material 之下（真违例）
             *   · 没产出 ⇒ 不检查（这个函数不需要 Material）
             * ```
             *
             * ⚠️ 顺序不能反：必须先 `_converge` 再判 hits 增量。
             * ⚠️ 仍保留「调用点漏 Material」的检测能力 —— 见下方断言：
             *    对**真含 tile** 的函数，调用点无 Material 必须红（有专门的用例钉着）。
             */
            final hitsBefore = hits.length;
            _converge(
              name: sm.group(1)!,
              all: all,
              seen: <String>{},
              path: where,
              depth: 0,
              where: where,
              out: hits,
              fromFile: file,
              fromOwner: _ownerAt(src, idx),
            );
            // ★ 只有这一跳真的追到了 tile，才要求调用点在 Material 之下
            if (hits.length > hitsBefore) {
              final badSym = _shapeProblem(blk, w, [cs < 0 ? -1 : cs + sm.start]);
              if (badSym != null) {
                formBad.add(_Verdict('undecided', where,
                    sm.group(1)! + '(...) 的调用点 ⇒ ' + badSym));
              }
            }
          }
          /*
           * 裸标识符 child（`child: inner` / `child: child`）有两种来源：
           *
           * ① 本方法里的**局部变量**
           *      `final inner = Column(children: [...]);`
           *      ⇒ **可以精确判定**：把该变量在方法体里的赋值表达式拿来追。
           *      实例：settings_kit.dart:281 `child: inner`，
           *            它的 inner 里就有调用方塞进来的 tile ⇒ 必须留 Material。
           *
           * ② 方法的**形参**
           *      `Widget _card({required List<Widget> children})`
           *      ⇒ 静态看不到调用方实参 ⇒ **只能报未判定**（绝不静默）。
           *      实例：source_composer_dialog 的 `_card`。
           *
           * ⚠️ 我第一版只做了 ②，把 ① 也当成「未判定」⇒ 故障注入时
           *    settings_kit 里塞进 ListTile 门禁**没反应**。
           *    ⇒ 局部变量必须真追，不能偷懒归到未判定。
           */
          final trimmed = child.trim();
          if (RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(trimmed)) {
            final owner = _ownerAt(src, idx);
            final local = _localAssign(src, owner, trimmed);
            if (local != null) {
              // ① 局部变量：先看字面量，再收敛追踪其中的符号
              var hitLocal = false;
              for (final t in _tiles) {
                if (RegExp(r'\b' + t + r'\s*\(').hasMatch(local)) {
                  hits.add(_Verdict(
                      'hit', where, 'child=' + trimmed + '（局部变量）直接含 ' + t));
                  if (!local.trim().startsWith('Material')) {
                    final badL = _shapeProblem(blk, w, [cs]);
                    if (badL != null) {
                      formBad.add(_Verdict('undecided', where,
                          'child=' + trimmed + '（局部变量）⇒ ' + badL));
                    }
                  }
                  hitLocal = true;
                  break;
                }
              }
              if (!hitLocal) {
                for (final sm in RegExp(r'\b(_[A-Za-z][A-Za-z0-9]*)\s*\(')
                    .allMatches(local)) {
                  _converge(
                    name: sm.group(1)!,
                    all: all,
                    seen: <String>{},
                    path: where + ' child=' + trimmed,
                    depth: 0,
                    where: where,
                    out: hits,
                    fromFile: file,
                    fromOwner: owner,
                  );
                }
              }
            } else {
              // ② 形参（或解析不到）⇒ 只能未判定
              undecided.add(_Verdict('undecided', where,
                  'child = ' +
                      trimmed +
                      '（' +
                      _unknownKind(src, idx, trimmed) +
                      '）'));
            }
          }
        }
        idx += w.length;
      }
    }
  }

  if (verbose) {
    print('[T66] 命中 ' + hits.length.toString() + ' 处');
    // ① 去重：同一位置被多条路径命中时算一处（否则白名单维护不了）
    final byWhere = <String, List<_Verdict>>{};
    for (final h in hits) {
      byWhere.putIfAbsent(h.where, () => []).add(h);
    }
    print('[T66] 合法组合 ' +
        byWhere.length.toString() +
        ' 处（不透明包裹 + 块内 Material( 承接）');
    print('[T66] 命中 ' + hits.length.toString() + ' 条路径');
    for (final h in hits) {
      print('  HIT ' + h.where + '   ' + h.path);
    }
    print('[T66] 未判定 ' + undecided.length.toString() + ' 处（**不是**干净，需人看）');
    for (final u in undecided) {
      // ★ 机器可读行：UNKNOWN|文件:行号|原因
      print('  UNKNOWN|' + u.where + '|' + u.path);
      print('  ??? ' + u.where + '   ' + u.path);
    }
    print('[T66] ★ 违例 ' +
        formBad.length.toString() +
        ' 处（有 tile、块内没有 Material 承接 ⇒ 运行期必抛断言）');
    for (final f in formBad) {
      print('  SHAPE|' + f.where + '|' + f.path);
    }
  }

  return (hits: hits, undecided: undecided, formBad: formBad);
}


void main() {
  late Map<String, String> libs;
  late Map<String, List<_Method>> all;

  setUpAll(() {
    libs = {};
    all = {};
    for (final e in Directory('lib').listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      final p = e.path.replaceAll('\\', '/');
      final base = p.split('/').last;
      if (RegExp(r'^t[0-9]').hasMatch(base)) continue;
      if (base.contains('probe')) continue;
      final s = _strip(e.readAsStringSync());
      libs[p] = s;
      _methods(p, s).forEach((k, v) => all.putIfAbsent(k, () => []).addAll(v));
    }
    print('[T66] 文件 ' + libs.length.toString() + ' / 方法符号 ' + all.length.toString());
  });

  test('★★★ wrapper 的 child 依赖必须收敛追踪，不许静默当干净', () {
    // ★ 与阳性对照 C **共用** scan() —— 见 scan 的文档（假绿的来源）
    final r = scan(libs);

    /*
     * ★★★ 2026-10-20：白名单整体删除 —— 定位方式从「文件:行号」改成「结构」
     *
     * # 为什么删（两次重锚都没救回来）
     * ```text
     * 2026-10-17 +412、2026-10-19 +741、2026-10-20 位移 +25 / −2 —— 三次都是**纯漂移**：
     * 别人在 player_page / emby_page 上面加删代码，白名单立刻报 GONE + NEW 成对出现。
     * 每次人工核对、改数字、再提交，换来的是下一次同样的红。
     * ⇒ 一条需要人工周期性维护的门禁，维护成本最终会让人把它关掉。
     * ```
     *
     * # 现在的判据（结构，不碰行号）
     * ```text
     * 对每个「有不透明底色、且子树里有 ListTile 家族」的中间层：
     *   块内必须有一层 Material( 的括号范围把 tile（或它的调用点）包住；
     *   否则 ⇒ **红**（formBad）。行号只出现在报错信息里，**不参与判定**。
     * ⇒ 谁在上面加十行都不会红；真违例（有 tile 却没 Material 承接）照样红。
     * ```
     *
     * # 丢掉的东西（诚实记账）
     * ```text
     * 旧白名单还兼职「腐化检测」：某条豁免不再命中 ⇒ 红。
     * 改成结构判据后这条**没有了** —— tile 被换成自绘行时，门禁不再提醒。
     * 这是有意的取舍：那条检测的代价是周期性误红，收益只是提醒人清理文档。
     * ```
     */
    expect(
        r.formBad,
        isEmpty,
        reason: '★ 违例：tile 的调用点上没有「不透明中间层 + Material( 承接」的组合 —— '
            '这类代码运行期会抛 "ListTile background color or ink splashes may '
            'be invisible"。\n'
            '⇒ 修法只有两种：在 tile 外面包一层 Material(type: MaterialType.transparency)，'
            '或把不透明底色挪到 Material 之外。\n' +
            r.formBad.map((f) => f.where + '  ' + f.path).join('\n'));

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 判别力自检：**这一条**证明 `formBad` 还能红（2026-10-20）
     * ══════════════════════════════════════════════════════════════════
     *
     * # 为什么必须放在**主测试**里，而不是只靠阳性对照 C
     * ```text
     * 真实仓里「真违例」的数量恰好是 0（17 处误报修完之后）。
     * ⇒ 把 scan() 里的 `formBad.add(...)` 删掉（判据彻底失效）后：
     *      主测试：formBad 仍是空的 ⇒ **仍然绿**（0 == 0）
     *      C     ：红（它塞的假源码本来就是违例）
     *
     * 实测就是这样：注入 A 只让 C 红，主测试毫发无伤。
     * 「0 个违例」既可能是"全修好了"也可能是"判据失效了" —— 主测试自己
     * **无法区分**这两种状态，这正是 Lead 说的"判据已失去判别力"。
     * ```
     *
     * # 做法：同一次运行里，拿**同一份 scan()** 扫一段已知违例
     * ```text
     * 若 scan() 真的还能报违例 ⇒ 这里必得 1 处
     * 若 scan() 被改坏       ⇒ 这里得 0 ⇒ **主测试自己红**
     * ```
     * ★ 与阳性对照 C 的分工：
     *   · 本条：证明「判据没失效」（在主测试内部，跑真实仓的同一次调用里）
     *   · C    ：证明「判据的**输入**能触发它」（独立用例，报错信息更具体）
     *   两者都用**同一个** scan()，任何一处改坏两边一起红。
     */
    final canary = scan(<String, String>{
      'canary.dart': [
        'class Canary {',
        '  Widget build() {',
        '    return AppSurface(color: red, child: _row());',
        '  }',
        '  Widget _row() {',
        '    return ListTile(title: Text(x));',
        '  }',
        '}',
      ].join('\n'),
    }, verbose: false);
    expect(canary.formBad, isNotEmpty,
        reason: '★★ 判别力自检失败：scan() 对一段**已知违例**（AppSurface>_row>ListTile，'
            '调用点无 Material）没有报出 formBad。\n'
            '  ⇒ 判据已失效。此时主测试上面那条 `formBad isEmpty` 是**假绿**：\n'
            '     它之所以绿，不是因为仓里没有违例，而是因为判据不再会报违例。');
  });

  test('★ 阳性对照 A：多跳（3 层）必须被抓到', () {
    final fake = <String, String>{
      /*
       * ⚠️ 样本必须用**花括号体**，不能用 `=>` 表达式体。
       *    `_methods()` 的判据是「参数表后面跟 `{`」，`=> body;` 找不到花括号
       *    ⇒ 整个样本一个方法都解析不出来 ⇒ 对照测试变成假红。
       *    （第一版就是 `=>`，结果 out 为空、我自己以为是扫描器坏了。）
       */
      'a.dart': [
        'class A {',
        '  Widget build() {',
        '    return AppSurface(child: _group());',
        '  }',
        '  Widget _group() {',
        '    return _section();',
        '  }',
        '  Widget _section() {',
        '    return _row();',
        '  }',
        '  Widget _row() {',
        '    return SwitchListTile(value: true, onChanged: null);',
        '  }',
        '}',
      ].join('\n'),
    };
    final a = <String, List<_Method>>{};
    _methods('a.dart', fake['a.dart']!)
        .forEach((k, v) => a.putIfAbsent(k, () => []).addAll(v));
    final src = fake['a.dart']!;
    final idx = src.indexOf('AppSurface(');
    final child = _childExpr(_block(src, idx + 10));
    final out = <_Verdict>[];
    for (final m in RegExp(r'\b(_[A-Za-z][A-Za-z0-9]*)\s*\(').allMatches(child)) {
      _converge(
          name: m.group(1)!,
          all: a,
          seen: <String>{},
          path: 'a.dart',
          depth: 0,
          where: 'a.dart',
          out: out,
          fromFile: 'a.dart',
          fromOwner: 'A');
    }
    print('[T66] 阳性A(out) = ' + out.map((v) => v.kind + ':' + v.path).join(' | '));
    expect(out.where((v) => v.kind == 'hit'), isNotEmpty,
        reason: '3 层跳转必须被追到（_group→_section→_row→SwitchListTile）');
  });

  test('★ 阳性对照 B：形参透传必须报「未判定」而不是干净', () {
    final fake = <String, String>{
      'b.dart': [
        'class B {',
        '  Widget _card({required List<Widget> children}) => Material(child: Column(children: children));',
        '}',
      ].join('\n'),
    };
    final b = <String, List<_Method>>{};
    _methods('b.dart', fake['b.dart']!)
        .forEach((k, v) => b.putIfAbsent(k, () => []).addAll(v));
    final src = fake['b.dart']!;
    final idx = src.indexOf('Material(');
    final child = _childExpr(_block(src, idx + 8));
    print('[T66] 阳性B child = ' + child.trim());
    // 这里 child 是 Column(...) 不是裸标识符 ⇒ 由主扫描的「未判定」分支兜底
    // 本测试证明：我们**不会**把它判成 hit（那是误报），也**不会**判成干净。
    expect(child.contains('children'), isTrue);
  });

  test('★ 阴性对照：干净 wrapper 不许误报', () {
    final fake = <String, String>{
      'c.dart': [
        'class C {',
        '  Widget build() => AppSurface(color: red, child: Text(hi));',
        '}',
      ].join('\n'),
    };
    final c = <String, List<_Method>>{};
    _methods('c.dart', fake['c.dart']!)
        .forEach((k, v) => c.putIfAbsent(k, () => []).addAll(v));
    final src = fake['c.dart']!;
    final idx = src.indexOf('AppSurface(');
    final child = _childExpr(_block(src, idx + 10));
    final out = <_Verdict>[];
    for (final m in RegExp(r'\b(_[A-Za-z][A-Za-z0-9]*)\s*\(').allMatches(child)) {
      _converge(
          name: m.group(1)!,
          all: c,
          seen: <String>{},
          path: 'c.dart',
          depth: 0,
          where: 'c.dart',
          out: out,
          fromFile: 'c.dart',
          fromOwner: 'C');
    }
    print('[T66] 阴性(out) = ' + out.map((v) => v.kind).join(','));
    expect(out.where((v) => v.kind == 'hit'), isEmpty,
        reason: 'Text(hi) 不含 tile，不许报警');
  });

  /*
   * ══════════════════════════════════════════════════════════════════
   * ★★★ 阳性对照 C：**真违例必须红**（2026-10-20 新增）
   *
   * # 为什么必须补这一条
   * ```text
   * 同一天我修掉了 17 处误报 —— 误报的成因是「调用点一律要求 Material，
   * 不管被调函数内部有没有 tile」。
   *
   * 修法把判据改成「只有这一跳真的追到 tile，才要求调用点在 Material 之下」。
   * ⚠️ 这个修法有一个明显的失效风险：**如果改过头，就再也不会报任何形态违例**
   *    （违例数从 17 直接掉到 0 —— 而 0 既可能是"全修好了"也可能是"判据失效了"）。
   *
   * ⇒ 必须有一条用例证明：**真违例（函数内部确实含 tile、调用点却没 Material）
   *   仍然会红**。没有它，这次修改就是一次**无法区分**的放宽。
   * ```
   */
  test('★★★ 阳性对照 C：函数内部真含 tile、调用点无 Material ⇒ 必须报违例', () {
    final fake = <String, String>{
      'd.dart': [
        'class D {',
        '  Widget build() {',
        // ★ 关键：wrapper 是 AppSurface（不是 Material），child 调 _row()
        '    return AppSurface(color: red, child: _row());',
        '  }',
        // ★ 关键：_row 内部**真的**含 ListTile
        '  Widget _row() {',
        '    return ListTile(title: Text(x));',
        '  }',
        '}',
      ].join('\n'),
    };

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 2026-10-20（Lead 点出的假绿，本文件的核心修复）
     * ══════════════════════════════════════════════════════════════════
     *
     * # 改前：这里**自己复制了一份**主扫描的逻辑
     * ```text
     * final out = <_Verdict>[];
     * final formBad = <_Verdict>[];
     * for (final sm in ...allMatches(child)) {
     *   _converge(...);                        ← 自己调一次
     *   if (out.length > hitsBefore) {
     *     _shapeProblem(...);                  ← 自己判一次
     *     if (bad != null) formBad.add(...);   ← 自己加一次
     *   }
     * }
     * ```
     * ⇒ 它测的是**复制品**。实测：把主扫描里的 `formBad.add(...)` 删掉
     *   （判据彻底失效）后，**本条仍然绿** —— 因为复制品还在报。
     *   这是「同一个源比同一个源」的典型形态，只不过发生在**测试内部**。
     *
     * # 改后：与主测试**共用 `scan()`**
     * ```text
     * 主测试：  final r = scan(libs);
     * 本用例：  final r = scan({'d.dart': 那段假源码});
     * ```
     * ⇒ 判据只有一份。改坏它 ⇒ 主测试与本条**同时红**（注入 A 已实测）。
     *
     * ⚠️ `scan()` 内部**从传入的 sources 建符号表** —— 所以这里塞假源码时，
     *    收敛追踪只会在 d.dart 里找 _row，不会跑去真仓里找同名函数。
     *    （若沿用全局 `all`，这条就变成"用真仓符号表解析假源码"，仍是假绿。）
     */
    final r = scan(fake, verbose: false);

    print('[T66] 阳性C hits=' +
        r.hits.length.toString() +
        ' formBad=' +
        r.formBad.length.toString());

    // ① 必须追到 tile（否则下面的断言会因为"没命中"而空转）
    expect(r.hits, isNotEmpty,
        reason: '★ 前置：_row 内部含 ListTile，收敛追踪必须命中它');
    // ② 必须报违例（调用点无 Material）
    expect(r.formBad, isNotEmpty,
        reason: '★★ 真违例被放过了：函数内部含 ListTile、调用点却没有 Material 承接。\n'
            '  ⇒ 说明「只对追到 tile 的符号要求 Material」这条修法**改过头了**，'
            '判据已失去判别力。\n'
            '  ⚠️ 本用例与主测试共用 scan() —— 若本条绿而主测试也绿，'
            '     先确认注入「删掉 formBad.add」能让**两条同时红**。');
  });
}
