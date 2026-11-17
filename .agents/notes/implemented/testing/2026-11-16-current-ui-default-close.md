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

The task-only entry and native startup mean ordinary default-user Release startup remains unaccepted. Source-filter persistence, populated library covers, playback combinations and performance remain separate work. Revalidate affected scenarios after product, core, startup or diagnostic interface changes. Raw successes and launcher/build failures are retained in the task probe directory; no machine-specific scripts are shipped.
