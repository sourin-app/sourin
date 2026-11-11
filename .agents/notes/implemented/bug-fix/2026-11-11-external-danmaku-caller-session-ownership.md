# Agent Note: Preserve external danmaku caller ownership across playback changes

Status: implemented

Applies from November 11, 2026 to the `_biliUpdateNow` and `_biliAutoRefresh`
caller guards. The mounted qualification and integrated input binding are
recorded below. A subsequent caller-containing release package and Owner
acceptance retain their separate gates.

This extends [external aggregation session ownership](2026-11-11-external-danmaku-aggregation-session-ownership.md)
and the [player progress and danmaku workflow](2026-11-04-player-progress-and-danmaku-modal-workflow.md).
Their progress, binding storage, modal layout, pinned fallback, and already
entered aggregation decisions remain in effect. None is superseded.

## Problem

The apply helper's generation capture identifies the playback session when
that helper starts. It cannot identify an old manual external request that
returns only after the real mounted PlayerPage has adopted another session.
The new source resolver can remain pending while the generation has already
advanced and the fetch/panel tokens still retain their previous values. The
old `_biliUpdateNow` continuation writes the returned panel result and then
enters `_biliApplyComments`, allowing old comments to be claimed by the new
generation and merged with the new provider/content's plugin request.

The automatic caller has a separate continuation boundary. `_biliAutoRefresh`
awaits `_biliApplyComments`, whose cancellation is an ordinary `Future<void>`
return. The existing aggregation/helper generation guards can correctly leave
host comments and feedSamples empty after a session change, while the caller
still writes its old external result/count into the mounted Bili panel using
the new episode metadata. Helper return alone is not publication authority.

## Decision

`_biliUpdateNow` captures the playback generation before its external fetch.
After that await, mounted and the captured generation are checked before any
returned panel state is written or the apply helper is invoked. Its existing
panel-token rule remains at its existing location. This prevents the tested
old manual fetch from entering a new-generation aggregate.

`_biliAutoRefresh` captures generation, mutable active provider/content, episode
index/ID, the panel token, and the original danmaku fetch token before fetching.
It loads the manual binding under that active provider/content identity.
Its ownership predicate rechecks playback/episode identity, enabled automatic
update and the current persisted manual binding's bvid/aid/current-episode cid.
After external fetch it also requires the original fetch token and returned
cid to match before calling the apply helper.

For a current successful result, `_biliApplyComments` synchronously claims a
new fetch token before its first aggregate await. The automatic caller stores
that helper Future, immediately captures the actual claimed token, and then
awaits. On return it rechecks the original request ownership and this actual
apply token. The panel result/count/metadata are written only if the sheet is
still open and its captured panel token still matches. The original fetch
token is not compared after the helper's own increment, and panel token is
not compared to that incremented fetch token. Thus the caller's own current
apply claim does not cancel its positive control.

The production guards change only these two caller functions. The shared
`_aggregateDanmaku`, `_loadBiliDanmaku`, `_biliApplyComments` generation guards,
current primary/plugin merge, actual apply token claim, enabled state, sync
marker and success notification keep their existing contracts. No production
test seam, API, timer or new cancellation abstraction is added.

## Alternatives considered

Capturing generation only inside `_biliApplyComments` accepts a late old fetch
as new-session work. The manual caller must preserve its pre-fetch generation.
Treating a cancelled helper's normal completion as successful publication
leaves the automatic panel continuation unguarded. The automatic caller must
retain request ownership after helper return. Comparing only the original
fetch token after apply would reject the helper's own current token claim;
capturing its actual claimed token avoids that self-cancellation.

## Consequences

The four-case qualification uses the actual mounted PlayerPage and existing
local transport seams with media open disabled. Two manual cases invoke real
settings-to-Bili panel opening and the mounted `onUpdateNow` callback. They
hold the actual external cid-41 request before helper entry. The negative
case uses real `MediaSession.applySession` on the same mounted widget, holds
the new resolver, and then releases the old external success. It observes
actual host comments, overlay comments, settings feedSamples, panel result
and count, and the actual plugin provider/mediaId. Its current control
requires actual primary and panel publication for fixture/work.

Two automatic cases invoke actual `MediaSession.updateEpisodes` after the
real mounted panel enables auto update. This keeps the original episode ID
and index while updating its display title/list count. The actual plugin
request is held after external success and helper entry. The negative changes
the same mounted session while the new resolver stays pending, then releases
that entered aggregate. Existing helper guards retain empty render/samples;
the new caller guard additionally retains null panel result/count zero. The
current control retains real primary publication and panel cid 41/count 1,
index zero, refreshed episode title and count two.

This qualification covers exactly the manual late successful external fetch
across real session change, the automatic already-entered aggregate's later
panel continuation across real session change, and their current successful
controls. No automatic late-fetch-before-helper, same-generation token
supersession, rebind, unbind, preference disabling, repeated panel opening,
adopted-session panel/binding consistency, error response, or plugin exception
schedule is newly runtime-covered by these four cases.

The additional automatic pre-apply identity/token/binding/preference checks
are source-reviewed rather than separately exercised by an automatic late
fetch witness. A binding/preference change during an already-entered helper
can suppress the later caller panel write while the unchanged helper can
still publish comments if generation/fetch token were not invalidated. Panel
token is still copied from fetch token at open; it is not a unique per-open
serial. The manual early return leaves the old panel loading flag to its
normal reset/open path. These guards do not cancel external transport or
reverse the existing process-local cid cache update.

## Verification

The final production-named manual fixture is
test/player_external_danmaku_late_fetch_test.dart, SHA256
457ab621ba86c407b13400f6cc351e084a41f4f606e58c4ef30e240d45b9980c.
The final automatic fixture is test/player_bili_auto_refresh_panel_test.dart,
SHA256 f8d569ebcb49886d76838aa52236c649f32e2a11d272572d390c6c3e2e9f085c.
These exact files are recorded in the c2/c3/c4/c5 source maps. They replace the
earlier c1 draft input identities; c1 is not asserted to have used these hashes.
The qualification's previous player baseline is
8b7fc8367d0b471583a16f2cca78b6ee76851324e88008b5efd6c9850625dacb.
The fixed two-caller combination is
ae66ec53c778b80507ddd2d577b6a6f3a9095802192a94370774cdb32485e130.
The integrated production source and four final fixtures match their exact
qualification bytes. Their input hashes are retained in the ignored root
integration receipt alongside the reviewed source baseline.

Final baseline external-callers-final-red-c2 completes the four named cases:
two intended changed-session behavior failures and two passing current controls.
Its receipt records exit 1 and unchanged inputs. Manual late success still
publishes host count 1 and old panel/overlay/samples after real session change;
automatic cancelled application still writes panel cid 41/count 1 while the
helper correctly retains empty host/overlay/samples. Both are observed while
the new resolver is pending. Each manual case reaches old-operation, session
and native terminal markers; each automatic case reaches native terminal.
This is a completed behavioral RED with the final inputs.

The final four caller cases complete successfully on the combined player in
external-callers-related-green-c3 and c4, with two manual and two automatic
native terminal markers in each log. Their intended negative observations
become empty host/old overlay/feedSamples and empty panel result/count; current
controls still publish the primary comment and correct panel metadata.
Neither whole command is a green combination: c3 ends 109 passed and one failed
site-name gate, caused by the isolated qualification hash-index JSON entering
the scanned tree. c4 completes 102 other cases but the eight aggregation cases
and their teardown do not complete. Both exit-1 records are retained. No
110-case green claim follows from combining these partial results.

external-aggregate-isolated-green-c5 separately runs only the existing
test/player_external_danmaku_session_aggregate_test.dart. All eight cases and
their old/session/native cleanup markers complete; its receipt has exit 0,
unchanged inputs and the combined player hash above. Its aggregation fixture
is SHA256 63ba758a36f1bea97c1eafdd04cde1afe0d74e911212177a248cc6c7738924b9.
The caller files appear in the snapshot but are not c5's command inputs. This
eight-case run does not execute the four caller cases or prove a full 110 run.

Production analysis comparison c2 preserves severity, message, file and code,
ignoring only line/column. The candidate and baseline retain zero errors,
sixteen warnings and twelve info diagnostics, with no added/removed normalized
diagnostics. This is not a full-library zero-diagnostic claim.

The additional related pair t70_bili_danmaku_test.dart and t73_bili_wiring_test.dart
records 86 passed/9 failed on candidate c6 and 87 passed/8 failed on the detached
2f044ff baseline c8. Seven inherited failures use old framework widget finders;
the eighth is an inherited one-line token-guard source needle. The candidate's
extra failure is the active-identity capture/manual predicate source needle.
c7 fails during native-assets tool setup before behavior and is excluded from
behavioral counts. These records are retained rather than called green.

The minimal related-fixture migration uses the current production Miuix control
types while retaining real enterText, tap and drag operations, callback counts,
loading disabled predicates and slider bounds. Token predicates remain scoped
to the owning method and both async windows; the automatic manual predicate
requires the same captured active identity before binding lookup. Migrated
detached baseline c9 completes 94 passed/1 failed, specifically lacking captured
active provider identity. The eight inherited fixture failures disappear.
The full 23-suite c10 combination completes 203 other cases, but both no-match
cases and their teardown do not complete. Isolated c16 separately completes
the two unchanged no-match cases with the original budget. Neither c16 nor
the other partial runs turn c10 into a 205-case green combination or explain
the c4/c10 incomplete-run causes. Root's final qualification groups the eight
native files individually and the remaining fifteen files in one serial batch.
The completed final groups are recorded below. Their separate command results
do not turn either earlier incomplete combination into a green command.

The manual cleanup releases gates and awaits both the actual old caller and
actual session Future before the native barrier. updateEpisodes launches the
automatic caller unawaited: its fixture observes plugin transport completion,
drains the existing bound continuation with three pumps, then awaits the real
session operation and native barrier. This specific transport/drain schedule
is not a direct terminal Future for every future automatic continuation.

All runs are isolated synthetic request/host/mounted-widget inputs. They do not
establish decode, native pixels, desktop interactions, external availability,
real accounts or selected cloud-file playback. The independently audited v72
59-file package is tied to commit 2f044ff and the pre-caller player baseline;
it contains neither this caller combination nor these newly added fixtures.
Production and the four final fixtures match their qualified input bytes.
A subsequent caller-containing package, real playback, UI and delivery
acceptance remain open.

## Completed grouped qualification and fault restoration

Final qualification keeps the eight native fixture files in separate serial
commands and the other fifteen related files in one serial batch. Each uses
the original 90-second case budget and concurrency one. The nine command
receipts have exit zero, unchanged inputs and no failed or skipped cases.
They bind the same complete 1,386-entry source snapshot, including the fixed
player and all four final/migrated fixtures above. No command input file is
repeated between these groups.

| Final group | Command input | Passed |
| --- | --- | ---: |
| c16 | player_danmaku_no_match_test.dart | 2 |
| c17 | player_external_danmaku_session_aggregate_test.dart | 8 |
| c18 | player_danmaku_pinned_failure_cancellation_test.dart | 4 |
| c19 | player_candidate_cancellation_test.dart | 8 |
| c20 | t20261104_player_danmaku_ux_binding_session_test.dart | 15 |
| c21 | t20261104_player_danmaku_ux_session_test.dart | 4 |
| c22 | player_external_danmaku_late_fetch_test.dart | 2 |
| c23 | player_bili_auto_refresh_panel_test.dart | 2 |
| c24 | The fifteen other related files, including migrated t70/t73 | 160 |

This is 205 passing cases across 23 distinct files and nine completed groups:
45 in the eight separate native files plus 160 in the fifteen-file batch.
It is grouped qualification, not one 205-case combined green run. The c4/c10
incompletion records and unknown causes remain as recorded above.

Focused c11/c12/c13 separately apply loading-input-enabled,
loading-import-enabled and update-dispatch-import to the actual dialog source.
Each completes with exactly one intended mounted control/callback assertion
failure. c13 also completes one passing current control under its broader
plain-name selection. c14/c15 separately remove the automatic manual gate
and first load token guard, each completing exactly one intended method-scoped
source assertion failure. These last two are static source contracts, not
runtime race witnesses. All five receipts have exit one and unchanged fault
inputs; their exact owning-file payload hashes match the independent patch
reconstruction. Widget fault payloads use LF bytes, while restoration returns
the original raw CRLF dialog bytes; restored hashes are checked as raw bytes.

The fault collector initially expected zero c13 controls and stopped after
observing one control plus one intended failure. Its expectation was corrected
against that actual log and the existing c11-c13 receipts were reused; no
repeat execution is claimed. c14/c15 then completed separately. Final
external-callers-fixture-fault-restoration.json records restored player and
dialog bytes, and unchanged t70/t73 fixture hashes. The subsequent completed
c16-c24 receipts bind those exact restored bytes and provide green restoration
coverage for all selected related cases.

Final four-file analysis c25 separately analyzes the two caller and migrated
t70/t73 files, with exit zero and unchanged inputs. It reports zero errors,
zero warnings and three info diagnostics, all in the caller files; t70/t73
have no diagnostics. The three info messages are existing style findings,
not a zero-diagnostic claim. Production analysis retains its separately
recorded zero-error/unchanged sixteen-warning/twelve-info comparison.

Evidence entries are the final external-callers-split-qualification-summary.json,
external-callers-fixture-fault-restoration.json and actual c11-c25 receipts/logs
under .probe/background-takeover-20261111/. The independent source/receipt
review is .probe/parallel-next-20261111/ui-performance/final-audit/caller-integration/FINAL_GROUPED_FAULT_AUDIT.json.
The independent review and document preparation execute no Flutter/Cargo,
collector, packaging helper or client. Main source integration is complete;
Owner acceptance remains open. These fixture results establish no real decode
or pixels.

## Related fixture contracts

The [actual Miuix controls and framework bridge](../feature/2026-11-08-miuix-controls-and-framework-bridge.md)
owns input, callback and disabled-state preservation. `t70_bili_danmaku_test.dart`
now targets the actual ui.TextField/button/switch/slider/indicator adapters,
retaining real input, taps, drag, original ranges, disabled properties and host
callback counters. Its component-type migration adds no test or callback shortcut.

`t73_bili_wiring_test.dart`② requires the mounted/token/generation early return
after each external-fetch and aggregation await before publication. Its⑦
uses this caller decision's captured `_provider`/`_contentId`, requiring manual
eligibility before the same-identity binding lookup within the actual member.
These static hooks complement the mounted caller cases; they do not add new
runtime coverage for the explicitly untested automatic schedules above.

The migrated exact t70/t73 inputs are SHA256
`F650A1E46C79DA6542C5C6DB409D9BB079B2EBA44B079DA7091D647536859B79` and
`EF51CE3A1B1525BD95535992E2B44205245D353FBCC581ECA7718366CD5AA4DD`.
