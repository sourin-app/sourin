import 'dart:async';

import 'package:flutter/foundation.dart';

import 'models.dart';
import 'sourin_api.dart';

// ═══════════════════════════════════════════════════════════════════════
//  候选列表预处理 —— 把「播放页 URL」解析成「可播地址」
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要这一层（task-33，Owner 第 10 条）
//
// # Owner 原话（逐字）
// ```text
// > 我们不是要做解析站,要做的只是内置上这个这个播放 解码支持
// > 内置解析能力,解码层也要
// ```
//
// 现有插件契约假设插件给的就是**可播地址**（`StreamCandidate.url` 直接交给 mpv）。
// 但有一类站点的插件**拿不到**可播地址 —— 它只能给出**播放页 URL**，
// 剩下的要宿主自己解。于是契约多了一个位：`needsHostResolve`。
//
// # ★★ 这一层的存在理由：让那个位**真的有消费者**
//
// 本仓铁律：声明了不生效等于骗人。`needsHostResolve` 若没有消费点，
// 就是死代码（与 `theme_pack` 的 `buttonPadding` 全仓零消费同一类缺陷）。
//
// # 为什么放在 lib/core 而不是 player_page
//
// ```text
// · player_page.dart 已被另一位同事在改（弹幕面板），再加一个人必撞车
// · 「解析编排」本来就不是 UI 的职责 —— 播放页只该做「拿列表 → 挑一条 → 播」
// · 放在这里，`SourinApi.resolveStream` / `getLiveStream` 两个出口都能挂
//   ⇒ 两条独立代码路径（点播/直播）不会只修一条
// ```
//
// # ⚠️ 本层的诚实边界
// ```text
// 真正的『解析』能力（自实现签名 / 无头浏览器 / 插件解）**尚未选型**
//  ⇒ 所以这里只做**编排**（决定谁去解、解完怎么改），
//    真正的解析器通过 [StreamResolver] 注入。
//  ⇒ 未注入解析器时，`needsHostResolve` 的候选会被**如实标为不可播**，
//    而不是静默失败或假装成功。
// ```
//
// # ★ N1（2026-11-01，lead 批复①②）：appget 类源的候选摘除判据三态化
//
// ```text
// 背景（.probe/play-audit-cleanenv-2026-10-31.md 实锤）：appget 类源的 play
// 结果普遍是第三方播放页 ⇒ 改前判据 ⑤ 按形态整批摘掉 ⇒ 列表空
// ⇒ 「该内容没有可播放的地址」—— appget 类源完全不能播的直因。
//
// 管线核实（「有路径才保留」）：生产唯一可达的解析路径 = 起播预检
// player/nonmedia_guard.dart::precheckNonMedia（信封/页刮换直链）。
// 实测（appget gsuus）：播放页 HTML 壳内嵌 vid m3u8，GET 200 +
// application/vnd.apple.mpegurl + 合法 #EXTM3U（AES-128 + 真 .ts 分段）
// ⇒ 页面形态候选保留后有真实可播路径，不是"保留一条点了必死的候选"。
// StreamPreparer.resolver 生产零注入（死代码路径），不算依据。
//
// ⚠️ 残余边界（如实，不许当作"已解决"）：
// ① VIP 大站播放页（需 jx 解析接口）页内无流、仓内无 jx ⇒ 预检给人话报错
//    —— 播不了，但不是黑屏/静默；
// ② 页面若嵌假流 ⇒ 预检刮出后 mpv open 失败。
// 两者都由预检兜底；判据层只保证"不摘有路径的候选"。
// ```

/// 三态判据的结论（[StreamPreparer.verdictOf] 的返回值）
enum PrepareVerdict {
  /// 摘：无任何后续路径（空 / 非 http(s) / 无 host / 猜拼媒体后缀；
  /// 证红模式下页面形态也退回这一档）
  drop,

  /// 留 + 标「需解析」：页面形态（改前判据 ⑤ 的命中集），
  /// 起播预检可换真流（见文件头 N1 的实测依据）
  keepMarked,

  /// 直通：直链 / HLS，行为与改前逐字一致
  passthrough,
}

/// N1 三态判据的**证红开关**（仅测试）
///
/// 置真 ⇒ 页面形态退回改前的「摘」⇒ 三态门禁（`t20261101_n1_three_state_prepare_test.dart`）
/// 与 `zz_r65_stream_validation_test.dart` 混合③必须变红 —— 证明新字面有牙。
/// 生产代码**永不**写它。
@visibleForTesting
bool debugShortCircuitPageKeep = false;

/// 把「播放页 URL」解析成「可播地址」的能力
///
/// ⚠️ **目前没有任何实现** —— 三条候选路线（自研签名 / 无头浏览器 / 插件解）
/// 尚未选型（见 `.probe/t33/REPORT.md` §5 与 `REPORT_R2.md` §3）。
/// 接口先定下来，是为了让编排层能独立于选型存在。
typedef StreamResolver = Future<String?> Function(
  String playPageUrl, {
  String? siteId,
});

/// 候选列表预处理
///
/// ## 调用点（这是本类存在的意义，删了它就等于本项目没这个能力）
/// ```text
/// SourinApi.resolveStream()   → 点播，返回前过一遍
/// SourinApi.getLiveStream()   → 直播，返回前过一遍
/// ```
/// 两处都挂，是因为它们是**两条独立代码路径**（`_load()` 里按 `_isLive` 分叉）。
/// 只挂一条会留下「另一边静默黑屏」的口子 —— 本仓历史上正是这么漏的。
class StreamPreparer {
  StreamPreparer._();

  /// 注入的解析器（生产默认为 null ⇒ 未选型，见 [StreamResolver]）
  static StreamResolver? resolver;

  /// 只读：上一轮有多少条候选需要宿主解析（供 UI / 日志用）
  static int lastNeedsResolveCount = 0;

  /// 只读：上一轮有多少条候选**被摘掉**（插件给的地址本身不可用）
  ///
  /// ★ 第 65 轮第 8 条 D 类：这个计数是「补校验真的生效了」的**唯一证据**。
  ///   如果它恒为 0，说明校验没接上（本仓铁律：声明了不生效等于骗人）。
  static int lastDroppedCount = 0;

  /// 只读：上一轮被摘掉的候选**为什么**被摘（给日志与探针用）
  static List<String> lastDroppedReasons = const <String>[];

  /// 只读：上一轮有多少条候选因「页面形态」被**保留并标注**「需解析」（N1）
  ///
  /// 三态留痕的对齐位：[lastDroppedCount] 只收「无任何后续路径」的形态；
  /// 页面形态（有起播预检路径）从这里读数。
  /// ⚠️ **不复用** [lastNeedsResolveCount] —— 它的「needsHostResolve 条数」
  ///    语义被 `zz_t33_stream_prepare_test.dart` 钉着，两回事不许混。
  static int lastKeptNeedsResolveCount = 0;

  /// 判断一条候选的地址**本身**能不能用（不看网络，只看形态）
  ///
  /// # 为什么宿主必须自己校验（第 8 条 D 类）
  ///
  /// ```text
  /// 实测踩到的形态（.probe/round65-c/samples_run4.log）：
  ///   插件给的 url = https://v.gsuus.com/play/dBBBRBxd        ← 是个**播放页**
  ///   代理登记后变成 …/play/dBBBRBxd/index.m3u8                ← 插件自己拼了个后缀
  /// ⇒ 那个 URL 永远打不开，但插件"成功返回了候选"。
  ///   宿主若照单全收，用户看到的是「Failed to open <代理地址>」——
  ///   而真实原因是**插件给错了**。这正是 Owner 第 6 条抱怨的分不清。
  /// ```
  ///
  /// # 判据（全部是"形态"层面的，不联网 —— 联网校验会把播放入口拖慢）
  /// ```text
  /// ① 空串 / 只有空白                     ⇒ 不可用
  /// ② 不是 http(s) 绝对地址                ⇒ 不可用
  ///    （blob:/file:/data: 都不是播放器能直接取的东西）
  /// ③ host 为空（如 "https://"）           ⇒ 不可用
  /// ④ 同一路径里出现两段 .m3u8 / .mp4      ⇒ 不可用
  ///    实测形态：…/play/dBBBRBxd/index.m3u8 里路径本已带 play 页标记，
  ///    再拼 .m3u8 是插件**凭猜**补的，几乎必然 404
  /// ⑤ 明显是播放页（路径含页面段且无媒体扩展）⇒ **不再在这里判死**（N1），
  ///    交 [verdictOf] 分三态处置（默认留+标「需解析」）；
  ///    仅证红开关（[debugShortCircuitPageKeep]）置真时退回本函数的原判。
  /// ```
  ///
  /// ⚠️ **宁可漏放，不可错杀**：判据只覆盖"显然不可用"的形态。
  ///    拿不准的一律放行 —— 错杀一条本来能播的线路，代价比漏放一条大得多。
  /// ⚠️ 返回 null = 这条可以用；返回非空 = **为什么不能用**（一句话，进日志）。
  static String? _whyUnusable(String url) {
    final u = url.trim();
    if (u.isEmpty) return '地址是空的';

    final Uri parsed;
    try {
      parsed = Uri.parse(u);
    } catch (_) {
      return '地址解析不了';
    }
    if (parsed.scheme != 'http' && parsed.scheme != 'https') {
      return '不是 http(s) 地址（scheme=${parsed.scheme}）';
    }
    if (parsed.host.isEmpty) return '地址里没有主机名';

    /*
     * ④ 猜着拼出来的媒体后缀 —— 实测形态
     *
     * `…/play/dBBBRBxd/index.m3u8`：路径里已经有一个像是"页面"的段
     * （/play/ + 一个 8 位 id），后面又被拼上 `index.m3u8`。
     * 判据：路径里出现 `/play/` 或 `/video/` 这类**页面段**，
     *      同时结尾又是媒体扩展 ⇒ 几乎必然是插件拼的（页面不会正好以 .m3u8 结尾）。
     */
    final path = parsed.path.toLowerCase();

    /*
     * ★★★ 判据 ④ 只在「拼出来的痕迹」很明显时才拦
     *
     * 实测的坏形态：`…/play/dBBBRBxd/index.m3u8`
     *   —— `/play/` 之后只剩**一个短 id 段**，然后就被接上了 `index.m3u8`。
     *
     * 而正常站点的形态：`…/video/abc/def.mp4`
     *   —— 路径里有 `/video/` 但后面是**正常目录层级**，这种必须放行。
     *
     * ⇒ 加一条「短 id 段紧贴 index.*」的特征：
     *    `/play/<8~16 位无扩展名>/(index|playlist|main).(m3u8|mp4)`
     *    只有这种"页面 id + 猜的入口文件名"才拦。
     *    ★ 本仓门禁（`zz_r65_stream_validation_test.dart` ② 组 ③）就是
     *      在测这个 —— 它先红过一次（我把 `/video/abc/def.mp4` 误杀了）。
     */
    final guessedSuffix = RegExp(
      r'/(play|video|vodplay)/[a-z0-9]{3,20}/(index|playlist|main)\.'
      r'(m3u8?|mp4|flv|mpd)$',
    ).hasMatch(path);
    if (guessedSuffix) {
      return '看起来是播放页地址又拼了媒体后缀：$path';
    }

    /*
     * ⑤ 页面形态（改前判据：路径有页面段，且完全没有媒体扩展）
     *
     * N1：不再在这里判死 —— 命中集抽成 [_pageShapePathOf]，
     *     由 [verdictOf] 分三态处置（默认留+标「需解析」）。
     *     仅 [debugShortCircuitPageKeep] 置真（证红）时，保留改前的摘除原句。
     */
    final pagePath = _pageShapePathOf(u);
    if (pagePath != null && debugShortCircuitPageKeep) {
      return '看起来是播放页而不是媒体地址：$pagePath';
    }

    return null;
  }

  /// 页面形态判据（纯函数）：路径有页面段（/play/ /video/ /vodplay/ /index.php/）
  /// 且**完全没有**媒体扩展 —— 即改前判据 ⑤ 的命中集
  ///
  /// ```text
  /// ⚠️ 只在没有媒体扩展时算页面 —— 有扩展就当作可信（宁可漏放，不可错杀）。
  /// 返回非空 = 命中（值是去参后的小写 path，供摘除理由/日志复用）；null = 不是页面形态。
  /// ```
  static String? _pageShapePathOf(String url) {
    final u = url.trim();
    if (u.isEmpty) return null;
    final Uri parsed;
    try {
      parsed = Uri.parse(u);
    } catch (_) {
      return null;
    }
    if ((parsed.scheme != 'http' && parsed.scheme != 'https') ||
        parsed.host.isEmpty) {
      return null;
    }
    final path = parsed.path.toLowerCase();
    final hasMediaExt = path.endsWith('.m3u8') ||
        path.endsWith('.m3u') ||
        path.endsWith('.mp4') ||
        path.endsWith('.flv') ||
        path.endsWith('.mpd') ||
        path.contains('.m3u8?') ||
        path.contains('.mp4?') ||
        path.contains('.mpd?');
    final looksLikePage = path.contains('/play/') ||
        path.contains('/video/') ||
        path.contains('/vodplay/') ||
        path.contains('/index.php/');
    return (looksLikePage && !hasMediaExt) ? path : null;
  }

  /// 三态判据（**纯函数**，门禁直测的入口；N1，lead 批复的判据表）
  ///
  /// ```text
  /// S1 空 / 非 http(s) / 无 host                  ⇒ drop（无任何后续路径）
  /// S2 猜拼媒体后缀（…/play/<id>/index.m3u8 等）    ⇒ drop（既有 r65 门禁，本批不动）
  /// S3 页面段且无媒体扩展（改前判据 ⑤）             ⇒ keepMarked（留+标「需解析」）
  ///    —— 依据见文件头 N1：起播预检真实可达，页面内嵌 vid 可刮出换直链
  ///       （appget gsuus 实证 200 + 合法 #EXTM3U）。
  /// S4 直链 / HLS（媒体扩展，含带 query）           ⇒ passthrough（逐字不变）
  /// S5 needsHostResolve=true                      ⇒ 编排层不变（t33 契约）
  /// ```
  ///
  /// # 为什么留/摘按**形态**判，不按 Rust 的 label 声明
  /// ```text
  /// appget 自家页（/play/<id>）在 Rust 侧 needs_parse **根本不声明**
  /// （needs_parse 只认 PAGE_HOSTS + .html 结尾）⇒ 只认声明会漏掉主修目标。
  /// ```
  ///
  /// [debugShortCircuitPageKeep] = true ⇒ S3 退回 drop（改前行为，证红注入点）。
  @visibleForTesting
  static PrepareVerdict verdictOf(String url) {
    // S2（猜拼后缀）与 S3（页面形态）互斥：前者带媒体扩展、后者没有
    // ⇒ 先查谁都不会改变结果；这里先查页面形态，让证红开关只管 S3 一档。
    if (_pageShapePathOf(url) != null) {
      return debugShortCircuitPageKeep
          ? PrepareVerdict.drop
          : PrepareVerdict.keepMarked;
    }
    return _whyUnusable(url) == null
        ? PrepareVerdict.passthrough
        : PrepareVerdict.drop;
  }

  /// 摘除理由（仅 [PrepareVerdict.drop] 的候选调用）
  ///
  /// S1/S2 来自 [_whyUnusable]；证红模式下的页面形态用**改前原句**
  /// （保证退回旧行为时日志/留痕逐字一致）。
  static String _dropReasonOf(String url) {
    final why = _whyUnusable(url);
    if (why != null) return why;
    final pagePath = _pageShapePathOf(url);
    if (pagePath != null) return '看起来是播放页而不是媒体地址：$pagePath';
    // 不可达：verdict==drop 必有理由（S1/S2 或证红下的页面形态）。
    // 兜底串不许编造形态 —— 如实说"没给出"。
    return '（未给出）';
  }

  /// 给页面形态候选追加「（需解析）」标注（返回原实例或 copyWith 的新实例）
  ///
  /// # 为什么**不走** needsHostResolve=true
  /// ```text
  /// 那会让 isPlayable=false ⇒ 候选被筛掉 ⇒ 列表又空了 —— 等于白改。
  /// 标注只进 label（用户在抽屉/标题里看得到），可用性判断不碰。
  /// ```
  ///
  /// # 防重复加
  /// Rust 侧 `label_with_parse_hint` 已给声明过的候选标了「（需 parse）」；
  /// label 里已有「需 parse」或「需解析」的不再追加。
  ///
  /// # 已核实（lead 补充 1）：追加串不会触发任何按 label 判事的逻辑
  /// ```text
  /// 全仓 label 内容消费点三处 ——
  /// · live_availability.dart:97 isAudioOnlyLine：只认 音频/广播/audio
  /// · player_page.dart:24358 qualityBadgeFor：只认 label 是否含 quality
  /// · player_page.dart:525 lineDurationKey：label 作缓存键（S3 候选改前
  ///   根本不存在 ⇒ 无旧键回归）
  /// 「（需解析）」不含以上任何关键字；门禁里有对应断言钉着。
  /// ```
  static StreamCandidate _withResolveMark(StreamCandidate c) {
    final lab = c.label ?? '';
    if (lab.contains('需 parse') || lab.contains('需解析')) return c;
    final marked = lab.isEmpty ? '需解析' : '$lab（需解析）';
    return c.copyWith(label: marked);
  }

  /// 预处理一批候选
  ///
  /// 对每条 [StreamCandidate.needsHostResolve] 的候选：
  /// ```text
  /// ① 有解析器 ⇒ 调它拿真实地址
  ///    成功 → url 换成真实地址、needsHostResolve 置 false
  ///    失败 → 标 drmProtected（= 不可播），让 UI 走「不可播」如实提示
  /// ② 没解析器 ⇒ 同样标为不可播
  /// ```
  ///
  /// ⚠️ 失败时**不抛异常**：一条线路解不出来不该让整个播放页报错。
  ///    但也不静默 —— 该候选会被 [StreamCandidate.isPlayable] 拦下，
  ///    UI 因此会显示「所有线路都不可播（可能受 DRM 保护）」而不是播成黑屏。
  static Future<List<StreamCandidate>> prepare(
    List<StreamCandidate> list,
  ) async {
    final needIdx = <int>[];
    for (var i = 0; i < list.length; i++) {
      if (list[i].needsHostResolve) needIdx.add(i);
    }
    lastNeedsResolveCount = needIdx.length;

    /*
     * ★★★ 第 65 轮第 8 条 D 类：插件给的地址**本身**不可用 ⇒ 在这里摘掉
     *（N1 起按 [verdictOf] 三态处置：摘 / 留+标「需解析」/ 直通）
     *
     * # 为什么必须摘（对 drop 档），而不是原样交给播放器
     * ```text
     * 摘掉 ⇒ 该候选 isPlayable=false ⇒ 与"所有线路都不可播"同一条路，
     *        用户看到「这个源没有返回可播放地址」—— 说的是实话
     * 不摘 ⇒ 播放器去打那个坏地址 ⇒ 用户看到「Failed to open <代理地址>」
     *        而真实原因是插件给错了 ⇒ 又是分不清源/软件（Owner 第 6 条）
     * ```
     *
     * # 为什么放在 prepare 里（而不是新开一个函数）
     * ```text
     * prepare 已经被 resolveStream / getLiveStream **两个出口**调用
     * ⇒ 挂在这里，点播与直播两条独立路径同时受保护。
     * 新开一个函数就必须有人记得去两处调用（本仓"written ≠ wired"的坑）。
     * ```
     *
     * ⚠️ 只摘**显然不可用**的（[PrepareVerdict.drop]）；页面形态保留并标注；
     *    拿不准的原样放行。
     * ⚠️ needIdx 为空时也要跑这一步 —— 坏地址跟 needsHostResolve 无关。
     * ⚠⚠ 但**零摘且零标时保持返回原实例** —— 既有门禁
     *    （`zz_t33_stream_prepare_test.dart` 的「原样返回（零副作用）」）
     *    钉的就是这个契约：没要改的东西，调用方拿到的必须是同一个 List。
     *    复制一份虽然内容相同，但会让 `identical()` 判据失效，
     *    也会让下游误以为"这一批被改过"。
     */
    final dropped = <String>[];
    final kept = <StreamCandidate>[];
    var keptNeedsResolve = 0;
    for (final c in list) {
      final v = verdictOf(c.url);
      if (v == PrepareVerdict.drop) {
        dropped.add(
          '${(c.label ?? '').isEmpty ? (c.quality ?? '-') : c.label}: '
          '${_dropReasonOf(c.url)}',
        );
      } else if (v == PrepareVerdict.keepMarked) {
        kept.add(_withResolveMark(c));
        keptNeedsResolve++;
      } else {
        kept.add(c);
      }
    }
    lastDroppedCount = dropped.length;
    lastDroppedReasons = List<String>.unmodifiable(dropped);
    lastKeptNeedsResolveCount = keptNeedsResolve;

    /*
     * ★ 零摘且零标 ⇒ **返回原实例**（既有契约，见上面的说明）
     *
     * 这一步必须在算 needIdx2 之前做：零摘零标就说明 kept 与 list 逐项相同，
     * 直接把 list 交回去最安全（identical 判据保住、下游也不会误判"改过"）。
     */
    final working = (dropped.isEmpty && keptNeedsResolve == 0) ? list : kept;
    final needIdx2 = <int>[];
    for (var i = 0; i < working.length; i++) {
      if (working[i].needsHostResolve) needIdx2.add(i);
    }
    lastNeedsResolveCount = needIdx2.length;
    if (needIdx2.isEmpty) return working;

    final out = List<StreamCandidate>.of(working);
    final r = resolver;

    for (final i in needIdx2) {
      final c = working[i];
      if (r == null) {
        /*
         * 没有解析器 —— 这是**当前的真实状态**（路线未选型）。
         *
         * 为什么不直接 throw：一条线路解不出来不代表整个作品不可播，
         * 同一作品可能有别的线路（标 needsHostResolve=false 的传统线路）。
         * 所以只把这一条标成不可播，让 isPlayable 把它筛掉。
         */
        // 保留 needsHostResolve=true ⇒ isPlayable 自然为 false。
        // ⚠⚠ 不标 drmProtected：那会让 UI 对用户说「受版权保护」，
        //    而真实原因是「宿主还没实现解析能力」。两件事不许冒充。
        out[i] = c;
        continue;
      }

      try {
        final resolved = await r(c.url, siteId: c.siteId);
        if (resolved == null || resolved.isEmpty) {
          // 解不出来 ⇒ 保持 needsHostResolve=true（仍不可播）
          out[i] = c;
          continue;
        }
        out[i] = c.copyWith(url: resolved, needsHostResolve: false);
      } catch (_) {
        /*
         * 解析器抛异常 ⇒ 同样只废掉这一条。
         * ⚠⚠ 不标 drmProtected（同上，不许冒充）。
         *    这条候选保持 needsHostResolve=true ⇒ isPlayable 为 false，
         *    UI 会走「所有线路都不可播」而不是黑屏。
         */
        out[i] = c;
      }
    }
    return out;
  }

  /// 仅供测试：重置全局状态
  static void debugReset() {
    resolver = null;
    lastNeedsResolveCount = 0;
    lastDroppedCount = 0;
    lastDroppedReasons = const <String>[];
    lastKeptNeedsResolveCount = 0;
  }
}
