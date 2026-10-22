// ═══════════════════════════════════════════════════════════════════════
//  完整 API 层 —— 覆盖原版全部 87 个命令（2026-09-22）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件的作用
//
// 把 FFI 的「命令名字符串 + 松散 JSON」包装成**类型安全的 Dart API**：
// ```text
// 之前：SourinCore.callAsync('get_progress', {'provider': p, 'id': i})
// 之后：SourinApi.getProgress(provider: p, id: i)   → Progress?
// ```
//
// # 为什么值得单独一层（而不是 UI 里直接 call）
//
// ```text
// ① 参数名只在**一处**出现 —— 原版是 camelCase，Rust 读 snake_case，
//    Args 会自动回退；但 Dart 侧如果每个调用点各写各的，容易漏
// ② 返回类型明确 —— UI 拿到的不是 dynamic，编译器能查出笔误
// ③ 默认值集中 —— 比如 list_history 的 limit 默认 100
// ```
//
// # 命名约定
//
// ```text
// 命令名          get_progress
// Dart 方法名     getProgress        （小驼峰，Dart 惯例）
// 命令名里的 _    去掉，段首字母大写
// ```
// ⚠️ **命令名字符串本身不能改** —— 那是与 Rust 的契约。
//
// # 同步 vs 异步
//
// Rust 侧把命令分成两类（见 ffi.rs）：
// ```text
// with_state        → 纯本地（SQLite / 文件），微秒级
// with_state_async  → 走网络或要起线程
// ```
// Dart 侧**统一返回 Future** —— 因为即使本地命令也不该阻塞 UI 线程。
// `call` 走同步路径（快），`callAsync` 走线程池（慢/网络）。

// ⚠️ 只为了 `@visibleForTesting`（task-11 的三个探针注入点）——
//    用 `show` 限定，不把整个 foundation 拉进来。
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'ffi.dart';
import 'json_utils.dart';
import 'models.dart';
import 'stream_prepare.dart';

/*
 * ★ 把模型一起 export（2026-09-22）
 *
 * 调用方只需 import 'core/sourin_api.dart' 就能拿到
 * SourinApi + 全部模型类型（ProviderManifest / Progress ...）。
 *
 * 为什么这么做：几乎所有调用点都是「拿 API 顺便拿返回类型」——
 * 强迫每个文件写两行 import 只会让人漏掉第二行，
 * 而漏掉的症状是 The name 'X' isn't a type（看不出该 import 什么）。
 */
export 'models.dart';

/// 源影核心 API
///
/// 全部方法都是静态的 —— 核心是单例（`SourinCore` 内部就是静态状态），
/// 做成实例方法反而会让人误以为可以有多个。
class SourinApi {
  SourinApi._();

  // ═══════════════════════════════════════════════════════════════════
  //  探针 / 生命周期
  // ═══════════════════════════════════════════════════════════════════

  /// 启动核心（建库、恢复源、起流代理）
  ///
  /// # dataDir 由调用方决定
  ///
  /// 核心层不该知道各平台的路径 API：
  /// ```text
  /// Windows → %APPDATA%\app.sourin.player
  /// Android → /data/data/<pkg>/files/
  /// ```
  static Future<Map<String, dynamic>> start(String dataDir) =>
      SourinCore.startAsync(dataDir);

  // ═══════════════════════════════════════════════════════════════════
  //  ★★ 探针钩子：让**真进程**探针包住三个取数函数来数调用次数
  // ═══════════════════════════════════════════════════════════════════
  //
  // # 为什么必须包住真函数（而不是让探针另写一份计数逻辑）
  //
  // 本项目踩过两次「仪器与被测对象不是同一个东西」：
  // ```text
  // ① fix-autoscroll 用「日志文本计数」当判据 ⇒ binding 接管 debugPrint ⇒ 恒 0
  // ② 探针自己循环取流，而产品走的是 probe() 的并发池 ⇒ 数的是另一条路
  // ```
  // ⇒ 判据必须与判据对象**同源**：要数「首页切源发了几次列表请求」，
  //   就包住**首页真正调的那两个函数**（getList / getRank）。
  //
  // ⚠️ 默认全为 null ⇒ 生产路径**逐字不变**（只是多一次判空）。
  //   探针进程退出即恢复默认（进程级），不会影响别的入口。
  // ⚠️ 真机探针的实测结论见 `.probe/t11-cache.txt`。

  /// 探针注入点：`get_home`（首页分区骨架）
  ///
  /// ⚠️ **生产路径永不为非 null** —— 只有真机探针（`lib/t11_cache_probe.dart`）
  ///    会在启动时装一次，进程退出即消失。产品代码里没有任何地方写它。
  @visibleForTesting
  static Future<List<ProviderGroup>> Function()? debugHomeFetcher;

  /// 探针注入点：`get_list` / `get_rank`（首页区块内容）
  ///
  /// ⚠️ 同上：**生产路径永不为非 null**，只给探针数「切源那一刻发了几次请求」。
  @visibleForTesting
  static Future<Page<MediaItem>> Function(
    String provider,
    String categoryId, {
    int page,
  })? debugListFetcher;
  @visibleForTesting
  static Future<Page<MediaItem>> Function(
    String provider,
    String rankId, {
    int page,
  })? debugRankFetcher;

  /// 装/卸这两个注入点（`null` = 恢复真实实现）
  static void debugSetListFetchers({
    Future<Page<MediaItem>> Function(String, String, {int page})? getList,
    Future<Page<MediaItem>> Function(String, String, {int page})? getRank,
  }) {
    debugListFetcher = getList;
    debugRankFetcher = getRank;
  }

  static void debugSetHomeFetcher(
    Future<List<ProviderGroup>> Function()? getHome,
  ) {
    debugHomeFetcher = getHome;
  }

  /// 探针注入点：`get_live_stream`（T27-06 门禁用）
  ///
  /// ⚠️ 与上面的探针同一纪律：**生产路径永不为非 null**（默认全 null ⇒
  ///    生产路径逐字不变）。
  /// ⚠️ 语义：fake 顶替的是**核心层传输**（`SourinCore.callAsync`），
  ///    不是缓存 —— 装上后缓存逻辑**照常生效**，门禁数的
  ///    「真取次数」是缓存之下真实打到 fake 的次数（仪器与被测对象同源）。
  @visibleForTesting
  static Future<List<StreamCandidate>> Function(
    String provider,
    String channelId,
  )? debugLiveStreamFetcher;

  /// 门禁注入点：`resolve_stream`（PR#22 切集续播提示门禁用）
  ///
  /// ⚠️ 与上面的探针同一纪律：**生产路径永不为非 null**（默认 null ⇒
  ///    生产路径逐字不变，只是多一次判空）。
  /// ⚠️ 语义：fake 顶替的是**核心层传输**（`SourinCore.callAsync`），
  ///    不是缓存 —— [resolveStream] 本来就没有缓存。
  ///
  /// # 为什么需要它（门禁必须能造出「起播成功」的世界）
  ///
  /// `flutter test` 里没有核心层（`sourin_core.dll` 未加载），真实的
  /// `resolve_stream` 会抛 `SourinCoreException(other): 无法路由: <provider>:<id>`。
  /// 播放页 `_reload()` 把这条异常写进 `_error`，于是「切集续播提示」
  /// 新增的 `_error == null` 守卫**在门禁里恒为假** —— 提示永远弹不出来，
  /// 门禁无法区分「守卫正确工作」与「守卫写错了」。装上这个 fake 就能
  /// 让 `_reload()` 走完 `_startPlayback()`（它会清 `_error`），
  /// 把世界还原成「起播成功」，从而真正检验守卫。
  @visibleForTesting
  static Future<List<StreamCandidate>> Function(
    String provider,
    String id, {
    PlayRequest? req,
  })? debugResolveStreamFetcher;

  /// 清空直播取址缓存（T27-06）
  ///
  /// 换源 / 手动重试后的出口 —— 不留 30 秒内的旧地址。
  /// 也被测试用来保证用例之间互不污染（tearDown）。
  ///
  /// ★ CodeRabbit PR#5 N1：**代次也要一起抬**（不只是清表）。
  ///   清表只让**将来**的命中失败，却拦不住**此刻正在飞**的那次取址：
  ///   它在 `await` 期间被清、返回后照样把旧地址写回（见 [_liveStreamGen]
  ///   的长注释）—— 于是「清缓存」在竞态窗口内**恰好白做**。
  ///   清，意味着「此前发起的取址结果一律作废」⇒ 每个键的代次都得前进。
  @visibleForTesting
  static void debugClearLiveStreamCache() {
    _liveStreamCache.clear();
    // ★ CodeRabbit PR#5 N1：表里没有的键（正在飞、尚未写回）也必须作废
    //   ⇒ 抬「全局代次基准」一次作废所有键。见 [_liveStreamGenBase]。
    _liveStreamGenBase++;
  }

  /// 让**某一个**直播频道（`provider|channelId`）的缓存立即失效（生产出口）
  ///
  /// ★ 这是一个**非测试专用**的 API（不加 `@visibleForTesting`）—— 直播
  ///   取址有 30 秒 TTL，但 TTL 内地址仍可能先坏掉：代理重启、上游换址、
  ///   核心层探测出的地址在租期内失效。这时用户点「重试」若还命中同一份
  ///   坏地址，就会**永远重试同一个坏结果直到 TTL 到期**（表现为"点重试
  ///   没用"）；切回一个刚缓存过的频道也会拿到旧地址。
  ///   ⇒ 直播**播放失败**与**手动重试**入口都应先调它，把该频道的缓存
  ///   踢掉再重新取址。
  ///
  /// ⚠️ **只删对应的 `provider|channelId` 条目，不清空全部** ——
  ///    其他频道的缓存（预取邻居台的成果）必须留着，否则一次失败就把
  ///    "切台≈0ms" 的收益全丢掉。
  static void invalidateLiveStream(String provider, String channelId) {
    final key = '$provider|$channelId';
    _liveStreamCache.remove(key);
    // ★ CodeRabbit PR#5 N1：**只删条目是不够的** —— 见 [_liveStreamGen]。
    _liveStreamGen[key] = (_liveStreamGen[key] ?? 0) + 1;
  }
  /// 测试可见的缓存条目数（门禁断言「空结果不缓存」用）
  @visibleForTesting
  static int get debugLiveStreamCacheSize => _liveStreamCache.length;

  /// 测试可见的某键**代次**（CodeRabbit PR#5 N1 门禁用）
  ///
  /// 断言「失效真的抬了代次」—— 这是行为门禁的**阴性对照**：
  /// 只测「缓存里没有旧条目」会被「本来就没缓存」蒙混过关，
  /// 代次前进才证明失效**确实作用于在飞的那次取址**。
  @visibleForTesting
  static int debugLiveStreamGen(String provider, String channelId) =>
      _liveStreamGenOf('$provider|$channelId');

  /// 核心是否已启动
  static bool get isStarted => SourinCore.isStarted;

  /// 核心版本
  static String get version => SourinCore.version;

  /// 连通性探针
  static Future<bool> ping() async {
    final r = await SourinCore.callAsync('ping');
    return r is Map && r['pong'] == true;
  }

  // ═══════════════════════════════════════════════════════════════════
  //  内容源（Provider）
  // ═══════════════════════════════════════════════════════════════════

  /// 全部源（含启用状态与能力位）
  static Future<List<ProviderManifest>> listProviders() async {
    final r = await SourinCore.callAsync('list_providers');
    return jlist<ProviderManifest>(r, ProviderManifest.fromJson).toList();
  }

  /// 源的显示顺序
  static Future<List<String>> getProviderOrder() async {
    final r = await SourinCore.callAsync('get_provider_order');
    return jstrList(r);
  }

  /// 某个源是否启用
  static Future<bool> getProviderEnabled(String id) async {
    final r = await SourinCore.callAsync('get_provider_enabled', {'id': id});
    return r == true;
  }

  /// 门禁注入点：`set_provider_enabled`（直播页筛选的反向守卫用）
  ///
  /// ⚠️ 与 `debugLiveStreamFetcher` 同一纪律：**生产路径永不为非 null**
  ///   （默认 null ⇒ 生产路径逐字不变，只多一次判空）。
  ///
  /// # 为什么需要它
  /// ```text
  /// task-53 用户**否定**了"点直播页的源 tag 就去启停源"那个形态
  /// （配置该在设置页）。task-1013 给直播页加了"按源筛选" ——
  /// 它**看起来**又像可点的源标签 ⇒ 必须能**机器证明**它不启停源。
  /// 装一个探针数调用次数即可（调用为 0 才合格）。
  /// 没有这个钩子时，测试只能断言"没抛异常" —— 那**区分不了**
  /// 「没调」与「调了但恰好没抛」，属于假绿。
  /// ```
  @visibleForTesting
  static Future<bool> Function(String id, bool enabled)?
      debugProviderEnabledHook;

  /// 启用/停用某个源（**会落盘**，重启后保持）
  static Future<bool> setProviderEnabled(String id, bool enabled) async {
    // ★ 探针注入点（默认 null ⇒ 生产路径逐字不变）
    final hook = debugProviderEnabledHook;
    if (hook != null) return hook(id, enabled);
    final r = await SourinCore.callAsync(
      'set_provider_enabled',
      {'id': id, 'enabled': enabled},
    );
    return r == true;
  }

  /// 设置源顺序 —— 返回**实际生效**的顺序（不是回显入参）
  ///
  /// ⚠️ 入参里可能有过期/不存在的 id，返回值才是真相。
  /// UI 应该用返回值刷新自己的列表。
  static Future<List<String>> setProviderOrder(List<String> ids) async {
    final r = await SourinCore.callAsync('set_provider_order', {'ids': ids});
    return jstrList(r);
  }

  /// 取第三方源的持久化配置（JSON 原文）
  static Future<Map<String, dynamic>?> getProviderConfig(String id) async {
    final r = await SourinCore.callAsync('get_provider_config', {'id': id});
    return jmap(r);
  }

  /// 移除第三方源（内存 + 清单都清，否则重启后「幽灵源」复活）
  static Future<bool> removeProvider(String id) async {
    final r = await SourinCore.callAsync('remove_provider', {'id': id});
    return r == true;
  }

  /// 全源健康检查 —— id → 是否可用
  static Future<Map<String, bool>> healthSweep() async {
    final r = await SourinCore.callAsync('health_sweep');
    final m = jmap(r);
    if (m == null) return {};
    return m.map((k, v) => MapEntry(k, v == true));
  }

  /// ★★★ 2026-10-18（第 66 轮 N10 取证）：运行期开关并行预取
  ///
  /// # 为什么需要它
  /// ```text
  /// 环境变量 `SOURIN_PREFETCH_DISABLE` 只在 StreamProxy::new() 里读一次
  /// ⇒ 进程内改环境变量无效，必须重启进程
  /// 而 streamproxy.rs 的注释自己写明：CDN 吞吐每分钟在变，
  ///   跨进程对照里两个变量同时在变 ⇒ 量不出真实差值
  /// ⇒ 只有**同进程内交替 ON/OFF** 才能做单变量 A/B
  /// ```
  ///
  /// # 安全性
  /// 只改一个 AtomicBool；下一次请求生效（plan_prefetch 每次请求都读）
  /// ⇒ 不影响已在飞的请求，不碰任何连接/缓存状态。
  ///
  /// # ⚠️⚠️ 仅实验用：生产代码**不调用**这三个方法
  ///
  /// ```text
  /// 真实调用点（全部在 .probe/n10_real/，gitignore，不随包发布）：
  ///   .probe/n10_real/accept_ab.dart:247,346   setPrefetchDisabled
  ///   .probe/n10_real/real_ab.dart:227,306     setPrefetchDisabled
  ///   .probe/n10_real/real_ab.dart:228,309     prefetchDisabled
  ///   .probe/n10_real/accept_ab.dart:349       inYieldWindow
  ///   .probe/probe_tests/t66_n10_*_probe.dart  prefetchDisabled
  /// ```
  ///
  /// **生产路径走的是另一对**：
  /// ```text
  /// `beginYieldForSeek()` / `endYieldForSeek()`
  ///   ⇒ 由 `player_page.dart::_beginPrefetchYield()` 在 seek 后调用
  ///   ⇒ 它们是**已接线**的生产 API，与这里的三个"强制开关"不是一回事：
  ///      · begin/end ：seek 后**自动**让路 2 秒，产品行为
  ///      · set/get   ：**人工**强制 ON/OFF，只为 A/B 对照
  /// ```
  ///
  /// # ★ 为什么保留（而不是删掉）
  /// ```text
  /// ① N10（拖动转圈）的**根因验证**依赖它们：
  ///    「同进程内交替 ON/OFF 量出真实差值」这个实验，
  ///    必须能人为控制开关 ⇒ 删掉以后重验要重写整套探针。
  /// ② 它们是**只读探针 + 一个开关**，不参与任何产品决策 ——
  ///    `prefetchDisabled()` / `inYieldWindow()` 纯查询，
  ///    `setPrefetchDisabled()` 只在探针里被调用。
  /// ③ 将来若做用户可选的"省流模式"，这里就是现成的入口
  ///    （但**现在没有**任何 UI 接它）。
  /// ```
  ///
  /// # ★ 仓库硬约束的例外声明
  /// ```text
  /// 本仓要求「新增公开 API 必须同时给出调用点」。
  /// ⇒ 这三个是**例外**：调用点在 `.probe/`（不进版本库发布范围）。
  /// ⇒ 例外理由就是上面「为什么保留」三条，写在这里以备审计。
  /// ⚠️ 若将来 `.probe/` 被整体删除，这三个方法应一并删除。
  /// ```
  static Future<void> setPrefetchDisabled(bool disabled) async {
    await SourinCore.callAsync('set_prefetch_disabled', {
          'disabled': disabled,
        });
  }

  /// 读当前并行预取开关 —— ⚠️ **仅实验用**（详见上方 [setPrefetchDisabled] 的例外声明）
  ///
  /// 调用点：`.probe/n10_real/real_ab.dart:228,309`、
  ///         `.probe/probe_tests/t66_n10_cold_seek_probe.dart:175` 等。
  /// 生产代码**不调用**。
  static Future<bool> prefetchDisabled() async {
    final r = await SourinCore.callAsync('prefetch_disabled');
    return jmap(r)['disabled'] == true;
  }

  /*
   * ═══════════════════════════════════════════════════════════════════
   *  ★★★ N10：seek 让路窗口
   * ═══════════════════════════════════════════════════════════════════
   *
   * # 背景（真机实测，2026-10-18，详见 streamproxy.rs 的 `yield_until_ms`）
   * ```text
   * 预取 ON   seek 到某位置后（逐 500ms 采样）：
   *   t+500ms    demuxer-cache-time 读不到
   *   t+1000ms   播放位置**卡死不动**
   *   t+1500ms   才恢复
   * 预取 OFF  同一位置：t+500ms 立刻有缓存
   *
   * ⇒ 4 路并行预取在 seek 后与"当前播放点"抢同一条上行，
   *   当前点排在后面 ⇒ mpv 手里没有可播数据 ⇒ 转圈亮起，
   *   而底栏缓冲条画的是预取拉回来的**别处**数据 ⇒ 用户看到"条满了还在转"。
   * ```
   *
   * # 为什么只在 seek 后短暂让路，不一刀切关掉
   * ```text
   * 实测远端 seek(85%)：预取 ON 162ms vs OFF 190ms
   * ⇒ 预取在远处是**有益的**，关掉是用一个 bug 换另一个 bug
   * ```
   */

  /// 让路窗口长度（与 Rust 侧 `StreamProxy::YIELD_WINDOW_MS` 保持一致）
  ///
  /// 2 秒 —— 实测 seek 后恢复 500ms~1500ms，留 33% 余量。
  /// ⚠️ 两侧必须同步修改；`zz_t66_prefetch_yield_test.dart` 有源码字面量校验。
  static const int yieldWindowMs = 2000;

  /// 进入让路窗口：接下来 [yieldWindowMs] 内预取让路给前台读取
  ///
  /// 返回 `true` 表示**本次是首次进入**窗口
  /// ⇒ 调用方据此决定要不要起恢复定时器。
  /// 连续 seek 时返回 `false`（Rust 侧已重置截止时刻），**不要**再起第二个定时器。
  static Future<bool> beginYieldForSeek() async {
    final r = await SourinCore.callAsync('begin_yield_for_seek');
    return jmap(r)['first'] == true;
  }

  /// 结束让路窗口：**恢复**进入前的开关状态（不是无条件打开预取）
  ///
  /// ⚠️ 页面销毁时必须调用，否则预取会一直处于让路状态。
  static Future<void> endYieldForSeek() async {
    await SourinCore.callAsync('end_yield_for_seek');
  }

  /// 当前是否处于让路窗口内 —— ⚠️ **仅实验/门禁用**
  ///
  /// 调用点：`.probe/n10_real/accept_ab.dart:349`（A/B 跑完复位时打印）。
  /// 生产代码**不调用**（生产侧不需要"问"，它只在 seek 时主动 begin/end）。
  ///
  /// ★ 保留理由见 [setPrefetchDisabled] 的例外声明 —— 同一组三个方法。
  static Future<bool> inYieldWindow() async {
    final r = await SourinCore.callAsync('in_yield_window');
    return jmap(r)['inWindow'] == true;
  }

  /// 导入声明式源（JSON 配置）
  static Future<ProviderManifest> importDeclarativeProvider(String json) async {
    final r = await SourinCore.callAsync(
      'import_declarative_provider',
      {'json': json},
    );
    return ProviderManifest.fromJson(jmap(r) ?? {});
  }

  /// 安装 HTTP 源（连上去读契约，自动生成 manifest）
  static Future<ProviderManifest> installHttpProvider(
    String baseUrl, {
    Map<String, String>? headers,
  }) async {
    final r = await SourinCore.callAsync('install_http_provider', {
      'base_url': baseUrl,
      if (headers != null) 'headers': headers,
    });
    return ProviderManifest.fromJson(jmap(r) ?? {});
  }

  // ═══════════════════════════════════════════════════════════════════
  //  内容浏览
  // ═══════════════════════════════════════════════════════════════════

  /// 跨源聚合首页（每个源一个分区组）
  ///
  /// ⚠️ **sections 里没有 items 是正常的**（原版设计）：
  /// 首页只列出「有哪些分类区块」，具体内容等用户切过去时再拉。
  /// 见 `Section.items` 的说明。
  static Future<List<ProviderGroup>> getHome() async {
    // ★ 探针注入点（默认 null ⇒ 生产路径逐字不变）
    final hook = debugHomeFetcher;
    if (hook != null) return hook();
    return getHomeReal();
  }

  /// **真实实现**（不经 hook）—— 只给探针在计数包装里"转发"用
  ///
  /// ⚠️ 为什么必须单独暴露它（第一版踩到的硬 bug，实测炸过）
  /// ```text
  /// 探针的计数包装里写的是 `SourinApi.getHome()` —— 而 getHome 又调 hook
  ///   （= 那个计数包装）⇒ **自己调自己**：
  ///   Unhandled Exception: Stack Overflow（15200+ 帧）
  ///   countingGetHome → getHome → hook(=countingGetHome) → …
  /// ```
  /// ⇒ 计数包装必须调 **Real**。★ 这也修掉了"仪器与被测对象不同源"：
  ///   探针转发到的就是**生产走的那段代码**，外面只多包了一层计数。
  @visibleForTesting
  static Future<List<ProviderGroup>> getHomeReal() async {
    final r = await SourinCore.callAsync('get_home');
    return jlist<ProviderGroup>(r, ProviderGroup.fromJson).toList();
  }

  /// 某源的分类列表
  static Future<List<Category>> getCategories(String provider) async {
    final r = await SourinCore.callAsync('get_categories', {'provider': provider});
    return jlist<Category>(r, Category.fromJson).toList();
  }

  /// 某源的排行榜
  static Future<Page<MediaItem>> getRank(
    String provider,
    String rankId, {
    int page = 1,
  }) async {
    // ★ 探针注入点（默认 null ⇒ 生产路径逐字不变）
    final hook = debugRankFetcher;
    if (hook != null) return hook(provider, rankId, page: page);
    return getRankReal(provider, rankId, page: page);
  }

  /// 真实实现（不经 hook）—— 理由同 [getHomeReal]
  @visibleForTesting
  static Future<Page<MediaItem>> getRankReal(
    String provider,
    String rankId, {
    int page = 1,
  }) async {
    final r = await SourinCore.callAsync('get_rank', {
      'provider': provider,
      'rank_id': rankId,
      'page': page,
    });
    return Page.fromJson(jmap(r) ?? {}, MediaItem.fromJson);
  }

  /// 分类内容列表
  ///
  /// ⚠️ 参数名 `category_id` —— 原版前端传 `categoryId`，
  /// Rust 的 `Args::get` 会自动回退到 camelCase。
  static Future<Page<MediaItem>> getList(
    String provider,
    String categoryId, {
    int page = 1,
  }) async {
    // ★ 探针注入点（默认 null ⇒ 生产路径逐字不变）
    final hook = debugListFetcher;
    if (hook != null) return hook(provider, categoryId, page: page);
    return getListReal(provider, categoryId, page: page);
  }

  /// 真实实现（不经 hook）—— 理由同 [getHomeReal]
  @visibleForTesting
  static Future<Page<MediaItem>> getListReal(
    String provider,
    String categoryId, {
    int page = 1,
  }) async {
    final r = await SourinCore.callAsync('get_list', {
      'provider': provider,
      'category_id': categoryId,
      'page': page,
    });
    return Page.fromJson(jmap(r) ?? {}, MediaItem.fromJson);
  }

  /// 作品详情（含剧集列表）
  static Future<MediaDetail> getDetail(String provider, String id) async {
    final r = await SourinCore.callAsync('get_detail', {
      'provider': provider,
      'id': id,
    });
    return MediaDetail.fromJson(jmap(r) ?? {});
  }

  /// 播放源列表（一个作品可能有多个源）
  static Future<List<PlaySource>> getSources(String provider, String id) async {
    final r = await SourinCore.callAsync('get_sources', {
      'provider': provider,
      'id': id,
    });
    return jlist<PlaySource>(r, PlaySource.fromJson).toList();
  }

  /// 某源下的剧集列表
  static Future<List<Episode>> getEpisodes(
    String provider,
    String id,
    String sourceCode,
  ) async {
    final r = await SourinCore.callAsync('get_episodes', {
      'provider': provider,
      'id': id,
      'source_code': sourceCode,
    });
    return jlist<Episode>(r, Episode.fromJson).toList();
  }

  /// 解析出**可直接播放的地址**（返回候选列表，不是一个）
  ///
  /// # ⚠️ 返回的是**列表**
  ///
  /// 我第一版写成了返回单个 `StreamCandidate` —— 那是错的。
  /// 原版签名是 `Result<Vec<StreamCandidate>, String>`：
  /// ```text
  /// 一个作品可能有多个可播候选（不同清晰度 / 不同线路）
  /// ```
  /// UI 应该用 [firstPlayable] 挑第一个能播的。
  ///
  /// # 返回值已经是本地代理地址
  ///
  /// 核心层会处理防盗链（Referer/UA 等），返回
  /// `http://127.0.0.1:<port>/s/...` 这样的本地地址 ——
  /// Flutter 侧拿到直接交给 media_kit 播即可，
  /// **不需要再处理请求头**（那已由本地代理负责）。
  static Future<List<StreamCandidate>> resolveStream(
    String provider,
    String id, {
    PlayRequest? req,
  }) async {
    final fake = debugResolveStreamFetcher;
    if (fake != null) {
      // 门禁注入：fake 顶替核心层传输（生产路径永为 null）
      // —— 见 [debugResolveStreamFetcher] 的说明。
      return await fake(provider, id, req: req);
    }
    final r = await SourinCore.callAsync('resolve_stream', {
      'provider': provider,
      'id': id,
      if (req != null) 'req': req.toJson(),
    });
    /*
     * ★★ task-33：出口处过一遍预处理
     *
     * # 为什么挂在这里（而不是 player_page）
     * ```text
     * ① resolveStream 是点播获取候选的**唯一出口**，
     *    挂这里就能保证「不管谁调、都会过一遍」；
     *    挂在 UI 层则要每个调用点各自记得调。
     * ② 保持分层：「解析编排」不是 UI 职责。
     * ③ player_page.dart 当前有另一位同事在改（弹幕面板）。
     * ```
     *
     * ⚠⚠ 这一步**不改任何现有行为**：
     *    老插件不传 needs_host_resolve ⇒ 列表原样返回（prepare 内部直接 return list）。
     */
    final raw = jlist<StreamCandidate>(r, StreamCandidate.fromJson).toList();
    return StreamPreparer.prepare(raw);
  }

  /// 挑第一个**能播**的候选
  ///
  /// # 为什么不按清晰度排序
  ///
  /// 原版是取第一个非 DRM 的候选。**排序是产品决定** ——
  /// 如果这里偷偷按清晰度重排，用户看到的默认清晰度就会和原版不一致
  ///（违反「操作逻辑保持一致」）。所以只跳过 DRM，顺序完全保留。
  static Future<StreamCandidate?> firstPlayable(
    String provider,
    String id, {
    PlayRequest? req,
  }) async {
    final list = await resolveStream(provider, id, req: req);
    for (final s in list) {
      if (s.isPlayable) return s;
    }
    return null;
  }

  // ═══════════════════════════════════════════════════════════════════
  //  搜索
  // ═══════════════════════════════════════════════════════════════════

  /// 跨源搜索（等全部源返回后一次性给结果）
  ///
  /// ⚠️ 慢 —— 最慢的源决定整体等待时间（实测可达 30 秒以上）。
  /// UI 应该优先用 `searchAllStream`（流式，边搜边显示）。
  static Future<SearchAllResult> searchAll(
    String keyword, {
    int page = 1,
  }) async {
    final r = await SourinCore.callAsync('search_all', {
      'keyword': keyword,
      'page': page,
    });
    return SearchAllResult.fromJson(jmap(r) ?? {});
  }

  /// 流式跨源搜索 —— 每完成一个源就回调一次
  ///
  /// # 为什么需要流式版（实测数据）
  ///
  /// ```text
  /// 非流式 searchAll  → 用户干等 37 秒才看到第一批结果
  /// 流式 searchAllStream → 首个结果 0.25 秒到达
  /// ```
  ///
  /// # 回调返回 false = 用户关掉了搜索页
  ///
  /// 这会**立刻中止**剩余源的搜索（实测 0.66 秒返回，而不是等 30 秒）。
  /// 用户已经离开页面了，还在后台跑几十个网络请求是纯浪费。
  ///
  /// # 用法
  ///
  /// ```dart
  /// await SourinApi.searchAllStream('庆余年', (ev) {
  ///   switch (ev) {
  ///     case SearchHit(:final providerName, :final items):
  ///       setState(() => _addResults(providerName, items));
  ///     case SearchMiss(:final provider, :final reason):
  ///       setState(() => _addMiss(provider, reason));
  ///   }
  ///   return !_pageClosed;   // 返回 false 即取消
  /// });
  /// ```
  static Future<void> searchAllStream(
    String keyword,
    bool Function(SearchStreamEvent) onEvent, {
    int page = 1,
  }) =>
      SourinCore.callStream(
        'search_all_stream',
        {'keyword': keyword, 'page': page},
        (ev) {
          /*
           * ★★ 必须先把 JSON Map 转成 SearchStreamEvent（2026-09-22 实测踩到）
           *
           * 我第一版直接写 `ev.kind` —— 但 `callStream` 交过来的是
           * **解码后的 Map**，不是模型对象。实测报：
           * ```text
           * NoSuchMethodError: Class '_Map<String, dynamic>'
           *                   has no instance getter 'kind'
           * ```
           * 这个错误 `flutter analyze` 查不出来（`ev` 是 dynamic）。
           *
           * 教训：**dynamic 的边界要立刻收窄成具体类型**，
           * 否则拼写/类型错误全留到运行时。
           */
          final event = SearchStreamEvent.fromJson(jmap(ev));
          // done / error 是流结束信号，不交给业务回调
          // （callStream 内部已识别并处理，这里再兜一次以防字段名不一致）
          if (event.kind == SearchEventKind.done) return true;
          if (event.kind == SearchEventKind.error) {
            // ⚠️ SourinCoreException 是 (message, kind) 两个参数
            throw SourinCoreException(event.error ?? '流式搜索失败', 'other');
          }
          return onEvent(event);
        },
      );

  // ═══════════════════════════════════════════════════════════════════
  //  直播
  // ═══════════════════════════════════════════════════════════════════

  /*
   * ★★ T27-06：`get_live_stream` 的 30 秒结果缓存
   *
   * 业主原话：> 切换到直播播放页总是要反应很长时间才出现画面
   *
   * # 根因
   * ```text
   * 每次切台 `_adoptLiveChannel` 都同步 `await getLiveStream(...)`：
   * 切回一个刚看过的台（↑↓ 按回去是最常见的动作）也要重新打穿核心层
   * ⇒ 上游取址慢多少，切台就黑屏/转圈多少秒。
   * ```
   *
   * # 为什么 TTL 是 30 秒
   * ```text
   * 直播地址不是恒久的（核心层探测/代理都有租期），不能永久缓存；
   * 但切台↔切台的间隔远小于 30 秒，30s 窗口已覆盖「看 A → 看 B → 看 A」。
   * 预取相邻台（player_page 侧）与这里共用同一份缓存 ⇒ 点选邻居 = 0 次取数。
   * ```
   *
   * # 为什么空结果不缓存
   * ```text
   * 空结果多半是「探测暂时失败」，缓存它 = 把一次失败放大成 30 秒失败。
   * ```
   *
   * # 为什么返回同一份 List（不拷贝）
   * ```text
   * 上游（player_page）对列表只做只读遍历/`where` 过滤，从不 mutate；
   * 拷贝一份只会制造「两次结果 != identical」的假差异，还会多占内存。
   * ```
   */
  static const Duration _liveStreamCacheTtl = Duration(seconds: 30);
  static final Map<String, (DateTime, List<StreamCandidate>)> _liveStreamCache =
      {};

  /// ★★★ CodeRabbit PR#5 N1：缓存键的**代次** —— 失效与「在飞取址」之间的竞态保护
  ///
  /// # 缺陷（真问题，改前实测可复现）
  /// ```text
  /// t0: getLiveStream(A) 命中未缓存 ⇒ 发请求、await（核心层取址，几十 ms~秒级）
  /// t1: （await 期间）用户起播失败点「重试」⇒ invalidateLiveStream(A)
  ///     ⇒ 表里那条被删。**但此时根本没有条目可删**（上次取址还没写回！
  ///       而且这次 await 更早的命中若已过期，条目也已 remove）⇒ 删了个空气。
  /// t2: t0 那次 await 返回 ⇒ `_liveStreamCache[key] = (now, list)`
  ///     ⇒ **把用户刚作废的旧地址又写回了缓存**，30 秒 TTL 重新开始计时。
  /// ⇒ invalidateLiveStream 的语义是「重试必须拿到新地址」，却在
  ///   **最容易命中的时刻**（重试与上一次取址在飞重叠）**恰好失效** ——
  ///   用户点重试，取回的仍是同一份坏地址，直到 TTL 到期，表现为"点重试没用"。
  /// ```
  ///
  /// # 修法（最小面：只碰缓存这一层，不重构）
  /// ```text
  /// 每个键一个代次计数：失效 ⇒ 该键代次 +1；取址**发起前**记下当时的代次；
  /// `await` 回来后**只有代次未变**才允许写回。代次变了 = 这次取址的结果
  /// 已被期间发生的失效作废 ⇒ 丢弃（不写缓存），调用方仍拿到本次结果自用。
  /// ```
  static final Map<String, int> _liveStreamGen = {};

  /// 全局代次基准：`debugClearLiveStreamCache()` 用它一次作废**所有**键，
  /// 包括「正在飞、还没写回」的那些（它们不在 [_liveStreamCache] 里，
  /// 按键抬不到）。
  static int _liveStreamGenBase = 0;

  /// 读某键的当前代次（键代次 + 全局基准；两者都单调 ⇒ 和也单调）
  static int _liveStreamGenOf(String key) =>
      (_liveStreamGen[key] ?? 0) + _liveStreamGenBase;

  /// 全部直播频道（按源分组）
  static Future<List<LiveGroup>> getLiveChannels() async {
    final r = await SourinCore.callAsync('get_live_channels');
    return jlist<LiveGroup>(r, LiveGroup.fromJson).toList();
  }

  /// 取某频道的播放地址（可能多个候选；30s 内同台命中缓存）
  static Future<List<StreamCandidate>> getLiveStream(
    String provider,
    String channelId,
  ) async {
    final key = '$provider|$channelId';
    // ★ `|` 只是可读的分隔符 —— provider/channelId 由核心层保证非空且
    //    不含 `|`（callAsync 的参数表）；即使含，也只影响可读性，
    //    不影响正确性（两个分量拼在同一字符串里，'(a|bc,b)' 与
    //    '(a,b|c)' 唯一性由核心层入参约束兜底）。
    final hit = _liveStreamCache[key];
    if (hit != null) {
      final (at, cached) = hit;
      if (DateTime.now().difference(at) < _liveStreamCacheTtl) {
        return cached;
      }
      _liveStreamCache.remove(key);
    }
    // ★★★ CodeRabbit PR#5 N1：记下**发起取址前**的代次。
    //   之后的 await 期间若有 invalidateLiveStream / debugClearLiveStreamCache
    //   发生，代次就会前进 ⇒ 这次的结果属于「已被作废的旧世界」，不许写回。
    final gen = _liveStreamGenOf(key);
    final fake = debugLiveStreamFetcher;
    final List<StreamCandidate> list;
    if (fake != null) {
      // 门禁/探针注入：fake 顶替核心层传输，**缓存逻辑照常生效**
      // （仪器在缓存之下 —— 见 [debugLiveStreamFetcher] 的说明）。
      // 生产路径永为 null。
      list = await fake(provider, channelId);
    } else {
      final r = await SourinCore.callAsync('get_live_stream', {
        'provider': provider,
        'channel_id': channelId,
      });
      list = jlist<StreamCandidate>(r, StreamCandidate.fromJson).toList();
    }
    // ★ N1：只有代次未变才写回 —— 变了说明这次取址已被期间的失效作废，
    //   写回就等于把旧地址又塞回缓存（失效白做）。丢弃 ≠ 错：
    //   调用方本次照样拿到 list，只是它不进缓存。
    /*
     * ★★ task-33：直播出口同样过一遍预处理
     *
     * 点播与直播是**两条独立代码路径**（player_page 里按 _isLive 分叉），
     * 只挂一条会留下「另一边静默黑屏」的口子 ——
     * 本仓历史上正是这么漏的（见 live_audio_only_notice_test 里那条“两条通道都要有”）。
     *
     * ⚠⚠ 必须在**写缓存之前**预处理：否则缓存里存的是「没解的播放页 URL」，
     * 30s 内再次切台会直接拿到它并当成可播地址。
     */
    final prepared = await StreamPreparer.prepare(list);
    if (prepared.isNotEmpty && _liveStreamGenOf(key) == gen) {
      _liveStreamCache[key] = (DateTime.now(), prepared);
    }
    return prepared;
  }

  /// 电子节目单（EPG）
  static Future<List<EpgEntry>> getEpg(String provider, String channelId) async {
    final r = await SourinCore.callAsync('get_epg', {
      'provider': provider,
      'channel_id': channelId,
    });
    return jlist<EpgEntry>(r, EpgEntry.fromJson).toList();
  }

  /// 时移回看（start/end 是 Unix 时间戳，秒）
  static Future<StreamCandidate> getTimeshift(
    String provider,
    String channelId,
    int start,
    int end,
  ) async {
    final r = await SourinCore.callAsync('get_timeshift', {
      'provider': provider,
      'channel_id': channelId,
      'start': start,
      'end': end,
    });
    return StreamCandidate.fromJson(jmap(r) ?? {});
  }

  // ═══════════════════════════════════════════════════════════════════
  //  收藏 / 追更
  // ═══════════════════════════════════════════════════════════════════

  /// 收藏列表 / 追更列表
  ///
  /// # ★★★ 参数是 `followingOnly`，**不是** `includeDeleted`
  ///     （2026-09-23 修正的移植错误）
  ///
  /// 原版签名是 `list_favorites(following_only: bool)` ——
  /// 一个**二选一的分派**：
  /// ```text
  /// followingOnly = true  → 追更列表（按最近更新排）
  /// followingOnly = false → 收藏列表（只含 favorited=1）
  /// ```
  ///
  /// ⚠️ 我第一版把它当成 `includeDeleted` 直接透传 ——
  ///    两个参数都是 bool，**编译期看不出传错**。
  ///    表现是「追更页显示一堆已删除的内容」，只有真跑界面才发现。
  ///
  /// # 列表过滤用 `favorited` 而不是 `deleted`
  ///
  /// ```text
  /// deleted=0      "行还活着"（可能只是追更、没收藏）
  /// favorited=1    ★ "在收藏列表里"
  /// ```
  static Future<List<Favorite>> listFavorites({
    bool followingOnly = false,
  }) async {
    final r = await SourinCore.callAsync(
      'list_favorites',
      {'following_only': followingOnly},
    );
    return jlist<Favorite>(r, Favorite.fromJson).toList();
  }

  /// 追更列表（UI 形态，带未读计数）
  static Future<List<Favorite>> listFollowingForUi() async {
    final r = await SourinCore.callAsync('list_following_for_ui');
    return jlist<Favorite>(r, Favorite.fromJson).toList();
  }

  /// 未读总数（底栏徽章用）
  static Future<int> totalUnread() async {
    final r = await SourinCore.callAsync('total_unread');
    return r is int ? r : 0;
  }

  /// ★ 明确地设置收藏状态（`on = true` 收藏 / `false` 取消）
  ///
  /// # 这是真正做收藏/取消的命令
  ///
  /// ⚠️ 不要用 `toggleFavorite` —— 那个名字骗人，它**不切换**
  ///（见该方法的说明）。
  ///
  /// # 两条 Owner 纠正过的语义
  ///
  /// ```text
  /// ① 取消收藏**只清 favorited，不动 following**
  ///    「不收藏了，但还想盯着看它更新」是正常诉求
  /// ② 封面会在核心层被 unproxy 还原成原始地址
  ///    否则下次启动端口变了 → 必然裂图
  /// ```
  static Future<Favorite> setFavorite(
    String provider,
    String id, {
    required bool on,
    String? title,
    String? cover,
    String? kind,
    bool? following,
  }) async {
    final r = await SourinCore.callAsync('set_favorite', {
      'provider': provider,
      'id': id,
      'on': on,
      if (title != null) 'title': title,
      if (cover != null) 'cover': cover,
      if (kind != null) 'kind': kind,
      if (following != null) 'following': following,
    });
    return Favorite.fromJson(jmap(r) ?? {});
  }

  /// ★★ 设置/取消追更
  ///
  /// # 追更**不要求先收藏**（Owner 明确纠正过）
  ///
  /// > 追更并不代表就要收藏，这是独立的状态
  ///
  /// 所以「只追更不收藏」会新建一行但 `favorited: false` ——
  /// 它出现在追更列表里，**不出现在收藏列表里**。
  ///
  /// # 开启时会自动记基准集数
  ///
  /// 「更新了」的判据是 `平台当前集数 > 基准集数`。
  /// 若不记基准，用户刚点追更就会收到"更新了 10 集"的误报。
  /// 抓基准失败不阻断（断网也得能追更），首次巡检会补记。
  static Future<Favorite?> setFollowing(
    String provider,
    String id, {
    required bool following,
    String? title,
    String? cover,
    String? kind,
  }) async {
    final r = await SourinCore.callAsync('set_following', {
      'provider': provider,
      'id': id,
      'following': following,
      if (title != null) 'title': title,
      if (cover != null) 'cover': cover,
      if (kind != null) 'kind': kind,
    });
    // 关一个本来就不存在的追更 → 返回 null（幂等空操作）
    final m = jmap(r);
    return m == null ? null : Favorite.fromJson(m);
  }

  /// 取消收藏（写墓碑，不是真删）
  ///
  /// # 为什么写墓碑
  ///
  /// 真删了，另一端（或云端）还以为这条存在，下次同步会把它**复活**。
  /// 墓碑是一条 `deleted=1` 的记录，能把这个删除动作同步出去。
  static Future<void> removeFavorite(String key) =>
      SourinCore.callAsync('remove_favorite', {'key': key});

  /// 把收藏标记为已读（清未读计数）
  static Future<void> markFavoriteRead(String key) =>
      SourinCore.callAsync('mark_favorite_read', {'key': key});

  /// ⚠️ **名字骗人：这个命令不切换收藏状态**
  ///
  /// # 原版真实语义
  ///
  /// ```text
  /// 库里没有 → 新建，favorited = true
  /// 库里已有 → favorited **保持不变**（只复活 deleted、更新元信息）
  /// ```
  /// 已收藏的再调一次**还是收藏**，不会取消。
  ///
  /// # 为什么保留这个"坏"命令
  ///
  /// Owner 要求「操作逻辑和原版完全一致」，所以照抄。
  /// 但它原版就是**死代码**（全项目无调用点）——
  /// 一个"叫 toggle 但不 toggle"的命令没法用。
  ///
  /// **UI 请用 [setFavorite]**。
  static Future<Favorite> toggleFavorite(
    String provider,
    String id, {
    required String title,
    String? cover,
    String? kind,
    bool? following,
  }) async {
    final r = await SourinCore.callAsync('toggle_favorite', {
      'provider': provider,
      'id': id,
      'title': title,
      if (cover != null) 'cover': cover,
      if (kind != null) 'kind': kind,
      if (following != null) 'following': following,
    });
    return Favorite.fromJson(jmap(r) ?? {});
  }

  /// 手动触发追更检查 —— 返回本次发现的更新
  static Future<List<UpdateInfo>> checkUpdates({int maxItems = 50}) async {
    final r = await SourinCore.callAsync('check_updates', {'max_items': maxItems});
    return jlist<UpdateInfo>(r, UpdateInfo.fromJson).toList();
  }

  // ═══════════════════════════════════════════════════════════════════
  //  进度 / 历史
  // ═══════════════════════════════════════════════════════════════════

  /// 某作品的播放进度（null = 没看过）
  static Future<Progress?> getProgress(String provider, String id) async {
    final r = await SourinCore.callAsync('get_progress', {
      'provider': provider,
      'id': id,
    });
    /*
     * ★★★ 必须用 `jmapOrNull` 而不是 `jmap`（2026-09-23 实测发现的真 bug）
     *
     * 后端签名是 `Result<Option<Progress>, String>` ——
     * **没有进度时返回 JSON null**，这是正常情况（不是错误）。
     *
     * 而 `jmap` 对 null 会**抛异常**：
     * ```text
     * SourinCoreException(other): 期望对象，实际收到 Null
     * ```
     * 后果：任何"还没看过这部片"的调用都会炸 ——
     * 也就是**第一次打开任何详情页都会报错**。
     */
    final m = jmapOrNull(r);
    return m == null ? null : Progress.fromJson(m);
  }

  /// 继续观看列表
  static Future<List<Progress>> continueWatching({int limit = 20}) async {
    final r = await SourinCore.callAsync('continue_watching', {'limit': limit});
    return jlist<Progress>(r, Progress.fromJson).toList();
  }

  /// 全部进度（同步/备份用）
  static Future<List<Progress>> listAllProgress() async {
    final r = await SourinCore.callAsync('list_all_progress');
    return jlist<Progress>(r, Progress.fromJson).toList();
  }

  /// 观看历史
  static Future<List<HistoryEntry>> listHistory({int limit = 100}) async {
    final r = await SourinCore.callAsync('list_history', {'limit': limit});
    return jlist<HistoryEntry>(r, HistoryEntry.fromJson).toList();
  }

  /// 清空历史 —— ⚠️ **会连进度一起清**
  ///
  /// # 这是原版既定行为（不是 bug）
  ///
  /// 原版注释：
  /// > progress 表同时承担"续播位置"这个职责 ——
  /// > 清空历史时一并清掉才符合用户预期
  /// > （否则点开一个看过的片子还会从上次的位置续播）。
  ///
  /// 所以「两套数据」的说法只在**写入时**成立（`saveProgress` 会同时
  /// 写 history 和 progress 两张表），**清除时是要一起清的**。
  static Future<void> clearHistory() => SourinCore.callAsync('clear_history');

  /// 保存播放进度（**同时写一条历史**）
  ///
  /// # 自动判定「看完」
  ///
  /// 观看超过 95% 时自动标记 `finished: true`。
  /// 也可用 `finished` 参数显式覆盖。
  static Future<void> saveProgress(
    String provider,
    String id, {
    required String title,
    String? cover,
    String? episodeId,
    String? episodeTitle,
    required int position,
    required int duration,
    bool? finished,
  }) =>
      SourinCore.callAsync('save_progress', {
        'provider': provider,
        'id': id,
        'title': title,
        if (cover != null) 'cover': cover,
        if (episodeId != null) 'episode_id': episodeId,
        if (episodeTitle != null) 'episode_title': episodeTitle,
        'position': position,
        'duration': duration,
        if (finished != null) 'finished': finished,
      });

  /// ★★★ task-67 需求⑤：换源时把记录**搬到**新源
  ///
  /// # Owner 原话（逐字）
  ///
  /// ```text
  /// 追更收藏历史，当我换源之后，这三个记录却没有更新，
  /// 返回再进去却还是老的源，这也是错误的
  /// ```
  ///
  /// # 根因
  ///
  /// 四张表（`favorites` / `progress` / `history` / `skip_markers`）的 key
  /// 都是 `<provider>:<id>`（Rust 侧 `commands_write::item_key`）：
  /// ```text
  /// 换源 ⇒ provider 变 ⇒ ★ key 变 ⇒ 写入是【新行】，旧行原样留着
  /// ⇒ 列表里那一条仍指向**旧源**（点进去是旧源的详情页）
  /// ```
  ///
  /// # 为什么要做成一个命令（而不是 Dart 侧删+写）
  ///
  /// ```text
  /// 两步之间崩溃/断电 ⇒ 记录**直接丢失**（删了但没写成功）
  /// ⇒ Rust 侧在一个事务里做完四张表（见 `Db::repoint_item`）
  /// ```
  ///
  /// # ★ 只在**跨源**时调用
  ///
  /// ```text
  /// fromProvider == toProvider ⇒ 不迁移
  /// ```
  /// 同一个 provider 内换**线路**（`switch_source`）不是换源；
  /// 而"同 provider 不同 id"是**另一部作品**，迁移会把两部的记录混在一起。
  /// ⇒ Rust 侧也有一道同样的守卫（两道都要，不能只靠调用方）。
  ///
  /// # 失败语义
  ///
  /// 抛异常。⚠️ 调用方**必须** catch 住并继续 —— 记录搬不动也得让用户能看。
  static Future<void> repointItem({
    required String fromProvider,
    required String fromId,
    required String toProvider,
    required String toId,
  }) =>
      SourinCore.callAsync('repoint_item', {
        'fromProvider': fromProvider,
        'fromId': fromId,
        'toProvider': toProvider,
        'toId': toId,
      });

  // ═══════════════════════════════════════════════════════════════════
  //  片头 / 片尾跳过点
  // ═══════════════════════════════════════════════════════════════════

  /// 读某作品的跳过点
  /// 探针注入点：`get_skip_marker`（PR #10 的「过期标记响应」门禁用）
  ///
  /// ⚠️ 与 `debugLiveStreamFetcher` 同一纪律：**生产路径永不为非 null**
  ///    （默认 null ⇒ 生产路径逐字不变）。
  /// ⚠️ 语义：fake 顶替的是**核心层传输**（`SourinCore.callAsync`）。
  ///    ★ 它让门禁能在**不加载 libmpv** 的前提下驱动真实的 `_loadSkipMarker()`
  ///      竞态路径（否则只能打 `native-media` 标签、在 CI 里被默认跳过）。
  @visibleForTesting
  static Future<SkipMarker?> Function(String provider, String id)?
      debugSkipMarkerFetcher;

  static Future<SkipMarker?> getSkipMarker(String provider, String id) async {
    final fake = debugSkipMarkerFetcher;
    if (fake != null) {
      // 门禁/探针注入：fake 顶替核心层传输。生产路径永为 null。
      return fake(provider, id);
    }
    final r = await SourinCore.callAsync('get_skip_marker', {
      'provider': provider,
      'id': id,
    });
    /*
     * ★★★ 同 `getProgress` —— 后端是 `Result<Option<SkipMarker>, String>`，
     *     没设过跳过点时返回 null。用 `jmap` 会抛异常。
     *
     * 实测表现：播放器页读跳过点时报
     * `期望对象，实际收到 Null`，然后整个跳过功能静默失效。
     */
    final m = jmapOrNull(r);
    return m == null ? null : SkipMarker.fromJson(m);
  }

  /// 列出全部跳过点
  static Future<List<SkipMarker>> listSkipMarkers() async {
    final r = await SourinCore.callAsync('list_skip_markers');
    return jlist<SkipMarker>(r, SkipMarker.fromJson).toList();
  }

  /// 设置跳过点
  ///
  /// # ⚠️ 后端会做区间校验（不是只靠前端）
  ///
  /// 原版注释记录的真实事故：
  /// > 前端会挡，但**遥控端可能直接发命令**，不经过前端校验 ——
  /// > 上一版就是这样漏掉了防呆，结果把整个视频（1420 秒）设成了片头。
  ///
  /// 规则：
  /// ```text
  /// ① 每个区间内部：start < end
  /// ② 片头整体在片尾之前：intro_end <= outro_start
  /// ```
  /// 违反会返回错误（`SourinCoreException`）。
  /// 写跳过点 —— ⚠️ 与 [debugSkipMarkerFetcher] 同一纪律：
  /// **生产路径永不为非 null**（默认 null ⇒ 生产路径逐字不变）。
  ///
  /// ★ 为什么要它：门禁要能构造「保存超时 / 保存失败」这两种情形。
  ///   否则只能等真实核心层不可用 —— 那既不可控也不可复跑。
  @visibleForTesting
  static Future<void> Function({
    String? title,
    int? introStart,
    int? introEnd,
    int? outroStart,
    int? outroEnd,
    bool? autoSkip,
  })? debugSkipMarkerWriter;

  /// 清空跳过点 —— 同上，生产路径永不为非 null
  @visibleForTesting
  static Future<void> Function()? debugSkipMarkerClearer;

  static Future<void> setSkipMarker(
    String provider,
    String id, {
    String? title,
    int? introStart,
    int? introEnd,
    int? outroStart,
    int? outroEnd,
    bool? autoSkip,
  }) {
    final fake = debugSkipMarkerWriter;
    if (fake != null) {
      // 门禁注入：fake 顶替核心层传输。生产路径永为 null。
      return fake(
        title: title,
        introStart: introStart,
        introEnd: introEnd,
        outroStart: outroStart,
        outroEnd: outroEnd,
        autoSkip: autoSkip,
      );
    }
    return SourinCore.callAsync('set_skip_marker', {
      'provider': provider,
      'id': id,
      if (title != null) 'title': title,
      if (introStart != null) 'intro_start': introStart,
      if (introEnd != null) 'intro_end': introEnd,
      if (outroStart != null) 'outro_start': outroStart,
      if (outroEnd != null) 'outro_end': outroEnd,
      if (autoSkip != null) 'auto_skip': autoSkip,
    });
  }

  /// 清除跳过点
  static Future<void> clearSkipMarker(String provider, String id) {
    final fake = debugSkipMarkerClearer;
    if (fake != null) {
      // 门禁注入：fake 顶替核心层传输。生产路径永为 null。
      return fake();
    }
    return SourinCore.callAsync('clear_skip_marker', {
      'provider': provider,
      'id': id,
    });
  }

  // ═══════════════════════════════════════════════════════════════════
  //  插件管理
  // ═══════════════════════════════════════════════════════════════════

  /// 插件列表（含**配置声明**，设置页据此渲染表单）
  ///
  /// # ⚠️ 配置声明来自已注册的 Provider，不是静态解析
  ///
  /// 原版踩过的坑：用 `load_plugins()`（只做静态解析、不执行脚本）
  /// 拿到的 `config` **永远是空数组** —— 表现是「插件明明声明了配置，
  /// 但设置页死活不显示『配置』按钮」，而且不报任何错。
  static Future<PluginListResult> listPlugins() async {
    final r = await SourinCore.callAsync('list_plugins');
    return PluginListResult.fromJson(jmap(r) ?? {});
  }

  /// 重新加载全部 JS 插件 —— 返回加载成功的数量
  static Future<int> reloadPlugins() async {
    final r = await SourinCore.callAsync('reload_plugins');
    return r is int ? r : 0;
  }

  /// 读插件源码
  static Future<String> readPlugin(String file) async {
    final r = await SourinCore.callAsync('read_plugin', {'file': file});
    return r is String ? r : '';
  }

  /// 删除插件（同时从 registry 摘掉）
  static Future<void> removePlugin(String file) =>
      SourinCore.callAsync('remove_plugin', {'file': file});

  /// 保存插件源码（带元信息 + 语法校验，成功后热重载）
  ///
  /// ⚠️ 这个命令是「编辑**已有**插件」，不是「新建」——
  /// 文件不存在会报错。新建请用 [installPluginSource]。
  static Future<int> savePluginSource(String file, String source) async {
    final r = await SourinCore.callAsync('save_plugin_source', {
      'file': file,
      'source': source,
    });
    return r is int ? r : 0;
  }

  /// 从 URL 安装插件（自动解析各种插件市场链接）
  static Future<PluginInstallResult> installPlugin(String url) async {
    final r = await SourinCore.callAsync('install_plugin', {'url': url});
    return PluginInstallResult.fromJson(jmap(r) ?? {});
  }

  /// 从本地内容安装插件
  static Future<PluginInstallResult> installPluginSource(
    String source, {
    String? nameHint,
  }) async {
    final r = await SourinCore.callAsync('install_plugin_source', {
      'source': source,
      if (nameHint != null) 'name_hint': nameHint,
    });
    return PluginInstallResult.fromJson(jmap(r) ?? {});
  }

  /// 导入 TVBox 配置（task-5）
  ///
  /// [config] 既可以是 TVBox 配置的 **JSON 文本**，也可以是配置的 **URL**
  /// （http/https）—— 两种都收，用户不用先想「我手上这个算哪种」。
  ///
  /// 返回结构：
  /// ```text
  /// totalSites → 配置里一共几个 sites
  /// imported[] → 成功导入的源 {id,name,api,categories,total}
  /// skipped[]  → 没导入的 {name,type,stage,reason}（stage: type=类型不支持 / probe=探测失败）
  /// lives[]    → 配置里的直播源（**本版本不导入**，只如实回报）
  /// ```
  static Future<TvboxImportResult> importTvboxConfig(String config) async {
    final r = await SourinCore.callAsync('import_tvbox_config', {
      'config': config,
    });
    // ⚠️ 这里**不用** `jmap(r) ?? {}`：`jmap` 返回非空类型（null 直接抛），
    //    加 `?? {}` 会多出两条 dead_code 告警。同文件的旧写法是历史遗留，
    //    新代码不再跟着抄。
    return TvboxImportResult.fromJson(jmap(r));
  }

  // ═══════════════════════════════════════════════════════════════════
  //  TVBox「订阅链接 / 检测更新 / 一键更新」（task-12）
  // ═══════════════════════════════════════════════════════════════════
  //
  // 用户拍板：
  // > 填入 tvbox 源的链接，然后他有更新我们也能收得到，不至于更新失效了
  //
  // 与插件那套（[checkPluginUpdate]）**同构**，只差一处：
  // ```text
  // 插件    1 个 .js  ↔ 1 个安装链接 → 一个 id 一个 sidecar 文件
  // TVBox   1 份配置  ↔ 1 个订阅链接 → 一份配置产出几十个源
  //                                  → sidecar 是单文件 map {id: meta}
  // ```
  //
  // ★★ 同一条产品原则：**没有的能力不假装有**
  // ```text
  // 直接贴 JSON 文本导入的源 → 没有链接可查
  //   → needsSource=true，界面不显示「检测更新」按钮，只如实说明「无订阅链接」
  //   → 绝不显示成「已是最新」（那是假装查过了）
  // ```

  /// 列出全部 TVBox 源 + 它们有没有订阅链接（**纯本地读，零网络**）
  ///
  /// # ★ 为什么必须是独立命令（与 [listPluginSources] 同一个理由）
  ///
  /// 界面要在打开设置页时就知道「哪张卡该显示检测更新按钮」。
  /// 若用 [checkTvboxUpdates] 来判断 → 打开设置页会对每个订阅链接发一次 HTTP。
  ///
  /// 联网检测只在用户**真的点按钮**时才跑。
  static Future<TvboxSourceList> listTvboxSources() async {
    final r = await SourinCore.callAsync('list_tvbox_sources');
    return TvboxSourceList.fromJson(jmap(r));
  }

  /// 给某个 TVBox 源指定/清除订阅链接
  ///
  /// ```text
  /// 贴文本导入的源本来查不了更新。用户的合理诉求是：
  /// 「我这个源其实来自这个链接，以后就按它检测更新」→ 传 url 即可。
  /// 传空字符串 = 清除链接（回到"贴文本导入"状态）。
  /// ```
  static Future<void> setTvboxSource(String id, String url) =>
      SourinCore.callAsync('set_tvbox_source', {'id': id, 'url': url});

  /// 检测订阅链接有没有更新（`id` 不传 = 查全部有链接的源）
  ///
  /// # 三种结局都不许静默（与 [checkPluginUpdate] 同一条）
  ///
  /// ```text
  /// ① 没有订阅链接     → 进 skipped，如实说「查不了」
  /// ② 网络/解析失败     → 该条 error != null
  /// ③ 查到了           → added / removed / changed / unchanged
  /// ```
  ///
  /// ⚠️ 一份配置产出几十个源，它们共用同一个链接 —— 后端按链接分组，
  ///    一次下载对比全部，而不是每个源各下一遍。
  static Future<TvboxUpdateCheck> checkTvboxUpdates({String? id}) async {
    final r = await SourinCore.callAsync('check_tvbox_updates', {
      if (id != null) 'id': id,
    });
    return TvboxUpdateCheck.fromJson(jmap(r));
  }

  /// 一键应用订阅链接上的更新
  ///
  /// # 默认值就是"最保守"的那一侧（很重要）
  ///
  /// ```text
  /// applyNew      = true  → 远端新增的站也一起注册（这是用户点"更新"想要的）
  /// deleteMissing = false → 远端已经没有的站**只报告、不删**
  /// ```
  /// 配置作者临时删掉一个站又加回来是常事；静默删掉用户本地的东西
  /// 是不可逆的伤害。要删必须由用户明确勾选（`deleteMissing=true`）。
  static Future<TvboxSourceUpdate> updateTvboxSource(
    String id, {
    bool applyNew = true,
    bool deleteMissing = false,
  }) async {
    final r = await SourinCore.callAsync('update_tvbox_source', {
      'id': id,
      'applyNew': applyNew,
      'deleteMissing': deleteMissing,
    });
    return TvboxSourceUpdate.fromJson(jmap(r));
  }

  /// 移除一个 TVBox 源，并**同时忘掉它的订阅链接**
  ///
  /// ⚠️ 不要用通用的 removeProvider 代替：那只删源、留下孤儿 sidecar，
  ///    将来任何一份配置若恰好产出同一个 id，新源就会**继承**那条陈旧的
  ///    订阅链接（表现为「刚导入的源却显示有更新可查」）。
  static Future<bool> removeTvboxSource(String id) async {
    final r = await SourinCore.callAsync('remove_tvbox_source', {'id': id});
    return r is Map && r['removed'] == true;
  }

  /// 读插件的配置项（声明 + 当前值）
  ///
  /// 返回的两部分：
  /// ```text
  /// fields → 插件声明的配置项（设置页据此渲染表单）
  /// values → 每项的当前值（用户设过的，或声明里的默认值）
  /// ```
  /// 一起返回是为了避免"先画表单再跳一下"的中间态。
  static Future<PluginConfig> pluginConfigGet(String id) async {
    final r = await SourinCore.callAsync('plugin_config_get', {'id': id});
    return PluginConfig.fromJson(jmap(r) ?? {});
  }

  // ═══════════════════════════════════════════════════════════════════
  //  插件「检测更新 / 更新 / 回滚」（task-23）
  // ═══════════════════════════════════════════════════════════════════
  //
  // 用户拍板：
  // > 通过链接检测更新,可以进行回滚
  // > 插件市场暂时不做  github raw 暂时不做
  //
  // 数据来源**只有一条**：当初安装它的那个链接（`plugins/.meta/<id>.json`）。
  //
  // ★★ 最重要的一条：**没有的能力不假装有**
  // ```text
  // 用户手动丢进 plugins/ 的 .js 没有安装链接 → 永远查不了更新。
  // 后端返回 needsSource=true（而不是"已是最新"），
  // 界面据此**不显示**「检测更新」按钮，只如实说明"无安装链接"。
  // ```

  /// 检测**单个**插件是否有更新
  ///
  /// 三种结局都如实返回（见 [PluginUpdateInfo]）：
  /// ```text
  /// needsSource  → 没有安装链接（手动放入的），**查不了**
  /// error != null → 查了但失败（网络/链接失效/不是 JS/无 @version）
  /// 否则          → hasUpdate / remoteVersion
  /// ```
  static Future<PluginUpdateInfo> checkPluginUpdate(String id) async {
    final r = await SourinCore.callAsync('check_plugin_update', {'id': id});
    return PluginUpdateInfo.fromJson(jmap(r) ?? {});
  }

  /// 批量检测（**用户真正会用的**：26 个插件不可能一个个点）
  ///
  /// 返回 `(每个插件的结果, 跳过的数量)`。
  ///
  /// ⚠️ "跳过"= 没有安装链接的（以及个别出错的）。
  ///    界面要显示这个数 —— 否则用户看到列表安安静静，
  ///    会以为"功能坏了"，实际是"这些插件本来就没链接可查"。
  static Future<(List<PluginUpdateInfo>, int)> checkAllPluginUpdates() async {
    final r = await SourinCore.callAsync('check_all_plugin_updates');
    if (r is Map && r['items'] is List) {
      final items = (r['items'] as List)
          .map((e) => PluginUpdateInfo.fromJson(jmap(e) ?? {}))
          .toList();
      final skipped = r['skipped'];
      return (items, skipped is int ? skipped : 0);
    }
    return (<PluginUpdateInfo>[], 0);
  }

  /// 更新到远端最新版（**用户点了才执行** —— 绝不自动覆盖）
  ///
  /// 内部会：下载 → 校验 @id 一致 → 归档旧版到 `.versions/` → 写盘 → 热重载。
  /// `updated == false` 表示"内容一致，无需更新"（不是错误）。
  static Future<PluginUpdateResult> updatePluginFromSource(String id) async {
    final r = await SourinCore.callAsync('update_plugin_from_source', {'id': id});
    return PluginUpdateResult.fromJson(jmap(r) ?? {});
  }

  /// 列出某个插件的**历史版本档**（新的在前）—— 回滚弹窗的数据源
  ///
  /// 没有历史时返回空列表（**不是错误**）。
  static Future<List<PluginVersionEntry>> listPluginVersions(String id) async {
    final r = await SourinCore.callAsync('list_plugin_versions', {'id': id});
    if (r is List) {
      return r
          .map((e) => PluginVersionEntry.fromJson(jmap(e) ?? {}))
          .toList();
    }
    return <PluginVersionEntry>[];
  }

  /// 回滚到指定历史版本
  ///
  /// ⚠️ 会**先把当前版本也归档一份**（对称性）——
  /// 否则"回滚错了想再回来"就回不去了。
  /// ⚠️ 只换 `.js`，**不碰 `plugins/.data/`**（用户配置）。
  static Future<PluginUpdateResult> rollbackPlugin(
    String id,
    String version,
  ) async {
    final r = await SourinCore.callAsync('rollback_plugin', {
      'id': id,
      'version': version,
    });
    return PluginUpdateResult.fromJson(jmap(r) ?? {});
  }

  /// 给插件指定/清除安装来源链接
  ///
  /// # 为什么这是**真实功能**而不是测试开关
  ///
  /// ```text
  /// 本机现有 26 个插件全是手动放入的（没有任何 meta）
  /// → 做完功能后界面上一个「检测更新」按钮都不会出现。
  /// 而用户的合理诉求是：「我这个手动放的插件其实来自这个链接，
  /// 以后就按它检测更新」—— 传 url 即可。
  /// 传空字符串 = 清除来源（回到"手动放入"状态）。
  /// ```
  static Future<void> setPluginSource(String id, String url) =>
      SourinCore.callAsync('set_plugin_source', {'id': id, 'url': url});

  /// 列出**哪些插件有安装来源**（`{ id: sourceUrl }`）
  ///
  /// # ★ 为什么必须是独立命令（界面不能用 checkAllPluginUpdates 代替）
  ///
  /// ```text
  /// 界面要在**页面加载时**就知道"哪张卡该显示「检测更新」按钮"。
  /// 若用批量检测来判断 → 打开设置页会对每个插件发一次 HTTP 请求
  /// → 设置页要等几秒、还可能被 CDN 限流。
  /// ```
  /// 本命令**纯本地读 sidecar**（毫秒级、零网络），
  /// 联网检测只在用户**真的点按钮**时才跑。
  ///
  /// ⚠️ 只包含**有来源**的插件 —— 查到 null 就是"查不了"，
  ///    界面据此**不显示**按钮（如实，不假装）。
  static Future<Map<String, String>> listPluginSources() async {
    final r = await SourinCore.callAsync('list_plugin_sources');
    final raw = r is Map ? r['sources'] : null;
    if (raw is Map) {
      return raw.map((k, v) => MapEntry('$k', '$v'));
    }
    return <String, String>{};
  }

  /// 写插件的配置项
  static Future<int> pluginConfigSet(
    String id,
    Map<String, dynamic> values,
  ) async {
    final r = await SourinCore.callAsync('plugin_config_set', {
      'id': id,
      'values': values,
    });
    return r is int ? r : 0;
  }

  // ═══════════════════════════════════════════════════════════════════
  //  登录 / 会话
  // ═══════════════════════════════════════════════════════════════════

  /// 用账号密码登录某个源
  static Future<Map<String, dynamic>> providerLogin(
    String provider,
    String username,
    String password,
  ) async {
    final r = await SourinCore.callAsync('provider_login', {
      'provider': provider,
      'username': username,
      'password': password,
    });
    return jmap(r) ?? {};
  }

  /// 登出
  static Future<void> providerLogout(String provider) =>
      SourinCore.callAsync('provider_logout', {'provider': provider});

  /// 取当前会话（null = 未登录）
  static Future<Map<String, dynamic>?> providerSession(String provider) async {
    final r = await SourinCore.callAsync('provider_session', {'provider': provider});
    /*
     * ★★★ 必须用 `jmapOrNull`（2026-09-23 同类 bug 的第二处）
     *
     * 后端签名是 `Result<Option<Session>, String>` ——
     * **未登录时返回 JSON null**，这是正常状态，不是错误。
     *
     * 用 `jmap` 会抛 `期望对象，实际收到 Null`，
     * 表现是「设置页一打开就报错」而不是「显示未登录」。
     */
    return jmapOrNull(r);
  }

  /// 确保会话可用（必要时自动登录）
  static Future<bool> ensureProviderSession(String provider) async {
    final r = await SourinCore.callAsync('ensure_provider_session', {
      'provider': provider,
    });
    return r == true;
  }

  /// 忘记凭据
  ///
  /// 优先走插件的 `forgetCredentials()` —— 插件把凭据存在自己的
  /// 私有存储里（`plugins/.data/<id>.json`），不是系统钥匙串。
  static Future<void> forgetProviderCredentials(String provider) =>
      SourinCore.callAsync('forget_provider_credentials', {
        'provider': provider,
      });

  /// ★ 申请一个登录二维码（扫码登录第一步）
  ///
  /// 返回 `{ key, url, svg, hint? }`：
  /// - `key` —— 轮询凭据，交给 `providerQrLoginPoll`
  /// - `url` —— 二维码里编的原始链接（渲染失败时可当文本兜底显示）
  /// - `svg` —— **宿主渲染好的**二维码 SVG，直接喂给 `QrView`
  ///
  /// ⚠️ 源不支持扫码时后端返回错误「该源不支持扫码登录」——
  /// 调用方应据此**不显示**扫码入口（先看 `caps.loginQrSupported`
  /// 更省事，那正是它存在的理由）。
  static Future<Map<String, dynamic>> providerQrLoginStart(
    String provider,
  ) async {
    final r = await SourinCore.callAsync('provider_qr_login_start', {
      'provider': provider,
    });
    return jmap(r) ?? {};
  }

  /// ★ 轮询扫码状态（扫码登录第二步）
  ///
  /// ⚠️ **调用方按约 2 秒的间隔调**，直到 `status` 变成
  /// `confirmed` / `expired` / `failed` 之一为止。
  /// 后端一次调用只问一次、不循环 —— 弹窗关掉就自然停了。
  ///
  /// 返回 `{ status, message, session? }`，`status` 取值：
  /// `pending` 未扫 / `scanned` 已扫待确认 / `confirmed` 成功 /
  /// `expired` 已失效（要重新 `providerQrLoginStart`）/ `failed` 出错。
  static Future<Map<String, dynamic>> providerQrLoginPoll(
    String provider,
    String key,
  ) async {
    final r = await SourinCore.callAsync('provider_qr_login_poll', {
      'provider': provider,
      'key': key,
    });
    return jmap(r) ?? {};
  }


  // ═══════════════════════════════════════════════════════════════════
  //  插件弹幕（task-T2，2026-10-16）
  // ═══════════════════════════════════════════════════════════════════

  /// 取某一集的弹幕列表（插件提供）
  ///
  /// # ⚠️ 当前**还没有 UI 调用点**（这是有意的，不是漏接）
  ///
  /// 本仓规矩「新增公开 API 必须同时给出调用点，否则按死代码处理；
  /// 例外要写明为什么现在不接」—— 这里就是那个例外，理由：
  /// ```text
  /// ① 取弹幕是主体价值，发送是增强；先交付主体（已交付）
  /// ② 发送入口要落在弹幕面板上，而 lib/ui/widgets/danmaku_settings_dialog.dart
  ///    正在被另一个并行任务改（统一弹窗外壳）
  /// ③ 现在硬接 UI 会与那个改动互相踩 —— 等它收工再派入口
  /// ```
  /// ⇒ 本方法目前只被 `.probe/plugin-work/e2e_danmaku_chain_test.dart`
  ///    端到端验证覆盖（真插件 → 真桥接 → 真解析器）。
  ///
  /// # ★ 返回值语义 —— 调用方**必须**区分这三件事
  /// ```text
  /// 非空 items        这一集有弹幕
  /// 空 items          ★ 这一集**真的**没人发弹幕（合法结果，不是错误）
  /// 抛异常(Unsupported) ★ 这个源**不支持**弹幕（另一件事）
  /// ```
  /// 混起来用户就无法判断「是源不支持还是真没弹幕」—— 这是明确的设计要求。
  ///
  /// # ⚠️ cid 由**宿主**补位（不要以为插件一定会给）
  ///
  /// 契约里 `cid` 是**可选**的（外部视频源弹幕 XML 没有这个概念）。
  /// 而 `DanmakuComment.fromJson` 在 `cid == null` 时**整条丢弃且不报错** ——
  /// 所以 Rust 桥接层会按下标 + 1 补位（`DanmakuBundle::fill_missing_cids`）。
  /// ⇒ 到这里时每条都该有 cid；若仍缺，说明桥接层被绕过，那是个 bug。
  static Future<PluginDanmakuBundle> providerDanmakuList(
    String provider, {
    String mediaId = '',
    String episodeId = '',
    String? title,
    String? episodeTitle,
    int? duration,
  }) async {
    final r = await SourinCore.callAsync('provider_danmaku_list', {
      'provider': provider,
      /*
       * ★★★ 键名必须是 **snake_case**，不是 Dart 侧的驼峰（2026-10-17 修正）
       *
       * # 为什么（真 bug，会静默丢字段）
       *
       * `req` 这一层是**嵌套对象**，FFI 那边直接走：
       * ```text
       * serde_json::from_value::<DanmakuRequest>(v["args"]["req"])
       * ```
       * 而 serde **只认 Rust 字段名（snake_case）**。
       * 关键：`DanmakuRequest` 的字段**全都带 `#[serde(default)]`** ——
       * 所以驼峰的键**不会报错**，而是被**当作不存在的字段静默丢弃**：
       * ```text
       * Dart 发 { mediaId: "m1", episodeId: "ep1" }
       *   ⇒ Rust 收到 media_id: "" / episode_id: ""  ← 空串，**零报错**
       *   ⇒ 插件拿到的剧集 id 是空 ⇒ 取弹幕全失败，且看不出原因
       * ```
       *
       * ⚠️ **注意与 `Args` 的区别**：外层具名参数（如 `provider`）走
       *    `crate::args::Args`，它**自动兼容** camelCase（那是为照搬原版
       *    前端代码保留的隐式契约，见 args.rs 的说明）。
       *    但嵌套 `req` 这一层**没经过 Args**，所以没有那层兼容。
       *
       * ⚠️ 别再"顺手"改回驼峰 —— 有跨语言门禁钉着：
       *    `test/zz_danmaku_ffi_keys_test.dart` 会从 **Rust 源码**里
       *    读取真实字段名来比对，改错即红。
       */
      'req': {
        'media_id': mediaId,
        'episode_id': episodeId,
        if (title != null) 'title': title,
        if (episodeTitle != null) 'episode_title': episodeTitle,
        if (duration != null) 'duration': duration,
      },
    });
    // `jmap` 非空（解不出会抛）—— 不要写 `?? const {}`，那是死代码
    return PluginDanmakuBundle.fromJson(jmap(r));
  }

  /// 发送一条弹幕（插件提供）
  ///
  /// # ★★ 纪律：不支持的站点会**如实抛异常**，不会假装成功
  ///
  /// 返回 `true` 是「**上游确实收下了**」的承诺。
  /// 未实现 / 上游拒绝 ⇒ 抛异常（`unsupported:` / `unauthorized:`）。
  ///
  /// ⚠️ 调用方**不要**做自动重试：发错撤不回，多数站点不支持删除。
  ///    发送中要禁用按钮（防连点），失败要**原样透出上游理由**。
  static Future<PluginDanmakuSendResult> providerDanmakuSend(
    String provider, {
    required String episodeId,
    required String text,
    double? time,
    int? mode,
    int? color,
    int? progressMs,
  }) async {
    final r = await SourinCore.callAsync('provider_danmaku_send', {
      'provider': provider,
      // 同样必须 snake_case（理由见 providerDanmakuList 里的长注释）
      'req': {
        'episode_id': episodeId,
        'text': text,
        if (time != null) 'time': time,
        if (mode != null) 'mode': mode,
        if (color != null) 'color': color,
        /*
         * ★ 2026-10-17（Lead 修，原 dlg-provider 笔误）：
         *   这里**判断式**误写成了 JSON 的 key 名 `progress_ms`，
         *   而形参名是 camelCase 的 `progressMs` ⇒ `undefined_identifier`，
         *   全仓编译不过（连带阻塞了 resume-fix 的 T9 验收）。
         *
         * ⇒ 删掉这个 if 分支，直接放进 map（见下）。
         *   理由是**语义更对**：`progress_ms` 是「以毫秒计的播放进度」，
         *   **0 是合法值**（从头开始发弹幕），
         *   写成 `if (x != null)` 会把 0 和 null 混为一谈。
         *   改为由后端按 `Option<i64>` 处理（Rust 侧已支持）。
         */
        'progress_ms': progressMs,
      },
    });
    return PluginDanmakuSendResult.fromJson(jmap(r));
  }

  // ═══════════════════════════════════════════════════════════════════
  //  站点代理
  // ═══════════════════════════════════════════════════════════════════

  /// 全部源的代理配置
  static Future<Map<String, ProxyConfig>> listProxyConfigs() async {
    final r = await SourinCore.callAsync('list_proxy_configs');
    final m = jmap(r);
    if (m == null) return {};
    return m.map(
      (k, v) => MapEntry(k, ProxyConfig.fromJson(jmap(v) ?? {})),
    );
  }

  /// 设置某源的代理
  ///
  /// ★ 写后**主动失效缓存**（原版注释：用户改了代理设置时主动失效）——
  ///   漏掉的话用户改完再进来看到的是旧值。
  static Future<void> setProxyConfig(String provider, ProxyConfig config) async {
    await SourinCore.callAsync('set_proxy_config', {
      'provider': provider,
      'config': config.toJson(),
    });
    ProxyCache.invalidate();
  }

  /// 清除某源的代理（写后失效缓存）
  static Future<void> clearProxyConfig(String provider) async {
    await SourinCore.callAsync('clear_proxy_config', {'provider': provider});
    ProxyCache.invalidate();
  }

  /// 设置代理密码（存系统钥匙串，不落库）
  ///
  /// ★ 写后失效**该源的密码标记** —— 全量配置没变，不必整份丢掉。
  static Future<void> setProxyPassword(String provider, String password) async {
    await SourinCore.callAsync('set_proxy_password', {
      'provider': provider,
      'password': password,
    });
    ProxyCache.invalidatePassword(provider);
  }

  /// 是否已设置代理密码（**不返回密码本身**）
  static Future<bool> hasProxyPassword(String provider) async {
    final r = await SourinCore.callAsync('has_proxy_password', {
      'provider': provider,
    });
    final m = jmap(r);
    return m?['has'] == true;
  }

  /// 测试代理连通性
  static Future<ProxyTestResult> testProxy(String provider) async {
    final r = await SourinCore.callAsync('test_proxy', {'provider': provider});
    return ProxyTestResult.fromJson(jmap(r) ?? {});
  }

  /// 系统代理提示（检测到系统代理时给用户一条提示）
  static Future<String?> systemProxyHint() async {
    final r = await SourinCore.callAsync('system_proxy_hint');
    // ★ 后端是 `Result<Option<String>, String>` —— 用 jmapOrNull
    final m = jmapOrNull(r);
    final h = m?['hint'];
    return h is String && h.isNotEmpty ? h : null;
  }

  // ═══════════════════════════════════════════════════════════════════
  //  备份
  // ═══════════════════════════════════════════════════════════════════

  /// 备份预览（不写盘，只报告"会导出什么"）
  static Future<BackupPreview> backupPreview() async {
    final r = await SourinCore.callAsync('backup_preview');
    return BackupPreview.fromJson(jmap(r) ?? {});
  }

  /// 备份的默认文件名（含设备 id 与日期）
  static Future<String> backupDefaultName() async {
    final r = await SourinCore.callAsync('backup_default_name');
    return r is String ? r : 'backup.zip';
  }

  /// 导出备份到指定路径
  ///
  /// # ★ 登录态（CS-1）
  ///
  /// 传了 [passphrase] ⇒ 用**与云同步完全同一套**加密把登录态打进包里
  /// （`credentials::encrypt`，不是第二套格式）。
  /// 不传 ⇒ 包里**不含登录态**，且返回值里 `credentialsIncluded == false`
  /// + 一句 `credentialsNote` —— **界面必须显示它**，
  /// 不许让用户以为"备份了全部数据"。
  ///
  /// ⚠️ 口令**不进包**（包是用户会分发的东西）：导入时要重新输入。
  static Future<BackupExportResult> backupExport(
    String path, {
    String? passphrase,
  }) async {
    final r = await SourinCore.callAsync('backup_export', {
      'path': path,
      if (passphrase != null && passphrase.isNotEmpty) 'passphrase': passphrase,
    });
    return BackupExportResult.fromJson(jmap(r) ?? {});
  }

  /// 检视一个备份文件（不导入，只报告内容）
  static Future<BackupPreview> backupInspect(String path) async {
    final r = await SourinCore.callAsync('backup_inspect', {'path': path});
    return BackupPreview.fromJson(jmap(r) ?? {});
  }

  /// ★ 导入备份 —— **按时间戳合并，不是覆盖**
  ///
  /// # 六类数据的策略各不相同
  ///
  /// ```text
  /// ① 收藏/追更  按 updated_at 取新；保留本机的分组/别名
  /// ② 进度       按 updated_at 取新（不倒退）
  /// ③ 历史       直接追加（"看过"的记录无冲突概念）
  /// ④ 片头片尾   按 updated_at 取新
  /// ⑤ 源配置     只补新的，同 id 保留本机的
  /// ⑥ 插件       同名内容相同则跳过（幂等，重复导入不产生副本）
  /// ```
  /// **不能简化成"导入即覆盖"** —— 那会把用户本机较新的进度打回旧值
  ///（备份可能是三天前的，而用户这两天又看了几集）。
  ///
  /// # ★ 登录态（CS-1）
  ///
  /// 包里含登录态时**必须**给对 [passphrase]，否则后端返回
  /// 「口令不正确（或这个备份包已被改动），登录态没有导入」。
  ///
  /// ★★ 后端**不会**静默跳过凭据只导入其它平面 ——
  ///    那会让用户以为"恢复成功"，而每个源其实都要重新登。
  static Future<ImportSummary> backupImport(
    String path, {
    String? passphrase,
  }) async {
    final r = await SourinCore.callAsync('backup_import', {
      'path': path,
      if (passphrase != null && passphrase.isNotEmpty) 'passphrase': passphrase,
    });
    return ImportSummary.fromJson(jmap(r) ?? {});
  }

  /// 抓取平台自带历史并保存为备份镜像（**只读，不回写平台**）
  static Future<int> backupPlatformHistory(
    String provider, {
    String? deviceId,
  }) async {
    final r = await SourinCore.callAsync('backup_platform_history', {
      'provider': provider,
      if (deviceId != null) 'device_id': deviceId,
    });
    return r is int ? r : 0;
  }

  /// 平台历史镜像列表
  static Future<List<Map<String, dynamic>>> listPlatformHistory({
    int limit = 100,
  }) async {
    final r = await SourinCore.callAsync('list_platform_history', {'limit': limit});
    // 元素本身就是对象 → 用 jlist<Map<String, dynamic>> 直接透传
    return jlist<Map<String, dynamic>>(r, (m) => m);
  }

  // ═══════════════════════════════════════════════════════════════════
  //  云盘同步（WebDAV）
  // ═══════════════════════════════════════════════════════════════════

  /// 配置 WebDAV 并**立即自检**
  ///
  /// # 密码为空时沿用钥匙串里已存的
  ///
  /// 支持"用户只改地址"的场景 —— 否则改地址就得重新输密码。
  ///
  /// # 内部顺序：先建目录再自检
  ///
  /// 原版 2026-09-15 修的 bug：`test()` 会 PROPFIND 含 `remote_dir`
  /// 的完整路径，目录不存在就 404 → 报「路径不存在：请确认 WebDAV
  /// 地址包含目标目录」，**用户明明填对了地址却被告知路径错**。
  static Future<String> configureWebdav({
    required String baseUrl,
    required String username,
    String password = '',
    String? remoteDir,
  }) async {
    final r = await SourinCore.callAsync('configure_webdav', {
      'base_url': baseUrl,
      'username': username,
      'password': password,
      if (remoteDir != null) 'remote_dir': remoteDir,
    });
    return r is String ? r : '已配置';
  }

  /// 断开云盘（不动钥匙串里的凭据）
  static Future<void> disconnectSync() =>
      SourinCore.callAsync('disconnect_sync');

  // ═══════════════════════════════════════════════════════════════════
  //  云盘同步 · 探针注入点
  // ═══════════════════════════════════════════════════════════════════
  //
  // ⚠️ **生产路径永不为非 null** —— 只有 widget 测试会装一次，
  //    测试结束即复原。产品代码里没有任何地方写它们。
  //
  // # 为什么需要（这是实测逼出来的）
  //
  // 面板**绝大部分 UI 只在「已连接」时存在**：
  //
  // ```text
  // 连接详情（服务/地址/账号/目录/上次同步/上次备份）  ← 只有已连接才有
  // 四个动作按钮（测试连接/立即同步/立即备份/断开）   ← 只有已连接才有
  // 自动同步设置区                                  ← 只有已连接才有
  // 云端备份列表（含删除按钮）                       ← 只有已连接才有
  // ```
  //
  // 而 `flutter test` 环境里**加载不了核心库**（worktree 根目录没有
  // `sourin_core.dll`）⇒ `syncStatus()` 抛异常 ⇒ 面板走降级分支
  // ⇒ 永远停在「未配置」态 ⇒ 上面那些**一条都渲染不出来**。
  //
  // 结果就是：这块 UI 既没有截图、也没有布局断言，等于没测。
  // 有了下面这几个注入点，测试就能造出「已连接 + 有备份列表」的形态，
  // 把真正会被用户看到的界面**渲染出来并量它**。
  //
  // # 纪律：只给**只读**的三个接口
  //
  // 注入点只覆盖 `sync_status` / `sync_settings_get` / `sync_backup_list`
  // —— 它们都只是读。写接口（configure / test / sync / 备份 / 删除）
  // **不给注入点**：测试不需要它们，而且注入了就等于把「按钮点了会发生什么」
  // 从测试里拿掉，那正是最该测的部分（真跑由 t94 在 Rust 侧端到端覆盖）。
  @visibleForTesting
  static Future<SyncStatus> Function()? debugSyncStatusFetcher;

  @visibleForTesting
  static Future<SyncSettings> Function()? debugSyncSettingsFetcher;

  @visibleForTesting
  static Future<List<SyncBackupEntry>> Function()? debugSyncBackupListFetcher;

  /// 凭据同步状态的注入点（同上面三个的理由 —— 只读接口才给注入）
  @visibleForTesting
  static Future<CredentialsStatus> Function()? debugCredentialsStatusFetcher;

  /// 装/卸这三个注入点（`null` = 恢复真实实现）
  @visibleForTesting
  static void installSyncDebugFetchers({
    Future<SyncStatus> Function()? status,
    Future<SyncSettings> Function()? settings,
    Future<List<SyncBackupEntry>> Function()? backups,
    Future<CredentialsStatus> Function()? credentials,
  }) {
    debugSyncStatusFetcher = status;
    debugSyncSettingsFetcher = settings;
    debugSyncBackupListFetcher = backups;
    debugCredentialsStatusFetcher = credentials;
  }

  /// 同步状态（设置页据此显示「已连接 / 未配置」）
  static Future<SyncStatus> syncStatus() async {
    final f = debugSyncStatusFetcher;
    if (f != null) return f();
    final r = await SourinCore.callAsync('sync_status');
    return SyncStatus.fromJson(jmap(r) ?? {});
  }

  /// 测试云盘连通性
  static Future<String> testSync() async {
    final r = await SourinCore.callAsync('test_sync');
    return r is String ? r : 'OK';
  }

  /// 立即同步 —— 返回每一步的汇总
  ///
  /// ★ 返回里**一定有一条 `plane == "credentials"`**（CS-1）。
  ///   没有口令时它的 `note` 是「凭据未同步：…」——
  ///   [SyncSummary.note] 必须显示出来，不许只报"同步完成"。
  static Future<List<SyncSummary>> syncNow() async {
    final r = await SourinCore.callAsync('sync_now');
    return jlist<SyncSummary>(r, SyncSummary.fromJson).toList();
  }

  // ── ★ 凭据同步（CS-1，2026-10-19）────────────────────────────────
  //
  // 登录态随云同步：口令存**系统钥匙串**（不落盘、不进导出包），
  // 凭据用 PBKDF2(600k) + AES-256-GCM 加密后传 `data/credentials.enc`。
  //
  // ⚠️ 下面三个接口**都不需要已连接** —— 纯本地读 / 只写钥匙串与设置文件。

  /// 读凭据同步状态
  ///
  /// ★★ **永不失败**（纯本地读），且返回里带一个**派生**字段
  ///    `willSync = enabled && passphraseSet`。
  ///    界面**只看 `willSync`** 就不可能假绿 ——
  ///    自己拼 `enabled && passphraseSet` 必然有人漏一个条件。
  static Future<CredentialsStatus> credentialsStatus() async {
    final f = debugCredentialsStatusFetcher;
    if (f != null) return f();
    final r = await SourinCore.callAsync('credentials_status');
    return CredentialsStatus.fromJson(jmap(r) ?? {});
  }

  /// 设 / 改 / 清凭据同步口令（空串 = 清除）
  ///
  /// 返回改完之后的完整状态（同 [credentialsStatus]），可直接刷 UI。
  static Future<CredentialsStatus> setCredentialsPassphrase(
    String passphrase,
  ) async {
    final r = await SourinCore.callAsync('set_credentials_passphrase', {
      'passphrase': passphrase,
    });
    return CredentialsStatus.fromJson(jmap(r) ?? {});
  }

  /// 开关凭据同步
  ///
  /// ⚠️ 允许「开着但没口令」—— 但状态里 `willSync` 会是 `false`，
  ///    界面必须显示「凭据未同步」，**不许**显示「同步完成」。
  static Future<CredentialsStatus> setCredentialsEnabled(bool enabled) async {
    final r = await SourinCore.callAsync('set_credentials_enabled', {
      'enabled': enabled,
    });
    return CredentialsStatus.fromJson(jmap(r) ?? {});
  }

  /// 只同步凭据这一个平面（不等整轮同步）
  static Future<SyncSummary> syncCredentialsNow() async {
    final r = await SourinCore.callAsync('sync_credentials_now');
    return SyncSummary.fromJson(jmap(r) ?? {});
  }

  // ── 云盘设置 + 整体备份（2026-09-29 新增，契约 §1/§2/§5）────────────

  /// 读云盘设置 + 自动备份设置
  ///
  /// # ★ 这个接口**永远不会失败**（后端契约 §3.3）
  ///
  /// 纯本地文件读，不碰网络。文件不存在 / JSON 坏了 / 字段缺失 ⇒
  /// 后端返回**默认值**（`retainCount: 10`、`autoIntervalMinutes: 30`、
  /// `autoBackupIntervalMinutes: 1440`、`autoEnabled: false`）。
  /// 因为它比「用户配云盘」早得多就会被调用（一进「备份与恢复」页就调）。
  static Future<SyncSettings> syncSettings() async {
    final f = debugSyncSettingsFetcher;
    if (f != null) return f();
    final r = await SourinCore.callAsync('sync_settings_get');
    return SyncSettings.fromJson(jmap(r) ?? {});
  }

  /// 改云盘设置 / 自动备份设置
  ///
  /// 只传要改的字段（`null` = 保持不动）；返回改完之后的**完整**设置。
  /// ★ 不需要已连接 —— 这些是本地偏好，可以先设再连。
  static Future<SyncSettings> setSyncSettings({
    int? retainCount,
    bool? autoEnabled,
    int? autoIntervalMinutes,
    bool? autoOnChange,
    int? autoBackupIntervalMinutes,
  }) async {
    final r = await SourinCore.callAsync('sync_settings_set', {
      if (retainCount != null) 'retain_count': retainCount,
      if (autoEnabled != null) 'auto_enabled': autoEnabled,
      if (autoIntervalMinutes != null) 'auto_interval_minutes': autoIntervalMinutes,
      if (autoOnChange != null) 'auto_on_change': autoOnChange,
      if (autoBackupIntervalMinutes != null)
        'auto_backup_interval_minutes': autoBackupIntervalMinutes,
    });
    return SyncSettings.fromJson(jmap(r) ?? {});
  }

  /// 立即上传一份整体备份（按日期时间命名），并按保留份数清理旧份
  static Future<SyncBackupResult> syncBackupNow() async {
    final r = await SourinCore.callAsync('sync_backup_now');
    return SyncBackupResult.fromJson(jmap(r) ?? {});
  }

  /// 列出云端的整体备份
  ///
  /// ★ 没配云盘时后端返回**空列表**（不是报错）—— 界面会无条件调它。
  static Future<List<SyncBackupEntry>> syncBackupList() async {
    final f = debugSyncBackupListFetcher;
    if (f != null) return f();
    final r = await SourinCore.callAsync('sync_backup_list');
    return jlist<SyncBackupEntry>(r, SyncBackupEntry.fromJson).toList();
  }

  /// 删掉云端的一份整体备份
  ///
  /// ⚠️ WebDAV 上删除通常**不进回收站**（坚果云/Yandex 都是直接永久删除）。
  static Future<void> syncBackupDelete(String name) =>
      SourinCore.callAsync('sync_backup_delete', {'name': name});

  /// 同步某源的平台历史（同时存本地镜像）
  static Future<int> syncPlatformHistory(String provider) async {
    final r = await SourinCore.callAsync('sync_platform_history', {
      'provider': provider,
    });
    return r is int ? r : 0;
  }

  // ═══════════════════════════════════════════════════════════════════
  //  局域网遥控
  // ═══════════════════════════════════════════════════════════════════

  /// 读遥控状态（不改任何东西 —— UI 轮询用这个）
  static Future<RemoteStatus> remoteStatus() async {
    final r = await SourinCore.callAsync('remote_status_cmd');
    return RemoteStatus.fromJson(jmap(r) ?? {});
  }

  /// 开启遥控
  ///
  /// # 手动开启 = 用户希望它开着 → 会自动记住「开机自启」
  ///
  /// 这样用户不必再去别处找开关：开着的时候重启，它自己就回来了。
  static Future<RemoteStatus> remoteStart({int? port}) async {
    final r = await SourinCore.callAsync('remote_start', {
      if (port != null) 'port': port,
    });
    return RemoteStatus.fromJson(jmap(r) ?? {});
  }

  /// 关闭遥控
  ///
  /// # 会记住「不自动开启」
  ///
  /// 遥控默认开机自启；如果用户明确关掉了、下次开机又被拉起来，
  /// 那是直接无视用户的意愿 —— 比「不默认开」更烦人。
  ///
  /// 返回值里的 `stopped` 字段如实反映是否真的停了
  ///（超时可能没停干净，UI 应提示）。
  static Future<RemoteStatus> remoteStop() async {
    final r = await SourinCore.callAsync('remote_stop');
    return RemoteStatus.fromJson(jmap(r) ?? {});
  }

  /// 换一个随机配对码
  static Future<RemoteStatus> remoteRefreshPin() async {
    final r = await SourinCore.callAsync('remote_refresh_pin');
    return RemoteStatus.fromJson(jmap(r) ?? {});
  }

  /// 设置/清除固定配对码（传空串 = 清除）
  ///
  /// # 与随机码重合会被拒绝
  ///
  /// 否则「换一个随机码」之后用户会以为固定码还有效，
  /// 实际两个码变成同一个了。
  static Future<RemoteStatus> remoteSetFixedPin(String pin) async {
    final r = await SourinCore.callAsync('remote_set_fixed_pin', {'pin': pin});
    return RemoteStatus.fromJson(jmap(r) ?? {});
  }

  /// 设置开机自启（只改偏好，不影响当前是否在跑）
  static Future<bool> remoteSetAutoStart(bool enabled) async {
    final r = await SourinCore.callAsync(
      'remote_set_auto_start',
      {'enabled': enabled},
    );
    return r == true;
  }

  /// 读「开机是否自启」偏好
  static Future<bool> remoteAutoStart() async {
    final r = await SourinCore.callAsync('remote_auto_start');
    return r == true;
  }

  /// 上报本机播放状态给遥控服务（手机端据此显示"正在播什么"）
  static Future<void> remoteReportState(Map<String, dynamic> state) =>
      SourinCore.callAsync('remote_report_state', {'state': state});

  /// 取待执行的遥控命令（宿主轮询这个）
  static Future<List<Map<String, dynamic>>> remoteTakeCommands() async {
    final r = await SourinCore.callAsync('remote_take_commands');
    // 元素本身就是对象 → 用 jlist<Map<String, dynamic>> 直接透传
    return jlist<Map<String, dynamic>>(r, (m) => m);
  }

  /// 上报搜索结果给遥控服务（手机端显示）
  static Future<void> remoteSetSearch(Map<String, dynamic> payload) =>
      SourinCore.callAsync('remote_set_search', {'payload': payload});

  /// 上报首页数据给遥控服务（手机端显示）
  static Future<void> remoteSetHome(Map<String, dynamic> payload) =>
      SourinCore.callAsync('remote_set_home', {'payload': payload});

  // ═══════════════════════════════════════════════════════════════════
  //  Provider 导入 / 编辑（任务 R 追加）
  // ═══════════════════════════════════════════════════════════════════
  //
  // # 这一段为什么是**追加**在文件末尾
  //
  // 同一轮里有多个代理在改这个文件（内容源区块 / 备份面板 / 动画）。
  // 往中间插会和别人的 hunk 撞车，所以统一往末尾追加。
  //
  // # 先说清一件事：**六个命令的包装本来就都在**
  //
  // 审计把 `import_declarative_provider` / `install_http_provider` /
  // `get_provider_config` / `get_provider_order` 列为「缺口」，指的是
  // **UI 入口缺失**，不是包装缺失。逐个核对（避免重复造轮子）：
  // ```text
  // listProviders()             :97    ✓ 已有
  // getProviderOrder()          :103   ✓ 已有（返回 List<String>）
  // getProviderConfig()         :133   ✓ 已有（返回 Map<String,dynamic>?）
  // healthSweep()               :145   ✓ 已有
  // importDeclarativeProvider() :153   ✓ 已有
  // installHttpProvider()       :162   ✓ 已有（base_url + headers）
  // reloadPlugins()             :780   ✓ 已有
  // ```
  // 所以这里**只补一个真正缺的东西**：`PersistedProvider` 的**类型化模型**。
  //
  // # 为什么非要有这个模型（`getProviderConfig` 的返回不够用）
  //
  // `getProviderConfig` 返回裸 `Map<String,dynamic>?`，调用方要自己：
  // ```text
  // ① 判 kind（"declarative" / "http"）决定回填哪个表单
  // ② 声明式：jsonDecode 那串 json 才能 pretty 打印
  // ③ HTTP：headers 缺失时是 null 还是 {}（两种都会出现）
  // ```
  // 这三件事分散在 UI 里做，就是「重复的契约逻辑」——
  // 后端加第三种持久化形态时会改到一处、漏掉另一处。
  // 收进一个 `fromJson` 里，UI 只面对一个**封闭的** switch。

  /// ★ 读第三方源的**原始配置**（「编辑」回填表单用）
  ///
  /// 后端签名是 `Result<Option<PersistedProvider>, String>`，
  /// 返回 JSON null 表示**这个 id 不是第三方源**（内置源 / JS 插件）——
  /// 那是**正常情况不是错误**。
  ///
  /// ⚠️ 必须用 `jmapOrNull`：`jmap` 对 null 会抛
  ///    「期望对象，实际收到 Null」。这个坑本文件已踩过三次
  ///    （见 [getProgress] / [getSkipMarker] / [providerSession] 的注释）。
  static Future<ProviderImportSeed?> getProviderImportSeed(String id) async {
    final r = await SourinCore.callAsync('get_provider_config', {'id': id});
    final m = jmapOrNull(r);
    return m == null ? null : ProviderImportSeed.fromJson(m);
  }

  // ═══════════════════════════════════════════════════════════════════
  //  站点代理 —— 便捷读写（任务 P2 追加）
  // ═══════════════════════════════════════════════════════════════════
  //
  // # 为什么这里还要补东西（上面 8 个代理方法本来就有）
  //
  // 上面那 8 个（`listProxyConfigs` / `setProxyConfig` / …）**签名都是对的**，
  // 错的是它们依赖的 `models.dart::ProxyConfig` —— 那个类的字段
  // 是 `{enabled, url, username, hasPassword}`，而 Rust 是
  // `{mode, url, bypass, scope, username}`。于是：
  // ```text
  // 写：`enabled` 被 serde 静默丢弃 + `mode` 缺省 Direct
  //     → `uses_proxy()` false → **代理永远不生效且不报错**
  // 读：从不下发的 `enabled` 键 → UI 永远显示"未启用"
  // ```
  // `models.dart` 已按 Rust 修好（见那里的类文档）。
  //
  // 这一段的**唯一新增**是 [proxyConfigFor]：面板只需要"某一个源的配置"，
  // 而 `list_proxy_configs` 返回的是 `HashMap<providerId, ProxyConfig>`
  // （Rust 签名，不是"当前 provider 的配置"）。让每个调用方自己
  // `all[id]` + `ProxyConfig.fromJson`，就是又一份私有契约 ——
  // 收在这里，字段变更只改一处。
  //
  // ⚠️ 这一段是**追加**在类末尾的（不插进中间）：同一轮有多个代理
  //    在改这个文件，往中间插会和别人的 hunk 撞车。

  /// 读**某一个源**的代理配置
  ///
  /// # 为什么不是 `get_proxy_config`
  ///
  /// 因为**那个命令不存在** —— 原版与我们的 Rust 核心都只注册了
  /// `list_proxy_configs`（全量 Map）+ `set_proxy_config` +
  /// `clear_proxy_config`（见 `rust/sourin_core/src/ffi.rs:1372-1403`）。
  /// 调一个不存在的命令会抛「命令不存在」，所以这里老老实实读全量再取。
  ///
  /// 没配过（Map 里没有这个 id）→ 返回 `const ProxyConfig()`（= 直连），
  /// 这**不是错误**：Rust 的 `ProxyStore::all()` 只返回配过的项。
  ///
  /// ★ 走 [ProxyCache]（任务 AE）—— 26 张卡片各拉一次全量 Map
  ///   是原版那次「15 次 IPC」在我们这里的放大版，见类文档。
  static Future<ProxyConfig> proxyConfigFor(String provider) async {
    final all = await ProxyCache.configs();
    return all[provider] ?? const ProxyConfig();
  }

  /// 读一个源的代理配置 **+ 密码标记**（面板一次拿全，少一次往返）
  ///
  /// ★ 两个读都走共享缓存（任务 AE）—— 这是**每张源卡片**都会调的那个，
  ///   所以它是"26 张卡片 × 3 次 IPC"里最主要的两个来源。
  static Future<ProxyConfig> proxyConfigWithPassword(String provider) async {
    final results = await Future.wait([
      proxyConfigFor(provider),
      ProxyCache.hasPassword(provider),
    ]);
    return (results[0] as ProxyConfig)
        .copyWith(hasPassword: results[1] as bool);
  }

  /// 只改模式（UI 上那三个 pill 就是调它）
  ///
  /// 保留其余字段 —— 用 [ProxyConfig.copyWith] 而不是整份重建，
  /// 避免"改模式时把地址/范围/用户名弄丢"。
  static Future<void> setProxyMode(String provider, ProxyMode mode) async {
    final cur = await proxyConfigFor(provider);
    await setProxyConfig(provider, cur.copyWith(mode: mode));
  }

  // ═══════════════════════════════════════════════════════════════════
  //  会话状态 —— 修正**返回类型写错**的包装（任务 P2 追加）
  // ═══════════════════════════════════════════════════════════════════
  //
  // # 这里补的是一个真 bug（与 bug ① 同类：**静默失效**）
  //
  // 曾经有一个签名写错的包装：
  // ```dart
  // static Future<Map<String, dynamic>?> providerSessionState(String provider)
  // ```
  // ★ 它已于任务 AF 删除（旧签名**永远拿不到正确结果**，见下面的链条）。
  //   当时不敢动是因为它在文件中间，同一轮有 3 个代理在改这个文件，
  //   往中间插会和别人的 hunk 撞车；AF 那一轮已确认**零生产调用者**
  //   （唯一调用者是 `lib/nullpath_probe.dart`，随探针一起删除），
  //   所以直接删掉，不再保留转发壳。
  //
  // 后端 `provider_session_state` 的真实返回类型是：
  // ```rust
  // Result<Option<SessionState>, String>
  // #[serde(rename_all = "snake_case")]
  // pub enum SessionState { NotRequired, Active, Expiring, Expired }
  // ```
  // 也就是**一个字符串**（`"active"` / `"not_required"` / `"expiring"` /
  // `"expired"`）或 `null`，**不是对象**。
  // 依据：`rust/sourin_core/src/provider.rs:383-395` +
  //      `commands_backup.rs:81-86` + `ffi.rs:1343-1351`。
  //
  // 后果链条（每一环都静默）：
  // ```text
  // ① jmapOrNull("active") 抛「期望对象，实际收到 String」
  // ② 调用方（登录面板）用 catchError 吞掉 → 拿到 null
  // ③ → _state 永远是 null → UI 永远显示「无需登录」
  // ④ → 连 `expired`（登录已失效）都不提示 —— 用户不知道要重新登录
  // ```
  // 而登录面板的"清除本机凭据"按钮**只在 `expired` 时显示**，
  // 所以那个按钮也是死的（用户想清掉坏凭据都点不到）。
  //
  // ⚠️ 教训：**返回类型写错**不会报编译错（调用方都在 catchError 里），
  //    它只会让功能静默失效。改包装时**必须对着 Rust 的签名核**，
  //    不能照着旧注释/旧用法猜。
  //
  // 为什么这里回传 `String?` 而不是解析成枚举：
  // `SessionState` 枚举定义在 `ui/widgets/provider_login_panel.dart`（UI 层），
  // core 层不该反向依赖 UI 层。core 只保证"把后端的原始值**不丢失**地
  // 交出去"，语义映射留给消费方。

  /// 会话状态（**正确的返回类型** —— `snake_case` 字符串或 null）
  ///
  /// ```text
  /// "active"        已登录且可用
  /// "expiring"      已登录但即将过期（宿主会尝试自动续期）
  /// "not_required"  该源不需要登录
  /// "expired"       登录已失效，**需要用户去设置页人工登录**
  /// null            源不存在（**不是错误** —— 原版如此）
  /// ```
  static Future<String?> providerSessionStateWire(String provider) async {
    final r = await SourinCore.callAsync('provider_session_state', {
      'provider': provider,
    });
    // 后端是 `Result<Option<SessionState>, String>` —— 原始值就是字符串
    return r is String ? r : null;
  }

  // ═══════════════════════════════════════════════════════════════════
  //  站点代理 —— **共享缓存**（任务 AE 追加）
  // ═══════════════════════════════════════════════════════════════════
  //
  // # 为什么必须有这一层（原版实测的教训，直接抄进注释）
  //
  // 原版 `SettingsView.vue:482-495` 的注释原文：
  // > ★ 代理配置的缓存（性能优化，Owner 报「操作卡顿」后加）
  // >
  // > 实测：一次 5 次切页的操作里 `has_proxy_password` 被调了 **15 次**
  // > （每次进设置页都要逐个源问一遍）。而这些数据**极少变化** ——
  // > 只在用户自己改代理设置时才会变。
  // >
  // > 做法：加载过一次就标记，之后进设置页直接用缓存；
  // > 用户改了代理设置时主动失效（见 `proxyDirty`）。
  //
  // # 我们这边的**放大倍数比原版更大**（这才是真缺口）
  //
  // 原版是「进设置页时，父组件对 N 个源各问一遍」→ 一次进页 N 次。
  // 而我们把代理面板**嵌进了每个源卡片**（照原版 `ProviderProxy` 的设计），
  // 于是**每个 `ProxyPanel` 各自**在 `initState` 里拉一次：
  // ```text
  // 每张卡片  → proxyConfigWithPassword() → listProxyConfigs()   ← 全量 Map！
  //                                     → hasProxyPassword()
  //          → systemProxyHint()
  // ```
  // 本机 26 个源 ⇒ **一次进设置页 26 × (1 全量 + 1 密码 + 1 系统提示)**
  // = 78 次 IPC，而且其中 26 次是把**同一份全量 Map** 拉了 26 遍。
  //
  // 所以三样东西都收进 [ProxyCache] 那个**进程级共享缓存**：
  // ```text
  // · configs    list_proxy_configs   —— 全量 Map，一次拉够所有卡片用
  // · hasPw      has_proxy_password   —— 逐源，但**只问一次**
  // · sysHint    system_proxy_hint    —— 全局唯一值，问一次就够
  // ```
  //
  // # 失效（与原版 `proxyLoaded = false` 同语义）
  //
  // ```text
  // ProxyCache.invalidate()          任何写操作后调（set / clear / setPassword）
  // ProxyCache.invalidatePassword(id) 只改了某个源的密码标记
  // ```
  // ⚠️ **写路径必须主动失效** —— 原版注释里那句「用户改了代理设置时
  //    主动失效」就是这个意思。漏掉的话用户改完密码再进来看到的是旧值。
  //
  // # 为什么状态放在 [ProxyCache] 而不是这里的私有字段
  //
  // 一是**本轮多个代理在改这个文件**，新增的类冲突面最小；
  // 二是**可测**：缓存有没有生效只能靠"底层命令被调了几次"证明，
  // 计数器需要从测试里读得到（见 `ProxyCache.configFetches`）。
  //
  // ⚠️ 缓存的是**后端状态**，与"哪个页面在看"无关 —— 所以放 core 层。
  //    放 UI 层的话设置页与播放页各存一份，改一处漏一处，
  //    正是当初那个 `ProxyConfig` 双模型 bug 的形态。

  /// 全量代理配置 —— 走共享缓存（**不再每次 IPC 拉全量**）
  static Future<Map<String, ProxyConfig>> listProxyConfigsCached() =>
      ProxyCache.configs();

  /// 是否已存代理密码 —— 走共享缓存
  static Future<bool> hasProxyPasswordCached(String provider) =>
      ProxyCache.hasPassword(provider);

  /// 系统代理提示 —— 走共享缓存（全局唯一值）
  static Future<String?> systemProxyHintCached() => ProxyCache.systemHint();

  /// ★ 代理缓存失效（**任何写操作后都必须调**）
  ///
  /// 对应原版 `invalidateProxy()`：
  /// ```ts
  /// let proxyLoaded = false;
  /// function invalidateProxy() { proxyLoaded = false; }
  /// ```
  static void invalidateProxyCache() => ProxyCache.invalidate();
}

/// 站点代理的**进程级共享缓存**（任务 AE）
///
/// # 为什么单独一个类（而不是 `SourinApi` 的私有字段）
///
/// ```text
/// ① 冲突面 —— `sourin_api.dart` 本轮有多个代理在改，
///    新增一个类不会和别人往中间插的 hunk 撞车
/// ② 可测   —— 「有没有缓存」只能靠**底层命令的调用次数**证明，
///    计数器必须能从测试里读到
/// ```
///
/// # ★ 为什么必须有计数器（本轮 5 次「断言在错误范围上跑」的教训）
///
/// ```text
/// ✗ 断言「调两次 proxyConfigFor 都拿到配置」 → **恒真**，缓存坏了也过
/// ✓ 断言「底层 list_proxy_configs 只被调了 1 次」 → 真的能抓到没缓存
/// ```
/// 所以 [configFetches] / [passwordFetches] / [sysHintFetches] 是
/// **公开的**，单测直接断言它们。
///
/// ⚠️ 只在**单 isolate** 下正确（本应用如此：FFI 调用都在主 isolate）。
class ProxyCache {
  ProxyCache._();

  /// 底层 `list_proxy_configs` 真正被调用的次数（**测试探针**）
  static int configFetches = 0;

  /// 底层 `has_proxy_password` 真正被调用的次数（**测试探针**）
  static int passwordFetches = 0;

  /// 底层 `system_proxy_hint` 真正被调用的次数（**测试探针**）
  static int sysHintFetches = 0;

  static Map<String, ProxyConfig>? _configs;
  static final Map<String, bool> _hasPw = {};
  static String? _sysHint;
  static bool _sysHintLoaded = false;

  /*
   * ── ★ 可注入的取值函数（**测试接缝**）──
   *
   * # 为什么需要它（本轮「断言在错误范围上跑」的第 6 种形态）
   *
   * 「缓存有没有生效」的硬判据是**底层被调了几次**。但如果缓存直接
   * 写死调 `SourinApi.listProxyConfigs()`，那在 `flutter test` 里
   * **根本跑不起来**（没有 `sourin_core.dll`）—— 于是只能退化成
   * 「断言计数器这个字段存在」，那是**恒真**的废断言。
   *
   * 把取值函数做成可替换的，测试就能：
   * ```text
   * ① 塞一个假的 fetcher（返回固定值 + 自己计数）
   * ② 连调 3 次 configs()
   * ③ 断言假 fetcher 只被调了 **1** 次   ← 这才是真的在测缓存
   * ```
   *
   * ⚠️ 生产路径**永远**是默认值（真 `SourinApi` 调用）——
   *    只有测试会替换它，且必须用 [reset] 还原。
   */
  static Future<Map<String, ProxyConfig>> Function() _fetchConfigs =
      SourinApi.listProxyConfigs;

  static Future<bool> Function(String) _fetchHasPassword =
      SourinApi.hasProxyPassword;

  static Future<String?> Function() _fetchSysHint = SourinApi.systemProxyHint;

  /// 替换三个取值函数（**只给测试用**）
  ///
  /// 传 null 的项保持默认实现。
  static void overrideFetchers({
    Future<Map<String, ProxyConfig>> Function()? configs,
    Future<bool> Function(String)? hasPassword,
    Future<String?> Function()? sysHint,
  }) {
    _fetchConfigs = configs ?? SourinApi.listProxyConfigs;
    _fetchHasPassword = hasPassword ?? SourinApi.hasProxyPassword;
    _fetchSysHint = sysHint ?? SourinApi.systemProxyHint;
  }

  /// 清空缓存**并归零计数**（每个用例开始前调，避免用例互相污染）
  static void reset() {
    _configs = null;
    _hasPw.clear();
    _sysHint = null;
    _sysHintLoaded = false;
    configFetches = 0;
    passwordFetches = 0;
    sysHintFetches = 0;
    _fetchConfigs = SourinApi.listProxyConfigs;
    _fetchHasPassword = SourinApi.hasProxyPassword;
    _fetchSysHint = SourinApi.systemProxyHint;
  }

  /// 全量配置（缓存命中时**不产生 IPC**）
  static Future<Map<String, ProxyConfig>> configs() async {
    final hit = _configs;
    if (hit != null) return hit;
    configFetches++;
    final v = await _fetchConfigs();
    _configs = v;
    return v;
  }

  /// 某个源是否已存密码（缓存命中时**不产生 IPC**）
  static Future<bool> hasPassword(String provider) async {
    final hit = _hasPw[provider];
    if (hit != null) return hit;
    passwordFetches++;
    final v = await _fetchHasPassword(provider);
    _hasPw[provider] = v;
    return v;
  }

  /// 系统代理提示（全局唯一值 —— 问一次就够）
  static Future<String?> systemHint() async {
    if (_sysHintLoaded) return _sysHint;
    sysHintFetches++;
    final v = await _fetchSysHint();
    _sysHint = v;
    _sysHintLoaded = true;
    return v;
  }

  /// 写操作后失效（原版 `invalidateProxy()` 的等价物）
  static void invalidate() {
    _configs = null;
    _hasPw.clear();
    _sysHint = null;
    _sysHintLoaded = false;
  }

  /// 只失效某个源的密码标记（改密码后调 —— 不必把全量配置也丢掉）
  static void invalidatePassword(String provider) => _hasPw.remove(provider);

  /// 只失效系统提示
  static void invalidateSystemHint() {
    _sysHint = null;
    _sysHintLoaded = false;
  }
}

/// ★ 一份「可编辑的第三方源原始配置」（对应 Rust 的 `PersistedProvider`）
///
/// # 为什么只有两种形态
///
/// ```text
/// Declarative { id, json }                  ← 存原始 JSON 描述
/// Http        { id, base_url, headers }     ← 存基址与自定义头
/// ```
/// 后端注释解释了为什么**存原始配置而不是实例**：
/// > 声明式源存原始 JSON、HTTP 源存 base URL，启动时**重新构造**。
/// > 这样上游改了契约/数据格式，重启即生效。
///
/// 这正是「编辑」能实现的前提 —— 原始配置在，就能回填给用户改。
///
/// # ⚠️ `headers` 可能含凭据
///
/// 后端注释明确写着：
/// > HTTP 源的 `headers` 可能含 `Authorization` 之类的凭据……
/// > 调用方必须只在设置页展示，**不得写入日志或上报**。
///
/// 所以这个类**故意不实现 `toString()`**（Dart 默认的 `toString` 是
/// `Instance of ...`，不会漏字段）—— 防止有人顺手 `print(seed)`
/// 把令牌打进日志。
class ProviderImportSeed {
  const ProviderImportSeed({
    required this.kind,
    required this.id,
    this.json,
    this.baseUrl,
    this.headers = const {},
  });

  /// `declarative` 或 `http`（后端 `#[serde(tag = "kind")]`）
  final String kind;

  final String id;

  /// 声明式源的原始 JSON **文本**（未解析 —— 回填时要先 pretty 再显示）
  final String? json;

  /// HTTP 源的基址
  final String? baseUrl;

  /// HTTP 源的自定义请求头（后端 `#[serde(default)]`，缺失时是空 Map）
  final Map<String, String> headers;

  bool get isDeclarative => kind == 'declarative';
  bool get isHttp => kind == 'http';

  /// 解析后端返回。**kind 不认识时返回 null** ——
  ///
  /// 为什么要正向列举而不是"默认当成声明式"：
  /// 后端将来加了第三种形态时，误当成声明式会让用户看到一个
  /// 空白的 JSON 编辑框，点保存就把原源覆盖成一个坏配置。
  /// 返回 null → UI 不给「编辑」按钮，是**安全**的失败方式。
  static ProviderImportSeed? fromJson(Map<String, dynamic> j) {
    final kind = j['kind'];
    final id = j['id'];
    if (kind is! String || id is! String) return null;

    switch (kind) {
      case 'declarative':
        final json = j['json'];
        if (json is! String) return null;
        return ProviderImportSeed(kind: kind, id: id, json: json);

      case 'http':
        final base = j['base_url'];
        if (base is! String) return null;
        final raw = j['headers'];
        return ProviderImportSeed(
          kind: kind,
          id: id,
          baseUrl: base,
          headers: raw is Map
              ? raw.map((k, v) => MapEntry('$k', '$v'))
              : const {},
        );

      default:
        return null;
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  TVBox 配置导入的数据模型（task-5）
// ═══════════════════════════════════════════════════════════════════════
//
// 权威定义在 Rust 侧：`rust/sourin_core/src/tvbox.rs::import_tvbox_config`
// 返回的 `serde_json::Value`：
// ```text
// { totalSites, imported: [...], skipped: [...], lives: [...] }
// ```
// ⚠️ Rust 侧用 `serde_json::json!` **手写字段名**（camelCase），
//    不是 derive 出来的 —— 所以两边对不上时**编译期发现不了**，
//    只能靠这里的解析 + 单测/实机覆盖。

/// 导入成功的一个源
class TvboxImportedSource {
  const TvboxImportedSource({
    required this.id,
    required this.name,
    required this.api,
    this.categories = 0,
    this.total = 0,
  });

  final String id;
  final String name;

  /// 探测成功后固化的接口地址（**已去掉 query 段**，见 Rust `normalize_api_url`）
  final String api;

  /// 探到的分类数
  final int categories;

  /// 探到的影片总数（后端给的 `total`，可能为 0）
  final int total;

  factory TvboxImportedSource.fromJson(Map<String, dynamic> j) =>
      TvboxImportedSource(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        api: j['api'] as String? ?? '',
        categories: (j['categories'] as num?)?.toInt() ?? 0,
        total: (j['total'] as num?)?.toInt() ?? 0,
      );
}

/// 被跳过的 site
class TvboxSkippedSite {
  const TvboxSkippedSite({
    required this.name,
    this.type,
    this.stage = '',
    this.reason = '',
  });

  final String name;

  /// 配置里的 `type`（type0/1/3/4，可能缺失 → null）
  final int? type;

  /// `type` = 类型就不支持，没发请求；`probe` = 发了探测请求但失败
  final String stage;

  final String reason;

  factory TvboxSkippedSite.fromJson(Map<String, dynamic> j) => TvboxSkippedSite(
        name: j['name'] as String? ?? '',
        type: (j['type'] as num?)?.toInt(),
        stage: j['stage'] as String? ?? '',
        reason: j['reason'] as String? ?? '',
      );
}

/// 配置里的直播源（**本版本不导入**，只如实回报）
class TvboxLiveSource {
  const TvboxLiveSource({required this.name, required this.url});

  final String name;
  final String url;

  factory TvboxLiveSource.fromJson(Map<String, dynamic> j) => TvboxLiveSource(
        name: j['name'] as String? ?? '',
        url: j['url'] as String? ?? '',
      );
}

/// TVBox 配置导入的结果
///
/// # ★ 为什么要把 skipped / lives 一路带到 UI
///
/// TVBox 配置里 site 的 `type` 有 0/1/3/4 等好几种，其中**只有 type1
/// （苹果 CMS）**能在本机跑 —— type3 要 Java JAR / drpy 引擎，type0/4
/// 是别的协议。另一个常见情况是探测请求本身失败（站点挂了 / 被墙）。
///
/// 如果我们只显示"导入成功 N 个"，用户会以为「我这份配置就该有这么多源」，
/// 永远不知道自己少了什么、为什么少。所以三份清单**全部**回传，
/// 界面逐条列出原因。
class TvboxImportResult {
  const TvboxImportResult({
    this.totalSites = 0,
    this.imported = const [],
    this.skipped = const [],
    this.lives = const [],
    this.multiRepo = false,
    this.repos = const [],
  });

  /// 配置里 `sites` 数组的长度
  final int totalSites;

  final List<TvboxImportedSource> imported;
  final List<TvboxSkippedSite> skipped;
  final List<TvboxLiveSource> lives;

  /// ★ 这是一份**多仓**配置（只有 `urls`，没有 `sites`）
  ///
  /// task-12 之前这种情况直接抛错误（把子仓清单塞进错误文案里）；
  /// 现在改成结构化返回 —— 界面据此列出子仓，用户点一个就能继续。
  ///
  /// ⚠️ 多仓本身**不会**产出任何源（`imported` 必为空）：
  ///    后端没有"把多仓展开成一份配置"的能力，就不假装有。
  final bool multiRepo;

  /// 多仓配置里的子仓清单（`multiRepo` 为 true 时才有）
  final List<TvboxSubRepo> repos;

  factory TvboxImportResult.fromJson(Map<String, dynamic> j) => TvboxImportResult(
        totalSites: (j['totalSites'] as num?)?.toInt() ?? 0,
        imported: _listOf(j['imported'], TvboxImportedSource.fromJson),
        skipped: _listOf(j['skipped'], TvboxSkippedSite.fromJson),
        lives: _listOf(j['lives'], TvboxLiveSource.fromJson),
        multiRepo: j['multiRepo'] == true,
        repos: _listOf(j['repos'], TvboxSubRepo.fromJson),
      );

  static List<T> _listOf<T>(
    Object? raw,
    T Function(Map<String, dynamic>) f,
  ) =>
      raw is List
          ? raw
              .whereType<Map>()
              .map((e) => f(e.cast<String, dynamic>()))
              .toList(growable: false)
          : const [];
}

/// 多仓配置里的一个子仓（task-12）
///
/// 多仓配置长这样：`{"urls":[{"name":"子仓甲","url":"..."}]}` ——
/// 它本身没有 `sites`，所以**不能直接导入**。界面把这份清单列出来，
/// 用户点一个就把它的地址填回输入框，再导一次即可。
class TvboxSubRepo {
  const TvboxSubRepo({required this.name, required this.url});

  final String name;
  final String url;

  factory TvboxSubRepo.fromJson(Map<String, dynamic> j) => TvboxSubRepo(
        name: (j['name'] as String?)?.trim() ?? '',
        url: (j['url'] as String?)?.trim() ?? '',
      );

  /// 界面直接显示用（名字缺了就显示地址）
  String get label => name.isEmpty ? url : '$name（$url）';
}

// ═══════════════════════════════════════════════════════════════════════
//  TVBox「订阅链接 / 检测更新」的数据模型（task-12）
// ═══════════════════════════════════════════════════════════════════════
//
// 权威定义在 Rust 侧 `rust/sourin_core/src/tvbox.rs`：
// ```text
// TvboxSourceMeta  订阅来源 sidecar（data_dir/tvbox-sources.json）
// SiteDiff         diff_sites 的返回值（added/removed/changed/unchanged）
// ```
// Rust 侧全部用 `#[serde(rename_all = "camelCase")]` —— 与插件那套
// （snake_case）**不一样**，别照着插件抄字段名。

/// 一个 TVBox 源 + 它的订阅来源信息
class TvboxSourceInfo {
  const TvboxSourceInfo({
    required this.id,
    required this.name,
    required this.api,
    this.sourceUrl,
    this.needsSource = true,
    this.siteKey = '',
    this.installedAt = 0,
  });

  final String id;
  final String name;
  final String api;

  /// 当初导入它的配置链接（null = 贴文本导入的，查不了更新）
  final String? sourceUrl;

  /// ★ 界面据此决定**要不要显示**「检测更新」按钮
  ///
  /// true → 不显示按钮，只如实说明「无订阅链接」（不是"已是最新"）
  final bool needsSource;

  /// 站点在配置 `sites[]` 里的 key（更新对比时用来认出"还是同一个站"）
  final String siteKey;

  /// Unix 秒（0 = 未知）
  final int installedAt;

  factory TvboxSourceInfo.fromJson(Map<String, dynamic> j) => TvboxSourceInfo(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        api: j['api'] as String? ?? '',
        sourceUrl: (j['sourceUrl'] as String?)?.trim().isEmpty ?? true
            ? null
            : (j['sourceUrl'] as String).trim(),
        needsSource: j['needsSource'] != false,
        siteKey: j['siteKey'] as String? ?? '',
        installedAt: (j['installedAt'] as num?)?.toInt() ?? 0,
      );
}

/// [SourinApi.listTvboxSources] 的返回
class TvboxSourceList {
  const TvboxSourceList({
    this.sources = const [],
    this.total = 0,
    this.withSource = 0,
  });

  final List<TvboxSourceInfo> sources;

  /// 全部 TVBox 源数
  final int total;

  /// 其中**有订阅链接**的个数（= 能检测更新的个数）
  final int withSource;

  factory TvboxSourceList.fromJson(Map<String, dynamic> j) => TvboxSourceList(
        sources: jlist(j['sources'], TvboxSourceInfo.fromJson),
        total: (j['total'] as num?)?.toInt() ?? 0,
        withSource: (j['withSource'] as num?)?.toInt() ?? 0,
      );

  /// 没有链接的源（界面如实说明"查不了"的那些）
  List<TvboxSourceInfo> get withoutSource =>
      sources.where((s) => s.needsSource).toList(growable: false);
}

/// 一条**新增**的远端站点（本地还没有）
class TvboxRemoteSite {
  const TvboxRemoteSite({this.key = '', this.name = '', this.api = ''});

  final String key;
  final String name;
  final String api;

  factory TvboxRemoteSite.fromJson(Map<String, dynamic> j) => TvboxRemoteSite(
        key: j['key'] as String? ?? '',
        name: j['name'] as String? ?? '',
        api: j['api'] as String? ?? '',
      );
}

/// 一条**远端已消失**的本地站点（默认只报告，绝不自动删）
class TvboxLocalSite {
  const TvboxLocalSite({
    this.id = '',
    this.key = '',
    this.name = '',
    this.api = '',
  });

  final String id;
  final String key;
  final String name;
  final String api;

  factory TvboxLocalSite.fromJson(Map<String, dynamic> j) => TvboxLocalSite(
        id: j['id'] as String? ?? '',
        key: j['key'] as String? ?? '',
        name: j['name'] as String? ?? '',
        api: j['api'] as String? ?? '',
      );
}

/// 一条**变更**（同一个站，接口或名字变了）
class TvboxSiteChange {
  const TvboxSiteChange({
    this.id = '',
    this.key = '',
    this.oldName = '',
    this.newName = '',
    this.oldApi = '',
    this.newApi = '',
  });

  final String id;
  final String key;
  final String oldName;
  final String newName;
  final String oldApi;
  final String newApi;

  factory TvboxSiteChange.fromJson(Map<String, dynamic> j) => TvboxSiteChange(
        id: j['id'] as String? ?? '',
        key: j['key'] as String? ?? '',
        oldName: j['oldName'] as String? ?? '',
        newName: j['newName'] as String? ?? '',
        oldApi: j['oldApi'] as String? ?? '',
        newApi: j['newApi'] as String? ?? '',
      );

  /// 是不是换了接口（而不是只改了名字）
  bool get apiChanged => oldApi != newApi;
}

/// 一个订阅链接的检测结果
///
/// # ★★ 三种状态，界面必须区分对待（与 [PluginUpdateInfo] 同一条）
///
/// ```text
/// ok == false && multiRepo == true → 远端现在是一份多仓配置，列子仓给用户选
/// ok == false && error != null     → 查了但失败，**不能显示"已是最新"**
/// ok == true                       → 看 added / changed 决定要不要显示「更新」
/// ```
class TvboxUpdateItem {
  const TvboxUpdateItem({
    this.sourceUrl = '',
    this.ids = const [],
    this.ok = false,
    this.error,
    this.multiRepo = false,
    this.repos = const [],
    this.remoteTotalSites = 0,
    this.remoteConvertible = 0,
    this.remoteUnsupported = 0,
    this.added = const [],
    this.removed = const [],
    this.changed = const [],
    this.unchanged = 0,
    this.unchangedForeign = 0,
  });

  /// 这条结果对应的订阅链接
  final String sourceUrl;

  /// 这个链接下的本地源 id（一份配置产出几十个源，共用一条结果）
  final List<String> ids;

  /// 查询是否成功（false 时看 [error] / [multiRepo]）
  final bool ok;

  /// 失败原因（网络/解析/配置形状不对）
  final String? error;

  /// 远端链接现在是一份「多仓」配置（只有 urls，没有 sites）
  final bool multiRepo;

  /// 多仓里的子仓清单
  final List<TvboxSubRepo> repos;

  /// 远端配置里 sites 的总数
  final int remoteTotalSites;

  /// 其中**能转换**的（type=1 苹果 CMS）个数
  final int remoteConvertible;

  /// 其中**转不了**的（type3 需要 JAR / drpy 引擎）个数
  final int remoteUnsupported;

  final List<TvboxRemoteSite> added;

  /// ★ 远端已经没有的本地站 —— 默认**只报告，不删**
  final List<TvboxLocalSite> removed;

  final List<TvboxSiteChange> changed;

  /// 完全没变的条数（只算本订阅的）
  final int unchanged;

  /// 被认出来、但属于**别的订阅**的站（避免重复注册用）
  final int unchangedForeign;

  /// 有没有值得应用的变化（新增或变更）
  bool get hasChanges => added.isNotEmpty || changed.isNotEmpty;

  factory TvboxUpdateItem.fromJson(Map<String, dynamic> j) => TvboxUpdateItem(
        sourceUrl: j['sourceUrl'] as String? ?? '',
        ids: jstrList(j['ids']),
        ok: j['ok'] == true,
        error: (j['error'] as String?)?.trim().isEmpty ?? true
            ? null
            : (j['error'] as String).trim(),
        multiRepo: j['multiRepo'] == true,
        repos: jlist(j['repos'], TvboxSubRepo.fromJson),
        remoteTotalSites: (j['remoteTotalSites'] as num?)?.toInt() ?? 0,
        remoteConvertible: (j['remoteConvertible'] as num?)?.toInt() ?? 0,
        remoteUnsupported: (j['remoteUnsupported'] as num?)?.toInt() ?? 0,
        added: jlist(j['added'], TvboxRemoteSite.fromJson),
        removed: jlist(j['removed'], TvboxLocalSite.fromJson),
        changed: jlist(j['changed'], TvboxSiteChange.fromJson),
        unchanged: (j['unchanged'] as num?)?.toInt() ?? 0,
        unchangedForeign: (j['unchangedForeign'] as num?)?.toInt() ?? 0,
      );
}

/// [SourinApi.checkTvboxUpdates] 的返回
class TvboxUpdateCheck {
  const TvboxUpdateCheck({
    this.items = const [],
    this.checked = 0,
    this.skipped = 0,
    this.skippedIds = const [],
  });

  final List<TvboxUpdateItem> items;

  /// 真的发出去的链接数（一份配置一条，不是每个源一条）
  final int checked;

  /// 没有链接、**查不了**的源个数
  final int skipped;

  final List<String> skippedIds;

  /// 按 id 找这条源所属的检测结果（一份链接的 ids 里包含它）
  TvboxUpdateItem? itemOf(String id) {
    for (final it in items) {
      if (it.ids.contains(id)) return it;
    }
    return null;
  }

  factory TvboxUpdateCheck.fromJson(Map<String, dynamic> j) => TvboxUpdateCheck(
        items: jlist(j['items'], TvboxUpdateItem.fromJson),
        checked: (j['checked'] as num?)?.toInt() ?? 0,
        skipped: (j['skipped'] as num?)?.toInt() ?? 0,
        skippedIds: jstrList(j['skippedIds']),
      );
}

/// 一键更新的结果（[SourinApi.updateTvboxSource]）
class TvboxSourceUpdate {
  const TvboxSourceUpdate({
    this.updated = false,
    this.reason,
    this.sourceUrl = '',
    this.added = const [],
    this.changed = const [],
    this.removed = const [],
    this.deleted = const [],
    this.notApplied = const [],
    this.failed = const [],
    this.unchanged = 0,
    this.unchangedForeign = 0,
    this.skippedByType = 0,
  });

  /// 这次调用有没有真的改动本地
  final bool updated;

  /// 没有改动时的原因（如「远端配置与本地一致，无需更新」）
  final String? reason;

  final String sourceUrl;

  /// 新注册进来的源（{id,name,api,categories,total}）
  final List<TvboxRemoteSite> added;

  /// 原地更新了接口的源（id 沿用原值，保住用户的启用状态/排序）
  final List<TvboxRemoteSite> changed;

  /// 远端已消失的本地站（**只报告**）
  final List<TvboxLocalSite> removed;

  /// 真正被删掉的（只有 deleteMissing=true 才会有内容）
  final List<TvboxLocalSite> deleted;

  /// 用户没勾「同时加入新增站点」时被跳过的
  final List<TvboxRemoteSite> notApplied;

  /// 探测失败的（{name,api,reason}）
  final List<TvboxRemoteSite> failed;

  final int unchanged;
  final int unchangedForeign;

  /// 远端配置里因为类型不支持而跳过的 site 数
  final int skippedByType;

  factory TvboxSourceUpdate.fromJson(Map<String, dynamic> j) =>
      TvboxSourceUpdate(
        updated: j['updated'] == true,
        reason: (j['reason'] as String?)?.trim().isEmpty ?? true
            ? null
            : (j['reason'] as String).trim(),
        sourceUrl: j['sourceUrl'] as String? ?? '',
        added: jlist(j['added'], TvboxRemoteSite.fromJson),
        changed: jlist(j['changed'], TvboxRemoteSite.fromJson),
        removed: jlist(j['removed'], TvboxLocalSite.fromJson),
        deleted: jlist(j['deleted'], TvboxLocalSite.fromJson),
        notApplied: jlist(j['notApplied'], TvboxRemoteSite.fromJson),
        failed: jlist(j['failed'], TvboxRemoteSite.fromJson),
        unchanged: (j['unchanged'] as num?)?.toInt() ?? 0,
        unchangedForeign: (j['unchangedForeign'] as num?)?.toInt() ?? 0,
        skippedByType: (j['skippedByType'] as num?)?.toInt() ?? 0,
      );
}

// ═══════════════════════════════════════════════════════════════════════
//  插件「检测更新 / 更新 / 回滚」的数据模型（task-23）
// ═══════════════════════════════════════════════════════════════════════
//
// ⚠️ 为什么放在 `sourin_api.dart` 而不是 `models.dart`：
//    `models.dart` 不在本次任务的写入范围（有并发改动），
//    而这几个模型**只被本次的 API + 设置页使用** —— 就近定义、
//    自包含，不跨文件制造依赖。
//
// 权威定义在 Rust 侧：
// ```text
// PluginUpdateInfo    commands_provider.rs  struct PluginUpdateInfo
// PluginUpdateResult  update_plugin_from_source / rollback_plugin 的返回值
// PluginVersionEntry  list_plugin_version_history 的每一项
// ```
// ⚠️ 字段名两边必须一致（Rust 用 `#[derive(Serialize)]` 的**原字段名**，
//    没有 `rename_all`，所以 JSON 里是 `snake_case`）。

/// 一个插件的「检测更新」结果
///
/// # ★★ 三种状态，界面必须区分对待（不能混成一个"没更新"）
///
/// ```text
/// needsSource == true   → 没有安装链接，**查不了**
///                         界面**不显示**「检测更新」按钮，如实说明原因
/// error != null         → 查了但失败（网络/链接失效/不是 JS/无 @version）
///                         界面显示失败原因，**不能显示"已是最新"**
/// 否则                  → hasUpdate 决定要不要显示「更新到 vX」
/// ```
/// ⚠️ 把前两种当成"已是最新"就是**假装有能力** —— 用户会以为
///    "点了没反应 = 没问题"，实际我们从没查过。
class PluginUpdateInfo {
  const PluginUpdateInfo({
    required this.id,
    this.file = '',
    this.version = '',
    this.needsSource = false,
    this.sourceUrl,
    this.remoteVersion,
    this.hasUpdate = false,
    this.sameContent = false,
    this.error,
  });

  final String id;
  final String file;

  /// 本地当前版本（插件声明的 `@version`）
  final String version;

  /// ★ 没有安装链接 = 无法检测（**不是错误**，是如实的能力缺失）
  final bool needsSource;

  /// 安装来源链接（[needsSource] 时为 null）
  final String? sourceUrl;

  /// 远端版本（查不到时为 null）
  final String? remoteVersion;

  /// 是否有新版（`remote > local`，按数字段比较）
  final bool hasUpdate;

  /// 远端内容与本地**逐字节相同**（"内容没变"）
  ///
  /// 与 [hasUpdate] 是**两件事**：作者改了内容但忘了改版本号时
  /// `hasUpdate=false / sameContent=false` —— 我们不提示更新（保守），
  /// 但用户至少能从历史弹窗看到差异。
  final bool sameContent;

  /// 失败原因（网络错 / 链接失效 / 不是 JS / 解析不出版本）
  final String? error;

  /// 界面用：这个插件**能不能**检测更新
  ///
  /// = 有来源链接。没有来源的插件不该出现「检测更新」按钮。
  bool get canCheck => !needsSource && sourceUrl != null;

  /// 界面用：检测是否**成功完成**（有结论，不管有没有新版）
  bool get checked => canCheck && error == null;

  factory PluginUpdateInfo.fromJson(Map<String, dynamic> j) => PluginUpdateInfo(
        id: j['id'] as String? ?? '',
        file: j['file'] as String? ?? '',
        version: j['version'] as String? ?? '',
        needsSource: j['needs_source'] as bool? ?? false,
        sourceUrl: j['source_url'] as String?,
        remoteVersion: j['remote_version'] as String?,
        hasUpdate: j['has_update'] as bool? ?? false,
        sameContent: j['same_content'] as bool? ?? false,
        error: j['error'] as String?,
      );
}

/// 更新 / 回滚的结果
class PluginUpdateResult {
  const PluginUpdateResult({
    this.updated = false,
    this.rolledBack = false,
    this.version = '',
    this.fromVersion = '',
    this.file = '',
    this.reason,
    this.archived = '',
    this.pruned = 0,
  });

  /// 真的更新了（`false` = 内容一致，无需更新 —— **不是错误**）
  final bool updated;

  /// 真的回滚了
  final bool rolledBack;

  /// 更新/回滚**之后**的版本
  final String version;

  /// 更新/回滚**之前**的版本
  final String fromVersion;

  final String file;

  /// `updated == false` 时的原因（"内容与本地一致，无需更新"）
  final String? reason;

  /// 归档的历史文件名（`154@1.0.0.js`）
  final String archived;

  /// 本次清理掉的旧档数量
  final int pruned;

  factory PluginUpdateResult.fromJson(Map<String, dynamic> j) =>
      PluginUpdateResult(
        updated: j['updated'] as bool? ?? false,
        rolledBack: j['rolledBack'] as bool? ?? false,
        version: j['version'] as String? ?? '',
        fromVersion: j['fromVersion'] as String? ?? '',
        file: j['file'] as String? ?? '',
        reason: j['reason'] as String?,
        archived: j['archived'] as String? ?? '',
        pruned: (j['pruned'] as num?)?.toInt() ?? 0,
      );
}

/// 一个历史版本档（回滚弹窗的一行）
class PluginVersionEntry {
  const PluginVersionEntry({
    required this.version,
    this.file = '',
    this.bytes = 0,
    this.mtime = 0,
  });

  final String version;

  /// 归档文件名（`154@1.0.0.js`）
  final String file;

  final int bytes;

  /// Unix 秒
  final int mtime;

  /// 归档时间（本地时区，给弹窗显示）
  DateTime get at => DateTime.fromMillisecondsSinceEpoch(mtime * 1000);

  factory PluginVersionEntry.fromJson(Map<String, dynamic> j) =>
      PluginVersionEntry(
        version: j['version'] as String? ?? '',
        file: j['file'] as String? ?? '',
        bytes: (j['bytes'] as num?)?.toInt() ?? 0,
        mtime: (j['mtime'] as num?)?.toInt() ?? 0,
      );
}

// ═══════════════════════════════════════════════════════════════════════
//  插件弹幕（task-T2，2026-10-16）
// ═══════════════════════════════════════════════════════════════════════
//
// 这三个类对应 Rust 侧的 `WireComment` / `DanmakuBundle` / `DanmakuSendResult`。
//
// # ★ 为什么 wire 格式与 dandanplay 的 `{cid, p, m}` 逐字一致
//
// 因为宿主渲染层**已经有**解析器：`lib/core/danmaku.dart` 的
// `DanmakuComment.parse({cid, p, m})`。插件输出直接喂它 ⇒
// **零新增解析逻辑**，不存在「两套解析各写一半、结果不一致」的经典问题。
//
// 而且这个形状与**外部视频源弹幕 XML 天然同构**（颜色/模式语义一致），
// 也与**某些动画站的弹幕后端**对齐（它们直接走 dandanplay 协议）——
// 所以它是多方交集的**最小公倍数**，不是为某一个站点量身定的。

/// 插件返回的一条弹幕（wire 形态）
///
/// `p` 的分段（宿主 `DanmakuComment.parse` 逐字实现）：
/// ```text
/// "出现时间秒,模式,颜色,用户ID"
///   模式  1 = 滚动（右→左）   4 = 底部固定   5 = 顶部固定   其余 → 归滚动
///   颜色  十进制 24 位 RGB（0xFFFFFF = 16777215）
/// ```
class PluginWireComment {
  const PluginWireComment({this.cid, required this.p, required this.m});

  /// 弹幕唯一编号
  ///
  /// ⚠️ 契约里**可空**（外部视频源弹幕 XML 没有这个概念）。
  ///    Rust 桥接层已按下标 + 1 补位 —— 见 [PluginDanmakuBundle] 的说明。
  final int? cid;

  /// `"时间,模式,颜色,用户ID"`
  final String p;

  /// 弹幕正文
  final String m;

  factory PluginWireComment.fromJson(Map<String, dynamic> j) =>
      PluginWireComment(
        cid: (j['cid'] as num?)?.toInt(),
        p: j['p'] as String? ?? '',
        m: j['m'] as String? ?? '',
      );

  /// 转成 `DanmakuComment.fromJson` 能直接吃的 Map
  ///
  /// ★ 这里**必须**保证 `cid` 非空 —— 见 [PluginDanmakuBundle.fromJson] 的说明。
  Map<String, dynamic> toWireJson() => {
        if (cid != null) 'cid': cid,
        'p': p,
        'm': m,
      };
}

/// 插件取弹幕的返回
class PluginDanmakuBundle {
  const PluginDanmakuBundle({
    this.items = const [],
    this.source = '',
    this.truncated = false,
  });

  final List<PluginWireComment> items;

  /// 这条弹幕从哪来（如 `"bili:777"`）—— 排错时的唯一线索
  final String source;

  /// ★ 上游是否被**截断**（本版本不做分页，只如实告知）
  ///
  /// 必须让用户能看出「这是前 N 条」而不是假装全量 ——
  /// 与「如实说明这条弹幕怎么找到的」同一条纪律。
  final bool truncated;

  bool get isEmpty => items.isEmpty;

  factory PluginDanmakuBundle.fromJson(Map<String, dynamic> j) {
    final raw = j['items'];
    final out = <PluginWireComment>[];
    if (raw is List) {
      for (final e in raw) {
        /*
         * 用 `jmapOrNull` 而不是 `jmap`：**单条格式坏掉不该毁掉整批**。
         * 弹幕是「多一条少一条都能看」的数据，与登录态那种
         * 「解不出就必须报错」的语义相反。
         */
        final m = jmapOrNull(e);
        if (m != null) out.add(PluginWireComment.fromJson(m));
      }
    }
    /*
     * ★★★ 客户端兜底：缺 cid 就补「下标 + 1」
     *
     * 正常路径上 Rust 桥接层（`DanmakuBundle::fill_missing_cids`）已经补过，
     * 这里**不是**重复劳动 —— 它是**防绕过**：
     * ```text
     * DanmakuComment.fromJson 在 cid == null 时 return null（整条丢弃，不报错）
     * ⇒ 只要有一条漏网，用户就会看到「加载成功但少了几条」且无从排查
     * ```
     * 两处都补的成本是一次 `is None` 判断，收益是那条链路**不可能**静默丢弹幕。
     */
    for (var i = 0; i < out.length; i++) {
      if (out[i].cid == null) {
        out[i] = PluginWireComment(
          cid: i + 1,
          p: out[i].p,
          m: out[i].m,
        );
      }
    }
    return PluginDanmakuBundle(
      items: out,
      source: j['source'] as String? ?? '',
      truncated: j['truncated'] as bool? ?? false,
    );
  }
}

/// 插件发送弹幕的返回
///
/// ⚠️ [ok] 为 true 是「**上游确实收下了**」的承诺，不是「我们试过了」。
///    未实现 / 上游拒绝时 Rust 侧**抛异常**（不会给 ok=false）——
///    调用方据此如实告知用户，**绝不**自行把失败当成功。
class PluginDanmakuSendResult {
  const PluginDanmakuSendResult({this.ok = false, this.id = ''});

  final bool ok;

  /// 上游回传的弹幕 id（有则给，便于用户核对）
  final String id;

  factory PluginDanmakuSendResult.fromJson(Map<String, dynamic> j) =>
      PluginDanmakuSendResult(
        ok: j['ok'] as bool? ?? false,
        id: j['id'] as String? ?? '',
      );
}

// ═══════════════════════════════════════════════════════════════════════
//  播放失败的**用户可见文案** —— 净化 + 归因（Owner 第 6 / 7 条）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个模块解决的两件事
//
// ```text
// 第 7 条  「就不要加上溯影自己的信息了，就只显示插件的报错信息就足够了」
//          ⇒ 剥掉宿主加的包装前缀，只留插件原文
//
// 第 6 条  「要优化报错信息，现在不知道是源的问题还是软件本身的问题」
//          ⇒ 把失败归到三类，并给出能照着做的下一步
// ```
//
// # 为什么必须单独一层（而不是在 player_page 里各写一句 if）
//
// ```text
// ① 赋值点有 9 处（_load / _startPlayback / _reload / 换源 / 换台 / 本地…），
//    每处各写一份判定 ⇒ 必然漂（本仓已有「两处同构必须一起改」的教训）
// ② 它是**纯函数**，可以脱离 UI 直接单测 —— 而 UI 层的判据只能靠渲染树间接验
// ③ 归因结论与「怎么显示」分开：将来换 UI 只改渲染，不动判据
// ```
//
// # ⚠️ 净化**只删宿主加的包装**，绝不删插件自己的话
//
// ```text
// 删  SourinCoreException(other):    ← ffi.dart 的 toString 拼的
// 删  插件报错:                       ← plugins/mod.rs 的 Other 分支包装
// 留  该内容需要大会员…               ← ★ 插件原文，一个字都不动
// ```
// 判据见 [PlaybackErrorText.stripHostErrorNoise]：只削**开头**的已知前缀，
// 中间出现的同名字样一律不碰（插件自己说的话里也可能有这些词）。

/// 一次播放失败**归到哪一类**（决定给用户看什么、给什么按钮）
///
/// # 为什么要分类而不是一句话兜底
///
/// Owner 第 6 条的原话是「现在不知道是源的问题还是软件本身的问题」——
/// 用户要的是**能判断该找谁**。几类失败的处置完全不同：
/// ```text
/// source     这个源没给可播地址   → 换源 / 换集（用户能自己解决）
/// proxy      内置代理没起来       → 重试（软件侧，重试往往就好）
/// decode     这个格式解不了       → 换线路（这条线路的编码本机解不了）
/// permission 源站要会员/地区      → 换源（软件不绕过，也不该假装能修）
/// network    源站限流/临时故障     → 等一会儿重试
/// unknown    归不到上面任何一类   → 只显示原文，不猜
/// ```
enum PlaybackFailureKind {
  /// 源解析失败：插件没返回可播地址 / 返回的地址本身不可用
  source,

  /// 内置代理没起来，或代理起来了但转发失败
  proxy,

  /// 取到了流，但本机解不了（编码/封装）
  decode,

  /// 源站明确要求会员 / 地区 / 版权
  permission,

  /// 源站限流 / 5xx / 超时
  network,

  /// 归不到任何一类
  unknown,
}

/// 一次播放失败的**结构化描述**（UI 只读这个，不再自己解析字符串）
class PlaybackFailure {
  const PlaybackFailure({
    required this.kind,
    required this.detail,
    this.canRetry = true,
    this.canSwitchSource = true,
  });

  final PlaybackFailureKind kind;

  /// 给用户看的**正文**（已净化：不含宿主前缀、不含内部代理地址）
  final String detail;

  /// 重试有没有意义（源站权限问题重试一万次都一样）
  final bool canRetry;

  /// 换源有没有意义（解码问题换源常常有用，代理问题重试更直接）
  final bool canSwitchSource;

  /// 一行「这是什么」（**用户可见文案**）
  ///
  /// ⚠️ 不许出现：宿主类名、内部代理地址、开发过程用语。
  String get headline => switch (kind) {
    PlaybackFailureKind.source => '这个源没有返回可播放地址',
    /*
     * ★★★ 2026-10-18（第 66 轮 R2，Owner 真机反馈）
     *
     * 原文案是「内置代理没起来」。**它在多数情况下是假话**：
     * ```text
     * Owner 实测日志（sourin-2026-10-18.log）：
     *   19:03:01  起播 OK   端口 57106
     *   19:03:06  起播失败  Failed to open http://127.0.0.1:57106/…
     *   19:03:48  起播 OK   端口 57106   ← 同一个端口，代理一直活着
     *   19:07:25  起播 OK   端口 57106
     * ⇒ 代理没"没起来"，是**那一条流**打不开。
     * ```
     * Owner 的原话是「内置代理没起来，这个要修复啊，很严重的 bug」——
     * 他看到这句话，合理地以为代理进程挂了。**措辞制造了一个不存在的故障。**
     *
     * ⇒ 改成如实描述「这一条流取不到」。它同时覆盖两种真实情况：
     *    · 代理真没起来（那就整页都播不了，用户能自己看出来）
     *    · 代理活着但这条流失败（这才是绝大多数）
     * ⚠️ 这里**不能**写具体端口 —— 那是内部地址，随进程退出就失效。
     */
    PlaybackFailureKind.proxy => '这一条流取不到',
    PlaybackFailureKind.decode => '这个格式解不了',
    PlaybackFailureKind.permission => '这个内容需要源站会员，或不在当前地区',
    PlaybackFailureKind.network => '源站暂时连不上',
    PlaybackFailureKind.unknown => '播放失败',
  };

  /// 给用户的**下一步**（空串 = 没什么可说的，别硬凑）
  String get nextStep => switch (kind) {
    PlaybackFailureKind.source => '换一个源，或者换一集再试。',
    /*
     * ★ 2026-10-18（R2 同批）：原文是「点『重试』。如果一直这样，重启客户端。」
     * 代理活着时重启客户端**没有用**（见 headline 那段实测日志），
     * 让用户去做一件无效的事，比不给建议更糟。
     */
    PlaybackFailureKind.proxy => '点「重试」，或者换一条线路。',
    PlaybackFailureKind.decode => '换一条线路试试（右上角的线路列表）。',
    PlaybackFailureKind.permission => '换一个源。这不是客户端能绕过的东西。',
    PlaybackFailureKind.network => '等一会儿再点「重试」。',
    PlaybackFailureKind.unknown => '',
  };

  @override
  String toString() => 'PlaybackFailure(${kind.name}: $detail)';
}

/// 播放失败文案的净化与归因（**纯函数**，无副作用、可单测）
class PlaybackErrorText {
  const PlaybackErrorText._();

  /// 宿主在错误消息外面套的已知前缀 —— **只削开头**，只削这些
  ///
  /// ```text
  /// SourinCoreException(other):       ← lib/core/ffi.dart 的 toString()
  /// SourinCoreException(network):     ← 同上（kind 不同）
  /// 插件报错:                          ← rust/sourin_core/src/plugins/mod.rs 的 Other 包装
  /// Exception:                        ← Dart 自带的裸包装
  /// ```
  ///
  /// ⚠️ 顺序有讲究：先削 `SourinCoreException(...)` 再削 `插件报错:`，
  ///    因为真实消息是「类名 + 插件报错: + 原文」这个嵌套顺序。
  static final List<RegExp> _hostPrefixes = <RegExp>[
    // SourinCoreException(kind):    —— 只认宿主自己的类名，别的 Exception 不动
    RegExp(r'^SourinCoreException\s*\([^)]*\)\s*[:：]\s*'),
    // 插件报错:                     —— plugins/mod.rs 的 Other 分支包装
    RegExp(r'^插件报错\s*[:：]\s*'),
    // 裸 Exception:                —— Dart 默认包装（仅当后面还有内容时）
    RegExp(r'^Exception\s*[:：]\s*(?=\S)'),
  ];

  /// 剥掉**宿主加的**包装前缀，只留插件原文（Owner 第 7 条）
  ///
  /// # 判据
  /// ```text
  /// ① 只削**开头**：中间出现的同名字样一律不碰
  ///    （插件自己说的话里也可能有「插件报错:」）
  /// ② 反复削到不动为止：包装可能叠了两三层
  ///    （实测真实消息 = 「SourinCoreException(other): 插件报错: 该内容需要大会员…」）
  /// ③ 削完为空 ⇒ 退回原文（宁可显示一句带前缀的话，也不要显示空白）
  /// ```
  ///
  /// ⚠️ 不做任何「翻译」/「改写」：留下的就是插件说的那句话。
  ///    这是 Owner 的原话要求 —— 「只显示插件的报错信息就足够了」。
  static String stripHostErrorNoise(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return s;
    // 最多削 5 轮（防御无限循环；正常只有 2 层）
    for (var i = 0; i < 5; i++) {
      final before = s;
      for (final re in _hostPrefixes) {
        s = s.replaceFirst(re, '').trim();
      }
      if (s == before) break;
    }
    return s.isEmpty ? raw.trim() : s;
  }

  /// 内部代理地址的**特征** —— 这类地址绝不能出现在用户可见文案里
  ///
  /// # 为什么是「环回地址 + /s/ 路径」
  /// ```text
  /// 用户看到的原文是：
  ///   Failed to open http://127.0.0.1:57209/s/18df.../
  /// 其中 127.0.0.1:<随机端口> 是**内置代理**，随进程退出就失效。
  /// 把它显示给用户有三个问题：
  ///   ① 用户看不懂，也无法据此判断是源的问题还是软件的问题（第 6 条原话）
  ///   ② 那个端口事后无法回连，写进截图只会误导排查
  ///   ③ 它暴露了内部实现（与本仓 CWE-532 同一条纪律）
  /// ```
  ///
  /// ⚠️ 只用于**文案**：日志与 AppLog 照旧记完整地址（那是排查用的）。
  ///
  /// ★★ 2026-10-19（Lead 修，`r3-dns` 复核时查出）：原正则只认 `/s/<id>` **一种形态**
  /// ```text
  //  原：RegExp(r'https?://(?:127\.0\.0\.1|localhost|\[::1\]):\d+/s/\S*')
  //  实测（Lead 亲自跑，四条输入对照）：
  //    ok    '…http://127.0.0.1:57106/s/18df9acc/.'  ⇒ '内置代理取不到这条流'
  //    LEAK  'LEAK http://127.0.0.1:1/'              ⇒ 原样输出
  //    LEAK  'boom http://127.0.0.1:9999/api/v2/…' ⇒ 原样输出
  //    LEAK  '取流失败 http://localhost:2080/movie/x.mp4' ⇒ 原样输出
  //  ⇒ 换端口/换路径就直接漏，与本函数自己写的三条理由（用户看不懂 /
  //    端口失效会误导排查 / 暴露内部实现）**直接冲突**。
  //  ⇒ 修法：**不锚定任何路径**，环回 host + 端口后面一律吃掉。
  // ```
  ///
  /// ⚠️ 为什么不能贪吃过头：`\S*` 会把**紧跟其后的标点与后续文字**一起吞掉
  ///   （例如「取流失败(地址)后重试」里的 `)` 与「后重试」）。
  ///   而环回 URL 在句中几乎总是被空白、行尾或标点包围，所以**只吃 URL 自身的字符集**。
  ///
  /// ★★ 2026-10-19（Lead 第三次修）：字符类**只放 URL 真正可能出现的 ASCII 字符**
  /// ```text
  /// 放： A-Za-z0-9 - . _ ~ % : / ? # [ ] @ & = + ;
  /// 不放： ) ] } > ' " ` , ! * (   ← 这些是**句子结构**，不是 URL
  ///       其它一切（含全部 CJK）也**不在集合内** ⇒ 天然终止匹配
  /// ```
  /// ⇒ 好处有两层，不必再单独维护一份「中文标点」清单：
  ///   ① `)` 后面的正文**根本进不来**（不是进来了再剪掉）
  ///   ② query `?a=1&b=2` **保得住**（`? & =` 都在集合里）
  ///      —— 第一版把 ASCII 标点排掉是为了救 `)`，结果把 query 也吃掉了；
  ///      这里改为**精确列出 URL 字符**，两个问题一起消失。
  static final RegExp _loopbackProxyUrl = RegExp(
    r'https?://(?:127\.0\.0\.1|localhost|\[::1\])(?::\d+)?(?:[/?#][A-Za-z0-9\-._~%:/?#\[\]@&=+;,]*)?',
    caseSensitive: false,
  );

  /// 把内部代理地址从**用户可见文案**里抹掉
  ///
  /// 替换成一句中性说明，而不是留空 —— 留空会让句子读起来像被截断了。
  ///
  /// ★★ 2026-10-19（Lead 第二次修，`r4-dialog` 复核时查出的真缺陷）：
  /// 第一版只把 **CJK 标点**排除在字符类外，**ASCII 标点仍在射程内** ⇒
  /// ```text
  /// IN : '取流失败(http://127.0.0.1:8080/s/x)后重试'
  /// OUT: '取流失败(（内置代理地址）'      ← ')' 连同「后重试」三个字全没了
  /// IN : 'see http://127.0.0.1:8080/s/x, retry'
  /// OUT: 'see （内置代理地址） retry'    ← ', ' 被吃
  /// ```
  /// ★ 这正是本函数注释里说的那种「缺字句」，只是发生在 ASCII 上。
  ///
  /// # 为什么是「字符类 + 事后剪尾」两条一起上，而不是只改字符类
  /// ```text
  /// 只把 ASCII 标点排进字符类 ⇒ 修复上面两条，但 URL 的 query 会被吃掉：
  ///   '…/api?a=1&b=2' 里 '&'、'=' 一旦排掉 → 只剩 '?a'，信息错得**更隐蔽**。
  /// 而 `)` 这条**事后剪尾救不回来** —— 它已经被字符类吃进 match 里了。
  /// ⇒ 两条必须同时上：字符类负责「别多吞」，剪尾负责「别把尾随标点带走」。
  /// ```
  static String hideInternalUrls(String raw) {
    if (raw.isEmpty) return raw;

    // ① 正则逐字匹配，但每个 match 命中后**剪掉尾随标点**
    const tailPunct = '.,;:!?)]}>\'"`';
    final buf = StringBuffer();
    var last = 0;
    for (final m in _loopbackProxyUrl.allMatches(raw)) {
      var hit = m[0]!;
      var cut = 0;
      while (hit.length - cut > 1 && tailPunct.contains(hit[hit.length - 1 - cut])) {
        cut++;
      }
      buf
        ..write(raw.substring(last, m.start))
        ..write('（内置代理地址）')
        ..write(hit.substring(hit.length - cut));
      last = m.end;
    }
    buf.write(raw.substring(last));
    var s = buf.toString();

    // 抹掉之后会剩下「Failed to open （内置代理地址）」这种英文尾巴，
    // 整句替换成中文（**只认这一种已知形态**，别的英文原样留着）
    s = s.replaceAll(
      RegExp(r'Failed to open\s*（内置代理地址）\.?', caseSensitive: false),
      '内置代理取不到这条流',
    );
    return s.trim();
  }

  /// 归因：把一条失败**归到几类之一**（第 6 条）
  ///
  /// # 判据全部来自**实测读数**（不是猜）
  ///
  /// ```text
  /// 代理（B 类）—— 证据最硬，排最前
  ///   · 「取流失败: error sending request for url (…)」
  ///     实测：rust/sourin_core/src/streamproxy.rs 的 BAD_GATEWAY 正文
  ///   · 「内置代理地址」（hideInternalUrls 的产物）
  ///   · Connection refused / 连接被拒绝
  ///
  /// 源站权限（E 类，不绕过）
  ///   · 原文含「大会员 / 会员 / VIP / 付费 / 地区 / 版权 / 无权」
  ///   · 结构化 kind = unauthorized
  ///
  /// 源站限流（F 类）
  ///   · 5xx / 超时 / 429 / 「稍后」/「限流」
  ///
  /// 解码（A 类）
  ///   · mpv 的编解码错误原句（Could not open codec / Invalid data found /
  ///     Failed to recognize file format / Unsupported / codec）
  ///
  /// 源解析（D 类）
  ///   · 「没有可播放的地址」「无法路由」/ 候选列表为空
  /// ```
  ///
  /// ⚠️ 判据顺序：**代理 → 权限 → 限流 → 解码 → 源**。
  ///    代理排最前是因为那条 502 正文只有代理会产出；
  ///    解码排在源前面，是因为「取到流但解不了」比「源没给地址」更具体。
  /// 从一段错误文本里抠出**明确的** HTTP 状态码（没有就返回 null）
  ///
  /// # 为什么要这么小心（不能简单 `contains('403')`）
  /// ```text
  /// 反例（都会造成误判）：
  ///   「第 403 集不存在」      ← 集数
  ///   「视频时长 403 秒」      ← 时长
  ///   「403号房间」            ← 房间号
  ///   「/videos/202503/20/...」← 路径里的数字
  /// ```
  /// ⇒ 只认**带协议上下文**的形态：
  /// ```text
  /// http 403 / http/1.1 403 / 403 forbidden / status=403 / status: 403
  /// 以及**整段文本恰好就是**一个三位状态码（如 "403"）
  /// ```
  /// ⚠️ 只认 100..599 区间 —— 避免把年份、id 之类当成状态码。
  static int? _extractHttpStatus(String lower) {
    /*
     * ★ 先做**排除**：文本里含 URL 时不认「裸三位数」与 `http<数字>` 形态
     *
     * # 实测踩到的误判（本文件的门禁抓到的，不是猜的）
     * ```text
     * 输入: https://cdn.example.com/videos/202503/20/x.m3u8
     * 改前: 正则 `http[/\s]*[0-9.]*\s*(\d{3})` 从 "…/202503/…" 里
     *       抠出 "503" ⇒ 归成 network（源站限流）—— 完全错误的归因
     * ```
     * URL 里的数字是**路径/时间戳**，与状态码无关。
     * ⇒ 含 `://` 的文本一律不认裸数字，只认显式的 `status=NNN` 或 `NNN Forbidden`。
     */
    final looksLikeUrl = lower.contains('://');

    // ① 带协议/状态上下文
    for (final re in <RegExp>[
      // `http 403` / `http/1.1 403` / `http status 403`
      //
      // ⚠️ 必须要求 http 后面**紧跟**可选版本号再是状态码，
      //    且**不许**跨越 `/` 之外的路径字符 —— 否则会从 URL 里抠数字。
      RegExp(r'\bhttp(?:/[0-9.]*)?\s+(?:status\s*[:=]?\s*)?(\d{3})\b'),
      RegExp(r'\bstatus\s*[:=]\s*(\d{3})\b'),
      RegExp(r'\b(\d{3})\s+(?:forbidden|unauthorized|too\s+many|'
          r'internal\s+server|bad\s+gateway|service\s+unavailable|'
          r'gateway\s+time-?out|not\s+found)\b'),
    ]) {
      final m = re.firstMatch(lower);
      if (m != null) {
        final n = int.tryParse(m.group(1) ?? '');
        if (n != null && n >= 100 && n <= 599) return n;
      }
    }
    // ② 整段文本恰好就是一个状态码（插件/代理有时只回这三个字符）
    //
    // ⚠️ 含 URL 时**不认**这一条：URL 里恰好只有三位数字的情形不该被当状态码。
    if (!looksLikeUrl) {
      final whole = lower.trim();
      if (RegExp(r'^\d{3}$').hasMatch(whole)) {
        final n = int.tryParse(whole);
        if (n != null && n >= 100 && n <= 599) return n;
      }
    }
    return null;
  }

  /// 归因：把一条失败**归到几类之一**（第 6 条）
  ///
  /// 判据顺序见本方法内注释（HTTP 状态码 → 代理 → 权限 → 限流 → 解码 → 源）。
  static PlaybackFailure classify(
    Object? error, {
    String? kindHint,
    bool hadCandidates = false,
  }) {
    final raw = error == null ? '' : error.toString();
    /*
     * ★★★ 2026-10-18（第 66 轮 R2，Owner 真机报「内置代理没起来」）：这里原来是
     *
     *     final text = stripHostErrorNoise(hideInternalUrls(raw));
     *
     * `hideInternalUrls` 是**给用户看的展示函数**（把 `127.0.0.1:57106` 抹成
     * 「内置代理取不到这条流」），但它被拿来**生成归因输入** ⇒ 自我强化的误判环：
     *
     * ```text
     * 真实错误：Failed to open http://127.0.0.1:57106/s/18df9acc…/.
     *   ① hideInternalUrls 改写成「内置代理取不到这条流」
     *   ② 下面 ① 段的 proxyDown 判据含 lower.contains('内置代理')
     *   ③ ⇒ 恒命中 ⇒ kind = proxy ⇒ UI 显示「内置代理没起来」
     * ```
     * **Owner 实测反证**：同一端口 57106 在 43 秒后（19:03:48）、4 分钟后、
     * 6 分钟后**都成功起播**。代理一直是活的，是他点的那一条流取不到。
     *
     * ⇒ 归因必须读**原始文本**。展示改写只在渲染时做（`player_page.dart:17110`
     *   那里仍然调用 hideInternalUrls，那是对的）。
     *
     * ★ 这条属于本轮反复出现的同一类错误：**判据作用在了被改写过的对象上**。
     */
    final text = stripHostErrorNoise(raw);
    /*
     * ★ `detail` 是**给用户看的正文** ⇒ 必须用净化版（抹掉 127.0.0.1:PORT 这类
     *   内部地址，见 Owner 第 6 条诉求 + `zz_r65_error_text_test` ③）。
     *   而 `lower` 是**归因输入** ⇒ 必须用原文，否则又会落进
     *   「hideInternalUrls 的产物『内置代理…』让 proxyDown 恒真」那个误判环。
     * ⇒ 两个用途，两份文本，不许混用。
     */
    final display = hideInternalUrls(text);
    final lower = text.toLowerCase();

    /*
     * ── ⓪ 先按 **HTTP 状态码** 归因（轨道 H · 2026-10-18 新增）─────────
     *
     * # 为什么必须排在所有关键词之前
     *
     * ```text
     * 实测（`.probe/round65-c/samples_run6.log`，32 个源 35 条样本）：
     *   代理把上游的 403 原样转出来，正文是一张 **HTML 错误页**：
     *     <h1>403 Forbidden</h1>
     *     <p>The region has been denied.</p>
     *   而改前的判据只认中文关键词（「大会员」「地区」「版权」…），
     *   **完全没有 403/401 这两个数字**。
     *   ⇒ 这条真实的「源站地区限制」落到 unknown，
     *     用户看到的是那张 HTML 错误页原文 —— 既看不懂也不知道该找谁。
     * ```
     *
     * # 判据顺序：数字比词可靠
     * ```text
     * 「403」是**协议层事实**；「地区」是我们从人话里猜的。
     * 协议事实优先 —— 这跟本仓 `classify_error` 的
     * 「先认标准前缀，再退中文关键词」是同一条纪律。
     * ```
     *
     * ⚠️ 只在**明确的 HTTP 状态**上下文里认这三个数（`http 403` / `403 forbidden`
     *    / `status=403` / 单独出现的 403 作为独立词），
     *    避免把「403 集」「403 号」这类**内容里的数字**当成状态码。
     */
    final httpCode = _extractHttpStatus(lower);
    if (httpCode != null) {
      // 401 / 403 ⇒ 源站权限（E 类：只优化提示，不绕过）
      if (httpCode == 401 || httpCode == 403) {
        return PlaybackFailure(
          kind: PlaybackFailureKind.permission,
          detail: display,
          // ★ 权限问题重试一万次都一样
          canRetry: false,
        );
      }
      // 429 / 5xx ⇒ 源站限流或临时故障（F 类）
      if (httpCode == 429 || (httpCode >= 500 && httpCode <= 599)) {
        return PlaybackFailure(
          kind: PlaybackFailureKind.network,
          detail: display,
        );
      }
      // 404 / 410 ⇒ 地址没了，归源解析失败
      if (httpCode == 404 || httpCode == 410) {
        return PlaybackFailure(
          kind: PlaybackFailureKind.source,
          detail: display,
        );
      }
    }

    // ── ① 内置代理（B 类）────────────────────────────────────────
    /*
     * ★★★ 判据为什么只认「连不上代理」而不认「取流失败」
     *
     * 实测（`.probe/round65-c/samples_run4.log`）：
     * ```text
     * [streamproxy] IN token=18df5e319265 path=/s/…
     * [streamproxy] UP send FAILED after 1072ms: error sending request for url (…)
     * [streamproxy] OUT status=502 elapsed=1072ms
     *          fetch → status=502 bytes=112 ct=text/plain
     * ```
     * 那条 502 的正文是 `取流失败: error sending request for url (…)`，
     * 它是**代理活着、但上游连不上**（本例上游域名根本解析不出来）。
     *
     * ⇒ 把它归成「内置代理没起来」就是**第二次误归**：
     *   代理明明是好的，坏的是那个源。这恰好重复了 Owner 抱怨的那件事
     *   （「不知道是源的问题还是软件本身的问题」）。
     * ⇒ 所以「取流失败」归 **source**，并明说「上游连不上」。
     *
     * 只有下面这些才是「代理这一层坏了」：
     * ```text
     * · 环回地址被拒（Connection refused）—— 代理进程没起/端口已死
     * · mpv 打不开**本机环回地址**（`Failed to open http://127.0.0.1:PORT/…`）
     * ```
     *
     * ⚠️ 2026-10-18（第 66 轮 R2）：原来这条判据写的是
     *    `lower.contains('内置代理')` —— 那是 `hideInternalUrls()` 的**产物**。
     *    而上面 `text` 现在已是原文，**这四个字永远不会出现** ⇒ 死判据。
     *    必须改成认**环回地址本身**（`127.0.0.1` / `localhost`）。
     *
     *    Owner 实测（19:03:06 失败、19:03:48 同端口成功）证明：
     *    归成 proxy 本身没错，错的是**「没起来」这个措辞** ——
     *    代理是起来的，只是那一条流打不开。措辞见 `_headline`。
     */
    final loopbackFailed = lower.contains('127.0.0.1') ||
        lower.contains('localhost') ||
        lower.contains('[::1]');
    final proxyDown = lower.contains('connection refused') ||
        lower.contains('连接被拒绝') ||
        // mpv 明确说「打不开」+ 目标是环回地址 ⇒ 是代理这一层
        (lower.contains('failed to open') && loopbackFailed);
    if (proxyDown) {
      return PlaybackFailure(
        kind: PlaybackFailureKind.proxy,
        detail: display,
        // 代理重启后重试通常就好；换源治不了代理
        canSwitchSource: false,
      );
    }

    /*
     * 代理**活着**但上游连不上（实测 502 正文）—— 那是源的问题，不是软件的。
     *
     * ★ 单独一支，因为它与「源没给可播地址」的处置不同：
     *   前者可以重试（上游可能只是抖了），后者换源才有用。
     */
    if (lower.contains('取流失败')) {
      return PlaybackFailure(
        kind: PlaybackFailureKind.source,
        detail: display,
      );
    }

    // ── ② 源站权限（E 类：只优化提示，不绕过）─────────────────────
    const permWords = <String>[
      '大会员', '会员', 'vip', '付费', '购买', '订阅',
      '地区', '版权', '仅限', '无权', '没有权限', '权限不足',
      '需要登录', '登录后', 'unauthorized',
    ];
    if (permWords.any(lower.contains) || kindHint == 'unauthorized') {
      return PlaybackFailure(
        kind: PlaybackFailureKind.permission,
        detail: display,
        // ★ 权限问题重试一万次都一样 —— 不给重试按钮是**诚实**
        canRetry: false,
      );
    }

    // ── ③ 源站限流 / 临时故障（F 类）─────────────────────────────
    /*
     * ★★★ 裸数字（429/502/503/504）**不能**用 `contains` 判
     *
     * 实测误判（本文件门禁抓到的）：
     * ```text
     * https://cdn.example.com/videos/202503/20/x.m3u8  ⇒ contains('502') 命中 "202503"
     * https://cdn.example.com/a/503/x.m3u8             ⇒ contains('503') 命中 "/503/"
     * 两条都被归成「源站限流」—— 而它们只是**路径里恰好有那几个数字**。
     * ```
     * ⇒ 数字一律走 [`_extractHttpStatus`]（带协议上下文才算），
     *    `netWords` 只留**文字**关键词。
     */
    const netWords = <String>[
      'timeout', '超时', 'timed out',
      'too many requests', '稍后', '限流', 'temporarily',
    ];
    if (netWords.any(lower.contains) || kindHint == 'network') {
      return PlaybackFailure(
        kind: PlaybackFailureKind.network,
        detail: display,
      );
    }

    // ── ④ 解码（A 类）────────────────────────────────────────────
    // 这几条是 libmpv 的原句，实测形态见本方法的文档
    const decodeWords = <String>[
      'could not open codec', 'unsupported', 'invalid data found',
      'failed to recognize file format', 'no video', '解码',
      'codec', '不支持的格式',
    ];
    if (decodeWords.any(lower.contains)) {
      return PlaybackFailure(
        kind: PlaybackFailureKind.decode,
        detail: display,
      );
    }

    // ── ⑤ 源解析（D 类）──────────────────────────────────────────
    const srcWords = <String>[
      '没有可播放的地址', '不可播', '无法路由', 'not found',
      'no playable', '找不到', '解析',
    ];
    if (srcWords.any(lower.contains) || !hadCandidates) {
      return PlaybackFailure(
        kind: PlaybackFailureKind.source,
        detail: display,
      );
    }

    return PlaybackFailure(kind: PlaybackFailureKind.unknown, detail: text);
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  N12 · 登录轮询失败**按真因分类**（Owner：「提示网络异常 这也是bug」）
// ═══════════════════════════════════════════════════════════════════════
//
// # 缺陷（改前）
//
// `lib/ui/widgets/provider_login_panel.dart` 的二维码轮询里是：
// ```dart
// } catch (_) {
//   _qrPolling = false;
//   if (mounted) setState(() => _qrMsg = '网络异常，重试中…');
//   return;
// }
// ```
// **catch-all 吞掉一切**，然后一律告诉用户「网络异常」。
//
// # 为什么这是缺陷（不是措辞问题）
//
// ```text
// 实测（轨道 H · 第 4 步）：
//   核心层 qr_login_start  ✓ 440ms 真申请成功
//   qr_login_poll 假 key   ✓ 42ms  status=Expired（正常返回，不抛）
//   qr_login_poll 真 key   ✓ 41ms  status=Pending（正常返回，不抛）
//   连打 3 次              ✓ 59/86/85ms 全 Pending，一次没抛
// ⇒ 网络其实一直是好的。那句「网络异常」是**猜的**。
// ```
// 用户看到「网络异常」会去查网线、换 Wi-Fi、重启路由 —— 全是白费。
// 这正是 Owner 第 6 条抱怨的同一个毛病：
// **「不知道是源的问题还是软件本身的问题」**。
//
// # 改法：**先分类，再说人话**
//
// ```text
// network   SocketException / TimeoutException / 'network:' 前缀 / 超时
//           ⇒ 「网络异常，重试中…」  ← 这时原文案是**对的**，保留
// notReady  核心未就绪 / dll 没绑上 / UnsupportedError
//           ⇒ 「核心未就绪，正在重试…」 ← 与网络无关，别让用户查网线
// other     其余
//           ⇒ 「轮询失败：<原文>」     ← 透传，但保留真因
// ```
//
// ⚠️ 分类是**纯函数**，不碰 UI、不碰网络 ⇒ 可以脱离界面直接单测。
class QrPollErrorText {
  const QrPollErrorText._();

  /// 网络类错误的关键词（命中即认为是真的网络问题）
  ///
  /// ⚠️ 用 `kind` 而不是只靠字符串：`SourinCoreException.kind` 是**结构化**的
  ///    （`network` 由核心侧判定），比从文案里猜可靠。
  static bool _isNetwork(Object? e) {
    final s = (e ?? '').toString().toLowerCase();
    // 结构化 kind 优先
    if (e is SourinCoreException && e.kind == 'network') return true;
    const words = <String>[
      'socketexception',
      'timeoutexception',
      'handshakeexception',
      'network:',
      'network is unreachable',
      'connection refused',
      'connection reset',
      'connection closed',
      'connection terminated',
      'failed host lookup',
      '超时',
      '网络',
      '连不上',
      '连接被',
    ];
    return words.any(s.contains);
  }

  /// 「核心还没准备好」类错误
  ///
  /// ```text
  /// 实测形态（lib/core/ffi.dart）：
  ///   UnsupportedError('不支持的平台: …')
  ///   DynamicLibrary.open 失败（dll 不在）
  ///   核心尚未启动 / 核心不可用
  /// ```
  /// 这些**与网络毫无关系**，告诉用户「网络异常」是纯粹的误导。
  static bool _isNotReady(Object? e) {
    final s = (e ?? '').toString().toLowerCase();
    if (e is UnsupportedError) return true;
    const words = <String>[
      '核心尚未启动',
      '核心不可用',
      '核心未就绪',
      'core not',
      'dynamiclibrary',
      'failed to load dynamic library',
      'sourin_core.dll',
      'libsourin_core',
      'not bound',
      '未绑定',
    ];
    return words.any(s.contains);
  }

  /// 给用户看的文案（**必须与真因一致**）
  ///
  /// 返回值刻意保持「可读的一句话」：UI 直接 `setState(() => _qrMsg = ...)`。
  static String of(Object? e) {
    if (_isNetwork(e)) {
      // ★ 原文案在这里是**正确的** —— 网络真的坏了，就该这么说
      return '网络异常，重试中…';
    }
    if (_isNotReady(e)) {
      // ★ 与网络无关：别让用户去查网线
      return '核心未就绪，正在重试…';
    }
    // 其余：透传真因（先剥掉宿主包装前缀，与第 7 条同一纪律）
    final raw = PlaybackErrorText.stripHostErrorNoise(
      PlaybackErrorText.hideInternalUrls((e ?? '').toString()),
    );
    return raw.isEmpty ? '轮询失败，重试中…' : '轮询失败：$raw';
  }
}

