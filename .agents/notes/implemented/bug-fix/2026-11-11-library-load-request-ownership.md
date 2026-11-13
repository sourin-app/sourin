# Agent Note: Latest library load owns visible and persisted state

Status: implemented

Applies from 2026-11-11 to overlapping MyShelf and FollowPage local-library
refreshes, including the visibility admission contract verified on 2026-11-14.
The unchanged nine ownership cases and the retained-page visibility regression
pass after qualified behavior RED. This status records their request boundaries,
not native UI acceptance or independent dynamic coverage of every secondary await.

The note audit found related decisions for [cold snapshot covers](2026-11-11-cold-snapshot-cover-regressions.md),
[cached content and failed sections](2026-11-09-home-cache-and-section-failure-feedback.md),
[conditional metadata backfill](2026-11-10-progress-metadata-conditional-backfill.md)
and [source-switch request generations](2026-11-10-source-switch-search-generation.md).
They remain applicable. Snapshot write ordering does not identify an obsolete
live read, and metadata patch conditions do not protect a whole late list.
The [library cover lifecycle](2026-11-08-library-cover-lifecycle.md) owns shared
recovery, request limits and cover-only persistence. This note owns admission by
the calling page and response ownership; neither decision supersedes the other.

## Problem

The retained library views refresh on tab changes and route returns; FollowPage
also refreshes on app resume. Two reads can overlap. Both old implementations
check only mounted after Future.wait, so an older response completing last
replaces newer cards and viewing progress. MyShelf then submits that stale data
last to its ordered disk writer, making the old snapshot the final file.

FollowPage also abandons all successful list results when any one list fails.
That preserves an outdated populated lane even when its own successful result
is intentionally empty. Failure and successful emptiness need separate meanings.

The root route can become current while its retained library tab remains hidden.
Mounted alone lets that tab refresh when a route opened from another tab returns.
An accepted local read can also finish hidden and start cover repair, title
backfill or an update sweep. A synchronous activity check can reject an incoming
tab before its parent frame publishes the selected TickerMode value.

## Decision

Each load claims a monotonically increasing generation before its first await.
Only a still-mounted owner accepts list/count results, persists shelf data,
reports the outer load error or clears loading. Starting a newer load makes all
earlier response/completion handlers obsolete. Existing local refresh triggers
and one-call-per-lane reads remain. A hidden retained page can accept local data
without starting remote recovery, title backfill or an update sweep.

MyShelf passes ownership through its existing asynchronous remaining-count
refresh and checks again after that await. A superseded remaining response does
not change badges or schedule follow-up cover recovery. FollowPage captures the
load's owner before awaiting it, checks before and after its unread refresh, and
the unread query checks ownership after its own await before publishing badges
or calling the host. The same local follow-up guard covers mark-read and the
existing throttled update sweep. The sweep's successful database update still
starts an ordinary fresh local read. Its existing throttle and request policy
remain; page visibility determines whether a new sweep may start.

Both pages wait for the frame boundary before admitting remote work and read
the effective TickerMode through getValuesNotifier without subscribing the whole
page to inherited rebuilds. This preserves fast tab entry, where local reads can
finish before the parent's next frame enables the selected page. The generation,
mounted state and visibility must still agree after that frame. Route-return
callbacks also recheck that their route is current. A hidden return does not
launch the page's refresh callback; visible returns retain ordinary refresh.

Cover-repair completions request a follow-up load only while the original load
still owns the visible page. FollowPage applies the same frame admission to new
sweeps and checks visibility at title-backfill entry. Already-started remote work
keeps its existing completion and persistence policy. Existing title metadata
patch/merge conditions remain the backfill policy. The generation is local to
each mounted view, not a database version or a cross-page cancellation token.

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
Mounted does not identify the selected retained tab. Checking activity only
before the parent frame loses fast visible entry. Cancelling already admitted
work or changing image/cache timers does not guard a page's new-work dispatch.

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
The [separate fixture migration](../testing/2026-11-11-library-miuix-fixture-migration.md)
preserves their intended UI/cache contracts and the four registered old skips.

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

The retained-page regression uses real mounted MyShelf and FollowPage, parent
TickerModes, route push/pop callbacks, held core transport completions and a
temporary DiskCache. All hidden-work checks precede the first allowed recovery,
so the shared one-minute cooldown cannot mask an unintended hidden request.
The isolated unmodified 26b baseline fails the expected-zero recovery assertion
with one actual call; the identical test passes on the implementation. It also
checks fast visible entry, conditional title metadata, rendered 37% progress,
no reload when a positive repair finishes hidden, visible return refresh and
preserved shelf content/counts. The earlier fake-async file-I/O timeout remains
a setup failure, not product RED.

The current fifteen-file related run reports 75 passes, zero failures and two
existing native-media suite skips. Six separately receipted machine analyses
of the two production files and this test report 0 errors, 1 warning and 1 info
on each arm. Their complete normalized diagnostic multisets are equal; the
FollowPage analyzer's warning exit 2 remains recorded. The two behavior runs,
related regression and six analyses retain all bound inputs and naturally empty
their owned Jobs for at least eight seconds without forced cleanup. Independent
saved-result audits pass 30/30 for the pair and 62/62 for regression/analysis.
Evidence is under `.probe/goal-takeover-20261114/`; these checks do not establish
current native pixels, strict external-network acceptance or frame-time budgets.

## Consequences

An obsolete successful read cannot overwrite the last accepted current state,
even when the newer refresh fails. Existing in-flight work is not forcibly
cancelled; it finishes without publication. These local reads remain bounded by
their existing APIs. The qualified nine-case RED directly covers list ownership
and partial failure. Secondary remaining/unread awaits, repair callbacks and
outer completion ownership have source-order review, not distinct held-await
native reproductions in this checkpoint.

The linked fixture migration and this retained-page regression preserve normal
refresh behavior. Remote work already admitted before hiding is not cancelled.
A current ordinary-client observation and the strict network rerun remain
separate gates. The widget results and analysis above do not establish native
interactions, frame-rate improvement, source availability or native-client
completion.
