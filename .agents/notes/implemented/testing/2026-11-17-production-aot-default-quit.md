# Agent Note: Production AOT default Quit under isolated native diagnostics

Status: implemented

Related: [Current UI default close verification](2026-11-16-current-ui-default-close.md)
and [task-only nonactivating window show](../bug-fix/2026-11-16-task-noactivate-window-show.md).
Their diagnostic-entry and startup scopes remain separate. This note qualifies
the normal production Dart entry with task-private native components.

## Problem

An earlier Debug callback run does not establish that final production Release
AOT reaches the original close dialog. Untagged hide messages cannot identify
the main or shadow window. A minimized window fails the visible-dialog gate,
and restoring it can activate the desktop window.

## Decision

Use the final Release `lib/shell.dart` AOT without a Dart test entry or service
extension. Keep 57 runtime files byte for byte. Rebuild only the qualified
task-isolated runner and window-manager library with owned HWND, PID, class,
placement, system-command and minimize-entry logging. Retain nonactivation and
private profile guards. Never restore a minimized window. Validate invalid
flags, namespaces, profile roots and reparse ancestors before the accepted run.

After Home settles, require a complete visible window for at least five
seconds. Capture Home, request its original close dialog, read the real
accessibility tree, capture the dialog and invoke its original Quit semantic
action. Require saved quit preference, normal exit, exact window removal and
eight seconds of naturally empty owned Job membership. Reuse the qualified
accessibility helper and its inert guard controls.

Independently rehash build inputs, loaded modules, runtime files, screenshots
and raw receipts. Bind accepted Debug observations to their own package,
without transferring UI or active-player acceptance to Release. Reject forged
AOT, core, decoder, package, minimized-window, forced-exit and scope evidence.

## Alternatives considered

- Debug callbacks exercise widgets but do not run production AOT.
- Removing stability or visible-window gates hides observed failures.
- Restoring a minimized window triggers the foreground guard in a retained failure.
- Untagged hide messages cannot identify the hidden owned window.

## Consequences

Production input `6bb7e49` retains AOT SHA256
`B308E2D6494E75AE1ECA81E94E094266FE2459B0D098CF33D3228D9A2D853029`.
The window remains visible for 5.054454 seconds after settling. Two 1280x800
screenshots show the complete shell and original three-choice dialog. Original
Quit exits zero, saves quit and leaves the Job naturally empty for 8.041078
seconds without force, accessibility errors or overflow. All ten hide records
belong to the owned shadow; main-window minimize observations are zero.

The affected-input audit rechecks 3605 live and frozen Release inputs, 35
compiled assets, 269 core inputs and every runtime file. It revalidates four
Debug scenes with 3677 inputs and 416 product-parity rows. Twelve altered
controls fail. Evidence is retained in
`.probe/release-parallel-20261117/CURRENT_FINAL_AOT_DEFAULT_ASK_QUIT_DIAGNOSTIC_AUDITED_V1.json`
and `CURRENT_AFFECTED_INPUT_PACKAGE_REUSE_AUDITED_V1.json` in that directory.

Home settles to a network error, so content is unqualified. There is no active
player. Ordinary foreground startup, Release active-player shutdown and
performance remain separate. Earlier minimized-window and foreground-guard
failures remain failed; their minimization cause is not established by this
later shadow-window attribution.
