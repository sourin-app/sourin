@Tags(['native-media'])
library;

// ══════════════════════════════════════════════════════════════════════
//  T7 互检修回 —— 行为门禁（真挂页，驱动生产方法，不加载声明式夹具）
// ══════════════════════════════════════════════════════════════════════
//
// # 覆盖的两条打回
// ```text
// P1-2 「继续观看」误记：rewatch 的形态是 from≈0、to=上次观看位置，
//      pos∈(90,600] 全部会被判成片头终点 ⇒ 下次起播静默跳掉前几分钟。
//      本文件 ① 证明：rewatch 走生产 continueFromRewatchPrompt ⇒ 零落库；
//      ② 阴性对照：同形态的**普通** seek 照记（功能没被改废）。
// P2-2 假 flash：写库返回 false（被 Rust 声明优先拦截）⇒ 不出 flash。
//      ③ 用注入 writer 返回 false 证明"尝试了一次、无第二次写、无异常"；
//        flash 的条件性另有源码结构门禁（skip_memory_test 的 .then((ok) 断言）。
// ```
// # 跑法（与 zz_t1024 同口径）
// ```powershell
// flutter test test/skip_memory_rewatch_gate_test.dart --concurrency=1 --run-skipped --tags native-media
// ```
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

import 't102_playback_failure_banner_test.dart' as fixture;

/// 记忆写路径的注入记录器（真源 = debugSkipMemoryWriter 注入点）
final List<int> memoryWrites = <int>[];
int blockedAttempts = 0;
bool writerAllows = true;

void armMemory() {
  expect(debugPlayerSetSkipMemoryForProbe(true), isTrue,
      reason: '★ 本文件测的就是记忆开着的行为');
  SourinApi.debugSkipMemoryWriter = ({required int introEnd}) async {
    if (writerAllows) {
      memoryWrites.add(introEnd);
    } else {
      blockedAttempts++;
    }
    return writerAllows;
  };
}

void disarmMemory() {
  SourinApi.debugSkipMemoryWriter = null;
  memoryWrites.clear();
  blockedAttempts = 0;
  writerAllows = true;
}

void main() {
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
  });

  setUp(() => RemoteBridge.instance.stop());
  tearDown(() {
    RemoteBridge.instance.stop();
    disarmMemory();
  });

  testWidgets('① ★★★ 互检 P1-2：「继续观看」⇒ 零落库', (t) async {
    await fixture.mountPlayer(t);
    armMemory();
    expect(debugPlayerSetDurationForProbe(const Duration(seconds: 1420)), isTrue);

    // 300s ∈ (90, 600] —— 不抑制必然误记成"片头 5 分钟"的形态
    expect(debugPlayerShowRewatchPromptForProbe(const Duration(seconds: 300)), isTrue,
        reason: '夹具自检：浮层必须摆出来');
    expect(debugPlayerContinueRewatchForProbe(), isTrue,
        reason: '★ 必须真的走生产 continueFromRewatchPrompt（它内部走 _seekByUser）');
    await t.pump();

    expect(memoryWrites, isEmpty,
        reason: '★★★ rewatch 的 seek 落点不是片头信号 ⇒ 必须零落库。'
            '不抑制的话 from≈0、to=300 会被记成片头终点，下次起播静默跳掉前 5 分钟');
    // ★ rewatch/记忆命中都会 _flash（内部 1.2s 收起 Timer）——
    //   不 drain 会以 "Pending timers" 挂在 teardown（与 zz_t1024 同一口径）
    await fixture.drain(t);
  });

  testWidgets('② 阴性对照：同形态的普通用户 seek ⇒ 照记（功能没被改废）', (t) async {
    await fixture.mountPlayer(t);
    armMemory();
    expect(debugPlayerSetDurationForProbe(const Duration(seconds: 1420)), isTrue);
    expect(debugPlayerSetPositionOnlyForProbe(Duration.zero), isTrue);

    expect(debugPlayerUserSeekForProbe(const Duration(seconds: 300)), isTrue);
    await t.pump();

    expect(memoryWrites, [300],
        reason: '★★ 同样的 0→300 seek，普通路径必须照记 —— '
            '否则说明抑制做成了"一刀切禁写"');
    await fixture.drain(t); // _flash 的收起 Timer（同 ①）
  });

  testWidgets('③ 互检 P2-2：写库被拦（返回 false）⇒ 尝试一次、无第二次写', (t) async {
    await fixture.mountPlayer(t);
    writerAllows = false; // 模拟 Rust 声明优先拦截
    armMemory();
    expect(debugPlayerSetDurationForProbe(const Duration(seconds: 1420)), isTrue);
    expect(debugPlayerSetPositionOnlyForProbe(Duration.zero), isTrue);

    expect(debugPlayerUserSeekForProbe(const Duration(seconds: 300)), isTrue);
    await t.pump();
    await t.pump();

    expect(blockedAttempts, 1,
        reason: '★ 尝试了写库（分类器命中）但被库级拦截');
    expect(memoryWrites, isEmpty, reason: '★ 被拦 ⇒ 没有真实写入');
    // flash 的条件性（!ok ⇒ 不出）由 skip_memory_test 的源码结构门禁钉住；
    // 这里证明的是"被拦路径不炸、不重试、不重复写"。
    await fixture.drain(t); // 兜底 flush（同 ①）
  });
}
