// ═══════════════════════════════════════════════════════════════════════
//  T27-06「切换到直播播放页总是要反应很长时间才出现画面」—— 门禁
// ═══════════════════════════════════════════════════════════════════════
//
// # 业主原话
// > 切换到直播播放页总是要反应很长时间才出现画面
//
// # 修复（task-6，w6-live）
// ```text
// ① SourinApi.getLiveStream 30s TTL 缓存：同一 (provider, channelId) 30 秒内
//   第二次取地址直接查表，不再打穿核心层（切回刚看过的台 = 0 次取数）。
// ② 切台链路计时埋点：AppLog '切台' ①取地址 ②地址到手 ③open 返回 ④首帧，
//   _bootMark 同步打点（PLAYBACK_TIMING 时）—— 真机取证的数据通道。
// ③ 面板打开时预取相邻台的地址（与 ① 共用同一份缓存，点选邻居 = 0 次取数）。
// ```
//
// # 本文件测什么（默认套件必跑；不 mount 播放页、不加载 libmpv）
// ```text
// ①组 静态源码断言（stripComments 后扫函数体 —— 与被测对象同源，见铁律）：
//     getLiveStream 必须走缓存；注入/清空钩子存在；
//     _adoptLiveChannel 埋 ①/②、_startPlayback 埋 ③、_reportFirstFrame 埋 ④；
//     _toggleLiveChannels 必须触发预取。
// ②组 缓存层行为断言（直接打 SourinApi + fake 取数器，不碰 FFI）：
//     同台第二次不再取数 / 异台正常取 / 清缓存后重取 / 空结果不缓存。
// ```
// ⚠️ 验收③「widget 驱动 _adoptLiveChannel 两次」在
//    test/t27_w6_live_switch_adopt_test.dart（native-media 标签 + libmpv 夹具门，
//    缺夹具环境优雅 skip —— dart_test.yaml 约定）。
//
// ⚠️ 只打印事实 + 断言；不打印结论（与 t72 同一纪律）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/sourin_api.dart';

import '_support/strip_comments.dart';

const _apiPath = 'lib/core/sourin_api.dart';
const _playerPath = 'lib/ui/player_page.dart';

/// 括号配对取「签名开头 → 函数体结束」的源码片段。
///
/// 参数列表的 `)` 会先把深度打回 0，所以必须等到 `{``}` 主体闭合才算结束
/// （zz_t53 的 _matchParen 只取调用参数块，这里是函数声明的变体）。
///
/// ⚠️ T27-06 修复：**函数体**的 `{` 必须是「参数表收口（paren==0）之后」
/// 遇到的第一个花括号。record 类型参数（`({String provider, LiveChannel x})`）
/// 在参数表内就带 `{}` —— 旧实现把它当成函数体开始，`)` 收口时
/// `paren==0 && brace==0` 提前返回参数表，扫不到函数体（仪器假读数）。
String _fnBody(String src, String signaturePrefix) {
  final sig = src.indexOf(signaturePrefix);
  expect(sig, greaterThanOrEqualTo(0), reason: '找不到签名：$signaturePrefix');
  final open = src.indexOf('(', sig);
  expect(open, greaterThan(sig), reason: '签名后没有左括号：$signaturePrefix');
  var paren = 0, brace = 0, bracket = 0;
  var inBody = false; // 参数表收口后遇到的第一个 { 才是函数体开始
  var inStr = false;
  var inDq = false;
  for (var i = open; i < src.length; i++) {
    final c = src[i];
    if (inStr) {
      if (c == r'\') {
        i++;
      } else if (inDq ? c == '"' : c == "'") {
        inStr = false;
      }
      continue;
    }
    if (c == "'" || c == '"') {
      inStr = true;
      inDq = c == '"';
      continue;
    }
    if (c == '(') {
      paren++;
      continue;
    }
    if (c == ')') {
      paren--;
      continue;
    }
    if (c == '[') {
      bracket++;
      continue;
    }
    if (c == ']') {
      bracket--;
      continue;
    }
    if (!inBody) {
      // 参数表内的花括号（record 类型注解 / 默认值 lambda）一律不算函数体
      if (c == '{' && paren == 0 && bracket == 0) {
        inBody = true;
        brace = 1;
      }
      continue;
    }
    if (c == '{') {
      brace++;
      continue;
    }
    if (c == '}') {
      brace--;
      continue;
    }
    if (paren == 0 && brace == 0 && bracket == 0) {
      return src.substring(open, i + 1);
    }
  }
  fail('括号不配对：$signaturePrefix');
}

void main() {
  setUpAll(() {
    // 静态断言的输入：两份**剥掉注释**的源码（铁律：判据必须与被测对象同源，
    // 且必须复用 _support/strip_comments.dart，不许再抄一份剥注释器）。
  });

  group('①组 静态源码断言（stripComments 后）', () {
    late final String apiSrc;
    late final String playerSrc;
    setUpAll(() {
      apiSrc = stripComments(File(_apiPath).readAsStringSync());
      playerSrc = stripComments(File(_playerPath).readAsStringSync());
    });

    test('①a getLiveStream 必须走 30s 缓存（每次切台都打穿核心层=切台慢的根）', () {
      final body = _fnBody(
        apiSrc,
        'static Future<List<StreamCandidate>> getLiveStream(',
      );
      expect(
        body.contains('_liveStreamCache'),
        isTrue,
        reason: 'getLiveStream 函数体必须查询 _liveStreamCache（切回看过的台不再取数）',
      );
      expect(
        apiSrc.contains('Duration(seconds: 30)'),
        isTrue,
        reason: 'TTL 必须是 30 秒（任务验收指定的缓存窗口）',
      );
    });

    test('①b 缓存注入/清空钩子必须存在（探针与门禁的注入点，同 debugListFetcher 惯例）', () {
      expect(
        apiSrc.contains('debugLiveStreamFetcher'),
        isTrue,
        reason: '必须有 @visibleForTesting debugLiveStreamFetcher（行为断言的注入点）',
      );
      expect(
        apiSrc.contains('debugClearLiveStreamCache'),
        isTrue,
        reason: '必须有 debugClearLiveStreamCache（换源/重试后清缓存）',
      );
    });

    test('①c _adoptLiveChannel 必须埋切台计时 ①/②（AppLog 切台链路取证）', () {
      final body = _fnBody(playerSrc, 'Future<void> _adoptLiveChannel(');
      expect(
        body.contains("_liveSwitchMark('①"),
        isTrue,
        reason: '切台发起必须打 ①（切台链路的 t0）',
      );
      expect(
        body.contains("_liveSwitchMark('②"),
        isTrue,
        reason: 'getLiveStream 返回必须打 ②（resolve 耗时的直接读数）',
      );
      expect(
        body.contains('_liveSwitchStartedAt = DateTime.now()'),
        isTrue,
        reason: '切台必须重置计时起点 _liveSwitchStartedAt',
      );
    });

    test('①d 计时链 ③/④：_startPlayback 埋 open 返回、_reportFirstFrame 埋首帧', () {
      final start = _fnBody(playerSrc, 'Future<void> _startPlayback(');
      expect(
        start.contains("_liveSwitchMark('③"),
        isTrue,
        reason: '_player.open() 返回必须打 ③（直播路径）',
      );
      final frame = _fnBody(playerSrc, 'Future<void> _reportFirstFrame(');
      expect(
        frame.contains("_liveSwitchMark('④"),
        isTrue,
        reason: '首帧出现（stream.width 非空）必须打 ④（用户「看到画面」的时刻）',
      );
      expect(
        playerSrc.contains('void _liveSwitchMark('),
        isTrue,
        reason: '计时打点必须收口在 _liveSwitchMark（一条纪律一个实现）',
      );
      final load = _fnBody(playerSrc, 'Future<void> _load() async {');
      expect(
        load.contains("_liveSwitchMark('①"),
        isTrue,
        reason: '进直播播放页的首播路径也要打 ①（业主原话是「切到直播播放页」）',
      );
    });

    test('①e 面板打开必须触发相邻台预取（fire-and-forget，不阻塞 UI）', () {
      final toggle = _fnBody(playerSrc, 'void _toggleLiveChannels()');
      expect(
        toggle.contains('unawaited(_prefetchNextLiveChannel'),
        isTrue,
        reason: '_toggleLiveChannels 打开面板时必须预取相邻台（unawaited，不阻塞）',
      );
      expect(
        playerSrc.contains('Future<void> _prefetchNextLiveChannel('),
        isTrue,
        reason: '预取函数必须存在',
      );
    });

    test('①f 扫描器自检：注释里的假标记不许骗过门禁（阴性/阳性对照）', () {
      // 阴性：标记只出现在注释里 → 剥掉后必须扫不到
      final neg = stripComments('''
        void _toggleLiveChannels() {
          // unawaited(_prefetchNextLiveChannel());
          /* Future<void> _prefetchNextLiveChannel() {} */
          setState(() => _liveChannelsOpen = true);
        }
      ''');
      expect(neg.contains('_prefetchNextLiveChannel'), isFalse,
          reason: 'stripComments 后注释内的标记必须消失（否则门禁可被注释欺骗）');
      // 阳性：标记在真实代码里（含字符串实参）→ 必须扫到
      final pos = stripComments('''
        void _adoptLiveChannel() {
          _liveSwitchMark('① 切台取地址');
        }
      ''');
      expect(pos.contains("_liveSwitchMark('①"), isTrue, reason: '真实代码里的标记必须扫到');
      // 阳性②（仪器回归）：record 类型参数不许让扫描器把参数表当函数体
      // （_adoptLiveChannel 真身就是 ({String provider, LiveChannel channel}) pick）
      final recBody = _fnBody('''
        Future<void> _adoptLiveChannel(
          ({String provider, LiveChannel channel}) pick,
        ) async {
          _liveSwitchMark('① 切台发起');
        }
      ''', 'Future<void> _adoptLiveChannel(');
      expect(recBody.contains("_liveSwitchMark('①"), isTrue,
          reason: 'record 参数截断扫描 = 门禁假读数（本次 ①c 红的根因）');
    });
  });

  group('②组 缓存层行为断言（真 SourinApi + fake 取数器，不碰 FFI）', () {
    tearDown(() {
      SourinApi.debugLiveStreamFetcher = null;
      SourinApi.debugClearLiveStreamCache();
    });

    test('②a 同台 30s 内第二次调用不再取数（缓存命中，返回同一份结果）', () async {
      SourinApi.debugClearLiveStreamCache();
      var calls = 0;
      final cand = StreamCandidate(url: 'https://x.invalid/a.m3u8', kind: 'hls');
      SourinApi.debugLiveStreamFetcher = (provider, channelId) async {
        calls++;
        return <StreamCandidate>[cand];
      };
      final a = await SourinApi.getLiveStream('cctv', 'c1');
      final b = await SourinApi.getLiveStream('cctv', 'c1');
      expect(calls, 1, reason: '同一 (provider, channelId) 第二次调用必须命中缓存');
      expect(identical(a, b), isTrue, reason: '缓存命中应返回同一份候选列表');
      expect(b.single.url, 'https://x.invalid/a.m3u8');
    });

    test('②b 不同台必须真取（缓存按 (provider, channelId) 分键）', () async {
      SourinApi.debugClearLiveStreamCache();
      var calls = 0;
      SourinApi.debugLiveStreamFetcher = (provider, channelId) async {
        calls++;
        return <StreamCandidate>[
          StreamCandidate(url: 'https://x.invalid/$channelId.m3u8', kind: 'hls'),
        ];
      };
      await SourinApi.getLiveStream('cctv', 'c1');
      await SourinApi.getLiveStream('cctv', 'c2');
      await SourinApi.getLiveStream('cctv8', 'c1');
      expect(calls, 3, reason: 'provider 或 channelId 任一不同都必须真取');
    });

    test('②c 清缓存后必须重取（换源/手动重试的出口）', () async {
      SourinApi.debugClearLiveStreamCache();
      var calls = 0;
      SourinApi.debugLiveStreamFetcher = (provider, channelId) async {
        calls++;
        return <StreamCandidate>[
          StreamCandidate(url: 'https://x.invalid/a.m3u8', kind: 'hls'),
        ];
      };
      await SourinApi.getLiveStream('cctv', 'c1');
      expect(calls, 1);
      SourinApi.debugClearLiveStreamCache();
      await SourinApi.getLiveStream('cctv', 'c1');
      expect(calls, 2, reason: 'debugClearLiveStreamCache 之后不允许再命中');
    });

    test('②d 空结果不缓存（「暂时不可用」不该被放大成 30 秒不可用）', () async {
      SourinApi.debugClearLiveStreamCache();
      var calls = 0;
      SourinApi.debugLiveStreamFetcher = (provider, channelId) async {
        calls++;
        return const <StreamCandidate>[];
      };
      await SourinApi.getLiveStream('cctv', 'c1');
      await SourinApi.getLiveStream('cctv', 'c1');
      expect(calls, 2, reason: '空列表必须每次真取（探测失败不该被缓存）');
      expect(SourinApi.debugLiveStreamCacheSize, 0, reason: '空结果不允许进缓存');
    });
  });
}
