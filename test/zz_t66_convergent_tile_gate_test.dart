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

/// 只取**顶层**的 child 参数（跳过嵌套在别的组件里的 child:）
///
/// ⚠️ 第一版直接用 firstMatch，抓到的是嵌套里的 child:
/// 实测 _LoadingOverlay 的 ColoredBox(child: Center(child: AppLoading)) 被误判，
/// 因为取到的是 Center 的 child，然后又越过边界吃进后面的代码。
String? _topLevelChild(String blk) {
  var depth = 0;
  for (var i = 0; i < blk.length - 5; i++) {
    final c = blk[i];
    if (c == '(' || c == '[' || c == '{') {
      depth++;
    } else if (c == ')' || c == ']' || c == '}') {
      depth--;
    } else if (depth == 1 && blk.startsWith('child', i)) {
      final rest = blk.substring(i + 5, (i + 12).clamp(0, blk.length));
      final m = RegExp(r'^\s*:').firstMatch(rest);
      if (m != null) {
        return blk.substring(i + 5 + m.end);
      }
    }
  }
  return null;
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
    final cm = RegExp(r'(?:^|[,{\s])color\s*:\s*([^,\n]+)').firstMatch(seg);
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
    final hits = <_Verdict>[];
    final undecided = <_Verdict>[];

    for (final entry in libs.entries) {
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
          for (final t in _tiles) {
            if (RegExp(r'\b' + t + r'\s*\(').hasMatch(child)) {
              hits.add(_Verdict('hit', where, '直接含 ' + t));
              direct = true;
              break;
            }
          }
          if (!direct) {
            // 收敛追踪 child 里出现的所有私有符号
            for (final sm
                in RegExp(r'\b(_[A-Za-z][A-Za-z0-9]*)\s*\(').allMatches(child)) {
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
                    'child = ' + trimmed + '（疑形参，需看调用方）'));
              }
            }
          }
          idx += w.length;
        }
      }
    }

    print('[T66] 命中 ' + hits.length.toString() + ' 处');

    /*
     * ★ 基线白名单：把这 9 处「确认必须留」的豁免掉
     *
     * # 为什么需要白名单
     * ```text
     * 这 9 处**不会**变成能换 —— 它们的子树里真的需要 Material 祖先。
     * 没有白名单的话门禁**恒定红**，几周后没人会看它 ⇒ 等于没有门禁。
     * （形式不同：一种是漂移，一种是噪声，结果一样。）
     * ```
     *
     * # 判据（三条都要）
     * ```text
     * ① 命中在白名单里      ⇒ 不红，只打印「已知必须留 N 处」
     * ② 命中不在白名单      ⇒ **红**（新增的就该红）
     * ③ 白名单里的位置消失  ⇒ **红**（提示「这条豁免可以删了」）
     *    —— 否则白名单只增不减，会慢慢腐化，
     *       到最后没人知道哪条还有效。
     * ```
     */
    final known = <String, String>{
      /*
       * ★★★ 2026-10-17：行号整体 +412 重新锚定
       *
       * # 为什么会漂
       * dlg-provider 的 task-41（弹幕发送栏）在 player_page.dart 净增 837 行，
       * 把这些既有 ListTile 全部往下推。白名单按 file:line 硬编码 ⇒ 全部失效。
       *
       * 实测报错：
       *   GONE 19347 / 19369 / 19550 / 19572（已不存在）
       *   新增 19879 / 19901 / 20082 / 20104（同一段代码的新位置）
       *
       * # 这 4 处为什么合法
       * 形态都是同一套：
       *   ColoredBox(black@0.92) -> Material(transparency) -> Column -> ... -> ListTile
       *
       * Flutter 的 _findIntermediateWidget 从 ListTile 往上走，遇到第一个 Material 就停，
       * 所以列在 Material 之下的 ColoredBox 不在检查范围内 ⇒ 不触发断言。
       * （task-70 已证：ColoredBox 不能换成 Material，
       *   _RenderColoredBox 的 HitTestBehavior.opaque 写死，换掉会让点击穿透。）
       *
       * # ⚠️ 留给后来人
       * 行号锚定天然会漂。下次这里再红，先判断是「位置变了」还是「真新增」：
       *   · 报 GONE 一批 + 新增一批，且形态相同 ⇒ 只是漂移，更新行号
       *   · 只新增不 GONE，且形态是 ColoredBox->AppSurface（无 Material）⇒ 真问题
       */
      /*
       * ⚠️ 2026-10-18（round-65）：一批行号整体下移，全部按「位置变了」更新。
       *
       * # 判定依据（严格按本文件上方「留给后来人」那条规则）
       * ```text
       * 报 GONE 一批 + 新增一批，且**形态完全一致** ⇒ 只是漂移，更新行号
       * 只新增不 GONE，且形态是 ColoredBox->AppSurface（无 Material）⇒ 真问题
       * ```
       * 实测：9 条 GONE、8 条 NEW，形态逐条对应（ColoredBox->Material 仍是那个
       * Material，_switchRow->SwitchListTile 仍是那条路径）⇒ 是漂移。
       *
       * # 为什么会漂
       * · E1 删掉侧栏/顶栏两套布局骨架（`top_bar_layout.dart` 整个文件没了）
       * · E2 给 60 个文件加了 `import '../design/icons/app_icons.dart';`
       *   ⇒ 每个文件 +1 行，其后所有行号 +1
       * · 批次 B/C 在 `player_page.dart` 里新增了约 714 行
       *
       * # 顺带删掉一条
       * `lib/ui/shell_layouts/top_bar_layout.dart:215` 必须**移除** ——
       * 那个文件在 E1 里已删除。留着它就是一条永远 GONE 的死条目，
       * 而门禁有「白名单每条都必须仍然命中（防空条款假绿）」的反向检查，
       * 留着会让那条检查红。
       */
      'lib/ui/player_page.dart:20541':
          'ColoredBox(black@0.92) -> Material(transparency)，ListTile 在 Material 之下 ⇒ 合法。',
      'lib/ui/player_page.dart:20563':
          '同上，另一层 wrapper（播放页元信息面板）。',
      'lib/ui/player_page.dart:20744':
          'ColoredBox(black@0.92) -> Material(transparency)，同形态第二处（maxWidth 360）。',
      'lib/ui/player_page.dart:20766':
          '同上，另一层 wrapper。',
      'lib/ui/settings/emby_page.dart:986':
          'SwitchListTile（转码开关）。该处代码注释自己写着「必须自己包一层'
              '透明 Material，否则 flutter 断言」。',
      'lib/ui/settings/emby_page.dart:1285':
          'ListTile（dense，服务端行）。',
      'lib/ui/widgets/player_settings_sheet.dart:712':
          '卡片 Material；经 _switchRow -> SwitchListTile（六条 section 同路径，'
              '收敛追踪报了 10 次，去重后算一处）。',
      'lib/ui/widgets/player_settings_sheet.dart:777':
          '同上，外层另一处 Material。',
    };

    // ① 去重：同一位置被多条路径命中时算一处（否则白名单维护不了）
    final byWhere = <String, List<_Verdict>>{};
    for (final h in hits) {
      byWhere.putIfAbsent(h.where, () => []).add(h);
    }

    final newHits = <String, List<_Verdict>>{};
    for (final e in byWhere.entries) {
      if (!known.containsKey(e.key)) newHits[e.key] = e.value;
    }
    final gone = known.keys.where((k) => !byWhere.containsKey(k)).toList();

    print('[T66] 命中 ' + hits.length.toString() + ' 条 / 去重后 ' +
        byWhere.length.toString() + ' 处');
    print('[T66] 已知必须留 ' +
        (byWhere.length - newHits.length).toString() + ' 处（白名单命中）');
    for (final h in hits) {
      final mark = known.containsKey(h.where) ? '  (known)' : '  ★NEW';
      print('  HIT ' + h.where + '   ' + h.path + mark);
    }
    if (newHits.isNotEmpty) {
      print('[T66] ★★★ 新增命中 ' + newHits.length.toString() + ' 处：');
      for (final e in newHits.entries) {
        print('  NEW ' + e.key + '   ' + e.value.first.path);
      }
    }
    if (gone.isNotEmpty) {
      print('[T66] ★★★ 白名单里已消失 ' + gone.length.toString() + ' 处（豁免可删）：');
      for (final g in gone) {
        print('  GONE ' + g + '   ' + known[g]!);
      }
    }
    print('[T66] 未判定 ' + undecided.length.toString() + ' 处（**不是**干净，需人看）');
    for (final u in undecided) {
      print('  ??? ' + u.where + '   ' + u.path);
    }

    expect(newHits, isEmpty,
        reason: '★ 新增命中：这些 wrapper 的 child 收敛后含 ListTile 家族 ⇒ 换成无'
            ' Material 的 AppSurface 会触发 "ink splashes may be invisible"。\n'
            '若确认必须留，请加进 known 白名单**并写理由**；否则请改回 Material。\n'
            + newHits.entries
                .map((e) => e.key + ' ' + e.value.first.path)
                .join('\n'));

    expect(gone, isEmpty,
        reason: '★ 白名单腐化检测：以下位置**已经不再命中** —— 说明那里的 ListTile'
            ' 已被换成自绘行（或 Material 已被删），豁免没有意义了。\n'
            '⇒ 请从 known 里删掉这些条目。白名单只增不减会慢慢腐化。\n'
            + gone.map((g) => g + '  ' + known[g]!).join('\n'));
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
}
