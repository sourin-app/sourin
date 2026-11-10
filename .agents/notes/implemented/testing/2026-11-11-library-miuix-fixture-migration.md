# Agent Note: Legacy library tests target current Miuix behavior

Status: implemented

Applies from 2026-11-11 to the active t36 cache-refresh and t40 follow-badge
fixtures. This is a tests-only migration; production and the independently
qualified nine load-ownership cases remain frozen.

The note audit found [Miuix navigation/settings](../../implemented/feature/2026-11-08-miuix-navigation-and-settings.md),
[compact cards and previews](../../implemented/feature/2026-11-08-compact-home-and-motion-preview.md),
[catalog status](../../implemented/bug-fix/2026-11-10-catalog-card-status.md),
[compact empty captions](../../implemented/bug-fix/2026-11-10-compact-rail-empty-caption.md)
and [library request ownership](../../implemented/bug-fix/2026-11-11-library-load-request-ownership.md).
Those behavior/appearance decisions remain. This decision updates obsolete
test targeting, not the current Miuix design or the library load policy.

## Problem

The related v58 run reports 137 passed, four existing skips and five failures.
The two failed suites on isolated 23fe9aa also report the same five failures,
29 passes and four existing skips. The new production delta is not the cause of
those five failures, but leaving them unresolved obscures useful old behaviors.

Two t36 cases still tap retired 最近追更/最近收藏/播放历史 labels while the real
component renders 追更/收藏/历史 with counts. Two mobile target cases identify
InkWell or GestureDetector by a fixed width96, whereas current Miuix segmented
items measure their labels. Their guard correctly reports zero identified items,
not a measured target that is too small. The t40 positive metadata case expects
raw 更新至 12 集 under the poster, while the current contract shows normalized
更新至12集 in a cover badge and suppresses its duplicate following caption.

## Decision

The active t36 cases use the current ShelfTabs scope and actual count labels.
The failed-refresh case keeps its visible-card precondition, checks all three
lanes after repeated failures and rejects false empty-state messages. Its local
core reads now explicitly fail through the existing async transport seam;
missing native DLLs are not the failure fixture.

Both mobile cases measure the three enabled opaque GestureDetector tap regions
inside the actual MiuixGlassSegmentedTabRow. They require exactly three distinct,
hit-testable, correctly labelled regions and keep the height threshold≥34.
They do not measure text or the whole row. The 20px undersized control uses the
same tap-region finder and must still be measured below34.

The first-frame case taps each current tab and holds that actual core refresh
pending. It requires the expected cached card after one pump, before releasing
the request as an explicit failure. It also checks the held request was entered
and remains pending at that frame. It does not wait for animations or request
completion before checking visibility; finally and teardown release all holds.

The t40 metadata case now checks the actual normalized MiuixBadge, its bounds
inside the poster, the visible one-line work title, and absence of the duplicate
raw caption or fabricated 追更中 fallback. Compact and ordinary layouts both run.
Two non-status controls supply 特别篇 with episodeCount0 and require the real
caption below the title, preventing wholesale deletion of useful subtitles.
Existing no-fallback and remaining-count11/hidden-zero assertions stay.

The fixtures use the real Miuix app theme host. They disable DiskCache's data
directory, preserve and restore existing transport/load/preload seams, and
reject local reads explicitly. Covers are absent, ancillary progress is empty,
cover repair returns0 and the independent update scan returns a caught fixture
failure. No native binding, source/account/network call or profile is used.
Unexpected commands fail fixture teardown. The existing shared load fixture is
imported without modifying its frozen bytes.

## Alternatives considered

Deleting the five assertions or adding skips hides the behavioral requirements.
Keeping a fixed96px target bakes an obsolete appearance into a touch-size test.
Checking only row height or label text does not measure actual hit regions.
Waiting for settled UI before the cache assertion misses a first-frame skeleton.
Accepting any episode-related text without checking the cover badge could hide
lost metadata; expecting a badge for every string would discard real captions.

## Verification

The two modernized suites pass with 37 passes and four pre-existing skips.
After removing one unnecessary import, the final serial run includes the nine
unchanged request-ownership cases: 46 passes, four pre-existing skips and zero
failures. The production/test byte snapshot remains unchanged during execution.
Targeted analysis of the two migrated files reports no issues. The earlier
analysis found only that unnecessary import; it was removed before the final
run. Commands use --no-pub, and tests use --concurrency=1.
The four instrument-broken test bodies and their registration remain untouched:
the section containing them has identical before/after SHA256
AEF2C4FEF73307E869E8E55D457868DC0961A5518FFE89B8C416E102CFAD779F,
and the four tag declarations remain exactly four. dart_test.yaml is unchanged.
No new skip is added and no old test is removed. Replacing one t40 metadata case
with ordinary/compact status cases and two caption controls adds three cases.

The existing five-failure baseline and the independent ownership RED/GREEN are
separate evidence. The passing modernized old fixtures validate their preserved UI/cache
contracts; they do not independently prove the newer production generation fix. The unchanged nine ownership tests retain that separate responsibility.

## Consequences

The old suites can again identify current controls and metadata presentation,
while preserving failure retention, first-frame cache visibility, mobile hit
sizes and useful episode information. The registered four old instrumentation
skips remain unvalidated and must not be included as passes. Current native UI
or frame-time acceptance is not established by these fixture changes.
