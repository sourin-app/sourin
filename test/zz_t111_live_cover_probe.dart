// T111-LIVE: exercise the REAL dandanplay API (not a fake transport)
//
// Why this exists: the unit tests use a fake transport, which only proves the
// logic is self-consistent. It cannot prove the official API really returns an
// imageUrl, nor that the URL really downloads. Owner asked "can it?" -- that
// answer has to come from a real request.
//
// Credentials come from --dart-define, never hard-coded. With no credentials
// every test here is SKIPPED, so this can never be a silent false green.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/danmaku.dart';

const String kAppId = String.fromEnvironment('DANDANPLAY_APP_ID');
const String kAppSecret = String.fromEnvironment('DANDANPLAY_APP_SECRET');

void main() {
  final hasCred = kAppId.isNotEmpty && kAppSecret.isNotEmpty;

  group('T111-LIVE real API', () {
    test('** search really returns results, each with a downloadable cover', () async {
      final c = ExternalDanmakuClient(appId: kAppId, appSecret: kAppSecret);
      final found = await c.searchEpisodes(anime: '葬送的芙莉莲');

      expect(found, isNotEmpty, reason: 'real API must find something (else creds or endpoint are broken)');
      print('  found=' + found.length.toString());

      final first = found.first;
      print('  animeTitle=' + first.animeTitle);
      print('  episodeTitle=' + first.episodeTitle);
      print('  cover=' + first.cover);

      expect(first.cover, isNotEmpty,
          reason: '** a cover MUST come back -- this is exactly what Owner asked');
      expect(first.cover.startsWith('http'), isTrue);

      // The decisive check: the cover URL must really download (not a dead link).
      final cli = HttpClient();
      try {
        final req = await cli.getUrl(Uri.parse(first.cover));
        final resp = await req.close();
        expect(resp.statusCode, 200, reason: '** cover URL must be 200; a dead link means nothing was delivered');
        final bytes = await resp.fold<int>(0, (n, b) => n + b.length);
        print('  cover bytes=' + bytes.toString() + '  type=' + resp.headers.contentType.toString());
        expect(bytes, greaterThan(1000), reason: 'must be a real image, not an empty response');
      } finally {
        cli.close(force: true);
      }
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('* every episode of one work carries the same cover (one request gets all)', () async {
      final c = ExternalDanmakuClient(appId: kAppId, appSecret: kAppSecret);
      final found = await c.searchEpisodes(anime: '孤独摇滚');
      expect(found, isNotEmpty);
      final covers = found.map((m) => m.cover).where((s) => s.isNotEmpty).toSet();
      print('  episodes=' + found.length.toString() + '  distinct_covers=' + covers.length.toString());
      expect(covers.length, lessThanOrEqualTo(2),
          reason: 'one work should have one cover; many distinct covers means the wrong object was read');
      expect(covers, isNotEmpty, reason: 'at least one cover is required');
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('* a missing work does not crash (no cover still leaves search working)', () async {
      final c = ExternalDanmakuClient(appId: kAppId, appSecret: kAppSecret);
      final found = await c.searchEpisodes(anime: 'zzzNOPEzzzNoSuchWork');
      print('  found=' + found.length.toString() + ' (0 is expected)');
      expect(found, isEmpty);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('* without credentials it fails loudly (not a silent empty result)', () async {
      final c = ExternalDanmakuClient(appId: '', appSecret: '');
      expect(c.isConfigured, isFalse);
      await expectLater(
        c.searchEpisodes(anime: '葬送的芙莉莲'),
        throwsA(isA<DanmakuException>()),
        reason: 'with no credentials it must raise, not pretend it found 0',
      );
    }, timeout: const Timeout(Duration(seconds: 60)));
  }, skip: hasCred ? false : "need --dart-define=DANDANPLAY_APP_ID/_APP_SECRET");
}