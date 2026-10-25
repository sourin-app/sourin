// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 跨 FFI 契约门禁：Dart → Rust → 插件，剧集 id 必须真的送到
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件守的是 CodeRabbit 在 PR #30 抓到的 Major（真 bug）
//
// ```text
// Dart 侧 providerDanmakuList 发的 `req` 键名是 **camelCase**
//   { mediaId, episodeId, episodeTitle, progressMs }
// 而 FFI 那一层是 `serde_json::from_value::<DanmakuRequest>(...)`，
// Rust 字段名是 **snake_case**（media_id / episode_id / …），
// 两个结构体又**全部字段都带 #[serde(default)]** ⇒
// 驼峰键不报错，被当作「不存在的字段」**静默丢弃**：
//   episode_id 保持空串 → 插件收到的剧集 id 是 ""
// ⇒ 取弹幕必然失败，而且**一个错误都没有**。
// ```
//
// # 为什么必须**真跨 FFI**（这是本条与既有 Rust 单测的关键差别）
//
// Rust 侧那 11 条弹幕单测**直接构造 `DanmakuRequest` 结构体**调用，
// 完全绕过 FFI 的 JSON 解码 ⇒ 这个缺陷在它们那里**恰好不可见**：
// ```text
// Rust 单测：DanmakuRequest { episode_id: "ep1".into(), .. }  → 绿
// 真实链路：Dart 发 {"episodeId":"ep1"} → serde 丢弃 → ""      → 缺陷在这里
// ```
// 所以本文件**不构造结构体**，而是走 `SourinApi.providerDanmakuList`
// （Dart 侧唯一的真实入口）→ 真 DLL → FFI JSON 解码 → 真 QuickJS 插件。
//
// # 判据为什么是「插件回显的 episodeId」而不是「Rust 里读到了什么」
//
// 插件回的 `source` 就是 `'test:' + req.episodeId`（见下方插件源码）。
// 于是 `source == "test:ep1"` **同时**证明了：
// ```text
// ① Dart 发的键名被 serde 认了（没被静默丢弃）
// ② 值真的到了插件手里（不是只到了 Rust 结构体就没了）
// ```
// ★ 这正是 CodeRabbit 给的验证方式，逐字照做。
//
// # ⚠️ 环境前提（不满足就**如实跳过**，不许假绿）
//
// 需要一个**含 danmaku 命令**的 `sourin_core.dll`。
// 实测（2026-10-17）：`build/windows/x64/runner/Release/` 与 `windows/`
// 那两颗都**不含** `provider_danmaku_*`（是 10-15 的旧产物），
// 只有 `rust/sourin_core/target/debug/` 下那颗（当晚刚编的）含。
// 所以这里**按候选列表逐个探测**，都不行就跳并打印原因 ——
// 免得在别人的机器上变成「红得莫名其妙」。
// ═══════════════════════════════════════════════════════════════════════
library;

import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
// ★ 审计 B9：缺 dll 的统一处置（Windows ⇒ fail；其它平台 ⇒ 点名 skip）
import 'support/core_gate.dart';

/// 候选 DLL —— 按「最可能含 danmaku 命令」排序
///
/// ⚠️ Windows 分支的 `_openLibrary()` 只认**裸名** `sourin_core.dll`
///    （`lib/core/ffi.dart:226`），而 flutter_tester.exe 所在目录里没有它。
///    必须**先按绝对路径**把模块载进本进程，之后那次裸名 open 才命中
///    已映射的模块 —— 与 `test/zz_ops13_mirror_write_test.dart:76-94` 同一手法。
const List<String> _dllCandidates = <String>[
  r'rust\sourin_core\target\debug\sourin_core.dll',
  r'build\windows\x64\runner\Release\sourin_core.dll',
  r'windows\sourin_core.dll',
];

/// 插件源码 —— **故意**只用 `req.episodeId` 回显
///
/// 回显而不是「返回固定串」是关键：固定串的话，即使 id 被丢成空串
/// 断言也照样绿（那就成了「同一个源比同一个源」的假绿）。
const String _pluginSrc = r'''/** @id ffi_keys @name 跨层键名门禁 */
globalThis.plugin = {
  id: 'ffi_keys',
  capabilities: { vod: true, danmaku: true },
  async danmakuList(req) {
    /*
     * ★ 把收到的 id 原样回显 —— 这是「值真的到了插件」的唯一读数。
     *   mediaId 也一起回显，两条多词字段都覆盖。
     */
    return { items: [], source: 'test:' + req.episodeId + '/' + req.mediaId };
  },
};
''';

void main() {
  String? dllPath;
  late Directory sandbox;
  var coreUp = false;
  var installNote = '';

  setUpAll(() async {
    for (final c in _dllCandidates) {
      if (File(c).existsSync()) {
        dllPath = c;
        break;
      }
    }
    if (dllPath == null) {
      // ★ 审计 B9：改前 installNote + return ⇒ 缺件变 skip。Windows 必须红。
      handleMissingCore(
        missing: _dllCandidates.join('、'),
        notVerified: 'danmaku FFI 键名的真链路判据（episodeId/mediaId 到插件手里）',
      );
      return;
    }

    /*
     * ① 先把 DLL 载进本进程（绝对路径）—— 见 _dllCandidates 的说明
     */
    try {
      DynamicLibrary.open(File(dllPath!).absolute.path);
    } catch (e) {
      if (!isLibMissingForGate(e)) {
        fail('DLL 预加载失败，但**不是**缺件（不许降级成 skip）：$e');
      }
      handleMissingCore(
        missing: dllPath!,
        notVerified: 'danmaku FFI 键名的真链路判据（episodeId/mediaId 到插件手里）',
        error: e,
      );
      return;
    }

    /*
     * ② ★★★ 共享状态守卫：核心**已被别处启动** ⇒ 直接跳过，绝不往它装插件
     *
     * # 为什么必须有这一步（CodeRabbit 在 PR #30 提的真问题）
     *
     * `SourinCore` 是**进程级单例**，而 `startAsync` 在已启动时会返回
     * 「已经是启动状态」。改前这里写的是：
     * ```dart
     * if (!SourinCore.isStarted) await SourinCore.startAsync(sandbox.path);
     * coreUp = SourinCore.isStarted;      // ← 已启动也照样 true
     * // …接着 installPluginSource(…)    // ← 往**别人的**核心里装插件
     * ```
     * 于是 `sandbox` 只决定了「数据目录」，**挡不住「往一个正在运行的核心装插件」**：
     * ```text
     * 核心已被别的测试/文件启动
     *   ⇒ 我们往它装上 ffi_keys / ffi_keys2 / ffi_keys3 三个测试插件
     *   ⇒ 那个核心的 provider 列表被**污染**，且它会写进 sandbox 之外的库
     *   ⇒ 后续用例（甚至别的文件）看到凭空多出来的源
     * ```
     * ★ 关键：这种污染**不会报错**，只会让别处莫名其妙地多出东西 ——
     *   正是本仓反复强调的「静默」类缺陷。
     *
     * ⇒ 判据：**只有「本来没启动、由本文件自己起」时才继续**。
     *   已启动 ⇒ 如实跳过（不装、不跑、不拆）。
     */
    if (SourinCore.isStarted) {
      installNote = '核心已被别处启动（SourinCore 是进程级单例）'
          '⇒ 不往它装测试插件，以免污染共享状态。'
          '本文件的真链路用例因此跳过；'
          '静态交叉核对那组不依赖核心，照常执行。';
      debugPrint('FFIKEYS 跳过真链路: $installNote');
      return;
    }

    /*
     * ③ 起真核心（隔离目录 —— 绝不碰用户真实数据目录，见 docs/AGENTS.md §3）
     */
    sandbox = Directory(
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}'
        'ffi_keys_${DateTime.now().microsecondsSinceEpoch}');
    sandbox.createSync(recursive: true);
    try {
      await SourinCore.startAsync(sandbox.path);
      coreUp = SourinCore.isStarted;
    } catch (e, st) {
      coreStartFailedThenSkip(e, st,
          notVerified: 'danmaku FFI 键名的真链路判据（episodeId/mediaId 到插件手里）');
      return;
    }
    if (!coreUp) {
      fail('核心 startAsync 返回了但 isStarted=false —— 这不是缺件（不许 skip），'
          '本次没有校验到：danmaku FFI 键名的真链路判据');
    }

    /*
     * ④ 装插件 —— 用 Dart 侧唯一入口，装完 `install_plugin_source`
     *    自己会 `reload_plugins()`，所以之后直接可调。
     */
    try {
      await SourinApi.installPluginSource(_pluginSrc, nameHint: 'ffi_keys.js');
    } catch (e) {
      installNote = '装插件失败: $e';
      coreUp = false;
    }
    debugPrint('FFIKEYS dll=$dllPath coreUp=$coreUp note=$installNote');
  });

  tearDownAll(() {
    /*
     * ⚠️ 只在**本文件自己起的核心**上收尾（coreUp 为真 = 我们起的、我们装的）。
     *    跳过分支里 coreUp 恒为 false ⇒ 不碰 sandbox，也不动别人的核心。
     */
    if (coreUp) {
      try {
        if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
      } catch (_) {
        // Windows 上 SQLite 可能还被核心持有 —— 删不掉不是失败
      }
    }
  });

  /// ★★★ 主判据：`episodeId` / `mediaId` 必须真的到插件手里
  ///
  /// 改前（驼峰键）⇒ 插件拿到 '' ⇒ `source == "test:/"` ⇒ 本用例红。
  test('★★★ Dart 发的 episodeId/mediaId 真的到插件手里（不是空串）', () async {
    if (!coreUp) {
      markTestSkipped('真核心/danmaku 命令不可用：$installNote');
      return;
    }

    final b = await SourinApi.providerDanmakuList(
      'ffi_keys',
      mediaId: 'm1',
      episodeId: 'ep1',
    );

    expect(
      b.source,
      'test:ep1/m1',
      /*
       * 判据读数是「插件回显的 source」，它的形状由插件源码决定：
       *   source = `test:` + req.episodeId + `/` + req.mediaId
       * ⚠️ 这里**不要**把插件源码原样抄进 reason 字符串 ——
       *    反引号 + 单引号会提前截断 Dart 字符串（本次实测踩到）。
       */
      reason: '★ 期望插件收到 episodeId=ep1 / mediaId=m1，实际回显 "${b.source}"。\n'
          '  若是 "test:/" ⇒ 多词字段在 Dart→Rust 那一步被静默丢弃了\n'
          '  （serde 只认 snake_case，而两个结构体全字段 #[serde(default)] ⇒ 不报错）。\n'
          '  修法：lib/core/sourin_api.dart 的 req 键名改成 episode_id / media_id。',
    );
  });

  /// ★ 阳性对照：空值就该回显空 —— 证明上一条不是「恒等于 test:ep1/m1」
  test('★ 阳性对照：不传 id ⇒ 回显就是空的（上一条不是恒真）', () async {
    if (!coreUp) {
      markTestSkipped('真核心不可用：$installNote');
      return;
    }
    final b = await SourinApi.providerDanmakuList('ffi_keys');
    expect(
      b.source,
      'test:/',
      reason: '不传 id 时插件就该收到空串 —— 若这里也回 test:ep1/m1，'
          '说明上一条的断言与输入无关（假绿）。',
    );
  });

  /// ★ `episodeTitle` 同样要多词字段覆盖（它是 `Option<String>`，另一条分支）
  test('★ episodeTitle 也真的到插件手里', () async {
    if (!coreUp) {
      markTestSkipped('真核心不可用：$installNote');
      return;
    }
    /*
     * 插件回显里没带 title，所以这条走**另一条判据**：
     * 装一个只回显 episodeTitle 的插件来验。
     */
    const src2 = r'''/** @id ffi_keys2 @name 跨层键名门禁2 */
globalThis.plugin = {
  id: 'ffi_keys2',
  capabilities: { vod: true, danmaku: true },
  async danmakuList(req) {
    return { items: [], source: 'et:' + (req.episodeTitle ?? '<null>') };
  },
};
''';
    await SourinApi.installPluginSource(src2, nameHint: 'ffi_keys2.js');
    final b = await SourinApi.providerDanmakuList(
      'ffi_keys2',
      episodeId: 'ep1',
      episodeTitle: '第一集',
    );
    expect(
      b.source,
      'et:第一集',
      reason: '★ episodeTitle 被静默丢弃时会变成 et:<null>（Option 缺省 = None）',
    );
  });


  /// ★★★ `progress_ms = 0` 必须真的被收下 —— **0 是合法值，不是"没传"**
  ///
  /// # 这条守的是什么（Lead 在设计评审时指出的一处语义问题）
  ///
  /// 原先写的是 `if (progressMs != null) 'progress_ms': progressMs,` ——
  /// 后来确认：**0 与 null 是两件事**
  /// ```text
  /// progress_ms = 0    → 「这条弹幕属于第 0 毫秒」，合法输入
  /// progress_ms = null → 「本次没提供进度」，Rust 侧 Option = None
  /// ```
  /// 用 `if (x != null)` 也**不会**丢 0（Dart 里 0 != null），
  /// 但这个写法的**语义误导**是真的：读代码的人会以为 0 被当成了缺省。
  /// 现在改成**无条件放进 map**，由 Rust 按 `Option<i64>` 区分 ——
  /// 于是"0 被收下"这件事必须有一条**行为**判据钉住，不能靠读代码。
  ///
  /// # 为什么必须走真 FFI
  ///
  /// 「0 有没有被丢」取决于 JSON→serde 这一步：Dart 侧把 0 写进 map 了，
  /// 但若 Rust 侧解析成 `Option<i64>` 时把 0 当成 None，
  /// 只有真跨 FFI 才看得见。
  test('★★★ progress_ms = 0 真的到插件手里（0 不是缺省）', () async {
    if (!coreUp) {
      markTestSkipped('真核心不可用：$installNote');
      return;
    }
    /*
     * 插件把 progressMs 原样回显。
     * ⚠️ 用 `=== undefined` 区分「键不在」与「值是 0」——
     *    写成 `req.progressMs || '<none>'` 的话 0 会被当成假值，
     *    那这条测试就**永远看不到 0**（假绿的经典形态）。
     */
    const src3 = r'''/** @id ffi_keys3 @name 跨层键名门禁3 */
globalThis.plugin = {
  id: 'ffi_keys3',
  capabilities: { vod: true, danmaku: true, danmakuSend: true },
  async danmakuSend(req) {
    const pv = (req.progressMs === undefined || req.progressMs === null)
      ? '<none>' : String(req.progressMs);
    return { ok: true, id: 'pm:' + pv };
  },
};
''';
    await SourinApi.installPluginSource(src3, nameHint: 'ffi_keys3.js');

    // ① 0 ⇒ 必须是 "pm:0"，不能是 "<none>"
    final zero = await SourinApi.providerDanmakuSend(
      'ffi_keys3',
      episodeId: 'ep1',
      text: '从头开始',
      progressMs: 0,
    );
    expect(
      zero.id,
      'pm:0',
      reason: '★ progress_ms = 0 被当成缺省丢掉了 —— 0 是合法值（第 0 毫秒）。\n'
          '  实际回显: "${zero.id}"\n'
          '  若为 "pm:<none>" ⇒ 说明 0 在 Dart→Rust 某一步被当作"没传"。',
    );

    // ② 阳性对照：不传 ⇒ 必须是 "<none>"（证明上一条不是恒真）
    final none = await SourinApi.providerDanmakuSend(
      'ffi_keys3',
      episodeId: 'ep1',
      text: '不带进度',
    );
    expect(
      none.id,
      'pm:<none>',
      reason: '不传 progressMs 时插件该看到 undefined —— '

          '若这里也是 pm:0，说明上一条与输入无关（假绿）。',
    );

    // ③ 非零正常值也要能过（防止只钉住了 0 这个特例）
    final mid = await SourinApi.providerDanmakuSend(
      'ffi_keys3',
      episodeId: 'ep1',
      text: '中间',
      progressMs: 12345,
    );
    expect(mid.id, 'pm:12345');
  });

  // ═════════════════════════════════════════════════════════════════════
  //  ② 静态交叉核对：Dart 发出的键名 == Rust 结构体的 serde 名字
  // ═════════════════════════════════════════════════════════════════════
  //
  // # 为什么在「真跨 FFI」之外还要这一组
  //
  // 上面那三条要真 DLL + 真核心 + 真插件 —— 在**没有** danmaku 命令的
  // DLL 上（比如 CI，或本仓 `build/` 里那两颗 10-15 的旧产物）会**跳过**。
  // 跳过就等于这条契约在那些机器上**没有门禁**。
  // 所以这里补一组**零依赖**的静态核对，读的是**两边的真实来源**：
  // ```text
  // ① Rust 侧：从 `rust/sourin_core/src/model.rs` 抓 DanmakuRequest /
  //    DanmakuSendRequest 的 `pub <name>:` 字段名（serde 名字 = 字段名，
  //    因为这两个结构体**没有** rename_all —— 下面有一条专门钉住这点）
  // ② Dart 侧：从 `lib/core/sourin_api.dart` 抓两个 req 块里的键名
  // ```
  // ⚠️ 两边都是**现读现比**，不是手抄一份常量 ——
  //    手抄的那份会随源码漂移，正是本文件要防的假绿形态。

  group('② 静态交叉核对（零依赖，任何机器都跑）', () {
    /// 从 Rust 源码里抓某个结构体的字段名集合
    ///
    /// serde 的**默认**命名就是字段名本身 ⇒ 字段名 == JSON 键名。
    /// ⚠️ 只取**字段声明行**（`^\s*pub <name>:`）：结构体内部有大量中文
    ///    文档注释，里面也会出现 `media_id` 这种文字，不锚行首就会假绿。
    Set<String> rustFields(String structName) {
      const rel = 'rust/sourin_core/src/model.rs';
      final f = File(rel);
      expect(
        f.existsSync(),
        isTrue,
        reason: 'Rust 源码不在 $rel —— 交叉核对没法做。'
            '若目录结构变了，改这里的路径而不是删掉这条断言。',
      );
      final lines = f.readAsLinesSync();
      final at = lines.indexWhere((l) => l.contains('pub struct $structName'));
      expect(at, greaterThanOrEqualTo(0), reason: '找不到 pub struct $structName');
      final out = <String>{};
      for (var i = at + 1; i < lines.length; i++) {
        if (lines[i].trimRight() == '}') break;
        final m = RegExp(r'^\s*pub\s+(\w+)\s*:').firstMatch(lines[i]);
        if (m != null) out.add(m.group(1)!);
      }
      expect(out, isNotEmpty,
          reason: '一个字段都没抓出来 —— 正则或结构体边界写错了，这条会假绿');
      return out;
    }

    /// 从 Dart 源码里抓某个函数体内 `req` 块的键名
    ///
    /// 手法：先锚到函数签名，再找它后面**第一个** `'req': {`，
    /// 然后读到配平的 `}` —— 不依赖行号（行号会漂）。
    Set<String> dartReqKeys(String fnSignature) {
      const rel = 'lib/core/sourin_api.dart';
      final f = File(rel);
      expect(f.existsSync(), isTrue, reason: '找不到 $rel');
      final src = f.readAsStringSync();
      final at = src.indexOf(fnSignature);
      expect(at, greaterThanOrEqualTo(0),
          reason: '在 $rel 里找不到函数「$fnSignature」—— 改名了就要同步这里');
      final reqAt = src.indexOf("'req': {", at);
      expect(reqAt, greaterThanOrEqualTo(0),
          reason: '函数「$fnSignature」里找不到 req 块');
      final body = src.substring(reqAt);
      final out = <String>{};
      for (final line in body.split('\n').skip(1)) {
        final t = line.trim();
        if (t.startsWith('}')) break; // req 块结束
        /*
         * 键的形态：`'media_id': mediaId,` 或 `if (x != null) 'title': x,`
         * ⚠️ 用**行首**匹配，且要求键后面紧跟 `:` ——
         *    否则注释里出现的键名会被当真的抓进来（假绿）。
         */
        final m = RegExp(r"^(?:if\s*\([^)]*\)\s*)?'([^']+)'\s*:").firstMatch(t);
        if (m != null) out.add(m.group(1)!);
      }
      expect(out, isNotEmpty, reason: '一个键都没抓到 —— 解析写错了，这条会假绿');
      return out;
    }

    test('★★★ Rust 的两个弹幕结构体**没有** rename_all（所以键名必须 snake_case）', () {
      /*
       * 这条是上面所有结论的**前提**，必须先钉死：
       * 若哪天给这两个结构体加了 `#[serde(rename_all = "camelCase")]`，
       * 那么 Dart 侧的 snake_case 反而会**静默丢弃** —— 方向就反了。
       */
      final src = File('rust/sourin_core/src/model.rs').readAsStringSync();
      final lines = src.split('\n');
      for (final name in ['DanmakuRequest', 'DanmakuSendRequest']) {
        final at = lines.indexWhere((l) => l.contains('pub struct $name'));
        expect(at, greaterThanOrEqualTo(0));
        // 往前找 4 行（derive / serde 属性都贴在结构体上方）
        final head = lines.sublist((at - 4).clamp(0, at), at).join('\n');
        expect(
          head.contains('rename_all'),
          isFalse,
          reason: '★ $name 上出现了 rename_all —— 键名方向变了，'

              '本文件与 lib/core/sourin_api.dart 都要跟着改。\n'

              '头部:\n$head',
        );
        expect(
          head.contains('#[serde(default)]') || head.contains('Default'),
          isTrue,
          reason: '★ $name 预期是「全字段带 default」的宽进结构 —— '

              '这正是键名写错时**不报错、只静默丢弃**的根因。'

              '若它改了（比如加了 deny_unknown_fields），'

              '「静默丢弃」这个前提就不成立了，重新评估本文件。',
        );
      }
    });

    test('★★★ providerDanmakuList 的 req 键 == DanmakuRequest 的字段集', () {
      final rust = rustFields('DanmakuRequest');
      final dart = dartReqKeys('providerDanmakuList(');
      /*
       * ⚠️ 用**子集**而不是相等：Dart 侧是按需省略的
       *    （`if (title != null)` 这类），不可能每个键都出现。
       *    但**出现的每一个键都必须是 Rust 认识的** ——
       *    多一个不认识的键就会静默丢弃，正是本 bug 的形态。
       */
      final unknown = dart.difference(rust);
      expect(
        unknown,
        isEmpty,
        reason: '★ providerDanmakuList 发了 Rust **不认识**的键：$unknown\n'
            '  Rust 的字段集: ${rust.toList()..sort()}\n'
            '  Dart 发的键:   ${dart.toList()..sort()}\n'
            '  两个结构体全字段 #[serde(default)] ⇒ 多余的键会被**静默丢弃**，'
            '插件收到的就是空串，且不报任何错。',
      );
      // 反向：关键的三个多词字段必须真的在 Dart 侧出现（防止有人删掉）
      for (final k in ['media_id', 'episode_id', 'episode_title']) {
        expect(dart, contains(k),
            reason: '★ 关键字段 $k 在 providerDanmakuList 的 req 里不见了');
      }
    });

    test('★★★ providerDanmakuSend 的 req 键 == DanmakuSendRequest 的字段集', () {
      final rust = rustFields('DanmakuSendRequest');
      final dart = dartReqKeys('providerDanmakuSend(');
      final unknown = dart.difference(rust);
      expect(
        unknown,
        isEmpty,
        reason: '★ providerDanmakuSend 发了 Rust 不认识的键：$unknown\n'
            '  Rust 的字段集: ${rust.toList()..sort()}\n'
            '  Dart 发的键:   ${dart.toList()..sort()}',
      );
      for (final k in ['episode_id', 'progress_ms']) {
        expect(dart, contains(k),
            reason: '★ 关键字段 $k 在 providerDanmakuSend 的 req 里不见了');
      }
    });
  });
}