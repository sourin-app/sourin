# Agent Note: Latest library load owns visible and persisted state

Status: implemented

Applies from 2026-11-11 to overlapping MyShelf and FollowPage local-library
refreshes. The unchanged nine cases pass after qualified behavior RED. This
status records the implemented request boundary, not native UI acceptance or
independent dynamic coverage of every secondary await.

The note audit found related decisions for [cold snapshot covers](2026-11-11-cold-snapshot-cover-regressions.md),
[cached content and failed sections](2026-11-09-home-cache-and-section-failure-feedback.md),
[conditional metadata backfill](2026-11-10-progress-metadata-conditional-backfill.md)
and [source-switch request generations](2026-11-10-source-switch-search-generation.md).
They remain applicable. Snapshot write ordering does not identify an obsolete
live read, and metadata patch conditions do not protect a whole late list.
No existing note owns overlapping live library reads; none is superseded.

## Problem

The retained library views refresh on tab changes and route returns; FollowPage
also refreshes on app resume. Two reads can overlap. Both old implementations
check only mounted after Future.wait, so an older response completing last
replaces newer cards and viewing progress. MyShelf then submits that stale data
last to its ordered disk writer, making the old snapshot the final file.

FollowPage also abandons all successful list results when any one list fails.
That preserves an outdated populated lane even when its own successful result
is intentionally empty. Failure and successful emptiness need separate meanings.

## Decision

Each load claims a monotonically increasing generation before its first await.
Only a still-mounted owner accepts list/count results, persists shelf data,
reports the outer load error or clears loading. Starting a newer load makes all
earlier response/completion handlers obsolete. Existing refresh triggers and
one-call-per-lane reads remain; this does not disable tab refresh or introduce a
new network operation.

MyShelf passes ownership through its existing asynchronous remaining-count
refresh and checks again after that await. A superseded remaining response does
not change badges or schedule follow-up cover recovery. FollowPage captures the
load's owner before awaiting it, checks before and after its unread refresh, and
the unread query checks ownership after its own await before publishing badges
or calling the host. The same local follow-up guard covers mark-read and the
existing throttled update sweep. The sweep's successful database update still
starts an ordinary fresh local read; its schedule and network contract remain.

Both pages' existing cover-repair completions request a follow-up load only for
the current owner. Existing title metadata patch/merge conditions remain the
backfill policy. The generation is local to each mounted view, not a database
version or a cross-page cancellation token.

FollowPage catches its three list failures individually, as MyShelf already
does. Null means failed and retains that lane; a successful empty list replaces
it. Count failure retains the previous total independently. Loading-success
state is established only after a list actually succeeds, and total list failure
does not schedule new backfill/cover work. The existing render signatures still
avoid unnecessary rebuilds. Snapshot projection, timestamps, serialized writes,
provider/native identity and playback/history storage are unchanged.

## Alternatives considered

Serializing writes alone accepts a stale list that enqueues after the new read.
Mounted alone cannot distinguish requests in one retained State. Disabling tab
selection while loading would change the required immediate navigation/refresh
contract. Coalescing every request into the first in-flight read could miss a
library edit made before the second refresh. Treating failures as empty results
would erase data; rejecting every lane after one failure ignores valid results.

## Verification

Root's isolated 23fe9aa baseline compiled and ran the frozen nine cases in about
four seconds: five qualified behavior failures and four positive controls pass,
with unchanged production source snapshots. The first attempted run stopped on
an unresolved AppThemeHost import in the new support fixture; that compilation
failure is instrumentation, not product RED. Adding the real app_scaffold import
changed no assertion. Qualified evidence is
.probe/parallel-astra-1108/native-verify-v58/v58-load-red-v2.log and its receipt.

The failures observe actual stale temporary DiskCache records, old rendered
cards, history progress reverting from 80% to 10%, revived intentionally empty
lists, and FollowPage failing to apply successful empty lanes beside one failed
lane. Controls preserve newer cards after an older failure, preserve a failed
shelf lane beside successful empty results, and accept an ordinary successful
empty follow refresh. These are behavior assertions, not private generation
inspection or source-text matching.

The same nine frozen cases pass 9/9 in about four seconds on the implementation,
with unchanged source snapshots. Root's twelve related suites report 137 passed,
four pre-existing instrument-broken skips and five failures. The failed two
suites also fail in the isolated 23fe9aa baseline with the same five failures,
29 passing cases and four existing skips. These are not counted as new failures,
but the combined related run is not claimed green: four t36 cases use retired
tab labels or fixed-width legacy hit targets, while one t40 case expects an
unnormalized subtitle beneath the card instead of its current cover badge.
Original assertions remain unchanged pending a separate fixture migration.

Targeted analysis of five production/test/support paths reports zero errors,
one warning and one info. The baseline reports the same two diagnostics: an
unnecessary models import and an unused borderRadius parameter, whose line
moved with this edit. No new diagnostic was introduced. Independent source
review found no P1/P2 issue; it is review evidence, not a native interaction run.
Logs include v58-load-related and v58-legacy-baseline under the same ignored
native-verify-v58 evidence directory, with root's analysis comparison receipts.

Frozen SHA256:
- test/my_shelf_load_generation_test.dart:
  8E7AE08F8217FCDE20B91DD7E053F3FADB538A641C7F94A2406AFA3C9D8E7C2B
- test/follow_load_generation_test.dart:
  D4CE5E1994BD819A7E2BC4E0E2F54EDE82632FCDA209490E6569F092120A499F
- test/support/library_load_fixture.dart:
  87CF55ED647039C7C5AC7E376FB543DAD3A750321EEAAD79C7194DEAA3323172

The fixture controls only the existing core transport, preserves real model
deserialization and rendered tab-refresh paths, and uses actual temporary
DiskCache files. The file observer tracks real publication without changing
bytes or delaying I/O. Held completions allocate in runAsync and release in
finally/teardown; bounded I/O turns alternate real events and widget pumps.
Subsequent tab refreshes fail deliberately, so they cannot repair a stale UI
from fixture values while it is inspected. No native DLL, real profile/account,
HTTP override, VM or OS input is involved.

## Consequences

An obsolete successful read cannot overwrite the last accepted current state,
even when the newer refresh fails. Existing in-flight work is not forcibly
cancelled; it finishes without publication. These local reads remain bounded by
their existing APIs. The qualified nine-case RED directly covers list ownership
and partial failure. Secondary remaining/unread awaits, repair callbacks and
outer completion ownership have source-order review, not distinct held-await
native reproductions in this checkpoint.

The coordinating task owns the remaining old-fixture migration and a current
ordinary-client observation. The nine-case GREEN, related-suite baseline
comparison and analysis above do not establish native interactions. No
frame-rate improvement, source availability or native-client completion is
claimed by this implemented request boundary.
