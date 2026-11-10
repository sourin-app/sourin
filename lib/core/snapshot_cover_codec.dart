import 'dart:async';

import 'disk_cache.dart';
import 'sourin_api.dart';

/// Projects only cover fields in detached home/shelf JSON snapshots.
/// Live display models and all other snapshot metadata remain untouched.
abstract final class SnapshotCoverCodec {
  static final _httpScheme = RegExp(r'^https?:', caseSensitive: false);

  static Future<Map<String, dynamic>> homeToDurable(
    Map<String, dynamic> snapshot,
  ) => _home(snapshot, durable: true);

  static Future<Map<String, dynamic>> homeToDisplay(
    Map<String, dynamic> snapshot,
  ) => _home(snapshot, durable: false);

  static Future<Map<String, dynamic>> shelfToDurable(
    Map<String, dynamic> snapshot,
  ) => _shelf(snapshot, durable: true);

  static Future<Map<String, dynamic>> shelfToDisplay(
    Map<String, dynamic> snapshot,
  ) => _shelf(snapshot, durable: false);

  static Map<String, dynamic> copy(Map<String, dynamic> snapshot) =>
      _copy(snapshot) as Map<String, dynamic>;

  static Object? _copy(Object? value) {
    if (value is Map) {
      return <String, dynamic>{
        for (final entry in value.entries)
          entry.key as String: _copy(entry.value),
      };
    }
    if (value is List) return [for (final entry in value) _copy(entry)];
    return value;
  }

  static Future<Map<String, dynamic>> _home(
    Map<String, dynamic> snapshot, {
    required bool durable,
  }) async {
    final data = copy(snapshot);
    final covers = <_SnapshotCover>[];
    final groups = data['groups'];
    if (groups is List) {
      for (final group in groups) {
        if (group is! Map<String, dynamic>) continue;
        final provider = group['provider'] is String
            ? group['provider'] as String
            : '';
        final sections = group['sections'];
        if (sections is! List) continue;
        for (final section in sections) {
          if (section is Map<String, dynamic>) {
            _homeItems(covers, section['items'], provider);
          }
        }
      }
    }
    final items = data['items'];
    if (items is Map<String, dynamic>) {
      for (final entry in items.entries) {
        final separator = entry.key.indexOf('::');
        final provider = separator < 0
            ? ''
            : entry.key.substring(0, separator);
        _homeItems(covers, entry.value, provider);
      }
    }
    await _convert(covers, durable: durable);
    return data;
  }

  static void _homeItems(
    List<_SnapshotCover> covers,
    Object? items,
    String provider,
  ) {
    if (items is! List) return;
    for (final item in items) {
      if (item is! Map<String, dynamic>) continue;
      final fullId = item['id'] is String ? item['id'] as String : '';
      // Match Home's detail routing: split the full ID once. The remainder is
      // opaque, so child::native identifiers must never be split a second time.
      final separator = fullId.indexOf(':');
      covers.add(_SnapshotCover(
        item,
        separator < 0
            ? (item['provider'] is String ? item['provider'] as String : provider)
            : fullId.substring(0, separator),
        separator < 0 ? fullId : fullId.substring(separator + 1),
      ));
    }
  }

  static Future<Map<String, dynamic>> _shelf(
    Map<String, dynamic> snapshot, {
    required bool durable,
  }) async {
    final data = copy(snapshot);
    final covers = <_SnapshotCover>[];
    for (final lane in const ['favorites', 'following', 'history']) {
      final items = data[lane];
      if (items is! List) continue;
      for (final item in items) {
        if (item is! Map<String, dynamic>) continue;
        covers.add(_SnapshotCover(
          item,
          item['provider'] is String ? item['provider'] as String : '',
          item['native_id'] is String ? item['native_id'] as String : '',
        ));
      }
    }
    await _convert(covers, durable: durable);
    return data;
  }

  static Future<void> _convert(
    List<_SnapshotCover> covers, {
    required bool durable,
  }) async {
    for (var offset = 0; offset < covers.length;
        offset += SourinApi.snapshotCoverBatchLimit) {
      final end = offset + SourinApi.snapshotCoverBatchLimit;
      final batch = covers.sublist(
        offset,
        end < covers.length ? end : covers.length,
      );
      final requested = [for (final cover in batch) cover.request];
      List<SnapshotCoverItem>? converted;
      try {
        converted = await (durable
            ? SourinApi.coversToDurable(requested)
            : SourinApi.coversToDisplay(requested));
      } catch (_) {
        // A failed/malformed batch keeps cards and metadata. Values and native
        // errors can contain headers/tokens, so no response is logged here.
      }
      for (var index = 0; index < batch.length; index++) {
        final original = requested[index].cover;
        final result = converted?[index].cover;
        final cover = converted == null
            ? _fallback(original, durable: durable)
            : _checked(result, durable: durable);
        // Preserve the original absent-key shape for records with no cover.
        if (cover != null || batch[index].json.containsKey('cover')) {
          batch[index].json['cover'] = cover;
        }
      }
    }
  }

  static bool _http(String value) =>
      _httpScheme.hasMatch(value) || value.startsWith('//');

  static bool _internal(String value) {
    final url = Uri.tryParse(value);
    if (url == null ||
        url.scheme != 'http' ||
        url.host != '127.0.0.1' ||
        !url.hasPort ||
        !url.path.startsWith('/s/')) {
      return false;
    }
    final token = url.path.substring(3);
    return token.isNotEmpty && !token.contains('/');
  }

  static String? _checked(String? value, {required bool durable}) {
    if (value == null || value.trim().isEmpty) return null;
    final cover = value.trim();
    if (durable) return _internal(cover) ? null : cover;
    return _http(cover) && !_internal(cover) ? null : cover;
  }

  static String? _fallback(String? value, {required bool durable}) {
    if (value == null || value.trim().isEmpty) return null;
    final cover = value.trim();
    if (durable) return _internal(cover) ? null : cover;
    // Without native registration, no HTTP image can bypass the global policy.
    return _http(cover) ? null : cover;
  }
}

class _SnapshotCover {
  const _SnapshotCover(this.json, this.provider, this.id);

  final Map<String, dynamic> json;
  final String provider;
  final String id;

  SnapshotCoverItem get request => SnapshotCoverItem(
    provider: provider,
    id: id,
    cover: json['cover'] is String ? json['cover'] as String : null,
  );
}

/// Serialize conversion and publication per actual snapshot file, including
/// writes from separate HomeListCache/MyShelf instances. Capture data now, before
/// waiting for an older write, and discard work if its data directory changes.
abstract final class SnapshotCacheWrites {
  static final _pending = <(String, String), Future<void>>{};

  static Future<void> run({
    required String name,
    required Map<String, dynamic> snapshot,
    required Future<Map<String, dynamic>> Function(Map<String, dynamic>) convert,
    required Future<bool> Function(Map<String, dynamic>) write,
  }) {
    final directory = DiskCache.dataDir;
    if (directory == null || directory.isEmpty) return Future<void>.value();
    final captured = SnapshotCoverCodec.copy(snapshot);
    final key = (directory, name);
    final previous = _pending[key] ?? Future<void>.value();
    final pending = previous.then((_) async {
      if (DiskCache.dataDir != directory) return;
      final converted = await convert(captured);
      if (DiskCache.dataDir != directory) return;
      await write(converted);
    }).catchError((Object _) {
      // Cache failure must remain nonfatal, and must not block later writes.
    });
    _pending[key] = pending;
    unawaited(pending.then((_) {
      if (identical(_pending[key], pending)) _pending.remove(key);
    }));
    return pending;
  }
}
