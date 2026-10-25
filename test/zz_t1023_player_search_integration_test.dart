@Tags(['native-media'])
library;

import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/danmaku_search_page.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';
import 't102_playback_failure_banner_test.dart' as fixture;

void main() {
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
  });
  setUp(() => RemoteBridge.instance.stop());
  tearDown(() => RemoteBridge.instance.stop());

  testWidgets('settings production callback mounts search and Escape closes it', (t) async {
    await fixture.mountPlayer(t);
    expect(debugPlayerOpenDanmakuSettingsForProbe(), isTrue);
    await t.pump();
    final settings = t.widget<DanmakuSettingsDialog>(find.byType(DanmakuSettingsDialog));
    expect(settings.onOpenSearch, isNotNull);
    settings.onOpenSearch!();
    await t.pump();
    expect(find.byType(DanmakuSearchPage), findsOneWidget);
    // 设置面板保留 260ms 退出动画，结束后才卸载子树。
    await t.pump(const Duration(milliseconds: 300));
    await t.pump();
    expect(find.byType(DanmakuSettingsDialog), findsNothing);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    expect(find.byType(DanmakuSearchPage), findsNothing);
    await fixture.drain(t);
  });

  testWidgets('search close callback unmounts the real search page', (t) async {
    await fixture.mountPlayer(t);
    expect(debugPlayerOpenDanmakuSettingsForProbe(), isTrue);
    await t.pump();
    t.widget<DanmakuSettingsDialog>(find.byType(DanmakuSettingsDialog)).onOpenSearch!();
    await t.pump();
    final search = t.widget<DanmakuSearchPage>(find.byType(DanmakuSearchPage));
    search.onClose();
    await t.pump();
    expect(find.byType(DanmakuSearchPage), findsNothing);
    await fixture.drain(t);
  });
}
