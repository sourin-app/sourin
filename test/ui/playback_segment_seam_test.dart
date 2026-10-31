// ═══════════════════════════════════════════════════════════════════════
//  T9-P1/P3 门禁：起播分段打点 + getProgress 并行化（源码接缝钉，离线断言）
// ═══════════════════════════════════════════════════════════════════════
//
// 五段 = ①②③ 在 rust/sourin_core/src/playback.rs
//       （由 rust 侧 play_segment_seam_tests 钉）
//      ④⑤ 在 lib/ui/player_page.dart（本文件钉）。
// P3 = detail_page.dart 的进度读取与 getDetail 并行（本文件钉）。
// 证红：注入故障（删/错位任一段）⇒ 对应用例必须红 —— 本批已实测（见汇报）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final playerSrc = File('lib/ui/player_page.dart').readAsStringSync();
  final detailSrc = File('lib/ui/detail_page.dart').readAsStringSync();

  test('T9-P1 分段④：open 之后落 [PLAY] 日志，且每轮起播重置时间锚点', () {
    final openAt = playerSrc.indexOf('Media(playUrl, httpHeaders: st.httpHeaders)');
    expect(openAt, greaterThan(0), reason: 'open 调用点必须存在');
    final seg4 = playerSrc.indexOf('起播分段 ④ open 完成');
    expect(seg4, greaterThan(openAt), reason: '④ 必须落在 open 之后（先 open 后打点）');
    expect(
      playerSrc.contains('_openDoneAtMs = null;'),
      isTrue,
      reason: '每轮起播必须重置 ④ 锚点（否则换集后自open 耗时算到上一轮头上）',
    );
  });

  test('T9-P1 分段⑤：唯一首帧处理点里落日志（含自 open 耗时）', () {
    final handler = playerSrc.indexOf('void _handleFirstFrame');
    expect(handler, greaterThan(0), reason: '首帧唯一处理点必须存在');
    final seg5 = playerSrc.indexOf('起播分段 ⑤ 首帧已出');
    expect(seg5, greaterThan(handler), reason: '⑤ 必须落在 _handleFirstFrame 里');
    expect(playerSrc.contains('自open='), isTrue, reason: '⑤ 必须带自 open 的耗时');
  });

  test('T9-P3：getProgress 与 getDetail 并行起跑、尾部取结果、错误兜住', () {
    final progressStart =
        detailSrc.indexOf('final progressFuture = SourinApi.getProgress');
    final detailAwait = detailSrc.indexOf('await SourinApi.getDetail(');
    final tail = detailSrc.indexOf('final r = await progressFuture;');
    expect(progressStart, greaterThan(0), reason: '进度读取的并行起跑点必须存在');
    expect(
      detailAwait,
      greaterThan(progressStart),
      reason: '★ 进度读取必须先于 getDetail 起跑（这才是并行；放后面仍是串行）',
    );
    expect(tail, greaterThan(progressStart), reason: '尾部取结果（正常路径错误语义不变）');
    expect(
      detailSrc.contains('progressFuture.catchError'),
      isTrue,
      reason: '前序抛错走 catch 时，这条 future 不许变成未处理异常',
    );
  });

  // ── T9 连带修复：登录分流（lead 批复，T1a 查实的缺口） ──────────────

  final ffiSrc = File('lib/core/ffi.dart').readAsStringSync();

  test('登录分流①：SourinCoreException 必须带出 loginKind（ffi.dart）', () {
    expect(ffiSrc.contains('final String? loginKind;'), isTrue,
        reason: '异常对象必须携带 login_kind（可选参，默认 null）');
    expect(ffiSrc.contains("value['login_kind']?.toString()"), isTrue,
        reason: 'completeWith 必须把 ProviderError.login_kind 透传进异常');
  });

  test('登录分流②：_loginAndRetry 先按 loginKind 弹网盘登录，空则原面板兜底', () {
    final retryEntry = playerSrc.indexOf('Future<void> _loginAndRetry()');
    expect(retryEntry, greaterThan(0), reason: '_loginAndRetry 必须存在');
    // 断言范围收进函数体（showProviderLoginDialog 在文件别处还有出现，不能全文件 indexOf）
    final fnEnd = playerSrc.indexOf('/// 退出播放器', retryEntry);
    final fn = playerSrc.substring(retryEntry, fnEnd > 0 ? fnEnd : playerSrc.length);
    final branch = fn.indexOf("showPanQrLoginDialog(context, kind: panKind)");
    // ⚠️ 只匹配**真实调用语句**——函数体顶部的缺口说明注释里也写着这个符号
    final fallback = fn.indexOf('final ok = await showProviderLoginDialog(');
    expect(branch, greaterThan(0), reason: '网盘扫码分流必须存在');
    expect(fallback, greaterThan(0), reason: '原面板兜底必须保留（非网盘错误走它）');
    expect(fallback, greaterThan(branch),
        reason: '★ 分流必须在原面板兜底**之前**（loginKind 非空直接弹盘，不落 providerId 映射）');
    expect(
      playerSrc.contains('_errorLoginKind = e is SourinCoreException ? e.loginKind : null;'),
      isTrue,
      reason: 'catch 里必须存下 loginKind（与 _errorKind 同生命周期）',
    );
    expect(
      playerSrc.contains('_errorLoginKind = null;'),
      isTrue,
      reason: '复位点（_neutralizeErrorState / 预检分支）必须同清登录类别',
    );
  });
}
