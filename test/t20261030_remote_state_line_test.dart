// ═══════════════════════════════════════════════════════════════════════
//  现场反馈批次 2026-10-30：1.1 类推（lead 预授权）—— 遥控端选集不平铺
//  /api/state 的 episodes 只报当前线路；goto_episode 回查同口径
// ═══════════════════════════════════════════════════════════════════════
//
// # 真机读数（driver-ops drive-20261029-234208.json）
// ```text
// /api/state: episode_count=2913，episodes 把 1..164 重复了 ~17 遍
// ⇒ 手机选集面板同样在平铺全部线路（与 1.1 右侧详情栏同根因）。
// ```
//
// # 判据
// ```text
// ① 真 _remoteGetState：多线路源（17×27）⇒ episodeCount=27、episodes 只含
//    当前线路（BD_*），切线路后列表跟着换（BF_*）；
// ② goto_episode 的集号回查也只在本线路找（列表口径与回查口径必须一致，
//    否则手机点第 5 集会落到第一条线路的同集号）—— 静态窗口断言钉住。
// ```
//
// # 故障注入（实测见笔记）
// ```text
// 注入①：_remoteGetState 的列表退回全集 _episodes ⇒ 组①红；
// 注入②：goto_episode 回查退回全集 ⇒ 窗口断言红。
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/player_page.dart';

List<String> _libmpvCandidates() => Platform.isWindows
    ? <String>[
        r'build\windows\x64\libmpv\libmpv-2.dll',
        r'build\windows\x64\runner\Release\libmpv-2.dll',
      ]
    : <String>['/usr/lib/x86_64-linux-gnu/libmpv.so.2'];

String? _libmpv;

void _prepareLibmpvFixture() {
  for (final rel in _libmpvCandidates()) {
    final f = File(rel);
    if (f.existsSync()) {
      _libmpv = f.absolute.path;
      MediaKit.ensureInitialized(libmpv: _libmpv);
      return;
    }
  }
}

bool _requireLibmpv() => _libmpv != null;

const List<String> _lines = ['BD', 'BF', 'FF'];

List<Episode> _episodes17x27() => [
      for (final line in _lines)
        for (var i = 1; i <= 27; i++)
          Episode(
            id: '$line|$i',
            title: '${line}_第${i.toString().padLeft(2, '0')}集',
            flag: line,
          ),
    ];

List<Episode> _eps3() => [
      for (var i = 1; i <= 3; i++)
        Episode(id: 'e$i', title: '第$i集', url: 'https://x.invalid/$i.m3u8'),
    ];

Future<void> _mount(WidgetTester t) async {
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  final episodes = _eps3();
  await t.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        provider: 'cctv',
        id: 'cctv-1',
        title: '遥控选集过滤测试',
        episodes: episodes,
        episodeIndex: 0,
        episodeId: episodes.first.id,
        episodeTitle: episodes.first.title,
        isTv: false,
        isTouchOnly: false,
      ),
    ),
  );
  await t.pump();
  debugPlayerClearErrorForProbe();
  // ★ 灌**生产 episodes**（走真 updateEpisodes ⇒ _syncSelectedFlag 同步当前线路）
  final el = t.element(find.byType(PlayerPage)) as StatefulElement;
  // ignore: avoid_dynamic_calls
  (el.state as dynamic).updateEpisodes(_episodes17x27());
  await t.pump();
}

void main() {
  setUpAll(_prepareLibmpvFixture);

  testWidgets('① 真 _remoteGetState：/api/state 的 episodes 只含当前线路', (t) async {
    if (!_requireLibmpv()) return;
    await _mount(t);

    final st0 = debugPlayerRemoteStateForProbe();
    expect(st0.hasMedia, isTrue, reason: '前提：探针拿到的是真实 state（idle=没挂上）');
    expect(st0.episodeCount, 27,
        reason: '★★ 17 线路×27 集 ⇒ 遥控选集只报当前线路的 27 集，不是 81/2913');
    expect(st0.episodes.length, 27);
    expect(st0.episodes.every((e) => e.$2.startsWith('BD_')), isTrue,
        reason: '列表必须只含当前线路（默认第一条）的集');
    expect(st0.episodes.first, (1, 'BD_第01集'), reason: '集号口径不变（标题解析优先）');

    // 切线路（真 _pickEpisodeFlag）⇒ 列表跟着换
    expect(debugPlayerPickEpisodeFlagForProbe('BF'), isTrue);
    final st1 = debugPlayerRemoteStateForProbe();
    expect(st1.episodeCount, 27);
    expect(st1.episodes.every((e) => e.$2.startsWith('BF_')), isTrue,
        reason: '当前线路切到 BF ⇒ 手机选集列表也要跟着切（改前平铺全部线路）');
  });

  group('② goto_episode 回查同口径（静态窗口断言 —— dispatch 全链含 FFI 不可达）', () {
    late String src;
    setUpAll(() {
      final raw = File('lib/ui/player_page.dart').readAsStringSync();
      // 剥注释（t61 同款状态机要点）
      final out = StringBuffer();
      var i = 0;
      String? quote;
      while (i < raw.length) {
        final c = raw[i];
        final n = i + 1 < raw.length ? raw[i + 1] : '';
        if (quote != null) {
          if (c == r'\') {
            out.write(c);
            if (n.isNotEmpty) {
              out.write(n);
              i += 2;
              continue;
            }
          }
          if (c == quote) quote = null;
          out.write(c);
          i++;
          continue;
        }
        if (c == "'" || c == '"') {
          quote = c;
          out.write(c);
          i++;
          continue;
        }
        if (c == '/' && n == '/') {
          while (i < raw.length && raw[i] != '\n') {
            i++;
          }
          continue;
        }
        if (c == '/' && n == '*') {
          i += 2;
          while (i < raw.length &&
              !(raw[i] == '*' && i + 1 < raw.length && raw[i + 1] == '/')) {
            if (raw[i] == '\n') out.write('\n');
            i++;
          }
          i += 2;
          continue;
        }
        out.write(c);
        i++;
      }
      src = out.toString();
    });

    test('★★ episodes 列表真用 episodesForLine（不再平铺全集）', () {
      final start = src.indexOf('RemoteState _remoteGetState()');
      // ★ 终点用**代码**锚（下一个成员签名）——注释会被剥掉，不能当锚
      final end = src.indexOf('Future<void> _remoteExec', start);
      expect(start, greaterThan(0));
      expect(end, greaterThan(start));
      final win = src.substring(start, end);
      expect(win.contains('episodesForLine(_episodes, _selectedFlag)'), isTrue,
          reason: '列表过滤必须真在生产方法里（判据公共函数，不抄第二份）');
      expect(win.contains('for (var i = 0; i < _episodes.length; i++)'), isFalse,
          reason: '注入证据：退回全集平铺时本条红');
    });

    test('★★ goto_episode 回查也只在本线路找（与列表口径一致）', () {
      final start = src.indexOf("case 'goto_episode':");
      final end = src.indexOf("case 'seek':", start);
      expect(start, greaterThan(0));
      expect(end, greaterThan(start));
      final win = src.substring(start, end);
      expect(win.contains('episodesForLine(_episodes, _selectedFlag)'), isTrue,
          reason: '手机发来的集号来自已过滤的列表 ⇒ 回查也必须在本线路找，'
              '否则点第 5 集落到第一条线路的同集号');
      expect(
        win.contains("_episodes.indexWhere((e) => _epOrder(e.title) == order)"),
        isFalse,
        reason: '注入证据：回查退回全集时本条红',
      );
    });
  });
}
