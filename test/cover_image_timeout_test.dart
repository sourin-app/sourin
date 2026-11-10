import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/widgets/cover_image.dart';

const _validPoster =
    'iVBORw0KGgoAAAANSUhEUgAAACAAAAAwCAIAAAD/zu84AAAAYklEQVR4nGNUDp3LQEvARFPTGUYtIAKMxgFBMBpEAx9ELLgkdgbOItUs9/VpmIKjkUwQjAYRQTAaRATBaBARBKNBRBCMBhFBMBpEBMFoEI2AIGIc7cYO/0hmGrWAEKB5EAEASO0FiyW/0WUAAAAASUVORK5CYII=';

class _LocalProxy extends HttpOverrides {
  _LocalProxy(this.port);
  final int port;
  final clients = <HttpClient>[];
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (_) => 'PROXY 127.0.0.1:$port';
    clients.add(client);
    return client;
  }
}

void main() {
  testWidgets(
    'stalled covers time out, preserve HTTP failures, and can recover',
    (tester) async {
      late HttpServer server;
      final requests = <HttpRequest>[];
      final bytes = base64Decode(_validPoster);
      var recover = false;
      await tester.runAsync(() async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          requests.add(request);
          unawaited(
            request.response.done.then<void>(
              (_) {},
              onError: (Object _, StackTrace __) {},
            ),
          );
          final response = request.response;
          response.bufferOutput = false;
          response.headers.contentType = ContentType('image', 'png');
          try {
            switch (request.uri.path) {
              case '/progressive.png':
                response.contentLength = bytes.length;
                response.add(bytes.take(8).toList());
                await response.flush();
                return;
              case '/headers.png':
                return;
              case '/error.png':
                response.statusCode = HttpStatus.serviceUnavailable;
                response.write('retry later');
                await response.flush();
                return;
              case '/body.png':
                if (!recover) {
                  response.contentLength = bytes.length;
                  response.add(bytes.take(8).toList());
                  await response.flush();
                  return;
                }
                final compressed = gzip.encode(bytes);
                response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
                response.contentLength = compressed.length;
                response.add(compressed);
                await response.close();
            }
          } catch (_) {
            // The production client is expected to cancel stalled responses.
          }
        });
      });
      final previous = HttpOverrides.current;
      final proxy = _LocalProxy(server.port);
      HttpOverrides.global = proxy;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        for (final client in proxy.clients) {
          client.close(force: true);
        }
        HttpOverrides.global = previous;
        await server.close(force: true);
      });
      Object? error;
      final progress = <ImageChunkEvent>[];
      Future<void> drainIo() async {
        await tester.runAsync(() async {
          for (var i = 0; i < 60; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump();
          }
        });
      }

      Future<void> show(String path) async {
        await tester.pumpWidget(const SizedBox.shrink());
        error = null;
        progress.clear();
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => coverImage(
                context,
                url: 'http://cover-wait.invalid/$path',
                layoutWidth: 120,
                loadingBuilder: (_, child, event) {
                  if (event != null) progress.add(event);
                  return child;
                },
                errorBuilder: (_, value, __) {
                  error = value;
                  return const Text('cover unavailable');
                },
              ),
            ),
          ),
        );
        await drainIo();
      }

      await show('headers.png');
      expect(requests.length, 1);
      expect(error, isNull);
      await tester.pump(const Duration(seconds: 21));
      await drainIo();
      expect(
        error,
        isA<TimeoutException>(),
        reason: 'waiting for response headers must finish',
      );
      expect(find.text('cover unavailable'), findsOneWidget);

      await show('body.png');
      expect(requests.length, 2);
      expect(progress, isNotEmpty, reason: 'the real HTTP body has started');
      expect(error, isNull);
      await tester.pump(const Duration(seconds: 21));
      await drainIo();
      expect(
        error,
        isA<TimeoutException>(),
        reason: 'a partial image must not wait forever',
      );
      expect(find.text('cover unavailable'), findsOneWidget);

      await show('error.png');
      expect(requests.length, 3);
      expect(
        error,
        isA<NetworkImageLoadException>(),
        reason: 'a rejected status must not wait for its body',
      );
      expect((error! as NetworkImageLoadException).statusCode, 503);

      // Late server writes after cancellation must not emit into a closed chunk stream.
      await tester.runAsync(() async {
        try {
          requests[1].response.add(bytes.skip(8).toList());
          await requests[1].response.close();
        } catch (_) {}
      });
      await drainIo();
      recover = true;
      await show('body.png');
      expect(
        requests.length,
        4,
        reason: 'a failed image must be evicted so the same URL can retry',
      );
      expect(error, isNull);
      final image = tester.renderObject<RenderImage>(find.byType(RawImage));
      expect(image.image?.width, 32);
      expect(image.image?.height, 48);
      expect(progress, isNotEmpty);

      // A slow but progressing cover is allowed to span more than 20 seconds.
      // Its idle deadline resets from actual bytes, not from starting a retry.
      await show('progressive.png');
      expect(requests.length, 5);
      expect(progress.last.cumulativeBytesLoaded, 8);
      final partial = requests.last.response;
      await tester.pump(const Duration(seconds: 15));
      await tester.runAsync(() async {
        partial.add(bytes.sublist(8, 16));
        await partial.flush();
      });
      await drainIo();
      expect(progress.last.cumulativeBytesLoaded, 16);
      expect(error, isNull);
      await tester.pump(const Duration(seconds: 15));
      await tester.runAsync(() async {
        partial.add(bytes.sublist(16));
        await partial.close();
      });
      await drainIo();
      expect(error, isNull);
      final progressive = tester.renderObject<RenderImage>(
        find.byType(RawImage),
      );
      expect(progressive.image?.width, 32);
      expect(progressive.image?.height, 48);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      for (final client in proxy.clients) {
        client.close(force: true);
      }
    },
  );
}
