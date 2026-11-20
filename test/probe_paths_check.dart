// Run without pub or Flutter: dart test/probe_paths_check.dart
// The child processes run only dart:io and this file's path-helper cases.
import 'dart:io';

// Keep this smoke test executable with the SDK alone and no pub resolution.
// ignore: avoid_relative_lib_imports
import '../lib/probe_paths.dart';

void check(bool condition, String label) {
  if (!condition) throw StateError(label);
}

void expectError<T extends Object>(void Function() run, String message) {
  try {
    run();
  } catch (error) {
    check(
      error is T && error.toString().contains(message),
      'Unexpected: $error',
    );
    return;
  }
  throw StateError('Expected $T with message: $message');
}

void main(List<String> args) {
  if (args.isNotEmpty) {
    runCase(args.single);
    return;
  }

  final fixtureSpace = Directory.systemTemp.createTempSync(
    'probe-paths-check-',
  );
  try {
    ProcessResult invoke(
      String name, {
      Map<String, String> settings = const {},
      List<String> defines = const [],
    }) {
      // Forward only what the OS and Dart need, not user app settings.
      final environment = {
        for (final key in ['SYSTEMROOT', 'TEMP', 'TMP'])
          if (Platform.environment[key] case final value?) key: value,
        ...settings,
      };
      final result = Process.runSync(
        Platform.resolvedExecutable,
        [...defines, Platform.script.toFilePath(), name],
        environment: environment,
        includeParentEnvironment: false,
        // Also test that paths are independent of a Release-like cwd.
        workingDirectory: fixtureSpace.path,
      );
      check(
        result.exitCode == 0 && result.stdout.toString().trim() == 'PASS $name',
        '$name exited ${result.exitCode}: ${result.stdout}${result.stderr}',
      );
      stdout.writeln(result.stdout.toString().trim());
      return result;
    }

    // Negative controls first, with no fixture data and no artifact root.
    invoke('missing');
    invoke(
      'relative',
      settings: {
        'PROBE_ARTIFACT_ROOT': 'relative-artifacts',
        'PROBE_MEDIA': 'relative.mp4',
        'ORIGINAL_VUE_FIXTURE_ROOT': 'relative-fixtures',
      },
    );
    final absent = probeFileUnder(fixtureSpace, 'absent');
    invoke(
      'absent',
      settings: {
        'PROBE_MEDIA': absent.path,
        'ORIGINAL_VUE_FIXTURE_ROOT': absent.path,
      },
    );
    check(fixtureSpace.listSync().isEmpty, 'Missing inputs produced files');

    final fixture = Directory.fromUri(
      fixtureSpace.uri.resolveUri(Uri(pathSegments: ['夹具 #%'])),
    )..createSync();
    final input = File.fromUri(fixture.uri.resolve('media%23%25.mp4'))
      ..writeAsStringSync('media fixture bytes');
    final out = probeFileUnder(fixtureSpace, 'out #%');
    final other = probeFileUnder(fixtureSpace, 'not selected');
    final env = {
      'PROBE_ARTIFACT_ROOT': out.path,
      'ORIGINAL_VUE_FIXTURE_ROOT': fixture.path,
      'PROBE_MEDIA': input.path,
    };
    invoke('fixture-and-escaping', settings: env);
    invoke(
      'environment-precedence',
      settings: {...env, 'T74_DATA': '${other.path} data'},
      defines: [
        '-DDATA_DIR_OVERRIDE=${other.path}',
        '-DPROBE_ARTIFACT_ROOT=${other.path}',
        '-DPROBE_MEDIA=${absent.path}',
      ],
    );
    check(Directory('${other.path} data').existsSync(), 'T74_DATA did not win');
    final defined = probeFileUnder(fixtureSpace, 'from defines');
    invoke(
      'defines',
      defines: [
        '-DPROBE_ARTIFACT_ROOT=${defined.path}',
        '-DPROBE_MEDIA=${input.path}',
        '-DDATA_DIR_OVERRIDE=${defined.path} data',
      ],
    );
    check(Directory(defined.path).existsSync(), 'Dart define root not created');
    check(
      Directory('${defined.path} data').existsSync(),
      'Data define root not created',
    );
    check(!Directory(other.path).existsSync(), 'Shadowed Dart define touched');
    check(input.readAsStringSync() == 'media fixture bytes', 'Input changed');
  } finally {
    fixtureSpace.deleteSync(recursive: true);
  }
}

void runCase(String name) {
  const vue = 'ORIGINAL_VUE_FIXTURE_ROOT';
  switch (name) {
    case 'missing':
      expectError<StateError>(
        probeArtifactDirectory,
        'Set PROBE_ARTIFACT_ROOT',
      );
      expectError<StateError>(requireProbeMedia, 'Set PROBE_MEDIA');
      expectError<StateError>(probeDataDirectory, 'Set DATA_DIR_OVERRIDE');
      expectError<StateError>(() => requireProbeFixtureRoot(vue), 'Set $vue');
    case 'relative':
      expectError<StateError>(
        probeArtifactDirectory,
        'absolute local directory',
      );
      expectError<StateError>(requireProbeMedia, 'absolute local file');
      expectError<StateError>(
        () => requireProbeFixtureRoot(vue),
        'absolute local fixture',
      );
      expectError<StateError>(
        () => requireLocalProbeFile(
          'https://example.invalid/a.mp4',
          setting: 'probe media',
        ),
        'absolute local file',
      );
    case 'absent':
      expectError<StateError>(requireProbeMedia, 'fixture file does not exist');
      expectError<StateError>(
        () => requireProbeFixtureRoot(vue),
        'fixture directory does not exist',
      );
    case 'fixture-and-escaping':
      expectError<StateError>(
        () => requireProbeFixtureFile(vue, 'missing.vue'),
        'missing its required fixture: missing.vue',
      );
      for (final bad in [
        '../outside',
        'nested/../outside',
        '/absolute',
        r'..\outside',
        'D:relative',
      ]) {
        expectError<ArgumentError>(
          () => probeArtifactDirectory(bad),
          'Expected a child path',
        );
      }
      check(
        !Directory(Platform.environment['PROBE_ARTIFACT_ROOT']!).existsSync(),
        'Invalid child created the root',
      );
      final out = probeArtifactDirectory('nested/run');
      final report = probeFileUnder(out, '结果 #%2F.txt')
        ..writeAsStringSync('ok');
      check(
        File.fromUri(report.uri).readAsStringSync() == 'ok',
        'Output roundtrip',
      );
      check(
        out.listSync().single.uri.pathSegments.last == '结果 #%2F.txt',
        'Output name lost URI characters',
      );
      final fixture = requireProbeFixtureFile(vue, 'media#%.mp4');
      check(
        fixture.readAsStringSync() == 'media fixture bytes',
        'Fixture path decoding',
      );
      check(
        fixture.path == requireProbeMedia().uri.toFilePath(),
        'Media selected wrong input',
      );
    case 'environment-precedence':
    case 'defines':
      final out = probeArtifactDirectory();
      probeDataDirectory(runtimeSetting: 'T74_DATA');
      check(out.existsSync(), '$name output root missing');
      check(
        requireProbeMedia().readAsStringSync() == 'media fixture bytes',
        '$name input mismatch',
      );
    default:
      throw ArgumentError.value(name, 'name');
  }
  stdout.writeln('PASS $name');
}
