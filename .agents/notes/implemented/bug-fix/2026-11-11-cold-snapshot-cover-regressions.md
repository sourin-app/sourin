# Agent Note: Cold snapshot cover persistence and restoration

Status: implemented

Applies from 2026-11-11 to Dart snapshot projection, restoration and ordering.
This status records implemented behavior and the 28 passing Dart regressions;
it does not claim fresh native-client restart, image decode or pixel acceptance.

This extends the investigation behind [library cover lifetime](2026-11-08-library-cover-lifecycle.md)
and [global cover routing](2026-11-10-cover-global-proxy-routing.md).
[Homepage cache visibility](2026-11-09-home-cache-and-section-failure-feedback.md)
still governs first-frame content and failure preservation. The note audit found
these partially overlapping decisions; none owns durable covers inside Flutter's
home/shelf JSON snapshots. No prior decision is superseded.

The parallel [native cover-lifetime decision](2026-11-11-cold-snapshot-cover-lifetime.md)
owns the wire contract and real Runtime A/B evidence. This note owns Dart
snapshot persistence, restoration and read/write race regressions; the two
decisions keep their separate evidence and do not replace one another.

## Problem

The baseline HomeListCache and MyShelf serialize their display covers directly.
These may be session-bound loopback wrappers, so a cold preview process can
restore cards whose image requests still target the previous process port.
Existing library database cover repair does not rewrite these separate JSON
snapshots. Simply accepting raw remote addresses on restore could bypass cover
proxy/header policy.

## Decision

The coordinating task qualified the existing-public-API regressions on an
isolated cfe8aea baseline before authorizing production changes. SourinApi now
exposes typed covers_to_durable and covers_to_display batches, each receiving an
ordered items list with provider, native id and nullable cover. The API rejects
response length, identity or cover-type mismatches for the entire batch, and
does not merge returned metadata. Aggregate child::native values remain opaque.

SnapshotCoverCodec copies snapshot JSON, projects covers in both home
groups/section items and the separate fetched-items map, and handles every
favorites/following/history record. Requests are chunked at the native 4096-row
limit. Durable raw addresses retain inline header suffixes; restore registers
current display wrappers. Unknown prior-session tokens become null without
dropping metadata or cards. Failed batches keep safe nonnetwork covers and
metadata; persistence never saves an unresolved temporary wrapper, and restore
never displays an unregistered raw HTTP image. Other batches remain usable.

Shell now awaits home preload after successful startAsync and before runApp.
Successful startup retry also rehydrates the cache after the core is ready.
No isStarted getter is used as a before-start readiness check.

SnapshotCacheWrites captures detached payloads before awaiting any older work,
then serializes conversion and actual DiskCache publication by data directory
and filename, including separate cache/widget instances. Home retains its
original snapshot timestamp; shelf captures the successful load's time rather
than renewing it after a queued wait. Home preload rechecks per-provider puts
and clear generations after native registration. Its revision metadata is
released when the last pending preload completes. Shelf rechecks existing
fresh-lane flags after registration, preserving intentionally empty live lanes.

## Alternatives considered

Discarding cached cards loses the requested cold-start content. Storing direct
display URLs ignores global cover routing and required headers. Borrowing artwork
from another source or matching by title does not preserve media identity.
Serializing covers without ordering guards lets a delayed read overwrite a new
memory put, or an older asynchronous conversion/write replace a newer snapshot.

## Risks

The new tests use the existing async transport seam for native cover projection
and real temporary-directory DiskCache I/O. Their file gate delays actual read
completion or temporary-file publication, rather than replacing DiskCache with
an in-memory implementation. Socket/network overrides are not installed; widget
cover addresses remain under Flutter's ordinary fake test HTTP client.
Every gated action releases its held file operation in finally, with teardown
release as an additional safeguard; assertion failures cannot leave a gate held.

Native conversion and current wrapper identity are fixture results here; they
do not establish a live source image's availability or final native pixels. The
startup check is a source-order guard, not execution of a second application.
Root must distinguish any import/fixture error from a meaningful behavioral RED.

## Verification

Prepared test/cold_snapshot_cover_cache_test.dart and
test/support/snapshot_cover_fixture.dart cover real persistence/restore metadata,
inline headers, unknown tokens, 5001-item chunking, malformed responses,
conversion failure, data-image fallback, late reads and inverted publications.
They also retain all shelf lanes and startup-order requirements. The initial
coordinator run on the old baseline produced 14 qualified behavior failures,
3 passing positive controls and one shelf persistence case with a file-gate
timeout. That instrument timeout was not counted as a qualified behavior RED.
The shelf gate allocated its Completers in the widget's fake-clock zone; moving
that allocation into tester.runAsync retained all ordering, timeout and final
three-lane assertions. The isolated single-case rerun then failed only because
the actual published file retained the old title instead of the new title,
without a timeout or multiple exception. Production snapshots were unchanged.
That qualified 15 behavior failures plus 3 passing controls across the complete
18-case suite. No production Dart edits preceded qualification. Evidence is
v57-snapshot-red.log and v57-shelf-race-red under
.probe/parallel-astra-1108/native-verify-v57.

The frozen 18-case source used for RED and main GREEN is SHA256
6248EF7C1E18AF43E4517BADB5D4B99B9C1E829D6CC14992F15F3A1EB9527615;
its support fixture remains
B4A789AFABD53FDE9C68E88275DEC8C0E0C45B4068E771058CF60298BD38AD9A.
An additional snapshot_cover_conversion_race_test.dart covers clear/new put and
live shelf data arriving during held native display registration, and a malformed
cover-type batch alongside a valid neighboring batch and untrusted metadata.

The older my_shelf_preload_race_test.dart now feeds a durable cached raw origin
to the new display seam and expects its synthetic current-session wrapper for
the failed lane. Its delayed preload ordering and cover assertions remain;
unknown retired wrappers are not fabricated into readable mappings. The frozen
18 regressions independently assert that unknown wrappers become null.

The coordinator's main GREEN completed with 28/28: the unchanged 18 frozen
cold-snapshot cases, 4 additional conversion/race cases and the 6 updated older
preload-race cases. Before/after source snapshots were unchanged. The frozen test
and support hashes above were intact throughout those runs. The separate older race fixture is
SHA256 CE9D1E099412E3BA9415EFAFA0D0B93C0F47E5B593B98065904ADB951D7F6636;
the additional conversion/race suite is
AA7B427CA00E82B7D98A753470CE295FA7BF9AA5EB0394CEEBE3AA183D3C1CC3.

The coordinator's ten related cache/shelf suites also pass 75/75 with unchanged
before/after source snapshots. Its nine-path analysis reported no errors. The
same-baseline comparison found 91 warnings and 7 infos on old production versus
91 warnings and 8 infos on this implementation: the sole introduced diagnostic
was the multiline Home guard without braces. An unnecessary dart:async import in
the 18-case fixture was also present in the baseline analysis with those new
tests. Both infos were repaired after GREEN: the guard gained braces and the
unused import was removed. No branch, expectation, fixture or ordering changed;
the support fixture remains frozen.
The final 18-case test SHA256 is
7EE6570CD056C607DC09BDA1FA34CCF328DB1B5D599E43EE25DBA6E4B2030B31,
separate from its original RED/GREEN hash above. Home's braces-only final hash is
A4A8AF499101F99F48FB384817094C44A1F90C9D935D21E204C6EBAB85FC8A89.
The final analysis rerun remains a coordinator-owned check. Existing API
warnings were compared against the baseline rather than cleaned in this repair.

This lane ran only static diff/whitespace inspection. The coordinator performed
the Flutter tests and owns analysis and real current-session cover evidence.
No fresh native-client restart, real image decode or final pixel completion is
claimed by these Dart tests.

## Consequences

The old behavior and the implemented durable/display ordering boundaries are
qualified by the RED, 28-case GREEN and 75 related passing cases above. Final
post-lint analysis remains a coordinator-owned follow-up check. A freshly
restarted ordinary native client must still use the same isolated profile and
decode current-session covers after normal prior-client exit. The implemented
Dart decision alone does not complete that native acceptance gate.


Final verification after the braces/import-only cleanup: the 18 frozen-behavior
cases and four conversion cases passed again (22/22). Analysis reported zero
errors, 91 warnings and six informational findings. A fresh cfe8aea analysis
baseline had the same 91 warnings and seven informational findings; normalized
path/message/code comparison found no introduced diagnostics and removal of
the unused test import. These existing warnings keep analyzer exit status 1;
this is not a claim of a clean analyzer run.
