# Agent Note: Preserve screenshot saving after PlayerPage disposal

Status: implemented

The [native-media selection decision](../testing/2026-09-25-native-media-tag-skip-not-exclude.md)
and [first-line annotation gate](../testing/2026-10-30-native-media-tag-gate.md)
continue to govern actual native test execution.


Extends [app-owned native screenshot storage](2026-11-12-native-screenshot-owned-storage.md)
with actual PlayerPage save and complete-path feedback evidence for the two
qualified page lifetimes. Its capture arguments, lock, compute/encoding boundary,
pixel-storage decision and native opt-in rules remain applicable. The helper
note's previously open PlayerPage capture/save/feedback boundary is addressed
only for these software-native local-file cases; Owner delivery remains open.
The [Miuix player-control decision](../feature/2026-11-08-player-miuix-controls.md)
and [popover focus lifetime](2026-11-08-player-popover-focus-lifetime.md) retain
their interaction, motion, focus and local-rebuild ownership. This mounted check
adds a page-retirement boundary to control restoration and changes no panel
controller or live-page control policy.

## Problem

A screenshot initiated from the rendered More menu can finish saving after the
user leaves PlayerPage. `_takeScreenshot` awaits the real screenshot, shots
directory and file write, records success, calls the mounted-aware `_flash`,
then unconditionally calls `_showControls`. The latter previously entered
`_applyControlsMotion` even after its State had been removed. Reading
`MotionPrefs.duration(context, ...)` then throws because the State no longer has
a context. `_takeScreenshot` catches this control-restoration error and logs
`截图失败`, despite the requested JPEG already being saved successfully.

The actual baseline reproduces this sequence by holding the original shots
directory's `Directory.create` completion, disposing the real mounted page and
its own NativePlayer, and only then resuming that real filesystem operation.
It saves the JPEG and subsequently logs the unmounted-State context failure.
This is a completed behavioral failure, not a static risk, compiler/setup error,
timeout, missing native fixture or forced process cleanup.

## Decision

Add only `if (!mounted) return;` at `_showControls` entry. An already requested
screenshot still completes its original save and success logging after page
exit; only the retired page's controls, animation and timers are left alone.

The original `_takeScreenshot` body, native capture/worker, save path/naming,
busy guard, DL logging and mounted-aware flash are unchanged. For a live page,
the existing controls visibility, motion, auto-hide and cursor activity policies
continue through the same code. The owning-source review retains all nineteen
actual `_showControls` references, including boot/screenshot completion,
settings close, remote controls, live selection, play/seek/hold, volume/rate,
sheet recovery and hover. This qualification directly verifies the alive and
retired screenshot cases; it does not claim to rerun every unrelated caller.

## Alternatives considered

- Returning before the pending screenshot save prevents a requested image from
  being written when the page exits. Saving is retained.
- Catching only animation/context errors inside `_showControls` hides lifecycle
  misuse and can still allow its later timer/cursor work. The mounted entry
  condition avoids all retired-page control restoration.
- Moving JPEG/RGB work again is unrelated to this failure. The current helper
  already performs capture, pixel conversion and encoding inside `compute`.
  This change is not a new encoding-performance optimization or timing claim.

## Verification

The fresh v2 pair is historically bound to source commit
`5d43449ae08bbb2c3605e3d7a3d0c69fee75e564` and binds the same two test payload bytes to ordinary baseline
and candidate source copies. The baseline really exits 1 with one alive-page
pass and the specified retired-page failure. The candidate really exits 0 with
two passes and no skips. Both cases invoke the actual rendered More screenshot
row, use the same real software NativePlayer/local MP4 capture and forward the
held directory creation to the original filesystem.

The alive case requires the original complete saved path in its actual feedback
widget and visible controls. The retired case asserts page removal and actual
native disposal before releasing the save, retains one real JPEG, and rejects
false failure logging or page restoration. Removal-before-release is supported
by the bound actual assertions and completed specified test, not report booleans
alone. All four baseline/candidate case JPEGs contain 52,246 bytes and have SHA256
`55357251ABFE56E27714C5F3AC86D927BCD0E13B302E9339D872C9639963519F`.
The short review checks saved-file identity/envelope, not repeated pixel
qualification.

Both actual arms retain all 2,248 main-source bindings, qualification source,
metadata, 116 selected dependency-package file maps, SDK tools, MP4 and private
libmpv pins unchanged before/after. Both finish with Job counts zero after exit
and before cleanup, 159 continuously zero samples over 8.032 and 8.025 seconds,
no forced cleanup and no cleanup errors. The cases complete original native
disposal and its six-second real drain. Framework/pending/native error and
denied-core-command arrays are empty. The retired baseline's caught false
screenshot failure is the intended product assertion, not an unhandled error.

Root pipeline: `.probe/player-cover/player-late-controls-v2/PIPELINE_b1.json`,
SHA256 `9B075220D9D2C253E482DF5CE4C0FD8A166D286D03A396760E7AF45C65647713`.
Independent actual short review: `.probe/player-cover/player-late-controls-v2/actual-short-review/ACTUAL_PAIR_b1_SHORT_REVIEW.json`,
43 passed / 0 failed, SHA256
`33ACC5D85D338005CB11EB248FB21175ED549914F82D9217F70EF49784A21ACD`.

The preceding v1/b1 run failed only during preparation because an inherited
paired manifest was incorrectly read as a top-level dependency map. Its failed
pipeline and partial root remain preserved and do not qualify RED. The fresh v2
preparer uses the actual paired baseline dependency path with matched selected
files, entirely fresh roots and unchanged source/test bytes and budgets.

## Scoped analyzer verification

The already qualified baseline and candidate trees subsequently ran four
explicit single-file Dart analyzer commands: `lib/ui/player_page.dart` and
`test/player_late_screenshot_controls_native_test.dart` once for each arm. Each
command used `analyze --format=machine --no-fatal-warnings` and really exited 0.
Execution qualification and the zero-ERROR/no-new-WARNING diagnostic gate are
recorded separately; exit 0 does not mean the existing warnings disappeared.

| Selected file | Baseline ERROR / WARNING / INFO | Candidate ERROR / WARNING / INFO |
| --- | --- | --- |
| `lib/ui/player_page.dart` | 0 / 16 / 8 | 0 / 16 / 8 |
| Fixed screenshot test | 0 / 11 / 2 | 0 / 11 / 2 |

Each arm therefore has 0 ERROR, 27 WARNING and 10 INFO occurrences. Source
warnings include existing protected `setState` access, private testing
annotations, unused elements/parameters and an unused shown name. The fixed
test retains an unused import and unnecessary non-null assertions. Existing
INFO includes braces/const/string-interpolation guidance. No warning or INFO
occurrence was added by this change. The independent review compares the full
diagnostic multiset, preserving repeated diagnostics, column, length and
message, and maps only source locations after the inserted guard line back by
one. All occurrences match. The tested bare `if (!mounted) return;` bytes were
retained; no untested lint rewrite or fixed-test cleanup was substituted.

All original source/dependency/metadata/SDK/input maps remain identical before
and after the pair and both arms. The four analyzer Jobs naturally reach zero
and remain zero for at least eight seconds (159 zero samples each), with no
forced cleanup or cleanup errors. This analyzes only the two selected files;
it does not repeat the native screenshot tests, perform broad directory
analysis, launch the ordinary client or establish additional runtime/Owner
acceptance.

Actual scoped result:
`.probe/player-cover/player-late-controls-scoped-analyze-v1/runs/b1/result.json`,
SHA256 `D354CD69787E94E19B7DFCD80A0B8479A3564F603A475FD76F8A8DD0102D2531`.
Independent raw-log/binding short review:
`.probe/player-cover/player-late-controls-scoped-analyze-v1/actual-scoped-short-review/ACTUAL_SCOPED_b1_SHORT_REVIEW.json`,
50 passed / 0 failed, SHA256
`48F66A56BBA388F9E186F2E7ECD3FBCA0DA1EC5A0498406A739F4BAC11F568B1`.

## Consequences

The user-requested screenshot remains saved when its page exits, and a retired
State cannot turn that success into a misleading failure through control
restoration. Normal mounted-page feedback and controls remain verified.

This is actual software native capture and PlayerPage/storage lifecycle evidence.
The video-output channel and core transport are disclosed test adapters; this
does not establish rendered native child surfaces, physical desktop input,
external/cloud availability, general smoothness, C destruction or Owner/package
acceptance. No Owner profile/cloud/desktop operation or main-tree mutation was
performed by the reviewer. The full eighteen-item acceptance scope remains separate from this scoped
lifecycle correction.
