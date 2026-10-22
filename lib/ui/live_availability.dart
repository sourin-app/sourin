// ═══════════════════════════════════════════════════════════════════════
//  直播频道可用性判定（task-39 新增）
// ═══════════════════════════════════════════════════════════════════════
//
// 用户原话：
// > 不可用的某电视台站直播就不要显示出来了
//
// # ★★★ 为什么必须在**取流阶段**判定（而不是列表阶段）
//
// 实测（`.probe/t39_recon_full.py`，真核心 FFI）：
// ```text
// get_live_channels 返回的字段 = ['group', 'id', 'logo', 'name']
//   ⇒ ★ 没有任何可用性 / DRM 字段
// ```
// 而 `drm_protected` 是 `get_live_stream` 才返回的
// （`srcl.js:341` 硬编码在 `liveUrls()` 里）——
// **列表阶段拿不到**。
//
// ⇒ 所以"不显示不可用"只能：
// ```text
// ① 取流阶段探测（本文件）—— 真实，但要多一轮请求
// ② 或硬编码"srcl 全不可用"  —— ★ 危险（见下）
// ```
//
// # ★★★ 为什么**不**硬编码"srcl 全不可用"
//
// ```text
// 我实测过：20/20 个 srcl 频道的**视频线全部 drm_protected: true**
//   ⇒ 很容易得出"srcl 天生如此，直接过滤掉"
// ★ 但那是**此刻的快照**：
//   · 某电视台 CDN 地址会过期/更换（实测过 404 / 504 / SSL EOF 三种）
//   · 哪天内容方取消加密，硬编码的过滤会让用户**永远看不到**
//     ⇒ 这是**永久性假阴性**，比"多显示几个台"危险得多
// ⇒ 所以判定必须**动态探测**，且结果**带 TTL 缓存**（别每次进页面都探）。
// ```
//
// # ★ 探测失败 ≠ 不可用（铁律 51 的同一教训）
//
// ```text
// 网络抖动 / 源临时挂了 ⇒ 探测拿不到结果
// ⇒ ★ 必须当成"未知"并**照常显示**，绝不能因为"探不到"就隐藏
//   （否则用户的频道列表会随网络状况**随机变少**，那比不隐藏更糟）
// ```
//
// # 与 `player_page.dart:1544-1550` 的关系
//
// 那里也判过"只剩音频可播"（`hasDrmVideo && onlyAudioPlayable`）。
// ★ 但那是**播放时**的提示（已经点进去了）；本文件是**列表阶段**的分类，
//   目的是决定"要不要显示"。两者结论要一致，所以判据刻意写成同一套：
//   都是「可播线路里有没有带视频的」。

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core/disk_cache.dart';
import '../core/sourin_api.dart';

/// 一个频道的可用性
enum LiveAvailability {
  /// 有带视频的可播线路 —— 正常显示
  playable,

  /// ★ 只有音频线可播（srcl 的实际情况）——
  ///   默认隐藏但**可展开**（用户可能就想听广播）
  audioOnly,

  /// 一条可播线路都没有 —— 显示也没意义
  unavailable,

  /// 还没探测 / 探测失败
  ///
  /// ★★ 这一档**必须存在**，且 UI 必须把它当"显示"处理 ——
  ///    否则"探不到"会被当成"不可用"（假阴性，见文件头）。
  unknown,
}

/// 判定一条线路是不是"只有声音"（没有视频轨）
///
/// # 判据来源
/// `srcl.js` 给音频线的 `quality` 是 `'仅音频'`、`label` 是 `'广播'`
/// （实测 `get_live_stream(srcl, srcl1)` 的第三条）。
///
/// ⚠️ 这是**插件约定**不是协议字段 —— 所以判据写成"包含关键字"而不是等值，
///    将来插件换个说法（`'音频'` / `'伴音'`）也还能命中。
///    命中不了时的后果是**当成视频线**（保守：倾向显示）。
///
/// ★★★ 必须**大小写不敏感**（被单测抓出来的真 bug）
/// ```text
/// 我第一版写 `t.contains('audio')` ⇒ 'Audio' / 'AUDIO' 都命中不了
/// ⇒ 那条线路被当成**视频线** ⇒ 若它是唯一可播的，
///   分类会从 audioOnly 变成 playable ⇒ 列表里显示出来，
///   用户点进去看到黑屏（音频流没有画面）—— 正是要修的那个症状。
/// ★ 用 `toLowerCase()` 统一后再比。
/// ```
bool isAudioOnlyLine(StreamCandidate s) {
  final t = '${s.quality ?? ''}${s.label ?? ''}'.toLowerCase();
  return t.contains('音频') || t.contains('广播') || t.contains('audio');
}

/// 把一次 `getLiveStream` 的结果分类
LiveAvailability classifyStreams(List<StreamCandidate> list) {
  final playable = list.where((s) => s.isPlayable).toList();
  if (playable.isEmpty) return LiveAvailability.unavailable;
  final withVideo = playable.where((s) => !isAudioOnlyLine(s)).toList();
  if (withVideo.isEmpty) return LiveAvailability.audioOnly;
  return LiveAvailability.playable;
}

/// 是否应该**默认显示**这个频道
///
/// ```text
/// playable    → 显示
/// audioOnly   → ★ 默认隐藏（用户要求"不可用的不要显示"），但可展开
/// unavailable → 隐藏
/// unknown     → ★ 显示（探不到不等于不可用）
/// ```
bool shouldShowByDefault(LiveAvailability a) =>
    a == LiveAvailability.playable || a == LiveAvailability.unknown;

// ═══════════════════════════════════════════════════════════════════════
//  播放结果驱动的可用性（N15）
// ═══════════════════════════════════════════════════════════════════════
//
// 用户原话：
// > 然后还有这个直播频道的可用性应该缓存,而不是每次都实时刷新,
// > 然后定时刷新+打开如果不能播放,动态标记 定时再刷新掉状态
// > + 有些直播不是一直播放的,这个也要注意
//
// # ★★★ 为什么这一层必须**独立于**上面的 LiveAvailabilityProbe
//
// ```text
// 上面那层的判据是 StreamCandidate.isPlayable：
//     !drmProtected && !needsHostResolve && url.isNotEmpty     (models.dart:1003)
// ★ 纯元数据判定，**不发任何网络请求**。
// ⇒ 它只能回答"这个源有没有给出一个可播地址"，
//   **不能**回答"这个地址现在能不能出画面"。
//
// ⇒ 所以「可用 / 未检测到画面 / 不可用」三态**只能**由**播放结果**驱动。
//   探测路径帮不上忙 —— 这是实测逼出来的架构结论，不是设计偏好。
// ```
//
// # ★★★ 「暂时没开播」在产品侧**零信号**（N15 实测，决定整套判据）
//
// ```text
// 实测五类源（工程自带 libmpv-2.dll，本地 HTTP + Range）：
//   ① 正常 HLS        ⇒ 出画面，无 stream.error
//   ② 404 地址失效    ⇒ [stream] Failed to open <m3u8>。
//   ③ 端口无监听      ⇒ [ffmpeg] tcp: Connection ... failed + 同②
//   ④ 空播放列表(没开播) ⇒ ★ **一条错误都没有**
//   ⑤ 分片全 404      ⇒ [stream] Failed to open <分片.ts>。
//
// ④ 为什么没有信号（查实，非推测）：
//   mpv 只发 prefix='cplayer' level='fatal'
//   'No video or audio streams selected.'
//   而 media_kit real.dart:2075 **只转发 level == 'error'**
//   ⇒ 这条被**丢弃** ⇒ 产品侧拿不到任何信号。
//
// ⇒ 判据只能是「**有没有收到错误串**」，**不是**「错误串长什么样」：
//   错误串的可辨识度不足以区分"源坏了"的细分类型（②③⑤ 文本几乎一样）。
// ```
//
// # 为什么 idle 的文案不能说死「未开播」
//
// ```text
// idle 的真实含义是「我们等够了，但没等到画面」——
// 它**可能**是频道没开播，**也可能**是我们超时设得太短 / 网络慢。
// ⇒ 把一个推断说成事实，与本仓「不支持就说不支持」是同一条纪律：
//   **不知道就说不知道，不要冒充确定。**
// ```
//
// # 为什么 idle 与 broken 必须分开
//
// ```text
// 「不可用」      ⇒ 这个源坏了，别试了
// 「未检测到画面」⇒ 可能它现在没播，过会儿再看看
// ⇒ 混成一个「不可用」，用户会**放弃一个其实只是暂时没播的源**。
// ```

/// 一次播放尝试的结论（由播放路径回写，**不是**探测出来的）
enum LivePlaybackHealth {
  /// 从未尝试过 / 状态已过期 —— 不标记，正常显示
  unknown,

  /// 出过画面 —— 正常
  playable,

  /// 等够时间仍没画面，但**没有**收到任何错误串
  ///
  /// ★ 这不是"确认没开播"，只是"我们没等到画面"。
  ///   文案必须体现不确定性（见文件头）。
  idle,

  /// 收到了错误串 —— 这个地址当前打不开
  broken,
}

/// 一条频道健康记录的完整内容
class LivePlaybackHealthEntry {
  const LivePlaybackHealthEntry({
    required this.health,
    required this.at,
    this.detail,
  });

  final LivePlaybackHealth health;

  /// 记录时间 —— 定时刷新据此判断"要不要重试"
  final DateTime at;

  /// 原始错误串（**原样保存，不加工**）
  ///
  /// ★ 保存原文而不是分类后的枚举：因为实测证明错误串的可辨识度
  ///   不足以可靠分类（见文件头），过早归一化会把证据丢掉。
  ///   将来若要细分，靠的是这些原文。
  final String? detail;

  /// 该不该让后台定时刷新去重试它
  ///
  /// ★ 只重试 idle 与 broken：`playable` 没必要花流量，
  ///   `unknown` 本来就没试过。
  bool get retryable =>
      health == LivePlaybackHealth.idle || health == LivePlaybackHealth.broken;

  @override
  String toString() =>
      'LivePlaybackHealthEntry(${health.name}, $at, ${detail ?? '-'})';
}

/// 可用性缓存的**唯一**键格式：`provider \u0000 channelId`
///
/// # ★★★ 为什么必须是单点定义（这是一个被门禁抓出来的真 bug）
///
/// ```text
/// 我写持久化时，`LiveHealthCache` 用 `'$provider|$channelId'`（管道符），
/// 而 `LivePlaybackHealthStore._key()` 用的是 `'$provider\u0000$channelId'`（NUL）。
/// ⇒ 落盘时按管道符写，读回时 store 按 NUL 查 ⇒ **一条都对不上**。
///
/// 症状会极其难查：
///   缓存文件确实生成了、内容看起来也对，
///   但重启后**一个徽标都没有**，且日志里没有任何报错
///   （因为两边各自都"工作正常"，只是永远不命中）。
/// ```
///
/// ⇒ 定死在这里，两边都调它。**不许任何地方再手写拼接**。
///
/// ⚠️ 用 `\u0000` 而不是 `|`：provider / channelId 由核心层保证非空，
///   但不保证不含 `|`（频道 id 里出现竖线并非不可能）；
///   NUL 是 JSON 与文件路径都不会出现的字符 ⇒ 拼接后可唯一还原。
String liveHealthCacheKey(String provider, String channelId) =>
    '$provider\u0000$channelId';

/// 把键还原成 (provider, channelId)
///
/// ★ 与 [liveHealthCacheKey] 严格互逆；格式不对返回 null（**不猜**）。
(String, String)? liveHealthCacheKeyParts(String key) {
  final i = key.indexOf('\u0000');
  if (i <= 0 || i >= key.length - 1) return null;
  return (key.substring(0, i), key.substring(i + 1));
}

/// 播放结果状态机 + 缓存（N15 ③④⑤）
///
/// # 判据（Lead 已批）
/// ```text
/// 收到错误串                     ⇒ broken          （**优先于超时**）
/// 出过画面                       ⇒ playable
/// 等满 [bootTimeout] 无画面且无错误 ⇒ idle
/// ```
///
/// ★ **错误串优先于超时**：3 秒收到错误串就立刻判 broken，
///   不必空等 12 秒 —— 用户已经看到了明确的失败原因。
///
/// # 12 秒这个值的依据
/// ```text
/// 实测正常 HLS 首帧 < 2s；个别慢源到 8s
/// ⇒ 12s 留 50% 余量。
/// ⚠️ 这个值偏保守（宁可慢判也不误判）：误判成 idle 只是显示灰点，
///    误判成 broken 会让用户彻底放弃一个能播的源 —— 两者代价不对等。
/// ```
class LivePlaybackHealthStore {
  LivePlaybackHealthStore({
    this.bootTimeout = const Duration(seconds: 12),
    this.retryAfter = const Duration(minutes: 10),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// 起播多久没画面就判 idle（见类注释的取值依据）
  final Duration bootTimeout;

  /// 多久之后才允许重试（与探测 TTL 保持一致）
  final Duration retryAfter;

  final DateTime Function() _now;

  final Map<String, LivePlaybackHealthEntry> _entries = {};

  String _key(String provider, String channelId) =>
      liveHealthCacheKey(provider, channelId);

  /// 读状态（**不做过期判断** —— 过期与否由 [needsRetry] 决定）
  ///
  /// ★ 为什么不在这里自动清过期：
  ///   过期只意味着"该重试了"，**不**意味着"状态消失了"。
  ///   若过期即返回 unknown，UI 上的灰/红点会自己闪掉，
  ///   用户会看到状态莫名消失 —— 那比一直显示还糟。
  LivePlaybackHealthEntry? entryOf(String provider, String channelId) =>
      _entries[_key(provider, channelId)];

  /// 便捷读：只要枚举
  LivePlaybackHealth healthOf(String provider, String channelId) =>
      _entries[_key(provider, channelId)]?.health ?? LivePlaybackHealth.unknown;

  /// 当前时刻（**与 [record] 写 `at` 用的是同一个时钟**）
  ///
  /// ★ 外部要判断"这条还新不新鲜"时必须读这里，不能自己调 `DateTime.now()`：
  ///   测试注入了 `now` 之后，若比较用真实时钟、写 `at` 用注入时钟，
  ///   两者会差出一整个测试的时间跨度 —— 那种门禁看起来在跑，读数却无意义。
  DateTime get now => _now();

  /// 这个频道**现在**该不该被后台重试
  ///
  /// 条件：状态可重试（idle/broken）**且**已过 [retryAfter]。
  bool needsRetry(String provider, String channelId) {
    final e = _entries[_key(provider, channelId)];
    if (e == null || !e.retryable) return false;
    return _now().difference(e.at) >= retryAfter;
  }

  /// 所有需要重试的频道（给定时刷新用）
  List<(String, String)> pendingRetries() {
    final out = <(String, String)>[];
    for (final k in _entries.keys) {
      final parts = k.split('\u0000');
      if (parts.length != 2) continue;
      if (needsRetry(parts[0], parts[1])) out.add((parts[0], parts[1]));
    }
    return out;
  }

  /// ★★ 回写一次播放结果（**这是 ③ 动态标记的唯一入口**）
  ///
  /// # 为什么必须在这里做"错误串优先"
  /// ```text
  /// 播放页会先后收到两个信号：
  ///   · stream.error（可能 3 秒就来）
  ///   · 我们自己的 12 秒超时
  /// 若两者都写，先到的 broken 会被后到的 idle 覆盖 ⇒ 丢失真实原因。
  /// ⇒ 本方法对同一频道做**优先级保护**：已有 broken 时，
  ///   idle 不得覆盖它（直到定时重试真的成功为止）。
  /// ```
  void record({
    required String provider,
    required String channelId,
    required LivePlaybackHealth health,
    String? detail,
  }) {
    final k = _key(provider, channelId);
    final prev = _entries[k];

    /*
     * ★ 优先级规则（三条，全部来自实测/用户要求）
     *
     * ① broken 一旦成立，**idle 不得覆盖**它
     *    （否则"我看到明确报错"会被"等超时了"抹掉）
     * ② playable 永远可以覆盖任何状态
     *    （真的出画面了就是最硬的证据）
     * ③ unknown 不主动写入
     *    （没试过 = 没有信息，不该制造记录）
     */
    if (health == LivePlaybackHealth.unknown) return;
    if (prev != null &&
        prev.health == LivePlaybackHealth.broken &&
        health == LivePlaybackHealth.idle) {
      return; // ①
    }

    _entries[k] = LivePlaybackHealthEntry(
      health: health,
      at: _now(),
      detail: detail,
    );
  }

  /// 定时刷新成功后**清掉**标记（用户原话「定时再刷新掉状态」）
  ///
  /// ★ 清掉 = 移除记录 ⇒ 回到 unknown ⇒ UI 不再显示灰/红点。
  ///   不写成 `playable`：因为"这次重试没报错"不等于"确认能播"
  ///   （可能只是又超时了一次的另一种表现）。
  void clear(String provider, String channelId) {
    _entries.remove(_key(provider, channelId));
  }

  /// 记录数（给测试/诊断用）
  int get length => _entries.length;

  /// 清空（测试用）
  void debugReset() => _entries.clear();

  /// 全部条目（序列化用）
  ///
  /// ★ 返回的是 `provider|channelId → entry` 的**新** Map，
  ///   调用方改它不会影响本 store。
  Map<String, LivePlaybackHealthEntry> snapshot() => Map.of(_entries);

  /// 从磁盘内容**批量灌入**（启动读盘用）
  ///
  /// # 与 [record] 的区别（不能复用 [record]）
  /// ```text
  /// `record()` 会做优先级保护 + 把 `at` 设成**现在**。
  /// 但读盘时我们要**原样恢复**：时间必须是磁盘上那个（否则
  /// "已过期"的信息就丢了，等于把旧状态洗成新的）。
  /// ⇒ 单独开一个灌入口，语义是"我还原现场"，不是"我观测到了"。
  /// ```
  void restore(Map<String, LivePlaybackHealthEntry> entries) {
    _entries
      ..clear()
      ..addAll(entries);
  }

  /// 从「有没有错误串 + 有没有出过画面 + 等了多久」推导状态
  ///
  /// ★ 这是整个判据的**唯一实现**，UI 与测试都走它 ——
  ///   避免两处各写一套导致"显示的和判定不一致"。
  static LivePlaybackHealth derive({
    required bool sawFrame,
    required String? errorText,
    required bool timedOut,
  }) {
    if (errorText != null && errorText.trim().isNotEmpty) {
      return LivePlaybackHealth.broken; // ★ 错误串优先，不等超时
    }
    if (sawFrame) return LivePlaybackHealth.playable;
    if (timedOut) return LivePlaybackHealth.idle;
    return LivePlaybackHealth.unknown;
  }
}

/// 徽标文案（**空字符串 = 不显示徽标**）
///
/// # 为什么 idle 的文案是「未检测到画面」而不是「未开播」
///
/// ```text
/// idle 的真实含义是「我们等够了 [LivePlaybackHealthStore.bootTimeout]，
/// 但没等到画面」——它**可能**是频道没开播，
/// **也可能**是我们超时太短 / 用户网络慢 / 上游卡了一下。
///
/// ⇒ 把一个推断说成事实，与本仓「不支持就说不支持」是同一条纪律：
///   **不知道就说不知道，不要冒充确定。**
///
/// ⇒ 用「可能」把不确定性留在界面上，用户才不会因为一次误判
///   永久放弃一个其实能播的源。
/// ```
///
/// # 为什么 broken 与 idle 必须是两句不同的话
/// ```text
/// 「不可用」      ⇒ 这个源坏了，别试了
/// 「未检测到画面」⇒ 可能它现在没播，过会儿再看看
/// ⇒ 混成一句，用户会**放弃一个只是暂时没播的源**。
/// ```
String liveHealthLabel(LivePlaybackHealth h) => switch (h) {
      LivePlaybackHealth.playable => '',
      LivePlaybackHealth.unknown => '',
      LivePlaybackHealth.idle => '未检测到画面（可能未开播）',
      LivePlaybackHealth.broken => '不可用',
    };

/// 可用性探测 + 缓存
///
/// # 为什么要缓存
/// ```text
/// 实测单个 get_live_stream 延迟 22~105ms（中位 24ms）
/// 用户目录里 srcl 20 + iptv 28 = 48 个频道
///   ⇒ 串行 ≈ 1.2s，8 路并发 ≈ 0.2s
/// ★ 进一次直播页探一遍可以接受，但**每次 setState 都探**就不行 ——
///   所以按 (provider, channelId) 缓存，TTL 10 分钟。
/// ```
class LiveAvailabilityProbe {
  LiveAvailabilityProbe({
    this.ttl = const Duration(minutes: 10),
    this.concurrency = 8,
    Future<List<StreamCandidate>> Function(String provider, String channelId)?
        fetch,
    DateTime Function()? now,
  })  : _fetch = fetch ?? SourinApi.getLiveStream,
        _now = now ?? DateTime.now;

  final Duration ttl;

  /// 时钟（默认 [DateTime.now]）
  ///
  /// ★ 与 [LivePlaybackHealthStore.now] 同款理由：`seed()` 灌进来的是
  ///   **磁盘上的观测时刻**，`cached()` 却拿"现在"去比。
  ///   若一边能被注入、另一边只能读真实时钟，两者的时间跨度对不上 ——
  ///   门禁里就会看到"明明灌了新鲜数据，`probe()` 却仍全量重发"这种
  ///   看起来像产品缺陷、其实是两个世界对不上的读数。
  /// ★ 不注入时行为与之前逐字一致（默认就是 `DateTime.now`）。
  final DateTime Function() _now;

  /// 并发上限 —— 别把核心/网络打爆（实测 8 路时中位仍 ~24ms）
  final int concurrency;

  final Future<List<StreamCandidate>> Function(String, String) _fetch;

  final Map<String, LiveAvailability> _result = {};
  final Map<String, DateTime> _at = {};

  String _key(String provider, String channelId) => '$provider\u0000$channelId';

  /// 取缓存（过期返回 null）
  LiveAvailability? cached(String provider, String channelId) {
    final k = _key(provider, channelId);
    final t = _at[k];
    if (t == null) return null;
    if (_now().difference(t) > ttl) return null;
    return _result[k];
  }

  /// ★★★ P0：从磁盘缓存**灌入**一条已知结果（不发起任何请求）
  ///
  /// # 为什么需要它（这是"跳过全量探测"能生效的关键）
  /// ```text
  /// `probe()` 的跳过判据是 `cached(...) != null`。
  /// 只把磁盘状态放进 `_health` 而不放进这里 ⇒
  /// `probe()` 仍会把所有频道算进 todo ⇒ 全量探测照旧发生。
  /// ⇒ 必须让 `_probe` 也"看起来已经探过"。
  /// ```
  ///
  /// ⚠️ 时间用**磁盘上的观测时刻**，不是 now —— 否则过期信息就丢了
  ///    （灌进来会变成"刚刚探过"，TTL 白给）。
  void seed(
    String provider,
    String channelId,
    LiveAvailability value,
    DateTime at,
  ) {
    final k = _key(provider, channelId);
    _result[k] = value;
    _at[k] = at;
  }

  /// 探测一批频道；返回**新探到**的数量
  ///
  /// ★ 已经有有效缓存的会跳过（除非 [force]）。
  Future<int> probe(
    List<LiveGroup> groups, {
    bool force = false,
    void Function()? onProgress,
  }) async {
    final todo = <(String, String)>[];
    for (final g in groups) {
      for (final c in g.channels) {
        if (!force && cached(g.provider, c.id) != null) continue;
        todo.add((g.provider, c.id));
      }
    }
    if (todo.isEmpty) return 0;

    var done = 0;
    // 手写并发池（不引依赖；`Future.wait` 会一次性打完）
    final queue = List.of(todo);
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final (provider, channelId) = queue.removeAt(0);
        LiveAvailability a;
        try {
          final list = await _fetch(provider, channelId);
          a = classifyStreams(list);
        } catch (e) {
          /*
           * ★★ 探测失败 ⇒ unknown（**不是** unavailable）
           *
           * 否则用户的频道列表会随网络状况随机变少。
           * ⚠️ 也不能只留 unknown 不记时间 —— 否则会被当成"已探测过"
           *    而永不重试。这里记时间，让 TTL 后再试。
           */
          debugPrint('[LIVE-PROBE] 探测失败 $provider/$channelId: $e');
          a = LiveAvailability.unknown;
        }
        _result[_key(provider, channelId)] = a;
        _at[_key(provider, channelId)] = DateTime.now();
        done++;
        onProgress?.call();
      }
    }

    final n = concurrency < 1 ? 1 : concurrency;
    await Future.wait(List.generate(n, (_) => worker()));
    return done;
  }

  /// 统计（给 UI 显示"已隐藏 N 个"）
  int countOf(Iterable<(String, String)> keys, LiveAvailability a) =>
      keys.where((k) => _result[_key(k.$1, k.$2)] == a).length;
}

// ═══════════════════════════════════════════════════════════════════════
//  可用性持久化（P0：Owner 说「迟早要被拉黑」）
// ═══════════════════════════════════════════════════════════════════════
//
// 用户原话：
// > 直播页现在每次都刷新全量的检测,这是错误的 一定要有缓存啊,
// > 不然这样子迟早要被拉黑
//
// # ★ 为什么"进程内存里的 TTL"救不了这件事（这是根因）
//
// ```text
// · `LiveAvailabilityProbe._result`  →  LivePage State 里的 Map
// · `SourinApi._liveStreamCache`     →  SourinApi 的静态 Map
// ★ 两者都是**进程内存** ⇒ 进程一退就全没了
// ⇒ 每次启动客户端 = 从零开始全量探测 1248 个频道
// ⇒ 这正是"每次启动都全量打网络"的真正病因。
//
// ⚠️ 而且**把 TTL 从 30 秒改成 10 分钟并不能解决它** ——
//    内存里的东西，TTL 多长进程一退都一样。
//    （那条改动还会带回"点重试没用"的老 bug，见 sourin_api 的 invalidateLiveStream）
// ```
//
// # ★ 为什么用 DiskCache 而不是自己写文件、也不是 UiPrefs
//
// ```text
// UiPrefs  是"用户偏好"：用户可改、可清、"恢复默认设置"会清空它
//          ⇒ 可用性是**运行时观测数据**，混进去会被误清
// DiskCache 已经处理了：数据目录未就绪 / 文件不存在 / 读失败 /
//          JSON 损坏 / 信封版本不符 —— **全部降级为 null，不抛**
//          ⇒ 正好满足"损坏的 JSON 不能让页面崩"
// ```
//
// # 磁盘形态
//
// ```json
// {
//   "v": 1,
//   "at": <DiskCache 自己的外层时间戳>,
//   "data": {
//     "<provider>|<channelId>": { "h": "broken", "t": 1750000000000, "d": "原文" }
//   }
// }
// ```
// ★ `h` 存**枚举名**而不是 bool —— 四态机里 `idle` 与 `broken` 意义完全不同，
//   压成 bool 会把"可能没开播"和"源坏了"混成一个。
// ★ 每条带**自己的** `t`（观测时刻），不共用外层 `at`：
//   不同频道是不同时刻观测的，共用会让"刚才探的"和"一小时前的"混为一谈。
// ★ `unknown` **不落盘**（没观测过就没有记录，与 `record()` 契约一致）。

/// 持久化文件名（放 <dataDir> 下）
const String kLiveHealthCacheName = 'live-availability.json';

/// 磁盘信封版本（格式改了要 +1，旧版本会被 DiskCache 判为不可用）
const int kLiveHealthCacheVersion = 1;

/// 一条可用性状态的**有效窗口**
///
/// 与 [LiveAvailabilityProbe.ttl] 的 10 分钟**刻意一致**：
/// 两套缓存用同一个节律，用户看到的"多久前的检查"语义不会打架。
const Duration kLiveHealthTtl = Duration(minutes: 10);

/// 可用性持久化读写（静态类，与 `DiskCache` / `UiPrefs` 同款用法）
///
/// # 为什么单独一个类而不是塞进 store
/// ```text
/// store 是**纯逻辑**（可单测、无 I/O）。
/// 一旦让它依赖 DiskCache，门禁就必须准备数据目录才能跑 —— 
/// 那会把"判据对不对"和"文件写没写成"耦在一起。
/// ⇒ 读/写各一次，纯函数式进出，store 永远不知道磁盘存在。
/// ```
class LiveHealthCache {
  const LiveHealthCache._();

  /// 序列化成可落盘的 JSON
  static Map<String, dynamic> encode(
    Map<String, LivePlaybackHealthEntry> entries,
  ) {
    final data = <String, dynamic>{};
    for (final e in entries.entries) {
      final v = e.value;
      // ★ unknown 不落盘 —— 它等价于"没有记录"
      if (v.health == LivePlaybackHealth.unknown) continue;
      data[e.key] = {
        'h': v.health.name,
        't': v.at.millisecondsSinceEpoch,
        if (v.detail != null && v.detail!.isNotEmpty) 'd': v.detail,
      };
    }
    return {
      'v': kLiveHealthCacheVersion,
      'data': data,
    };
  }

  /// 从落盘 JSON 还原（**任何异常都降级为空，绝不抛**）
  ///
  /// # 为什么会坏（必须容忍的三种真实情况）
  /// ```text
  /// ① 写到一半断电 ⇒ 文件是半截 JSON
  /// ② 手改/别的版本写过 ⇒ 字段缺失或类型不对
  /// ③ 枚举名变了（将来重命名 idle）⇒ `values.byName` 抛
  /// ⇒ 全部当"没有缓存"处理。宁可多探一轮，也不能让直播页打不开。
  /// ```
  static Map<String, LivePlaybackHealthEntry> decode(Object? raw) {
    final out = <String, LivePlaybackHealthEntry>{};
    try {
      if (raw is! Map) return out;
      if (raw['v'] != kLiveHealthCacheVersion) return out;
      final data = raw['data'];
      if (data is! Map) return out;
      for (final e in data.entries) {
        final key = e.key;
        final v = e.value;
        if (key is! String || v is! Map) continue;
        final hs = v['h'];
        final ts = v['t'];
        if (hs is! String || ts is! int) continue;
        LivePlaybackHealth? h;
        for (final cand in LivePlaybackHealth.values) {
          if (cand.name == hs) {
            h = cand;
            break;
          }
        }
        // ★ 认不出的枚举名 ⇒ 跳过这一条（不是整份丢掉：
        //   其余条目仍然有用，不该被一条坏数据连坐）
        if (h == null || h == LivePlaybackHealth.unknown) continue;
        out[key] = LivePlaybackHealthEntry(
          health: h,
          at: DateTime.fromMillisecondsSinceEpoch(ts),
          detail: v['d'] is String ? v['d'] as String : null,
        );
      }
    } catch (e) {
      debugPrint('[LIVE] 可用性缓存解析失败（当作无缓存）: $e');
      return <String, LivePlaybackHealthEntry>{};
    }
    return out;
  }

  /// 读盘（数据目录未就绪 / 没有文件 / 损坏 ⇒ 空 Map）
  static Future<Map<String, LivePlaybackHealthEntry>> load() async {
    try {
      final entry = await DiskCache.read(kLiveHealthCacheName);
      if (entry == null) return <String, LivePlaybackHealthEntry>{};
      // ★ DiskCache 已经拆掉了 {v, at, data} 外层信封
      //   ⇒ entry.data 就是我们的 data Map，直接解析
      return decode({'v': kLiveHealthCacheVersion, 'data': entry.data});
    } catch (e) {
      debugPrint('[LIVE] 读取可用性缓存失败（当作无缓存）: $e');
      return <String, LivePlaybackHealthEntry>{};
    }
  }

  /// 落盘（失败只记日志，不影响功能）
  static Future<void> save(
    Map<String, LivePlaybackHealthEntry> entries,
  ) async {
    try {
      // ★ 只喂 data：DiskCache 自己会包 {v, at, data}
      await DiskCache.write(kLiveHealthCacheName, encode(entries)['data']);
    } catch (e) {
      debugPrint('[LIVE] 写入可用性缓存失败（不影响功能）: $e');
    }
  }

  /// 过滤出**仍然有效**（未超过 [kLiveHealthTtl]）的条目
  ///
  /// # ★ 为什么"过期"不等于"丢掉"
  /// ```text
  /// 用户要求：过期后**保留条目、标记待刷新**，不要清空。
  /// 理由：灰/红点突然消失比"状态旧了"更让用户困惑
  ///      （"我刚看到一个红点，怎么没了？它好了还是我记错了？"）。
  /// ⇒ 本函数只**分类**，不删。是否重试由 needsRetry 决定，
  ///   是否显示旧徽标由 UI 决定（旧的要弱化显示）。
  /// ```
  static Map<String, LivePlaybackHealthEntry> freshOnly(
    Map<String, LivePlaybackHealthEntry> entries, {
    DateTime? now,
    Duration ttl = kLiveHealthTtl,
  }) {
    final t = now ?? DateTime.now();
    final out = <String, LivePlaybackHealthEntry>{};
    for (final e in entries.entries) {
      if (t.difference(e.value.at) < ttl) out[e.key] = e.value;
    }
    return out;
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  延迟探测调度器（P0 ③：错开启动瞬间的请求高峰）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么单独抽一个类，而不是在 `LivePage` 里裸写 `Timer`
//
// ```text
// 裸写 Timer 的唯一验证方式是"静态文本断言"（源文件里有没有那一行）。
// ★ 但静态断言抓不到"定时器真的生效" —— 它只证明"代码写着"，
//   不证明"到点真的会调"、"取消真的会停"。
// ⇒ 那正是 Lead 指出的假绿风险。
//
// 抽成类之后，可以用 `fake_async` 直接**推进时间**来验证行为：
//   · 30 秒不到 ⇒ **一次都不许调**
//   · 到 30 秒   ⇒ 恰好调一次
//   · 取消之后   ⇒ 永不调用（即使时间推得再远）
// ```
//
// ⚠️ 这个类**不碰 Flutter**（只用 dart:async），所以能纯单测。

/// 「稍后开始探测」的调度器
///
/// 语义只有三条：
/// ```text
/// schedule()  安排一次延迟触发（重复调用只保留最后一次）
/// cancel()    取消（未触发则永不触发）
/// isPending   是否还在等待
/// ```
class DelayedProbeScheduler {
  DelayedProbeScheduler({
    required this.delay,
    required this.onFire,
  });

  /// 等多久才触发
  final Duration delay;

  /// 到点要做的事
  final void Function() onFire;

  Timer? _timer;

  /// 是否还在等待（UI 用它决定要不要显示"稍后开始"）
  bool get isPending => _timer != null && _timer!.isActive;

  /// 安排一次
  ///
  /// ★ 重复调用**只保留最后一次**：否则页面重建会叠加出多个定时器，
  ///   到点一次触发 N 遍探测 —— 比不延迟更糟。
  void schedule() {
    _timer?.cancel();
    _timer = Timer(delay, () {
      _timer = null;
      onFire();
    });
  }

  /// 取消（页面销毁 / 已有缓存时调用）
  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  探测结论 → 健康状态的镜像（P0 修复：写进去的是空数据）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个函数存在的唯一原因：我第一版漏了三种情况
//
// ```text
// 第一版只写了一行：
//     if (a == LiveAvailability.unavailable && healthOf == unknown) record(broken)
//
// ⇒ 探测 1136 个频道，绝大多数是 **playable**
// ⇒ 只把 unavailable 的写进 _health，playable/audioOnly 一条都不写
// ⇒ _health.snapshot() 空 ⇒ 落盘 {"data":{}}
// ⇒ 下次启动读到 0 条 ⇒ 不 seed ⇒ **全量重探 706 次**
//
// ⚠️ 而这一切发生时：
//    · 文件生成了 ✅    · 大小看着正常 ✅    · 路径正确 ✅
//    · 我用 fake fetcher 写的门禁全绿 ✅（它直接调 probe()/seed()，
//      从不经过这个镜像函数）
// ⇒ **只看"文件存在"或"门禁绿"都会误判为已修复。**
// ```
//
// # 为什么抽成纯函数（而不是留在 Page 里）
// ```text
// 留在 `_LivePageState` 里 ⇒ 门禁只能靠 widget 测试或"读源码文本"，
// 前者重、后者假（静态断言抓不到逻辑）。
// 抽成纯函数后，门禁可以**直接喂 3 种可用性、断言产出 3 条记录** ——
// 走的正是产品代码的同一条路。
// ```

/// 探测结论（[LiveAvailability]）→ 健康状态（[LivePlaybackHealth]）的映射
///
/// ★ `audioOnly` 也映射成 `playable`：能出声音就算"这个源是可用的"。
///   "仅音频"是另一层信息（`LiveAvailability` 自己保留），
///   不该在这里被压成 `broken`（那会让广播台被误标成"不可用"）。
LivePlaybackHealth healthFromAvailability(LiveAvailability a) => switch (a) {
      LiveAvailability.playable => LivePlaybackHealth.playable,
      LiveAvailability.audioOnly => LivePlaybackHealth.playable,
      LiveAvailability.unavailable => LivePlaybackHealth.broken,
      LiveAvailability.unknown => LivePlaybackHealth.unknown,
    };

/// 把一批探测结论镜像进健康状态（**四个分支全覆盖**）
///
/// # 优先级保护：按**新鲜度**，不是按"有没有记录"
/// ```text
/// ★ 已有条目**仍新鲜**（`now - at < kLiveHealthTtl`）⇒ 不覆盖。
///   理由：`broken` 来自**真实播放失败**，比"探测说没有可播地址"更硬；
///   真实证据不该被推断结论覆盖。
/// ★ 已有条目**已过期** ⇒ 允许被这次探测结论刷新（**含 `at`**）。
/// ★ `unknown` 不写（`record()` 内部也会早退，这里显式跳过更清楚）。
/// ```
///
/// # ★★★ 为什么"过期也要保护"是个真 bug（PR #32 ①，2026-10-21 修）
///
/// ```text
/// 原判据是 `healthOf(...) != unknown ⇒ continue`，即"只要有记录就不写"。
/// 它把 P0 的目标（「10 分钟内有缓存就一个请求都不发」）**从内部打穿**：
///
///   首次探测后写入所有频道，at = T0，落盘
///   ⇒ 11 分钟后重启：restore 回 at = T0 ⇒ freshOnly 为空 ⇒ 延迟分支
///   ⇒ 30s 后全量重探
///   ⇒ 探完回到这里：`healthOf != unknown` 对**所有**频道都成立
///   ⇒ **一条都不写** ⇒ `_persistHealth()` 把仍是 T0 的旧快照写回磁盘
///   ⇒ 下次启动重复 ⇒ **只有"首次探测后 10 分钟内重启"才命中缓存**
///
/// ★ 而 `at` 的语义是「**最后一次观测到该状态的时刻**」——
///   两处消费方（`needsRetry` / `freshOnly`）要的都是这个语义。
///   重新观测到同一状态却不更新 `at`，等于把它悄悄改成了
///   "第一次观测到的时刻"，语义被写坏，而且是**无声的**：
///   文件生成了、大小正常、路径正确，只是时间永远不前进。
/// ```
///
/// # 为什么用 [LivePlaybackHealthStore.now] 而不是 `DateTime.now()`
/// ```text
/// `record()` 写 `at` 用的是 store 的注入时钟。
/// 若这里用真实时钟比较、那里用注入时钟写，测试注入的时间跨度
/// 会让"新鲜"判据和"写入的 at"来自两个不同的世界 ——
/// 门禁看起来在跑，读数却没有意义。
/// ```
///
/// 返回实际写入的条数（门禁与日志用）。
int mirrorAvailabilityIntoHealth({
  required LivePlaybackHealthStore store,
  required Iterable<(String provider, String channelId, LiveAvailability a)> items,
}) {
  var n = 0;
  // ★ 与 `record()` 写 `at` 同一个时钟（见上面第二段注释）
  final now = store.now;
  for (final (provider, channelId, a) in items) {
    // ★ unknown 没有信息，不制造记录
    if (a == LiveAvailability.unknown) continue;
    final prev = store.entryOf(provider, channelId);
    // ★ 已有条目**仍新鲜** ⇒ 保护它不被推断结论覆盖（真实播放证据更硬）
    //   已过期 ⇒ 落到下面，被这次探测结论刷新（含 at）
    if (prev != null && now.difference(prev.at) < kLiveHealthTtl) {
      continue;
    }
    final h = healthFromAvailability(a);
    if (h == LivePlaybackHealth.unknown) continue;
    store.record(
      provider: provider,
      channelId: channelId,
      health: h,
      detail: switch (a) {
        LiveAvailability.audioOnly => '取址探测：仅音频线路',
        LiveAvailability.unavailable => '取址探测：没有可播线路',
        _ => null,
      },
    );
    n++;
  }
  return n;
}
