import 'dart:async';

import 'package:flutter/foundation.dart';

import 'ffi.dart';

class DiscoveredSource {
  DiscoveredSource(Map<String, dynamic> json)
    : id = json['id'] as String? ?? '',
      name = json['name'] as String? ?? '',
      repository = json['repository'] as String? ?? '',
      status = json['status'] as String? ?? '',
      message = json['message'] as String? ?? '',
      providerId = json['providerId'] as String?,
      installed = json['installed'] == true,
      checkedAt = json['checkedAt'] as int? ?? 0;
  final String id, name, repository, status, message;
  final String? providerId;
  final int checkedAt;
  final bool installed;
  bool get canEnable => status == 'ready' && !installed;
}

class DiscoveryNotice {
  DiscoveryNotice(Map<String, dynamic> json)
    : text = json['text'] as String? ?? '',
      unread = json['unread'] == true,
      at = json['at'] as int? ?? 0;
  final String text;
  final bool unread;
  final int at;
}

class DiscoverySnapshot {
  DiscoverySnapshot(Map<String, dynamic> json)
    : proxyUrl = json['proxyUrl'] as String? ?? '',
      automatic = json['automatic'] == true,
      running = json['running'] == true,
      lastError = json['lastError'] as String? ?? '',
      lastScan = json['lastScan'] as int? ?? 0,
      candidates = (json['candidates'] as List? ?? [])
          .map((e) => DiscoveredSource(Map<String, dynamic>.from(e as Map)))
          .toList(),
      notices = (json['notices'] as List? ?? [])
          .map((e) => DiscoveryNotice(Map<String, dynamic>.from(e as Map)))
          .toList();
  final String proxyUrl, lastError;
  final bool automatic, running;
  final int lastScan;
  final List<DiscoveredSource> candidates;
  final List<DiscoveryNotice> notices;
  int get unread => notices.where((n) => n.unread).length;
}

abstract final class SourceDiscoveryService {
  static final current = ValueNotifier<DiscoverySnapshot?>(null);
  static Future<DiscoverySnapshot>? _pending;
  static Future<void>? _updates;
  static int _revision = 0;
  static Future<DiscoverySnapshot> _call(
    String command, [
    Map<String, dynamic>? args,
  ]) async {
    final response = await SourinCore.callAsync(command, args);
    return DiscoverySnapshot(
      Map<String, dynamic>.from(response as Map),
    );
  }

  static Future<DiscoverySnapshot> refresh() {
    if (_pending != null) return _pending!;
    final revision = _revision;
    late final Future<DiscoverySnapshot> request;
    request = _call('source_discovery_status').then((snapshot) {
      if (revision == _revision) current.value = snapshot;
      return current.value ?? snapshot;
    }).whenComplete(() {
      if (identical(_pending, request)) _pending = null;
    });
    _pending = request;
    return request;
  }

  static void _invalidateReads() {
    _revision++;
    _pending = null;
  }

  static Future<DiscoverySnapshot> _update(
    String command, [
    Map<String, dynamic>? args,
  ]) {
    // Reads issued before an action, or while it is still running, must not
    // undo the result when their responses arrive after the action completes.
    _invalidateReads();
    final update = (_updates ?? Future<void>.value()).then((_) async {
      // A new page can submit while a disposed page's action is outstanding.
      // Order the actual commands so persisted state follows the user's order.
      _invalidateReads();
      try {
        final snapshot = await _call(command, args);
        current.value = snapshot;
        return snapshot;
      } finally {
        _invalidateReads();
      }
    });
    late final Future<void> pending;
    void release() {
      if (identical(_updates, pending)) _updates = null;
    }
    pending = update.then<void>((_) => release(), onError: (Object _) => release());
    _updates = pending;
    return update;
  }

  static Future<DiscoverySnapshot> configure(bool automatic) =>
      _update('source_discovery_configure', {'automatic': automatic});
  static Future<DiscoverySnapshot> scan() => _update('source_discovery_scan');
  static Future<DiscoverySnapshot> enable(String id) =>
      _update('source_discovery_enable', {'id': id});
  static Future<DiscoverySnapshot> markRead() => _update('source_discovery_read');
}
