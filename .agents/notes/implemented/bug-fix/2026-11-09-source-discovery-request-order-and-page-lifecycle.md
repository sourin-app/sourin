# Agent Note: Source Discovery Request Order And Page Lifecycle

Status: implemented

The final 19 discovery tests and 84 associated regression tests pass. Targeted
analysis of five files reports no issues.

This extends [proxy-required discovery with manual enablement](../feature/2026-11-08-proxy-github-source-discovery.md) with ordered mutations and page lifecycle guarantees. That discovery policy remains active; this note owns response ordering and retained user drafts rather than validation or installation policy.

## Problem

The discovery service published every response to its shared snapshot. A status
read issued before configure, scan, enable, or mark-read could arrive after the
action and restore old automatic, running, installed, or unread state. A read
issued during an action had the same problem after that action finished.
Refresh also reused a pending read from before a completed save.

The page copied its initial response into a separate automatic boolean. A late
initial response erased a user's edit, later confirmed snapshots did not update
an unedited switch, and a rejected save left the unsaved choice displayed.
A late poll error could replace a successful action's UI with an obsolete error.
The poll's error handler also dereferenced the nullable shared snapshot merely
to return a value; a controlled cache reset after disposal exposed a second
exception from that handler.

The page's busy flag only protects one State instance. A user can start saving,
press the actual page back button, reopen discovery, and save again while the
first request remains outstanding. Two writes could then reach the backend at
once and finish in the opposite order. Discarding an old UI response alone
would not protect the persisted preference.

## Decision

Keep the existing command API and transport. In
[SourceDiscoveryService](../../../../lib/core/source_discovery.dart), status reads
capture a revision and publish only when it still matches. Starting and ending
an action invalidates pending reads. A completed old read clears only its own
pending slot, so it cannot erase a newer request's deduplication state.

Serialize the actual configure, scan, enable, and mark-read command sends on one
service Future chain. Invalidation happens when queued and when execution starts
and finishes. A failed action still fails its caller, while the queue continues
to the next action. This preserves user request order across page instances;
it is not just a rule for which response can update the UI.

Retain only the pending tail. Its success/error handler releases the slot only
if it still owns that slot, leaving any newer queued action intact. Idle service
state must not retain a completed Future and its creation Zone. No test-only
reset API or longer test waiting budget was added.

In [SourceDiscoveryPage](../../../../lib/ui/settings/source_discovery_page.dart),
use a nullable automatic draft. With no draft, display the confirmed shared
snapshot. Initial/background reads do not overwrite a draft. Once saving
succeeds or fails, clear the draft and display confirmed state. A failed save
still shows its user-facing error.

Use a void refresh helper with try/catch and an action revision. Old poll errors
cannot overwrite a newer action's result, and reporting failure needs no
non-null cached snapshot. Disposal cancels polling and mounted checks protect
page state updates.

Keep the successful enable callback after page disposal. Returning from the
discovery page does not cancel an already requested installation. Home, settings,
and source-management owners use this notification to refresh source lists;
dropping it based only on the discovery page's mounted state would leave the
homepage stale. The relevant owner load methods guard their own state updates,
and shell invalidation uses currentState?. The regression checks exactly one
notification after the discovery page is removed, with no page UI exception.

## Verification

The root agent ran the toolchain serially. This subagent edited the three scoped
files and inspected evidence, but did not run Flutter, Dart, Cargo, or the app.
All tests use the real production service and widgets with held FFI transport
futures; no new production test hook was added.

- [Initial RED](../../../../.probe/parallel-astra-1108/regression-discovery-race-red-v1.log):
  2 passed / 15 failed. Fourteen failures reached the intended assertions. The
  final disposal test first failed because its fixture returned an unawaited
  Future through a conditional expression; that failure is not product evidence.
- [Qualified disposal RED](../../../../.probe/parallel-astra-1108/regression-discovery-disposed-red-v2.log):
  after fixing only that fixture, 0 passed / 1 failed at the original poll
  handler's current.value! null assertion. Production was still unchanged.
- [First GREEN](../../../../.probe/parallel-astra-1108/regression-discovery-race-green-v1.log):
  all 17 discovery tests passed, including the existing complete discovery flow
  and successful enable notification after disposal.
- [Associated regression before write serialization](../../../../.probe/parallel-astra-1108/regression-source-discovery-dialog-final-v3.log):
  all 82 tests passed. This result predates the final two write-order tests and
  cannot by itself validate the serialized-write change.
- [Write-order RED](../../../../.probe/parallel-astra-1108/regression-discovery-write-order-red-v1.log):
  0 passed / 2 failed. Both observed the second backend command already sent
  before the first settled. One uses actual entry navigation, saving, the page
  back button, and reopening; the other verifies failure must release the next
  queued save.
- [First combined run with serialization](../../../../.probe/parallel-astra-1108/regression-source-discovery-dialog-final-v4.log):
  77 passed / 7 failed. The reopened-page test timed out after releasing its first
  save; subsequent writes stalled behind the retained tail, causing six further
  failures. This was not accepted as a successful regression run.
- [Isolated reopened-page test](../../../../.probe/parallel-astra-1108/regression-discovery-reopen-isolated-v1.log):
  1 passed / 0 failed with exactly the same production source as the failed
  combined run. The difference supports completed-tail lifetime across test
  Zones rather than a single queue-operation deadlock. The pending-only tail
  change follows this result; the original 19 tests remain unchanged.
- [Final discovery GREEN](../../../../.probe/parallel-astra-1108/regression-discovery-write-order-green-v2.log):
  all 19 tests in the full
  [discovery test file](../../../../test/source_discovery_page_test.dart) passed
  after the pending-only tail change. This includes the real reopened-page
  navigation and failure recovery tests, with no reset or waiting-budget change.
- [Final associated regression](../../../../.probe/parallel-astra-1108/regression-source-discovery-dialog-final-v5.log):
  all 84 tests passed on the final source, including the 19 discovery tests.
- [Final targeted analysis](../../../../.probe/parallel-astra-1108/analyze-discovery-lifecycle-final-v2.log):
  five files checked, no issues found, exit 0. The earlier three nested const
  suggestions in the discovery test were resolved by making the root MaterialApp
  const.

## Alternatives considered

- Dropping only stale write responses can keep the displayed state fresh while
  backend writes still finish out of order. Serialize command sends instead.
- Disabling page navigation during saving changes the existing return behavior
  and still cannot protect multiple service callers.
- Resetting service state in tests conceals completed queue ownership. Release
  the actual pending tail when it settles, retaining a newer queued tail.

## Consequences

Returning to the parent page remains available while an operation is pending.
Writes requested after a long scan or enable wait for that operation to settle;
there is no new cancellation or retry behavior. A write failure does not poison
the queue. The queue is scoped to this Dart service, not a cross-process lock.

These results verify async ordering, command payloads, page lifecycle, and
displayed state with controlled transport. They do not prove real GitHub access,
real proxy connectivity, repository discovery, source installation on an Owner
profile, playback, native screenshots, or a final Windows package. Rust, accounts,
and the Owner profile were not changed in this work.
