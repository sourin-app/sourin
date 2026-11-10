import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/player_page.dart';

const _signedFailure =
    'Failed to open https://viewer:fixture-password@media.example.invalid:9090/'
    'play/fixture-private-path?token=fixture-query-secret&time=1790000000000.';

// Synthetic URI references only; never copy a real resolved media address here.
const _relativeOpaque =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _relativeMediaPath =
    '/tg/$_relativeOpaque/master.m3u8'
    '?verify=fixture-relative-verify&expires=1790000000123';
const _relativeFailure = 'Failed to open $_relativeMediaPath';

void _expectRelativeFieldsHidden(String text) {
  for (final value in <String>[
    '/tg/',
    _relativeOpaque,
    'master.m3u8',
    'fixture-relative-verify',
    '1790000000123',
  ]) {
    expect(text, isNot(contains(value)), reason: 'Relative playback fields are private');
  }
}

String _renderedText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((text) => text.data ?? text.textSpan?.toPlainText() ?? '')
    .join('\n');

void _expectPrivateFieldsHidden(String text) {
  for (final value in <String>[
    'https://',
    'viewer:',
    'fixture-password',
    'fixture-private-path',
    'fixture-query-secret',
    '1790000000000',
  ]) {
    expect(
      text.contains(value),
      isFalse,
      reason: 'Playback details are private',
    );
  }
}

Widget _errorCard(PlaybackFailure failure) => MaterialApp(
  home: Scaffold(
    body: PlayerErrorCardForProbe(
      failure: failure,
      onRetry: () {},
      onBack: () {},
    ),
  ),
);

Future<void> _capture(WidgetTester tester, String name) async {
  final directory = Platform.environment['PRIVACY_SHOT_DIR'] ?? '';
  if (directory.isEmpty) return;
  final render = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('privacy-capture')),
  );
  await tester.runAsync(() async {
    final image = await render.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory(directory).createSync(recursive: true);
    File('$directory/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  group('relative playback reference privacy', () {
    for (final path in <String>[
      _relativeMediaPath,
      '//cdn.example.invalid$_relativeMediaPath',
      'tg/$_relativeOpaque/master.m3u8?verify=fixture-relative-verify&expires=1790000000123',
    ]) {
      test('open failure hides URI reference form ${path.startsWith('//') ? 'network' : path.startsWith('/') ? 'root' : 'relative'}', () {
        final detail = PlaybackErrorText.classify(
          'Failed to open $path; HTTP status=502',
          hadCandidates: true,
        ).detail;
        _expectRelativeFieldsHidden(detail);
        expect(detail, isNot(contains('cdn.example.invalid')));
        expect(detail, contains('HTTP status=502'));
        expect(detail, contains('无法打开播放地址'));
        expect(PlaybackErrorText.forDisplay(detail), detail);
      });
    }

    test('CJK without spaces retains the readable cause around a private reference', () {
      final display = PlaybackErrorText.forDisplay(
        '播放失败：$_relativeMediaPath无法加载，请换条线路重试',
      );
      _expectRelativeFieldsHidden(display);
      expect(display, startsWith('播放失败：'));
      expect(display, endsWith('无法加载，请换条线路重试'));
      expect(display, contains('播放地址已隐藏'));
    });

    test('opaque path without a query is private in an open failure', () {
      final display = PlaybackErrorText.forDisplay(
        'Failed to open /tg/$_relativeOpaque; unsupported media format',
      );
      _expectRelativeFieldsHidden(display);
      expect(display, contains('unsupported media format'));
      expect(display, contains('无法打开播放地址'));
    });

    test('wrapped relative reference removes its opaque continuation', () {
      final detail = PlaybackErrorText.classify(
        'Failed to open /tg/$_relativeOpaque\n'
        '$_relativeOpaque?verify=fixture-relative-verify&expires=1790000000123\n'
        'HTTP status=502',
        hadCandidates: true,
      ).detail;
      _expectRelativeFieldsHidden(detail);
      expect(detail, contains('HTTP status=502'));
    });

    test('relative reference redaction preserves permission attribution', () {
      final failure = PlaybackErrorText.classify(
        'HTTP 403 Forbidden: $_relativeFailure',
        hadCandidates: true,
      );
      expect(failure.kind, PlaybackFailureKind.permission);
      expect(failure.canRetry, isFalse);
      _expectRelativeFieldsHidden(failure.detail);
      expect(failure.detail, contains('HTTP 403 Forbidden'));
    });

    test('ordinary readable explanations and slash-separated formats stay intact', () {
      for (final plain in <String>[
        'Failed to open something',
        'H.264/AVC 解码失败，请重试/返回',
        '分享里有多个视频，请选择具体文件',
        'Token expired; retry may succeed',
        'HTTP status=502，源暂时没有返回可用内容',
      ]) {
        expect(PlaybackErrorText.forDisplay(plain), plain);
      }
    });

    testWidgets('actual error card hides unclassified relative reference fields', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_errorCard(const PlaybackFailure(
        kind: PlaybackFailureKind.unknown,
        detail: _relativeFailure,
      )));
      await tester.pump();
      _expectRelativeFieldsHidden(_renderedText(tester));
      expect(find.text('播放失败'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('返回'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('actual interruption banner hides relative reference fields', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Stack(children: [
        playerPlaybackFailureBannerForProbe(
          message: _relativeFailure,
          onRetry: () {},
        ),
      ]))));
      await tester.pump();
      _expectRelativeFieldsHidden(_renderedText(tester));
      expect(find.text('重试'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  test('unknown candidate failure does not expose signed playback fields', () {
    final failure = PlaybackErrorText.classify(
      _signedFailure,
      hadCandidates: true,
    );
    expect(failure.kind, PlaybackFailureKind.unknown);
    expect(failure.canRetry, isTrue);
    _expectPrivateFieldsHidden(failure.detail);
    expect(failure.detail, isNotEmpty);
  });

  test('HTTP permission attribution survives playback URL redaction', () {
    final failure = PlaybackErrorText.classify(
      'HTTP 403 Forbidden: $_signedFailure',
      hadCandidates: true,
    );
    expect(failure.kind, PlaybackFailureKind.permission);
    expect(failure.canRetry, isFalse);
    expect(failure.detail, contains('HTTP 403 Forbidden'));
    _expectPrivateFieldsHidden(failure.detail);
  });

  test('multiple playback URLs do not leak through a single failure', () {
    final failure = PlaybackErrorText.classify(
      'Failed to open https://first.example.invalid/private-one?token=one '
      'or http://second.example.invalid/private-two?sign=two',
      hadCandidates: true,
    );
    for (final value in <String>[
      'https://',
      'http://',
      'private-one',
      'private-two',
      'token=one',
      'sign=two',
    ]) {
      expect(failure.detail.contains(value), isFalse);
    }
  });

  test('credentials on following diagnostic lines are hidden', () {
    final failure = PlaybackErrorText.classify(
      '$_signedFailure\n'
      'Authorization: Bearer fixture-bearer-secret\n'
      'Cookie: fixture-cookie-secret\n'
      'token=fixture-detached-secret; retry may succeed',
      hadCandidates: true,
    );
    _expectPrivateFieldsHidden(failure.detail);
    for (final value in <String>[
      'fixture-bearer-secret',
      'fixture-cookie-secret',
      'fixture-detached-secret',
    ]) {
      expect(failure.detail.contains(value), isFalse);
    }
    expect(failure.detail, contains('retry may succeed'));
  });

  test('loopback timeout retains attribution and neutral visible text', () {
    final failure = PlaybackErrorText.classify(
      'Failed to open http://127.0.0.1:12345/s/private-loopback?token=secret',
      hadCandidates: true,
      elapsed: const Duration(seconds: kPlaybackNetworkTimeoutSeconds),
    );
    expect(failure.kind, PlaybackFailureKind.timeout);
    expect(failure.detail, contains('内置代理取不到这条流'));
    expect(failure.detail.contains('12345'), isFalse);
    expect(failure.detail.contains('private-loopback'), isFalse);
  });

  test('ordinary plugin explanation and HTTP code remain readable', () {
    final failure = PlaybackErrorText.classify(
      'SourinCoreException(other): 插件报错: 分享里有多个视频，请选择具体文件',
    );
    expect(failure.detail, '分享里有多个视频，请选择具体文件');
  });

  for (final path in [
    "private(file).mp4?expires=fixture-secret",
    "private'file.mp4?expires=fixture-secret",
    '\u79c1\u6709\u6587\u4ef6.mp4?expires=fixture-secret',
  ]) {
    test(
      'ordinary diagnostic hides the entire special-character URL: $path',
      () {
        final display = PlaybackErrorText.forDisplay(
          'HTTP status=502 while loading https://cdn.invalid/$path',
        );
        expect(display, contains('HTTP status=502'));
        expect(display, isNot(contains(path)));
        expect(display, isNot(contains('fixture-secret')));
        expect(display, isNot(contains('https://')));
      },
    );
  }

  test(
    'same-line open failure keeps the HTTP diagnostic after the address',
    () {
      final failure = PlaybackErrorText.classify(
        'Failed to open https://cdn.invalid/private(file).mp4?expires=fixture-secret; '
        'HTTP status=502',
        hadCandidates: true,
      );
      expect(failure.detail, contains('HTTP status=502'));
      expect(failure.detail, isNot(contains('fixture-secret')));
      expect(failure.detail, isNot(contains('private(file)')));
      expect(failure.detail, isNot(contains('https://')));
    },
  );

  test(
    'expired-token diagnosis remains readable and display is idempotent',
    () {
      const expired = 'Token expired; retry may succeed';
      expect(PlaybackErrorText.forDisplay(expired), expired);
      final once = PlaybackErrorText.forDisplay(
        '$_signedFailure\nAuthorization: Bearer fixture-bearer-secret',
      );
      expect(PlaybackErrorText.forDisplay(once), once);
    },
  );

  test('hard-wrapped address continuation is not left in the explanation', () {
    const continuation = 'abcdef1234567890abcdef1234567890abcdef';
    final detail = PlaybackErrorText.classify(
      'Failed to open https://media.example.invalid/$continuation\n'
      '$continuation?token=fixture-query-secret&time=1790000000000.\n'
      'HTTP status=502',
      hadCandidates: true,
    ).detail;
    expect(detail.contains(continuation), isFalse);
    _expectPrivateFieldsHidden(detail);
    expect(detail, contains('HTTP status=502'));
  });

  testWidgets('production error widget hides unclean classified details', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('privacy-capture'),
        child: _errorCard(
          const PlaybackFailure(
            kind: PlaybackFailureKind.unknown,
            detail: _signedFailure,
          ),
        ),
      ),
    );
    await tester.pump();
    _expectPrivateFieldsHidden(_renderedText(tester));
    expect(find.text('播放失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('返回'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _capture(tester, 'error-desktop');
  });

  testWidgets('production error widget retains permission guidance', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('privacy-capture'),
        child: _errorCard(
          PlaybackErrorText.classify(
            'HTTP 403 Forbidden: $_signedFailure',
            hadCandidates: true,
          ),
        ),
      ),
    );
    await tester.pump();
    _expectPrivateFieldsHidden(_renderedText(tester));
    expect(find.text('重试'), findsNothing);
    expect(find.text('返回'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _capture(tester, 'error-mobile');
  });

  testWidgets('actual playback-interruption banner hides the same fields', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('privacy-capture'),
        child: MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                playerPlaybackFailureBannerForProbe(
                  message: _signedFailure,
                  onRetry: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    _expectPrivateFieldsHidden(_renderedText(tester));
    expect(find.text('重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _capture(tester, 'interruption-desktop');
  });
}
