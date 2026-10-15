// ═══════════════════════════════════════════════════════════════════════
//  磁盘 JSON 快照缓存 —— 让「重启后还是秒开」成立
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要它（Owner 原话）
//
// ```text
// > 我希望这个页面的数据可以缓存,而不是每次打开都是彻底的请求重载,
// > 太影响观感,可以缓存然后异步
// > （追加）对的,我就是希望持久化的,而不是重启软件就没了
// > （再追加）不限制时间,可以启动后异步刷新替换,切换源检测时间对比 然后再替换
// ```
//
// task-11 已经做了**进程内**的 stale-while-revalidate（见 ui/home_page.dart
// 的 HomeListCache）—— 切源秒开、后台异步刷新都有。但它**只活在内存里**：
// 重启软件 ⇒ 缓存全空 ⇒ 又变成冷加载（正是 Owner 抱怨的那件事）。
// 本文件补的就是那一半：把快照写到数据目录，启动时读回来预热。
//
// # ★ 不设过期时间（Owner 明确要求「不限制时间」）
//
// ```text
// 读侧**只看有没有、坏没坏、版本对不对** —— 绝不因为「存了多久」而丢弃。
// 新鲜度由**调用方**用时间戳自己判（见 CacheEntry.at）：
//   够新 → 一个请求都不发
//   旧了 → 先把缓存画出来，再异步拉新的替换
// ```
// ⚠️ 这与 task-11 的 kHomeCacheTtl（10 分钟）**不是**一个东西：那个管
//    「内存里这份还算不算数」，本文件不做这件事（做的话就违背 Owner 的要求）。
//
// # 数据目录从哪来
//
// 复用 shell 的 _resolveDataDir() 结果（由 shell 调 [DiskCache.init] 注入）：
// ```text
// Windows → %APPDATA%\app.sourin.player
// Android → 应用私有目录（沙箱）
// ```
// ⇒ **一套代码两个平台都生效**，不需要分平台写。
// ⚠️ 也正因如此，DATA_DIR_OVERRIDE（开发/探针隔离）自动跟着生效 ——
//    探针跑在隔离目录里，**碰不到用户的真实数据**。
//
// # 存的是「后端原始 JSON」而不是模型对象
//
// 这是本文件最重要的一条设计决定。
// ```text
// 存盘：callAsync('get_home') 的原始 JSON  ──写──▶  home-cache.json
// 读回：home-cache.json  ──▶ ProviderGroup.fromJson（现成的，一行不改）
// ```
// 好处：绕开**整类字段名漂移**。本项目栽过这个跟头 ——
// `MediaItem.note` 的真实来源是后端的 `subtitle`，键名不匹配导致
// **6 处界面**的副标题恒为空且不报错（见 core/models.dart:485 那段）。
// 走原始 JSON ⇒ 以后模型加字段，缓存自动跟上，不需要维护第二套映射。
//
// # 坏文件绝不致命
//
// 缓存是**纯优化**：任何异常（文件损坏、权限不足、磁盘满、版本不符）
// 都降级成「没有缓存」⇒ 走原来的冷加载路径。
// ★ 绝不让缓存问题变成「应用起不来」——那是把优化做成了故障。

import 'dart:convert';
import 'dart:io';

/// 缓存文件的**格式版本**
///
/// ★ 什么时候必须 +1：**写入结构变了**（不是数据变了）。
///   例：以后决定把 at 换成别的时间源、或加一层信封字段。
///   ⇒ 旧文件会被 [DiskCache.read] 判为版本不符而忽略（不删、不报错），
///     下次写入自然覆盖成新格式。
const int kDiskCacheVersion = 1;

/// 一份读回来的快照
class CacheEntry {
  CacheEntry({required this.data, required this.at});

  /// 存进去的原样 JSON（调用方自己喂给对应的 fromJson）
  final Object? data;

  /// **存入时刻**（不是「读取时刻」）
  ///
  /// ★ 调用方拿它判新鲜度（Owner：「切换源检测时间对比 然后再替换」）：
  ///   `DateTime.now().difference(at) <= 某个窗口` ⇒ 连后台刷新都不必发。
  final DateTime at;

  /// 存了多久（探针/日志用）
  Duration ageFrom(DateTime now) => now.difference(at);
}

/// 磁盘快照缓存（静态类 —— 与 UiPrefs 同款用法）
///
/// ⚠️ 不依赖 Flutter（只用 dart:io / dart:convert）⇒ 可以直接单测，
///    不需要 flutter_test 的 binding。
class DiskCache {
  DiskCache._();

  static String? _dir;

  /// 数据目录是否已就绪
  static bool get ready => _dir != null;

  /// 测试/探针读数：当前数据目录
  static String? get dataDir => _dir;

  /// 注入数据目录（由 shell 在 _resolveDataDir 之后调一次）
  ///
  /// ⚠️ 幂等：重复调用只是覆盖同一个值。
  static void init(String dataDir) {
    _dir = dataDir;
  }

  /// 测试专用：重置（不碰磁盘）
  static void debugResetForTest([String? dir]) {
    _dir = dir;
  }

  static File? _fileOf(String name) {
    final d = _dir;
    if (d == null || d.isEmpty) return null;
    return File('$d${Platform.pathSeparator}$name');
  }

  /// 读一份快照
  ///
  /// # 返回 null 的全部情形（一律降级，不抛）
  /// ```text
  /// · 数据目录还没就绪（init 没调）
  /// · 文件不存在（第一次跑）
  /// · 文件读失败（权限/被占用）
  /// · JSON 解析失败（写到一半断电 ⇒ 半个文件）
  /// · 不是本类写的信封（缺 v / 缺 data）
  /// · 版本不符（格式改过）
  /// ```
  /// ★ **不因「存了多久」返回 null** —— 见文件头「不设过期时间」。
  static Future<CacheEntry?> read(String name) async {
    final f = _fileOf(name);
    if (f == null) return null;
    try {
      if (!await f.exists()) return null;
      final txt = await f.readAsString();
      final m = jsonDecode(txt);
      if (m is! Map) return null;
      final v = (m['v'] as num?)?.toInt();
      if (v != kDiskCacheVersion) return null;
      final atMs = (m['at'] as num?)?.toInt();
      if (atMs == null) return null;
      return CacheEntry(
        data: m['data'],
        at: DateTime.fromMillisecondsSinceEpoch(atMs),
      );
    } catch (e) {
      // ★ 缓存坏了是小事 —— 如实记一行，然后当作没有缓存继续跑
      debugLog('读 $name 失败（当作无缓存）: $e');
      return null;
    }
  }

  /// 写一份快照（原子替换：先写 .tmp 再 rename）
  ///
  /// # 为什么要原子写
  /// ```text
  /// 直接 writeAsString：写到一半崩溃/断电 ⇒ 盘上留**半个 JSON**
  ///   ⇒ 下次启动解析失败 ⇒ 降级成无缓存（虽然不崩，但白丢一份好数据）
  /// rename 同卷原子 ⇒ 要么完整的新文件、要么完整的旧文件
  /// ```
  /// ⚠️ 失败**不抛**（缓存写不进去不该影响任何功能），只记日志。
  ///    返回 true/false 是给探针和门禁看的。
  static Future<bool> write(
    String name,
    Object? data, {
    DateTime? at,
  }) async {
    final f = _fileOf(name);
    if (f == null) return false;
    final now = at ?? DateTime.now();
    try {
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(
        jsonEncode(<String, Object?>{
          'v': kDiskCacheVersion,
          'at': now.millisecondsSinceEpoch,
          'data': data,
        }),
        flush: true,
      );
      await _replace(tmp, f, name: name);
      return true;
    } catch (e) {
      debugLog('写 $name 失败（不影响功能）: $e');
      return false;
    }
  }

  /// 删掉一份快照（设置页「清缓存」/ 指纹作废时用）
  static Future<void> remove(String name) async {
    final f = _fileOf(name);
    if (f == null) return;
    try {
      if (await f.exists()) await f.delete();
    } catch (e) {
      debugLog('删 $name 失败: $e');
    }
  }

  /// 原子替换的退避序列（毫秒）—— 抄自 download_queue.dart 的实测依据
  ///
  /// 真实占用者都是**短命**的：杀软实时扫描刚写出的文件（几十毫秒）、
  /// 并发读同一份 JSON（微秒级）。440ms 足够覆盖，又不会让用户可感地卡。
  static const List<int> _backoffMs = <int>[20, 50, 120, 250];

  /// 把 [tmp] 换成 [target]
  ///
  /// # 为什么要重试 + 兜底（不是过度设计）
  /// Windows 上 rename 到**已存在且被别的句柄打开**的目标会抛
  /// `PathAccessException (errno = 5)` —— 而占用者常常是我们自己
  /// （另一个 isolate 正在读同一份缓存）或系统（杀软）。
  /// 只 rename 一次 + 一个吞异常的 catch ⇒ 概率性丢掉整份新缓存。
  ///
  /// 三级处理（与 download_queue._atomicReplaceWith 同款）：
  /// ```text
  /// ① rename，失败退避重试
  /// ② 兜底：原地覆盖写（放弃原子性，但不丢数据）
  /// ③ 都失败 ⇒ 记日志 + 清掉 tmp，不在用户目录留垃圾
  /// ```
  static Future<bool> _replace(File tmp, File target,
      {required String name}) async {
    Object? renameErr;
    for (var attempt = 0; attempt <= _backoffMs.length; attempt++) {
      try {
        await tmp.rename(target.path);
        return true;
      } catch (e) {
        renameErr = e;
        if (attempt < _backoffMs.length) {
          await Future<void>.delayed(
              Duration(milliseconds: _backoffMs[attempt]));
        }
      }
    }
    try {
      final bytes = await tmp.readAsBytes();
      final raf = await target.open(mode: FileMode.write);
      try {
        await raf.writeFrom(bytes);
        await raf.flush();
      } finally {
        await raf.close();
      }
      await _tryDelete(tmp);
      debugLog('$name 原子替换退化为原地写（rename 被占用）: $renameErr');
      return true;
    } catch (e) {
      debugLog('$name 写入彻底失败: rename=$renameErr fallback=$e');
      await _tryDelete(tmp);
      return false;
    }
  }

  static Future<void> _tryDelete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {
      // 清不掉就算了 —— 一个 .tmp 残留不值得再报一次错
    }
  }
}

/// 轻量日志（本文件不依赖 Flutter，所以用 print）
void debugLog(String msg) {
  // ignore: avoid_print
  print('[DISK-CACHE] $msg');
}