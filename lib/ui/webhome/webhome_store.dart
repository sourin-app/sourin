// ═══════════════════════════════════════════════════════════════════════
//  T6 webHome：存储与控制器 —— 命名首页目录 + 独立 HTML 本体 + 缓存
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么 HTML 不放进 UiPrefs
// UiPrefs 是**单个 JSON 文件**的 kv（shell.dart:663 启动时整载），
// 塞 2MB 的 HTML 会让每次 flush 都重写它 —— HTML 落独立文件
// `<dataDir>/webhome/`；library.json 管理命名模板，旧 home.html 原样保留。
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

/// Legacy preference; the v2 library is authoritative after migration.
const String webhomeEnabledKey = 'webhome.enabled';

class WebHomeTemplate {
  const WebHomeTemplate({
    required this.id,
    required this.name,
    required this.file,
  });

  final String id;
  final String name;
  final String file;

  Map<String, String> toJson() => {'id': id, 'name': name, 'file': file};
}

/// 控制器：home_page 的双模式开关订阅它。
class WebHomeController extends ChangeNotifier {
  WebHomeController._();

  static final WebHomeController instance = WebHomeController._();

  bool _loaded = false;
  bool _enabled = false;
  String _html = '';
  String? _htmlPath;
  Future<void>? _loadFuture;
  Future<void> _writes = Future<void>.value();
  List<WebHomeTemplate> _templates = [];
  String? _activeId;
  bool _loadFailed = false;
  String? lastStorageError;

  /// 本次会话内 HTML 首页是否已回退（加载失败/白屏后置位；重启用时清）。
  bool fallbackThisSession = false;

  /// 最近一次自动回退的原因（给设置页/日志看）。
  String? lastFallbackReason;

  bool get enabled => _enabled;
  String get html => _html;
  String? get htmlPath => _htmlPath;
  String? get activeId => _activeId;
  List<WebHomeTemplate> get templates => List.unmodifiable(_templates);

  /// 是否该显示 HTML 首页（build 判据，一处收口防散落）。
  bool get showWebHome =>
      _enabled && !fallbackThisSession && _html.trim().isNotEmpty;

  /// 启动后由 home_page 触发一次（幂等）。UiPrefs 已由 shell load 完。
  Future<void> ensureLoaded() {
    if (_loaded) return Future<void>.value();
    return _loadFuture ??= _load().whenComplete(() => _loadFuture = null);
  }

  Future<void> reload() => _serialize(() async {
    if (_loadFuture != null) await _loadFuture;
    _loaded = false;
    await ensureLoaded();
  });

  Future<String> _homeDir() async =>
      '${await dataDir()}${Platform.pathSeparator}webhome';

  Future<void> _load() async {
    _templates = [];
    _activeId = null;
    _enabled = false;
    _html = '';
    _htmlPath = null;
    fallbackThisSession = false;
    lastFallbackReason = null;
    lastStorageError = null;
    _loadFailed = false;
    try {
      final dir = await _homeDir();
      final catalog = File('$dir${Platform.pathSeparator}library.json');
      if (await catalog.exists()) {
        final value = jsonDecode(await catalog.readAsString());
        if (value is! Map || value['version'] != 2 || value['items'] is! List) {
          throw const FormatException('Invalid home library');
        }
        final ids = <String>{};
        for (final row in value['items'] as List) {
          if (row is! Map ||
              row['id'] is! String ||
              row['name'] is! String ||
              row['file'] is! String ||
              !RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(row['id'] as String) ||
              !RegExp(r'^[a-zA-Z0-9_-]+\.html$')
                  .hasMatch(row['file'] as String) ||
              (row['name'] as String).trim().isEmpty ||
              !ids.add(row['id'] as String)) {
            throw const FormatException('Invalid home template');
          }
          _templates.add(
            WebHomeTemplate(
              id: row['id'] as String,
              name: row['name'] as String,
              file: row['file'] as String,
            ),
          );
        }
        _activeId = value['activeId'] is String
            ? value['activeId'] as String
            : null;
        _enabled = value['enabled'] == true && ids.contains(_activeId);
        if (_activeId != null && !ids.contains(_activeId)) _activeId = null;
        if (_activeId != null) {
          _htmlPath =
              '$dir${Platform.pathSeparator}'
              '${_templates.firstWhere((t) => t.id == _activeId).file}';
          try {
            _html = await readTemplate(_activeId!);
          } catch (e) {
            AppLog.write('WEBHOME', 'active template unreadable: $e');
            fallbackThisSession = true;
            lastFallbackReason = 'template-unreadable';
            lastStorageError = '当前首页文件读取失败，已使用原生首页；可编辑修复或切换配置';
          }
        }
      } else {
        final legacy = File('$dir${Platform.pathSeparator}home.html');
        if (await legacy.exists()) {
          if (await legacy.length() > webhomeHtmlMaxBytes) {
            throw const FormatException('Legacy home exceeds limit');
          }
          final html = await legacy.readAsString();
          if (webhomeHtmlAcceptable(html)) {
            final enabled = UiPrefs.get(webhomeEnabledKey) == '1';
            final entry = WebHomeTemplate(
              id: 'legacy',
              name: '默认首页',
              file: 'legacy-${_revision()}.html',
            );
            final body = File('$dir${Platform.pathSeparator}${entry.file}');
            await _writeAtomic(body, html);
            try {
              await _commit([entry], entry.id, enabled, html);
            } catch (_) {
              await body.delete();
              rethrow;
            }
          }
        }
      }
    } catch (e) {
      AppLog.write('WEBHOME', 'ensureLoaded failed: $e');
      _enabled = false;
      _loadFailed = true;
      lastStorageError = '首页配置读取失败，已使用原生首页；原文件已保留';
    } finally {
      _loaded = true;
      notifyListeners();
    }
  }

  String _revision() => DateTime.now().microsecondsSinceEpoch.toString();

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _writes.then((_) => action());
    _writes = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<String> readTemplate(String id) async {
    final entry = _templates.firstWhere((t) => t.id == id);
    final body = File(
      '${await _homeDir()}${Platform.pathSeparator}${entry.file}',
    );
    if (await body.length() > webhomeHtmlMaxBytes) {
      throw const FormatException('Home template exceeds limit');
    }
    final html = await body.readAsString();
    if (!webhomeHtmlAcceptable(html)) {
      throw const FormatException('Empty home template');
    }
    return html;
  }

  Future<void> _writeAtomic(File target, String value) async {
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.${_revision()}.tmp');
    try {
      await temporary.writeAsString(value, flush: true);
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> _commit(
    List<WebHomeTemplate> entries,
    String? active,
    bool enabled,
    String html, {
    bool resetFallback = false,
  }) async {
    final dir = await _homeDir();
    await _writeAtomic(
      File('$dir${Platform.pathSeparator}library.json'),
      jsonEncode({
        'version': 2,
        'items': entries.map((t) => t.toJson()).toList(),
        'activeId': active,
        'enabled': enabled,
      }),
    );
    _templates = entries;
    _activeId = active;
    _enabled = enabled;
    _html = html;
    _htmlPath = active == null
        ? null
        : '$dir${Platform.pathSeparator}${entries.firstWhere((t) => t.id == active).file}';
    if (resetFallback) {
      fallbackThisSession = false;
      lastFallbackReason = null;
    }
    lastStorageError = null;
    // The library is committed; legacy preferences must never roll it back.
    try {
      UiPrefs.set(webhomeEnabledKey, enabled ? '1' : '0');
      await UiPrefs.flush();
    } catch (e) {
      AppLog.write('WEBHOME', 'legacy preference sync failed: $e');
    }
    notifyListeners();
  }

  Future<WebHomeTemplate?> saveTemplate({
    String? id,
    required String name,
    required String html,
    bool activate = false,
  }) => _serialize(() async {
    await ensureLoaded();
    if (_loadFailed) return null;
    if (name.trim().isEmpty ||
        name.trim().length > 128 ||
        !webhomeHtmlAcceptable(html)) {
      return null;
    }
    File? newBody;
    try {
      final old = _templates.where((t) => t.id == id).firstOrNull;
      if (id != null && old == null) return null;
      final nextId = old?.id ?? 'home-${_revision()}';
      final entry = WebHomeTemplate(
        id: nextId,
        name: name.trim(),
        file: '$nextId-${_revision()}.html',
      );
      newBody = File(
        '${await _homeDir()}${Platform.pathSeparator}${entry.file}',
      );
      await _writeAtomic(newBody, html);
      final entries = [
        for (final t in _templates)
          if (t.id == nextId) entry else t,
        if (old == null) entry,
      ];
      final active = activate ? nextId : _activeId;
      await _commit(
        entries,
        active,
        activate || _enabled,
        active == nextId ? html : _html,
        resetFallback: activate || active == nextId,
      );
      newBody = null;
      if (old != null) await _removeBody(old);
      return entry;
    } catch (e) {
      if (newBody != null && await newBody.exists()) await newBody.delete();
      AppLog.write('WEBHOME', 'save template failed: $e');
      lastStorageError = '保存失败，原配置已保留';
      notifyListeners();
      return null;
    }
  });

  Future<bool> activateTemplate(String id) => _serialize(() async {
    await ensureLoaded();
    if (_loadFailed) return false;
    try {
      final html = await readTemplate(id);
      await _commit([..._templates], id, true, html, resetFallback: true);
      return true;
    } catch (e) {
      AppLog.write('WEBHOME', 'activate template failed: $e');
      lastStorageError = '启用失败，原配置已保留';
      notifyListeners();
      return false;
    }
  });

  Future<bool> deleteTemplate(String id) => _serialize(() async {
    await ensureLoaded();
    if (_loadFailed) return false;
    final old = _templates.where((t) => t.id == id).firstOrNull;
    if (old == null) return false;
    try {
      final active = _activeId == id ? null : _activeId;
      await _commit(
        _templates.where((t) => t.id != id).toList(),
        active,
        active != null && _enabled,
        active == null ? '' : _html,
        resetFallback: _activeId == id,
      );
      await _removeBody(old);
      return true;
    } catch (e) {
      AppLog.write('WEBHOME', 'delete template failed: $e');
      lastStorageError = '删除失败，请稍后重试';
      notifyListeners();
      return false;
    }
  });

  Future<void> _removeBody(WebHomeTemplate entry) async {
    try {
      final file = File(
        '${await _homeDir()}${Platform.pathSeparator}${entry.file}',
      );
      if (await file.exists()) await file.delete();
    } catch (e) {
      // A committed library is valid even if an obsolete body cannot be removed.
      AppLog.write('WEBHOME', 'obsolete template cleanup failed: $e');
    }
  }

  Future<bool> saveAndEnable(String html) async {
    await ensureLoaded();
    return await saveTemplate(
          id: _activeId,
          name:
              _templates.where((t) => t.id == _activeId).firstOrNull?.name ??
              '默认首页',
          html: html,
          activate: true,
        ) !=
        null;
  }

  Future<void> disable() => _serialize(() async {
    await ensureLoaded();
    if (_loadFailed) return;
    await _commit(
      [..._templates],
      _activeId,
      false,
      _html,
      resetFallback: true,
    );
  });

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

  // ── 数据目录（与 shell.dart 对齐；测试可注入）──
  static String? _dataDirOverride;

  /// 测试用：注入固定数据目录（null = 恢复自动解析）
  @visibleForTesting
  static void debugSetDataDir(String? dir) => _dataDirOverride = dir;

  static Future<String> dataDir() async {
    final override = _dataDirOverride;
    if (override != null) return override;
    if (!kIsWeb && Platform.isWindows) {
      final appdata =
          Platform.environment['APPDATA'] ??
          Platform.environment['HOME'] ??
          '.';
      final dir = Directory(
        '$appdata${Platform.pathSeparator}app.sourin.player',
      );
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
      current - replacedBytes,
      incoming,
      webhomeCacheQuotaBytes,
    )) {
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
