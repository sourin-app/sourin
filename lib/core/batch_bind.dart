// ═══════════════════════════════════════════════════════════════════════
//  番剧批量绑定弹幕 —— 设计说明（先读这里再看代码）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话
// ```text
// > 再然后再支持一个功能,番剧的批量绑定弹幕,可以互联关系,
// > 你看看怎么设计这个功能好,做好之后再一起提醒我,我来测试
// ```
//
// ───────────────────────────────────────────────────────────────────────
//  ## 一、这个功能到底在解决什么
// ───────────────────────────────────────────────────────────────────────
//
// 现状：绑定是**逐集**做的。用户点进第 1 集 → 搜 → 点一条 → 绑上；
// 换到第 2 集 → 再来一遍。一部 12 集的番要重复 12 次同样的动作，
// 而每次搜索的**结果几乎是同一份**（同一部作品、不同集号）。
//
// ⇒ 批量绑定 = **做一次，铺满整部**。
//
// ───────────────────────────────────────────────────────────────────────
//  ## 二、为什么不能"搜一次然后把结果复制到每一集"
// ───────────────────────────────────────────────────────────────────────
//
// 这是本功能最容易做错的地方，也是我把它单独抽成 core 模块的原因。
//
// ```text
// 弹幕库里「一集」= 一个 episodeId，而**每集的弹幕是独立的**。
// 把第 1 集的 episodeId 铺给 12 集 ⇒ 12 集全都在放第 1 集的弹幕，
// 时间轴、剧情、台词**全错**，而 UI 上看起来"绑定成功"。
// ```
//
// 所以铺开的不是 episodeId，而是**对应关系**：
// ```text
// 我们这边：第 1 集 / 第 2 集 / … / 第 12 集   （本地剧集表，有顺序）
// 弹幕库：  第1话 / 第2话 / … / 第12话        （搜索结果的 episodes，有顺序）
// ⇒ 按**集号**对齐，而不是按数组下标硬配。
// ```
//
// ───────────────────────────────────────────────────────────────────────
//  ## 三、"互联关系"是什么（Owner 提到的那个词）
// ───────────────────────────────────────────────────────────────────────
//
// 指**同一部作品在不同来源之间共享同一份绑定**。
//
// ```text
// 用户在源 A 看《无职转生》绑好了 12 集
// 切到源 B 看同一部《无职转生》⇒ 还要再绑一遍？
// ```
//
// 显然不该。但"同一部作品"需要一个**判据** —— 本仓已有现成的：
// `lib/core/title_match.dart` 的 `titleSimilarity`（bigram Jaccard），
// 换源弹层与搜索排序都在用它，**不另造一套**（两套定义必然漂移）。
//
// ⚠️ 判据必须**保守**：错认成同一部 ⇒ 源 B 被源 A 的弹幕污染，
//    而且用户不会立刻发现。所以：
// ```text
// · 相似度门槛高于自动匹配用的 0.34（那个是"要不要自动绑"，
//   这个是"要不要把 A 的绑定当 B 的"—— 后果更重）
// · 两边**都要有**标题（空标题一律不互联，宁可让用户手绑）
// ```
//
// ───────────────────────────────────────────────────────────────────────
//  ## 四、模块边界（为什么这些逻辑放在 core 而不是 UI）
// ───────────────────────────────────────────────────────────────────────
//
// ```text
// · 纯函数、无 Flutter 依赖 ⇒ 可单测（本功能的对齐规则错一次就是全错，
//   必须有确定性判据钉住，不能只靠手点）
// · UI 只负责"展示计划 + 让用户确认"，不参与对齐决策
// ```
//
// ⚠️ 本文件**不写盘**：产出的是"计划"，落盘由调用方走既有的
//    `saveBinding` / `saveBiliDanmakuBinding`（单一写入口，不新开一条）。

import 'dart:convert';

import 'danmaku.dart';
import 'title_match.dart';
import 'ui_prefs.dart';

/// 批量绑定里"一集要对到哪一条弹幕"。
class BatchBindPlanItem {
  const BatchBindPlanItem({
    required this.episodeIndex,
    required this.episodeId,
    this.episodeTitle = "",
    this.shift = 0,
  });

  /// 本地第几集（0 基，与 `_epIndex` / `BiliEpisodeBinding.episodeIndex` 同口径）。
  final int episodeIndex;

  /// 弹幕库里那一集的 id。
  final int episodeId;

  /// 那一集在弹幕库里的名字（给用户核对用）。
  final String episodeTitle;

  /// 时间轴偏移秒数。
  final double shift;

  @override
  String toString() =>
      'E${episodeIndex + 1} -> #$episodeId${episodeTitle.isEmpty ? '' : ' ($episodeTitle)'}';
}

/// 批量绑定的完整计划。
class BatchBindPlan {
  const BatchBindPlan({
    required this.items,
    this.workTitle = "",
    this.totalLocal = 0,
    this.unmatchedLocal = const <int>[],
  });

  final List<BatchBindPlanItem> items;

  /// 这次铺的是哪部作品（弹幕库侧的名字）。
  final String workTitle;

  /// 本地一共几集。
  final int totalLocal;

  /// 没对上弹幕的本地集号（0 基）—— **必须如实报给用户**。
  ///
  /// 为���么重要：只报"绑了 9 集"而吞掉"有 3 集没绑"，用户会以为整部都好了，
  /// 直到播到第 10 集发现没弹幕才回来查。
  final List<int> unmatchedLocal;

  int get count => items.length;
  bool get isEmpty => items.isEmpty;

  @override
  String toString() => 'BatchBindPlan(${items.length}/${totalLocal} 集, 未匹配 ${unmatchedLocal.length})';
}

/// 从剧集标题里抠出**集号**（1 基）；抠不到返回 null。
///
/// # 为什么要认这么多种写法
/// ```text
/// 弹幕库侧：「第1话 我是路飞！」「第01集 xxx」「第 3 话 yyy」
/// 本地侧  ：「第01集」「EP05」「第3集」「12」
/// ```
/// 实测（2026-10-15 打官方 API）三种形态都真实存在，只认一种就会大面积对不上。
///
/// ⚠️ 顺序有讲究：**先认「第N话/集/回/幕」，再认 EP/SP 前缀，最后才是裸数字**。
///    反过来的话，「第2话」里的 2 会被裸数字规则先抢走（结果一样但语义错），
///    而「2024」这种年份会被当成第 2024 集。
int? episodeNumberFrom(String title) {
  final t = title.trim();
  if (t.isEmpty) return null;

  // ① 第N话 / 第N集 / 第N回 / 第N幕（中文最常见的写法）
  final cn = RegExp(r'第\s*(\d{1,4})\s*[话話集回幕]').firstMatch(t);
  if (cn != null) {
    final n = int.tryParse(cn.group(1)!);
    if (n != null && n > 0) return n;
  }

  // ② EP05 / ep5 / SP03 这类前缀
  final ep = RegExp(r'\b(?:ep|sp|e)\s*(\d{1,4})\b', caseSensitive: false).firstMatch(t);
  if (ep != null) {
    final n = int.tryParse(ep.group(1)!);
    if (n != null && n > 0) return n;
  }

  // ③ 整串就是个数字（本地标题有时只有集号）
  final bare = RegExp(r'^(\d{1,4})$').firstMatch(t);
  if (bare != null) {
    final n = int.tryParse(bare.group(1)!);
    if (n != null && n > 0) return n;
  }

  return null;
}

/// 由「本地剧集标题表」+「弹幕库集列表」生成批量绑定计划。
///
/// # 对齐规则（按优先级）
/// ```text
/// ① 两边都能抠出集号 ⇒ **按集号配**（最准：跨过了"顺序不同/缺集"）
/// ② 只有一边能抠出，或都抠不出 ⇒ 退到**按下标顺序配**
/// ③ 数量不等 ⇒ 多出来的一律**不绑**（宁缺勿错），并记进 unmatchedLocal
/// ```
///
/// ⚠️ 规则 ③ 是刻意的：本地 24 集、弹幕库只有 12 集时，
///    硬把后 12 集也塞进去 = 每集都挂着错的时间轴。
///    宁可少绑，也不能错绑 —— 错绑用户看不出，少绑他看得见。
BatchBindPlan buildBatchBindPlan({
  required List<String> localTitles,
  required List<DanmakuMatch> matches,
  String workTitle = "",
}) {
  if (localTitles.isEmpty || matches.isEmpty) {
    return BatchBindPlan(
      items: const <BatchBindPlanItem>[],
      workTitle: workTitle,
      totalLocal: localTitles.length,
      unmatchedLocal: <int>[for (var i = 0; i < localTitles.length; i++) i],
    );
  }

  final byNumber = <int, DanmakuMatch>{};
  final unnumbered = <DanmakuMatch>[];
  for (final m in matches) {
    final n = episodeNumberFrom(m.episodeTitle);
    if (n == null) {
      unnumbered.add(m);
    } else {
      byNumber.putIfAbsent(n, () => m); // 同集号只取第一条（结果已按相似度排过）
    }
  }

  final items = <BatchBindPlanItem>[];
  final unmatched = <int>[];
  var seq = 0; // 退到下标对齐时的游标（★ 只吃 unnumbered 池，见下）

  for (var i = 0; i < localTitles.length; i++) {
    final localNo = episodeNumberFrom(localTitles[i]);
    DanmakuMatch? hit;
    if (localNo != null) {
      hit = byNumber[localNo];
    }
    /*
     * 退路：按下标顺序取，**只从 unnumbered 池里取**。
     *
     * # 为什么不能从整个 matches 里取（2026-10-16 实测踩到）
     *
     * 原来是 `matches[seq]`。当**弹幕库这侧是带集号的**、而本地某一集
     * 在库里没有对应集时，退路会把游标停在一条**已经有主的**记录上：
     *
     * ```text
     * 本地 [第1集, 第2集, 第3集]  库 [第1话(#11), 第3话(#33)]
     *   → 第1集 按集号配 #11
     *   → 第2集 库里没有第2话 ⇒ 退路拿到 matches[1] = #33   ← 错！
     *   → 第3集 按集号配 #33                                ← 和第2集撞了
     * 结果：两集共享同一个 episodeId，第2集放的是第3集的弹幕，
     *       而且 unmatchedLocal 是空的 —— 用户以为全绑好了。
     * ```
     *
     * 这正是本文件开头那条铁律要防的事（错配比不配更糟）。
     * ⇒ 退路只允许消耗**库里没集号**的那些条目（它们本来就没法按号配）；
     *   库这侧带集号却没配上时，老实记进 unmatchedLocal。
     */
    if (hit == null && seq < unnumbered.length) {
      hit = unnumbered[seq];
    }
    seq++;
    if (hit == null) {
      unmatched.add(i);
      continue;
    }
    items.add(BatchBindPlanItem(
      episodeIndex: i,
      episodeId: hit.episodeId,
      episodeTitle: hit.episodeTitle,
      shift: hit.shift,
    ));
  }

  return BatchBindPlan(
    items: items,
    workTitle: workTitle,
    totalLocal: localTitles.length,
    unmatchedLocal: unmatched,
  );
}

/// 互联判据用的门槛。
///
/// 比自动绑定那个 0.34 **高**：那一个是"要不要自动绑"（错了用户能改），
/// 这一个是"要不要把 A 源的绑定当成 B 源的"（错了是**静默污染**，
/// 用户不会立刻发现）。后果更重 ⇒ 判据更严。
const double kInterconnectThreshold = 0.60;

/// 两个标题是不是**同一部作品**（跨源互联的判据）。
///
/// ⚠️ 任一侧标题为空 ⇒ 一律 false。
///    空标题与任何东西相似度都是 0，但更危险的是"两个都空"会被某些
///    实现判成相等 —— 那会把所有没有标题的作品串成一片。
bool looksLikeSameWork(String a, String b) {
  final x = a.trim();
  final y = b.trim();
  if (x.isEmpty || y.isEmpty) return false;
  if (x == y) return true;
  return titleSimilarity(x, y) >= kInterconnectThreshold;
}

/// 在其它来源里找出与 [title] 同一部作品的 (provider, id)。
///
/// [candidates] 每项 = (provider, id, title)。
/// 返回按相似度**降序**排好的结果（同一部作品的多个源）。
List<({String provider, String id, double score})> findInterconnectedSources({
  required String title,
  required List<({String provider, String id, String title})> candidates,
}) {
  final out = <({String provider, String id, double score})>[];
  for (final c in candidates) {
    if (!looksLikeSameWork(title, c.title)) continue;
    out.add((
      provider: c.provider,
      id: c.id,
      score: titleSimilarity(title.trim(), c.title.trim()),
    ));
  }
  out.sort((p, q) => q.score.compareTo(p.score));
  return out;
}

// ═══════════════════════════════════════════════════════════════════════
//  落盘：整部绑定的**弹幕库**对应关系
// ═══════════════════════════════════════════════════════════════════════
//
// ⚠⚠⚠ 2026-10-15（我自己写错过一次，记下来）
// ```text
// 第一版我把这些 episodeId 写进了 `saveBinding`
// （= 外部视频站的 `BiliBinding`）。
//
// 而 `BiliBinding` 被 `_loadBiliDanmaku(cid)` 消费 —— 那是**外部视频站的
// 评论接口**。把弹幕库的 id 往里面塞，下次起播就会拿着
// 弹幕库的 id 去调外部站的接口 ⇒ 请求必失败。
//
// ★ 两个 id 语系**不能混**：它们碰巧都是整数，
//   但各自属于不同的服务。编译器看不出来，只能靠存储分开。
// ```
//
// ⇒ 本模块自带一条**独立**的存储，键与 `BiliBinding` 那套完全分开。

/// 弹幕库整部绑定的存储前缀。
///
/// ⚠️ 与 `dsh.bili.bind.*` **不同命名空间** —— 那一套是外部视频站的。
const String kDanmakuBindPrefix = 'dsh.danmaku.bind';

/// 一部作品的弹幕库绑定（本地第 N 集 → 弹幕库第 M 集）。
class DanmakuBindStore {
  const DanmakuBindStore({
    required this.workTitle,
    required this.episodes,
    this.updatedAt = 0,
  });

  /// 这次铺的是哪部作品（给用户看“绑到哪去了”）。
  final String workTitle;

  /// 本地第 N 集（0 基） → 弹幕库 episodeId。
  final Map<int, int> episodes;

  final int updatedAt;

  bool get isEmpty => episodes.isEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
        't': workTitle,
        // 键必须转字符串：JSON 的键只能是字符串。
        'e': <String, int>{
          for (final e in episodes.entries) '${e.key}': e.value,
        },
        'u': updatedAt,
      };

  static DanmakuBindStore? fromJson(Object? j) {
    if (j is! Map) return null;
    final raw = j['e'];
    if (raw is! Map) return null;
    final eps = <int, int>{};
    for (final e in raw.entries) {
      final k = int.tryParse('${e.key}');
      final v = e.value;
      if (k == null || v is! int || v <= 0) continue;
      eps[k] = v;
    }
    return DanmakuBindStore(
      workTitle: j['t'] is String ? j['t'] as String : '',
      episodes: eps,
      updatedAt: j['u'] is int ? j['u'] as int : 0,
    );
  }
}

/// 读一部作品的弹幕库绑定；没有 / 损坏都返回 null（不抛）。
DanmakuBindStore? loadDanmakuBind(String provider, String id) {
  final raw = UiPrefs.get('$kDanmakuBindPrefix.$provider:$id');
  if (raw == null || raw.isEmpty) return null;
  try {
    return DanmakuBindStore.fromJson(jsonDecode(raw));
  } catch (_) {
    // 坏数据不能把播放页拖崩 —— 当成“没绑过”处理。
    return null;
  }
}

/// 写一部作品的弹幕库绑定。
void saveDanmakuBind(String provider, String id, DanmakuBindStore s) {
  UiPrefs.set('$kDanmakuBindPrefix.$provider:$id', jsonEncode(s.toJson()));
}

/// 删一部作品的弹幕库绑定。
void clearDanmakuBind(String provider, String id) {
  UiPrefs.remove('$kDanmakuBindPrefix.$provider:$id');
}