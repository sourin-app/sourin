// ═══════════════════════════════════════════════════════════════════════
//  现场反馈批次 2026-10-30：1.3 二十秒样片线路
//  duration<60s ⇒ 抽屉行标注「疑似样片 (m:ss)」+ 默认线路选择跳过
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 现象
// ```text
// 聚合源里不少线路是 20 秒样片，起播没多久就停，还默认选中第一条这样的线路。
// ```
//
// # 方案（本批采用"线路时长缓存"，备选"resolve 阶段探测首分片"都写进笔记）
// ```text
// duration 起播后才有 ⇒ 起播后把 (剧, 线路) → 秒 记进缓存（UiPrefs 持久化），
// 下一轮默认选线/标注就能避开样片 —— 零起播延迟；首次仍会中招一次，只中一次。
// ```
//
// # 判据
// ```text
// ① isSuspectedSampleLine：0 < d < 60 才是样片（null/≤0 不冤枉没量过的）；
// ② pickDefaultPlayable：跳过样片选第一条正常的；全是样片 ⇒ 保持原序选第一条；
// ③ 真树：抽屉行真的画出「疑似样片 (0:20)」（读生产 _lineDurationCache）；
// ④ 静态接线：_load 真调 pickDefaultPlayable、duration 广播真调 _recordLineDuration
//    （剥注释断言 —— widget 测试到不了 resolve/FFI，仓库 t61 同款手法）。
// ```
//
// # 故障注入（实测见笔记）
// ```text
// 注入①：pickDefaultPlayable 恒返回 playable.first（不跳样片）⇒ 组①红；
// 注入②：_StreamSheet 行标注退回恒 null ⇒ 组②红；
// 注入③：_load 退回 firstOrNull / duration 监听删掉 _recordLineDuration ⇒ 组③红。
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/player_page.dart';

// ── 剥注释（复用 t61_panel_scroll_test 的同一实现要点：状态机，非正则）────
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  String? quote;
  while (i < src.length) {
    final c = src[i];
    final n = i + 1 < src.length ? src[i + 1] : '';
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
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && n == '*') {
      i += 2;
      while (i < src.length &&
          !(src[i] == '*' && i + 1 < src.length && src[i + 1] == '/')) {
        if (src[i] == '\n') out.write('\n');
        i++;
      }
      i += 2;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

// ═══════════════════════════════════════════════════════════════════════
//  libmpv 夹具（同 t72 —— 缺夹具 skip，不假红）
// ═══════════════════════════════════════════════════════════════════════

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

List<Episode> _eps(int n) => [
      for (var i = 1; i <= n; i++)
        Episode(id: 'ep$i', title: '第$i集', url: 'https://x.invalid/$i.m3u8'),
    ];

Future<void> _mount(WidgetTester t) async {
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  final episodes = _eps(3);
  await t.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        provider: 'cctv',
        id: 'cctv-1',
        title: '样片标注测试',
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
  await t.pump();
}

void main() {
  setUpAll(_prepareLibmpvFixture);

  group('① 样片判据 / 默认选线（纯函数）', () {
    test('isSuspectedSampleLine 边界：59 是、60 不是、0/null 不是', () {
      expect(isSuspectedSampleLine(20), isTrue);
      expect(isSuspectedSampleLine(59), isTrue);
      expect(isSuspectedSampleLine(60), isFalse, reason: 'Owner 判据 <60s（不含）');
      expect(isSuspectedSampleLine(0), isFalse, reason: '量到 0 = 量坏了，不冤枉');
      expect(isSuspectedSampleLine(null), isFalse,
          reason: '没量过的线路不许被当样片跳过');
    });

    test('formatLineDuration：m:ss 补零', () {
      expect(formatLineDuration(20), '0:20');
      expect(formatLineDuration(65), '1:05');
      expect(formatLineDuration(600), '10:00');
    });

    test('lineDurationKey：label 优先、quality 兜底、两者皆空留空尾巴', () {
      const a = StreamCandidate(url: 'u', label: '子站A · 线路1');
      expect(
        lineDurationKey(provider: 'tvbox_agg', contentId: 'x', s: a),
        'tvbox_agg:x:子站A · 线路1',
      );
      const b = StreamCandidate(url: 'u', quality: '高清');
      expect(lineDurationKey(provider: 'p', contentId: 'i', s: b), 'p:i:高清');
      const c = StreamCandidate(url: 'u');
      expect(lineDurationKey(provider: 'p', contentId: 'i', s: c), 'p:i:',
          reason: '空尾巴 = 认不出线路；_recordLineDuration 对它不记不读');
    });

    test('pickDefaultPlayable：跳过样片；全是样片保原序取第一条；空列表 null', () {
      final sample = const StreamCandidate(url: 'u1', label: '样片线');
      final normal = const StreamCandidate(url: 'u2', label: '正常线');
      final playable = [sample, normal];
      int? durationOf(StreamCandidate s) => s.label == '样片线' ? 20 : null;
      expect(identical(pickDefaultPlayable(playable, durationOf), normal),
          isTrue, reason: '默认线路必须跳过 20s 样片（Owner 现象的主断言）');
      // 没读数的线路不许被跳过（不冤枉）
      expect(identical(pickDefaultPlayable([normal], durationOf), normal),
          isTrue);
      // 全是样片 ⇒ 保持原序播第一条（不"全跳成没有"）
      expect(
        identical(pickDefaultPlayable([sample], durationOf), sample),
        isTrue,
      );
      expect(pickDefaultPlayable(const [], durationOf), isNull);
    });
  });

  group('② 真树：抽屉行标注「疑似样片 (m:ss)」', () {
    testWidgets('有缓存读数的样片行带标注，正常行不带', (t) async {
      if (!_requireLibmpv()) return;
      await _mount(t);

      const sampleLine = StreamCandidate(url: 'https://x.invalid/1.m3u8', label: '样片线');
      const normalLine = StreamCandidate(url: 'https://x.invalid/2.m3u8', label: '正常线');
      expect(debugPlayerSetStreamsForProbe([sampleLine, normalLine]), isTrue);
      // ★ 灌**生产缓存**（键由同一个纯函数 lineDurationKey 产出 —— 状态形状与生产一致）
      expect(debugPlayerSetLineDurationsForProbe({
        lineDurationKey(provider: 'cctv', contentId: 'cctv-1', s: sampleLine): 20,
      }), isTrue);
      await t.pump();

      expect(debugPlayerOpenStreamSheetForProbe(), isTrue);
      await t.pump();
      expect(find.text('疑似样片 (0:20)'), findsOneWidget,
          reason: '20s 线路必须被标注（Owner 指定文案 + m:ss 格式）');
      // 正常行只有行名，没有样片标注（整树恰好一处标注）
      expect(find.text('疑似样片'), findsNothing,
          reason: '标注必须带时长读数「(m:ss)」，不许画一个没有读数的裸标签');
    });

    testWidgets('缓存里没有读数 ⇒ 不标注（不冤枉没量过的线路）', (t) async {
      if (!_requireLibmpv()) return;
      await _mount(t);
      const s = StreamCandidate(url: 'https://x.invalid/1.m3u8', label: '未知线');
      expect(debugPlayerSetStreamsForProbe([s]), isTrue);
      expect(debugPlayerSetLineDurationsForProbe(const {}), isTrue);
      await t.pump();
      expect(debugPlayerOpenStreamSheetForProbe(), isTrue);
      await t.pump();
      expect(find.textContaining('疑似样片'), findsNothing,
          reason: '没读数不许标 —— 否则每条新线路一打开全是"疑似样片"');
    });
  });

  group('③ 生产接线（静态断言 —— resolve/FFI 在 widget 测试里不可达）', () {
    late String src;
    setUpAll(() {
      src = stripComments(
          File('lib/ui/player_page.dart').readAsStringSync());
    });

    test('★★ _load 的默认选线真调 pickDefaultPlayable（不再 firstOrNull）', () {
      expect(
        src.contains('final first = pickDefaultPlayable(\n'
            '        playableCandidates,\n'
            '        _cachedLineDuration,\n'
            '      );'),
        isTrue,
        reason: '_load 必须走 pickDefaultPlayable 挑默认线路 —— '
            '判据只此一份；注入退回 firstOrNull 时本条红',
      );
    });

    test('★★ duration 广播真调 _recordLineDuration（缓存有写入点）', () {
      // ★ 2026-10-30（task-9）：实参从广播值 d 改为权威值 authoritative
      //   （DISCONTINUITY 清单下分片伪影 6s 会把 82.72s 完整内容误判成样片
      //   —— 缓存记权威值是修正的一部分，运行时证明见
      //   t20261030_playlist_total_duration_test 的缓存断言）。
      expect(src.contains('_recordLineDuration(authoritative);'), isTrue,
          reason: 'duration 监听里必须真记缓存 —— 没有写入点，'
              '标注与跳过永远等不到读数；注入删掉调用时本条红');
    });

    test('★★ 抽屉真传 sampleBadgeOf（标注不是孤儿函数）', () {
      expect(src.contains('sampleBadgeOf: _sampleBadgeFor'), isTrue,
          reason: '_StreamSheet 构造点必须接生产 _sampleBadgeFor —— '
              '否则标注只在测试里存在，用户看不到');
    });
  });
}
