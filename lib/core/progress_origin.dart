// ═══════════════════════════════════════════════════════════════════════
//  续播进度「来源身份」—— 本地缓存与在线观看的**统一键**推导（唯一下拉点）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字，反馈 C）
//
// > 续播进度,我希望的是我缓存这集了,但是如果我在线看,他还能记得我看过
// > 而不是 本地和线上的就彻底分开了,你懂不
//
// # 现象
//
// 同一集：缓存下来看一遍，再在线点开 => **从第 0 秒开始**；反过来也一样。
// 用户感知就是「本地看过的，在线不认」。
//
// # 根因（一句话）
//
// 进度主键是 `(provider, mediaId)`（`rust/sourin_core/src/commands_write.rs:42-44`
// `fn item_key(provider, id) -> "{provider}:{id}"`），而本地播放的 provider
// 恒为 `local`、id 是**文件的规范化绝对路径**（`lib/ui/cache_page.dart:787`
// 与 `:817-818`），在线播放的 provider/id 是**站点与站点内容 id**。
// => 同一集在两套命名空间里各有一条记录，互相看不见。
//
// # 方案：**写的时候多写一条镜像**（不是把两个空间合并）
//
// ```text
// 本地会话（provider=local, id=D:/…/第01集.mp4）
//   ├─ ① 原样写 local 键        —— 既有行为逐字不变
//   └─ ② 原来源可知时，再写一条 (站点, 站点内容 id) 的镜像
// 在线会话（provider=bilibili, id=BV…）
//   └─ 原样写站点键             —— 既有行为逐字不变
// 读的时候（PlayerPage._prepareResume）
//   ├─ 先读本会话自己的键（逐字不变，老数据必须继续能续播）
//   └─ 再读对侧键，取 updatedAt 更新的那条
// ```
//
// # ★ 为什么不改成「本地会话直接用站点键」
//
// `lib/ui/cache_page.dart:722-734` 是**有意**把本地进度放进 `local` 空间的，
// 那是上一轮 Owner 反馈的裁决，本轮**一个字都不改**：
// ```text
// ① 若用站点 provider+id 写，本地播放会把在线那条记录的进度
//    改成本地文件的进度（两个文件 -> 一条记录 -> 互相覆盖）
// ② 但也不许「静默不写」—— 本地文件的观看进度必须能存能读
// => 折中：命名空间用 local，id 用文件的规范化绝对路径
// ```
// 本文件只做**加法**：镜像写在**另一个键**上，`local` 那条一个字都不改。
//
// # ★ 为什么读侧要「读两个键取新的」而不是只读镜像
//
// 存量数据（本轮之前写的）只有 `local` 那条，镜像**不存在**。
// 若读侧改成「只读镜像」，老用户的续播会**全部失效**。
// 两条都读、按 `updatedAt` 取新的 => 老数据、新数据都能续播，
// 而且**可逆**（镜像那条读失败时，行为退化成今天的样子）。
//
// # ★ 为什么不调 Rust 的 `repoint_item` 做一次性迁移
//
// ```text
// ① commands_write.rs:505-547 里 if from_provider == to_provider { return Ok(()) }
//    => 「同一个源里换个 id」是**静默无操作**，迁移根本做不到
// ② 跨源迁移是**破坏性**的：旧记录被改掉之后，
//    旧版本 App 打开就看不到那条进度了
// => 读两侧、取新的：无迁移、无删除、随时可退
// ```
//
// ⚠️ 本文件**只有纯函数与常量**（没有 IO、没有 FFI、不 import `lib/ui/**`）——
//    判断逻辑能单测，才不会又变成「只有真机才测得出」的那种改动。
//    （`lib/core/**` 反向依赖 `lib/ui/**` 的代价见 `lib/core/download_dir.dart:226-232`。）

import 'package:flutter/foundation.dart';

import 'models.dart';
import 'sourin_api.dart';

/// `local` 命名空间的 provider 字面量 —— 与 `lib/ui/cache_page.dart:787`
/// 的 `kLocalProvider` **必须是同一个值**。
///
/// # 为什么在这里再写一遍（而不是 import 那个常量）
///
/// `kLocalProvider` 住在 `lib/ui/cache_page.dart`，而本文件在 `lib/core/**`：
/// `lib/core` 依赖 `lib/ui` 会让「core 层」这个概念失效
/// （本仓唯一反例 `lib/core/app_tray.dart:46-47` 是个 UI 专用文件，不是先例）。
///
/// => 代价是同一个字面量出现两处，**用一条硬断言钉住它**：
///    `test/zz_ops13_origin_test.dart` 里 `kProgressLocalProvider == kLocalProvider`。
///    谁改了一处而没改另一处，测试立刻红，不会静默漂。
const String kProgressLocalProvider = 'local';

/// 「这条进度原本来自哪个站点内容」—— 一个**非 local** 的 (provider, id) 对
///
/// # 为什么需要它（而不是复用 CachedPlayRequest.originProvider）
///
/// `CachedPlayRequest`（`lib/ui/cache_page.dart:735-784`）已经有
/// `originProvider`/`originMediaId`，但那是 **UI 层的一个字段**，
/// 且它在 `shell._openCachedWork` 那一步就**丢掉了**。
/// 判断逻辑（能不能镜像、镜像成什么）必须住在 core 层才能单测。
@immutable
class ProgressOrigin {
  const ProgressOrigin({required this.provider, required this.mediaId});

  /// 站点 id（如 `bilibili` / `dandanplay`）—— **绝不是** `local`
  final String provider;

  /// 该站点上的内容 id（如 `BV1xx411c7mD` / `36578`）
  final String mediaId;

  /// 规范化构造：任一侧为空/全空白 => `null`（**不猜**）
  ///
  /// ⚠️ 空白要当空处理：`CachedWork.provider` 是从旁文件里读出来的字符串，
  ///    用户手改过的旁文件里出现全空白完全可能。放过去的话会写出一条
  ///    键为 `" :12345"` 的孤儿记录。
  static ProgressOrigin? of({String? provider, String? mediaId}) {
    final p = provider?.trim() ?? '';
    final m = mediaId?.trim() ?? '';
    if (p.isEmpty || m.isEmpty) return null;
    return ProgressOrigin(provider: p, mediaId: m);
  }

  @override
  String toString() => 'ProgressOrigin($provider:$mediaId)';

  @override
  bool operator ==(Object other) =>
      other is ProgressOrigin &&
      other.provider == provider &&
      other.mediaId == mediaId;

  @override
  int get hashCode => Object.hash(provider, mediaId);
}

/// 进度主键 —— 与 Rust `item_key`（`commands_write.rs:42-44`）**同构**
///
/// ```text
/// Rust : format!("{provider}:{id}")
/// Dart : provider + ':' + mediaId
/// ```
/// 拼错不会报错、只会静默查不到（Rust 侧注释原话），所以两边的格式由
/// `test/zz_ops13_origin_test.dart` 的源码扫描一起钉住。
String canonicalProgressKey(String provider, String mediaId) =>
    '$provider:$mediaId';

/// 从 `CachedPlayRequest` 的两个 origin 字段得到规范化的来源
///
/// `null` = 旁文件里没有来源信息（或就是 `local`）=> **不镜像**，不猜。
ProgressOrigin? localProgressOrigin({
  required String? originProvider,
  required String? originMediaId,
}) {
  final o = ProgressOrigin.of(provider: originProvider, mediaId: originMediaId);
  if (o == null) return null;
  // 来源本身就是 local（例如旁文件写的就是 local）=> 镜像等于重复写同一行
  if (o.provider == kProgressLocalProvider) return null;
  return o;
}

/// 要不要把这条进度镜像到 [origin] 那个键上 —— 三条拒绝
///
/// ```text
/// ① origin == null                       没有来源 => 不猜
/// ② origin.provider == 'local'           镜像到 local 键 = 原地重写
/// ③ origin.provider == sessionProvider   ★ 会话自己的键 => 会覆盖自己
/// ```
///
/// # ★ 第 ③ 条为什么是硬约束（不是洁癖）
///
/// 会话的 provider 与来源 provider 相同时，镜像的目标键 **就是**
/// 会话正在写的那个键：两条 `save_progress` 打同一个 key，后者覆盖前者。
/// 今天两边写的内容恰好一样（title/position 都取自同一处），但那只是**巧合** ——
/// 镜像那条按设计不带 `episode_id`（见 [saveProgressWithMirror]），
/// 一旦真打到同一个键上，就会把**正常那条**的 `episode_id` 抹成 NULL，
/// 续播的「按集校验」（`lib/ui/player_page.dart:3390`）随即失效
/// => 上一集的进度会串到这一集。
/// => 所以「自己镜像自己」必须在这里就被挡掉，而不是靠调用方自觉。
ProgressOrigin? mirrorOriginFor(
  ProgressOrigin? origin, {
  required String sessionProvider,
}) {
  if (origin == null) return null;
  if (origin.provider == kProgressLocalProvider) return null;
  if (origin.provider == sessionProvider) return null;
  return origin;
}

/// 镜像那条记录该写什么标题
///
/// 优先用真正的集标题（`episodeTitle`，如 `第01集`）；
/// 没有就退回**文件名去掉后缀**（`第01集.mp4` -> `第01集`）。
///
/// # ★ 为什么退回时必须去掉后缀（本轮的 RED 判据之一）
///
/// 本地会话手上只有文件名（`CachedEpisode` 没有 `episodeTitle` 字段，
/// `lib/ui/cache_page.dart:134-156`），而文件名是 `第01集.mp4`。
/// 直接把它当标题写进镜像，播放记录里就会出现「第01集.mp4」这种带后缀的条目。
///
/// 返回 `null` = **不写镜像**：Rust 的 `upsert_progress` 对空标题是
/// 「保留旧值」（`rust/sourin_core/src/store.rs:932-947` 的
/// `CASE WHEN excluded.title <> ''`），写一条空标题只会白刷 `updated_at`，
/// 把「取更新的那条」判据带偏。
String? mirrorProgressTitle({
  required String episodeTitle,
  required String episodeFileName,
}) {
  final t = episodeTitle.trim();
  if (t.isNotEmpty) return t;
  // 与 CachedEpisode.displayName（lib/ui/cache_page.dart:149-155）同款算法
  var name = episodeFileName.trim();
  if (name.endsWith('.part')) {
    name = name.substring(0, name.length - 5);
  }
  final dot = name.lastIndexOf('.');
  // ★ dot == 0 说明整个文件名就是"后缀"（形如 `.mp4` / `.part` 去掉后剩下的）
  //   ⇒ 拿不出名字。返回 null 比写一条标题叫 ".mp4" 的记录好得多：
  //   后者会污染播放记录列表（`upsert_progress` 对空标题才是"保留旧值"）。
  if (dot == 0) return null;
  final base = dot > 0 ? name.substring(0, dot) : name;
  return base.isEmpty ? null : base;
}

/// 续播该用哪一条记录 —— **读两侧、取 updatedAt 更新的那条**
///
/// # ★ 为什么不是「只读镜像」（这是存量数据能不能续播的关键）
///
/// 本轮之前写的进度**只有** `local` 那条，镜像不存在。
/// 只读镜像 => 老用户的续播**全部失效**。
/// 两条都读、取新的 => 老数据、新数据都能续播，而且**可逆**：
/// 镜像那条读失败/不存在时，行为退化成今天的样子。
///
/// ⚠️ 平局取 `session`（本会话自己的键）—— 与「镜像只是补充」的定位一致，
///    也让「镜像不存在」这条路径与今天**逐字同构**。
Progress? pickResumeProgress({Progress? session, Progress? mirror}) {
  if (session == null) return mirror;
  if (mirror == null) return session;
  return mirror.updatedAt > session.updatedAt ? mirror : session;
}

/// 这条进度是不是**当前这一集**的 —— 与 `lib/ui/player_page.dart:3390` 的守卫同义
///
/// ```text
/// player_page.dart:3390（逐字）
///   if (p.episodeId != null && curEpId != null && p.episodeId != curEpId) { 不续播 }
/// ⇒ 只有「两侧都**有**集号、且不相等」才算「属于另一集」；任一侧没有集号 => 放行。
/// ```
///
/// # ★ 与那行唯一的差别：**空串也算「没有集号」**
///
/// 那行只判 `!= null`。而 `curEpId` 的来源是
/// `widget.episodeId`（本地会话下 = 文件名，也可能是空串）——
/// 把空串当成一个"真集号"去比，结果必然是"不相等" ⇒
/// **每一次续播都被判成另一集**（功能整个失效，且日志里看起来还很"正常"）。
/// ⇒ 本函数把 null / 空串 / 全空白一律当"没有集号"。
///   ⚠️ 这是一处**有意的**宽松，不是笔误；产品侧那条既有守卫（自己那个键）
///   本轮**一个字都不改**（见 `test/player_capability_test.dart:326-330` 钉住的
///   `p.episodeId != curEpId` 字面量）。
bool progressBelongsToCurrentEpisode({
  required String? progressEpisodeId,
  required String? currentEpisodeId,
}) {
  final a = progressEpisodeId?.trim() ?? '';
  final b = currentEpisodeId?.trim() ?? '';
  if (a.isEmpty || b.isEmpty) return true;
  return a == b;
}

/// 一次镜像写入的全部内容（供注入点断言用）
@immutable
class ProgressMirrorCall {
  const ProgressMirrorCall({
    required this.provider,
    required this.mediaId,
    required this.title,
    required this.position,
    required this.duration,
    this.finished,
    this.episodeId,
    this.episodeTitle,
  });

  final String provider;
  final String mediaId;

  /// ★★★ **作品标题**（会话的 `title`，如 `本地剧`）—— **不是**集标题
  ///
  /// CR-07（CodeRabbit #7，Major）：这里原来放的是**集标题**。Rust 的
  /// `upsert_progress` 对非空 title 是**覆盖写**
  /// （`rust/sourin_core/src/store.rs:932-941` 的
  /// `CASE WHEN excluded.title <> '' THEN excluded.title ELSE title END`）
  /// ⇒ 站点键上原本那条**在线记录**的作品标题被改成「第01集」
  /// ⇒ `lib/ui/detail_page.dart:1689-1690` 的 `_resolveLocalOrigin`
  ///    按标题认源随之失效 ⇒ 来源 chip 退回「本地」。
  final String title;

  final int position;
  final int duration;
  final bool? finished;

  /// ★★★ **站点集 id**（如 `51463`）—— 拿不到时**整条镜像不写**
  ///
  /// CR-08（CodeRabbit #8，Major）：这里原来**恒为 `null`**。两个后果：
  /// ```text
  /// ① 读侧：pickResumeProgress（本文件 :230-234）会选中较新的镜像，
  ///    而 progressBelongsToCurrentEpisode（本文件 :254-262）在
  ///    progressEpisodeId 为空时**返回 true** ⇒ 按集校验失效
  ///    ⇒ 本地第 1 集的进度被在线第 3 集用上。
  /// ② 写侧：store.rs:939 是 episode_id=excluded.episode_id，**没有**守卫
  ///    ⇒ 镜像写入把在线记录已有的集 ID 覆盖成 NULL。
  /// ```
  /// ⇒ 现在的契约：**必须**是站点集 id；拿不到就跳过镜像
  ///   （见 [saveProgressWithMirror] 的 `originEpisodeId`）。
  ///   ⚠️ **绝不能**拿本地文件名充数 —— 二者必然不等。
  final String? episodeId;

  /// ★★★ 镜像那条的**集标题**（`第01集`）—— CR-07 把它从 [title] 里拆出来
  ///
  /// 由 [mirrorProgressTitle] 推出：优先会话的 `episodeTitle`，
  /// 没有就退回**文件名去后缀**（`第01集.mp4` -> `第01集`）。
  final String? episodeTitle;

  @override
  String toString() => 'ProgressMirrorCall($provider:$mediaId '
      'title=$title pos=$position/$duration finished=$finished '
      'episodeId=$episodeId episodeTitle=$episodeTitle)';
}

/// 镜像写入的**注入点**（`null` = 走真 `SourinApi.saveProgress`）
///
/// ⚠️ 与 `lib/core/sourin_api.dart:106-138` 的 `debugHomeFetcher` 同一套做法：
///    默认 null => 生产路径**逐字不变**（只多一次判空）；
///    只有测试会临时装一个记录器，用完必须复位（否则污染同进程里的其他用例）。
@visibleForTesting
Future<void> Function(ProgressMirrorCall call)? debugProgressMirrorSink;

/// 保存进度的**唯一出口**：先写会话自己的键，再（条件满足时）写一条镜像
///
/// # 写入顺序为什么是「先自己、后镜像」
///
/// 镜像那条是**补充**：万一它失败（键不合法 / 库里那条被别的东西锁住），
/// 会话自己的进度**已经落盘**了 => 用户最多是「本地和在线还没打通」，
/// 而不是「这次观看的进度整个丢了」。
///
/// # ★★ 镜像那条的 `episodeId`：**只写站点集 id，拿不到就整条跳过**
///
/// （CR-08 / CodeRabbit #8 改的正是这一节 —— 它原来写的是「恒为 null」）
///
/// ```
/// 本地会话手上的「集号」是**文件名**（lib/shell.dart:4830 传
///   req.episode.fileName，如 第01集 CR13.mp4），而在线侧比的是
///   **站点集 id**（如 51463）—— 二者必然不等。
/// ① 若把文件名写进镜像的 episode_id ⇒ 在线那条守卫
///    （lib/ui/player_page.dart:3390）判成「进度属于另一集」⇒ 拒绝续播 ⇒ 白写。
/// ② 若写 null（本轮修复前的做法）⇒ 两个方向都坏：
///    读侧 progressBelongsToCurrentEpisode 在 progressEpisodeId 为空时
///      返回 true ⇒ 本地第 1 集的进度被在线第 3 集用上；
///    写侧 store.rs:939 的 episode_id=excluded.episode_id **没有**守卫
///      ⇒ 把在线记录已有的集 ID 覆盖成 NULL。
/// ```
/// ⇒ 现在的契约：`originEpisodeId` **必须是站点集 id**；
///    拿不到（老下载 / 手拷进来的目录 / 旁文件里没记）就**整条镜像不写**。
///    「少写一条镜像」只是退化成今天的样子（本地和在线还没打通），
///    「写坏一条在线记录」是**数据损坏** —— 两者不对等，所以选前者。
///
/// # ★ 镜像为什么不带封面
///
/// 本地会话手上的封面是**盘上路径**（`lib/shell.dart:4827` 传的是
/// `w.localCoverPath ?? w.cover`）—— 把它写进在线记录，别的入口会拿一个
/// 本机路径当网络 URL 用。而 Rust 的 `upsert_progress` 对封面是
/// `COALESCE(excluded.cover, cover)` => 传 null 会**保留原记录已有的封面**，
/// 这正是想要的。
Future<void> saveProgressWithMirror({
  required String provider,
  required String id,
  required String title,
  String? cover,
  String? episodeId,
  String? episodeTitle,
  required int position,
  required int duration,
  bool? finished,
  ProgressOrigin? mirror,
  /*
   * ★★★ CR-08（CodeRabbit #8）：镜像那条的**站点集 id**。
   *
   * # 为什么不复用 episodeId
   * ```
   * 形参 episodeId 是**会话自己的集号**：本地会话里它是**文件名**
   *   （lib/shell.dart:4830 传 req.episode.fileName），在线会话里它是站点集 id。
   * 拿它当镜像的 episode_id ⇒ 本地会话必然写进一个文件名 ⇒ 在线那条
   *   「按集校验」（lib/ui/player_page.dart:3390）判成「另一集」⇒ 拒绝续播。
   * ⇒ 镜像那条**必须**另开一个口子，由调用方显式给**站点**集 id。
   * ```
   *
   * ⚠️ 默认 null = **不写镜像**（不是「写 null」）—— 见下面那段。
   */
  String? originEpisodeId,
}) async {
  await SourinApi.saveProgress(
    provider,
    id,
    title: title,
    cover: cover,
    episodeId: episodeId,
    episodeTitle: episodeTitle,
    position: position,
    duration: duration,
    finished: finished,
  );

  final target = mirror;
  if (target == null) return;

  // ★★★ CR-08 的安全修复：拿不到**站点集 id** ⇒ 整条镜像不写。
  //
  // 宁可「少写一条镜像」（退化成今天的样子：本地和在线还没打通），
  // 也不写 episode_id=null —— 后者在 store.rs:939 那里**没有**守卫，
  // 会把在线记录已有的集 ID 覆盖成 NULL（数据损坏，不可逆）。
  final siteEpisodeId = originEpisodeId?.trim() ?? '';
  if (siteEpisodeId.isEmpty) return;

  // ★★★ CR-07：镜像的 title 用**会话的作品标题**，集标题走 episodeTitle。
  //
  // 作品标题为空时同样不写：Rust 对空标题是「保留旧值」
  //   （store.rs:932-941 的 CASE WHEN excluded.title <> ''），
  //   写一条空标题只会白刷 updated_at，把「取更新的那条」判据带偏。
  final siteTitle = title.trim();
  if (siteTitle.isEmpty) return;

  // 集标题：优先会话的 episodeTitle，没有就退回文件名去后缀
  final mEpisodeTitle = mirrorProgressTitle(
    episodeTitle: episodeTitle ?? '',
    episodeFileName: episodeId ?? '',
  );
  // 连集标题都推不出来 => 不写（理由同上）
  if (mEpisodeTitle == null) return;

  final call = ProgressMirrorCall(
    provider: target.provider,
    mediaId: target.mediaId,
    // ★ 作品标题（不是集标题）—— CR-07
    title: siteTitle,
    position: position,
    duration: duration,
    finished: finished,
    // ★ 站点集 id（不是文件名、也不是 null）—— CR-08
    episodeId: siteEpisodeId,
    episodeTitle: mEpisodeTitle,
  );

  final sink = debugProgressMirrorSink;
  if (sink != null) {
    await sink(call);
    return;
  }
  await SourinApi.saveProgress(
    call.provider,
    call.mediaId,
    title: call.title,
    position: call.position,
    duration: call.duration,
    finished: call.finished,
    // ★ 站点集 id（见本节说明）—— 修复前这里是 call.episodeId = null
    episodeId: call.episodeId,
    // ★ 集标题终于有地方去了（修复前它被塞进了 title，覆盖掉作品标题）
    episodeTitle: call.episodeTitle,
  );
}
