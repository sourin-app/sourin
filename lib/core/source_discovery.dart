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
  static Future<DiscoverySnapshot> _call(
    String command, [
    Map<String, dynamic>? args,
  ]) async {
    final response = await SourinCore.callAsync(command, args);
    final snapshot = DiscoverySnapshot(
      Map<String, dynamic>.from(response as Map),
    );
    current.value = snapshot;
    return snapshot;
  }

  static Future<DiscoverySnapshot> refresh() =>
      _pending ??= _call('source_discovery_status')
          .whenComplete(() => _pending = null);
  static Future<DiscoverySnapshot> configure(String proxy, bool automatic) =>
      _call('source_discovery_configure', {
        'proxy_url': proxy,
        'automatic': automatic,
      });
  static Future<DiscoverySnapshot> scan() => _call('source_discovery_scan');
  static Future<DiscoverySnapshot> enable(String id) =>
      _call('source_discovery_enable', {'id': id});
  static Future<DiscoverySnapshot> markRead() => _call('source_discovery_read');
}
