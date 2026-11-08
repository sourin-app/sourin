# Agent Note: Login and danmaku fixtures follow actual Miuix controls

Status: implemented

Applies to `t38_selfcheck_open_test.dart`, `t3b_selfhosted_panel_test.dart`
and `zz_t1028_danmaku_regressions_test.dart`, 2026-11-08.

This extends the test-host decisions in
[source discovery/search controls](../feature/2026-11-08-miuix-source-discovery-and-search-controls.md)
and [shared menus/dialogs](../feature/2026-11-08-miuix-shared-menus-and-dialogs.md).
The existing login expansion, probe-race, credential privacy and preference
side-effect contracts remain applicable.

## Problem

The login and danmaku fixtures still assumed Material control types, immediate
popup content and ordinary teardown timing after the Miuix migration. Those
assumptions caused fixture failures before the intended behavior assertions.

## Decision

The login self-check still counted Material `TextButton` widgets after the
panel adopted `ui.TextButton`. It now counts real `MiuixButton` descendants of
the login panel and taps the unique real Miuix toggle. Form fields continue to
prove the expanded/collapsed result. Widget exceptions are explicitly rejected
instead of drained and ignored.

The danmaku success paths schedule the normal 300 ms UiPrefs debounce timer.
`pumpAndSettle` does not promise to advance a timer that schedules no frame,
and ordinary test teardown runs after Flutter's pending-timer invariant.
All cases now run inside a fixture that resets in-memory preferences before
the body and, in `finally`, cancels its pending preference timer, restores the
builtin config and unmounts the panel before the widget callback returns.
Every behavior and privacy assertion executes before cleanup; failures still
propagate. `debugResetForTest` leaves no loaded preference file, so this fixture
does not test disk persistence or touch the user's preference directory.

The removed `显示 / 过滤 / 请求` subtitle is not a current panel contract.
The structure test instead requires the visible title, shared `AppDialogShell`,
actual `MiuixDialogLayout` and only the host's single Scaffold. The separate
three-tab assertion remains unchanged.

The regression fixture locates feed rows by their stable channel keys and taps
the actual Miuix pressable. The tap and `UiPrefs.flush()` run in the same real
async zone because the production toggle starts a flush immediately. Disk
persistence remains a behavior assertion: the saved JSON contains exactly the
remaining three feeds, clearing memory and reloading restores that value, and
remounting leaves only dan-api disabled. Cleanup unmounts, flushes and resets
preferences, then removes only the generated temporary directory.

Binding and selection assertions target the real `MiuixCheckbox` and its
state. The session draft and diagnostics fixtures wait for deferred Miuix
popup content after mounting; keyword, selection, preview and diagnostics
header assertions remain in place.

## Alternatives considered

Counting removed Material widgets or asserting source strings would not prove
the current interaction. Draining widget exceptions, skipping assertions or
loosening persistence checks would hide failures. Ordinary teardown alone
cannot cancel a timer before Flutter checks the widget callback's pending
timers, so cleanup stays inside the fixture's `finally` block.

## Consequences

The fixtures follow the actual component tree while retaining behavior,
privacy and preference assertions. Login and self-hosted panel fixtures keep
preferences in memory; the regression persistence case uses its own temporary
directory. Widget coverage does not establish native playback or Owner
interaction acceptance.

## Verification

This lane does not run Flutter tests, analysis, builds or native executables.
Only isolated Dart formatting and scoped diff checks are performed here. The
coordinating task reported that both `t38_selfcheck_open_test.dart` and
`t3b_selfhosted_panel_test.dart` were individually all green in a broader batch
with 115 passed and four failed; that broader batch is not claimed as green.
After the deferred-popup fixture corrections, the coordinating task reported
`zz_t1028_danmaku_regressions_test.dart` green at 5/5.
