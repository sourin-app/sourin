import 'dart:convert';
import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/widgets/cover_image.dart';

const _expectedUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';
const _visibleTinyPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAD0lEQVR4nGNg+M8AQhAKABvyA/1tVLjHAAAAAElFTkSuQmCC';
const _transparentSentinelGif =
    'R0lGODlhBAAIAJECAP///wAAAP///wAAACH5BAEAAAIALAAAAAAEAAgAAAIFlI+piwUAOw==';
const _posterPng =
    'iVBORw0KGgoAAAANSUhEUgAAACAAAAAwCAIAAAD/zu84AAAAYklEQVR4nGNUDp3LQEvARFPTGUYtIAKMxgFBMBpEAx9ELLgkdgbOItUs9/VpmIKjkUwQjAYRQTAaRATBaBARBKNBRBCMBhFBMBpEBMFoEI2AIGIc7cYO/0hmGrWAEKB5EAEASO0FiyW/0WUAAAAASUVORK5CYII=';

class _FixtureHttp extends HttpOverrides {
  _FixtureHttp(this.port);

  final int port;
  final clients = <HttpClient>[];

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    clients.add(client);
    // Preserve the public request host for the production header policy, while
    // the fixture handles every byte locally and never reaches that host.
    client.findProxy = (_) => 'PROXY 127.0.0.1:$port';
    return client;
  }

  void close() {
    for (final client in clients) {
      client.close(force: true);
    }
  }
}

void main() {
  testWidgets('Douban cover headers apply only to exact image CDN hosts', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(),
        child: Builder(
          builder: (value) {
            context = value;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    NetworkImage provider(String url) {
      final image = coverImage(context, url: url, layoutWidth: 120);
      expect(image.runtimeType, Image);
      return (image.image as ResizeImage).imageProvider as NetworkImage;
    }

    for (final url in [
      'https://img2.doubanio.com/view/photo/public/poster.jpg',
      'https://img3.doubanio.com/view/photo/public/poster.jpg',
      'https://img9.doubanio.com/view/photo/public/poster.jpg',
      'http://img1.doubanio.com/view/photo/public/poster.jpg',
    ]) {
      final headers = provider(url).headers!;
      expect(headers['Referer'], 'https://movie.douban.com/');
      expect(headers['User-Agent'], _expectedUserAgent);
      expect(headers.keys, unorderedEquals(['Referer', 'User-Agent']));
    }

    for (final url in [
      'http://127.0.0.1:53002/s/cover-token',
      'https://gimg1.baidu.com/gimg/app=2001&src=poster.jpg',
      'https://i0.hdslb.com/poster.jpg',
      'https://movie.douban.com/poster.jpg',
      'https://img3.doubanio.com.example.invalid/poster.jpg',
      'https://notimg3.doubanio.com/poster.jpg',
      'https://img3.doubanio.com@example.invalid/poster.jpg',
      'file://img3.doubanio.com/poster.jpg',
    ]) {
      expect(provider(url).headers, isNull, reason: url);
    }

    const url = 'https://img3.doubanio.com/key.jpg';
    expect(provider(url), provider(url));
    expect(provider(url).hashCode, provider(url).hashCode);
    final cached = provider(url);
    final images = <NetworkImage, String>{cached: 'loaded'};
    expect(images[provider(url)], 'loaded');
    expect(images[provider('$url?variant=2')], isNull);
    expect(cached.headers, same(cached.headers));
    expect(
      provider(url),
      isNot(NetworkImage(url)),
      reason: 'A failed default-UA request must not share this image key',
    );
    final image = coverImage(
      context,
      url: url,
      layoutWidth: 120,
      layoutHeight: 180,
    );
    final resized = image.image as ResizeImage;
    expect(resized.width, isNull);
    expect(resized.height, 180);
  });

  testWidgets(
    'coverImage preserves headers and visible icons but rejects empty sentinels',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      late HttpServer server;
      var calls = 0;
      String? requestedHost;
      String? referer;
      List<String>? userAgents;
      await tester.runAsync(() async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          if (request.requestedUri.host == 'cover-fixture.invalid') {
            final path = request.uri.path;
            request.response.headers.contentType = ContentType(
              'image',
              path.endsWith('.gif') ? 'gif' : 'png',
            );
            request.response.add(
              base64Decode(
                path.endsWith('/empty.gif')
                    ? _transparentSentinelGif
                    : path.endsWith('/poster.png')
                    ? _posterPng
                    : _visibleTinyPng,
              ),
            );
            await request.response.close();
            return;
          }
          calls++;
          requestedHost = request.requestedUri.host;
          referer = request.headers.value(HttpHeaders.refererHeader);
          userAgents = request.headers[HttpHeaders.userAgentHeader];
          if (referer != 'https://movie.douban.com/' ||
              userAgents?.length != 1 ||
              userAgents!.single != _expectedUserAgent) {
            request.response.statusCode = 418;
          } else {
            request.response.headers.contentType = ContentType('image', 'png');
            request.response.add(base64Decode(_visibleTinyPng));
          }
          await request.response.close();
        });
      });
      final previous = HttpOverrides.current;
      final fixture = _FixtureHttp(server.port);
      HttpOverrides.global = fixture;
      addTearDown(() async {
        fixture.close();
        HttpOverrides.global = previous;
        await server.close(force: true);
      });
      Object? imageError;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => coverImage(
              context,
              url: 'http://img3.doubanio.com/cover-headers-fixture.png',
              layoutWidth: 120,
              errorBuilder: (_, error, __) {
                imageError = error;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
          if (find
              .byType(RawImage)
              .evaluate()
              .any(
                (element) =>
                    (element.renderObject as RenderImage).image != null,
              )) {
            break;
          }
        }
      });
      expect(calls, 1);
      expect(requestedHost, 'img3.doubanio.com');
      expect(referer, 'https://movie.douban.com/');
      expect(userAgents, [
        _expectedUserAgent,
      ], reason: 'The Dart default must be replaced, not appended');
      expect(imageError, isNull);
      final image = tester.renderObject<RenderImage>(find.byType(RawImage));
      expect(image.image?.width, 2);
      expect(image.image?.height, 2);
      expect(tester.takeException(), isNull);

      Future<void> showFixture(String file, {double width = 120}) async {
        // Finish the previous Image's error build before recording a new case.
        // Image retains its error until its next image stream is installed.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        imageError = null;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => coverImage(
                context,
                url: 'http://cover-fixture.invalid/$file',
                layoutWidth: width,
                errorBuilder: (_, error, __) {
                  imageError = error;
                  return const Text('cover unavailable');
                },
              ),
            ),
          ),
        );
        await tester.runAsync(() async {
          for (var i = 0; i < 50; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            await tester.pump();
            if (imageError != null ||
                find
                    .byType(RawImage)
                    .evaluate()
                    .any(
                      (element) =>
                          (element.renderObject as RenderImage).image != null,
                    ))
              break;
          }
        });
      }

      await showFixture('empty.gif');
      expect(imageError, isA<StateError>());
      expect(find.text('cover unavailable'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await showFixture('visible-icon.png');
      expect(
        imageError,
        isNull,
        reason: 'A visible 2 x 2 icon is still an image',
      );
      expect(
        tester.renderObject<RenderImage>(find.byType(RawImage)).image?.width,
        2,
      );
      expect(tester.takeException(), isNull);

      await showFixture('poster.png', width: 2);
      expect(
        imageError,
        isNull,
        reason: 'The resize cache dimensions are not intrinsic dimensions',
      );
      expect(
        tester.renderObject<RenderImage>(find.byType(RawImage)).image?.width,
        2,
      );
      expect(
        tester.renderObject<RenderImage>(find.byType(RawImage)).image?.height,
        3,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.close();
    },
  );
}
