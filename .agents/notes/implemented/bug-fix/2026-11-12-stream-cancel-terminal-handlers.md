# Agent Note: 流式取消保留终态并抑制排队回填

Status: implemented

Related: [source-switch search generations](2026-11-10-source-switch-search-generation.md)
owns the UI callback's stale-request rejection through `callStream`. This note
owns transport cancellation and terminal completion; the earlier decision remains
active and is not superseded.

## Problem

`cancelStream` 原先在发送取消请求后移除流的终态处理器，后续 `done/error` 无法结算原 Future。`onEvent` 返回 `false` 后，已经排队的业务事件仍可回填，也会再次发送取消。未知、重复、已结束 token 还会产生无效取消请求。

## Decision

`lib/core/ffi.dart` 为活动流记录取消状态。首次取消发送一次 native 请求并停止后续业务回填，同时保留终态处理器；`done/error` 或原有 180 秒超时结算 Future，并清理 handler、取消状态与 timer。显式取消与 `onEvent` 返回 `false` 使用同一取消入口。未知、重复、已结束 token 不再发送 native 请求。

取消请求本身不提前结算 Future，也不提前宣告原生生产者已经停止。业务 callback 异常保留原错误，dispatch 异常清理已经建立的流状态。普通 `callAsync` 的 120 秒及 `callStream` 的 180 秒兜底时长保持原契约。

## Verification

2026-11-12 的 C12 实际测试绑定两份完整 owning FFI 源码前缀和相同 9 case 载荷：baseline 的 9 个业务 case 各出现一个真实 matcher assertion failure，Dart 退出 1；candidate 的同名 9 case 全部 success，Dart 退出 0，无 reporter error。两次正常退出后分别连续 8.0317087 秒、8.0312067 秒 Job 0，159 个样本均为 0，无 forced cleanup，清理错误为空。

安装与运行绑定主树 2236 个 tracked 原始文件、资格副本 2238 个源文件、实际 C12 package config 的 117 个依赖根及 5901 个 lib/pubspec 文件，before/after 相等。runner 显式传入私有 `DATA_DIR_OVERRIDE` Dart define。两份测试只增加同一 `flutter_test` import 并附加同一载荷，独立重组验证通过。

证据入口：

- `.probe/qual-stream-cancel-c12/.probe/install-receipt.json`
- `.probe/qual-stream-cancel-c12/.probe/run-baseline-v1/result.json`
- `.probe/qual-stream-cancel-c12/.probe/run-candidate-v1/result.json`
- `.probe/source/next-ffi-streamproxy-media-v2/c12-independent-audit-v1/BASELINE_AUDIT.json`
- `.probe/source/next-ffi-streamproxy-media-v2/c12-independent-audit-v1/CANDIDATE_AUDIT.json`

候选 FFI SHA256 为 `AB7625330ADF74358EAD91F0970EBA89C968812D13E9EF0D384A8544404DF0B1`；共同测试载荷 SHA256 为 `82EF960D46115FFCC1422E7F55B4A53696042E5235A196BB572AC506171C028A`。baseline/candidate result SHA256 分别为 `DEE3210EBE8994F305AB122A8E6D24312C56B7C241A410981104E57858C16B5C`、`540938139DEA75592868B6EA2034E1057501D174D913A537BD2D9597C94B55BD`。

## Alternatives considered

- Immediate Future completion after requesting cancellation avoids waiting, but changes the existing native-terminal completion contract. The implementation keeps the original acknowledgement or timeout boundary.
- Removing the handler immediately drops queued business events, but also drops done/error and leaves the Future waiting for timeout. Keeping terminal handling while suppressing business publication preserves both responsibilities.

## Consequences

取消后的业务结果停止回填，流仍能接收终态并释放 timer；互不相干的流保持独立。生产整合只有 FFI 最小修改和本注记，没有把完整 FFI 实现复制进永久测试，也没有增加生产 stream 测试注入 API。C12 是已绑定源码快照的本批证据，后续源码变化需要重新绑定和验证。

C12 使用 typed Dart transport 替身，证明的是 owning Dart 源逻辑。它不证明实际 native cancel、core/listener shutdown、网盘选集、Owner UI 或正式包验收；测试自有 NativeCallable 的关闭也不代表 core listener 已释放。9 case 不覆盖真实 180 秒等待或取消 transport 的 Dart throw；实际 void FFI 不采用该异常协议。
