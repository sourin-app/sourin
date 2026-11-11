# Agent Note: Guard external danmaku aggregation publication by play session

Status: implemented


Applies from November 11, 2026 to PlayerPage external comment publication and
aggregation feed-sample writes. This extends the ownership described by
[player progress and danmaku workflow](2026-11-04-player-progress-and-danmaku-modal-workflow.md)
and the separately tested I/O boundary in
[pinned fallback cancellation](2026-11-11-pinned-danmaku-fallback-cancellation.md).
Both related decisions remain in effect; none is superseded.

## Problem

Changing the real mounted PlayerPage session advances its playback generation
before the new source resolve finishes. During that window the danmaku fetch
token can remain unchanged. A previous external load or manual update already
waiting for plugin aggregation can therefore publish its old primary comments
into the new session. Aggregation also writes private per-feed samples before
returning; blocking only caller publication still leaves old settings input.

## Decision

`_loadBiliDanmaku` captures the playback generation before its external update
and checks mounted/generation/fetch-token ownership after that await and after
aggregation. `_biliApplyComments` captures the generation when it claims its
fetch token and checks the same ownership after aggregation, before publishing
comments, settings, cid, sync marker or success notification.

`_aggregateDanmaku` captures its entry generation. Its existing stale-primary
return after a successful plugin await also checks the playback generation.
Before writing `_danmakuFeedSamples`, mounted/generation/fetch-token ownership
is checked again. Both caught plugin exception branches pass through that final
write guard. Obsolete aggregation can return its existing result without
writing samples; its caller publication guards reject the obsolete result.

Current primary/plugin merge, token claim, source attribution, success/failure
feedback, sync marker and enabled-state behavior keep their existing semantics.
No new production API, debug seam, timer or cancellation abstraction is added.

## Alternatives considered

The earlier two-function candidate guards caller comment publication but does
not guard `_aggregateDanmaku`'s private samples write. The aggregation write
boundary therefore needs its own ownership check as well as caller checks.

## Consequences

The frozen regression mounts the real PlayerPage, uses a saved synthetic manual
binding, and enters either its ordinary external load or the real external
panel's manual-update callback. It holds the actual plugin aggregation request,
changes the same player's session through `MediaSession.applySession`, keeps
the real new-source resolver pending, and then releases the old plugin response.
Both successful and failed plugin responses are tested. Actual host comment
count, mounted DanmakuOverlay comments, and real DanmakuSettingsDialog feedSamples
are observed. Each entry/response also has a current-session passing control.

This is the already-entered aggregation boundary. A delayed external fetch
that finishes after session change and only then enters `_biliApplyComments`
still needs caller-owned generation validation; the helper's new capture
describes the current session and cannot identify that old request. This batch
does not cover that schedule or claim complete external caller isolation.

`_biliAutoRefresh` can write its external-sheet state after awaiting
`_biliApplyComments`. Its post-await caller state is not guarded by this change
or exercised by the external-load/manual-update cases. This is a remaining
static caller risk, not a reproduced failure or a newly fixed behavior.

## Verification

The final production-named fixture is
`test/player_external_danmaku_session_aggregate_test.dart`, SHA256
`63ba758a36f1bea97c1eafdd04cde1afe0d74e911212177a248cc6c7738924b9`.
Before the three-function guard,
`.probe/background-takeover-20261111/external-session-final-red-c4.log` reports
four changed-session failures and four current-session control passes. All four
negative schedules observe host count 1, overlayOld=true and samplesOld=true
while the new resolve remains pending. All eight cases complete old-operation,
session-operation and native cleanup. The matching receipt records unchanged
source SHA256
`24450da7ab78b70968f6e0d659cabd71eb08e480274a8fdea85ebe268704d657`.

With only the three-function guard, all eight named external cases pass within
the seventeen-file combination in
`.probe/background-takeover-20261111/external-session-related-green-c1.log`:
91 passed, 0 failed, 0 skipped. Four changed-session schedules now observe host
count 0, overlayOld=false and samplesOld=false while the new resolve remains
pending. Four current-session controls still publish the single primary
comment into both overlay and per-feed samples, including plugin failures.
The matching GREEN receipt records exit 0, unchanged sources during the command,
the same final fixture SHA256 as the RED receipt, and guarded player SHA256
`8b7fc8367d0b471583a16f2cca78b6ee76851324e88008b5efd6c9850625dacb`.
The eight external cases establish their aggregation boundary within that
explicitly scoped 91-case combination; 91 is not a separate external-case count.

The command uses `--run-skipped --no-pub --concurrency=1 --timeout=90s
--reporter=expanded`, below-normal priority and two logical CPUs. Transport,
cache directory and preferences are isolated; no desktop input or client launch
is involved. Media open is disabled. These are deterministic request/host/widget
input observations, not native decode, pixels, physical interaction, external
availability, account playback or formal package acceptance. Early c1 teardown
and c2 error-zone fixture failures are retained separately and are not counted
as the final behavioral RED.
