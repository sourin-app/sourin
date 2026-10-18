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

import 'package:flutter/widgets.dart';

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

  String _key(String provider, String channelId) => '$provider\u0000$channelId';

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
  }) : _fetch = fetch ?? SourinApi.getLiveStream;

  final Duration ttl;

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
    if (DateTime.now().difference(t) > ttl) return null;
    return _result[k];
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
