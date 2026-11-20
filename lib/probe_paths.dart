/// Path configuration for standalone probes and their fixture-based tests.
///
/// Set PROBE_ARTIFACT_ROOT to an absolute directory for this run. Existing
/// probe-specific subdirectories and filenames are relative to that root.
/// Set PROBE_MEDIA to the exact local media fixture required by the probe,
/// not a substitute with different timestamps or tracks. An environment
/// variable takes precedence over a matching --dart-define for built probes.
/// Neither setting falls back to the working directory or a user profile.
/// Flutter probes with app data also need an isolated DATA_DIR_OVERRIDE.
/// T104, T98, and the Vue reference tests require an explicitly selected
/// fixture root (PROBE_REPO_ROOT, PROBE_CODEC_FIXTURE_ROOT, and
/// ORIGINAL_VUE_FIXTURE_ROOT, respectively).
library;

import 'dart:io';

String _configuredPath(String name, String dartDefine) {
  final path = Platform.environment[name] ?? dartDefine;
  if (path.trim().isEmpty) {
    throw StateError('Set $name to an absolute local path before running.');
  }
  return path;
}

bool _isAbsoluteLocalPath(String path) => Platform.isWindows
    ? RegExp(r'^[a-zA-Z]:[/\\]').hasMatch(path)
    : path.startsWith('/') && !path.startsWith('//');

Uri _under(Directory root, String relativePath) {
  final segments = relativePath.split('/');
  if (segments.any(
    (segment) =>
        segment.isEmpty ||
        segment == '.' ||
        segment == '..' ||
        RegExp(r'[:\\\x00]').hasMatch(segment) ||
        (Platform.isWindows &&
            (segment.endsWith('.') || segment.endsWith(' '))),
  )) {
    throw ArgumentError.value(
      relativePath,
      'relativePath',
      'Expected a child path',
    );
  }
  return root.uri.resolveUri(Uri(pathSegments: segments));
}

/// Resolves a slash-separated child path without interpreting # or % as a URI.
File probeFileUnder(Directory root, String relativePath) =>
    File.fromUri(_under(root, relativePath));

/// Creates only the explicitly configured output directory for this run.
Directory probeArtifactDirectory([String? subdirectory]) {
  const name = 'PROBE_ARTIFACT_ROOT';
  final rootPath = _configuredPath(name, const String.fromEnvironment(name));
  if (!_isAbsoluteLocalPath(rootPath)) {
    throw StateError('$name must be an absolute local directory.');
  }
  final root = Directory(rootPath);
  final out = subdirectory == null
      ? root
      : Directory.fromUri(_under(root, subdirectory));
  return out..createSync(recursive: true);
}

/// Prepares a caller-provided scratch data directory, never a user profile.
/// The operator must point this at a run-specific directory or fixture copy.
Directory probeDataDirectory({
  String? runtimeSetting,
  String dartDefine = const String.fromEnvironment('DATA_DIR_OVERRIDE'),
}) {
  final runtime = runtimeSetting == null
      ? null
      : Platform.environment[runtimeSetting];
  // Keep DATA_DIR_OVERRIDE a Dart define: product code reads it that way too.
  final useRuntime = runtime != null && runtime.isNotEmpty;
  final name = useRuntime ? runtimeSetting! : 'DATA_DIR_OVERRIDE';
  final path = useRuntime ? runtime : dartDefine;
  if (path.trim().isEmpty) {
    throw StateError(
      'Set $name to an absolute scratch data directory before running.',
    );
  }
  if (!_isAbsoluteLocalPath(path)) {
    throw StateError('$name must be an absolute scratch data directory.');
  }
  return Directory(path)..createSync(recursive: true);
}

/// Returns an explicitly selected fixture directory without creating it.
Directory requireProbeFixtureRoot(String name, {String dartDefine = ''}) {
  final root = _configuredPath(name, dartDefine);
  if (!_isAbsoluteLocalPath(root)) {
    throw StateError('$name must be an absolute local fixture directory.');
  }
  final dir = Directory(root);
  if (!dir.existsSync()) {
    throw StateError('$name fixture directory does not exist: $root');
  }
  return dir;
}

/// Resolves and checks a required input under an explicitly selected checkout.
File requireProbeFixtureFile(
  String name,
  String relativePath, {
  String dartDefine = '',
}) {
  final root = requireProbeFixtureRoot(name, dartDefine: dartDefine);
  final file = probeFileUnder(root, relativePath);
  if (!file.existsSync()) {
    throw StateError('$name is missing its required fixture: $relativePath');
  }
  return file;
}

/// Validates a local file selected in a probe config. URLs are not fixtures.
File requireLocalProbeFile(String path, {required String setting}) {
  if (!_isAbsoluteLocalPath(path)) {
    throw StateError('$setting must be an absolute local file path.');
  }
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError('$setting fixture file does not exist: $path');
  }
  return file;
}

File requireProbeMedia({
  String name = 'PROBE_MEDIA',
  String dartDefine = const String.fromEnvironment('PROBE_MEDIA'),
}) => requireLocalProbeFile(_configuredPath(name, dartDefine), setting: name);
