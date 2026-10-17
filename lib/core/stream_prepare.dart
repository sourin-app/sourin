import 'dart:async';

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
    if (needIdx.isEmpty) return list;

    final out = List<StreamCandidate>.of(list);
    final r = resolver;

    for (final i in needIdx) {
      final c = list[i];
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
  }
}
