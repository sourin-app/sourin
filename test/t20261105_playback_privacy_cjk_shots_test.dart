import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/player_page.dart';

const _fontFamily = 'PlaybackPrivacyCjk1105';

const _captureKey = ValueKey<String>('playback-privacy-cjk-capture');
const _syntheticFailure =
    '播放地址打开失败，稍后可重试。 '
    'Failed to open https://fixture-user:fixture-password@media.example.invalid/'
    'fixture-private-path?token=fixture-query-secret&time=1790000000000.\n'
    'Authorization: Bearer fixture-bearer-secret\n'
    'Cookie: fixture-cookie-secret\n'
    'token=fixture-detached-secret; retry may succeed';
const _bannerSyntheticFailure =
    '连接失败，请稍后重试。 '
    'https://fixture-user:fixture-password@media.example.invalid/'
    'fixture-private-path?token=fixture-query-secret&time=1790000000000';
const _privateMarkers = <String>[
  'https://',
  'http://',
  'fixture-user',
  'fixture-password',
  'fixture-private-path',
  'fixture-query-secret',
  '1790000000000',
  'fixture-bearer-secret',
  'fixture-cookie-secret',
  'fixture-detached-secret',
];

final _shots = <Map<String, Object?>>[];
String? _fontPath;
String? _iconFontPath;

bool _containsPrivateFields(String text) => _privateMarkers.any(text.contains);

String _visibleText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((text) => text.data ?? text.textSpan?.toPlainText() ?? '')
    .join('\n');

Future<void> _loadCjkFont() async {
  final windowsRoot = Platform.environment['SystemRoot'];
  if (windowsRoot == null || windowsRoot.isEmpty) {
    throw StateError(
      'SystemRoot is required to locate a local Windows CJK font',
    );
  }
  for (final name in ['simhei.ttf', 'msyh.ttc']) {
    final file = File('$windowsRoot/Fonts/$name');
    if (!await file.exists()) continue;
    final bytes = await file.readAsBytes();
    final loader = FontLoader(_fontFamily)
      ..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
    _fontPath = file.path;
    return;
  }
  throw StateError('A local CJK font is required; refusing unreadable shots');
}

Future<File> _materialIconFontFile() async {
  // Use the SDK selected by the test's package configuration, even when a
  // custom engine supplies the flutter_tester executable from another tree.
  final library = await Isolate.resolvePackageUri(
    Uri.parse('package:flutter/foundation.dart'),
  );
  if (library == null || !library.isScheme('file')) {
    throw StateError('Flutter SDK not found in the test package configuration');
  }
  final file = File.fromUri(
    library.resolve(
      '../../../bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    ),
  );
  if (!await file.exists()) {
    throw StateError(
      'MaterialIcons-Regular.otf missing from the Flutter SDK cache',
    );
  }
  return file;
}

Future<void> _loadIconFont() async {
  final file = await _materialIconFontFile();
  final bytes = await file.readAsBytes();
  final loader = FontLoader('MaterialIcons')
    ..addFont(Future.value(ByteData.sublistView(bytes)));
  await loader.load();
  _iconFontPath = file.path;
}

Widget _host(Widget child) {
  final base = AppTheme.themeFor(Brightness.dark);
  final theme = base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: _fontFamily),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: _fontFamily),
    filledButtonTheme: FilledButtonThemeData(
      style: base.filledButtonTheme.style?.copyWith(
        textStyle: WidgetStateProperty.resolveWith<TextStyle?>(
          (states) => base.filledButtonTheme.style?.textStyle
              ?.resolve(states)
              ?.copyWith(fontFamily: _fontFamily),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: base.outlinedButtonTheme.style?.copyWith(
        textStyle: WidgetStateProperty.resolveWith<TextStyle?>(
          (states) => base.outlinedButtonTheme.style?.textStyle
              ?.resolve(states)
              ?.copyWith(fontFamily: _fontFamily),
        ),
      ),
    ),
  );
  return RepaintBoundary(
    key: _captureKey,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      builder: (context, content) => AppThemeHost(
        data: theme,
        child: DefaultTextStyle.merge(
          style: const TextStyle(fontFamily: _fontFamily),
          child: content ?? const SizedBox.shrink(),
        ),
      ),
      home: Scaffold(body: child),
    ),
  );
}

void _checkReadableBounds(WidgetTester tester, Size viewport) {
  var cjkParagraphs = 0;
  for (final paragraph in tester.renderObjectList<RenderParagraph>(
    find.byType(RichText),
  )) {
    final text = paragraph.text.toPlainText();
    if (text.trim().isEmpty) continue;
    final position = paragraph.localToGlobal(Offset.zero);
    expect(position.dx, greaterThanOrEqualTo(-1));
    expect(position.dy, greaterThanOrEqualTo(-1));
    expect(
      position.dx + paragraph.size.width,
      lessThanOrEqualTo(viewport.width + 1),
    );
    expect(
      position.dy + paragraph.size.height,
      lessThanOrEqualTo(viewport.height + 1),
    );
    expect(paragraph.didExceedMaxLines, isFalse);
    for (final box in paragraph.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: text.length),
    )) {
      expect(box.left, greaterThanOrEqualTo(-1));
      expect(box.right, lessThanOrEqualTo(paragraph.size.width + 1));
      expect(box.top, greaterThanOrEqualTo(-1));
      expect(box.bottom, lessThanOrEqualTo(paragraph.size.height + 1));
    }
    if (RegExp(r'[\u3400-\u9fff]').hasMatch(text)) {
      cjkParagraphs++;
      expect(
        paragraph.text.style?.fontFamily,
        _fontFamily,
        reason: 'Rendered CJK paragraphs must use the loaded font explicitly',
      );
    }
  }
  expect(cjkParagraphs, greaterThanOrEqualTo(2));
}

Future<void> _capture(WidgetTester tester, String name, Size viewport) async {
  final directory = Platform.environment['PRIVACY_CJK_SHOT_DIR'] ?? '';
  if (directory.isEmpty) {
    throw StateError('A fresh isolated screenshot directory is required');
  }
  final text = _visibleText(tester);
  expect(_containsPrivateFields(text), isFalse);
  _checkReadableBounds(tester, viewport);
  expect(tester.takeException(), isNull);
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
  await tester.runAsync(() async {
    final target = File('$directory/$name.png');
    if (await target.exists()) {
      throw StateError('Refusing to overwrite executed screenshot evidence');
    }
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      expect(png, isNotNull);
      expect(image.width, viewport.width.toInt());
      expect(image.height, viewport.height.toInt());
      expect(png!.lengthInBytes, greaterThan(1000));
      await target.parent.create(recursive: true);
      await target.writeAsBytes(png.buffer.asUint8List(), flush: true);
      _shots.add({
        'file': target.absolute.path,
        'width': image.width,
        'height': image.height,
        'bytes': png.lengthInBytes,
        'redactionCheckedBeforeWrite': true,
        'loadedCjkFontExplicitlyApplied': true,
        'textBoundsChecked': true,
        'visibleText': text,
        'uiAccepted': false,
      });
    } finally {
      image.dispose();
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await _loadCjkFont();
    await _loadIconFont();
  });
  tearDownAll(() async {
    final directory = Platform.environment['PRIVACY_CJK_SHOT_DIR'] ?? '';
    if (directory.isEmpty) return;
    final report = File('$directory/widget-shots-report.json');
    if (await report.exists()) {
      throw StateError('Refusing to overwrite executed screenshot report');
    }
    await report.parent.create(recursive: true);
    await report.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'uiAccepted': false,
        'scope':
            'production playback error widget and banner visual checks only',
        'nativeApplicationUiVerified': false,
        'actualPlaybackVerified': false,
        'ownerDataRead': false,
        'syntheticDiagnosticMarkersOnly': true,
        'fontFamily': _fontFamily,
        'localFontPath': _fontPath,
        'localMaterialIconsFontPath': _iconFontPath,
        'shots': _shots,
      }),
      flush: true,
    );
  });

  test(
    'pre-write redaction guard rejects the unredacted synthetic fixture',
    () {
      expect(_containsPrivateFields(_syntheticFailure), isTrue);
      expect(
        _containsPrivateFields(PlaybackErrorText.forDisplay(_syntheticFailure)),
        isFalse,
      );
    },
  );

  for (final viewport in [
    (name: 'desktop', size: const Size(1280, 800)),
    (name: 'mobile360', size: const Size(360, 800)),
  ]) {
    testWidgets('CJK production unknown error ${viewport.name}', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(viewport.size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _host(
          PlayerErrorCardForProbe(
            failure: const PlaybackFailure(
              kind: PlaybackFailureKind.unknown,
              detail: _syntheticFailure,
            ),
            onRetry: () {},
            onBack: () {},
          ),
        ),
      );
      await tester.pump();
      expect(find.text('播放失败'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('返回'), findsOneWidget);
      expect(_visibleText(tester), contains('播放地址打开失败，稍后可重试。'));
      await _capture(tester, 'error-unknown-${viewport.name}', viewport.size);
    });

    testWidgets('CJK production permission error ${viewport.name}', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(viewport.size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final failure = PlaybackErrorText.classify(
        'HTTP 403 Forbidden: $_syntheticFailure',
        hadCandidates: true,
      );
      expect(failure.kind, PlaybackFailureKind.permission);
      await tester.pumpWidget(
        _host(
          PlayerErrorCardForProbe(
            failure: failure,
            onRetry: () {},
            onBack: () {},
          ),
        ),
      );
      await tester.pump();
      expect(find.text('重试'), findsNothing);
      expect(find.text('返回'), findsOneWidget);
      expect(_visibleText(tester), contains('HTTP 403 Forbidden'));
      await _capture(
        tester,
        'error-permission-${viewport.name}',
        viewport.size,
      );
    });

    testWidgets('CJK production interruption banner ${viewport.name}', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(viewport.size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _host(
          Stack(
            children: [
              playerPlaybackFailureBannerForProbe(
                message: _bannerSyntheticFailure,
                onRetry: () {},
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(find.text('播放中断了（画面还在，可以重试）'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      await _capture(tester, 'interruption-${viewport.name}', viewport.size);
    });
  }
}
