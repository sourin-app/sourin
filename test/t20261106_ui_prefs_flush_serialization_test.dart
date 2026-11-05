import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/ui_prefs.dart';

class _HeldWrite {
  _HeldWrite(this.snapshot);

  final String snapshot;
  final completion = Completer<File>();
}

class _HeldFile extends Fake implements File {
  final writes = <_HeldWrite>[];
  Completer<String>? heldRead;
  String persisted = '{}';
  bool present = false;
  int outstanding = 0;
  int maximumOutstanding = 0;

  @override
  Future<bool> exists() async => present;

  @override
  Future<String> readAsString({Encoding encoding = utf8}) async =>
      heldRead == null ? persisted : await heldRead!.future;

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) {
    final write = _HeldWrite(contents);
    writes.add(write);
    outstanding++;
    if (outstanding > maximumOutstanding) {
      maximumOutstanding = outstanding;
    }
    return write.completion.future.then(
      (_) {
        outstanding--;
        persisted = contents;
        present = true;
        return this;
      },
      onError: (Object error, StackTrace stack) {
        outstanding--;
        Error.throwWithStackTrace(error, stack);
      },
    );
  }

  void release(int index) => writes[index].completion.complete(this);

  void fail(int index) => writes[index].completion.completeError(
    const FileSystemException('synthetic held write failure'),
  );
}

Future<void> _load(_HeldFile file) => IOOverrides.runZoned(
  () => UiPrefs.load('synthetic-ui-prefs-fixture'),
  createFile: (_) => file,
);

Future<void> _settle(WidgetTester tester, List<_HeldFile> files) async {
  for (var i = 0; i < 8; i++) {
    for (final file in files) {
      for (final write in file.writes) {
        if (!write.completion.isCompleted) write.completion.complete(file);
      }
      if (file.heldRead case final read?) {
        if (!read.isCompleted) read.complete('{}');
      }
    }
    await tester.pump(const Duration(milliseconds: 350));
  }
  UiPrefs.debugResetForTest();
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  setUp(UiPrefs.debugResetForTest);

  testWidgets('a clean concurrent flush joins the held write', (tester) async {
    final file = _HeldFile();
    addTearDown(() => _settle(tester, [file]));
    await _load(file);
    UiPrefs.set('synthetic.selection', 'first');
    final first = UiPrefs.flush();
    var joinedCompleted = false;
    final joined = UiPrefs.flush().then((_) => joinedCompleted = true);
    await tester.pump();
    expect(file.writes, hasLength(1));
    expect(joinedCompleted, isFalse);
    file.release(0);
    await tester.pump();
    await Future.wait([first, joined]);
    expect(joinedCompleted, isTrue);
  });

  testWidgets('dirty edits drain the latest snapshot without overlapping writes', (
    tester,
  ) async {
    final file = _HeldFile();
    addTearDown(() => _settle(tester, [file]));
    await _load(file);
    UiPrefs.set('synthetic.selection', 'longer original selection');
    final first = UiPrefs.flush();
    UiPrefs.set('synthetic.selection', 'short');
    UiPrefs.set('synthetic.other', 'latest');
    var joinedCompleted = false;
    final joined = UiPrefs.flush().then((_) => joinedCompleted = true);
    await tester.pump();
    expect(file.writes, hasLength(1));
    expect(file.maximumOutstanding, 1);
    expect(joinedCompleted, isFalse);
    file.release(0);
    await tester.pump();
    expect(file.writes, hasLength(2));
    expect(file.maximumOutstanding, 1);
    expect(joinedCompleted, isFalse);
    expect(jsonDecode(file.writes[1].snapshot), {
      'synthetic.selection': 'short',
      'synthetic.other': 'latest',
    });
    file.release(1);
    await tester.pump();
    await Future.wait([first, joined]);
    expect(jsonDecode(file.persisted), {
      'synthetic.selection': 'short',
      'synthetic.other': 'latest',
    });
  });

  testWidgets('scheduled flush and fire-and-forget source flush stay serialized', (
    tester,
  ) async {
    final file = _HeldFile();
    addTearDown(() => _settle(tester, [file]));
    await _load(file);
    UiPrefs.setHomeSource('synthetic-long-source');
    await tester.pump(const Duration(milliseconds: 300));
    expect(file.writes, hasLength(1));
    UiPrefs.setHomeSource('short');
    unawaited(UiPrefs.flush());
    await tester.pump(const Duration(milliseconds: 300));
    expect(file.writes, hasLength(1));
    expect(file.maximumOutstanding, 1);
    file.release(0);
    await tester.pump();
    expect(file.writes, hasLength(2));
    file.release(1);
    await tester.pump();
    await UiPrefs.flush();
    expect(jsonDecode(file.persisted), {UiPrefs.homeSourceKey: 'short'});
  });

  testWidgets('write failure is nonfatal and retries only on a later flush', (
    tester,
  ) async {
    final file = _HeldFile();
    addTearDown(() => _settle(tester, [file]));
    await _load(file);
    UiPrefs.set('synthetic.selection', 'retained');
    final first = UiPrefs.flush();
    file.fail(0);
    await tester.pump();
    await expectLater(first, completes);
    expect(UiPrefs.get('synthetic.selection'), 'retained');
    await tester.pump(const Duration(seconds: 2));
    expect(file.writes, hasLength(1), reason: 'Failure must not busy-retry.');
    final retry = UiPrefs.flush();
    expect(file.writes, hasLength(2));
    file.release(1);
    await tester.pump();
    await retry;
    expect(jsonDecode(file.persisted), {'synthetic.selection': 'retained'});
  });

  testWidgets('reset and load retain ownership of an already held file write', (
    tester,
  ) async {
    final oldFile = _HeldFile();
    final newFile = _HeldFile();
    addTearDown(() => _settle(tester, [oldFile, newFile]));
    await _load(oldFile);
    UiPrefs.set('synthetic.old', 'old');
    final oldFlush = UiPrefs.flush();
    UiPrefs.debugResetForTest();
    var loaded = false;
    final newLoad = _load(newFile).then((_) => loaded = true);
    await tester.pump();
    expect(loaded, isFalse);
    expect(oldFile.outstanding, 1);
    expect(newFile.writes, isEmpty);
    oldFile.release(0);
    await tester.pump();
    await Future.wait([oldFlush, newLoad]);
    UiPrefs.set('synthetic.new', 'new');
    final newFlush = UiPrefs.flush();
    expect(oldFile.writes, hasLength(1));
    expect(newFile.writes, hasLength(1));
    expect(jsonDecode(oldFile.persisted), {'synthetic.old': 'old'});
    newFile.release(0);
    await tester.pump();
    await newFlush;
    expect(jsonDecode(newFile.persisted), {'synthetic.new': 'new'});
  });

  testWidgets('a stale held load cannot overwrite a reset generation', (
    tester,
  ) async {
    final file = _HeldFile()
      ..present = true
      ..heldRead = Completer<String>();
    addTearDown(() => _settle(tester, [file]));
    final loading = _load(file);
    await tester.pump();
    UiPrefs.debugResetForTest({'synthetic.new': 'current'});
    file.heldRead!.complete('{"synthetic.old":"stale"}');
    await tester.pump();
    await loading;
    expect(UiPrefs.get('synthetic.new'), 'current');
    expect(UiPrefs.get('synthetic.old'), isNull);
    expect(UiPrefs.isLoaded, isFalse);
  });

  testWidgets('setters remain synchronous and coalesce at exactly 300ms', (
    tester,
  ) async {
    final file = _HeldFile();
    addTearDown(() => _settle(tester, [file]));
    await _load(file);
    UiPrefs.set('synthetic.selection', 'first');
    UiPrefs.set('synthetic.selection', 'latest');
    UiPrefs.set('synthetic.removed', 'remove');
    UiPrefs.remove('synthetic.removed');
    expect(UiPrefs.get('synthetic.selection'), 'latest');
    expect(UiPrefs.get('synthetic.removed'), isNull);
    await tester.pump(const Duration(milliseconds: 299));
    expect(file.writes, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(file.writes, hasLength(1));
    expect(jsonDecode(file.writes.single.snapshot), {
      'synthetic.selection': 'latest',
    });
    file.release(0);
    await tester.pump();
  });

  testWidgets('reset cancels the old scheduled deadline for a new file', (
    tester,
  ) async {
    final oldFile = _HeldFile();
    final newFile = _HeldFile();
    addTearDown(() => _settle(tester, [oldFile, newFile]));
    await _load(oldFile);
    UiPrefs.set('synthetic.old', 'old');
    await tester.pump(const Duration(milliseconds: 100));
    UiPrefs.debugResetForTest();
    await _load(newFile);
    UiPrefs.set('synthetic.new', 'new');
    await tester.pump(const Duration(milliseconds: 200));
    expect(oldFile.writes, isEmpty);
    expect(newFile.writes, isEmpty);
    await tester.pump(const Duration(milliseconds: 100));
    expect(newFile.writes, hasLength(1));
    newFile.release(0);
    await tester.pump();
  });

  test('real scratch file remains valid after a shorter trailing snapshot', () async {
    final dir = await Directory.systemTemp.createTemp('ui-prefs-serialized-');
    addTearDown(() async {
      UiPrefs.debugResetForTest();
      await dir.delete(recursive: true);
    });
    await UiPrefs.load(dir.path);
    UiPrefs.setHomeSource('synthetic-long-source-identity');
    UiPrefs.set('synthetic.removed', 'longer value');
    await UiPrefs.flush();
    UiPrefs.setHomeSource('short');
    UiPrefs.remove('synthetic.removed');
    await UiPrefs.flush();
    final disk = File('${dir.path}${Platform.pathSeparator}ui-prefs.json');
    expect(jsonDecode(await disk.readAsString()), {UiPrefs.homeSourceKey: 'short'});
    UiPrefs.debugResetForTest();
    await UiPrefs.load(dir.path);
    expect(UiPrefs.homeSource, 'short');
  });
}
