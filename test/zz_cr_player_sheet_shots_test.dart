// 播放器设置面板的**看图台**（自用，不是断言型测试）—— 本批换控件后出图给人眼看。
//
// 跑法：
//   $env:SOURIN_SHOT_DIR = '.probe\shots'
//   flutter test test/zz_cr_player_sheet_shots_test.dart --concurrency=1
//
// ⚠️ 本文件**只**依赖面板本身（不吃 FFI 核心），flutter_tester 里能跑。
// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/player_settings_sheet.dart';

import 'support/ui_shot.dart';

Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    theme: theme,
    builder: (_, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: Scaffold(body: Stack(children: [child])),
  );
}

PlayerSettingsSheet _sheet({double? videoZoom = 100}) {
  return PlayerSettingsSheet(
    isLive: false,
    subtitleTracks: const [
      PlayerTrackOption(id: 'auto', label: '自动'),
      PlayerTrackOption(id: 'no', label: '关闭'),
      PlayerTrackOption(id: '1', label: '简体中文', hint: 'chi'),
    ],
    audioTracks: const [
      PlayerTrackOption(id: 'auto', label: '自动'),
      PlayerTrackOption(id: 'no', label: '关闭'),
      PlayerTrackOption(id: '1', label: '国语', hint: 'aac'),
    ],
    currentSubtitleId: '1',
    currentAudioId: '1',
    externalSubtitleName: null,
    mpvStyle: const {
      'sub-ass-override': 'no',
      'sub-font': 'Microsoft YaHei',
      'sub-font-size': '55',
      'sub-color': '1.00/1.00/1.00',
      'sub-border-color': '0.00/0.00/0.00',
      'sub-border-size': '1.65',
      'sub-margin-y': '0',
    },
    endAction: PlayEndAction.autoNext,
    countdownBeforeNext: true,
    keepSourceOnNext: true,
    autoSkip: true,
    rate: 1.0,
    isPlaying: true,
    clipDownloading: false,
    clipDownloaded: false,
    clipDownloadError: null,
    onSetConcurrency: (_) {},
    onDownloadClip: () {},
    onOpenClipDir: () {},
    onPickSubtitle: (_) {},
    onPickAudio: (_) {},
    onLoadSubtitleFile: (_) {},
    onRemoveExternalSubtitle: () {},
    onSetMpvProperty: (_, __) {},
    onSetEndAction: (_) {},
    onSetCountdown: (_) {},
    onSetKeepSource: (_) {},
    onSetAutoSkip: (_) {},
    onSetRate: (_) {},
    onClose: () {},
    hwdecMode: HwdecMode.auto,
    onSetHwdecMode: (_) {},
    videoZoom: videoZoom,
    onSetVideoZoom: (_) {},
  );
}

void main() {
  setUpAll(() async {
    await loadRealFonts();
  });

  testWidgets('播放器设置面板 出图（本批换控件后）', (t) async {
    await setShotViewport(t, const Size(700, 1100));
    await t.pumpWidget(_host(_sheet()));
    await t.pumpAndSettle();
    final f = await saveViewShot(t, 'player_settings_sheet');
    print('SHOT ${f.path}');
  });
}