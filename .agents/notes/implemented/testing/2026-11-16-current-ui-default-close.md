# Agent Note: Current UI and default close callback verification

Status: implemented

Related: [Bound local decoder PCM verification](2026-11-16-local-decoder-pcm-verification.md).

Continued by: [Source settings cold-restart verification](2026-11-16-source-settings-cold-restart.md).

The [production AOT default Quit verification](2026-11-17-production-aot-default-quit.md)
separately qualifies the normal Dart entry with isolated native diagnostics.

## Problem

A persisted quit preference skips the default close dialog. Earlier isolated lifecycle success therefore does not prove default ask, cancel or the original quit action. An image captured while the Home page is loading also cannot qualify all covers.

## Decision

Use a fresh task profile with no close preference, current product sources and the accepted packaged core. The diagnostic entry suppresses product window activation and exposes token-authenticated service extensions that find mounted rendered widgets and invoke their original callbacks. The task native runner creates a nonactivating owned window. No system input is injected.

Send a close request to that owned window, observe the default dialog, invoke its original Cancel button and verify the preference remains absent. Repeat the owned request, invoke the original Quit button, and verify normal process exit, window removal, persisted quit and continuously empty Job membership for at least eight seconds. Cleanup quit cannot satisfy this callback gate.

Independently parse raw receipts and rehash the runtime inventory, frozen build inputs and screenshots. Reject altered receipts that remove the dialog, introduce a premature preference, shorten empty Job observation or mark forced cleanup. Inspect captured settings, disclosure, source pages, empty states and the final Home return.

## Alternatives considered

- Presetting quit: bypasses the behavior under review.
- Calling cleanup quit: proves cleanup rather than the dialog action.
- Injecting operating-system input: violates the task isolation contract.
- Treating a loading screenshot or empty library as full cover acceptance: exceeds the observed scope.

## Consequences

For product inputs unchanged since af2afab, the actual default ask/cancel/quit sequence passes. Exit is zero, the owned window disappears, quit is saved by the original callback and Job membership stays empty for 8.0286492 seconds without forced cleanup. The runtime log has zero unhandled, Flutter, accessibility-tree and overflow errors. The independent audit verifies 59 files, 3586 build inputs and 11 screenshots, and rejects all four corrupted controls.

The original LAN disclosure expands and restores. Source and danmaku entry callbacks render their production pages. Live, follow and cache render empty fixtures. Initial Home has four decoded cards among twenty intersecting the viewport; after returning Home all twenty decode and the screenshot shows their pixels. This is a bounded current-page observation, not acceptance of every cover, library data or provider.

The task-only entry and native startup mean ordinary default-user Release startup remains unaccepted. 2026-11-20 的只读会话准入回执现已给出具体阻断：没有独立 Active/Connected 交互会话，前台仍属于当前探测 session，Owner 单独授权为 false，故未启动普通默认 Release。该采集只查询本机会话/服务元数据；没有 GUI/VM 启动、桌面切换、输入注入、焦点变更、凭据、数据库或网络访问。首次采集因 WTS FreeMemory 入口调用失败而退出 1，原失败被保留；修正互操作后续次只读回执为 BLOCKED，原因是 `OWNER_DEDICATED_AUTHORIZATION_NOT_PRESENT` 与 `NO_SEPARATE_ACTIVE_OR_CONNECTED_INTERACTIVE_SESSION`，不把失败前置采集升级为成功。原件：`任务证据根/sourin-glpb-startup-20261120-round6/ordinary-session/attempt-v1-failure.json`、`A11_READ_ONLY_SESSION_ADMISSION_V1.json`、`ROOT_COPY_READBACK_V1.json`。复开前需要 Owner 指定已存在、干净、专用交互会话或已运行隔离 VM，明确授权该资源及允许的普通启动/焦点行为，并绑定当前 package/source 与隔离数据根；聊天不提供密码。不得通过抢焦点或合成输入绕过缺口。Source-filter persistence, populated library covers, playback combinations and performance remain separate work. Revalidate affected scenarios after product, core, startup or diagnostic interface changes. Raw successes and launcher/build failures remain retained; no machine-specific scripts are shipped.
