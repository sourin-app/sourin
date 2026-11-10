import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/disk_cache.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/app_scaffold.dart' show AppThemeHost;
import 'package:sourin_spike/ui/app_theme.dart';

/// Complete records from one local-library read. A failed lane throws at the
/// existing async core seam; an empty list is a successful, intentionally empty
/// result. No page state, DiskCache implementation or native code is replaced.
class LibraryReadData {
  const LibraryReadData({
    required this.favorites,
    required this.following,
    required this.history,
    required this.historyCount,
    this.failures = const {},
  });

  factory LibraryReadData.named(String version, {int position = 20}) =>
      LibraryReadData(
        favorites: [libraryFavorite('favorites', version)],
        following: [libraryFavorite('following', version)],
        history: [libraryProgress(version, position)],
        historyCount: 1,
      );

  static const empty = LibraryReadData(
    favorites: [],
    following: [],
    history: [],
    historyCount: 0,
  );

  final List<Favorite> favorites;
  final List<Favorite> following;
  final List<Progress> history;
  final int historyCount;
  final Set<String> failures;

  Object value(String lane) {
    if (failures.contains(lane)) {
      throw StateError('Synthetic local $lane read failure');
    }
    return switch (lane) {
      'favorites' => [for (final row in favorites) row.toJson()],
      'following' => [for (final row in following) row.toJson()],
      'history' => [for (final row in history) row.toJson()],
      'count' => historyCount,
      _ => throw StateError('Unknown fixture lane'),
    };
  }
}

Favorite libraryFavorite(String lane, String version) => Favorite(
  key: 'fixture:$lane',
  provider: 'fixture',
  nativeId: lane,
  title: '$version $lane title',
  groupName: 'preserved group',
  kind: 'series',
  favorited: lane == 'favorites',
  following: lane == 'following',
  lastEpisodeCount: 12,
  lastEpisodeTitle: '第12集',
  note: '$version note',
  createdAt: 100,
  updatedAt: version == 'newer' ? 300 : 200,
);

Progress libraryProgress(String version, int position) => Progress(
  key: 'fixture:history:e2',
  provider: 'fixture',
  nativeId: 'history',
  title: '$version history title',
  episodeId: 'e2',
  episodeTitle: '第2集',
  position: position,
  duration: 100,
  updatedAt: version == 'newer' ? 300 : 200,
);

class HeldLibraryRead {
  final entered = Completer<void>();
  final result = Completer<LibraryReadData>();

  Future<LibraryReadData> read() {
    if (!entered.isCompleted) entered.complete();
    return result.future;
  }

  void complete(LibraryReadData data) {
    if (!result.isCompleted) result.complete(data);
  }
}

class LibraryReadFixture {
  LibraryReadFixture(this.current);

  LibraryReadData current;
  HeldLibraryRead? held;
  final List<HeldLibraryRead> _held = [];
  final unexpectedCommands = <String>[];
  bool rejectReads = false;

  HeldLibraryRead hold() {
    final read = HeldLibraryRead();
    _held.add(read);
    held = read;
    return read;
  }

  void use(LibraryReadData data) {
    held = null;
    current = data;
    rejectReads = false;
  }

  void releaseAll() {
    for (final read in _held) {
      read.complete(current);
    }
  }

  Future<dynamic> call(String command, Map<String, dynamic>? args) {
    final lane = switch (command) {
      'list_favorites' => args?['following_only'] == true
          ? 'following'
          : 'favorites',
      'continue_watching' => 'history',
      'continue_watching_count' => 'count',
      _ => null,
    };
    if (lane != null) {
      if (rejectReads) {
        return Future<Object>.error(StateError('Synthetic local read failure'));
      }
      // Capture this call's data/future before another load changes the fixture.
      final read = held;
      final data = current;
      return (read?.read() ?? Future<LibraryReadData>.value(data))
          .then((value) => value.value(lane));
    }
    if (!const {
      'list_all_progress',
      'repair_library_covers',
      'check_updates',
      'covers_to_durable',
      'covers_to_display',
    }.contains(command)) {
      unexpectedCommands.add(command);
    }
    return switch (command) {
      'list_all_progress' => Future.value(<dynamic>[]),
      'repair_library_covers' => Future.value(0),
      // The independent automatic network sweep is deliberately unavailable.
      // Production catches this error; no successful sweep adds a third load.
      'check_updates' => Future<Object>.error(
        StateError('Automatic update scan unavailable in local fixture'),
      ),
      'covers_to_durable' || 'covers_to_display' => Future.value({
        'items': [
          for (final row in args!['items'] as List)
            Map<String, dynamic>.from(row as Map),
        ],
      }),
      _ => Future<Object>.error(
        StateError('Unexpected library fixture command: $command'),
      ),
    };
  }
}

Widget libraryLoadHost(Widget child) {
  final theme = AppTheme.themeFor(Brightness.light);
  return MaterialApp(
    theme: theme,
    builder: (_, content) => AppThemeHost(data: theme, child: content!),
    home: Scaffold(body: child),
  );
}

Future<void> pumpLibrary(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

Future<Map<String, dynamic>> readLibraryDisk(String name) async {
  final entry = await DiskCache.read(name);
  expect(entry, isNotNull, reason: 'The real temporary-directory cache exists');
  return Map<String, dynamic>.from(entry!.data as Map);
}

final class _OriginalIO extends IOOverrides {}

/// Observes actual temp-file writes/publication without delaying or replacing
/// their bytes. It supplies an I/O-drain boundary for unawaited persistence, so
/// the final cache assertion cannot race a still-running older publisher.
class LibraryDiskObserver {
  LibraryDiskObserver(this.target);

  final String target;
  final _original = _OriginalIO();
  final _pending = <String>{};
  int publications = 0;
  bool get idle => _pending.isEmpty;

  File file(String path) => path == target || path.startsWith('$target.')
      ? _ObservedLibraryFile(_original.createFile(path), this)
      : _original.createFile(path);
}

Future<void> settleLibraryDisk(
  WidgetTester tester,
  LibraryDiskObserver observer,
) async {
  var quiet = 0;
  // Bound real I/O turns explicitly; DateTime.now in a widget fake zone does
  // not advance while awaiting runAsync and must not control this timeout.
  for (var turn = 0; turn < 500; turn++) {
    await tester.runAsync(() =>
        Future<void>.delayed(const Duration(milliseconds: 10)));
    // Initial post-frame loads originate in the widget's fake zone. Alternate
    // real I/O turns and pumps so their continuations cannot deadlock this wait.
    await tester.pump();
    quiet = observer.idle ? quiet + 1 : 0;
    if (quiet == 3) return;
  }
  fail('Actual library snapshot publication did not finish');
}

class _ObservedLibraryFile implements File {
  _ObservedLibraryFile(this.real, this.observer);

  final File real;
  final LibraryDiskObserver observer;

  @override
  String get path => real.path;

  @override
  Future<bool> exists() => real.exists();

  @override
  Future<String> readAsString({Encoding encoding = utf8}) =>
      real.readAsString(encoding: encoding);

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    if (path.endsWith('.tmp')) observer._pending.add(path);
    try {
      await real.writeAsString(
        contents,
        mode: mode,
        encoding: encoding,
        flush: flush,
      );
      return this;
    } catch (_) {
      observer._pending.remove(path);
      rethrow;
    }
  }

  @override
  Future<File> rename(String newPath) async {
    final result = await real.rename(newPath);
    observer._pending.remove(path);
    if (newPath == observer.target) observer.publications++;
    return result;
  }

  @override
  Future<Uint8List> readAsBytes() => real.readAsBytes();

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) =>
      real.open(mode: mode);

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    final result = await real.delete(recursive: recursive);
    observer._pending.remove(path);
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected library fixture file operation: ${invocation.memberName}',
  );
}
