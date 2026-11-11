# Agent Note: Hydrate external danmaku panel from the active playback session

Status: implemented

Extends [external danmaku caller ownership](2026-11-11-external-danmaku-caller-session-ownership.md)
with separate synchronous panel-hydration evidence. That note's four caller
cases and grouped 205 related qualifications retain their historical scope.
The [native-media selection decision](../testing/2026-09-25-native-media-tag-skip-not-exclude.md)
and [first-line native annotation gate](../testing/2026-10-30-native-media-tag-gate.md)
continue to govern opt-in native execution. The qualified baseline already
contains the [screenshot lifetime correction](2026-11-12-player-screenshot-after-dispose.md);
these three cases do not repeat its screenshot qualification.

## Problem

Actual `MediaSession.applySession` keeps the same mounted PlayerPage State and
widget while replacing active provider/content and episode identity. Before
this change `_openBiliSheet` loads binding, manual eligibility and saved P from
the initial `widget.provider`/`widget.id`. The real opened panel combines the
adopted B episode metadata with initial A's binding/P. Opening that panel while
B's resolver is still pending exposes the wrong identity before any new loader
can replace this observation.

## Decision

Change only the three synchronous hydration reads in `_openBiliSheet` to active
`_provider`/`_contentId`: `loadBinding`, `isManualBinding`, and `BiliPrefs.pageKey`.
No await, caller/aggregation guard, mutation callback, metadata continuation,
controller, animation or cache rule changes. The current-state A and return-A
controls retain original binding and saved P; B receives its own manual binding,
selected-episode cid and P. Current B's manual eligibility invokes the existing
metadata method for B. Its fake local metadata response is explicitly disclosed.

## Alternatives considered

Returning to initial widget identity would preserve this observed mismatch;
remounting the entire player would alter the same-State session contract. The
three active-identity reads address the demonstrated opening boundary without
changing either operation.

## Actual verification

The fresh ordinary v5 paired trees are historically bound to source commit
`a8765831277efd712027425e70995aa33f18257b` and 2254 tracked main-source maps.
Both use exactly the same fixed three-case test SHA256 `B369B82C3914DB0A9D04A16E23C32ABAE318784287DED7B8B43CAA69981406ED`.
Baseline really exits 1 with two passing A controls and only B failing at
`Opened B panel must hydrate the adopted session B binding`; candidate really
exits 0 with all three passing and no skips. Actual raw failure/case counts,
observed-panel JSON and native-terminal markers are independently reviewed.

Each case mounts the original PlayerPage and opens its real settings callback.
Its original local Miuix layout/controller/registry entry identity is followed
through the real Host's keyed rendered content root. Actual bounded attachment
traces observe the next normal Host repaint and original card completion before
the original sources ChoiceChip pointer tap verifies selected false to true.
It rereads the current original callback after that normal rebuild and uses an
actual `tester.tap` on the rendered original external-source button inside the
same registered entry root.
A remains fixture/work with binding BV1fixture0001, cid41/P1 and no metadata
request. B is next/next-work, actual selected episode index1/ep-b2/title B Episode
Two/count2, on the same State and widget with its real resolver held. Baseline
opens A binding/manual=false/cid0/P1 under B's episode. Candidate opens B binding
BV1fixture0002/manual=true/cid52/P3 and calls B metadata exactly once. The third
case really adopts B and returns to A before opening, retaining original A.

All six private binding/manual/P preference keys remain unchanged. All cases
complete original native output handle disposal without framework or cleanup
errors; no external HTTP, comment fetch or plugin aggregation occurs. Source/API
and video-output adapters are local fixtures and media open is disabled. The
helper's fake six-second disposal pumps are not six seconds of real C/native
destruction drain. Both process Jobs naturally reach zero and remain zero for
at least eight seconds, without forced cleanup. All recorded main/qualification,
metadata/dependency/SDK/input maps remain unchanged before and after both arms.
The original selected 116-package/4833-file dependency maps are reused without
copying caches.

The earlier v1/b1 did not compile because its fixture omitted the actual
`app_scaffold.dart show AppThemeHost` import. It ran zero business cases and its
candidate did not start; all failure evidence remains preserved and is excluded
from RED counts. v2 added only that 70-byte host import and compiled, but all
three actual cases then stopped at the rendered-opener SETUP finder because its
material_ui TextButton type differed from the owning Miuix adapter. All three
native terminal markers completed; there was no target hydration assertion and
candidate did not start. Its frozen setup evidence also remains excluded from RED.
v3 compiled with the actual adapter but all three cases again stopped at
the rendered-opener SETUP finder. The owning source defaults to display and
constructs the source row only after sources selection; v3 did not record an
attached-tree diagnosis. All three native terminal markers completed; no target
hydration assertion ran and candidate did not start. Its frozen failure is
excluded from business RED.
v4 added an actual sources ChoiceChip tap, but all three cases stopped earlier
at the original fixed-tabs SETUP finder with zero tabs before any setup trace.
Again no target panel observation ran and candidate did not start. Its actual
0-pass/3-SETUP log, three terminal results and natural Job0 are independently
reviewed and excluded from business RED. Owning source then identified the
local Miuix registry registration and post-frame Host repaint boundary; this
source deduction alone was not an observed attachment or behavior pass.
v5 adds only exact fixture setup. It takes the actual original dialog layout
controller, finds its unique identical-controller entry in the same local
registry and binds the original Host's `ObjectKey(entry)` painted root. Bounded
actual attached-tree traces record registration, the next normal Host frame and
card completion, including controller/registry/entry keys and public gates. The
route transitions are the original zero-duration transitions; the actual card
motion uses its MotionPrefs/token duration and must reach Opacity1 before taps.
The original settings wrapper remains visible. The sources tab and opener are
searched only inside that exact original entry root, retaining the original
callback-identity finder, ensureVisible/hitTestable and real pointer taps. All
three before/after sources selections and current original callback rereads are
independently reviewed. The production candidate is byte for byte identical
across all five versions; business assertions, native helpers and budgets are
unchanged. Static source/AST/synthetic parser review alone was never a compiler,
rendered-tap or behavior pass; only the completed actual v5 runs qualify this
three-case boundary.

Actual v5 pipeline: `.probe/player-cover/player-late-controls-scoped-analyze-v1/next-adopted-bili-panel-v5/PIPELINE_b1.json`,
SHA256 `E05F2206ABF0546AD60E0B10BF3C9C4D3E54CC2C5DB88E49215A61BB4EAC669C`.
Independent pair short review: `.probe/player-cover/player-late-controls-scoped-analyze-v1/next-adopted-bili-panel-v5/actual-pair-short-review/ACTUAL_PAIR_b1_SHORT_REVIEW.json`,
101 passed / 0 failed, SHA256 `3A0337A6FA5B20216B4C923D3AFBF1DA076A56B5636A0038D1771C88F1A4EA88`.

## Scoped analyzer verification

Four serial explicit single-file Dart analyzes use the same original paired
trees and fixed test. Actual diagnostic exits and the zero-ERROR/no-new-WARNING
occurrence gate are recorded separately. Existing warnings and INFO are retained.

| Arm / selected file | Actual exit | ERROR / WARNING / INFO |
| --- | ---: | --- |
| baseline / `lib/ui/player_page.dart` | 0 | 0 / 16 / 8 |
| baseline / `test/player_bili_adopted_panel_test.dart` | 0 | 0 / 1 / 5 |
| candidate / `lib/ui/player_page.dart` | 0 | 0 / 16 / 8 |
| candidate / `test/player_bili_adopted_panel_test.dart` | 0 | 0 / 1 / 5 |

The full occurrence-preserving diagnostic comparison records 0 added
and 0 removed diagnostic occurrences, zero new WARNING and 0
new INFO occurrences. Raw positions/messages remain in the actual logs and
review. Exact tested source/test bytes are retained. All analyzer Jobs naturally
reach zero and stay zero for at least eight seconds; no force/cleanup errors,
source/metadata/dependency/SDK/input changes or repeated native tests occur.
The analysis covers these two files only.

Actual analysis result: `.probe/player-cover/player-late-controls-scoped-analyze-v1/next-adopted-bili-panel-v5/scoped-analyze-v1/runs/b1/result.json`,
SHA256 `C7EE269C95680E561345CC8681C90CD3B2056D075B98B868F5D48B4C1AEC9552`.
Independent analyzer short review: `.probe/player-cover/player-late-controls-scoped-analyze-v1/next-adopted-bili-panel-v5/scoped-analyze-v1/actual-scoped-short-review/ACTUAL_SCOPED_b1_SHORT_REVIEW.json`,
58 passed / 0 failed, SHA256 `D7B35A8F2F205F61A1BFBF5B1136382BBF2017B0BB79E5EF42544225DE3A5797`.

## Consequences

Opening the external panel uses the active adopted playback identity for its
binding/manual/P hydration, while current A and return-A behavior remains verified.
This new qualification is three local mounted-session/panel cases. It does not
extend historical caller/aggregation race counts. Import, selecting P, unbind,
repeated opening and asynchronous metadata continuation ownership remain separate
unqualified boundaries. Decoder playback, native presented surfaces, C destruction,
desktop input, external availability, performance, Owner and package acceptance
remain separate from this hydration correction.
