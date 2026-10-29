// test/zz_pan_cleanup_on_dispose_test.dart
//
// ══════════════════════════════════════════════════════════════════════════
// 「播完即删」必须真的接上（播放器 dispose → pan_cleanup_temp）
// ══════════════════════════════════════════════════════════════════════════
//
// # 为什么是源码门禁而不是 widget 测试
// ```text
// 这条链路的证据是"播放器销毁时有没有发那条命令"。做 widget 测试要把整个播放器
// （media_kit + 原生 mpv）拉起来 —— 在 flutter test 里既慢又不稳（本仓已有多个
// 探针因此被隔离）。而这里要防的退化是"有人把 dispose 里那行删了/改了命令名"，
// 那正好是源码级的事实，不是渲染结果。
// ⇒ 断言三件事：命令名逐字、在 dispose() 里、且是 fire-and-forget（不 await，
//   避免收尾路径被网络阻塞）。
// ```
//
// ⚠️ 反面对照也在这里：命令名拼错（`pan_cleanup`）必须被这条抓到。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String rel) => File(rel).readAsStringSync();

void main() {
  group('播完即删', () {
    test('播放器 dispose 里发出 pan_cleanup_temp（fire-and-forget）', () {
      final src = _read('lib/ui/player_page.dart');
      expect(
        src.contains('pan_cleanup_temp'),
        isTrue,
        reason: '★★ 命令名必须与 Rust ffi.rs 的分支逐字一致',
      );
      // 取 dispose() 到下一个方法之前的片段，确认调用在里面
      final i = src.indexOf('void dispose() {');
      expect(i, greaterThan(0), reason: '播放器状态类必须有 dispose');
      final tail = src.substring(i, (i + 4000).clamp(0, src.length));
      expect(
        tail.contains('pan_cleanup_temp'),
        isTrue,
        reason: '★★ 调用必须落在 dispose() 里（否则"播完"永远不会触发清理）',
      );
      expect(
        tail.contains('unawaited('),
        isTrue,
        reason: '★ 收尾路径不许 await 网络（会卡 UI 退出）',
      );
    });

    test('Rust 侧命令与实现都在位', () {
      final ffi = _read('rust/sourin_core/src/ffi.rs');
      expect(ffi.contains('"pan_cleanup_temp"'), isTrue);
      expect(ffi.contains('purge_all_previous'), isTrue,
          reason: '★ 空分支 = 没做');
      final drive = _read('rust/sourin_core/src/csp/pan_drive.rs');
      expect(drive.contains('pub async fn purge_all_previous'), isTrue);
      expect(drive.contains('file_delete_url'), isTrue);
      // 删除必须是"移入回收站"（action_type:2），不是真删
      expect(drive.contains(r'{"action_type":2'), isTrue,
          reason: '★★ 原版用 2（回收站）；改成 1 会让用户找不回文件');
    });
  });
}
