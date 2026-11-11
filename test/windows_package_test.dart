import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String? ps;
  if (Platform.isWindows) {
    for (final candidate in ['pwsh', 'powershell']) {
      try {
        if (Process.runSync(candidate, [
              '-NoProfile',
              '-Command',
              'exit 0',
            ]).exitCode ==
            0) {
          ps = candidate;
          break;
        }
      } on ProcessException {
        // Try the other supported Windows PowerShell executable.
      }
    }
  }
  if (ps == null) {
    test(
      'Windows package tooling requires PowerShell on Windows',
      () {},
      skip: 'Windows package tooling requires PowerShell on Windows',
    );
    return;
  }
  late Directory project;
  late Directory release;
  late Directory package;
  late String coreHash;
  late File manifest;

  File put(String path, List<int> bytes) {
    final f = File(path);
    f.parent.createSync(recursive: true);
    return f..writeAsBytesSync(bytes);
  }

  void config({String target = 'lib/shell.dart', String? define}) {
    put(
      '${project.path}/windows/flutter/ephemeral/generated_config.cmake',
      utf8.encode(
        '"FLUTTER_TARGET=$target"\n"DART_DEFINES=${base64Encode(utf8.encode(define ?? 'FLUTTER_BUILD_NAME=1.0.0'))}"\n',
      ),
    );
  }

  ProcessResult run(String script) => Process.runSync(
    ps!,
    [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      'tools/$script',
      '-BuildProject',
      project.path,
      '-PackageRoot',
      package.path,
      '-ExpectedCoreSha256',
      coreHash,
    ],
    stdoutEncoding: const Utf8Codec(allowMalformed: true),
    stderrEncoding: const Utf8Codec(allowMalformed: true),
    environment: {
      // A parent PowerShell 7 session can omit the legacy Windows modules.
      'PSModulePath': [
        if (!ps!.toLowerCase().endsWith('powershell.exe'))
          Platform.environment['PSModulePath'] ?? '',
        '${Platform.environment['SystemRoot'] ?? 'C:/Windows'}'
            '/System32/WindowsPowerShell/v1.0/Modules',
      ].join(';'),
    },
  );

  setUp(() {
    project = Directory.systemTemp.createTempSync('sourin-package-');
    release = Directory('${project.path}/build/windows/x64/runner/Release')
      ..createSync(recursive: true);
    package = Directory('${project.path}/delivered');
    config();
    final paths = <String>[];
    for (final name in [
      'sourin_core.dll',
      'flutter_windows.dll',
      'data/icudtl.dat',
      'data/flutter_assets/AssetManifest.bin',
      'data/flutter_assets/NativeAssetsManifest.json',
      'data/flutter_assets/assets/logos/01-orbit.ico',
    ]) {
      paths.add(put('${release.path}/$name', utf8.encode(name)).absolute.path);
    }
    paths.add(
      put(
        '${release.path}/data/app.so',
        List.filled(6 * 1024 * 1024, 8),
      ).absolute.path,
    );
    for (final name in ['sourin_spike.exe', 'WebView2Loader.dll']) {
      put('${release.path}/$name', utf8.encode(name));
    }
    // The hook build intermediate is not a root runtime asset.
    put(
      '${release.path}/native_assets.json',
      utf8.encode('PRIVATE-BUILD-INPUT'),
    );
    // Real builds can accumulate these after being launched. They must stay out.
    put(
      '${release.path}/app.sourin.player/ui-prefs.json',
      utf8.encode('PRIVATE'),
    );
    put(
      '${release.path}/webview_window_WebView2/cache.bin',
      utf8.encode('PRIVATE'),
    );
    manifest = put(
      '${project.path}/build/windows/x64/install_manifest.txt',
      utf8.encode(paths.join('\n')),
    );
    coreHash = sha256
        .convert(File('${release.path}/sourin_core.dll').readAsBytesSync())
        .toString();
  });
  tearDown(() => project.deleteSync(recursive: true));

  test(
    'manifest packaging excludes runtime data and binds all runtime bytes',
    () {
      final result = run('package_owner_windows.ps1');
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(jsonDecode(result.stdout as String)['filesVerified'], 9);
      expect(File('${package.path}/native_assets.json').existsSync(), isFalse);
      expect(
        File('${package.path}/data/flutter_assets/NativeAssetsManifest.json')
            .readAsStringSync(),
        'data/flutter_assets/NativeAssetsManifest.json',
      );
      expect(
        Directory('${package.path}/app.sourin.player').existsSync(),
        isFalse,
      );
      expect(
        Directory('${package.path}/webview_window_WebView2').existsSync(),
        isFalse,
      );
      expect(
        File('${package.path}/data/flutter_assets/assets/logos/01-orbit.ico')
            .existsSync(),
        isTrue,
      );
      File('${package.path}/sourin_core.dll').writeAsStringSync('changed');
      expect(run('verify_owner_windows_package.ps1').exitCode, isNot(0));
    },
  );
  test('package rejects additional data, missing dependency and wrong configuration', () {
    expect(run('package_owner_windows.ps1').exitCode, 0);
    final extra = put('${package.path}/extra.json', [1]);
    expect(run('verify_owner_windows_package.ps1').exitCode, isNot(0));
    expect(Process.runSync('attrib', ['+h', extra.path]).exitCode, 0);
    expect(
      run('verify_owner_windows_package.ps1').exitCode,
      isNot(0),
      reason: 'Hidden data is still extra package content.',
    );
    expect(Process.runSync('attrib', ['-h', extra.path]).exitCode, 0);
    extra.deleteSync();
    final dll = File('${package.path}/WebView2Loader.dll');
    final bytes = dll.readAsBytesSync();
    dll.deleteSync();
    expect(run('verify_owner_windows_package.ps1').exitCode, isNot(0));
    dll.writeAsBytesSync(bytes);
    config(target: 'lib/main.dart');
    expect(run('verify_owner_windows_package.ps1').exitCode, isNot(0));
    config(define: 'DATA_DIR_OVERRIDE=');
    expect(run('verify_owner_windows_package.ps1').exitCode, isNot(0));
    config();
    coreHash = '0' * 64;
    expect(run('verify_owner_windows_package.ps1').exitCode, isNot(0));
  });
  test(
    'inventory rejects path escape, missing build file and empty manifest',
    () {
      final original = manifest.readAsStringSync();
      final outside = put('${release.path}-outside/subdir/outside.dll', [2]);
      manifest.writeAsStringSync('$original\n${outside.path}');
      final escaped = run('package_owner_windows.ps1');
      expect(escaped.exitCode, isNot(0));
      expect(escaped.stderr, contains('outside the Release directory'));
      expect(package.existsSync(), isFalse);
      manifest.writeAsStringSync('');
      expect(run('package_owner_windows.ps1').exitCode, isNot(0));
      manifest.writeAsStringSync(original);
      File('${release.path}/sourin_core.dll').deleteSync();
      expect(run('package_owner_windows.ps1').exitCode, isNot(0));
    },
  );
  test('runtime native manifest must be installed even when a build intermediate exists', () {
    final original = manifest.readAsLinesSync();
    manifest.writeAsStringSync(
      original
          .where((path) => !path.endsWith('NativeAssetsManifest.json'))
          .join('\n'),
    );
    final result = run('package_owner_windows.ps1');
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('NativeAssetsManifest.json'));
    expect(package.existsSync(), isFalse);
  });
  test(
    'Windows PowerShell reads UTF-8 manifest paths without a BOM',
    () {
      const legacy =
          'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe';
      ps = legacy;
      final asset = put('${release.path}/data/flutter_assets/封面.png', [3]);
      manifest.writeAsStringSync(
        '${manifest.readAsStringSync()}\n${asset.path}',
      );
      final result = run('package_owner_windows.ps1');
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(
        File('${package.path}/data/flutter_assets/封面.png').existsSync(),
        isTrue,
      );
    },
    skip:
        File('C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe')
            .existsSync()
        ? false
        : 'Windows PowerShell 5.1 is not installed',
  );
}
