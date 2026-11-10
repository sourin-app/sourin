import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

const snapshotOldCover = 'http://127.0.0.1:53002/s/old-session-token';
const snapshotNewCover = 'http://127.0.0.1:61234/s/new-session-token';
const snapshotRawCover =
    'https://images.invalid/poster.jpg@Referer=https://headers.invalid/@User-Agent=Fixture';
const snapshotUnknownCover = 'http://127.0.0.1:53002/s/unknown-old-token';

class SnapshotCoverTransport {
  final calls = <({String command, List<Map<String, dynamic>> items})>[];
  bool rejectConversions = false;
  bool foreignIdentity = false;
  bool truncateResponse = false;

  Future<dynamic> call(String command, Map<String, dynamic>? args) async {
    if (command == 'covers_to_durable' || command == 'covers_to_display') {
      final request = args!;
      expect(request.keys, ['items']);
      final items = [
        for (final item in request['items'] as List)
          Map<String, dynamic>.from(item as Map),
      ];
      expect(items.length, lessThanOrEqualTo(4096));
      for (final item in items) {
        expect(item.keys, unorderedEquals(['provider', 'id', 'cover']));
        expect(item['provider'], isA<String>());
        expect(item['id'], isA<String>());
      }
      calls.add((command: command, items: items));
      if (rejectConversions) throw StateError('Conversion fixture unavailable');
      return {
        'items': [
          for (final item in (truncateResponse ? items.skip(1) : items))
            {
              ...item,
              if (foreignIdentity) 'id': 'foreign-identity',
              'cover': switch ((command, item['cover'])) {
                ('covers_to_durable', snapshotOldCover) => snapshotRawCover,
                ('covers_to_durable', snapshotNewCover) => snapshotRawCover,
                (_, snapshotUnknownCover) => null,
                ('covers_to_display', snapshotRawCover) => snapshotNewCover,
                _ => item['cover'],
              },
            },
        ],
      };
    }
    if (command == 'list_all_progress') return <dynamic>[];
    if (command == 'repair_library_covers') return 0;
    throw StateError('Unexpected snapshot fixture command: $command');
  }
}

final class _RealIO extends IOOverrides {}

/// Delay selected real file operations; bytes and DiskCache remain real.
class SnapshotDiskGate {
  SnapshotDiskGate(this.target, {this.holdRead = false, this.oldWriteMarker});

  final String target;
  final bool holdRead;
  final String? oldWriteMarker;
  final entered = Completer<void>();
  final release = Completer<void>();
  final newerPublished = Completer<void>();
  final olderPublished = Completer<void>();
  final _real = _RealIO();
  bool _captured = false;

  File file(String path) =>
      path == target || path.startsWith('$target.')
      ? _GatedFile(_real.createFile(path), this)
      : _real.createFile(path);

  void unblock() {
    if (!release.isCompleted) release.complete();
  }
}

class _GatedFile implements File {
  _GatedFile(this.real, this.gate);
  final File real;
  final SnapshotDiskGate gate;
  bool _older = false;

  @override
  String get path => real.path;
  @override
  Future<bool> exists() => real.exists();
  @override
  Future<DateTime> lastModified() => real.lastModified();
  @override
  Future<String> readAsString({Encoding encoding = utf8}) async {
    final value = await real.readAsString(encoding: encoding);
    if (gate.holdRead && path == gate.target && !gate._captured) {
      gate._captured = true;
      gate.entered.complete();
      await gate.release.future;
    }
    return value;
  }

  @override
  Future<File> writeAsString(String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    await real.writeAsString(contents, mode: mode, encoding: encoding, flush: flush);
    if (gate.oldWriteMarker != null && contents.contains(gate.oldWriteMarker!)) {
      _older = true;
      if (!gate._captured) {
        gate._captured = true;
        gate.entered.complete();
        await gate.release.future;
      }
    }
    return this;
  }

  @override
  Future<File> rename(String newPath) async {
    final result = await real.rename(newPath);
    final completion = _older ? gate.olderPublished : gate.newerPublished;
    if (!completion.isCompleted) completion.complete();
    return result;
  }

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) => real.open(mode: mode);
  @override
  Future<Uint8List> readAsBytes() => real.readAsBytes();
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) => real.delete(recursive: recursive);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected cache fixture File operation: ${invocation.memberName}');
}

Future<T> snapshotGatedIO<T>(SnapshotDiskGate gate, Future<T> Function() body) =>
    IOOverrides.runZoned(() async {
      try {
        return await body();
      } finally {
        gate.unblock();
      }
    }, createFile: gate.file);

Future<void> snapshotEventually(Future<bool> Function() check) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    if (await check()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('The actual snapshot file did not reach the expected state');
}

Object? snapshotWithoutCovers(Object? value) => switch (value) {
  Map() => {
    for (final entry in value.entries)
      if (entry.key != 'cover') entry.key: snapshotWithoutCovers(entry.value),
  },
  List() => [for (final item in value) snapshotWithoutCovers(item)],
  _ => value,
};
