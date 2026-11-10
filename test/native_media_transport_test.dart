import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/core/native_media_transport.dart';

// These callbacks model only the native property boundary. They deliberately
// do not reflect a written map back as a read result: ignored setters and
// unsupported readbacks must prevent the continuation from opening media.
class _NativeBoundary extends Fake implements NativePlayer {
  _NativeBoundary({required this.write, required this.read});

  final Future<void> Function(String name, String value) write;
  final Future<String> Function(String name) read;

  @override
  Future<void> setProperty(String name, String value,
          {bool waitForInitialization = true}) =>
      write(name, value);

  @override
  Future<String> getProperty(String name,
          {bool waitForInitialization = true}) =>
      read(name);
}

class _OtherPlatform extends Fake implements PlatformPlayer {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('A non-native platform must not receive native properties');
}

void main() {
  test('native policy finishes both writes and confirmed read before opening', () async {
    final events = <String>[];
    final proxyWrite = Completer<void>();
    final streamWrite = Completer<void>();
    final confirmedRead = Completer<String>();
    final native = _NativeBoundary(
      write: (name, value) {
        events.add('write $name=$value');
        if (name == 'http-proxy') return proxyWrite.future;
        if (name == 'stream-lavf-o') return streamWrite.future;
        throw StateError('Unexpected property');
      },
      read: (name) {
        events.add('read $name');
        return confirmedRead.future;
      },
    );
    final opened = prepareNativeMediaTransport(native).then((_) => events.add('open'));
    expect(events, ['write http-proxy=']);
    proxyWrite.complete();
    await Future<void>.delayed(Duration.zero);
    expect(events, ['write http-proxy=', 'write stream-lavf-o=http_proxy=']);
    streamWrite.complete();
    await Future<void>.delayed(Duration.zero);
    expect(events, ['write http-proxy=', 'write stream-lavf-o=http_proxy=', 'read stream-lavf-o']);
    confirmedRead.complete('http_proxy=');
    await opened;
    expect(events, ['write http-proxy=', 'write stream-lavf-o=http_proxy=', 'read stream-lavf-o', 'open']);
  });

  for (final readback in ['', 'http_proxy=http://proxy.invalid:8080', 'http_proxy']) {
    test('ignored or unconfirmed stream policy blocks open: ${readback.isEmpty ? 'missing' : readback}', () async {
      final events = <String>[];
      final native = _NativeBoundary(
        write: (name, _) async { events.add(name); },
        read: (name) async { events.add('read $name'); return readback; },
      );
      await expectLater(
        prepareNativeMediaTransport(native).then((_) => events.add('open')),
        throwsA(isA<NativeMediaTransportException>()),
      );
      expect(events, ['http-proxy', 'stream-lavf-o', 'read stream-lavf-o']);
    });
  }

  for (final failingProperty in ['http-proxy', 'stream-lavf-o']) {
    test('write failure blocks subsequent policy work and open: $failingProperty', () async {
      final events = <String>[];
      final native = _NativeBoundary(
        write: (name, _) async {
          events.add(name);
          if (name == failingProperty) throw StateError('native transport failure');
        },
        read: (_) async { events.add('read'); return 'http_proxy='; },
      );
      await expectLater(
        prepareNativeMediaTransport(native).then((_) => events.add('open')),
        throwsA(isA<NativeMediaTransportException>()),
      );
      expect(events, failingProperty == 'http-proxy'
          ? ['http-proxy'] : ['http-proxy', 'stream-lavf-o']);
    });
  }

  test('read failure blocks open and exposes only a neutral error', () async {
    final native = _NativeBoundary(
      write: (_, __) async {},
      read: (_) async => throw StateError('http://secret.invalid/stream?token=fixture'),
    );
    var opened = false;
    await expectLater(
      prepareNativeMediaTransport(native).then((_) => opened = true),
      throwsA(isA<NativeMediaTransportException>().having(
        (error) => error.toString(), 'message', '播放连接配置未能完成，请重试。')),
    );
    expect(opened, isFalse);
  });

  test('non-native and missing platforms do not call native properties', () async {
    final opened = <String>[];
    await prepareNativeMediaTransport(_OtherPlatform());
    opened.add('other');
    await prepareNativeMediaTransport(null);
    opened.add('missing');
    expect(opened, ['other', 'missing']);
  });
}
