// ═══════════════════════════════════════════════════════════════════════
//  多线路选集的**公共判据**（2026-10-30 现场反馈批次 1.1/1.2/1.4 抽出）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么单独一个文件
//
// ```text
// 选集有两个渲染路径：
//   ① lib/ui/player/episode_panel.dart  PlayerEpisodePanel（抽屉/底部弹层）
//   ② lib/ui/detail_page.dart           _bodyEpisodes（合并页右侧详情栏）
// 改前只有 ① 按线路过滤（2026-10-26/29 两轮），② 仍把 17 线路 × 27 集
// = 459 条全部平铺（Owner 图5/图8：「右侧没有区分线路，重复的集数一大把」）。
//
// 两路径要用**同一份**判据（selectedFlag ?? _firstFlag + 过滤），
// 写两份 = 两处会漂移 —— 与 provider_name.dart 单独成文件是同一条理由。
// ```
//
// # 为什么不放 episode_strip.dart
//
// live_page.dart 持有「episode_strip.dart 只读复用，不改它（lead 明确）」的
// 既有约束 ⇒ 判据落在新文件，两条旧路径各自 import 本件（lead 2026-10-30 裁决）。

import '../../core/models.dart';

/// 有效线路名 —— 两个渲染路径共用的「当前线路」判据
///
/// # 语义（与 PlayerEpisodePanel._eps 2026-10-29 的兜底逐字同源）
///
/// ```text
/// ① selectedFlag 非空且确实存在于 episodes 里 ⇒ 用它；
/// ② 否则（没传 / 指向已不存在的旧线路）⇒ 用第一条出现的线路名；
/// ③ 全都没有 flag（单线路源）⇒ null —— 调用方原样返回全集，一集不丢。
/// ```
///
/// # 为什么 ② 要校验「存在于 episodes」而不是直接信 selectedFlag
///
/// ```text
/// 换源/换剧会整批替换 episodes，而上游的 selectedFlag 可能还停在旧值
/// （player_page._syncSelectedFlag 正是为这条写的）⇒ 判据层自己兜一次，
/// "面板全空"这类形态就结构性地不可能再出现。
/// ```
String? effectiveFlag(List<Episode> episodes, String? selectedFlag) {
  final sel = selectedFlag?.trim() ?? '';
  if (sel.isNotEmpty && episodes.any((e) => e.flag == sel)) return sel;
  for (final e in episodes) {
    final f = e.flag;
    if (f != null && f.isNotEmpty) return f;
  }
  return null;
}

/// 本线路的集（渲染路径只该画这一份）
///
/// `effectiveFlag` 返回 null（单线路源）⇒ **原样返回**，一集不丢 ——
/// 与 `episodeLineFilter` 在单线路下的既有语义逐字一致。
List<Episode> episodesForLine(List<Episode> all, String? selectedFlag) {
  final flag = effectiveFlag(all, selectedFlag);
  if (flag == null) return all;
  return all.where((e) => e.flag == flag).toList();
}

/// 线路条数（去重；无 flag 的集不参与计数）
///
/// 单线路源返回 0 或 1 —— 调用方判「多线路」用 `> 1`。
int lineCountOf(List<Episode> all) {
  final seen = <String>{};
  for (final e in all) {
    final f = e.flag;
    if (f == null || f.isEmpty) continue;
    seen.add(f);
  }
  return seen.length;
}

/// 集号归一化：从标题里提取**数字集号**（1.4 线路切换集数对齐用）
///
/// # 为什么不能只做标题精确相等
///
/// ```text
/// 同一集在不同线路/不同源里的标题形态不同（真机读数）：
///   「第2集」 vs 「第02集」   ← 零填充差异
///   「第 2 集」 vs 「2」      ← 「第…集」壳的差异
/// 精确相等匹配不到 ⇒ 上游要么停在旧集、要么跳回第 1 集。
/// ```
///
/// # 归一化规则（两层，先专项后兜底）
///
/// ```text
/// ① 「第 N 集/话/回」优先（与 player_page._epOrder 同一正则，
///    防「2024 重映版」这类年份误判）；
/// ② 否则取标题里第一段连续数字（「01」「EP3」「2」）。
/// 两层都落空 ⇒ null（调用方按"匹配不到"处理，不许编一个号）。
/// ```
int? episodeNumberOf(String? title) {
  if (title == null || title.isEmpty) return null;
  final m = RegExp(r'第\s*(\d+)\s*[集话回]').firstMatch(title);
  if (m != null) return int.tryParse(m.group(1)!);
  final m2 = RegExp(r'\d+').firstMatch(title);
  return m2 == null ? null : int.tryParse(m2.group(0)!);
}
