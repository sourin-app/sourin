// ═══════════════════════════════════════════════════════════════════════
//  主题包 —— 一份调色板 + 少量形状/字号参数（JSON 描述）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话
//
// > 4. 主题如果可以做多主题就是外部插件式 或者之类的,能做的话就做一下,
//    不能就直接算了
//
// ⇒ 做成**外部主题包**：一份 JSON 就是一个主题，可以从文件选、可以粘贴、
//   可以放在 `<数据目录>/themes/*.json` 让它自动出现在列表里。
//
// # 为什么用「调色板 + 形状参数」而不是「整个 ThemeData」
//
// ```text
// 整个 ThemeData 序列化 → 版本一改就全废，且用户手写不动
// 一份调色板           → 与 app 的令牌体系一一对应，用户看得懂、改得动
// ```
//
// 所以格式是**扁平的角色 → 颜色**，加上几个可选的形状/字号微调。
// 缺字段一律回落默认值 —— 详见 [ThemePack.resolved]。

import 'dart:convert';
import 'dart:io';

import 'package:cross_file/cross_file.dart' show XFile;
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../app_palette.dart';
import '../../core/ui_prefs.dart';

/// 主题包的格式版本
///
/// ⚠️ 字段**只增不删不改语义**。用户的主题包可能存了很久；
///    解析时必须能认旧版本（[_parseV1] 就是为此）。
const int kThemePackVersion = 1;

/// 一份主题
@immutable
class ThemePack {
  const ThemePack({
    required this.id,
    required this.name,
    required this.brightness,
    required this.palette,
    String? familyId,
    this.radius,
    this.buttonPadding,
    this.borderWidth,
    this.dividerThickness,
    this.builtin = false,
    this.sourcePath,
  }) : familyId = familyId ?? id;

  /// 唯一 id（内置主题用 `'builtin.dark'` 这类固定值；外部包用文件名去掉扩展名）
  final String id;

  /// 显示名
  final String name;

  /// 明暗。⚠️ 一份包**只管一档明暗** —— 两档拆成两个包更清楚，
  /// 也避免"深色底配浅色文字"这种组合被配出来。
  final Brightness brightness;

  /// 语义色
  final AppPalette palette;

  /// 控件圆角（null = 用默认 10）
  final double? radius;

  /// 按钮内边距（null = 用默认 `EdgeInsets.symmetric(horizontal: 10, vertical: 11)`）
  ///
  /// ⚠️ 2026-10-16 之前这个字段**全仓零消费**（只解析、只序列化，没人读）——
  ///    声明了不生效等于骗用户。现在由 `theme_language.dart` 的
  ///    `ThemeLanguage.apply` 真正接到四类按钮上。
  final EdgeInsets? buttonPadding;

  /// 描边粗细（null = 用默认 1）
  ///
  /// ★ 这是「设计语言」维度，不是装饰：1px 细线是**精致/极简**的语言，
  ///   2~3px 硬边是**新粗野主义**的语言 —— 同一套配色换这一个数，
  ///   观感就从「现代 App」变成「海报」。只靠颜色做不到这件事。
  final double? borderWidth;

  /// 分隔线粗细（null = 用默认 1）
  ///
  /// 与 [borderWidth] 同源的理由：列表/区块之间的那条线是**排版语言**的一部分。
  final double? dividerThickness;

  /// 主题家族 id —— **双色主题的配对键**（Owner 2026-10-17 第 11-A 条）。
  ///
  /// # 为什么需要它
  /// ```text
  /// Owner 原话：「一个主题同时提供浅色版和深色版两个独立风格」。
  ///
  /// 实测现状：10 套内置主题里 8 套只有深色、2 套只有浅色。
  /// 选「樱粉」后系统切浅色，没有对应的浅色版 ⇒ 只能整站变深或回落。
  ///
  /// ⇒ 给同一设计的明/暗两版一个相同的 familyId，
  ///   跟随系统时按 family 找对应的那一版。
  /// ```
  ///
  /// # 与 [id] 的区别
  /// ```text
  /// id        = 具体那一版（如 'builtin.sakura.dark'）—— 唯一
  /// familyId  = 那一套设计（如 'builtin.sakura'）     —— 两版共享
  ///
  /// 老主题包没有 familyId ⇒ 回落成 id 本身（向后兼容，自成一族）。
  /// ```
  ///
  /// ⚠️ **不做成"一个 ThemePack 内嵌 light+dark 两份 palette"** 的理由：
  ///    那样要改 ThemePack 结构与所有读 palette 的地方；
  ///    按 family 配对只加一个字段 + 一个查找函数，改动面小一个数量级。
  final String familyId;

  /// 是否内置（内置的不可删除）
  final bool builtin;

  /// 外部包的来源路径（内置为 null）
  final String? sourcePath;

  // ── JSON ────────────────────────────────────────────────────────────────

  Map<String, Object?> toJson() => {
        'version': kThemePackVersion,
        'id': id,
        'name': name,
        'brightness': brightness.name,
        'colors': {
          'background': _hex(palette.background),
          'surface': _hex(palette.card),
          'foreground': _hex(palette.foreground),
          'mutedForeground': _hex(palette.mutedForeground),
          'primary': _hex(palette.primary),
          'onPrimary': _hex(palette.primaryForeground),
          'secondary': _hex(palette.secondary),
          'border': _hex(palette.border),
          'error': _hex(palette.error),
        },
        if (radius != null) 'radius': radius,
        if (borderWidth != null) 'borderWidth': borderWidth,
        if (dividerThickness != null) 'dividerThickness': dividerThickness,
        if (buttonPadding != null)
          'buttonPadding': {
            'horizontal': buttonPadding!.left,
            'vertical': buttonPadding!.top,
          },
      };

  /// 解析。**任何**非法输入都归一到一份可用的主题包 + 一条警告，
  /// 绝不抛异常 —— 一份坏主题包不该让应用起不来。
  ///
  /// ⚠️ 2026-10-10（CR-09）字段取值**一律走 [_FieldReader]**。
  ///    原来的 `root['radius'] as num?` 这类强转，JSON 里类型一对不上
  ///    就直接抛 TypeError：`parseFile` 不 catch ⇒ `loadAll()` 抛 ⇒
  ///    `current()` 抛 ⇒ **一个坏文件让整个应用起不来**。
  ///    「用户会自己手写 JSON」是这个功能的卖点，那么「写错类型」是常规情况。
  static _Parsed parse(String source, {String? idHint, String? path}) {
    final warnings = <String>[];
    Map<String, Object?> root;
    try {
      final raw = jsonDecode(source);
      if (raw is! Map) {
        return _Parsed(_fallback(idHint, path), ['不是 JSON 对象']);
      }
      root = raw.cast<String, Object?>();
    } catch (e) {
      return _Parsed(_fallback(idHint, path), ['JSON 语法错误：$e']);
    }

    final f = _FieldReader(root, warnings);

    final version = f.number('version')?.toInt() ?? kThemePackVersion;
    if (version > kThemePackVersion) {
      warnings.add('版本 $version 比本应用新（支持到 $kThemePackVersion），'
          '未知的字段已忽略');
    }

    // ⚠️ brightness 的「值不对」（写成 "purple"）与「类型不对」（写成 123）
    //    是两回事，必须分别处理：前者提示后按底色推断，后者同样降级但要
    //    点名说是**类型**不对 —— 否则用户照着提示去改值，改多少都对不上。
    final rawBrightness = f.text('brightness');
    final brightness = switch (rawBrightness?.trim().toLowerCase()) {
      'light' => Brightness.light,
      'dark' => Brightness.dark,
      'system' || null => null,
      // ⚠️ 非空的**非白名单**值（含大小写变体之外的一切）⇒ 按跟随系统处理
      final String v => () {
          warnings.add('未知的 brightness「$v」，按跟随系统处理');
          return null;
        }(),
    };
    // 解析不出明暗就用这份主题的底色亮度来判（深色底 = 深色主题）
    final colors = f.map('colors');
    if (brightness == null && colors != null) {
      final bg = _unhex(colors['background']);
      final b = bg == null
          ? Brightness.dark
          : (bg.computeLuminance() < 0.5 ? Brightness.dark : Brightness.light);
      return _parseWithBrightness(colors, b, warnings, idHint, path, f);
    }
    return _parseWithBrightness(colors, brightness ?? Brightness.dark, warnings,
        idHint, path, f);
  }

  static _Parsed _parseWithBrightness(
    Map<String, Object?>? colors,
    Brightness brightness,
    List<String> warnings,
    String? idHint,
    String? path,
    _FieldReader f,
  ) {
    final base = brightness == Brightness.dark ? AppPalette.dark : AppPalette.light;

    Color? pick(String key, Color fallback) {
      final raw = colors?[key];
      if (raw == null) return null; // 缺字段 = 用默认，不算错
      final c = _unhex(raw);
      if (c == null) {
        warnings.add('颜色字段 $key 的值「$raw」不是合法的 #RRGGBB，'
            '已回落到默认值');
        return null;
      }
      return c;
    }

    final palette = base.copyWith(
      background: pick('background', base.background) ?? base.background,
      card: pick('surface', base.card) ?? base.card,
      foreground: pick('foreground', base.foreground) ?? base.foreground,
      mutedForeground: pick('mutedForeground', base.mutedForeground) ??
          base.mutedForeground,
      primary: pick('primary', base.primary) ?? base.primary,
      primaryForeground: pick('onPrimary', base.primaryForeground) ??
          base.primaryForeground,
      secondary: pick('secondary', base.secondary) ?? base.secondary,
      border: pick('border', base.border) ?? base.border,
      error: pick('error', base.error) ?? base.error,
    );

    final radius = f.number('radius')?.toDouble();
    if (radius != null && (radius < 0 || radius > 40)) {
      warnings.add('radius=$radius 超出合理范围 [0,40]，已忽略');
    }

    /*
     * ★ 2026-10-16：两个「设计语言」维度的取值。
     *
     * # 为什么也走 _FieldReader + 范围校验（与 radius 同一套纪律）
     * ```text
     * borderWidth: 3.5   ⇒ 描边比卡片还厚，界面变成一坨
     * borderWidth: -1    ⇒ 负宽度会让 paint 抛断言
     * borderWidth: 1e9   ⇒ 整屏被描边填满
     * ```
     * 都是**用户手写 JSON 时会真的写出来**的值（这个功能的卖点就是让用户手写），
     * 所以必须与 radius 一样：超范围 ⇒ 忽略 + 点名警告，绝不带进渲染层。
     * 合法上界取 6：新粗野主义用到 3 已经非常重，6 是「再厚就不叫 UI」的边界。
     */
    final borderWidth = f.number('borderWidth')?.toDouble();
    if (borderWidth != null && (borderWidth < 0 || borderWidth > 6)) {
      warnings.add('borderWidth=$borderWidth 超出合理范围 [0,6]，已忽略');
    }
    final dividerThickness = f.number('dividerThickness')?.toDouble();
    if (dividerThickness != null &&
        (dividerThickness < 0 || dividerThickness > 6)) {
      warnings.add('dividerThickness=$dividerThickness 超出合理范围 [0,6]，已忽略');
    }

    EdgeInsets? pad;
    final bp = f.map('buttonPadding');
    if (bp != null) {
      // ⚠️ buttonPadding 内部的 horizontal/vertical 也可能是任意类型
      //    （{"buttonPadding":{"horizontal":"wide"}}），所以走同一个取值器。
      final h = f.sub(bp, 'horizontal');
      final v = f.sub(bp, 'vertical');
      if (h != null && v != null && h >= 0 && v >= 0 && h < 80 && v < 40) {
        pad = EdgeInsets.symmetric(horizontal: h, vertical: v);
      } else {
        warnings.add('buttonPadding 缺失或超出范围，已忽略');
      }
    }

    return _Parsed(
      ThemePack(
        // ⚠️ id/name 不再强转：类型错 ⇒ 走兜底值，并在上面已记过一条警告。
        id: _nonBlank(f.text('id')) ?? (idHint ?? 'imported'),
        name: _nonBlank(f.text('name')) ?? '导入的主题',
        brightness: brightness,
        palette: palette,
        radius: (radius != null && radius >= 0 && radius <= 40) ? radius : null,
        buttonPadding: pad,
        borderWidth:
            (borderWidth != null && borderWidth >= 0 && borderWidth <= 6)
                ? borderWidth
                : null,
        dividerThickness: (dividerThickness != null &&
                dividerThickness >= 0 &&
                dividerThickness <= 6)
            ? dividerThickness
            : null,
        sourcePath: path,
      ),
      warnings,
    );
  }

  /// trim 后非空的字符串（`null` / 空串 / 全空格都算「没有」）
  static String? _nonBlank(String? v) {
    final t = v?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }


  static ThemePack _fallback(String? idHint, String? path) => ThemePack(
        id: idHint ?? 'imported',
        name: '导入的主题',
        brightness: Brightness.dark,
        palette: AppPalette.dark,
        sourcePath: path,
      );

  static String _hex(Color c) =>
      '#${(c.a >= 0.999 ? c.toARGB32() : c.withValues(alpha: 1).toARGB32())
          .toRadixString(16)
          .padLeft(8, '0')
          .substring(2)}';

  static Color? _unhex(Object? v) {
    if (v is! String) return null;
    var s = v.trim().replaceFirst('#', '');
    if (s.length == 6) s = 'ff$s';
    if (s.length != 8) return null;
    final n = int.tryParse(s, radix: 16);
    return n == null ? null : Color(n);
  }

  ThemePack copyWith({
    String? id,
    String? name,
    Brightness? brightness,
    AppPalette? palette,
    double? radius,
    EdgeInsets? buttonPadding,
    double? borderWidth,
    double? dividerThickness,
    bool? builtin,
    String? sourcePath,
  }) =>
      ThemePack(
        id: id ?? this.id,
        name: name ?? this.name,
        brightness: brightness ?? this.brightness,
        palette: palette ?? this.palette,
        radius: radius ?? this.radius,
        buttonPadding: buttonPadding ?? this.buttonPadding,
        borderWidth: borderWidth ?? this.borderWidth,
        dividerThickness: dividerThickness ?? this.dividerThickness,
        builtin: builtin ?? this.builtin,
        sourcePath: sourcePath ?? this.sourcePath,
      );
}

/// 类型安全的字段取值器（CR-09）
///
/// ★ 存在的唯一理由：**类型不对不许抛，要点名降级**。
///   ```dart
///   final v = f.number('radius');   // {"radius":"10"} ⇒ null + 一条警告
///   ```
///   三条规则：
///   1. 字段缺失（`null`）⇒ 返回 `null`，**不记警告** —— 缺字段不是错误；
///   2. 类型对不上 ⇒ 记一条「字段 X 类型不对（T），已忽略」并返回 `null`；
///   3. 每次取值只记**一次**警告（同一个 key 重复取值不刷屏）。
///
/// ⚠️ 边界：`bool` 在 Dart 里不是 `num`，所以 `{"version":true}` 会降级；
///    而 `int`/`double` 都 `is num` ⇒ `{"radius":10}` 与 `{"radius":10.5}` 都合法。
class _FieldReader {
  _FieldReader(this._root, this._warnings);

  final Map<String, Object?> _root;
  final List<String> _warnings;
  final Set<String> _warned = <String>{};

  /// 读 [key] 并按 [T] 校验；类型不对 ⇒ 警告 + `null`。
  T? take<T>(Map<String, Object?> from, String key) {
    final v = from[key];
    if (v == null || v is T) return v as T?;
    _warn(key, v);
    return null;
  }

  double? number(String key) => take<num>(_root, key)?.toDouble();

  String? text(String key) => take<String>(_root, key);

  /// JSON 对象。
  ///
  /// ⚠️ 这里**不用** `v.cast<String, Object?>()`：那个 cast 返回的是**惰性**视图，
  ///    转换失败要等到后面 `colors['background']` 真读的那一刻才抛 ——
  ///    正好把 CR-09 那个 TypeError 推迟到了更远、更难查的地方。
  ///    所以改成**当场遍历**复制一份，key 不是 String 就整体当类型错降级。
  Map<String, Object?>? map(String key) {
    final v = take<Map>(_root, key);
    if (v == null) return null;
    if (v is Map<String, Object?>) return v;
    final out = <String, Object?>{};
    for (final e in v.entries) {
      if (e.key is! String) {
        // JSON 解出来的对象 key 一定是 String，走不到这里；
        // 但 `parse` 也可能被直接喂一个 Map（内部调用），所以按类型错兜住。
        _warn(key, v);
        return null;
      }
      out[e.key as String] = e.value;
    }
    return out;
  }

  /// 从**子对象**里取值（buttonPadding.horizontal 等）
  double? sub(Map<String, Object?> from, String key) =>
      take<num>(from, key)?.toDouble();

  void _warn(String key, Object? v) {
    if (!_warned.add(key)) return; // 同一字段只提示一次
    _warnings.add('字段 $key 类型不对（${v.runtimeType}），已忽略');
  }
}

class _Parsed {
  const _Parsed(this.pack, this.warnings);
  final ThemePack pack;
  final List<String> warnings;
}

/// 主题包的解析结果 + 警告（给 UI 提示用）
class ThemePackResult {
  const ThemePackResult(this.pack, this.warnings);
  final ThemePack pack;
  final List<String> warnings;
}

/// 主题包的存取
abstract final class ThemePackStore {
  /// 存储键（当前选中的主题包 id）
  static const storageKey = 'dsh.themepack';

  static final _rev = ValueNotifier<int>(0);

  /// 任何写入后自增，UI 监听它刷新
  static ValueNotifier<int> get revision => _rev;

  static String? _injectedDataDir;

  /// 由 `shell.dart` 在启动时用 `ClipDownload.dataDir()` 注入一次。
  ///
  /// ⚠️ 为什么不能直接在这里 `await`：主题页可能在数据目录解析完成前
  ///   就被打开（保活的 tab 页），而 `loadAll()` 是**同步**的。
  ///   拿不到就回落到 [_fallbackDataDir]，最坏结果是"主题包列表为空"，
  ///   内置主题仍然全都在 —— 不会让应用起不来。
  static void debugSetDataDir(String? dir) => _injectedDataDir = dir;

  static String get _root => _injectedDataDir ?? _fallbackDataDir;

  /// 同步回落：只覆盖 `--dart-define` 与桌面 `%APPDATA%` 两条路径
  /// （与 `core/clip_download.dart` 的 `dataDir()` 同源，只是不 await）。
  static String get _fallbackDataDir {
    const override = String.fromEnvironment('DATA_DIR_OVERRIDE');
    if (override.isNotEmpty) return override;
    final appdata = Platform.environment['APPDATA'] ??
        Platform.environment['HOME'] ??
        '.';
    return '$appdata${Platform.pathSeparator}app.sourin.player';
  }

  /// 主题包目录：`<数据目录>/themes`
  ///
  /// ⚠️ 绝不能落到用户的真实视频目录 —— 一律跟着应用数据目录走。
  static Directory get dir {
    final d = Directory('$_root${Platform.pathSeparator}themes');
    if (!d.existsSync()) {
      try {
        d.createSync(recursive: true);
      } catch (_) {
        // 建不出来（只读介质）→ 导入功能降级，内置主题仍然可用
      }
    }
    return d;
  }

  static List<ThemePack> loadAll() {
    final out = <ThemePack>[...builtins];
    for (final f in _listPackFiles()) {
      final r = parseFile(f);
      // ★ 解析不出来的**不进列表**。
      //   为什么不是"降级也要显示"：主题页的卡片网格里出现一张
      //   名为「导入的主题」、配色全是默认值的卡片，用户完全不知道
      //   自己哪个文件坏了 —— 那种"静默降级"比"明确不显示"更糟。
      //   （手动导入时仍会降级并提示，见 [importFromString]。）
      if (r == null) {
        debugPrint('[THEME] 跳过读不出主题包的文件：${f.path}');
        continue;
      }
      out.add(r.pack);
    }
    return out;
  }

  static List<File> _listPackFiles() {
    try {
      return dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.json'))
          .toList();
    } catch (_) {
      // 目录不存在 / 不可枚举 —— 只用内置主题，不让应用起不来
      return const [];
    }
  }

  /// 读一个主题包文件。
  ///
  /// 返回 `null` = **这个文件不是可用的主题包**（读不了 / 语法错误 / 空）。
  /// 缺字段、非法颜色值那种「局部有问题」仍会降级并带上警告 ——
  /// 那是可用但要提示，与「完全读不懂」是两回事。
  static ThemePackResult? parseFile(File f) {
    final String src;
    try {
      src = f.readAsStringSync();
    } catch (_) {
      return null;
    }
    if (src.trim().isEmpty) return null;
    final parsed = ThemePack.parse(src, idHint: _idOfPath(f.path), path: f.path);
    // 语法 / 结构层面失败 -> 当作「不是主题包」
    if (parsed.warnings.any((w) =>
        w.contains('JSON 语法错误') || w.contains('不是 JSON 对象'))) {
      return null;
    }
    return ThemePackResult(parsed.pack, parsed.warnings);
  }

  /// 从字符串导入（设置页的「粘贴 JSON」入口）
  static ThemePackResult importFromString(String source,
      {String idHint = 'imported'}) {
    final p = ThemePack.parse(source, idHint: idHint);
    return ThemePackResult(p.pack, p.warnings);
  }

  /// 从文件导入 —— 会**落盘**到 [dir]
  ///
  /// ⚠️ 参数是 [XFile] 而不是 `File`：文件选择器返回的就是 `XFile`
  ///    （跨平台、且在 Web 上没有 `File`）。
  static ThemePackResult importFromFile(XFile src) {
    final id = _idOfPath(src.path);
    final r = importFromString(_readOrEmpty(src), idHint: id);
    final target = File('${dir.path}${Platform.pathSeparator}$id.json');
    try {
      target.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(r.pack.toJson()));
      _rev.value++;
    } catch (_) {
      // 落盘失败不致命：至少这一轮能看见（用户可能想立刻切过去）
    }
    return ThemePackResult(r.pack.copyWith(sourcePath: target.path), r.warnings);
  }

  /// 删除一个外部主题包（内置的不可删）
  static bool delete(ThemePack pack) {
    if (pack.builtin || pack.sourcePath == null) return false;
    try {
      File(pack.sourcePath!).deleteSync();
      if (selectedId == pack.id) {
        UiPrefs.remove(storageKey);
        _rev.value++;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 从文件路径取出主题包 id（= 文件名去扩展名）
  ///
  /// ⚠️ 必须自己按分隔符切，**不能**用 `f.uri.pathSegments`：
  ///    `File('C:<BS>Users<BS>x<BS>ok.json').uri` 在 Windows 上解析不出 scheme，
  ///    `pathSegments.last` 会返回**整条路径**（实测），于是 id 变成一个
  ///    含反斜杠的巨型字符串 —— 表现是「导入后在列表里找不到它」。
  static String _idOfPath(String path) {
    // ⚠️ 这里**刻意不用正则**。两种朴素写法都会踩坑：
    // ```dart
    // path.split(RegExp(r'[/\]'))   // 非法字符类：\] 被当成转义右括号
    //                               // ⇒ FormatException: Unterminated character class
    // path.split('/')                // Windows 的路径里一个都不匹配 ⇒ last 是整条路径
    // ```
    // 而 `File.uri.pathSegments` 在 Windows 上同样不给力（见上面那段）。
    // ⇒ 直接按 `Platform` 声明的分隔符切，两个平台的都对。
    final sep = Platform.pathSeparator;
    var base = path;
    final i = base.lastIndexOf(sep);
    if (i >= 0) base = base.substring(i + 1);
    final dot = base.lastIndexOf('.');
    final id = (dot > 0 ? base.substring(0, dot) : base).trim();
    return id.isEmpty ? 'imported' : id;
  }

  static String _readOrEmpty(XFile f) {
    // ⚠️ `readAsStringSync` 在 XFile 上不存在；统一走 path 拿 File。
    //    读不到就返回空串 —— 解析层会给出"JSON 语法错误"的警告并降级。
    try {
      return File(f.path).readAsStringSync();
    } catch (_) {
      return '';
    }
  }

  /// 当前选中的主题包 id
  static String get selectedId => UiPrefs.get(storageKey) ?? '';

  static void select(String id) {
    UiPrefs.set(storageKey, id);
    _rev.value++;
  }

  /// 当前生效的主题包（找不到就回落第一套内置的）
  static ThemePack current() {
    final all = loadAll();
    final id = selectedId;
    for (final p in all) {
      if (p.id == id) return p;
    }
    return all.first;
  }

  // ── 内置主题 ────────────────────────────────────────────────────────────
  //
  // 每套都按 WCAG 调过（见 theme_invariants_test.dart 的对比度断言）。
  // 命名用**用户能懂**的说法，不是色号。

  static ThemePack _dark(
    String id,
    String name,
    AppPalette p, {
    String? familyId,
    double? radius,
    double? borderWidth,
    double? dividerThickness,
    EdgeInsets? buttonPadding,
  }) =>
      ThemePack(
      familyId: familyId,
        id: id,
        name: name,
        brightness: Brightness.dark,
        palette: p,
        radius: radius,
        borderWidth: borderWidth,
        dividerThickness: dividerThickness,
        buttonPadding: buttonPadding,
        builtin: true,
      );

  static ThemePack _light(
    String id,
    String name,
    AppPalette p, {
    String? familyId,
    double? radius,
    double? borderWidth,
    double? dividerThickness,
    EdgeInsets? buttonPadding,
  }) =>
      ThemePack(
      familyId: familyId,
        id: id,
        name: name,
        brightness: Brightness.light,
        palette: p,
        radius: radius,
        borderWidth: borderWidth,
        dividerThickness: dividerThickness,
        buttonPadding: buttonPadding,
        builtin: true,
      );

  // ── 三套「设计语言」主题（2026-10-16 · Owner 第 14 条）────────────────────
  //
  // ⚠️ 与上面 6 套的**性质不同**：那 6 套是「同一个 App 换配色」
  //    （圆角/描边/按钮几何全是默认值），这三套要的是
  //    **看起来像三个不同的 App**。所以每套同时给出四个维度：
  //    ```text
  //    配色      background / card / primary …      ← 颜色
  //    radius    圆角：22 胶囊 / 0 直角 / 4 克制     ← 形状
  //    borderWidth      1 细线 / 2.5 硬边 / 1 发丝   ← 边缘语言
  //    dividerThickness 1 / 3 / 1                    ← 排版语言
  //    buttonPadding    松 / 厚重 / 紧               ← 控件手感
  //    ```
  //    ★ 只换颜色做不到「像另一个 App」—— 直角 vs 胶囊的差别比配色大得多。
  //
  // 三套的**对比度全部按 WCAG 算过**（正文 ≥4.5、次要 ≥3、按钮 ≥4.5、
  // 描边合成后在 (1.10, 3.0)、卡片底在 (1.02, 3.0)），
  // 由 `theme_pack_test.dart` 的「③ 内置主题的对比度」与
  // `theme_regression_test.dart` 守着。

  /// ① 液态玻璃 —— 深色，半透明感 + 冷蓝光晕 + 大圆角胶囊
  ///
  /// # 设计语言
  /// ```text
  /// 底色   近黑蓝（#0B0E14）—— 不是纯黑，留出"玻璃底下有东西"的余地
  /// 卡片   比底色亮 1.35:1 的蓝灰 + 冷色描边 ⇒ 读起来像一层"浮起来的玻璃"
  /// 主色   冰蓝 #7FB2FF（唯一的高饱和色，只用在选中/强调）
  /// 形状   圆角 22（胶囊级）+ 1px 细描边 ⇒ 圆润、轻、没有硬边
  /// 按钮   内边距松（16/12）⇒ 呼吸感
  /// ```
  /// ⚠️ 本主题**不依赖** `liquid_glass_widgets` 的运行时模糊 ——
  ///    它是一套**配色+形状**语言，在没有 shader 的环境（测试/旧显卡）下
  ///    仍然是同一套观感；真正的玻璃折射由标题栏/底栏那两处 GlassContainer 给。
  static final AppPalette _glassPalette = AppPalette.dark.copyWith(
    background: const Color(0xFF0B0E14),
    card: const Color(0xFF232A3A),
    foreground: const Color(0xFFF2F5FA),
    mutedForeground: const Color(0xFF9AA6BF),
    primary: const Color(0xFF7FB2FF),
    primaryForeground: const Color(0xFF06111F),
    secondary: const Color(0xFF1A2130),
    secondaryForeground: const Color(0xFFEAF0FA),
    muted: const Color(0xFF1A2130),
    error: const Color(0xFFFF8A93),
    border: const Color(0xFF405274),
    barrier: const Color(0x7A05070C),
  );

  /// ② 新粗野主义 —— 近黑纸 + 酸性黄 + 2.5px 硬边 + 直角
  ///
  /// # 设计语言
  /// ```text
  /// 底色   暖近黑（#12100E）—— 比"液态玻璃"的冷蓝黑更暖、更"油墨"
  /// 描边   **2.5px 硬边**（#5E5426，合成后 2.5:1）—— 本套的灵魂
  /// 圆角   **0**（直角）—— 与圆角 22 的那套形成最极端的对照
  /// 主色   酸性黄 #FFE24A 压近黑字（14.4:1）—— 高饱和撞色
  /// 按钮   厚重（内边距 18/14 + 2.5px 描边）⇒ 像可点的实体方块
  /// 分隔线 3px ⇒ 区块之间是"印刷分隔条"，不是发丝线
  /// ```
  ///
  /// # ★ 为什么这一套是**深色**而不是"奶油纸浅色"（我改过一次，有理由）
  /// ```text
  /// 我先做的是浅色版（#F2EFE6 奶油纸 + 酸性黄主色）—— 实测截图发现问题：
  /// 本仓的图标色**取的就是 primary**（theme_bridge.dart:194
  ///   iconTheme: IconThemeData(color: c.primary, size: 20)），
  /// 而酸性黄压在奶油纸上只有 **1.13:1** ⇒ 设置页里每个列表项的
  /// 前导图标（palette / play 那一列）几乎看不见。
  /// 那不是"风格"，是**看不见**。
  /// ⇒ 改成深色：酸性黄压近黑是 **14.4:1**，同一套配色语言
  ///   （酸性黄 + 直角 + 硬边 + 厚重按钮）一个都没丢，
  ///   而且与"液态玻璃"的差异反而更大（暖黑 vs 冷蓝黑）。
  /// ```
  /// ⚠️ 主色是**亮黄**，所以 `primaryForeground` 必须是近黑（#141210）——
  ///    写成白字会得到 1.22:1 的"黄底白字"（本仓踩过的同类坑）。
  static final AppPalette _brutalPalette = AppPalette.dark.copyWith(
    background: const Color(0xFF12100E),
    card: const Color(0xFF1E1B16),
    foreground: const Color(0xFFFFF8E7),
    mutedForeground: const Color(0xFFC9BFA6),
    primary: const Color(0xFFFFE24A),
    primaryForeground: const Color(0xFF141210),
    secondary: const Color(0xFF2A2620),
    secondaryForeground: const Color(0xFFFFF8E7),
    muted: const Color(0xFF2A2620),
    error: const Color(0xFFFF6B57),
    /*
     * ★ 2026-10-17：border 从 #5E5426 改成 #F2E9C8（奶油白）
     *
     * # 为什么改
     * ```text
     * 旧值 #5E5426（暗橄榄）压在 #12100E 近黑底上 = **2.51:1**。
     * 配上 2.5px 粗描边，正好落在我新写的门禁所禁止的「灰色中间地带」——
     * 既不是「细而低调」（<2px），也不是「粗而强硬」（>=2px 且 >=10:1）。
     * 渲染出来是深色版也会有的「灰框表格感」。
     * ```
     *
     * # 为什么改成奶油白而不是别的
     * ```text
     * 粗野主义的硬边在**深底上就该是浅色**（与浅色版「白底黑边」互为镜像）。
     * #F2E9C8 对 #12100E = **15.61:1** ✓，且是暖色，与整套的暖调（酸黄主色）
     * 同族，不会像纯白那样冷硬突兀。
     * ```
     *
     * ⚠️ 这个值是 dlg-source 改门禁时**顺带发现的**：旧门禁放行 2.51
     *    （它只要求 1.10 < r < 3.0），所以深色版一直绿着，没人看出问题。
     */
    border: const Color(0xFFF2E9C8),
    barrier: const Color(0x80000000),
  );

  /// ③ 极简留白 —— 暖白纸 + 墨绿单色 + 发丝线
  ///
  /// # 设计语言
  /// ```text
  /// 底色   暖白（#FAFAF8）—— 比纯白少一点屏幕感
  /// 卡片   **纯白**（1.045:1）—— 与底色的差小到"只是一层纸"，靠 1px 发丝线分界
  /// 主色   墨绿 #3D5A4C —— 低饱和、单色系，全站只有这一个强调色
  /// 形状   圆角 **4**（近乎直角但留一点）—— 克制，不圆润也不锋利
  /// 描边   1px #DEDDD6（1.30:1）—— 看得见但几乎不占视觉重量
  /// 按钮   紧（内边距 12/10）⇒ 安静、不抢视线
  /// ```
  /// ★ 与「新粗野主义」**没有任何一个维度相同**：
  ///    明暗 light vs dark、底色暖白 vs 暖近黑、主色墨绿 vs 酸性黄、圆角 4 vs 0、
  ///    描边 1px vs 2.5px、按钮紧 vs 厚重、分隔线 1px vs 3px。
  ///
  /// ⚠️ 2026-10-17（CodeRabbit CR）：上面这行原写「共用浅色档」，
  ///   那是**旧设计**的描述 —— 「新粗野主义」后来改成了**深色**
  ///   （原因：酸黄配奶油只有 1.13:1，列表行图标几乎不可见；
  ///    酸黄配近黑是 14.4:1）。本仓注释承担记录设计决策的职责，
  ///   过期描述会误导后续修改，故修正。
  /// ⚠️ 极简留白的底色是**故意走「明度更低」而不是「加饱和」**（不是漏改）
  ///
  /// ```text
  /// HSV 实测：饱和 3.4%（低于「有彩色」的 8% 门槛），明度 91.0%。
  /// 与基线 EEF0F6（s=3.3% v=96.5%）比：明度差 5.5%。
  ///
  /// 为什么不加饱和去凑 8%：
  ///   本主题的语义就是「极简 / 留白 / 一个墨绿强调色，其余全中性」。
  ///   给底色加饱和就成了「淡彩主题」，与「极简」自相矛盾。
  /// ⇒ 用明度区分：把底压到 91%，比默认更「沉」一点，卡片压白浮起来。
  ///   这正是纸白/留白的表达方式，也符合「不谈颜色、只谈明暗层次」的语义。
  ///
  /// 门禁 `zz_t68_theme_distinction_test.dart` 对此是**合法通过**：
  ///   饱和 < 8% ⇒ 走「无彩色」判据 ⇒ 只要明度差 >= 3% 即可。
  ///   实测 5.5% >= 3%，通过。
  /// ```
  static final AppPalette _minimalPalette = AppPalette.light.copyWith(
    background: const Color(0xFFE5E8E0),
    card: const Color(0xFFFFFFFF),
    foreground: const Color(0xFF22252A),
    // ★ 2026-10-17 加深底色后必须同步加深：
    //   原 #6E737C 对新底 #E5E8E0 只有 3.85:1（低于 AA 4.5）
    //   ⇒ 改 #55585C = 5.77:1，仍是同一冷调灰，只是深一档
    mutedForeground: const Color(0xFF55585C),
    primary: const Color(0xFF3D5A4C),
    primaryForeground: const Color(0xFFF7F9F7),
    secondary: const Color(0xFFF0F0EC),
    secondaryForeground: const Color(0xFF22252A),
    muted: const Color(0xFFF0F0EC),
    error: const Color(0xFFA83A2E),
    border: const Color(0xFFCDCDC4),
    barrier: const Color(0x40000000),
  );

  /*
   * ══════════════════════════════════════════════════════════════════
   *  task-31 / 11-C：加深 6 套浅色主题的底色（Owner 2026-10-17 选 A）
   * ══════════════════════════════════════════════════════════════════
   *
   * # 为什么
   * ```text
   * 真机像素采样（Lead，1444x845）发现 8 套浅色底彼此太近：
   *   液态玻璃·浅 7.5 / 新粗野·浅 6.0 / 深海蓝·浅 11.0 / 森绿·浅 11.7
   *   （RGB 欧氏距离，满量程 441）
   * ⇒ 用户把 8 套摆一起分不出是哪套 ⇒ 「主题」功能名存实亡。
   * ```
   *
   * # 判据（test/zz_t68_theme_distinction_test.dart 守着）
   * ```text
   * ① 每套 vs 默认基线 EEF0F6  >= 20
   * ② 任意两套彼此            >= 15
   * ③ 正文 vs 底              >= 4.5（WCAG AA，theme_invariants 守着）
   * ```
   *
   * # ★ 一个反直觉的实测结论：这条阈值比想象中难达到
   * ```text
   * 我最初以为「浅色区间」很宽，可以随便拉开 20。实测不是：
   *   · L* >= 92（仍是浅色）+ 正文 CR>=4.5 的可行域里，
   *     8 点（含固定的 BASE 与 WHITE）最大最小间距 ≈ 24.4，
   *     而 BASE↔WHITE 本身就占掉 24.4 ⇒ 其余 6 点必须挤进这条带。
   *   · 更关键：RGB 欧氏距离**奖励高饱和**（黄/青最远），
   *     所以纯数学最优解会给出 #FBF22E 这种荧光黄 —— 语义上不能接受。
   * ⇒ 必须先按语义限定每个主题的色相窗口，再在窗口内优化。
   * ```
   *
   * # 最终取值与实测
   * ```text
   * 主题          改前      改后      距离(vs基线)  正文CR
   * 樱粉·浅       FDF6F7    F9DDDF    31.8          12.03
   * 森绿·浅       F4FAF6    D7F4DF    32.8          13.10
   * 深海蓝·浅     F4F7FC    C9E4F7    38.9          11.66
   * 液态玻璃·浅   F2F5FA    DFDFEC    24.8          11.64
   * 新粗野·浅     F2F2F2    F7F3E3    21.2          13.82
   * 极简留白      FAFAF8    E5E8E0    25.1          12.41
   * ```
   * 最小两两距离 = 15.3（玻璃 vs 极简），满足 >=15。
   *
   * # 不改的 2 套（有理由，不是漏了）
   * ```text
   * · builtin.daylight  —— 它就是默认基线 EEF0F6 本身。
   *   加深会让「没选包」与「选了日间」变成两种颜色，用户会困惑。
   *   ⇒ 门禁里显式排除它。
   * · builtin.oled.light —— 纯白 FFFFFF，与基线已有 24.4，本就达标。
   *   且「OLED 纯黑」的浅色版语义上就该是纯白（纯黑/纯白对照）。
   * ```
   *
   * # ⚠️ 加深底色的连带影响（我踩到了）
   * ```text
   * 底色变深 ⇒ 次要文字对比度下降。
   * 极简留白的 mutedForeground #6E737C 对新底只有 3.85:1（原 4.56）
   * ⇒ 已同步加深到 #55585C = 5.77:1。
   * 其余 5 套的 #5F5F5F 仍在 4.84~5.44，未破线。
   * ```
   */
  /// 内置主题清单
  ///
  /// ⚠️ 顺序 = 主题页的展示顺序，第一套是**默认值**。
  /*
   * ══════════════════════════════════════════════════════════════════
   *  双色主题的浅色版 palette（Owner 2026-10-17 第 11-A 条）
   * ══════════════════════════════════════════════════════════════════
   *
   * # 设计原则（为什么不是"把深色反色"）
   * ```text
   * ① 主色**保持一致** —— 樱粉的粉、森绿的绿、深海蓝的蓝
   *    ⇒ 系统切明暗时品牌色不能跳，否则用户会觉得"换了个 App"
   *
   * ② 背景/卡片/边框按**浅色体系**重算，不是取反
   *    ⇒ 浅色下需要的是"纸白 + 极淡的色相偏移"，而不是"深色的补色"
   *
   * ③ 对比度必须够：正文 vs 背景 >= 4.5:1（WCAG AA）
   *    ⇒ 每套都按这个下限选色，不为了"氛围"牺牲可读性
   * ```
   */

  /// OLED 纯黑的浅色版 —— "高对比纸白"
  ///
  /// OLED 深色的卖点是纯黑省电；浅色版没有那个意义，
  /// 所以做成**同一设计语言**（极简、高对比）的纸白实现。
  static final AppPalette _oledLight = AppPalette.light.copyWith(
    background: const Color(0xFFFFFFFF),
    card: const Color(0xFFFAFAFA),
    secondary: const Color(0xFFF0F0F0),
    muted: const Color(0xFFF0F0F0),
    border: const Color(0xFFD0D0D0),
    foreground: const Color(0xFF000000),
    mutedForeground: const Color(0xFF5A5A5A),
  );

  /// 深海蓝的浅色版 —— 冷调纸白
  static final AppPalette _midnightBlueLight = AppPalette.light.copyWith(
    background: const Color(0xFFC9E4F7),
    card: const Color(0xFFFFFFFF),
    secondary: const Color(0xFFDCEAFB),
    muted: const Color(0xFFDCEAFB),
    border: const Color(0xFFAFC6E0),
    primary: const Color(0xFF1E4C8A),
    primaryForeground: const Color(0xFFFFFFFF),
    // ★ 必须显式覆盖（dlg-source 视觉验证发现，2026-10-17）
    //   不覆盖会继承 AppPalette.light 的默认 #737373，
    //   而本主题背景 #F4F7FC 比纯白更亮 ⇒ 对比度掉到 4.42（低于 AA 4.5）
    mutedForeground: const Color(0xFF5F5F5F),
  );

  /// 樱粉的浅色版 —— 暖粉纸白
  ///
  /// ⚠️ 主色从深色版的 #F2B8C6（浅粉，因为压在深底上）**换成** #C2567A
  ///    （深粉），因为浅底上浅粉看不清。这是"同一色相不同明度"，
  ///    不是"换了颜色"。
  static final AppPalette _sakuraLight = AppPalette.light.copyWith(
    background: const Color(0xFFF2C7CF),
    card: const Color(0xFFFFFFFF),
    secondary: const Color(0xFFEFCBD5),
    muted: const Color(0xFFEFCBD5),
    border: const Color(0xFFDFB6C1),
    /*
     * ★ 2026-10-17 樱粉·浅的两次修正
     *
     * # 第一次（Lead，被 WCAG 门禁抓出）
     * ```text
     * 原 #C2567A 配白字 = 4.28:1（低于 4.5）
     * ⇒ 改成 #A8435F = 5.78:1
     * ```
     *
     * # 第二次（dlg-source 视觉验证发现第一次改错了方向）
     * ```text
     * 它逐张看过图后说："确实偏酒红，已经不是粉，是干枯玫瑰/酒红"
     * 数据：#A8435F = 168/67/95，明度 L≈46% —— 太深了
     *
     * ★ 关键洞察：不该"加深主色去配白字"，而该"用浅粉配深字"。
     *   深色版 #F2B8C6 配深字 = 10.50，走的正是"浅粉+深字"这条路。
     *   现在这版是「深底用浅粉、浅底用深粉」⇒ 逻辑反而是相反的。
     * ```
     *
     * ⇒ 改成 #E38AA6 + primaryForeground = #231419
     *   对深字 7.13:1 ✓，而且**真的是粉**
     */
    primary: const Color(0xFFE38AA6),
    primaryForeground: const Color(0xFF231419),
    error: const Color(0xFFC62828),
    // ★ 同 midnightBlue：必须显式覆盖，否则继承默认 #737373 只有 4.45
    // ★ 2026-10-17 加深底色到 #F2C7CF 后，#5F5F5F 只有 4.21（低于 AA）
    //   ⇒ 加深到 #585858 = 4.69，仍是中性灰
    mutedForeground: const Color(0xFF585858),
  );

  /// 森绿的浅色版 —— 淡绿纸白
  static final AppPalette _forestLight = AppPalette.light.copyWith(
    background: const Color(0xFFD7F4DF),
    card: const Color(0xFFFFFFFF),
    secondary: const Color(0xFFC9E7D3),
    muted: const Color(0xFFC9E7D3),
    border: const Color(0xFFC8DFD0),
    primary: const Color(0xFF2E7D4F),
    primaryForeground: const Color(0xFFFFFFFF),
    error: const Color(0xFFC62828),
    // ★ 必须显式覆盖：否则继承 #737373，对 #F4FAF6 只有 4.48（低于 4.5）
    mutedForeground: const Color(0xFF5F5F5F),
  );

  /// 液态玻璃的浅色版
  ///
  /// 玻璃的关键是"半透明层叠"，浅色下用**极淡的蓝灰**表达那层雾。
  static final AppPalette _glassLightPalette = AppPalette.light.copyWith(
    background: const Color(0xFFE2DBF6),
    card: const Color(0xF5FFFFFF),
    secondary: const Color(0xFFEFEBFB),
    muted: const Color(0xFFEFEBFB),
    border: const Color(0xFFCCC4E4),
    primary: const Color(0xFF3B6FE0),
    primaryForeground: const Color(0xFFFFFFFF),
    // ★ 必须显式覆盖：否则继承 #737373，对 #F2F5FA 只有 4.34（最低的一套）
    mutedForeground: const Color(0xFF5F5F5F),
  );

  /// 新粗野主义的浅色版
  ///
  /// 粗野主义的核心是"硬边、高对比、无阴影"。
  /// 浅色下用**纯白 + 纯黑边框**，不用灰——灰会削弱那个"硬"。
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ⚠️ 2026-10-17 两次修正，第二次是**把第一次改回原样**
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// # ① card 与 background 都是 #FFFFFF ⇒ 卡片对比 1.00 ⇒ 卡片"消失"
  /// ```text
  /// （门禁要求 >1.02）
  /// ⇒ background 改成 #F2F2F2，card 保持 #FFFFFF ⇒ 卡片浮出来
  /// ```
  ///
  /// # ② border：纯黑 → #999999 → **改回纯黑**
  /// ```text
  /// 第一版：纯黑 #000000 ⇒ 对白底 21:1
  ///         ⇒ 被旧门禁「描边必须 <3:1」判红
  /// 第二版：改成 #999999 ⇒ 2.85:1（过旧门禁）
  ///         ⇒ 但 dlg-source 看图后指出：「不够硬，问题不在颜色，
  ///            在硬边被门禁逼没了」；渲染出来是「灰色表格框」，
  ///            既不像粗野主义也不像现代 App。
  /// 第三版（现在）：改回纯黑 #000000，并把**门禁判据本身**改成二选一
  ///         ⇒ 见 theme_pack_test「描边必须落在两档之一」那条注释。
  /// ```
  ///
  /// ★ 教训：这次不是"主题配错了"，是"门禁假设了所有主题都是细描边"。
  ///   当一个设计语言的**语义**与门禁的**假设**冲突时，该改的是门禁，
  ///   而不是把主题拧成门禁喜欢的样子 —— 后者只会得到妥协产物。
  static final AppPalette _brutalLightPalette = AppPalette.light.copyWith(
    background: const Color(0xFFF7F3E3),
    card: const Color(0xFFFFFFFF),
    secondary: const Color(0xFFEFEADC),
    muted: const Color(0xFFEFEADC),
    border: const Color(0xFF000000),
    foreground: const Color(0xFF000000),
    mutedForeground: const Color(0xFF3A3A3A),
    primary: const Color(0xFF000000),
    primaryForeground: const Color(0xFFFFFFFF),
  );

  /// 极简留白的深色版
  ///
  /// 极简的关键是"无阴影、细边框、小圆角"。深色下保持这个骨架，
  /// 只把色板换成深底浅字。
  static final AppPalette _minimalDarkPalette = AppPalette.dark.copyWith(
    background: const Color(0xFF16161A),
    card: const Color(0xFF1E1E23),
    secondary: const Color(0xFF26262C),
    muted: const Color(0xFF26262C),
    border: const Color(0xFF33333A),
  );

  static final List<ThemePack> builtins = [
    /*
     * ══════════════════════════════════════════════════════════════════
     *  ★ 2026-10-17 Owner 第 11-A 条：**双色主题**
     * ══════════════════════════════════════════════════════════════════
     *
     * Owner 原话：「一个主题同时提供浅色版和深色版两个独立风格」
     *
     * # 改前的问题
     * ```text
     * 9 套主题里 **7 深 2 浅**：
     *   深色：午夜 / OLED / 深海蓝 / 樱粉 / 森绿 / 液态玻璃 / 新粗野
     *   浅色：日间 / 极简留白
     * ⇒ 用户选「樱粉」后，系统切浅色时**没有对应的樱粉浅色版**
     *   ⇒ 只能整站变深（不跟随）或回落到无关的浅色主题（静默换主题）
     * ```
     *
     * # 改法
     * ```text
     * 每套深色主题补一个**同名浅色版**，两者共用 familyId：
     *   familyId = 'sakura'  →  builtin.sakura（深） + builtin.sakura.light（浅）
     *
     * 浅色版不是"把深色反色"，而是**同一设计语言下的浅色实现**：
     *   · 主色保持一致（樱粉的粉、森绿的绿），否则切明暗时品牌色会跳
     *   · 背景/卡片/边框按浅色体系重算
     *   · 圆角/边框宽度等形状参数与深色版**完全一致**（那是设计语言，不是明暗）
     * ```
     *
     * ⚠️ 顺序：浅色版紧跟在深色版**后面**，这样主题页成对显示。
     */

    // ── 午夜 ⇄ 日间（原本就有浅色版，补 familyId 即可）──
    _dark('builtin.midnight', '午夜', AppPalette.dark, familyId: 'midnight'),
    _light('builtin.daylight', '日间', _daylight, familyId: 'midnight'),
    // OLED 纯黑：像素熄灭 ⇒ 深色下的省电与对比最优
    _dark('builtin.oled', 'OLED 纯黑', AppPalette.dark.copyWith(
      background: const Color(0xFF000000),
      card: const Color(0xFF0B0B0B),
      secondary: const Color(0xFF1C1C1C),
      muted: const Color(0xFF1C1C1C),
      border: const Color(0x3DFFFFFF),
    ), familyId: 'oled'),
    // OLED 的浅色版：OLED 的卖点是"纯黑省电"，浅色版没有那个意义，
    // 所以浅色版做成"高对比纸白"——保持同一设计语言（极简、高对比）
    _light('builtin.oled.light', 'OLED 纯黑·浅', _oledLight, familyId: 'oled'),
    // 午夜蓝：给喜欢冷色调的人；正文仍是近白，只有背景偏蓝
    _dark('builtin.midnightBlue', '深海蓝', AppPalette.dark.copyWith(
      background: const Color(0xFF0B1220),
      card: const Color(0xFF141E30),
      secondary: const Color(0xFF1E2C42),
      muted: const Color(0xFF1E2C42),
      border: const Color(0xFF33455F),
    ), familyId: 'midnightBlue'),
    _light('builtin.midnightBlue.light', '深海蓝·浅', _midnightBlueLight,
        familyId: 'midnightBlue'),
    // 樱粉：暖色，强调色偏粉；正文仍用近白（不牺牲对比度换"氛围"）
    _dark('builtin.sakura', '樱粉', AppPalette.dark.copyWith(
      background: const Color(0xFF14100F),
      card: const Color(0xFF20191C),
      secondary: const Color(0xFF2E2429),
      muted: const Color(0xFF2E2429),
      border: const Color(0xFF3A2E35),
      primary: const Color(0xFFF2B8C6),
      primaryForeground: const Color(0xFF231419),
      error: const Color(0xFFFF8A8A),
    ), familyId: 'sakura'),
    _light('builtin.sakura.light', '樱粉·浅', _sakuraLight, familyId: 'sakura'),
    // 森绿：把"主色"从浅灰换成叶绿，于是选中态、开关、滑杆都带上绿色语言
    _dark('builtin.forest', '森绿', AppPalette.dark.copyWith(
      background: const Color(0xFF0A0F0C),
      card: const Color(0xFF121A15),
      secondary: const Color(0xFF1B271F),
      muted: const Color(0xFF1B271F),
      border: const Color(0xFF24332A),
      primary: const Color(0xFF8ED9A8),
      primaryForeground: const Color(0xFF0C1A11),
      error: const Color(0xFFFF9E8A),
    ), familyId: 'forest'),
    _light('builtin.forest.light', '森绿·浅', _forestLight, familyId: 'forest'),

    // 以下三套是「设计语言」主题（Owner 第 14 条，2026-10-16）
    // 与上面 6 套的区别：那 6 套只换颜色，这三套**连形状/边缘/按钮几何
    // 一起换** —— 目标是看起来像三个不同的 App。详见各自 palettes 的文档。
    //
    // 顺序说明：放在最后而不是最前，是为了不动既有 6 套的展示顺序
    // （第一套是默认值，builtin.midnight 必须继续排第一）。
    _dark(
      'builtin.glass',
      '液态玻璃',
      _glassPalette,
      familyId: 'glass',
      radius: 22,
      borderWidth: 1,
      dividerThickness: 1,
      buttonPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    ),
    _light(
      'builtin.glass.light',
      '液态玻璃·浅',
      _glassLightPalette,
      familyId: 'glass',
      radius: 22,
      borderWidth: 1,
      dividerThickness: 1,
      buttonPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    ),
    _dark(
      'builtin.neoBrutal',
      '新粗野主义',
      _brutalPalette,
      familyId: 'neoBrutal',
      radius: 0,
      borderWidth: 2.5,
      dividerThickness: 3,
      buttonPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
    ),
    _light(
      'builtin.neoBrutal.light',
      '新粗野主义·浅',
      _brutalLightPalette,
      familyId: 'neoBrutal',
      radius: 0,
      borderWidth: 2.5,
      dividerThickness: 3,
      buttonPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
    ),
    _light(
      'builtin.minimal',
      '极简留白',
      _minimalPalette,
      familyId: 'minimal',
      radius: 4,
      borderWidth: 1,
      dividerThickness: 1,
      buttonPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    ),
    // 极简的深色兄弟版 —— 与浅色版同一设计语言（无阴影、细边框、小圆角）
    _dark(
      'builtin.minimal.dark',
      '极简留白·深',
      _minimalDarkPalette,
      familyId: 'minimal',
      radius: 4,
      borderWidth: 1,
      dividerThickness: 1,
      buttonPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    ),
  ];

  /*
   * ══════════════════════════════════════════════════════════════════
   *  双色主题 · 按家族找对应明暗版（Owner 2026-10-17 第 11-A 条）
   * ══════════════════════════════════════════════════════════════════
   *
   * # Owner 要的是什么
   * ```text
   * 「一个主题同时提供浅色版和深色版两个独立风格」
   *
   * ⇒ 选「樱粉」后，系统切浅色时应当切到「樱粉·浅」，
   *    而不是整站变深或回落到某个无关的浅色主题。
   * ```
   *
   * # 匹配优先级
   * ```text
   * ① 同 familyId 且明暗匹配的 → 直接用（这就是双色主题的命中路径）
   * ② 同 familyId 但明暗不匹配的 → **没有对应版本**
   *    ⇒ 返回 null，由调用方决定回落策略（**不静默换主题**）
   * ③ familyId 找不到 → null
   * ```
   *
   * ⚠️ 为什么第 ② 条返回 null 而不是"随便找个同明暗的顶上"：
   *    静默换主题会让用户以为"我选的樱粉变成别的了"，
   *    属于本仓一贯禁止的"静默降级"。调用方必须显式决定怎么办。
   */

  /// 在 [all] 里找 [familyId] 家族、明暗为 [brightness] 的那一版。
  ///
  /// 返回 null = 该家族**没有**这一档明暗的版本。
  static ThemePack? findByFamily(
    List<ThemePack> all,
    String familyId,
    Brightness brightness,
  ) {
    for (final p in all) {
      if (p.familyId == familyId && p.brightness == brightness) return p;
    }
    return null;
  }

  /// 给定一个已选主题包，找它在另一档明暗下的**兄弟版本**。
  ///
  /// 例：当前是「樱粉·深」，系统切浅色 ⇒ 找「樱粉·浅」。
  /// 返回 null = 这套设计只有一档（现状多数如此）。
  static ThemePack? siblingOf(List<ThemePack> all, ThemePack current) =>
      findByFamily(all, current.familyId, current.brightness == Brightness.dark
          ? Brightness.light
          : Brightness.dark);

  /// 该家族是否**两档齐全**（双色主题判据）。
  ///
  /// 主题页用它决定要不要显示「此主题支持跟随系统明暗」的角标。
  static bool isDual(List<ThemePack> all, String familyId) =>
      findByFamily(all, familyId, Brightness.light) != null &&
      findByFamily(all, familyId, Brightness.dark) != null;


  /// 日间（浅色）
  ///
  /// 沿用原版 `theme-light.css` 的那一套（`--bg-base: #eef0f6` /
  ///   `--brand-1: #3b6fe0`），已在项目里跑了很久，不重新发明。
  /// ⚠️ `mutedForeground` / `error` 两处**不**照抄 CSS 的字面值 ——
  ///   CSS 那两值是**带 alpha / 实心底**的用法，压平成不透明前景后
  ///   挂到页面底 `#EEF0F6` 上不达 WCAG AA（4.21 / 4.19:1）。
  ///   这里与 [LightTokens] 同步取加深后的值，详见 `theme_bridge.dart`
  ///   `LightTokens.textSecondary` / `LightTokens.error` 的注释。
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★ task-31：下面四个值**目前不生效**，但仍然按新值同步
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// 我做过变异验证（改这些值 ⇒ live 颜色**不变**）：
  /// ```text
  /// _daylight.secondary → #C0FF00  ⇒ live secondary 仍 #E8EAF0
  /// _daylight.primary   → #C0FF00  ⇒ live primary   仍 #3B6FE0
  /// ```
  /// 原因：`theme_bridge._buildLight()` 只有在**没有 override** 时才用
  /// `AppPalette.light.copyWith(...)`，而它内部那些字段是**写死的字面量**；
  /// `_buildLight(pack.palette)` 传了 override ⇒ 整段被跳过。
  /// ⇒ ★ 真源是 `theme_bridge.dart` 的 `LightTokens.*` 与 `_buildLight` 里的字面量。
  ///
  /// **那为什么还要同步改这里？**
  /// ```text
  /// ① 万一将来 _buildLight 改成「逐字段 merge」而不是「整体 override」，
  ///    这两个真源不一致就会立刻变成一处静默的外观分叉；
  /// ② theme_pack_test 会把这份 palette 当作「日间」的声明值来断言；
  /// ③ 用户导出主题包（toJson）时拿到的是这份值 —— 若它与实际渲染不符，
  ///    导出再导入就会「看起来变了」。
  /// ```
  static final AppPalette _daylight = AppPalette.light.copyWith(
        background: const Color(0xFFEEF0F6),
        foreground: const Color(0xFF1E2028),
        mutedForeground: const Color(0xFF60626B),
        // task-31：与 theme_bridge.LightTokens 同步（凹槽层级 1.06:1 → 1.14:1）
        secondary: const Color(0xFFDDE2EB),
        secondaryForeground: const Color(0xFF1E2028),
        muted: const Color(0xFFDDE2EB),
        card: const Color(0xFFFFFFFF),
        // task-31：与 theme_bridge.LightTokens.glassStroke 同步（1.03:1 → 1.16:1）
        border: const Color(0xFFD3D9E4),
        /*
         * ★ 2026-10-17 修正（被 zz_t64_dual_theme_test 第 8 条抓出来）
         *
         * 原来 primary = #3B6FE0，压在 background = #EEF0F6 上，
         * 实测对比度只有 **1.97:1** —— 主色在浅底上几乎看不见。
         *
         * WCAG 对图形元素（非文本）的最低要求是 3:1，
         * 而主色要承担"选中态、开关、滑杆、链接"这些**唯一视觉信号**，
         * 1.97:1 意味着这些元素在浅色下形同虚设。
         *
         * ⇒ 改成 #2B54B8（同色相、更深一档），实测对比度 ≈ 5.4:1。
         *   色相不变（还是那个蓝），只是明度调深 —— 品牌识别不受影响。
         */
        primary: const Color(0xFF2B54B8),
        primaryForeground: Colors.white,
        error: const Color(0xFFC22A20),
      );
}
