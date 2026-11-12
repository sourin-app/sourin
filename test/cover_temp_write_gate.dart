import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

// Only schedule real operations on one explicitly owned cover temporary path.
// Every write and flush reaches disk. Let all three completed writers own the
// same filename before allowing production rename to resume.
final class CoverTempWriteGate extends IOOverrides {
  CoverTempWriteGate(String path, this.expected)
      : target = File(path).absolute.path {
    final ownedRoot = Directory.systemTemp.absolute.path;
    if (!target.startsWith('$ownedRoot${Platform.pathSeparator}') ||
        !target.endsWith('${Platform.pathSeparator}_sourin-cover.jpg.tmp')) {
      throw StateError('The file gate must use its exact temporary cover path');
    }
  }
  final String target;
  final int expected;
  final _release = Completer<void>();
  Future<void> _writes = Future<void>.value();
  int written = 0;
  int flushed = 0;
  int renameCalls = 0;

  @override
  File createFile(String path) {
    final real = super.createFile(path);
    return path == target ? _GatedCoverFile(real, this) : real;
  }

  Future<T> run<T>(Future<T> Function() body) async {
    try {
      return await IOOverrides.runZoned(body, createFile: createFile);
    } finally {
      if (!_release.isCompleted) _release.complete();
    }
  }

  Future<File> write(File real, List<int> bytes, FileMode mode, bool flush) async {
    // Avoid OS sharing policy changing the setup: each real write completes,
    // while all production callers remain concurrently pending before rename.
    final operation = _writes.then((_) async {
      final result = await real.writeAsBytes(bytes, mode: mode, flush: flush);
      if (await real.length() != bytes.length) {
        throw StateError('Real temporary write is incomplete');
      }
      written++;
      if (flush) flushed++;
      if (written == expected) _release.complete();
      return result;
    });
    _writes = operation.then<void>((_) {});
    await operation;
    await _release.future.timeout(const Duration(seconds: 25));
    return real;
  }
}

class _GatedCoverFile implements File {
  _GatedCoverFile(this.real, this.gate);
  final File real;
  final CoverTempWriteGate gate;
  @override String get path => real.path;
  @override Uri get uri => real.uri;
  @override bool get isAbsolute => real.isAbsolute;
  @override File get absolute => real.absolute;
  @override Directory get parent => real.parent;
  @override Future<File> writeAsBytes(List<int> bytes,
      {FileMode mode = FileMode.write, bool flush = false}) => gate.write(real, bytes, mode, flush);
  @override Future<File> rename(String newPath) {
    gate.renameCalls++;
    return real.rename(newPath);
  }
  @override Future<Uint8List> readAsBytes() => real.readAsBytes();
  @override Future<bool> exists() => real.exists();
  @override bool existsSync() => real.existsSync();
  @override Future<FileSystemEntity> delete({bool recursive = false}) => real.delete(recursive: recursive);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected gated File operation: ${invocation.memberName}');
}
