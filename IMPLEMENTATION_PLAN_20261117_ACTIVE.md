# Source and player continuation — 2026-11-17

Status: active / incomplete. This file is the current continuation pointer for
the scope in IMPLEMENTATION_PLAN_20261108.md. Product input is commit fadacc5;
later test/document-only commits do not change that built product. The previous
chat stopped on service rate limits, with an unexecuted detail-source patch.

## Completed product work

| Commit | Change | Evidence |
| --- | --- | --- |
| 3d0434f | Follow the player's declared source and current episode; reject stale source results; keep the correct line's catalogue on refresh failure | Prior implementation: 5 failures / 3 controls pass. Current-request-error case fails before fallback. Final source suite passes. |
| 5466e07 | Bound episode-loading placeholders to the actual remaining pane height | Public transient overflow: 40px. Synthetic pending-request baseline: 50px at 860x904, wide control passes. Fixed layout/source suite: 63 pass. |
| fadacc5 | Keep full episode buttons reachable after the live resume chip appears | Public viewport shrank to 16.2px after five seconds. Fixed current window has 80.2px and fully reachable 38px active button. Final focused suite: 65 pass. |

The final nine source-sync tests include success/failure reordering, initial
source preference, nested and absent sources, unknown identity, work remount,
and current-request failure. Removing only the completion guard makes both
stale-success and stale-failure cases fail (7 pass / 2 fail). The restored
product passes the full 65-case selected suite. No assertions were weakened.

The broader earlier ten-file run had 149 pass / 3 failures. All three failures
also occur on clean d291834 in detail_follow_test.dart: obsolete source-text
checks for a trailing argument comma, flat source count and old tab labels.
They remain failures; the selected final suite is not a full repository pass.
Final targeted analysis has zero errors/warnings and one inherited brace-style
info. The 408-note gate and diff whitespace check pass.

## Current real UI evidence

The task-only Debug observation package uses the original product callbacks and
an explicitly separate nonactivating launcher. The v11-final scene exercises
Home → error overlay → selected line/episode → actual native playback → settings
and episode panels → return → default ask dialog → original Quit.

- Current player State, native Player, selected source and episode remain the
  same between 8.299s and 11.019s. Both native frames are 1920x800. The central
  700x250 video rectangle changes 174,989 of 175,000 pixels; actual animation is
  visible. This proves visible playback, not the full movie's identity.
- The live resume chip is present. Header is 354px, episode viewport 80.2px,
  and both episode buttons are fully inside the viewport and hit-testable.
- Target detail cover and returned Home cover decode and render. Initial Home
  capture was taken before decoding and remains explicitly unaccepted as a
  cold-cover result. Other failed covers remain; this is one target's recovery.
- All nine PNGs and runtime/core/engine bindings are independently checked.
  The same owned HWND remains nonactivating under the actual foreground guard.
  No observed Flutter/AXTree/overflow errors. Original Quit exits zero; natural
  empty Job is observed for 8.048775s; no forced cleanup. Task relay closes.

The task relay caused part of the retained cover failure: Python's sequential
address attempts waited about 10s on IPv6 before a successful 13ms IPv4 connect.
The qualified task successor staggers frozen address candidates, shares a
bounded deadline and cancels in-flight sockets during close. It passes 22
HTTP/CONNECT/DNS-failure/timeout/cancellation controls. In the real v10 scene,
target connect is 285ms and the cover renders. This changes test infrastructure,
not product proxy behavior or the product's three-second header deadline.

## Builds and retained failures

Current Release core's original C ABI also passes two independent isolated JS
lifecycle runs. Two real held HTTP hydration responses are released in reverse
order: the later reload publishes its capability, and the older reload returns
an obsolete-operation error without overwriting that capability. Three invalid
saves (syntax, changed identity, missing name) leave actual file hashes and
registry unchanged. Removing the plugin while another reload is held prevents
resurrection after release and after a subsequent reload. All HTTP handlers and
call threads join; final native exit is zero and natural empty Job is 8.0388036s.
The production ABI uses a unique task credential namespace, not a test-only
EntryOnly backend. No real account login is attempted. The reload audit rejects
four altered-result controls and leaves whole-JS acceptance false.

The continuation also validates four production-ABI save/delete races: valid or
validation-failing source, each with a control and deletion during held
validation. A synthetic plugin uses the real private-store API to signal entry;
the fixture observes that signal before deleting, then releases validation.
Both deleted cases return obsolete-operation errors and remain absent after
another reload. Valid control saves version 2; invalid control preserves version
1 and its exact bytes. Unrelated private data is unchanged in all four cases.
All save threads join, exit is zero, and natural Job0 lasts 8.0009479s. Ten
altered-result controls are rejected. The first gate-release file-sharing error
is preserved as a failed fixture run; it is not a product defect or acceptance.

Current library validation now covers six original favorite/follow callbacks
and three populated library tabs. A second independent owner starts from an
exact task-profile copy, with only the task proxy listener address rebound;
there is no preparatory core/content reseed. Identity, flags, selected episode,
eight-second position and 6238-second duration remain stable. All three tabs
decode the target cover in both owners. Natural Job0 is 8.037807s / 8.0053375s,
without force. The audit checks 59 runtime files, 3598 frontend inputs, 415
product parity entries, 20 copied files and 18 PNGs, with eight rejected altered
controls. This is one target and a cold process, not multi-item sort validation
or an empty disk-cache test. Routine check timestamps and local cover URLs may
change; no claim of zero data writes is made.

A fresh second-line UI run also succeeds through original callbacks and native
decoding. The new line renders 1920x1080 but lasts only 30.058 seconds. Same
State/Player, changed session generation, selected episode, detail highlight,
actual playlist/segment forwarding and normal exit are verified. Two unrelated
denied endpoint requests are retained. This closes the observed short-clip
switching path, not two complete target-film lines.

Current Debug v3 and Release v2 each contain 59 files. Independent audits rehash
3,597 / 3,604 frontend inputs respectively, plus 269 unchanged core inputs.
The production core is deliberately reused from d291834 because Rust input is
unchanged. Release uses the normal lib/shell.dart AOT bundle and 22 retained
native files; byte/build acceptance is not ordinary-startup acceptance.

The attempted 5466e07 Release startup with the older native-only noactivation
runner became foreground, so the guard aborted and closed its owned Job.
Natural exit is not established. The old wrapper omitted its start tuple and
forced-cleanup flag in the partial receipt; a separate failure record states
that omission rather than inventing lifecycle evidence. Do not rerun that
startup path until the complete show/focus contract is resolved. The passing
Debug nonactivation scene does not replace ordinary Release validation.

Other retained failures include the initial missing test import, v9 transient
loading overflow and relay-close failure, two DNS preparation failures, and the
v11-visible resume clipping timeout. Successful successors preserve them.

## Performance evidence and next actions

The existing d291834 Profile package was diagnosed against its immutable
consumed source; the one changed live detail file is documented separately.
It captured a 37,067,332-byte settled Home SKP and completed all 20 windows /
1,138 frame records with natural exit. Startup raster maximum remains 356,013us;
the 16,667us budget is unchanged and performance is unaccepted.

Bounded opcode inspection finds 879 commands and 18 saveLayer operations. This
is a settled historical picture: paint/resource payloads are not decoded,
individual operations are not timed, and it is not the specific cold frame.
Do not infer a proven shader culprit or merge a visual change from that count.

A separate equal-configuration glass repaint guard was tested in isolated
copies. Component paint counts improve and twenty pixel pairs are identical,
but the actual Profile pair does not show navigation benefit: after-startup
raster max 23.644/49.080ms, p95 3.244/3.620ms and over-budget frames 1/6 for
baseline/candidate. Both retain all frames and the original twenty windows.
The candidate is rejected for product adoption; its lower cold maximum is not
attributed to the guard. See the [decision](.agents/notes/rejected/bug-fix/2026-11-17-equal-glass-update-repaint-guard.md).

Continue with distinct open work:

1. Resolve Release startup scope before another launch. Default product startup
   intentionally focuses its window, conflicting with the current no-focus task
   constraint. Native-only Show suppression misses independent plugin Show,
   Focus and geometry paths. Rebuilding task-safe Release native components may
   qualify isolated Release lifecycle, but cannot establish unchanged default
   activation. Do not rerun the old failed package or alter default behavior just
   to claim acceptance.
2. Validate remaining provider/second-line movie identity; retain upstream
   placeholders and failures. Account-required cloud playback still needs its
   separate external authorization and test conditions.
3. Bind the remaining UI, multi-item library/sort, cache-page cover and source
   persistence scenarios to current product inputs. Dual reload, concurrent
   save/delete and one-target library cold-process restoration now have current
   evidence. Prior scoped evidence
   may be reused only after verifying affected inputs and exact scope.
4. Obtain cold-frame resource/timeline evidence for a production performance
   candidate, then use the unchanged startup/navigation/scroll budget.
5. Complete whole-package integration only after the above evidence holds.

## Local evidence routes

All run directories below are under `.probe/goal-resume-20261115-evening/`:

- `line-sync-final-tests-20261117-v1/result.json`
- `line-sync-guard-red-20261117-v2/result.json`
- `line-sync-resume-red-20261117-v1/result.json`
- `line-sync-resume-green-20261117-v2/result.json`
- `current-player-yunduo-public-opaque-v11-final-20261117/result.json`
- `CURRENT_PLAYER_FINAL_VISIBLE_UI_AUDITED_20261117_V1.json`
- `detail-sync-resume-debug-bytes-audited-20261117-v3.json`
- `detail-sync-resume-release-bytes-audited-20261117-v3.json`
- `CURRENT_RELEASE_CORE_JS_RELOAD_INVALID_SAVE_DELETE_AUDITED_20261117_V1.json`
- `js-current-abi-20261117-v2/result.json`
- `JS_SAVE_DELETE_20261117_READONLY_AUDIT_V1.json`
- `js-save-delete-20261117-v2/result.json`
- `CURRENT_LIBRARY_CURRENT_COLD_20261117_AUDIT_V1.json`
- `current-player-yunduo-public-opaque-v13-library-20261117/result.json`
- `current-player-yunduo-public-opaque-v14-cold-20261117/result.json`
- `SECOND_LINE_SHORT_CLIP_20261117_READONLY_AUDIT_V1.json`
- `current-player-yunduo-public-opaque-v12-second-line-20261117/result.json`
- `line-sync-release-runtime-20261117-v2-manifest.json`
- `line-sync-release-independent-restart-20261117-v1/failure-record.json`
- `RELEASE_FOREGROUND_SCOPE_CLARIFICATION_20261117_V1.json`
- `owned-skp-d291834-frozen-20261117-v1/result.json`
- `SKP_OPERATION_INVENTORY_20261117_V2.json`
- `glass-guard-baseline-profile-v1/result.json`
- `glass-guard-candidate-profile-v1/result.json`

Additional local artifacts: `.probe/performance-continuation-20261117/` contains
the pixel comparison, Profile build audit and experiment disposition;
`.probe/startup-continuation-20261117/analysis.md` records the static activation
path review. Neither artifact family establishes whole-goal acceptance.

Local commits are authorized. No remote push or release is performed. Whole-goal
acceptance remains false; this continuation is not a completed delivery claim.
