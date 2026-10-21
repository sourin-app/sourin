// ═══════════════════════════════════════════════════════════════════════
//  门禁：弹幕发送的「当前安全」必须**持续**成立，而不只是一次性证明
// ═══════════════════════════════════════════════════════════════════════
//
// # 这条门禁在钉什么
//
// `docs/notes/danmaku-send-status.md` 第 ⑤ 条回答了「现在这个状态对用户
// 是安全的吗」，用的是**三层证据**：
//
// ```text
// ① 能力位 false，三处一致（源码 / dist / 用户数据目录）
// ② false ⇒ 底栏整条不渲染（真跑验证过）
// ③ 源码里没有 canSend / disabledReason 逃生口
// ```
//
// ★ 但那是一次性的：**若明天有人把 danmakuSend 改成 true，安全性静默消失，
//   而没有任何东西会报。** 本文件把那一页纸变成持续生效的守卫。
//
// # 三条判据
//
// ```text
// ① 部署一致性：凡**存在的**那几处 danmakuSend，值必须相同
//    （源码 / dist / 用户数据目录 —— 后者只在本地存在）
//    ⇒ 某一处 true 而另一处 false = 部署漂移，用户在旧版上行为不一致
//
// ② 无逃生口：lib/ui/** 里不许出现「能力位级别的 canSend / disabledReason」
//    ⇒ 那种字段的存在，就是「按钮在但点不动」的形态
//
// ③ ★ 前置联动（本文件的核心）：
//    若 danmakuSend == true ⇒ 必须同时给出「WebGL 闸门已解」的证据
//    否则**主动红**并打印翻案条件
// ```
//
// # ★ 为什么 ③ 要这样写（而不是退一步）
//
// ```text
// 状态文档里有一句散文：
//   「打开能力位必须与解决闸门同时做，不能先开再说」
//
// 散文不是机制。③ 让它变成机制：
//   · 现在（false）⇒ 绿，并打印「闸门未解，符合预期」
//   · 谁把它改 true §⇒ 除非同时提供证据，否则**红**
//
// 证据形态（任一即可，见 _gateEvidenceMarkers）：
//   · 私库插件源码里出现 `dm_img_str` 的**真实构造代码**（不是注释）
//   · 或宿主暴露了指纹钩子（lib/ 里出现 webglFingerprint 之类的注入点）
// ⇒ 选择"代码里真的有解法"，而不是"文档某节存在"：
//   后者只要有人写一段 Markdown 就能骗过门禁。
// ```
//
// # 作用域无关（本仓已踩过三次的坑）
//
// ```text
// ❌ 不写「必须有 3 处」（CI 上只有 2 处 ⇒ 永远红）
// ❌ 不写「必须有用户数据目录那处」（CI 上没有 ⇒ 永远红）
// ✅ 写「凡存在的处，值必须一致」+「至少查到 1 处」
// ✅ 覆盖度显式打印：查了几处、跳过了哪几处、为什么
// ```
//
// 运行：flutter test test/zz_t66_danmaku_send_safety_gate_test.dart
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// ───────────────────────────────────────────────────────────────────────
//  路径探测（三处能力位 + 私库 + 数据目录）
// ───────────────────────────────────────────────────────────────────────

/*
 * ★★★ 仓根怎么定位：用 `Directory.current`，**不要用 `Platform.script`**
 *
 * # 实测（这条不改就是假绿）
 * ```text
 * 第一版：File.fromUri(Platform.script).parent.parent
 *
 * 实测读数：
 *   Platform.script   = file:///D:/WishProject/sourin-flutter-spike/main.dart
 *                                      ↑ 不是测试文件，是 main.dart
 *   appRoot 推算      = D:\WishProject            ← **多上了一层**
 *
 * ⇒ 于是 `sourin-plugins` 被算到 D:\sourin-plugins（不存在）
 *   ⇒ 源码/产物两处**全部跳过**
 *   ⇒ 只剩用户数据目录 1 处被查
 *   ⇒ 门禁**看起来全绿**，实际只覆盖了 1/3
 * ```
 *
 * 这就是「覆盖度必须显式」救回来的：报告里写着「查了 1 / 3 处」，
 * 一眼就能看出不对 —— 否则它会是一条永远绿的假门禁。
 *
 * # 为什么 `Directory.current` 可靠
 * ```text
 * flutter test 从仓库根运行（CI 与本地一致），
 * 实测 `Directory.current = D:\WishProject\sourin-flutter-spike`。
 * ```
 */
final Directory _appRoot = Directory.current;

/// 私库根 —— 兄弟目录；CI 上**不存在**
final Directory _pluginsRoot =
    Directory('${_appRoot.parent.path}${Platform.pathSeparator}sourin-plugins');

/// 用户数据目录下的插件（只在本地存在；CI 上没有）
Directory? _dataPluginsDir() {
  final appData = Platform.environment['APPDATA'];
  if (appData == null || appData.isEmpty) return null;
  final d = Directory('$appData${Platform.pathSeparator}app.sourin.player'
      '${Platform.pathSeparator}plugins');
  return d.existsSync() ? d : null;
}

/// 一个「能力位所在处」的读数
class BitSite {
  BitSite({
    required this.label,
    required this.path,
    required this.exists,
    this.declared,
    this.note,
  });

  /// 人类可读的标签（源码 / 产物 / 数据目录）
  final String label;

  /// 绝对路径（报告用）
  final String path;

  /// 这个位置是否存在
  final bool exists;

  /// 解析出的声明值；`null` = 该文件里没找到这个键（或文件不存在）
  final bool? declared;

  /// 跳过原因（存在但没解析到时写这里）
  final String? note;
}

/// 从插件文本里解析 `danmakuSend: <bool>`（**排除注释行**）
///
/// # 为什么要排除注释
/// ```text
/// 实测：私库源码 1241 行有注释
///   `*  danmakuSend: false —— **已实现，但暂不开放**`
/// 若不过滤注释，会先命中它 —— 那行是文档，不是声明。
/// ```
bool? _parseDeclared(String text) {
  for (final rawLine in text.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    // 跳过注释行
    if (line.startsWith('//') ||
        line.startsWith('*') ||
        line.startsWith('/*') ||
        line.startsWith('*/')) {
      continue;
    }
    final m = RegExp(r'^danmakuSend\s*:\s*(true|false)\s*,?\s*$').firstMatch(line);
    if (m != null) return m.group(1) == 'true';
  }
  return null;
}

/// 收集所有**存在**的能力位位置
List<BitSite> _collectSites() {
  final out = <BitSite>[];

  // ① 私库源码（CI 上不存在）
  final src = File(
      '${_pluginsRoot.path}${Platform.pathSeparator}plugins'
      '${Platform.pathSeparator}bilibili.ts');
  out.add(BitSite(
    label: '私库源码',
    path: src.path,
    exists: src.existsSync(),
    declared: src.existsSync() ? _parseDeclared(src.readAsStringSync()) : null,
    note: src.existsSync() ? null : '私库未检出（CI 上正常）',
  ));

  // ② 私库产物（CI 上不存在）
  final dist = File(
      '${_pluginsRoot.path}${Platform.pathSeparator}dist'
      '${Platform.pathSeparator}plugins${Platform.pathSeparator}bilibili.js');
  out.add(BitSite(
    label: '私库产物',
    path: dist.path,
    exists: dist.existsSync(),
    declared: dist.existsSync() ? _parseDeclared(dist.readAsStringSync()) : null,
    note: dist.existsSync() ? null : '私库未检出（CI 上正常）',
  ));

  // ③ 用户数据目录（只在本地存在）
  final dataDir = _dataPluginsDir();
  if (dataDir == null) {
    out.add(BitSite(
      label: '用户数据目录',
      path: '(无 APPDATA 或无该目录)',
      exists: false,
      note: '本机无安装数据（CI 上正常）—— 该处**本次未检查**',
    ));
  } else {
    final f = File('${dataDir.path}${Platform.pathSeparator}bilibili.js');
    out.add(BitSite(
      label: '用户数据目录',
      path: f.path,
      exists: f.existsSync(),
      declared: f.existsSync() ? _parseDeclared(f.readAsStringSync()) : null,
      note: f.existsSync() ? null : '目录在但无该插件',
    ));
  }

  return out;
}

/// 这个 checkout / 这台机器上**真的存在**的站点有几处。
///
/// ★★ 为什么按「站点存在」而不是按「平台是不是 Windows」来守 ① 组：
///   ① 组的判据是「凡**存在**的 danmakuSend 声明值必须一致」+「至少一处」。
///   而三处站点**全是环境自带的**：
///     ① 私库源码 / ② 私库产物 —— 未公开的 `sourin-plugins` 仓库，CI 上不存在
///     ③ 播放器的用户数据目录   —— 得先在本机跑过产品才有，CI 上也不存在
///
///   ⇒ 只有**开发机**（私库已检出 + 产品跑过）才凑得出站点。
///     2026-10-21 之前这里按 `Platform.isWindows` 判，Windows CI 因此
///     **没被跳过而是直接红**（run 39543248739）：
///     `Expected: non-empty / Actual: []`
///     —— 平台对了，站点照样一个都没有。平台不是这个判据的谓词。
final int _existingSiteCount =
    _collectSites().where((s) => s.exists).length;

// ───────────────────────────────────────────────────────────────────────
//  ② 的扫描器：能力位级别的逃生口
// ───────────────────────────────────────────────────────────────────────

/// 一条违规
class EscapeHatch {
  EscapeHatch(this.file, this.line, this.text);
  final String file;
  final int line;
  final String text;
}

/// 扫 lib/ui/** 里「能力位级别」的逃生口字段
///
/// # ★ 判据为什么是「字段声明」而不是「词根」
/// ```text
/// 若 grep 词根 `canSend`：
///   ⇒ 命中 `bool get _canSend`（输入框内部状态，与能力位无关）⇒ 假阳性
///   ⇒ 命中注释 `正确做法是传 canSend: false ...` ⇒ 假阳性
///
/// ⇒ 只认**字段/参数声明**形态：
///     `bool? canSend;`  /  `final String? disabledReason;`
///     `this.canSend`    /  `required this.disabledReason`
///   且**排除**以下划线开头的私有成员（`_canSend` 是内部状态，不是接口）
/// ```
List<EscapeHatch> scanEscapeHatches(String srcDir) {
  final dir = Directory(srcDir);
  if (!dir.existsSync()) return const <EscapeHatch>[];

  final hits = <EscapeHatch>[];
  final declRe = RegExp(r'\b(?:bool|String)\??\s+(canSend|disabledReason)\b');
  final ctorRe = RegExp(r'\bthis\.(canSend|disabledReason)\b');

  for (final f in dir.listSync(recursive: true)) {
    if (f is! File || !f.path.endsWith('.dart')) continue;
    final lines = f.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final raw = lines[i];
      final t = raw.trim();
      // 跳过注释
      if (t.startsWith('//') || t.startsWith('*') || t.startsWith('/*')) continue;
      if (declRe.hasMatch(t) || ctorRe.hasMatch(t)) {
        // 排除私有（`_canSend`）—— 那是内部状态
        if (RegExp(r'[_\w]canSend|_disabledReason').hasMatch(t) &&
            !RegExp(r'\b(canSend|disabledReason)\b').hasMatch(t)) {
          continue;
        }
        hits.add(EscapeHatch(
          f.path.substring(_appRoot.path.length + 1).replaceAll(r'\', '/'),
          i + 1,
          t,
        ));
      }
    }
  }
  return hits;
}

// ───────────────────────────────────────────────────────────────────────
//  ③ 的证据探测器：WebGL 闸门是否真的解了
// ───────────────────────────────────────────────────────────────────────

/// 在某文件文本里找 `dm_img_*` 的**真实构造代码**（不是注释/文档）
///
/// # 为什么要区分
/// ```text
/// 私库源码里现在就有 `dm_img_str` 这个词 —— 但它在**注释里**（说明卡点）。
/// ⇒ 若只做 `text.contains('dm_img_str')`，那个注释会**冒充证据**，
///   于是任何人在注释里写一句就能把门禁骗绿。
/// ⇒ 必须要求「出现在非注释行，且像代码」（赋值 / 拼装 / 传参）。
/// ```
bool hasFingerprintConstruction(String text) {
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    final t = raw.trim();
    if (t.startsWith('//') || t.startsWith('*') || t.startsWith('/*') || t.startsWith('*/')) {
      continue;
    }
    // 代码形态：dm_img_xxx 出现在赋值/对象字面/模板串/参数里
    if (RegExp(r'''dm_img_(list|str|cover_img_str|inter)['"]?\s*[:=]''').hasMatch(t)) {
      return true;
    }
    if (RegExp(r'''['"]dm_img_(list|str|cover_img_str|inter)['"]''').hasMatch(t)) {
      return true;
    }
  }
  return false;
}

/// 在 lib/ 里找宿主暴露的指纹钩子（证据之二）
bool hasHostFingerprintHook(String libDir) {
  final dir = Directory(libDir);
  if (!dir.existsSync()) return false;
  final re = RegExp(
      r'\b(webglFingerprint|glFingerprint|fingerprintHook|WebGLFingerprint)\b');
  for (final f in dir.listSync(recursive: true)) {
    if (f is! File || !f.path.endsWith('.dart')) continue;
    for (final raw in f.readAsLinesSync()) {
      final t = raw.trim();
      if (t.startsWith('//') || t.startsWith('*') || t.startsWith('/*')) continue;
      if (re.hasMatch(t)) return true;
    }
  }
  return false;
}

/// 收集「闸门已解」的全部证据（空 = 未解）
List<String> gateEvidence() {
  final ev = <String>[];
  final src = File(
      '${_pluginsRoot.path}${Platform.pathSeparator}plugins'
      '${Platform.pathSeparator}bilibili.ts');
  if (src.existsSync() && hasFingerprintConstruction(src.readAsStringSync())) {
    ev.add('私库源码里有 dm_img_* 的真实构造代码');
  }
  if (hasHostFingerprintHook('${_appRoot.path}${Platform.pathSeparator}lib')) {
    ev.add('宿主暴露了指纹钩子（webglFingerprint / glFingerprint …）');
  }
  return ev;
}

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

void main() {
  // ★★★ ① 只在「至少有一处站点存在」时跑 —— 它要求「**至少查到一处**」
  //   danmakuSend 声明，而三处站点**全是环境自带的**：
  //     ① 私库源码  `<仓根同级>/sourin-plugins/plugins/bilibili.ts`（私库未公开）
  //     ② 私库产物  `<仓根同级>/sourin-plugins/dist/plugins/bilibili.js`（同上）
  //     ③ 用户数据  `<APPDATA>/app.sourin.player/plugins/bilibili.js`
  //                ← 得先在本机跑过产品才会有
  //
  //   实测（CI run 39526450290，macOS job）：三处全查不到 ⇒ 本组红。
  //   实测（CI run 39543248739，**Windows** job）：平台对了、照样红 ——
  //     `Expected: non-empty / Actual: []`
  //   ⇒ 原来的 `Platform.isWindows` 守卫**谓词选错了**：
  //     它防住了 macOS，却让 Windows CI 撞在同一堵墙上。
  //     真正的条件是「有没有站点可查」，那与平台无关。
  //
  //   ⚠️ 为什么不去掉那条「至少一处」断言：
  //     它正是本门禁的**防空转判据**（reason 里写着
  //     「不能把"没查"当成"没问题"」）。去掉 = 门禁恒绿 = 假绿门禁。
  //     所以只能**把整组显式跳过**并打印理由，不能放宽它。
  //   ⚠️ ②③ **不跳过**：②扫的是仓内 `lib/ui`（任何平台都有），
  //     ③扫的是仓内能力位与闸门证据 ⇒ 非开发机上照跑，覆盖率不损失。
  group('① 部署一致性：凡存在的 danmakuSend，值必须相同',
      skip: _existingSiteCount > 0
          ? false
          : '本组三处站点都是环境自带的（私库未公开 + 播放器用户数据目录），'
              '这个 checkout / 这台机器上一处都不存在 ⇒ 显式跳过，'
              '避免把"一处都没查到"伪装成"通过"', () {
    test('★ 各处声明值一致', () {
      final sites = _collectSites();
      final checked = sites.where((s) => s.declared != null).toList();
      final skipped = sites.where((s) => s.declared == null).toList();

      print('');
      print('[GATE] 能力位位置读数：');
      for (final s in sites) {
        if (s.declared != null) {
          print('  ✓ ${s.label.padRight(12)} danmakuSend = ${s.declared}');
        } else {
          print('  · ${s.label.padRight(12)} 跳过：${s.note ?? "未解析到"}');
        }
      }
      print('[GATE] 覆盖度：查了 ${checked.length} / ${sites.length} 处'
          '${skipped.isEmpty ? "（全覆盖）" : "（跳过 ${skipped.length} 处，见上）"}');

      /*
       * ★ 作用域无关判据：
       *   不要求「必须有 3 处」，只要求「查到的那些必须一致」+「至少 1 处」。
       *   CI 上私库不存在 ⇒ checked 只有 1~2 处，仍然成立。
       */
      expect(checked, isNotEmpty,
          reason: '★ 一处都没查到 ⇒ 扫描器失效（不能把"没查"当成"没问题"）');

      final values = checked.map((s) => s.declared).toSet();
      expect(values.length, 1,
          reason: '★ 部署漂移：各处 danmakuSend 声明值不同 '
              '⇒ 用户在旧版/新版上看到的行为不一致。'
              '实测：${checked.map((s) => "${s.label}=${s.declared}").join(", ")}');
    });

    test('★ 扫描器自检：能正确解析 true / false / 注释', () {
      /*
       * 反恒绿：若 _parseDeclared 永远返回 null，
       * 上一条的 `checked` 会是空的 —— 被 isNotEmpty 挡住。
       * 但若它永远返回**同一个值**，上一条也会绿。
       * ⇒ 用合成样本证明它真的在解析。
       */
      expect(_parseDeclared('    danmakuSend: true,'), isTrue);
      expect(_parseDeclared('    danmakuSend: false,'), isFalse);
      expect(_parseDeclared('    danmakuSend: false'), isFalse);
      // 注释必须先被跳过（源码里真有这一行）
      expect(
        _parseDeclared('     *  danmakuSend: false —— 已实现但未开放\n'
            '    danmakuSend: true,'),
        isTrue,
        reason: '★ 注释行不能被当成声明 —— 否则门禁会被文档骗过',
      );
      expect(_parseDeclared('  capabilities: { vod: true },'), isNull);
    });
  });

  group('② 无逃生口：lib/ui 里不许有 canSend / disabledReason 字段', () {
    test('★ 没有能力位级别的逃生口', () {
      final uiDir = '${_appRoot.path}${Platform.pathSeparator}lib'
          '${Platform.pathSeparator}ui';
      final hits = scanEscapeHatches(uiDir);

      print('');
      print('[GATE] 逃生口扫描：lib/ui/** 命中 ${hits.length} 处');
      for (final h in hits) {
        print('  ✗ ${h.file}:${h.line}  ${h.text}');
      }

      expect(hits, isEmpty,
          reason: '★ 发现「能力位级别的逃生口字段」：\n'
              '${hits.map((h) => "  ${h.file}:${h.line}  ${h.text}").join("\n")}\n'
              '⇒ 这类字段的存在 = 「按钮在但点不动」的形态。\n'
              '  本仓口径是「不支持就不显示」——不要加置灰+说原因的逃生口。');
    });

    test('★ 扫描器自检：合成样本必须命中', () {
      /*
       * 反恒绿：证明扫描器对**真违规**会红、对**合法形态**不误报。
       * 样本写到系统临时目录（不碰仓库）。
       */
      final tmp = Directory.systemTemp.createTempSync('dmk_gate_');
      try {
        File('${tmp.path}${Platform.pathSeparator}a.dart').writeAsStringSync(
          'class X {\n  bool? canSend;\n}\n',
        );
        File('${tmp.path}${Platform.pathSeparator}b.dart').writeAsStringSync(
          'class Y {\n  final String? disabledReason;\n}\n',
        );
        File('${tmp.path}${Platform.pathSeparator}c.dart').writeAsStringSync(
          'class Z {\n  bool get _canSend => true;\n'
          '  // 正确做法是传 canSend: false\n}\n',
        );

        final hits = scanEscapeHatches(tmp.path);
        final files = hits.map((h) => h.file).toSet();

        expect(files.any((f) => f.endsWith('a.dart')), isTrue,
            reason: '`bool? canSend;` 必须命中');
        expect(files.any((f) => f.endsWith('b.dart')), isTrue,
            reason: '`final String? disabledReason;` 必须命中');
        expect(files.any((f) => f.endsWith('c.dart')), isFalse,
            reason: '★ `_canSend`（私有内部状态）与注释里的词**不该**命中');
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });

  group('③ ★ 前置联动：danmakuSend == true ⇒ 必须有闸门已解的证据', () {
    test('★★★ 能力位与闸门证据必须同时成立', () {
      final sites = _collectSites();
      final checked = sites.where((s) => s.declared != null).toList();
      final evidence = gateEvidence();

      print('');
      print('[GATE] 闸门证据：${evidence.isEmpty ? "（无）" : evidence.join(" / ")}');

      /*
       * ★ 本文件的核心判据。
       *
       * ```text
       * 状态文档 §⑤ 有一句散文：
       *   「打开能力位必须与解决闸门同时做，不能先开再说」
       *
       * 散文不是机制。这条把它变成机制。
       * ```
       */
      final anyTrue = checked.any((s) => s.declared == true);

      if (!anyTrue) {
        print('[GATE] danmakuSend = false（闸门未解）⇒ 符合预期');
        // 明确断言：现在就该是全 false，否则上面的 anyTrue 逻辑变了
        expect(checked.every((s) => s.declared == false), isTrue,
            reason: '走这个分支说明全 false —— 与上一步的 anyTrue 应互补');
        return;
      }

      /*
       * 走到这里 = 有人把 danmakuSend 打开了。
       * ⇒ 必须有闸门证据，否则红。
       */
      expect(evidence, isNotEmpty,
          reason: '''
★★★ 你打开了 danmakuSend，但没有「WebGL 闸门已解」的证据。

  翻案条件（`docs/notes/danmaku-send-status.md` §④ / `bilibili.ts:1285-1290`）：
    ① 宿主给插件暴露 WebGL / canvas，或提供指纹钩子
       ⇒ 证据形态：lib/ 里出现 webglFingerprint / glFingerprint 之类的**代码**
    ② 上游放宽该闸门（如不再要求 dm_img_*）
       ⇒ 证据形态：插件源码里 dm_img_* 的**构造代码**可以删掉，
         但需同步说明"上游已不要求"——本条门禁届时需人工调整
    ③ 找到不依赖 WebGL 的等价发送路径
       ⇒ 证据形态：插件源码里有 dm_img_* 的真实构造代码（对应新的解法）

  当前证据：${evidence.isEmpty ? "（无）" : evidence.join(" / ")}

  ⇒ 若你确实解开了闸门但证据探测器没认出来，
    请更新 test/zz_t66_danmaku_send_safety_gate_test.dart 的 gateEvidence()。
''');

      print('[GATE] danmakuSend = true 且有闸门证据 ⇒ 放行');
    });

    test('★ 证据探测器自检：注释里的 dm_img_* 不算证据', () {
      /*
       * 反恒绿 + 防骗门禁：
       * 私库源码里**现在就有** `dm_img_str` —— 但它在注释里。
       * 若探测器不区分，任何人写一句注释就能把上面那条骗绿。
       */
      expect(
        hasFingerprintConstruction(
          '    * 上游要求 dm_img_str / dm_img_list 四个字段\n',
        ),
        isFalse,
        reason: '★ 注释里的 dm_img_* 不能冒充证据',
      );
      expect(
        hasFingerprintConstruction(
          "      dm_img_str: fp.webglRenderer,\n",
        ),
        isTrue,
        reason: '真实的构造代码必须被认出来',
      );
      expect(
        hasFingerprintConstruction(
          "    const body = { 'dm_img_list': list };\n",
        ),
        isTrue,
        reason: '对象字面量形态也算构造代码',
      );
    });
  });
}
