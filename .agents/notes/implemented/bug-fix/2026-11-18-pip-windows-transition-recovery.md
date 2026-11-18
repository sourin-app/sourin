# Agent Note: Windows PiP transition recovery

Status: implemented

Independent: PiP snapshot recovery and transition ordering have a different
contract from native player disposal and task startup window activation.
Related: [task startup nonactivation](2026-11-16-task-noactivate-window-show.md).

## Problem

Windows PiP can fail after changing window size or enabling topmost while the
controller remains inactive. An active-only exit then prevents recovery.
Interrupted restoration discards the snapshot, and overlapping calls can save
an intermediate window state. Registering entry after awaiting support also
allows an immediate exit to run first and leave PiP active afterward.

## Decision

Register Windows enter, exit and toggle in one queue before any support await.
Capture state, choose toggle direction and restore within that queue. Failed
entry attempts rollback; a pending snapshot permits exit even while inactive.
Retain the snapshot and activity until every restoration operation succeeds,
including taskbar restoration. A later call can retry a transient failure.

Successful PiP retains its existing width, clamped aspect height, topmost and
nonresizable behavior. Entry taskbar hiding remains optional. Restore captured
geometry, topmost, resizing and taskbar flags. The plugin has no minimum-size
getter, so restore the existing shell policy of900 by600. Android dispatch and
callbacks retain their existing behavior.

## Alternatives considered

- Restore only while active: leaves failed entry mutations unrecoverable.
- Clear the snapshot after a restore error: prevents a subsequent retry.
- Choose toggle direction or register entry after a support await: permits
  overlapping calls to use stale state or reverse the requested order.

## Consequences

Platform calls wait for earlier transitions; a call that never completes holds
the queue. Revisit if the plugin gains cancellation or a minimum-size getter.
This repair does not identify an earlier minimized window's actual cause.

## Verification

Two tests against the sealed original source fail on recovery assertions.
Review then identifies a support-await ordering gap in the first candidate:
three immediate-order tests fail, with a double-toggle control passing.
After both corrections, the tracked Windows MethodChannel suite passes53 of53
tests with zero skips. Scoped analysis of the source, test and mock reports
zero issues. Both final hosts naturally exit0 with two empty-Job measurements
above8 seconds; earlier analysis cleanup and checker failures remain retained.

Command: `flutter test --no-pub --concurrency=1 test/pip_windows_transition_test.dart`.
All window methods are mocks. Actual HWND behavior, a fresh production AOT,
latest Release lifecycles and full performance remain separate acceptance work.
