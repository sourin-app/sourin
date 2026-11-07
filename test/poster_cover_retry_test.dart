import 'dart:convert';
import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/widgets/poster_card.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  testWidgets(
    'temporary image failure retries same URL and renders decoded image',
    (tester) async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = _RealHttp();
      addTearDown(() => HttpOverrides.global = previous);
      var calls = 0;
      late HttpServer server;
      await tester.runAsync(() async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          calls++;
          if (calls == 1) {
            request.response.statusCode = 503;
          } else {
            request.response.headers.contentType = ContentType('image', 'png');
            request.response.add(
              base64Decode(
                'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAD0lEQVR4nGNg+M8AQhAKABvyA/1tVLjHAAAAAElFTkSuQmCC',
              ),
            );
          }
          await request.response.close();
        });
      });
      addTearDown(() => server.close(force: true));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: PosterCard(
                title: 'Retry cover',
                width: 120,
                cover: 'http://127.0.0.1:${server.port}/cover',
              ),
            ),
          ),
        ),
      );
      Future<void> settleImage() async {
        await tester.runAsync(() async {
          for (var i = 0; i < 15; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            await tester.pump();
          }
        });
      }

      await settleImage();
      expect(calls, 1);
      await tester.pump(const Duration(seconds: 3));
      // HTTP completion schedules its retry in runAsync's real-clock zone.
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 3)));
      await settleImage();
      expect(calls, 2);
      final images = tester.renderObjectList<RenderImage>(
        find.byType(RawImage),
      );
      expect(images.any((image) => image.image != null), isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
