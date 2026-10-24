import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings/danmaku_source_page.dart';

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

void main() {
  const savedEndpoint = 'http://127.0.0.1:19321';
  const draftEndpoint = 'http://127.0.0.1:19322';
  const oldProxy = 'http://127.0.0.1:17890';
  const newProxy = 'http://127.0.0.1:17891';

  tearDown(() => UiPrefs.debugResetForTest());

  for (final changeAddress in [false, true]) {
    for (final outcome in ['success', 'offline', 'exception']) {
      testWidgets(
        '${changeAddress ? 'editing custom proxy' : 'switching proxy mode'} discards old $outcome probe',
        (tester) async {
          UiPrefs.debugResetForTest({
            'dsh.danmaku.endpoint': savedEndpoint,
            UiPrefs.danmakuTokenKey: 'saved-token',
            UiPrefs.danmakuProxyModeKey: changeAddress ? 'custom' : 'direct',
            UiPrefs.danmakuProxyUrlKey: oldProxy,
          });
          final pending = Completer<DanmakuLocalStatus>();
          final requested = <DanmakuEndpoint?>[];
          await tester.pumpWidget(MaterialApp(
            theme: AppTheme.themeFor(Brightness.dark),
            home: Scaffold(body: DanmakuSourcePage(
              probeOverride: (endpoint) {
                requested.add(endpoint);
                return pending.future;
              },
            )),
          ));
          await tester.pumpAndSettle();
          final serviceAddress = find.byType(TextField).first;
          expect(serviceAddress, findsOneWidget);
          await tester.ensureVisible(serviceAddress);
          await tester.enterText(serviceAddress, draftEndpoint);
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('测试连接'));
          await tester.tap(find.text('测试连接'));
          await tester.pump();
          expect(requested, hasLength(1));
          expect(requested.single?.baseUrl, draftEndpoint);
          expect(find.text('正在测试…'), findsOneWidget);

          if (changeAddress) {
            final proxyAddress = _field('代理地址');
            await tester.ensureVisible(proxyAddress);
            await tester.enterText(proxyAddress, newProxy);
          } else {
            await tester.ensureVisible(find.text('跟随系统代理'));
            await tester.tap(find.text('跟随系统代理'));
          }
          await tester.pump();
          expect(UiPrefs.danmakuProxyMode, changeAddress ? 'custom' : 'system');
          expect(UiPrefs.danmakuProxyUrl, changeAddress ? newProxy : '');

          const staleVersion = 'stale-probe-version';
          const staleError = 'stale-probe-exception';
          const staleStatus = DanmakuLocalStatus(
            online: false,
            endpoint: DanmakuEndpoint(baseUrl: draftEndpoint),
          );
          if (outcome == 'exception') {
            pending.completeError(const SocketException(staleError));
          } else {
            pending.complete(outcome == 'success'
              ? const DanmakuLocalStatus(
                  online: true,
                  version: staleVersion,
                  endpoint: DanmakuEndpoint(baseUrl: draftEndpoint),
                )
              : staleStatus);
          }
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pumpAndSettle();

          await tester.scrollUntilVisible(
            find.text('测试连接'), -250,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          // Read rendered output and persisted preferences, not private state.
          expect(find.textContaining(staleVersion), findsNothing);
          expect(find.textContaining(staleError), findsNothing);
          expect(find.text(staleStatus.line), findsNothing);
          expect(find.text('正在测试…'), findsNothing);
          expect(UiPrefs.danmakuEndpoint, savedEndpoint,
            reason: 'An old successful probe must not save its draft endpoint.');
          expect(UiPrefs.danmakuToken, 'saved-token');
          expect(UiPrefs.danmakuProxyMode, changeAddress ? 'custom' : 'system');
          expect(UiPrefs.danmakuProxyUrl, changeAddress ? newProxy : '');
          await tester.ensureVisible(find.text('测试连接'));
          expect(tester.widget<FilledButton>(
            find.widgetWithText(FilledButton, '测试连接'),
          ).onPressed, isNotNull);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 400));
        },
      );
    }
  }

  for (final changeAddress in [false, true]) {
    for (final oldThrows in [false, true]) {
      testWidgets(
        '${changeAddress ? 'editing custom proxy' : 'switching proxy mode'} keeps newer result after old ${oldThrows ? 'exception' : 'success'}',
        (tester) async {
          UiPrefs.debugResetForTest({
            'dsh.danmaku.endpoint': savedEndpoint,
            UiPrefs.danmakuTokenKey: 'saved-token',
            UiPrefs.danmakuProxyModeKey: changeAddress ? 'custom' : 'direct',
            UiPrefs.danmakuProxyUrlKey: oldProxy,
          });
          final oldRequest = Completer<DanmakuLocalStatus>();
          final newRequest = Completer<DanmakuLocalStatus>();
          var requests = 0;
          await tester.pumpWidget(MaterialApp(
            theme: AppTheme.themeFor(Brightness.dark),
            home: Scaffold(body: DanmakuSourcePage(
              probeOverride: (endpoint) {
                requests++;
                expect(endpoint?.baseUrl, savedEndpoint);
                expect(requests, lessThanOrEqualTo(2));
                return requests == 1 ? oldRequest.future : newRequest.future;
              },
            )),
          ));
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('测试连接'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('测试连接'));
          await tester.pump();
          expect(requests, 1);
          expect(find.text('正在测试…'), findsOneWidget);

          if (changeAddress) {
            final proxyAddress = _field('代理地址');
            await tester.ensureVisible(proxyAddress);
            await tester.enterText(proxyAddress, newProxy);
          } else {
            await tester.scrollUntilVisible(
              find.text('跟随系统代理'), 250,
              scrollable: find.byType(Scrollable).first,
            );
            // 旧请求尚未完成，加载动画持续运行，此处只推进滚动帧。
            await tester.pump(const Duration(milliseconds: 400));
            await tester.tap(find.text('跟随系统代理'));
          }
          await tester.pumpAndSettle();
          expect(UiPrefs.danmakuProxyMode, changeAddress ? 'custom' : 'system');
          expect(UiPrefs.danmakuProxyUrl, changeAddress ? newProxy : '');
          await tester.scrollUntilVisible(
            find.text('测试连接'), -250,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          expect(tester.widget<FilledButton>(
            find.widgetWithText(FilledButton, '测试连接'),
          ).onPressed, isNotNull);
          await tester.tap(find.text('测试连接'));
          await tester.pump();
          expect(requests, 2);

          newRequest.complete(const DanmakuLocalStatus(
            online: true,
            version: 'newer-probe-version',
            endpoint: DanmakuEndpoint(baseUrl: savedEndpoint),
          ));
          await tester.pumpAndSettle();
          expect(find.textContaining('newer-probe-version'), findsOneWidget);
          expect(find.text('正在测试…'), findsNothing);

          if (oldThrows) {
            oldRequest.completeError(const SocketException('older-probe-error'));
          } else {
            oldRequest.complete(const DanmakuLocalStatus(
              online: true,
              version: 'older-probe-version',
              endpoint: DanmakuEndpoint(baseUrl: savedEndpoint),
            ));
          }
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pumpAndSettle();
          expect(find.textContaining('newer-probe-version'), findsOneWidget,
            reason: 'The newer successful result survives the late old response.');
          expect(find.textContaining('older-probe-version'), findsNothing);
          expect(find.textContaining('older-probe-error'), findsNothing);
          expect(find.text('正在测试…'), findsNothing);
          expect(UiPrefs.danmakuEndpoint, savedEndpoint);
          expect(UiPrefs.danmakuToken, 'saved-token');
          expect(UiPrefs.danmakuProxyMode, changeAddress ? 'custom' : 'system');
          expect(UiPrefs.danmakuProxyUrl, changeAddress ? newProxy : '');
          expect(tester.widget<FilledButton>(
            find.widgetWithText(FilledButton, '测试连接'),
          ).onPressed, isNotNull);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 400));
        },
      );
    }
  }
}
