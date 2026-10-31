// ═══════════════════════════════════════════════════════════════════════
//  T6 webHome：存储与控制器 —— 开关（UiPrefs）+ HTML 本体（独立文件）+ 缓存
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么 HTML 不放进 UiPrefs
// UiPrefs 是**单个 JSON 文件**的 kv（shell.dart:663 启动时整载），
// 塞 2MB 的 HTML 会让每次 flush 都重写它 —— HTML 落独立文件
// `<dataDir>/webhome/home.html`，UiPrefs 里只放开关与元信息。
//
// # 数据目录
// 对齐 shell.dart 的约定：桌面 = `%APPDATA%\app.sourin.player`（原版
// Tauri 同路径，用户数据接得上）。不 import shell（私有）；与
// ClipDownloader.dataDir 同形。测试用 debugSetDataDir 注入。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/app_log.dart';
import '../../core/ui_prefs.dart';
import 'fm_bridge.dart';

/// HTML 本体上限（设计书第五节）
const int webhomeHtmlMaxBytes = 2 * 1024 * 1024;

/// # 纯判据：一段 HTML 能不能作为 webHome 启用
/// 非空 + UTF-8 字节数在限内。不查内容（用户想写什么 HTML 是他的自由，
/// 安全边界在桥的白名单，不在内容审查）。
bool webhomeHtmlAcceptable(String html) {
  final t = html.trim();
  if (t.isEmpty) return false;
  return utf8.encode(t).length <= webhomeHtmlMaxBytes;
}

/// webHome 的 UiPrefs 键（v1：全局一个自定义首页，站点级是二期）
const String webhomeEnabledKey = 'webhome.enabled';

/// 控制器：home_page 的双模式开关订阅它。
class WebHomeController extends ChangeNotifier {
  WebHomeController._();

  static final WebHomeController instance = WebHomeController._();

  bool _loaded = false;
  bool _enabled = false;
  String _html = '';
  String? _htmlPath;
  bool _loading = false;

  /// 本次会话内 HTML 首页是否已回退（加载失败/白屏后置位；重启用时清）。
  bool fallbackThisSession = false;

  /// 最近一次自动回退的原因（给设置页/日志看）。
  String? lastFallbackReason;

  bool get enabled => _enabled;
  String get html => _html;
  String? get htmlPath => _htmlPath;

  /// 是否该显示 HTML 首页（build 判据，一处收口防散落）。
  bool get showWebHome =>
      _enabled && !fallbackThisSession && _html.trim().isNotEmpty;

  /// 启动后由 home_page 触发一次（幂等）。UiPrefs 已由 shell load 完。
  Future<void> ensureLoaded() async {
    if (_loaded || _loading) return;
    _loading = true;
    try {
      _enabled = UiPrefs.get(webhomeEnabledKey) == '1';
      final path = await _htmlFilePath();
      final f = File(path);
      if (await f.exists()) {
        _html = await f.readAsString();
        _htmlPath = path;
      }
      _loaded = true;
    } catch (e) {
      // 读失败按"未启用"处理 —— 绝不让首页因 webHome 存储坏了而白屏。
      AppLog.write('WEBHOME', 'ensureLoaded failed: $e');
      _enabled = false;
      _loaded = true;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// 保存 HTML 并启用（设置页「保存并启用」）。
  Future<bool> saveAndEnable(String html) async {
    if (!webhomeHtmlAcceptable(html)) return false;
    try {
      final path = await _htmlFilePath();
      final f = File(path);
      await f.parent.create(recursive: true);
      await f.writeAsString(html, flush: true);
      _htmlPath = path;
      _html = html;
      _enabled = true;
      fallbackThisSession = false;
      lastFallbackReason = null;
      UiPrefs.set(webhomeEnabledKey, '1');
      await UiPrefs.flush();
      notifyListeners();
      return true;
    } catch (e) {
      AppLog.write('WEBHOME', 'saveAndEnable failed: $e');
      return false;
    }
  }

  /// 停用（设置页「回到原生首页」）。HTML 保留，再启用不用重贴。
  Future<void> disable() async {
    _enabled = false;
    fallbackThisSession = false;
    UiPrefs.set(webhomeEnabledKey, '0');
    await UiPrefs.flush();
    notifyListeners();
  }

  /// HTML 首页加载失败 / 白屏超时 → 本次会话回退原生。
  /// ★ 不落盘（下次启动再给 HTML 一次机会），只挡住当前会话的循环失败。
  void reportLoadFailure(String reason) {
    if (fallbackThisSession) return;
    fallbackThisSession = true;
    lastFallbackReason = reason;
    AppLog.write('WEBHOME', 'fallback to native: $reason');
    notifyListeners();
  }

  /// 手动「回原生首页」（HTML 模式右上角按钮）：本次会话内不再上 HTML，
  /// 重启用或设置里再启用时清。与自动回退同一会话闸，原因分开记。
  void backToNativeForThisSession() {
    if (fallbackThisSession) return;
    fallbackThisSession = true;
    lastFallbackReason = 'user-request';
    notifyListeners();
  }

  Future<String> _htmlFilePath() async {
    final dir = await dataDir();
    return '$dir${Platform.pathSeparator}webhome${Platform.pathSeparator}home.html';
  }

  // ── 数据目录（与 shell.dart 对齐；测试可注入）──
  static String? _dataDirOverride;

  /// 测试用：注入固定数据目录（null = 恢复自动解析）
  @visibleForTesting
  static void debugSetDataDir(String? dir) => _dataDirOverride = dir;

  static Future<String> dataDir() async {
    final override = _dataDirOverride;
    if (override != null) return override;
    if (!kIsWeb && Platform.isWindows) {
      final appdata = Platform.environment['APPDATA'] ??
          Platform.environment['HOME'] ??
          '.';
      final dir = Directory('$appdata${Platform.pathSeparator}app.sourin.player');
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir.path;
    }
    // 非 Windows（Android/iOS/其它桌面）：V1 只承诺 Windows 桌面；
    // 其它平台用应用私有目录，行为一致。
    final d = await getApplicationSupportDirectory();
    if (!await d.exists()) await d.create(recursive: true);
    return d.path;
  }
}

/// # fm.cache 的宿主实现（V1：单命名空间 JSON 文件 + 5MB 配额）
///
/// 文件：`<dataDir>/webhome/cache.json`，内存映射 + flush 落盘。
/// 配额判据在 [cacheWriteAllowed]（纯函数，门禁覆盖）；
/// 超限 [set] 返回 false，页面拿到 `{ok: false}` —— 静默丢弃不行
/// （批次纪律：静默失败 = 缺陷）。
class WebHomeCache {
  WebHomeCache._();

  static final WebHomeCache instance = WebHomeCache._();

  static String? _fileOverride;

  /// 测试用：注入固定 cache 文件路径（null = 恢复自动解析）
  @visibleForTesting
  static void debugSetFile(String? path) => _fileOverride = path;

  final Map<String, String> _map = {};
  bool _loaded = false;
  bool _dirty = false;

  Future<String> get _path async {
    final override = _fileOverride;
    if (override != null) return override;
    final dir = await WebHomeController.dataDir();
    return '$dir${Platform.pathSeparator}webhome${Platform.pathSeparator}cache.json';
  }

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = File(await _path);
      if (await f.exists()) {
        final raw = await f.readAsString();
        if (raw.trim().isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            decoded.forEach((k, v) {
              if (k is String && v is String) _map[k] = v;
            });
          }
        }
      }
    } catch (e) {
      AppLog.write('WEBHOME', 'cache load failed (start empty): $e');
    }
  }

  Future<Object?> get(String key) async {
    await ensureLoaded();
    return _map[key];
  }

  Future<bool> set(String key, String value) async {
    await ensureLoaded();
    final incoming = utf8.encode(key).length + utf8.encode(value).length;
    final current = _map.keys
        .map((k) => utf8.encode(k).length + utf8.encode(_map[k]!).length)
        .fold(0, (a, b) => a + b);
    // 同 key 覆盖时旧值让位
    final replaced = _map[key];
    final replacedBytes = replaced == null
        ? 0
        : utf8.encode(key).length + utf8.encode(replaced).length;
    if (!cacheWriteAllowed(
        current - replacedBytes, incoming, webhomeCacheQuotaBytes)) {
      return false;
    }
    _map[key] = value;
    _dirty = true;
    await _flush();
    return true;
  }

  Future<void> del(String key) async {
    await ensureLoaded();
    if (_map.remove(key) != null) {
      _dirty = true;
      await _flush();
    }
  }

  Future<void> _flush() async {
    if (!_dirty) return;
    try {
      final f = File(await _path);
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(_map), flush: true);
      _dirty = false;
    } catch (e) {
      AppLog.write('WEBHOME', 'cache flush failed: $e');
    }
  }
}
