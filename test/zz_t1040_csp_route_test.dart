// ═══════════════════════════════════════════════════════════════════════
//  第19项（t1040）—— TVBox `csp_Xxx` 路由层的跨层门禁
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件守什么（为什么它必须存在）
//
// 第19项干的事是：把配置里 `type:3 + api:"csp_Bili"` 的源
// **从「跳过」变成「真能播」**，同时保证「没写的类如实说不支持」。
// 这两件事的失败方式都**不报错、只是静默变坏**：
// ```text
// ① 路由被短路（route 恒返回 None）→ csp_Bili 掉进 skipped
//    ⇒ 用户看到「这个源不支持」，而实际上我们写了
// ② 未命中被改成「静默丢弃」→ csp_PanWebShare 连 skipped 都不进
//    ⇒ 用户以为配置里没这个站（最坏的一类：不虚报变成了「不告知」）
// ③ 实现被改成返回硬编码数据 → 看起来能播，实际是假数据
// ```
// 三种都不会崩、都不会报错。所以必须有门禁，并且**门禁必须能变红**。
//
// # 为什么是静态断言（不是跑 FFI）
//
// 本仓既有纪律（见 `test/t67_repoint_test.dart` 头部、`task12_tvbox_subscription_test.dart`）：
// ```text
// `flutter test` 里 SourinCore.callAsync 要真 dll；即使 dll 在，
// 一次导入会写 %APPDATA% 的真实数据目录 —— 测试不许碰用户数据。
// ⇒ 行为判据放在 Rust 单测（`cargo test --lib --release`，含真 HTTP），
//   本文件只锁「Rust 侧那些**结构**有没有被改回去」（跨层契约）。
// ```
// 两边的对应关系写在每条 reason 里，看断言就知道该去 Rust 侧看哪个用例。
//
// # ★ 2026-10-25（第 19 项 P2 修复）：④c 是**例外**，而且是必要的例外
// ```text
// 缺陷本体就是「Rust 说了、Dart 没接」—— 这种**跨层断链**用源码字符串
// 永远抓不到（改前那条 reason 甚至写着"界面据此提示"，而 lib/ 里
// grep notPersisted 是 0 命中）。
// ⇒ ④c 不碰 FFI、不碰数据目录：喂一份与 Rust 输出**逐字同形**的 JSON，
//   走真 `TvboxImportResult.fromJson` + 真渲染 `TvboxImportResultView`。
//   这既不违反上面的纪律（没有 dll、没有网络、没有用户数据），
//   又能证明"用户真的被告知了"。
// ```
//
// # 剥注释的做法（以及为什么不用 _support/strip_comments.dart）
//
// `test/_support/strip_comments.dart` 是**Dart 语法**状态机：
// 它把 `'` 当字符串起始 —— 而 Rust 里 `'static` 是**生命周期**、
// `'?'` 是**字符字面量**，用它会从 `'static` 一路「吞」到下一个单引号，
// 把中间的真代码当字符串原样留下（**假通过**的来源）。
// ⇒ 这里只做**整行注释剥离**（trim 后以 `//` `/*` `*` 开头的行整行丢掉），
//   行尾注释不剥 —— 代价是「把代码写进行尾注释」能骗过这几条断言，
//   但那种写法在本仓从没出现过，而用错 helper 的假通过是**已实证**过的风险
//   （见 strip_comments.dart 头部记录的 10 份实现分叉）。
//
// 跑法：
// ```powershell
// & .probe\flutter_test_lock.ps1 -Paths 'test/zz_t1040_csp_route_test.dart' -Agent tvbox-csp
// ```

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/provider_import_dialog.dart';
import 'package:sourin_spike/ui/widgets/tvbox_source_panel.dart';
// ★ 审计 B9：缺 dll 的统一处置（Windows ⇒ fail；其它平台 ⇒ 点名 skip）
import 'support/core_gate.dart';

/// 去掉整行注释后的源码（判据对象是**代码**时必做）
///
/// 覆盖 Rust 的四种注释行：`//`、`///`、`//!`、块注释的 `/*` 与续行 `*`。
String codeOnly(String path) {
  final buf = StringBuffer();
  final lines = File(path).readAsStringSync().split('\n');
  for (final line in lines) {
    final t = line.trimLeft();
    if (t.startsWith('//') || t.startsWith('/*') || t.startsWith('*')) {
      continue;
    }
    buf.writeln(line);
  }
  return buf.toString();
}

/// 把某个函数的**函数体**精确切出来
///
/// ⚠️ 必须精确切（本仓踩过「substring 一直到文件末尾，断言命中的是后面
///    另一个同名符号」的坑，见 t65 的复盘）。这里用「从签名起，到第一个
///    顶格 `}`」作为终点 —— 本仓 Rust 代码风格统一用顶格 `}` 收函数。
String fnBody(String code, String signature) {
  final start = code.indexOf(signature);
  expect(start, greaterThan(-1), reason: '找不到函数：$signature');
  final end = code.indexOf('\n}', start);
  expect(end, greaterThan(start), reason: '找不到 $signature 的结尾（顶格 }）');
  return code.substring(start, end);
}

const cspMod = 'rust/sourin_core/src/csp/mod.rs';
const cspBili = 'rust/sourin_core/src/csp/bili.rs';
const cspProvider = 'rust/sourin_core/src/csp/provider.rs';
/// Rust 侧门禁（真 HTTP 与三向路由判据都在这里跑）
const cspRouteTests = 'rust/sourin_core/src/csp/route_tests.rs';
const tvboxRs = 'rust/sourin_core/src/tvbox.rs';
const cargoToml = 'rust/sourin_core/Cargo.toml';


/// tvbox.rs **原文**（含注释）—— 用于断言「解释性注释还在」
String rawTvbox() => File(tvboxRs).readAsStringSync();

void main() {
  group('① 注册表：键 = 去掉 csp_ 前缀的类名，且 csp_Bili 真的登记了', () {
    test('★ 注册表里插入了 bili::Bili::CLASS（不是硬编码字符串 "Bili"）', () {
      final code = codeOnly(cspMod);
      expect(
        code.contains('m.insert(bili::Bili::CLASS'),
        isTrue,
        reason: '注册表必须用 Bili::CLASS 这个常量登记 —— '
            '写成字面量 "Bili" 时，实现改名就与注册键漂移（编译不报错，路由悄悄失效）',
      );
      // 类名常量本身必须是 "Bili"（与配置里 api: "csp_Bili" 的后半段逐字一致）
      final bili = codeOnly(cspBili);
      expect(
        bili.contains('pub const CLASS: &\'static str = "Bili"'),
        isTrue,
        reason: '★ 类名必须逐字 "Bili"：注册表键与配置 api 是**逐字**匹配的',
      );
    });

    test('★ 注册表键的大小写敏感（route("csp_bili") 不许命中）', () {
      // 行为判据在 Rust 单测 csp::tests::route_misses_unimplemented_class；
      // 这里锁**实现形态**：查表必须精确，不许先 to_lowercase 再做
      final mod = codeOnly(cspMod);
      expect(
        mod.contains('registry().get(class)'),
        isTrue,
        reason: 'route 必须用**精确匹配**查表（BTreeMap.get 是精确匹配；'
            '改成 to_lowercase() 再查会让 csp_bili 命中 Bili，与 DEX 的类名语义不符）',
      );
    });
  });

  group('② 路由不许被短路（故障注入点）', () {
    test('★★★ route 的函数体里必须有真正的查表', () {
      final body = fnBody(codeOnly(cspMod), 'pub fn route(api: &str)');
      expect(
        body.contains('registry().get(class)'),
        isTrue,
        reason: '★★★ 这是第19项的主动脉：route 一旦短路（恒 None），'
            'csp_Bili 会掉进「尚未实现」—— 用户看到「不支持」，而实现是好的。'
            '对应故障注入读数：.probe/csp-fault-route-short-circuit.log（5 红）',
      );
      expect(
        body.contains('let _ = api;'),
        isFalse,
        reason: '★ 函数体里出现 `let _ = api;` 是「短路注入」的指纹 —— 那是故障，不是实现',
      );
      expect(
        body.contains('class_of(api)'),
        isTrue,
        reason: '必须先用 class_of 取类名（它会剥 csp_ 前缀与查询串）',
      );
    });

    test('★★ 未实现的类走**单一文案来源**，不是各处自己拼', () {
      final mod = codeOnly(cspMod);
      expect(
        mod.contains('pub fn unimplemented_reason(api: &str) -> String'),
        isTrue,
        reason: '必须有一个统一的「尚未实现」文案生成器',
      );
      // 文案形态：`{api} 尚未实现`（api 原样，用户能照着去配置里找）
      expect(
        RegExp(r'format!\("\{\} 尚未实现"').hasMatch(mod),
        isTrue,
        reason: '★ 文案必须是「csp_X 尚未实现」形态（带类名，且在句尾）',
      );
    });
  });

  group('③ tvbox.rs：type:3 的路由分支（两条判据不许混）', () {
    test('★★★ csp 分支查注册表，且未命中写进 skipped（不许静默丢弃）', () {
      final code = codeOnly(tvboxRs);
      expect(
        code.contains('kind == Some(3) && crate::csp::is_csp(&raw_api)'),
        isTrue,
        reason: '★ type:3 必须先判「是不是 csp_ 形态」，否则会把 drpy JS 也当 csp 处理',
      );
      expect(
        code.contains('crate::csp::is_implemented(&raw_api)'),
        isTrue,
        reason: '★ 命中判据必须查注册表（is_implemented）',
      );
      final collect = fnBody(code, 'pub fn collect_sites(');
      expect(
        collect.contains('crate::csp::unimplemented_reason(&raw_api)'),
        isTrue,
        reason: '★★★ 未命中必须用 unimplemented_reason 写进 skipped —— '
            '把这一支改成 `continue`（静默丢弃）会让用户在导入报告里看不到这个站，'
            '对应故障注入读数：.probe/csp-fault-silent-drop.log（5 红）',
      );
      expect(
        collect.contains('resolve_api(&raw_api, base_url)'),
        isTrue,
        reason: 'type:1 仍要走相对地址补全（这条别被 csp 改造误伤）',
      );
    });

    test('★★ csp 的 api 不许被当成相对 URL 补全', () {
      final code = codeOnly(tvboxRs);
      final collect = fnBody(code, 'pub fn collect_sites(');
      // csp 分支里给 api 的赋值必须是 normalize_api_url(&raw_api)（保留 csp_Bili 原样）
      expect(
        collect.contains('api: normalize_api_url(&raw_api)'),
        isTrue,
        reason: '★★ csp_Bili 不是 URL：做过 resolve_api 就会变成 '
            '"https://配置站/.../csp_Bili"（彻底错的地址）。'
            '对应 Rust 单测 implemented_csp_api_survives_base_url_resolution',
      );
    });

    test('★★ 两条 reason 不许互相渗透（csp 不说 Java，JS 不说尚未实现）', () {
      final tvbox = codeOnly(tvboxRs);
      /*
       * ★ 只看**生产代码**（`#[cfg(test)]` 之前）。
       *
       * 第一版这条断言是全域的，跑出来直接红 —— 而且红得有价值：
       * 命中处全在 `mod tests` 里（`assert_eq!(find("东篱"), "csp_DongLi 尚未实现")`
       * 这类**判据本身**）。判据必须能写出这个字面量，否则没法断言文案；
       * 而**生产代码**里写死一份才是真的漂移风险。
       * ```text
       * 生产代码写死文案 → 改 csp 侧文案时这里不同步 ⇒ 两处说法不一致
       * 测试里写死文案   → 那正是「锁住文案」的手段，要留
       * ```
       */
      final testAt = tvbox.indexOf('#[cfg(test)]');
      expect(testAt, greaterThan(0), reason: 'tvbox.rs 应有 #[cfg(test)] 段');
      final prod = tvbox.substring(0, testAt);
      expect(
        prod.contains('尚未实现'),
        isFalse,
        reason: '★★ 生产代码里出现字面量「尚未实现」= 又一份文案拷贝（会与 csp 侧漂移）。'
            '唯一来源是 crate::csp::unimplemented_reason',
      );
      // 而 skip_reason(Some(3)) 仍必须提 Java（那是**另一条**路的真话）
      expect(
        prod.contains('需要 Java 运行时'),
        isTrue,
        reason: '非 csp 的 type:3（drpy JS / jar）仍要如实说需要 Java —— '
            '别为了 csp 把这句话删掉（那会让另一类用户以为装个 Java 就能用）',
      );
    });

    test('★★ parses[] 的 type:3 与 sites[] 的 type:3 必须注释清楚不是一回事', () {
      final tvbox = codeOnly(tvboxRs);
      // 注释被 codeOnly 剥掉了，所以这条检查**原文**
      final raw = File(tvboxRs).readAsStringSync();
      expect(
        raw.contains('parses[].type: 3') && raw.contains('sites[].type: 3'),
        isTrue,
        reason: '★ 两处 type:3 语义不同（解析服务 vs 爬虫源），必须留明确注释 —— '
            '后来人看到「第19项接了 type:3」很容易把 parses[] 也接上（那需要 WebView）',
      );
      expect(
        tvbox.contains('continue; // parses[] 的 type 3'),
        isTrue,
        reason: 'collect_parsers 仍必须只取 type:0',
      );
    });
  });

  group('④ 探测/建 Provider 走同一路由（导入与订阅更新不许分叉）', () {
    test('★★★ probe_site 被两个入口共用（≥2 处调用）', () {
      final code = codeOnly(tvboxRs);
      final hits = RegExp(r'probe_site\(&client').allMatches(code).length;
      expect(
        hits >= 2,
        isTrue,
        reason: '★★★ 首次导入与订阅更新必须共用 probe_site（实际调用 $hits 处）。'
            '只改一处 = csp 源在「检测更新」里被当成苹果CMS 探测 → 全部误报失败',
      );
      expect(
        code.contains('pub async fn probe_site('),
        isTrue,
        reason: 'probe_site 必须存在（它按 job.csp 分流）',
      );
      expect(
        code.contains('pub fn build_site_provider('),
        isTrue,
        reason: 'build_site_provider 必须存在（否则 csp 源会建出苹果CMS Provider）',
      );
    });

    test('★★ csp Provider 不声明假的 search 能力', () {
      final provider = codeOnly(cspProvider);
      expect(
        provider.contains('search: false'),
        isTrue,
        reason: '★★ B 站搜索要 buvid/风控签名，没做就**不能**在 capabilities 里声明 —— '
            '声明了 UI 会出现一个点了必报错的搜索框（假能力位）',
      );
      expect(
        provider.contains('Rust 重写'),
        isTrue,
        reason: 'manifest 描述要能看出「这是 Rust 实现，不是 Java/DEX」',
      );
    });
  });

  group('④b Rust 侧落盘诚实性（**三段式第一腿**：字段出得来、且 `true` 有实据）', () {
    /*
     * ★ 2026-10-25（第 19 项 P2 修复 → **task-23 收口后重写**）
     *
     * ```text
     * 时间线（这条门禁自己经历了三次"契约变化"，每次都不是"改绿"而是"改对"）：
     *   ① 改前：Rust 诚实标 "persisted": false（csp 不落盘），Dart 没接 ⇒ P2 缺陷
     *   ② task-18：Dart 接上了；本组钉的就是 ① 那个诚实形态
     *   ③ task-23：csp 源**真的落盘**了（model.rs 加 ext + state.rs 加 csp 分支）
     *      ⇒ 旧断言（`job.csp.is_none()` / `csp_unpersisted`）**必然红**，
     *        而它红得对：守的不变量变了。
     *
     * 现在守什么（关键：不许变成"恒真"）：
     * ```text
     * A. `"persisted": true` 必须**有实据**支撑 —— 不能是"旁边什么都没做，只写个 true"：
     *    ① 同一分支必须先 `to_persist.push(PersistedProvider::Tvbox { … ext … })`
     *    ② 该批必须经 `persist_from_registry(state)?` 落盘
     *       ★ 那个 `?` 只保证**一件事**：写盘失败 ⇒ 整次导入报错 ⇒ 一个 imported
     *         行都不会吐出来（用户看到的是错误，不是"已导入"）。
     *       ⚠️ 它**不**保证"csp 真的在落盘批里" —— 批里有没有 csp，靠的是 A①
     *         （`to_persist.push(…Tvbox{…})` 是否**无条件**执行过），与这个 `?` 无关。
     *         把两件事混成一句"唯一依据"，会让下一个人以为有 `?` 就万事大吉。
     * B. 旧的"跳过 csp 落盘 + 清单"痕迹必须**消失**（`csp_unpersisted` / `job.csp.is_none()`）。
     * C. `notPersisted` 键**保留但恒空**（Dart 侧已接线；删键会让旧界面崩）。
     * D. `kindTag` 仍在。
     * ```
     * ⚠️ 残留风险（已记入交付说明，未在本批修）：`"persisted": true` 目前是**字面量**。
     *    它之所以不是谎话，靠的是 A①②（写盘失败会整次失败）。若将来 persist 变成
     *    "失败可降级、仍返回结果"，就必须改成**按落盘结果回填**，并把这条断言换成
     *    "读 persist 的返回值"。改坏了 A②（去掉 `?`）本条会立刻红。
     */
    test('★★ `persisted: true` 必须有实据（真落盘 + 写失败整次失败），不是空口 true', () {
      final code = codeOnly(tvboxRs);
      final testAt = code.indexOf('#[cfg(test)]');
      final prod = testAt > 0 ? code.substring(0, testAt) : code;

      // A①：imported 行与"真的把这条记录塞进落盘列表"在**同一函数**里
      expect(
        prod.contains('to_persist.push(crate::model::PersistedProvider::Tvbox {'),
        isTrue,
        reason: '★★ csp 源现在真的落盘：必须有 Tvbox 记录进 to_persist。'
            '若这一句消失而 persisted 仍是 true，那就是**空口**（重启后源没了却报"在"）',
      );
      // A①：落盘记录必须带 ext（csp 的行为参数；不带 ⇒ 重启恢复出半残源）
      expect(
        prod.contains('ext: {'),
        isTrue,
        reason: '★ 落盘记录必须保存 ext（csp 的站点列表/口令/分类覆盖）—— '
            '不带 ext 的记录重启后建出来的源行为不对，等于"落了但没用"',
      );
      // A②：写盘失败必须整次失败（`?` 不可省）—— 这是 `true` 不成为谎话的依据
      expect(
        RegExp(r'persist_from_registry\(state\)\?').hasMatch(prod),
        isTrue,
        reason: '★★ `persist_from_registry(state)?` 的 `?` 是关键：写盘失败 ⇒ 整次导入'
            '返回错误 ⇒ 不会吐任何 "persisted": true 的行。去掉 `?` 就会'
            '"写失败也报已导入"，本条会红。',
      );
      // B：旧的"csp 不落盘"专用痕迹必须已删（删了才叫真落盘）
      expect(
        prod.contains('csp_unpersisted'),
        isFalse,
        reason: '★ 旧的不落盘清单变量必须已移除 —— 留着它说明 csp 又被排除在 to_persist 之外',
      );
      expect(
        prod.contains('"persisted": job.csp.is_none()'),
        isFalse,
        reason: '★ 旧值（csp ⇒ false）必须已废；否则界面会把"重启还在"的源报成"重启会丢"',
      );
      /*
       * ★★★ 2026-10-25（半假绿加固 · 来自 tvbox-csp 对 ④b 的复核）
       *
       * # 上面 8 条判据全是"文件里**存在**某字符串"
       * ```text
       * 它们抓得到"整段删掉"，抓不到**半假绿**：
       *   把 `to_persist.push(...Tvbox{...})` 留着，但外面套一层
       *   `if job.csp.is_none() { … }`（= csp 仍然被排除）
       *   ⇒ `csp_unpersisted` 不见了（B 绿）、`persisted: true` 还在、
       *      `notPersisted` 恒空（C 绿）、`kindTag` 在（D 绿）
       *   ⇒ 旧清单式判据**全绿**，而行为与 task-23 之前一模一样。
       * ```
       * ⇒ 必须显式钉住"落盘批里**没有**按 csp 分叉的排除条件"。
       * ⚠️ 注意判据对象是 `prod`（已剥注释）：tvbox.rs 的**注释**里还留着
       *    「旧值 job.csp.is_none() 已废」这句历史说明，那是要留的证据，不是违规。
       */
      expect(
        prod.contains('job.csp.is_none()'),
        isFalse,
        reason: '★★★ 生产代码里**不许**再出现 `job.csp.is_none()`：'
            '哪怕 push 还在，只要外面套着这个条件，csp 就又被排除在落盘批之外'
            '（半假绿：清单变量消失 + persisted 仍是 true，8 条旧判据全绿）。',
      );
      expect(
        RegExp(r'if\s*!?\s*job\.csp\.is_none\(\)').hasMatch(prod),
        isFalse,
        reason: '★★★ 同上，并且**显式**钉住"if 守卫"这一形态'
            '（`if job.csp.is_none()` 与 `if !job.csp.is_none()` 两种方向都算排除）。',
      );
      /*
       * 判据自检（**每次跑都在**）：把两种"排除形态"喂给同一个函数必须判真，
       * 一个正常形态必须判假。否则上面两条可能是恒真/恒假。
       */
      bool cspExcluded(String code) =>
          code.contains('job.csp.is_none()') ||
          RegExp(r'if\s*!?\s*job\.csp\.is_none\(\)').hasMatch(code);
      expect(
        cspExcluded('if job.csp.is_none() { to_persist.push(x); }'),
        isTrue,
        reason: '★ 判据自检：`if job.csp.is_none()` 注入样本必须判真（否则上面两条恒真）',
      );
      expect(
        cspExcluded('if !job.csp.is_none() { to_persist.push(x); }'),
        isTrue,
        reason: '★ 判据自检：反向守卫同样算排除',
      );
      expect(
        cspExcluded('to_persist.push(crate::model::PersistedProvider::Tvbox { ext });'),
        isFalse,
        reason: '★ 判据自检：正常形态（无 csp 分叉）必须判假',
      );
      // C：键保留、恒空、并写明为什么保留
      expect(
        prod.contains('"notPersisted": Vec::<String>::new()'),
        isTrue,
        reason: '★ 这个键必须**保留但恒空**：Dart 的 TvboxImportResult.notPersisted 已接线，'
            '删键虽然解析不会崩（缺字段退化为空），但会让"契约里曾经有过这件事"从代码里消失，'
            '下一个人再也看不到"曾经有一批源不落盘"。',
      );
      expect(
        // ⚠️ 这条判据的对象是**注释**，所以要用未剥注释的原文（codeOnly 会把 `//` 行整行丢掉）
        rawTvbox().contains('Dart 侧 `notPersisted` 已接线'),
        isTrue,
        reason: '★ 必须写明"为什么留一个恒空的键" —— 否则下一轮会有人以"死代码"为由删掉它',
      );
      // D：kindTag 仍在
      expect(
        prod.contains('"kindTag"'),
        isTrue,
        reason: '★ 逐源的来源标记（csp / appleCms）仍要吐出来（界面/排查用）',
      );
    });
  });

  // ─────────────────────────────────────────────────────────────────
  //  ④c 第二/三腿：Dart 真解析 + 界面真点名警示
  // ─────────────────────────────────────────────────────────────────
  //
  // ★ 为什么必须有这一组（而不是继续用源码字符串当判据）
  // ```text
  // 缺陷本体：Rust 诚实吐了 "persisted": false / "notPersisted": [...]，
  // 而 Dart 的 TvboxImportResult 根本不解析它们 ⇒ 界面一片乐观。
  // 「源码里有这个字符串」永远抓不到这种**跨层断链**。
  // ⇒ 这里喂一份与 Rust 输出**逐字同形**的 JSON，走真 fromJson、真渲染。
  // ```
  //
  // ★★ task-23 之后（csp 源真落盘）这一组的定位变了，必须说清：
  // ```text
  // 现在真实响应里 **不会再出现** persisted:false —— 也就是说下面这些断言
  // 走的是**防御性路径**（合成 JSON），不是"今天某个真实源的现状"。
  // 为什么还要留、而且必须留：
  //   ① 契约里 `persisted` / `notPersisted` 仍然存在（Rust 恒空但键在），
  //      Dart 侧的解析与警示就是这条契约的**消费者**；删掉它 = 契约无人守。
  //   ② 将来只要再出现"不能落盘的源"（新平台专有实现、需要额外运行时的源…），
  //      这套警示必须**立刻**生效，而不是等下一次事故才发现界面没接。
  //   ③ 它守的失败模式是"静默"：源重启后消失且一句话都不说 —— 这类缺陷不崩不报，
  //      只能靠合成数据把路径钉死。
  // ⇒ 所以：数据是合成的，**断言是真的**（真 fromJson、真渲染、真找那段文案）。
  // ```
  group('④c Dart 解析 + 界面点名警示（三段式的第二、三腿；防御性路径）', () {
    /// ⚠️ 合成数据（防御性路径，理由见上方组注释）：
    /// 一条源 `persisted:false, kindTag:"csp"` + 一条苹果CMS 源（无这两个键 ——
    /// 模拟"旧核心"或缺省形态，Dart 必须按 true 兼容）。
    /// 字段名与 rust/sourin_core/src/tvbox.rs 的 `imported` 行**逐字同形**。
    Map<String, dynamic> rustResponse() => <String, dynamic>{
          'totalSites': 3,
          'imported': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'lib-bili',
              'name': '哔哩｜资源合集',
              'api': 'csp_Bili',
              'categories': 16,
              'total': 0,
              'persisted': false,
              'kindTag': 'csp',
            },
            <String, dynamic>{
              'id': 'old-src',
              'name': '苹果CMS 老源',
              'api': 'https://a.example/api.php',
              'categories': 5,
              'total': 120,
            },
          ],
          'skipped': <Map<String, dynamic>>[
            <String, dynamic>{
              'name': '木偶',
              'type': 3,
              'stage': 'type',
              'reason': 'csp_PanWebShare 尚未实现',
            },
          ],
          'lives': <Map<String, dynamic>>[],
          'liveImported': <Map<String, dynamic>>[],
          'notPersisted': <String>['哔哩｜资源合集'],
        };

    test('★★ Dart 真解析 persisted / kindTag / notPersisted（缺字段按 true）', () {
      final r = TvboxImportResult.fromJson(rustResponse());

      expect(r.notPersisted, <String>['哔哩｜资源合集'],
          reason: '★★ csp 清单必须被解析出来 —— 这是"不告知"缺陷的直接来源');
      expect(r.hasNotPersisted, isTrue);

      expect(r.imported[0].persisted, isFalse,
          reason: '★★ persisted:false 必须逐源保留');
      expect(r.imported[0].kindTag, 'csp');

      expect(r.imported[1].persisted, isTrue,
          reason: '★ 缺 persisted 的旧核心形态必须按 true 兼容 —— '
              '老 dll 没有这个键，那时所有源确实都落盘了，按 false 才是说谎');
      expect(r.imported[1].kindTag, '', reason: '缺 kindTag ⇒ 空串，不编');
    });

    testWidgets('★★★ 面板必须**点名**列出「重启后需重新导入」的源', (t) async {
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeFor(Brightness.dark),
        home: Scaffold(
          body: SingleChildScrollView(
            child: TvboxImportResultView(
              result: TvboxImportResult.fromJson(rustResponse()),
            ),
          ),
        ),
      ));
      await t.pump();

      final warn = find.byKey(const ValueKey<String>('tvbox-not-persisted'));
      expect(warn, findsOneWidget,
          reason: '★★★ 这条就是缺陷本体：Rust 说了"重启就没了"，'
              '界面必须说出来 —— 一个都没有等于又把 P2 原样留回去');
      final text = t.widget<Text>(warn).data ?? '';
      expect(text, contains('重启后需要重新导入'), reason: '文案要人话、点明后果');
      expect(text, contains('哔哩｜资源合集'),
          reason: '★★ 必须**点名**（用户要知道"是不是我正在用的那个源"），'
              '只说"有 1 个"无法回答这个问题');

      // 逐源标记也要在（用户可能只扫列表那一行）
      final row = find.byKey(const ValueKey<String>('tvbox-imported-lib-bili'));
      expect(row, findsOneWidget);
      expect(t.widget<Text>(row).data ?? '', contains('重启后需重新导入'));
      // 阴性对照：落盘的源**不许**被打上这句（否则恒亮 = 用户不再看）
      final okRow = find.byKey(const ValueKey<String>('tvbox-imported-old-src'));
      expect(t.widget<Text>(okRow).data ?? '', isNot(contains('重启后需重新导入')));
    });

    testWidgets('★ 阴性对照：没有这种源时**不画**警示（防常驻红字）', (t) async {
      final clean = rustResponse()..['notPersisted'] = <String>[];
      (clean['imported'] as List)[0] = <String, dynamic>{
        'id': 'lib-bili',
        'name': '哔哩｜资源合集',
        'api': 'csp_Bili',
        'categories': 16,
        'total': 0,
        'persisted': true,
        'kindTag': 'csp',
      };
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeFor(Brightness.dark),
        home: Scaffold(
          body: TvboxImportResultView(
            result: TvboxImportResult.fromJson(clean),
          ),
        ),
      ));
      await t.pump();
      expect(find.byKey(const ValueKey<String>('tvbox-not-persisted')),
          findsNothing,
          reason: '★ 全都落盘时还挂一条红字 ⇒ 用户会学会无视它（警示失效）');
    });

    test('★★ 关窗后的 toast 也必须提这件事（那是唯一还看得见的提示）', () {
      const withCsp = ProviderImportDone(
        name: '',
        wasEditing: false,
        isTvbox: true,
        importedCount: 2,
        notPersisted: <String>['哔哩｜资源合集'],
      );
      expect(withCsp.toast, contains('重启后需重新导入'),
          reason: '★★ 弹窗里的警示会随关窗消失；只报"已导入 2 个源"'
              '等于把"能用多久"藏起来');
      expect(withCsp.toast, contains('其中 1 个'));

      const allPersisted = ProviderImportDone(
        name: '',
        wasEditing: false,
        isTvbox: true,
        importedCount: 2,
      );
      expect(allPersisted.toast, isNot(contains('重启后需重新导入')),
          reason: '★ 阴性对照：没有这种源时不许出现这句');
    });

    test('★ 接线：弹窗真的把结果交给公开面板、把清单带进 toast', () {
      /*
       * ⚠️ 这一条是**源码判据**，理由写明：`_closeResult` 是 State 的私有方法，
       *    `flutter test` 里没有真 dll 就走不到它；面板与 toast 两个**行为**
       *    判据已在上面真跑。这里只补最后一截"有没有接上"。
       */
      final code = codeOnly('lib/ui/widgets/provider_import_dialog.dart');
      expect(code.contains('TvboxImportResultView(result: _tvboxResult!)'),
          isTrue,
          reason: '★ 弹窗必须渲染公开面板（改回私有方法就等于又锁死了这条判据）');
      expect(code.contains('notPersisted: r.notPersisted'), isTrue,
          reason: '★ 清单必须从结果带进 ProviderImportDone，否则 toast 永远是空的');
    });
  });

  // ─────────────────────────────────────────────────────────────────
  //  ④d 同类第二处：**订阅更新**那条路（检测更新 → 应用）
  // ─────────────────────────────────────────────────────────────────
  //
  // ★ 为什么必须单独守这一组
  // ```text
  // 导入路径修好后，**换个入口又静默了**：远端配置里多了一条 csp_Bili，
  // 用户点「检测更新 → 应用更新」，源注册进来了，同样不落盘，
  // 但更新结果面板原本一个字都不提（它只报新增/变更/删除的**数量**）。
  // ⇒ 这组喂真实形状的 update JSON，走真 fromJson + 真渲染。
  // ```
  group('④d 订阅更新路径：同样要说出「重启后需重新导入」（防御性路径）', () {
    /// ⚠️ 合成数据（防御性路径）：task-23 之后 csp 源真落盘，真实响应里
    /// `added/changed` 行会是 `persisted:true`。这里刻意造一条 `persisted:false`，
    /// 为的是把"将来再出现不能落盘的源时，更新这条路也必须说出来"钉死。
    ///
    /// 与 `update_tvbox_source` 的返回**逐字同形**（Rust 侧 `"persisted": <bool>`）。
    /// `changed` 行的 `persisted` 故意**缺失**（模拟旧核心 / 缺省形态 ⇒ 必须按 true）。
    Map<String, dynamic> updateJson() => <String, dynamic>{
          'updated': true,
          'sourceUrl': 'https://cfg.example.com/tvbox.json',
          'added': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'lib-bili',
              'name': '哔哩｜资源合集',
              'api': 'csp_Bili',
              'persisted': false,
            },
          ],
          'changed': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'old-src',
              'name': '苹果CMS 老源',
              'api': 'https://a.example/api.php',
            },
          ],
          'removed': <Map<String, dynamic>>[],
          'deleted': <Map<String, dynamic>>[],
          'notApplied': <Map<String, dynamic>>[],
          'failed': <Map<String, dynamic>>[],
          'unchanged': 3,
          'unchangedForeign': 0,
          'skippedByType': 0,
        };

    test('★★ TvboxRemoteSite 真解析 persisted / kindTag（缺字段按 true）', () {
      final r = TvboxSourceUpdate.fromJson(updateJson());
      expect(r.updated, isTrue);
      expect(r.added.single.persisted, isFalse,
          reason: '★★ 更新响应里的 persisted:false 必须逐行保留 —— '
              '丢了它，更新路径就永远不知道有新源不会落盘');
      expect(r.changed.single.persisted, isTrue,
          reason: '★ 缺字段按 true 兼容旧核心（老 dll 这条路上没有这个键）');
      expect(r.changed.single.kindTag, '');
    });

    test('★ 挑名字的共用函数：只收「不会落盘」且名字非空的行', () {
      final names = tvboxUnpersistedNames(<TvboxRemoteSite>[
        const TvboxRemoteSite(name: '甲', persisted: false),
        const TvboxRemoteSite(name: '乙'), // 落盘
        const TvboxRemoteSite(name: '   ', persisted: false), // 空名不进清单
        const TvboxRemoteSite(name: '丙', persisted: false, kindTag: 'csp'),
      ]);
      expect(names, <String>['甲', '丙'],
          reason: '★ 空名混进来会变成「甲乙、、丙」；落盘的源混进来会让提示失真');
    });

    testWidgets('★★★ 更新结果面板必须点名警示（真渲染）', (t) async {
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeFor(Brightness.dark),
        home: Scaffold(
          body: SingleChildScrollView(
            child: TvboxUpdateResultView(
              result: TvboxSourceUpdate.fromJson(updateJson()),
            ),
          ),
        ),
      ));
      await t.pump();

      final warn = find.byKey(const ValueKey<String>('tvbox-update-not-persisted'));
      expect(warn, findsOneWidget,
          reason: '★★★ 更新路径的源同样不落盘 —— 面板不点名 = 换个入口又"不告知"。'
              '改前这个面板只报「新增 1 · 变更 1 · 删除 0」，用户不会知道其中一个重启就没了');
      final text = t.widget<Text>(warn).data ?? '';
      expect(text, contains('重启后需要重新导入'));
      expect(text, contains('哔哩｜资源合集'),
          reason: '★★ 必须点名（用户要判断"是不是我正在用的那个源"）');
      expect(text, isNot(contains('苹果CMS 老源')),
          reason: '★ 阴性对照：persisted 缺省（= 落盘）的源不许被列进来');

      final hint = find.byKey(const ValueKey<String>('tvbox-update-not-persisted-hint'));
      expect(t.widget<Text>(hint).data, kTvboxUnpersistedHint,
          reason: '★ 副提示必须是**共用常量**（与导入面板同一句话），不许各写一遍');
    });

    testWidgets('★ 阴性对照：全都落盘时更新面板不画警示', (t) async {
      final clean = updateJson();
      (clean['added'] as List)[0] = <String, dynamic>{
        'id': 'lib-bili',
        'name': '哔哩｜资源合集',
        'api': 'csp_Bili',
        'persisted': true,
      };
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeFor(Brightness.dark),
        home: Scaffold(
          body: TvboxUpdateResultView(
            result: TvboxSourceUpdate.fromJson(clean),
          ),
        ),
      ));
      await t.pump();
      expect(find.byKey(const ValueKey<String>('tvbox-update-not-persisted')),
          findsNothing,
          reason: '★ 恒亮的警示 = 用户学会无视它（比不提示更糟）');
    });

    testWidgets('★★ 两个入口的警示文案**逐字相同**（防两处措辞漂移）', (t) async {
      // 同一批名字，分别走导入面板与更新面板 —— 抽出来的字符串必须相等。
      const names = <String>['哔哩｜资源合集'];
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeFor(Brightness.dark),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(children: <Widget>[
              TvboxImportResultView(
                result: TvboxImportResult.fromJson(<String, dynamic>{
                  'totalSites': 1,
                  'imported': <Map<String, dynamic>>[
                    <String, dynamic>{'id': 'a', 'name': names.first, 'persisted': false},
                  ],
                  'notPersisted': names,
                }),
              ),
              TvboxUpdateResultView(
                result: TvboxSourceUpdate.fromJson(<String, dynamic>{
                  'updated': true,
                  'added': <Map<String, dynamic>>[
                    <String, dynamic>{'id': 'a', 'name': names.first, 'persisted': false},
                  ],
                }),
              ),
            ]),
          ),
        ),
      ));
      await t.pump();

      final importText =
          t.widget<Text>(find.byKey(const ValueKey<String>('tvbox-not-persisted'))).data;
      final updateText =
          t.widget<Text>(find.byKey(const ValueKey<String>('tvbox-update-not-persisted'))).data;
      expect(updateText, importText,
          reason: '★★★ 两个入口说同一件事就必须**一样的说法** —— '
              '各写一遍会漂成两种措辞，用户以为是两件事（文案唯一来源在 sourin_api.dart）');

      /*
       * ★ 副提示也要比 —— 只比标题会漏掉"标题对、解释各写一套"的漂移
       *   （实测：把 update 面板的 `kTvboxUnpersistedHint` 换成一句自写文案，
       *    只比标题时这条**仍然绿**，所以必须两段都钉）。
       */
      final importHint = t
          .widget<Text>(find.byKey(const ValueKey<String>('tvbox-not-persisted-hint')))
          .data;
      final updateHint = t
          .widget<Text>(find.byKey(const ValueKey<String>('tvbox-update-not-persisted-hint')))
          .data;
      expect(updateHint, importHint,
          reason: '★★ 副提示（会发生什么+怎么恢复+原件不动）也必须是同一句话');
    });

    test('★ 接线：更新面板必须渲染公开 widget（不许退回私有方法）', () {
      final code = codeOnly('lib/ui/widgets/tvbox_source_panel.dart');
      expect(code.contains('TvboxUpdateResultView(result: _applied!)'), isTrue,
          reason: '★ 退回私有 `_appliedPanel(colors, …)` 就等于又把渲染判据锁死 —— '
              '那是本轮缺陷第一次溜过去的原因');
    });
  });

  group('⑤ 真 HTTP：端点是真接口，不是硬编码数据', () {
    test('★★★ bili.rs 里四个真端点都在，且取流用 fnval=1', () {
      final bili = codeOnly(cspBili);
      for (final endpoint in const [
        '/x/web-interface/ranking/v2',
        '/x/web-interface/newlist',
        '/x/web-interface/view?',
        '/x/player/playurl?',
      ]) {
        expect(
          bili.contains(endpoint),
          isTrue,
          reason: '★ 端点 $endpoint 必须在（这是「真发 HTTP」的证据；'
              '改成返回硬编码数据会先从端点消失开始）',
        );
      }
      expect(
        bili.contains('fnval=1'),
        isTrue,
        reason: '★★★ 取流必须用 fnval=1（durl = 音视频合一的 mp4）。'
            '改成 fnval=16（dash）会**只有画面没声音** —— 且不报错',
      );
      expect(
        bili.contains('const REFERER: &str') && bili.contains('reqwest::header::REFERER'),
        isTrue,
        reason: '★★ CDN 认 Referer（缺了直链 403，属于功能而不是礼貌）：'
            '要同时有常量与**真的挂到请求上**的那一句',
      );
    });

    test('★★ 上游 code != 0 必须变成错误（不是空列表）', () {
      final bili = codeOnly(cspBili);
      expect(
        bili.contains('code != 0'),
        isTrue,
        reason: '★★ 上游失败是 HTTP 200 + {"code":-404}：只看状态码会把失败当成功，'
            '而返回空列表会被用户理解成「这个分类没内容」（两件事，不许混）',
      );
      expect(
        bili.contains('message={msg}'),
        isTrue,
        reason: '错误里要带上游 message —— 改版时用户/我们才知道是谁的问题',
      );
    });
  });

  group('⑥ 不嵌 JVM / 不引新运行时', () {
    test('★★★ Cargo.toml 里没有 JVM 绑定', () {
      final toml = File(cargoToml).readAsStringSync();
      for (final banned in const ['jni', 'java', 'jvm', 'dex']) {
        expect(
          RegExp('^\\s*$banned\\s*=', multiLine: true).hasMatch(toml),
          isFalse,
          reason: '★★★ 不许引入 $banned 依赖 —— 第19项的立身之本就是「不嵌 JVM」'
              '（桌面端没有 DexClassLoader，DEX 是 Android 专属）',
        );
      }
    });

    test('★★ csp 源码里没有 dex/JVM 痕迹', () {
      for (final f in const [cspMod, cspBili, cspProvider]) {
        final code = codeOnly(f);
        for (final banned in const ['DexClassLoader', 'java.lang', 'System.loadLibrary']) {
          expect(
            code.contains(banned),
            isFalse,
            reason: '★ $f 里出现 $banned = 路线跑偏（这条线是 Rust 重写，不是跑 DEX）',
          );
        }
      }
    });
  });

  group('⑦ 四份 DLL 必须是同一个构建（否则 flutter 测试加载旧核心）', () {
    test('★★★ 仓库根 / windows / Debug / Release 的 sourin_core.dll 哈希一致', () {
      const expected = kCoreDllPaths;
      /*
       * ★★★ 2026-10-25（审计 B9）：改前这里是
       * ```dart
       * if (!root.existsSync()) {
       *   markTestSkipped('仓库根没有 sourin_core.dll（未构建），跳过 DLL 一致性检查');
       *   return;
       * }
       * ```
       * ⇒ **Windows 上把"仓库提交物缺失"写成了 skip**：CI 结论从红变绿
       *   （"1 项跳过"），"核心没同步"能一路混进发布。这正是 B9 的原始缺陷。
       * ⇒ 现在走统一处置（test/support/core_gate.dart）：
       *   Windows ⇒ `fail`；其它平台 ⇒ skip，且 reason 点名缺哪个文件 + 本次没校验到什么。
       */
      if (!requireCoreFiles(expected, notVerified: '四份 dll 的 SHA256 一致性（= 测试真正加载的那份核心与产物树是同一个构建）')) {
        return;
      }
      final root = File(expected.first);
      final rootHash = sha256.convert(root.readAsBytesSync()).toString();
      for (final p in expected) {
        final f = File(p);
        expect(f.existsSync(), isTrue, reason: '★ 缺少 $p（导入 csp 后必须同步四份）');
        final h = sha256.convert(f.readAsBytesSync()).toString();
        expect(
          h,
          rootHash,
          reason: '★★★ $p 与仓库根不是同一个构建 —— 这条守的是「**flutter 测试真正加载的'
              '那份核心，与产物树里的是同一个构建**」：不一致时会加载旧 DLL，'
              '表现为「命令未接入」/「源不支持」这类诡异错误（且不报镜像问题）。'
              '同步命令：cp rust/sourin_core/target/release/sourin_core.dll <目标>',
        );
      }
    });
  });

  group('⑧ Rust 侧门禁文件在位（真 HTTP 与三向路由判据在那边跑）', () {
    test('★★ route_tests.rs 存在且被 tvbox.rs 引入', () {
      final rt = File(cspRouteTests);
      expect(rt.existsSync(), isTrue,
          reason: '★ 缺 rust/sourin_core/src/csp/route_tests.rs');
      final code = codeOnly(cspRouteTests);
      expect(
        code.contains('fn csp_live_import_reports_bili_imported_and_others_skipped'),
        isTrue,
        reason: '★★ 真网络导入用例必须还在（CSP_LIVE=1 才跑，读数见 .probe/csp-live.log）',
      );
      final tvbox = codeOnly(tvboxRs);
      expect(
        tvbox.contains('#[path = "csp/route_tests.rs"]'),
        isTrue,
        reason: '★ tvbox.rs 必须把这个测试模块挂进来（否则它编译都不编译）',
      );
    });
  });
}
