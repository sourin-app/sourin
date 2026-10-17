@Tags(['needs-shot-dir'])
// ═══════════════════════════════════════════════════════════════════════
//  task-35 截图自查：设置页一级能看到 dan-api 配置
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件存在的原因
// Owner 的原话是「配置页没看到」。
// ⇒ 这条要求的验收**只能靠看图**：文字断言能证明「入口行存在」，
//    但证明不了「用户一眼能不能看到」。所以留一组截图给人读。
//
// ⚠️ 它是**自查工具**，不是断言文件：只断言截图落盘了。
//    把「好不好看」写成断言只会得到一条恒真的断言（本仓既有纪律）。
//
// # 跑法
// ```powershell
//   $env:SOURIN_SHOT_DIR = '.probe\shots-task35'
//   flutter test test/task35_danmaku_shots_test.dart --run-skipped \
//     --tags needs-shot-dir --concurrency=1
// ```

// hide ffi 的 Size —— 它和 dart:ui 的 Size 撞名，不 hide 每处 const Size(...) 都报错
import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings/danmaku_source_page.dart';
import 'package:sourin_spike/ui/settings_page.dart';

import 'support/ui_shot.dart';

Widget _app(Widget home) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.themeFor(Brightness.dark),
      home: Scaffold(body: home),
    );

/// 反复 pump 直到真内容画出来（理由见 zz_settings_shots_test.dart 同名函数）
///
/// ⚠️ `SettingsPage.initState` 会 await 一串走 FFI 的加载；
///    `testWidgets` 默认在 FakeAsync 下跑，��些 gap 永远不完成 ⇒ 截出一片黑。
Future<void> settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.pump();
  }
}

/// DLL 候选（见 setUpAll 里的说明）
const List<String> _dllCandidates = <String>[
  r'rust\sourin_core\target\debug\sourin_core.dll',
  r'build\windows\x64\runner\Release\sourin_core.dll',
  r'windows\sourin_core.dll',
];

void main() {
  final dataDir = Platform.environment['SOURIN_SHOT_DATA'];

  setUpAll(() async {
    loadRealFonts();
    /*
     * ⚠️ must preload the DLL by ABSOLUTE path first.
     *
     * `SourinCore._openLibrary()` on Windows only opens the BARE name
     * `sourin_core.dll` (ffi.dart:226) — looked up next to flutter_tester.exe,
     * which does not have it. Opening it once by absolute path maps the module
     * into this process, so the later bare-name open hits the loaded module.
     * Same trick as test/zz_ops13_mirror_write_test.dart:76-94.
     *
     * Candidate order: the debug build is the one that actually contains
     * `provider_danmaku_*`; `build/` / `windows/` copies may be older.
     */
    for (final c in _dllCandidates) {
      final f = File(c);
      if (!f.existsSync()) continue;
      try {
        DynamicLibrary.open(f.absolute.path);
        break;
      } catch (_) {
        // try the next candidate
      }
    }
    if (dataDir != null) await SourinCore.startAsync(dataDir);
  });

  setUp(() => UiPrefs.debugResetForTest());
  tearDown(() => UiPrefs.debugResetForTest());

  const gate = '需要真核心才能截到真实内容。跑法：带 SOURIN_SHOT_DIR=<输出目录> 与 '
      'SOURIN_SHOT_DATA=<临时数据目录> 跑。';

  testWidgets('★ 设置页一级 · 桌面（未配置 ⇒ 有引导）', (tester) async {
    if (dataDir == null) return markTestSkipped(gate);
    await setShotViewport(tester, const Size(1440, 900));
    await tester.pumpWidget(_app(const SettingsPage()));
    await settle(tester);
    await saveViewShot(tester, 'task35_settings_desktop_unconfigured');
  });

  testWidgets('★ 设置页一级 · 已配置 dan-api', (tester) async {
    if (dataDir == null) return markTestSkipped(gate);
    /*
     * ⚠️ 必须在 runAsync 里写偏好：`UiPrefs.set` 会排一个 300ms 的
     *    合并落盘定时器（ui_prefs.dart:107-113）。在 testWidgets 的
     *    FakeAsync 区里调用它 ⇒ 那个 Timer 永远等不到真实时钟，
     *    测试结束时报 "Pending timers" 并失败（本文件第一次跑就是这样）。
     *    runAsync 期间定时器按真实时钟走 ⇒ 定时器正常结清。
     */
    await tester.runAsync(() async {
      UiPrefs.setDanmakuEndpoint('http://127.0.0.1:9321');
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await setShotViewport(tester, const Size(1440, 900));
    await tester.pumpWidget(_app(const SettingsPage()));
    await settle(tester);
    await saveViewShot(tester, 'task35_settings_desktop_configured');
  });

  testWidgets('★ 设置页一级 · 手机', (tester) async {
    if (dataDir == null) return markTestSkipped(gate);
    await setShotViewport(tester, const Size(412, 915));
    await tester.pumpWidget(_app(const SettingsPage()));
    await settle(tester);
    await saveViewShot(tester, 'task35_settings_phone');
  });

  testWidgets('★ 弹幕源配置页（能改地址）', (tester) async {
    if (dataDir == null) return markTestSkipped(gate);
    await setShotViewport(tester, const Size(1440, 900));
    await tester.pumpWidget(_app(const DanmakuSourcePage()));
    await settle(tester, frames: 4);
    await saveViewShot(tester, 'task35_danmaku_source_page');
  });
}