# Source and player continuation — 2026-11-17

This continues the original scope in IMPLEMENTATION_PLAN_20261108.md. Current
product code baseline is 6144bedc, with the task window guard recorded below.
Local work remains without remote publication.
Historical failures and successor receipts remain intact under `.probe/`.
An earlier user instruction authorized an active goal and parallel continuation,
superseding the old no-goal preference. Current priority and pause state follow.

## Current priority — user instruction, 2026-11-18

The user's latest clarification allows access to real accounts and user data,
reports that no application account is in use, and retains the no-focus
requirement. A read-only presence check subsequently found pre-existing
non-empty Windows credential entries and WebDAV configuration; these may be
residual, and ownership, validity, and freshness remain unverified. Do not
override the user's report based on entry presence alone.
This supersedes the prior real-data access prohibition for the continuation;
the saved goal text and historical evidence retain the older wording. Inspect
actual configuration before treating an absent account as a test blocker.
Performance was previously deferred, but the newest full-goal instruction
restores it as a required acceptance item. A task-owned non-input Windows
desktop was tried for unchanged ordinary startup and the current release
failed before its first frame; do not switch the input desktop, activate an
existing user window or claim startup acceptance without a supported route
that also preserves the no-focus constraint.

The previous order deferred performance, but the user's new full-goal
instruction restores it as an outstanding acceptance requirement. V29
stability, final package, scoped protocol and cover acceptance are retained;
successful scenes are not repeated without an affected owning-input change.
The current continuation audits the one-shot V30 failure and will not repeat
it without a new bounded execution authority.

The intervening performance preparation remains preserved under `.probe/`:
V30 produced a successful Profile kernel, followed by a failed output-locator
check. The actual V31 one-shot run is under `.probe/pp32`: its fresh Profile
kernel stage naturally exited 0, then the output-census check stopped the run
before `gen_snapshot`. Separately, `.probe/pp31/source` was audited and found
to be a contaminated partial copy with a reused V30 `app.dill`; it was not the
V31 compiler input. V32 subsequently completed the current-source Profile
kernel and `gen_snapshot` stages and staged a 59-file runtime. That compiler
phase had no GUI or frame measurement; the later isolated proxy-route run
below completes all original 20 scenarios and retains full frame records, but
rejects the strict budget. No performance candidate was adopted in the
  product or final Release package. The user has restored performance to the
  full-goal scope; the later measured run is recorded below.
The V30 one-shot authority remains consumed and explicitly forbids retries;
any successor needs a fresh frozen output contract and separate one-shot
authority. Retain the original workload, readiness, raw-frame budget and
failed runs; no performance result is accepted yet.

The post-export requirement audit is recorded in
[FINAL_ACCEPTANCE_20261118.md](FINAL_ACCEPTANCE_20261118.md), retaining all
thirty requirements, precise protocol/cover scopes, outstanding external
conditions and the verified local ZIP. No new product gap was identified in
the specified reachable UI or selected playback/cover paths.

## Continuation update — 2026-11-18 evening

The previously prepared real-library cover candidate was exercised once
through the unmodified production repair API, but only in a task-owned database
projection. The source database was opened read-only; exactly one identity
was copied into a temporary database. The API filled its single missing
history cover from the one existing exact-identity variant. The copied
identity, row keys, all non-cover values and SQLite types remained unchanged;
the real database/configuration and production core bytes were unchanged, no
network was performed, and the owned host drained naturally. This verifies
one local recovery case only; the unrelated missing cover in the visible top
20 remains unresolved, and no arbitrary-cover or full-library claim follows.
Receipt: `.probe/current-real-config-permission-20261118/one-real-cover-repair-owned-v1-c3ec451ca53241f3bbfafd8673d2d6ea/aggregate.json`.

The ordinary-startup observation tool's first attempt failed before observing
the app because Win32 reports a valid empty desktop enumeration as
`FALSE`/`ERROR_SUCCESS`. A hash-bound v2 test-only successor handles that
empty snapshot. It reached the unmodified product launch on a fresh
non-input desktop, while the input desktop and foreground PID stayed
unchanged; however, the product exited before its first frame with
`0xC0000142` (`STATUS_DLL_INIT_FAILED`). The retained receipt has no loader
diagnostic identifying the failing DLL or initialization callback, so the
failure is not attributed to USER32. No UI actions, preference edits,
account creation, or runtime-file changes occurred. The process exited
naturally and the observer saw no focus/input-desktop violations, but this is
a failed startup observation, not ordinary-startup acceptance. Earlier
receipts and the v2 result remain intact. Do not retry from the same desktop
environment until the failing initialization is independently identified.
Receipt: `.probe/release-parallel-20261117/ordinary-inactive-desktop-boundary-v1/ordinary-desktop-actual-once-v2/result.json`.

### 2026-11-18 follow-up — startup diagnostic bridge and Top 20 cover

A read-only bridge binds the v2 failed launch's EXE SHA256 to the executable
inside the verified current Windows ZIP. It records 166 observer samples and
zero input-desktop/foreground changes. Historical Loader Snaps for a different
EXE captured `USER32.dll` failing `DLL_PROCESS_ATTACH`; a no-window GUI control
reached `WinMain` on `Default` but failed on the private desktop. This supports
a desktop-environment hypothesis only: the current EXE's failing module and
the OS condition remain unidentified. No repair or ordinary-startup acceptance
is established. No new product launch, input-desktop switch, focus change,
registry write, or process-memory modification was performed during this
read-only review. Bridge:
`.probe/release-parallel-20261117/ordinary-inactive-desktop-boundary-v1/ORDINARY_STARTUP_HISTORICAL_BRIDGE_V1.json`.

The Top 20 candidate was examined in a task-owned database/config projection.
It is a TVBox child already present in the copied configuration, but the
aggregate has an explicit empty child selection and the child is disabled.
Consequently it is not registered in the isolated runtime; this is not a
missing plugin/configuration-file case. The unmodified production cover repair
API returned zero, leaving the projection at two empty cover rows. This
candidate has no nonempty exact-identity cover variant in the projected
favorites/progress/history rows, so the local donor path cannot resolve it.
This does not prove an upstream cover is unavailable. No source was enabled
and no network request or real-library write was made. Receipt:
`.probe/remaining-cover-20261118-top20-v1/top20-repair-owned-v1-9bed3664cb59464c8850c5ea3a1ae57f/aggregate.json`.

The full-goal continuation resumed the existing V30 Profile build evidence.
Its one-shot Kernel stage exited naturally with code 0 and remained drained
for more than eight seconds, but the declared `kernel-observed-outputs.txt`
was empty, although the isolated build tree contains a 64,682,784-byte
`app.dill` at
`.probe/pp30/source/.dart_tool/flutter_build/055890d95b7063c6574cda4b01e375d5/app.dill`.
The coordinator therefore rejected the missing unique absolute `app.dill`
output record before `gen_snapshot`; the file cannot be promoted after the
fact because it was not named by the approved output-list contract.
The V30 authorization explicitly disallows retries and is consumed. No AOT,
runtime stage, GUI, or performance measurement was produced. A successor
requires a new frozen input/output contract and separate one-shot authority.
Receipt: `.probe/pp30/build-once-v1/result.json` and
`.probe/pp30/build-once-v1/current-full20-profile-kernel/result.json`.

At the time of this earlier note, the historical plan under the isolated
`app-tray-barrier-counterexample` fixture cited
`PRIVATE_DESKTOP_INITIALIZATION_CAUSE_QUALIFIED_V1.json`, but a bounded search
did not find the raw receipt. A later search located the receipt at
`.probe/goal-resume-20261115-evening/PRIVATE_DESKTOP_INITIALIZATION_CAUSE_QUALIFIED_V1.json`
and independently rehashed all 27 declared evidence files; all hashes match.
Its native fixture records private-desktop `NtGdiInit` returning zero with
`STATUS_ACCESS_DENIED`, and a default-desktop control returning one. This
confirms the historical fixture only. Its source commit and core are not the
current Release's; the current failure's DLL/callback therefore remains
unknown, and ordinary-startup acceptance remains false. See the 2026-11-19
correction below and `.probe/goal-remaining-review-20261119-c8a4e3/REMAINING_REVIEW.json`.

The accepted native provenance review also confirms why the earlier minimize
event cannot be resolved from current source alone: its QPC review is
cross-process, but the sequence is module-local, the asynchronous message ID
is not carried, and no Dart caller is attributed. The latest production AOT
pending-quit run observed zero native minimize method entries; this proves
that run's negative control, not the historical caller. Existing root review
rejected false-quit/forced-cleanup/scope-inflation controls but marked old
caller attribution unresolved. Do not infer a historical minimize call from
the V4 user attestation or from the accepted current run.

The read-only credential-presence check found non-empty entries for several
cloud-provider credential targets and WebDAV. It inspected presence only,
never credential blobs; it does not establish that an account is currently
configured for application use or that credentials work. No login, remote
transfer, or cleanup was attempted. A8 remains scoped to existing local and
anonymous protocol evidence until an authorized test account/environment is
available.

### Full-goal continuation — renewed by the user

The user has renewed the objective to finish the original 18+12 requirements,
including performance, and has explicitly said to keep working until complete.
The no-focus/no-input-desktop-switch and no-unauthorized credential, real-DB,
login, transfer, or remote-cleanup constraints remain in force. The new active
goal therefore does not waive the missing per-action permissions for compiler,
GUI, network, credential, or database operations.

The already-consumed V30 performance authorization was read-only audited. Its
single Profile kernel command exited zero and naturally drained, producing a
64,682,784-byte `app.dill` under the frozen task-owned source tree. The
Flutter `assemble` tool's `build-outputs` writer does not populate a precreated
empty file: it writes only when the path does not exist or its current text
differs, and this tool's implementation reads an existing empty file after
skipping the initial write. Consequently the output list stayed zero bytes;
the harness could not identify the unique kernel and stopped before
`gen_snapshot`, Profile AOT staging, GUI, or measurement. V30 explicitly
allows one execution only, disallows retries, and grants no GUI or measurement
permission. Its partial output and authority remain preserved; do not rerun
or reuse that authorization. A successor must use a fresh run root and a
newly reviewed output-manifest strategy, then obtain explicit new authority
before any compiler command.

The already-prepared public source-index lookup for the unresolved Top 20
cover was also reviewed. Its one bounded search ended naturally with exit 1
and `Unable to reach Agent2API: fetch failed`; it yielded no public source
result and did not access user credentials, browser state, or the real
library. Do not repeat the same failed network operation. Continue static
inspection of the source's actual poster-bearing endpoints/parsers; any new
network request still needs an explicit bounded scope and permission.

## Accepted stability and package phase — historical snapshot, 2026-11-18

Stability and final package acceptance passed in the following order, with
performance deferred at that time. The later full-goal renewal below
supersedes this historical priority.

1. Stability acceptance first, now passed. Generate the fresh native runner and window
   plugin needed to validate the adopted PIP recovery and task nonactivation
   fixes, using the already qualified normal-product AOT. Then validate the
   current Release during playback, episode switching and an outstanding
   request, followed by the original ask/Quit flow and natural owned-process
   exit. Preserve earlier failed runs and the latest possible manual-minimize
   clarification; historical cause remains unresolved.
2. Final package verification after stability acceptance, now passed. Bind the current
   product sources, native files, AOT and runtime assets in one package, then
   perform the final source-bar/sorting/player/exit smoke checks. Reuse the
   scoped three-protocol and four-cover evidence where owning inputs permit.
3. At that phase, performance was deferred by the user and skipped.
   Retain the original startup/all-frame budget, original twenty scenarios,
   failed measurements and missing public-content inputs as open work. Do
   not run more performance diagnostics, renderer experiments or benchmarks
   within that historical phase. Performance was not a completion gate for
   steps 1 and 2; skipping it did not qualify performance or complete the full
   original goal. The later renewal below supersedes this deferral.

Existing task-isolation, focus, real-account and publication boundaries remain
in force. This priority update does not authorize external-account acceptance.

At the time of this phase, stability acceptance had passed all three current-package
scenes. Playing, episode-two switching and an outstanding request each finish
through the original ask/Quit flow, natural exit zero and at least eight
seconds of empty owned Job on both clocks. The 59-file short runtime package
retains the qualified normal production CADA AOT and the guarded native runner
and window plugin. Source/build/runtime ownership is explicitly bridged;
the package is not described as 59 files freshly built from one commit.

Final visibility smoke has passed Home, Settings, LAN header expand/collapse,
source management, sort-page Back without saving, source-manager Back and
original ask/Quit. The successful background-window run naturally exited zero,
with empty-Job duration above eight seconds on both clocks, all 16 helpers naturally closed,
and unchanged runtime/input files. Its six-stage test-selector build also passed.
The earlier background attempt incorrectly requested a nonexistent Cancel
button. That rejected attempt and its natural original-Quit cleanup remain
recorded; the narrow successor uses the two observed original Back structures.
The previous minimized attempt is separately explained by the user's direct
confirmation of manual minimization; older run attribution remains open.
Performance was skipped and unaccepted at this phase; the full original goal
remains open, with later continuation recorded below.
Current evidence is recorded in
`.probe/goal-root-acceptance-next-20261117/CURRENT_STABILITY_AND_FINAL_PACKAGE_PHASE_ACCEPTANCE_V1.json`

## Full-goal continuation — 2026-11-18

The latest user instruction restores every remaining item, including
performance, to the active completion goal. The current audited state is:

- V30's one-shot Profile Kernel stage exited 0, but its declared output list
  was empty. Its no-retry authority is consumed; no AOT or frame measurement
  exists. A fresh output contract and execution authority are required.
  Read-only source inspection of the pinned Flutter 3.47.5 implementation
  identifies the precise contract fault: `assemble.dart`'s
  `writeListIfChanged` writes a missing `--build-outputs` file, but when that
  path already exists empty it only rewrites on unequal content. V30 created
  an empty file, so the successful Kernel output (`app.dill`) never appeared
  in the observer list. The next preparation must use a fresh run directory
  and a manifest path that does not exist before `assemble`; validate the
  recorded absolute `app.dill` and its hash before admitting `gen_snapshot`.
  This is source-only preparation guidance, not a V31 build approval or a
  reused V30 authorization. Root must review a new exact one-shot compiler
  authority before any compiler process starts.
- 2026-11-19 V31 output-contract audit: the separate `.probe/pp31` static
  preflight confirmed V30's kernel stage naturally exited 0 while its existing
  `--build-outputs` file remained empty and its generated `app.dill` existed
  separately at 64,682,784 bytes. The pinned Flutter `assemble.dart` explains
  why: it writes a missing list, but leaves an existing empty list untouched
  when contents compare equal. The preflight reserved fresh paths under
  `.probe/pp31/build-once-v1`, which remained absent; it did not start a new
  source copy, compiler, GUI, network or timing run. Independently, the actual
  V31 one-shot was executed under `.probe/pp32` with its own plan and authority:
  the Profile kernel exited 0 and naturally drained beyond eight seconds, but
  the output-census assertion failed before `gen_snapshot`; V31 AOT, runtime
  staging, GUI and measurement were not reached. Preserve that consumed V31
  authority and failure receipt; no retry is implied.
- The current package's unchanged ordinary launch exited `0xC0000142` on the
  non-input desktop. The input desktop and foreground did not change. The
  failing module is unknown; ordinary startup is not accepted.
- The Top 20 Sou4K child has no same-identity local cover donor and was not
  registered in the isolated runtime. Search results from this provider set
  `cover: None`; its detail path resolves cloud shares through
  `/api/check-links`, not a poster endpoint. No request was made because no
  identity-safe cover endpoint was established.
- The old private-desktop `NtGdiInit` receipt has since been located and its
  declared evidence hashes reverified, but remains scoped to its historical
  native fixture and does not identify the current Release's failing DLL.
  Historical minimize attribution likewise remains unresolved by the
  existing native timeline, whose method caller and cross-file clock are
  absent.
- Credential presence alone does not prove an application account or valid
  credentials. No login, transfer, or cleanup was performed.

The goal remains active and not accepted. Continue when fresh bounded
authorities or compliant test conditions become available; do not reuse the
consumed V30 authority, repeat the known-failing startup in the same desktop
environment, or infer success from preparation-only artifacts.

### 2026-11-19 — V31 output-contract stop, `.probe/pp31` copy audit, and seek regression

Read-only inspection found `.probe/pp31/source` is not a clean build input. All
819 source paths named by the V30 plan exist there; one path
(`lib/ui/widgets/miuix_controls.dart`) differs from the V30 frozen hash because
the click-to-seek fix is now present. The directory also contains a
64,682,784-byte `app.dill` whose SHA256 is exactly the V30 output hash
`67F07BE443AEDEDD4328301F17CBD6224C64A1C81E7571A7C5BBFD534CDA94B8`.
It is therefore a contaminated partial copy, not a fresh compiler result, and
was not the actual V31 source root. The V31 compiler plan, one-shot authority,
and failed output-census receipt belong to `.probe/pp32`; its kernel stage
passed, but no V31 AOT or GUI measurement exists. The `.probe/pp31` audit itself
ran no compiler, GUI, network or measurement.

The click-to-seek work was re-run on the final working tree after analyzer/lint
cleanup. The 31 ordinary progress/control tests pass, and the serial
native-media cohort passes 24, including PlayerPage and native WAV seek
(`time-pos=22.576s`, one commit, at least 300ms continued playback). Focused
analysis of the six changed Dart files reports `No issues found!`; formatter,
diff check and the 423-note gate are also verified. See the 2026-11-19 section
in `FINAL_ACCEPTANCE_20261118.md` for exact logs. No new Release or ZIP was
built, so this closes only the reported seek defect, not final package binding.

The user's instruction to continue restores performance as a goal but does not
turn the consumed V30 one-shot into a reusable authority. The prior V30 plan
also explicitly says its execution was not approved, its authority permits one
compiler execution only, and GUI/network/measurement were not approved. Any
successor must use a fresh immutable source/toolchain/runtime/output plan and
the original performance workload. Other remaining conditions stay as listed
in `FINAL_ACCEPTANCE_20261118.md`; do not re-run ordinary startup in the same
failing desktop, infer the unresolved historic minimize caller, use title-only
cover matching, or treat local proxy tests as external account/transfer proof.

### 2026-11-19 — progress-click seek continuation

A page-level double-tap recognizer may delay a single tap's Miuix value callback
until after pointer-up. The adapter commits that late tap while preserving drag
preview/end, cancellation, and immediate ordinary-tap behavior. On the final
working tree, 31 ordinary control/progress widget tests and 24 serial
native-media tests passed, including the production PlayerPage seek path and an
independent local WAV/libmpv check (native position 22.576s, one seek commit,
then at least 300ms playback advance; observed range 303–340ms). The old adapter behavior was temporarily restored;
the click regression failed and passed again after restoration.

Formatter check, `git diff --check`, and the 423-note gate pass. Focused
`flutter analyze` on the six actually changed Dart files reports `No issues
found!` (exit 0). A broader seven-file check that includes unchanged legacy
`zz_t1023` has only that file's existing import/const infos; it is not conflated
with the six-file result. Exact logs and outstanding overall-goal boundaries
are in `FINAL_ACCEPTANCE_20261118.md`. The user's running Release and final
ZIP were not replaced. This closes only the click-to-seek issue;
performance, ordinary startup, the Top 20 cover, external account/transfer
scope, and historical minimize attribution remain open.

### 2026-11-19 — V32 current-source compiler and static runtime bridge

V32 used a new task-owned source root at `.probe/pp33/source`, frozen against
current HEAD `c58b7dc7cbd765b7fe469dc73aa81a0911ac4589` with 819 input files.
Its one compiler authority was consumed exactly once: the Profile kernel and
`gen_snapshot` stages both exited 0, had no forced cleanup, and each owned Job
naturally drained for more than eight seconds. Because Flutter left the output
manifest empty, the runner admitted only the unique `app.dill` generated under
that fresh source root, copied it byte-for-byte to `compiler-input/app.dill`,
and then ran `gen_snapshot`; no V30/V31 kernel was reused.

The resulting AOT is `.probe/pp33/full20-profile-app.so`, SHA256
`5163D4DEDF0CA5BFE82D16507EA8C77A7877AA3FC06304D47F77C7967F6C29C0`.
`baseline-runtime/` contains exactly 59 staged files; only `data/app.so` and
`flutter_windows.dll` differ from the normal runtime. Receipts are
`.probe/pp33/build-once-v1/result.json`,
`.probe/pp33/build-once-v1/CURRENT_PROFILE_KERNEL_PRODUCER_BRIDGE_V32.json`,
`.probe/pp33/build-once-v1/CURRENT_PROFILE_STATIC_RUNTIME_STAGE_V32.json`,
and the read-only static PE bridge
`.probe/pp33/CURRENT_PROFILE_NATIVE_PE_ABI_STATIC_BRIDGE_V32.json`. That
bridge checks 22 native EXE/DLL images and 179 imported Profile-engine symbols;
the named/ordinal symbols resolve against the Profile export table, with no
ordinal-name mapping change versus the normal Release engine. This is only an
import-table preflight, not proof of ABI signatures, runtime dynamic loading,
or successful engine initialization.

A subsequent read-only audit rehashed all 59 staged files against both V32's
runtime manifest and the normal runtime manifest. The exact inventory and
per-file sizes/hashes match, and exactly `data/app.so` plus `flutter_windows.dll`
differ from the normal runtime. Receipt:
`.probe/pp33/CURRENT_PROFILE_STAGED_RUNTIME_REHASH_V32.json`. This remains
static evidence only and does not qualify runtime initialization, GUI startup,
or frame performance.

This was a build/staging result, not performance acceptance: its original
build receipt records `actualGUIStarted=false` and
`actualRuntimeQualified=false`. A later isolated run using the V32 AOT/runtime
and preserved workload completed all 20 windows and naturally exited zero,
with runtime qualification; its 1172-frame strict budget comparison failed
(build/raster/totalSpan over-budget counts 1/7/14; maxima 35,998/346,368/
530,909 μs). Keep the build-only receipt's original fields unchanged. The
current measurement and its window-by-window scope are recorded in
`FINAL_ACCEPTANCE_20261118.md` and
`.probe/perf-route-adapter-20261119-766ae2cfa4/circle-current-normal-full20-v32-loopback-v1/result.json`.
Any successor optimization must retain the same workload and exact frame
budget, fresh source/runtime bindings, and separately admitted quiet window.

## Implemented and verified

- Detail/source synchronization, late-result rejection, bounded loading
  skeletons and reachable resume controls pass actual native/UI checks.
- Detail/Follow's three obsolete static checks are replaced by actual page
  behavior: 85 tests pass and four isolated behavior mutations fail.
- More actions scroll and retain keyboard order. Original native 181px and
  synthetic 214px overflows remain recorded; 17 tests and current UI pass.
- Source-provider saving uses stable semantics. Current positive and cold
  restart scenarios pass, with native AXTree errors reduced from 21 to 0.
- Five animation styles have forward/backward tab and route samples, plus
  none controls. Actual snapshot painters close the old zoom observation gap.
- Native quit now waits for active and retiring playback/live/preview players.
  The pending-HTTP baseline crashes at the exact registered media wakeup
  callback address. The 6bb7e49 successor detaches it before the core fence,
  exits zero in 5.658 seconds, and records natural Job zero for 8.029 seconds.
  Forty-five related lifecycle, preference, live, preview and transport tests
  pass. Existing analyzer diagnostics are separately tracked.
- Current production C ABI reload and save/delete races preserve ownership.
- Earlier API-only relay denials remain failed observations. Their successors
  qualify exact media paths as described below; catalogues alone do not qualify
  playback.
- All three protocol families' exact fresh selections pass original core HLS
  forwarding and independent three-second file-PCM controls. Muted samples
  remain zero; positive nonzero counts are 256488, 120615 and 264499. All retain
  exact selections, headers and core/decoder bytes. Independent audits reject
  four, five and five altered controls. This is bounded decoder evidence, separate
  from PlayerPage presentation, device audio and full-film playback.
- The direct selection additionally yields four physical 1920x1080 offscreen
  native frames, 1.8 seconds of progress and 566793 first/last changed color
  pixels. Its relay orders a previously successful address first within the
  unchanged fresh public DNS set. Seven altered controls fail. Two original
  DNS-order requests retain the core three-second header timeout and HTTP502;
  earlier PNG-encoder failures and zero-byte files remain failed. Original DNS
  order and presented PlayerPage video are unqualified by this diagnostic.
- Two library items retain identities, ordering, timestamps, each eight-second
  progress and decoded covers across the same-profile cold process. All three
  original library subtabs and two cache covers pass independent verification.
- Delayed danmaku cancellation, exact comment binding, unmount/reentry and
  scrolling to channel 55 pass on the current package. Live tab return preserves
  the same player, pauses while hidden and restores actual changing video.
  The independent audit rehashes screenshots and rejects seven altered controls.
  The two initially black return captures remain recorded before the successful
  pair; the fixture repeats a short sample and is not full-film evidence.
- Populated live playback and independent nonzero decoder PCM are qualified.
- Task-safe Release native components retain production AOT/core bytes. The
  original ask dialog and semantic Quit pass on the earlier AOT. The current
  normal-entry Release AOT rebuild and 59-file staging pass. Its new ask run
  fails before invoking Quit: the window is minimized to 160x28. A successor
  observes minimization, but its task-window restore triggers the foreground
  gate. Both failed runs and forced cleanup remain; that restore is not repeated.
- The current production AOT now passes original ask/Quit with a qualified
  diagnostic native pair. All 57 other runtime files remain byte-identical.
  Home and ask are complete 1280x800 captures after 5.054454 seconds of stable
  visibility. Original Quit exits zero and retains natural Job zero for
  8.041078 seconds without force. All ten hide records are owned shadows;
  the main window is never observed minimized. Earlier failure causes remain
  unresolved. This scene has no active player and Home settles to a network
  error; ordinary foreground startup and content remain separate.
- The affected-input reuse audit rechecks 3605 live/frozen Release inputs,
  35 compiled assets, 269 core inputs and 59 runtime files. Four current Debug
  scenes revalidate with 3677 inputs and 416 exact product-parity rows. Twelve
  altered controls fail. The package matrix keeps each mode and scope separate.
- Three exact anonymous source selections now pass original FollowPage card
  to MediaPage/PlayerPage, current session reference graphs, 1920x1080 video,
  advancing position, same-player settings return, original Back and natural
  ask/Quit. Their visible video changes are 166253, 43068 and 146226 pixels.
  Four current image responses decode; three cards have fresh GUI evidence
  and the fourth same-native card has an exact owning-input/pixel reuse bridge.
  The combined audits reject 62 altered controls. No fourth fresh window,
  arbitrary all-cover, device-output or full-film acceptance is inferred.
- Current production Release AOT original playing-page ask/Quit and original
  Episode Two switch pass independent audits. Actual video pairs change 33271,
  36333 and 43204 pixels; every scene stays visible for at least five seconds.
  Both runs exit zero and naturally drain for 8.033101/8.036261 seconds.
  The first pending scene is rejected because native timeout precedes Quit;
  a held server body does not establish a still-pending native request.
- Two pending successors fail visibility without restoring their windows.
  Both show native method minimize, actual main-window SC_MINIMIZE and
  SIZE_MINIMIZED/iconic1. All hide records belong to the shadow. One has only
  a read-tree action before failure; the other invokes the original second
  episode parent button. The independent audit rechecks 39 original/frozen
  inputs and rejects ten controls. Calling origin remains unproved.
- One fresh production-AOT pending ask/Quit now passes with the shared-QPC
  native pair. The pending scene stays visible for 5.061644 seconds; two
  transfers send no body and have no native failure or second first frame
  before original Quit. Main exit is zero, exact window gone and natural
  Job-zero is 8.040445 seconds/160 samples with no force. All seven helpers
  qualify, four with concurrent eight-second observations. Fourteen required
  modules bind actual paths/hashes; root rechecks 113 inputs and all five PNGs,
  rejecting eight controls. No minimize occurs in this run, leaving the old
  calling origin unexplained; historical failures remain rejected.

Local evidence: `.probe/goal-resume-20261115-evening/` contains
`U5_SOURCE_SEMANTICS_COLD_B40_20261117_AUDIT_V1.json`,
`FINAL_MOTION_PAINTER_20261117_AUDIT_V1.json`,
`TCP_WAKEUP_EXACT_ATTRIBUTION_AUDIT_20261117_V1.json`,
`current-player-error-close-tcp-shutdown-v1/result.json`, and
`stacked-detail-player-shutdown-final-v3/result.json`.
The new independent library/live audit is
`TAKEOVER_LIBRARY_LIVE_20261117_AUDIT_V1.json` in the same directory.
Protocol and Release evidence are in `.probe/protocol-final-20261117/` and
`.probe/release-isolated-native-20261117-v1/` respectively.
Fresh parallel results are under `.probe/protocol-parallel-20261117/` and
`.probe/release-parallel-20261117/`; the latter contains
`CURRENT_AFFECTED_INPUT_PACKAGE_REUSE_AUDITED_V1.json`.

## Historical execution detail and remaining scope

1. Attribute actual program descriptors and generated shaders to the measured
   synchronous driver links using matching offline engine symbols and an owned
   diagnostic process. Select a new rendering hypothesis only after causal
   evidence; then retain exact visual parity and the original full-frame budget.
   The isolated circular candidate improves several untraced measurements but
   still exceeds the unchanged 16.667ms budget. A separate diagnostic frame is
   288.579ms with 236.322ms of driver links. Trace results do not replace the
   untraced measurements. The rejected prewarm/shadow/repaint experiments stay
   rejected.
   The shared stroke/rim-program candidate passes actual shader and component
   pixels but is rejected after the full same-source untraced comparison.
   Startup raster peaks are 324199/329501us; navigation raster peaks are
   46345/72113us. Both complete 20 windows and natural exit. The independent
   audit checks all 1186/1194 frames and rejects four altered controls.
   Physical program count decreases from four to three; actual driver link
   count is not inferred. Product rendering is unchanged.
   A native circular clip fails all twenty component pairs and is rejected
   before timing. A separate circle/rim candidate passes direct current-product
   twenty-pair RGBA parity and demand loading, but its complete same-source
   Profile pair retains 1268/1259 frames with startup raster375245/303557us,
   navigation36974/65974us and all-frame over-budget9/14. Both complete twenty
   windows and natural exit. Four altered controls fail. The two initial
   pre-start stability failures and their196/304 frames remain retained.
   The candidate remains outside product; performance remains unaccepted.
   A matching-engine/PDB hardware diagnostic completes all twenty windows and
   retains 1229 frames, 39 actual program descriptors and 78 generated GLSL
   captures. Eight runtime-effect captures uniquely match four packaged
   assets. The first failed stability run remains retained. Capturing can
   affect timing; descriptor counts do not establish actual GL-link counts.
   Actual embedded-engine V3 now completes twenty windows and 1181 frames,
   retaining all 229 startup records. Thirty-nine keys bind 78 compile returns
   and 39 observed GL link returns. All 78 full function tables and loaded
   294-byte target bodies qualify; root rehashes 509 inputs and rejects eight
   table mutations, while independent review passes 46 checks. Original V1
   prelaunch and V2 table-guard failures remain rejected. The 156 public
   compiler boundaries form 78 nested pairs; all raw strings and ordered
   macros qualify. Root separately reviews 59 exact API-only parameter sets
   against 245 inputs. Compiler workers remain unbound to key/program/link.
   A separately admitted API-only batch now invokes all 59 exact inputs once:
   every HRESULT is zero, every output is structured DXBC and all 59 local
   blob Releases return zero. The owned worker exits zero and naturally drains
   for 8.028296 seconds. Root rehashes 199 inputs and rejects seven DXBC/scope
   mutations; independent review passes 31 global and 649 case checks over
   276 artifacts. This accepts public return/output behavior only, without
   original-binary equality, strong render attribution or measured cost.
   The old incomplete executor closure remains rejected; the actual batch is
   consumed once and is not rerun.
   Frozen actual stacks locate the largest observed compile within
   `CircularRRectOp::onExecute`; its geometry-processor name does not identify
   a spinner, widget or drawing command. Prepare a minimal op-entry/return
   diagnostic before choosing a renderer hypothesis. The V1 stack guard is
   rejected: entry RSP plus eight belongs to the adjacent actual caller, not
   the named onExecute frame. Twenty-eight frozen native observations support
   the corrected predicate. A materialized V3 native fixture now qualifies
   39 raw receipts, ten actual op entry/return pairs, ten R9 flows and three
   exact caller bindings. Seven actual data failures and eighteen stack
   mutations reject; two strict return denials remain forced and unqualified.
   The positive run exits zero with natural Job-zero for 8.034255 seconds;
   independent review passes 518 checks plus 171 origin/ABI checks. Root
   rehashes 77 inputs and all actual memory. Compiler Jobs still fail natural
   drain, and their retained artifacts do not upgrade those Jobs. Fixture
   program metadata is preinitialized; this does not establish actual engine
   cold metadata, GL CreateProgram returns, op/widget origin or cost. The
   separately qualified single actual engine diagnostic now retains four op
   returns, eight Create saved returns, four same-caller typed metadata/key
   flows and 36 raw receipts. Root passes 779 checks and ten scope mutations;
   independent protocol review passes 826 checks. All 1924 startup and 2903
   total frames across twenty windows are retained after explicit target-return
   coverage retirement. Exit is zero without force; natural empty Job spans
   8.024210 seconds. Returned sk_sp semantics and cold metadata remain unknown.
   Bounds [27,65,132,99], a black-alpha-.06 capsule and zero coverage processor
   support the selected Home segmented-tab indicator as a source candidate.
   Validate a bounded rendering replacement with exact component/composition
   pixels, then original untraced performance. Widget identity, cost and worker
   attribution are not inferred from bounds. The sole diagnostic GUI stays
   consumed; no product rendering change is admitted.
   The fixed private four-conic path now passes 24 focused image pairs,
   468 real segmented-row pairs with 936 RGBA-format comparisons, and the
   original twenty composition image pairs, all with zero changed bytes.
   Theme, direction, fractional position, motion, focus, pressed and background
   cases retain their original pixels. A separate mask-SDF shader candidate is
   rejected by sixty differing alpha pixels, maximum channel difference three.
   The exact private source is also compiled into a separate Profile AOT:
   425 copied sources, 6853 frozen bindings, natural exit zero/Job-zero
   8.027848 seconds. The 59-file runtime changes only app.so; root verifies
   current ELF64 snapshot mappings. This is not production Release or
   performance acceptance. The sole selected-only native-key census now
   naturally completes twenty windows and retains 1097 frames, including all
   117 startup records, with Job-zero for 8.032535 seconds. It accepts zero
   Create calls and zero op calls: native boundary/key effect remains false,
   and the earlier positive empty-collection checker is explicitly rejected.
   Two matching engine mappings and a later registry overwrite are observed;
   no executed-PC or debug-register history proves the executing mapping or
   explains the empty capture. Do not repeat the consumed census.
   Its exclusive plain Profile also completes twenty windows naturally,
   retaining all 1143 frames and 152 startup records, with Job-zero for
   8.034137 seconds. Exact build/raster/total-span failures are 1/15/31;
   maxima are 19491/346259/499690us, including startup failures 1/3/7.
   Enforce rawUs*60<=1000000; 16667us fails. No product admission or shader-cost
   inference follows from this rejected measurement, and it is not rerun.
   A new three-source candidate combines the selected indicator, full-window
   general-path clipping and the actual Home breathing skeleton fill.
   Correct material_ui focused light/dark fixtures each pass 144 dual-format
   comparisons, including the actual 148-by-266 poster. The earlier focused
   fixture used a different Theme provider: equality remains fact, while its
   full theme-qualification claim is withdrawn. Combined actual24 and original20
   software pixel pairs pass all 68 RGBA comparisons. Its separate Profile AOT
   compiles naturally with 425 sources/7274 frozen bindings and Job-zero
   8.040191 seconds; native59 changes only app.so. This V1 is held before plain:
   the new window ClipPath rejects corner hits that the original default
   ClipRRect allowed, while the new shimmer CustomPaint accepts corner hits
   that the original BoxDecoration rejected. Prepare a fresh private render-
   object successor preserving both original hit semantics, including before
   paint. That fixed successor now passes 77220 actual queries per cohort
   across 180 before/after-paint cases and ninety dynamic pixel pairs. The
   full combined24/focused72/original20 cohort passes 212 RGBA comparisons;
   exact 417-source bridges reuse old baselines without rerunning them. The
   focused baseline retains the same B651 indicator in both cohorts and is
   scoped to WindowFrame/Shimmer. The new AOT compiles naturally from 425
   sources/7276 frozen bindings with Job-zero8.031431 seconds, native59 only
   app.so changed. Failed layout-to-paint fixture schedules remain rejected.
   Its sole newly admitted task-quiet plain run now completes twenty windows,
   retaining all 1174 frames/156 startup records and natural Job-zero8.025883
   seconds. Exact build/raster/total-span failures are 1/8/14, maxima
   23510/344067/482420us; startup failures1/5/7. This rejects the hitfix
   candidate under the original budget. No same-candidate measurement retry
   or product change is admitted. Prepare a separately reviewed observer with
   independent engine mapping identities and physical RIP/allocation-base/code
   witnesses. A bounded track-source hypothesis may undergo isolated exact
   pixels from retained op geometry/style, without unique widget or cost claims.
   All V1 sources, pixels, AOT and failed behavior evidence stay retained.
   New Python observers receive separate execution admission without changing
   any frozen compiler receipt. The sole combined plain runtime is consumed;
   all startup, navigation and between-window failures remain retained.
   An isolated one-line shader-draw AA candidate is rejected: all twenty RGBA pairs differ, totaling
   1025 changed bytes/432 pixels with maximum channel difference eight. Its
   original shader/clip/layer/shape inputs and both sixteen-control cohorts
   pass; no Profile or additional demand test runs after visual rejection.
2. Preserve the three original PlayerPage and four specific-card acceptance
   boundaries. The final family retains its original `mp4` candidate kind
   while actual HLS is decoded. Earlier decoder, VM observer and request-guard
   failures remain recorded; the fourth card uses exact input-bound reuse.
3. Preserve current production Release playing, original episode switching
   and pending-request Quit acceptance. Shared-QPC native tracing establishes
   this fresh pending lifecycle but contains no minimize event. Prepare a
   minimal calling-origin diagnostic under a separately bound task-only AOT.
   Its V3 staged source now passes seven direct-VM owned headless Jobs:
   187 worker and 67 independent checks qualify original once/Future/exception
   behavior and ready-callback LastError preservation. Explicit startup
   bootstrap records cold FFI side effects; the old lazy clock's cold failure
   remains rejected. Root rehashes 3064 inputs and admits build preparation
   only. The independent diagnostic AOT is now built. Its actual kernel
   compiler exits zero and naturally drains for 8.038322 seconds. The target
   stamp and input list bind 3488 unique inputs and one deduplicated app.dill.
   A separately admitted gen-only successor uses that kernel without repeating
   it or the constructor: exit zero, natural Job-zero for 8.030939 seconds.
   Root rehashes 15366 frozen inputs, validates the new ELF64 x64 snapshot
   ranges and every runtime file. The exact 59-file package changes only app.so;
   production AOT and 58 native/assets files remain preserved. The missing
   graph kernel failure and empty external-output-list postprocessing failure
   remain rejected. The single diagnostic GUI now observes bootstrap-ready
   exactly once and completes original Home/video/episode-two pending/Quit.
   Exit is zero without force, with 160 empty Job samples spanning 8.037827
   seconds. Root views five CRC-decoded screenshots and verifies changing
   native video pixels; independent release review passes 152 checks. Actual
   Dart callback and native minimize-entry counts are both zero, leaving the
   historical caller unresolved. The consumed GUI is not repeated merely to
   reproduce this zero-event result. Preserve every
   failed run and original method body. Never restore or suppress minimizing
   to make a visibility gate pass. Coordinate all diagnostic GUI windows with
   the performance branch.
4. Reconcile all original eighteen items and twelve additions with current
   owning-input bridges and scoped evidence. Reuse completed library/live,
   danmaku, source-selection and motion scenarios. Include new protocol,
   Release and performance outcomes without converting scope limits into passes.
   The current V20 matrix has thirty rows and 206 rehashed evidence reports;
   twenty-five altered matrix/scope controls fail. Selected-only software pixels,
   compiled Profile AOT and actual runtime qualify; its empty native-key census
   and original-budget performance are rejected. Combined V1 pixels and static
   AOT qualify, but changed hit semantics reject V1 behavior. The hitfix successor
   passes actual behavior/pixels/AOT and naturally completes its sole plain
   runtime, while the original budget is rejected. Actual diagnostic runtime and
   engine metadata capture qualify only in their stated scopes. Earlier controls and the pending
   run's eight negative controls remain retained.
   Its independent source binding rechecks 97 explicit files and rejects
   eleven scope/identity/progress/ownership/hash mutations. Current source
   PlayerPage, exact-card and Release playing/switch/pending scopes are closed.
   Current owning-input integration is accepted, including the two native
   logging components and separate Debug/Release library ownership. Reopen
   affected bindings after an admitted product renderer change. Performance
   under the original budget and the old minimize caller remain open.
   The track path passes 468 full-component pairs, 936 raw pixel comparisons
   and 468 encoded/decoded PNG comparisons with zero differences. Root rehashes
   4953 inputs with 29328 checks; only the row-local shape differs. Native
   outer/inner contains comparisons total 95040 per cohort at three scales.
   Old geometry/style does not prove a unique widget, current key effect or cost.
   Mapping coreV3 passes85 pure controls. AdapterV4 fixes shared-return readback
   drift in12 actual inherited-method fake cases; V3 failure remains preserved.
   Real suspended-thread Dr7 requests0/1/5/1024/1025/1029 read0/1/5/0/1/5.
   Dr7 zero clears all addresses; nonzero Dr7 keeps requested addresses, including
   a disabled slot. Root's incorrect individual-slot clearing assumption remains
   a failed review before the corrected548-check/313-input audit. Original and
   duplicate owned native handles pass exact PID/birth/Job controls. Finish the
   separately admitted single diagnostic on existing hitfix AOT for physical
   RIP/allocation-base/full568-byte Create code and nonempty saved-return inputs.
   Captured boundaries and complete mapping absence have separate gates.
   No track AOT, new formal budget or product renderer is admitted by preparation.
   The exact7376-input/19-module mapping preparation and prefix pass. Its single
   actual diagnostic is now consumed and rejected before Home readiness: the
   hardware stop records Dr7=1025 versus same-thread prior arm Dr7=1, with all
   four addresses identical. Root checks7640 predicates/7504 bound files and
   preserves the forced-cleanup failure, zero accepted calls/keys and no original
   twenty-window result. Full568-byte receipts belong to mapping-load stops34/37;
   the current entry buffer was not persisted before the guard rejected it.
   The transient second mapping loads37/unloads38. Neither product crash cause,
   current complete code witness, bounded absence nor key effect is established.
   A fresh stage-specific hardware-hit guard and saving evidence before validation
   now qualify with actual windowless native evidence and inherited controls. Every original
   address/global/RW/LEN/Dr6 check remains, and the consumed approval cannot be
   reused. Current PlayerPage/card/production Quit bridges remain accepted.
   The fresh successor preserves exact ARM readback, admits only the evidenced
   hardware-stop bit10 difference for masks1/4/5, and persists current-stop packets
   before guards. Native/core650/source362/inherited206 and exact7601-input
   preparation qualify. Its sole actual diagnostic naturally exits0 with160 empty
   Job samples across8.035059 seconds and completes all original20 windows.
   All36 entry/input/original saved-return pairs independently qualify: current
   entry568 bytes, current and originally saved return16 bytes, physical RIP,
   thread identity and mapping generation. Target key8F7A44 occurs once at call28.
   This run has one mapping; the prior transient second mapping remains specific
   to the failed predecessor. Root checks20896 predicates/8040 inputs, performance
   checks8806, and protocols checks4405/889 files. No unique widget, cost, key
   effect, complete absence or formal budget acceptance follows from this positive.
   A fresh one-source track AOT compile is separately approved, based on425 copied
   sources/8609 frozen inputs. Only the row source and package-config local URI
   remap differ; entry, shell, Home, Window and seven other metadata files retain
   their bytes. Runtime59 must retain58 shared files with only app.so changed.
   The sole compile subsequently naturally exits0 with dual empty8.0034857 seconds.
   Root9176/8675 and Release18114 reviews qualify425 sources/8609 frozen inputs
   and runtime59 with only app.so changed. The fresh untraced original20 is also
   consumed: natural exit0, dual empty8.0332484 seconds, all20 complete and1130
   delivered frames with178 startup records. Original build/raster/total-span
   failures2/73/164 and maxima26621/407274/572170 microseconds reject renderer
   adoption. Startup failures1/5/10 remain included; first heavy raster frames2/3
   are194268/407274 microseconds. Root8903/8709 checks recompute raw integer
   thresholds. No timing-difference cause or key effect is inferred. Reuse the
   qualified468 pixel/contains comparisons and unchanged functional owning inputs.
   Keep this candidate rejected, preserve all failed preparation/measurement
   predecessors and do not repeat the same candidate merely for better timing.
   Product renderer and whole-goal acceptance remain false.
   Next causal preparation compares the fresh track AOT's accepted key/GP/FP
   inputs with the old target28 CircleGeometryProcessor6/CircularRRectEffect7
   positive input. The sole fresh track native diagnostic now retains38 accepted
   Create/saved-return pairs and972 frames across original20 windows; the old
   target survives at call30 in one current engine mapping. Each568-byte entry
   and16-byte saved return passes Root's actual physical review. Natural exit0
   and dual-clock empty Job8 seconds qualify the session. This positive key
   comparison leaves unique widget, key effect and compilation cost unproved;
   formal performance still uses the rejected plain run.
   Loaded shader stroke/shadow/mask recipes remain unchanged by
   the single contour delta, while fallback/clip paths and contour construction
   are affected. Preserve cold20/startup/retirement/drain; infer neither widget
   identity nor cost from key presence or plain timing. Separately, historical
   v5's owned raw log retains move/top-resize/minimize append order compatible
   with source callbacks; it is a new clue, not historical caller attribution.
   V21 reconciles all30 requirements with231 rehashed reports and31 rejected
   scope mutations. Original performance and historical caller remain open;
   product renderer and whole-goal acceptance remain false.
   The completed74-key comparison qualifies35 shared canonical GP/FP inputs,
   three newly observed keys including Conic class26, and one old key not seen
   only in the new accepted set. Target old28/new30 stays byte equal. A distinct
   private child-clip candidate now changes two files: nullable childClipShape
   defaults to the original shape for shared callers; segmented row supplies
   the original native rounded child contour. The general outer contour,
   fallback and loaded shader remain unchanged. Root33 and Release selected
   reviews qualify source and a fresh AOT preparation plan, with new pixel,
   contains, widget-hit and semantics gates still pending before compilation.
   V22 reconciles30 requirements/242 rehashed reports and reuses the existing31
   scope rejection controls. New key presence does not establish widget or cost.
   Actual headless validation now rejects the unconditionally native child clip:
   all468 component images and10 boundary raster pairs are pixel equal, but
   native contains/actual clipper/direct RenderClipPath hit yield9 differences
   at40x40 and39.999x40 near the smallest positive float32 left-edge point.
   Default callers, global dispatch and semantics retain their bounded positives.
   The loader-only small-run failure and the actual behavior failure both retain
   natural exit1/dual empty8 seconds. No AOT compiler once is consumed. V23
   reconciles30 requirements/250 rehashed reports with the prior31 scope controls.
   A distinct guarded child clip is being prepared: preserve the general path
   for narrow/square logical or native bounds; return the original native Path
   only for strictly wide native bounds. Keep all failed points and add native
   size-rounding neighbors. Reuse468 only with its exact337x40 path proof.
   The guarded successor now passes actual precision qualification:12 new
   captures,36 actual branch receipts and4888 contains comparisons have zero
   differences, including all9 former failures and native size neighbors.
   The existing468 states are exact source/layout reuse, not fresh guarded
   executions. Its first fixture retains natural exit1 for SDK semantics
   cleanup; the cleanup-only successor naturally exits0 with dual empty8.
   Compiler invocation v1 fails before source materialization or once because
   its read helper receives a string path. A two-line successor canonicalizes
   that argument and binds the new packet without changing source or recipe.
   The first actual guarded AOT compiler then naturally exits0 with dual empty8;
   Root510 verifies425 source targets and runtime59, with only app.so changed.
   The complete startup/original20 plain measurement is next. No renderer,
   original performance budget or whole-goal acceptance is granted by compile.
   The sole guarded plain attempt is now consumed and fails Home readiness
   before any of the20 timed windows. All8 public-source section requests fail;
   Home has one group/eight sections but zero cards, while glass/demand resources
   are ready. Natural exit0/no force/dual empty8 qualify cleanup only.
   The356 stored status snapshots and357 startup-sample/2381-frame counts do not
   contain raw duration rows; original-budget counts cannot be reconstructed.
   The collector throws before its result fetch and its failure finally only
   fetches Quit. Preserve this failure and its missing-data limit. Separately
   repair failed-run raw persistence using the existing result extension and
   inspect the anonymous public source availability; do not lower readiness,
   alter the original workload or repeat this candidate just for timing.
   V25 reconciles30 requirements/294 rehashed evidence records with the prior31
   scope controls. Failed-run raw preservation is now source-qualified as nine
   added failure-only lines before Quit, using the existing failed-phase result
   extension. A completed headless fixture now executes the real nested RPC,
   extension and whole finally AST: seven branches and14 UTF-8 outputs pass,
   and the independent Release review passes36 checks. All1130 legacy frame
   dictionaries/timing receipts survive exactly; result precedes Quit and fetch
   failure preserves the primary error. The Python host naturally drains with
   both empty-Job clocks above8 seconds. No new native frames, exited failure
   recovery, source input restoration or original performance is qualified.
   The separate two-request anonymous transport check times out without response
   data. Its socket10s setting did not enforce a total10s request deadline; retain
   that protocol limitation instead of reporting source availability restored.
   The latest user clarification supersedes the earlier denial: manual
   minimization to the taskbar may have happened because the window stayed on
   top. The exact run/cause and native topmost flag remain unconfirmed. Manual,
   task/system and programmatic alternatives remain open without a link to the
   Home readiness failure; v5/v6 and old zero-event limits remain intact.
   V26 preserves30 requirements/308 records as historical predecessor. V27
   reconciles30 requirements/315 rehashed records with the latest clarification
   and actual targeted fixture review. Old task-private Home metadata has8
   sections/154 card positions,
   but no exact startup per-card or cover-byte binding; seeded disk restore
   changes cold startup and is not admitted. Source-only Windows GLPB feasibility
   identifies an invalid default disk-cache path and a possible three-file
   engine candidate. Real payload, exact ABI/caps/driver and runtime load/cost
   evidence remain absent; no engine or cache producer is implemented.

   V28 now reconciles30 requirements/337 rehashed records. Windows PiP recovery
   and immediate-call ordering are locally committed with53 headless tests and
   zero scoped analysis issues. The existing-mutex noactivation guard is also
   committed, with18 source-interpreted cases/198 assertions; native validation
   remains open after the retained failed compiler lifecycle. Fresh native/AOT,
   current Release playing/switch/pending Quit and final owning-input/smoke
   acceptance must be renewed for these changes. Previous protocol and cover
   evidence retains its exact scope. The selected Home source is bound to
   native Rust TVBox rather than JS. Eight generalized section error messages
   do not establish the underlying network/HTTP/parse/native error class.
   Transport proposals remain unapplied and have not restored original input.

   Current stability acceptance qualifies the normal production CADA AOT,
   19 LLVM native build stages and six guarded native successor stages, all
   with natural owned-process exit. The opt-in task window safety guard
   passes 189 headless behavior checks; its unguarded control fails 109.
   The SDK declaration collision in the first forced-include attempt remains
   failed; the repository-owned preloader successor preserves COM declarations.
   Six native objects and the resource are reused by exact input binding.
   The current 59-file short runtime passes playing, episode-two switching
   and pending-request original ask/Quit acceptance, independently reviewed.
   The first background visibility smoke failed its obsolete Cancel selector;
   its original-Quit cleanup passed natural dual-clock drain. The narrow Back
   helper successor passes six headless build/guard stages and the actual final
   smoke now passes all16 helpers, LAN preference1->0, both Back operations,
   unchanged order storage, exact module/runtime inputs and original ask/Quit.
   Main exit0 and empty-Job duration above8 seconds on both clocks pass without force.
   The limited current bridge binds21 Dart owners,4 native owners and runtime59;
   core/native reuse keeps its actual source lineage, without a single-commit
   package claim. V29 supersedes the stale current-state fields in V28 while
   retaining all337 historical evidence references through its sealed anchor.
   At this historical phase performance had been deferred; the later full-goal
   renewal supersedes that decision. It remains unaccepted and required by the
   active goal.

## Boundaries

### 2026-11-19 — seek Release same-package continuation

The current click fix has a naturally successful isolated `shell.dart` Release
assemble, with AOT `4B5B8A05...E170`. The exact compiler dependency census contains
3680 real files and one SDK wildcard sentinel; all 328 project inputs match the
current worktree. The 59-file staged runtime changes only `data/app.so` against
the accepted native/assets baseline. It is not a fresh single-commit native build.

All three same-package stability cases now naturally exit zero through original
ask/Quit with dual-clock empty Job durations above eight seconds. Final Home,
Settings, LAN disclosure, source management, sort Back and original ask/Quit
smoke also passes all 16 helpers. Receipt:
`.probe/seek-click-release-v1/CURRENT_RELEASE_STABILITY_AND_VISIBILITY_ACCEPTANCE_V1.json`.
Original minimized/forced-cleanup and selector failures remain failures. A
PerMonitorV2 helper manifest corrects mixed coordinate interpretation without
changing the qualified helper object or guards; successful GUI runs use 96 DPI,
so 125% DPI is not claimed as runtime-qualified.

Release single-click verification passes in v5 on that same production AOT:
one owned-window mouse down/up on the actually visible slider, no drag and no
slider accessibility action, advances isolated persisted playback32→93→98s.
The video burn-in reads00:01:38.917 in the final screenshot. Original ask/Quit
naturally exits zero, both empty-Job clocks exceed8s, no forced cleanup or log
exceptions. Continuous distinct hover messages expose the slider while the real
system cursor remains outside; engine TME_LEAVE/Add/hover deduplication explains
the earlier harness issue as a supported hypothesis, not a traced Leave claim.
v1-v4 stopped before any click and remain preserved failures. Receipt:
`.probe/seek-click-release-v1/CURRENT_RELEASE_CLICK_STABILITY_VISIBILITY_ACCEPTANCE_V2.json`.
The new local ZIP under `dist-deliver/sourin-windows-click-seek-20261119-4b5b8a05/`
is43,830,914bytes, SHA256`791F01507C28C19A4D166B7682BC9210E51C78E2BA2C9F28799510008F359175`;
all59 archive entries match runtime path/size/decompressed-content hashes, and328
project compiler inputs were reverified. No remote publication occurred. This
96DPI window-message acceptance does not claim physical-input or125%DPI testing.
The original anonymous performance category20 production-core request was
successfully retried in a fresh isolated profile using the existing
credential-free loopback proxy. The unmodified production core returned 14
items (13 covers) in 0.709 seconds; actual HTTP count was not instrumented and
compatibility fallback remained unchanged. The independent anonymous HTTP
transport proof returned 14 items (13 covers) in about 0.88 seconds. This is a
distinct proxy-route network cohort; it does not retroactively change the
failed direct-route attempts.

V32's preserved original20 Profile workload has now completed on that isolated
proxy-route cohort: all 20 windows, 1172 full frames, natural exit 0, no forced
cleanup, original Home readiness (8 sections, 154 cards, 20 stable visible
posters). Runtime qualification passed, but `performanceAccepted=false` and
`allFrameBudgetMet=false`; counts and exact retained frame windows are in the
current acceptance report. The workload ran but did not pass its frame budget.
The full 18+12 goal is active with no token budget cap.

Ordinary startup intentionally focuses its window, conflicting with the task's
no-focus restriction. Task-safe Release acceptance stays scoped accordingly.
Real cloud-account/cookie/transfer operations require separate external test
conditions; no real account or owner profile is used. Short upstream clips are
reported as short clips. No full-film-duration, physical-input or system-audio
requirement is invented. Blocked media probes remain explicit.

### 2026-11-19 — full-goal measurement and evidence-scope correction

The V32 isolated loopback-proxy run completed the unchanged original twenty
scenarios and retained all 1172 frame records, including the 206-frame cold
startup interval and frames outside timed windows. Strict 60 Hz results are
build/raster/total-span counts **1/7/14**, p95 **805/2,915/5,630 μs**, maxima
**35,998/346,368/530,909 μs**; budget is not accepted. No frames were
discarded to improve the result. The 20-window summary is in the acceptance
document and the raw run is
`.probe/perf-route-adapter-20261119-766ae2cfa4/circle-current-normal-full20-v32-loopback-v1/result.json`.
This proxy-route result is not directly comparable to the old direct-route
cohort without qualification. Continue with frame-level startup/first-navigation
causal classification before changing rendering code.

The old private-desktop initialization evidence was also found and rehashed:
all 27 declared fixture/evidence hashes match. It proves only the old native
fixture's private/default `NtGdiInit` contrast, not the current Release's
initialization failure or A11 ordinary launch. Current versus historical
binary identities and remaining boundaries are summarized in
`.probe/goal-remaining-review-20261119-c8a4e3/REMAINING_REVIEW.json`.

Independent preparations, source requests, builds and component tests run in
parallel under agreed task-owned resource limits. Actual Profile measurements
reserve a quiet exclusive window. Successors use new run directories. Reusable
evidence is bridged by owning inputs rather than rerunning unrelated successes.

### 2026-11-19 — actual GLPB material and corrected frame attribution

The full18+12 goal remains active without a token budget cap (`remainingTokens=null`).
Current delivery and seek same-package receipts are unchanged. V6 completes the
original20 diagnostic and retains967 frames,39 distinct genuine GLPB key/payload
pairs and39 physically guarded saved returns, with natural exit0 and no force.
The independent952-check/182-input review is
`.probe/perf-frame-audit-20261119-d81ef6c9/GLPB_V6_INDEPENDENT_MATERIAL_REVIEW_V1.json`.
Its original mapping coverage false remains: the missing arm witness belongs to a
thread registered during post-original20 retirement. A nine-case pure successor
fixture corrects that ordering, without promoting old coverage or executing a
new native run. No consumer hit, complete driver fingerprint, visual equivalence
or performance acceptance follows. Earlier failures and the unexplained V4
abort trigger remain preserved.

The fresh V34 task-only trace entry leaves product source and original20 intact.
Its1103 raw frames and90 chunks bind uniquely by actual rasterizer frame_number;
natural exit0/no force qualify lifecycle, not performance. The initial root
set-deduplicating analysis wrongly removed genuine same-tick repetitions and is
not used. Multiplicity-preserving independent parsers and5851 cross-checks now
agree; only four noncritical trace-boundary B/E edges remain incomplete.
Frame4 raster465049us contains shader union457369us and nested driver-link
union424233us. Frame43 build27594us contains LAYOUT27052us with nested
BUILD18293us. Do not add nested scopes or transfer traced durations into V32.
First Search's two earlier MakeGpuImage spans1133/329us do not explain its
shader-heavy raster; retain SnapshotWidget and all visual behavior.
Reference: `.probe/perf-frame-audit-20261119-d81ef6c9/V34_INDEPENDENT_REPORT_CROSSCHECK_V1.json`.
The next independent task-only build/layout-scoped diagnostic identifies concrete
widget work; it is not the subsequent required untraced full-budget acceptance.

### 2026-11-19: actual allocation candidate and collector race recovery

V36 completed original20 with1081 frames/94 chunks. Two independent widget scope
analyses agree in1316 additional cross-checks. Frame41 exclusive RenderParagraph
6556us/Image5110us/Scavenge1870us support local work, not a HomePage rewrite;
HomePage itself is34us. Traced values remain diagnostic only.

Two actual production optimizations are now bound into fresh pp38: optional
press feedback controllers allocate lazily (ordinary4→1), and fixed-URL cover
headers/hash are reused.57 related tests plus final6 lifecycle cases pass;
23 before/after PNG pairs match. Conditional InkWell wrappers were withdrawn
after live callback-transition review; original interaction tree remains.

V38 compiled successfully but its runtime pre-start signature guard rejected
late card work (settled20→19,dirty2→1).0 windows/37 raw frames retained;
natural exit0/no force/dual empty Job>8s do not qualify this failed measurement.
Failure receipts remain under perf-allocation-current-20261119-v1.

Fresh pp39 changes only the task collector's start handling to bounded recorded
reobservation, with stricter all-visible/clean readiness and unchanged signature
comparison. Original20 actions/windows/budget and every startup/outside raw frame
remain; no buffer reset, warmup or failed-run deletion. The successor actually
completed20 windows/1009 frames, runtimeQualified=true, natural exit0/no force
and dual empty Job>8s. Exact build/raster/totalSpan violations2/29/66,
max52898/744768/1053517us and p951476/9235/23429us still fail the budget.
All19 startup/239 outside/585 navigation/42 setup/124 scroll frames remain.
There was one pre-start check and no retry, so the retry branch is not dynamically
qualified. The90s loop-entry limit is not a strict total wall-clock cap including
individual30s drains; final snapshot was not saved, only its equality result.
Root and independent raw-frame/collector-delta audits agree. See
`.probe/perf-product-candidate-20261119-root-v1/V39_UNTRACED_ALL_RAW_FRAME_AUDIT_V1.json`
and `.probe/perf-frame-audit-20261119-d81ef6c9/V39_INDEPENDENT_RAW_FRAMES_AND_COLLECTOR_DELTA_V1.json`.
Do not infer candidate-caused regression from cross-run timing or rerun unchanged
inputs merely to select favorable numbers.

GLPB static v4 resolves four native vtable slots by matching PE/PDB symbols,
including the base description-store overload. No consumer installed/hit,
actual context fingerprint or untraced performance acceptance follows.
Original18+12 remains active without a token-budget limit.

The standalone GLPB payload validator now compiles with MSVC /W4 /WX and accepts
all39 actual key entries (37 distinct complete payloads), rejecting702 malformed
adaptations. Overlay-v3 places validation before returning cached SkData, but
is still an unbuilt engine proposal. Bounded manifest registration and an actual
context fingerprint remain necessary; no consumer hit/performance claim follows.
Root is preparing an isolated checkout at the SDK-pinned engine revision rather
than modifying the shared SDK or assuming an application-side ANGLE DLL replaces
the engine's statically linked ANGLE.

V40 continuation: poster-image configuration reuse was compiled into the fixed
Profile runtime and the unchanged original20 workload completed twice under
separate launch receipts. Both runs retained every raw frame and naturally
qualified lifecycle, but both failed the strict all-frame 60 Hz budget. Keep the
two receipts separate; do not choose the better sample as a performance pass.

### 2026-11-19 — Top 20 exact-cover continuation

Read-only review of the existing isolated projection confirms the candidate uses
cloud detail, while its configured aggregate child is disabled and unselected.
The exact identity appears once in progress and once in history, with no nonempty
cover donor; the projection database hash is unchanged. Static source review
finds no exact identity bridge from this detail branch to a recommendation/share
poster. No real database, credentials, application, or network request was used.
Keep the Top 20 cover unresolved; the next prerequisite is a verifiable exact
share/response identity mapping, followed by isolated image-decode and
non-cover-field-preservation checks. Receipts are recorded in
`FINAL_ACCEPTANCE_20261118.md` and `.probe/remaining-cover-20261118-top20-v1/`.

### 2026-11-19 — linked engine and actual V41 causal diagnostic

The GLPB-specific pinned engine now completes `windows gen_snapshot` compilation
and final linkage with natural exit0. The first failed include-layout attempt is
retained; its successor changes only the generated identity header include.
Receipt: `.probe/engine-build-pinned-20261119-v1/ninja-glpb-windows-result-v2.json`.
The DLL still has compile-only identity, not qualified closure, real GL capture,
consumer hit, driver acceptance, visual or performance acceptance. Complete the
bounded Windows producer wiring and independently bind the real build-input
closure before any same-DLL capture/consume qualification.

Fresh V41 keeps V40's product inputs and original20 workload, adding only the
task entry's exact trace flags and build/layout timeline scopes. Both Profile
compiler stages naturally exit0, with no force and dual empty-Job clocks over8s.
Root reads back3485 observed kernel inputs and all59 staged runtime files; only
app.so differs from V40. In a reserved quiet window the actual workload completes
20windows,1031raw frames and90trace chunks, then original ask/Quit naturally exits0
and drains over8s. Tracing adds overhead: strict counts6/21/50 are diagnostic,
not a performance pass or a causal comparison with another run. The same-run
frame-number-to-scope analysis now binds all1031 actual draw frame numbers.
Separate widget/raster and raw-only reports pass5192 cross-checks, including653
common named-scope interval unions. Frame3 raster881912us contains shader867856us
and nested driver-link792494us. Frame64 build106530us includes RenderParagraph
exclusive44371us, Image12450us and Scavenge7044us. These instrumented scopes are
diagnostic, not pure CPU or transferable V40 timings. Continue real-cache wiring
and scoped offscreen-build experiments without removing visible UI or weakening
focus/semantics; retain every raw frame and all failures.
See `.probe/pp41/ROOT_STATIC_BUILD_AUDIT_V41.json` and
`.probe/perf-layout-trace-current-20261119-v41/ROOT_RAW_TIMING_AUDIT_V41.json`.
The original18+12 goal remains active without a token-budget cap.

### 2026-11-19 — reviewed capture/observer and task-runner bridge

Root independently rehashed all17 candidate baselines/results, the handoff
references and22 test logs, then repeated the read-only apply-check. The fixed
capture/driver-observer successor patch is `8DC7D453…2BD96`; its7 pinned-header
compiles,2 actual-GN syntax checks,375 Windows-IO/decoder checks and52 synthetic
correlation checks are scoped evidence, not actual GL or driver acceptance.
Review: `.probe/glpb-runtime-harness-20261119-v1/ROOT_CAPTURE_OBSERVATION_COMPILE_ONLY_REVIEW_V1.json`.
Only isolated compile-only integration/build is authorized. Preserve the false
identity, collect a fresh final-source closure, independently review the
noncircular identity and verify post-relink invariance before runtime use.

The isolated task C-ABI bridge compiles under `/W4 /WX` against the candidate's
real public header and passes104 fake-engine-API checks. It is explicit/default
off, requires consumer plus observer configuration, propagates terminal setup
failure, and records failed/unreadable stats without retrying Finish to green.
A private mutation removing the one-shot Finish guard fails check18 while the
original helper hash remains unchanged. These tests are not native-engine
execution; actual task-wrapper/platform-channel wiring remains next. Initial
stdout-encoding failure is retained in fixture-v1, with successful successor in
fixture-v2 and the deliberate red control in rollback-negative-v1.

The reviewed17-file successor has subsequently been applied once to the
isolated engine with exact after-byte verification; the false identity and
args bytes remain unchanged. GN regeneration naturally exits0. Actual Ninja
`windows gen_snapshot -j6` starts at2026-11-19 19:51:15+08:00 and root reads
back its live log/PID. Keep this in-progress build separate from the previous
DLL's successful link; no final-link or runtime acceptance exists yet for this
integration. Receipts: `engine-build-pinned-20261119-v1/integration-full-v3-v1/`.

The same Ninja PID64140 then reaches599/599 and naturally exits0 at
2026-11-19 19:58:48+08:00. New compile-only DLL `AF089762…CC652` exports all6
GLPB C APIs and3 existing runner bridge names, each once. Root independently
rehashes32901 final-candidate materials, matches4944 compile dependency blocks,
checks39 directory member sets and verifies header-derived outputs do not
reenter the canonical material set. `ROOT_FULL_V3_FINITE_CLOSURE_REVIEW_V1.json`
is a finite material-boundary audit, not hermeticity, final relink or GL proof.
Capture and consume must share exact DLL **and AOT**; do not compile capture vs.
consume mode into Dart defines that change app.so.

Home viewport trials concluded: wide36 mounted/20 visible becomes33/20 for
horizontal168, but it loses an actually decoded cover at first mouse reveal.
Zero horizontal breaks real direction-key traversal; zero vertical alone does
not reduce wide mounts. No candidate adopted. Keep the behavior and failed
receipts; `home-cache-extent-20261119-v1/HOME_CACHE_EXTENT_BOUNDARY_EXPERIMENT_V1.json`
is component evidence, not an application budget pass.

### Current takeover — 2026-11-20

[FINAL_ACCEPTANCE_20261118.md](FINAL_ACCEPTANCE_20261118.md) owns the acceptance matrix and exact receipts.
The original 18+12 goal remains active. Keep the completed seek fix and its separately bound Release ZIP;
do not rerun seek, static closure, AOT, or any already-qualified capture/consume pair without changed owning inputs.

The original task DLL and AOT have nine verified correlated driver accepts. The changed
[stable caps fingerprint](.agents/notes/implemented/architecture/2026-11-20-stable-program-binary-caps-fingerprint.md)
now has its own qualified private DLL `064F25F4…FCD4F35` with the same AOT `8E68C741…0331A`:
39 fresh captured descriptors, 38 unique payloads, and 39/39 actual driver accepts without rejection or fallback.
This does not identify every old rejection, install a production engine, or qualify other contexts/drivers.
Two stored screenshots match in this pair; they do not establish whole-run equivalence.
The [decode observation component](.agents/notes/implemented/testing/2026-11-20-poster-decode-observation.md)
has a separate real component test; geometry-settled remains geometry-only in the unchanged AOT.

The saved pre-Quit consumer frames still fail the original strict budget (1120 frames, 1/10/14 excess
for build/raster/total span); 11 of its 14 total-span excesses are in startup. No already-failed
unchanged sample is rerun to select timing. Further performance work must isolate remaining work
on the changed owner and preserve cold, in-window and outside-window frames and original actions.
A separate startup-only read of the default VM ring on the identical package now binds all
40 initial saved frames (42 covered in the ring); 35/35 startup requests are accepted. Its
frame 3 spends 225520 of 232241 raster microseconds in the union of program creation and
compositor presentation. Frame 12 waits behind the prior draw; neither event is an exclusive
driver-call timing. This is diagnostic, not a new full20 attempt or performance acceptance.

Independent surfaceless native API probes now qualify 39 actual original binaries; serial binary/status
calls total 2421.2/137630.2 microseconds. One fixed-batch4 successor also accepts all 39; its submit/join
union is 111296.7 microseconds. These are separate diagnostics, not application frames or controlled
performance improvement. The old serial and startup workload are not rerun. The old 61346-microsecond present envelope remains coarse; a changed private trace DLL now
adds five exclusive present CPU scopes. Its new startup capture35/consumer35 actual driver accepts
share the original AOT. Capture106 raw frames have full phase coverage; consumer84 raw frames have
44 complete phase frames and40 timing-only, with a partial tail draw70 explicitly retained.
Consumer frame2 present80289us includes SwapBuffers70605; frame3 present49390 includes SwapBuffers49315.
This still is not DXGI/GPU/VSync attribution or performance acceptance. No full20/old sample is rerun.
The new real Reader24 and separate COM7 probes locate D3D CheckInterfaceSupport and caps dump cost;
no live driver-version/caps cache is admitted. Actual35-material embedded DXBC repetition only justifies
a private same-device exact-byte shader-object reuse candidate. Its real-D3D19 controls and
full-key fault-red are qualified. New private shader DLLBBC682…CCA9F0 startup35 capture naturally
exits but has no hit witness because Renderer teardown logging was bypassed; keep that consumed run.
A changed default-off bounded immediate observer DLL09C388…495A43 now has actual first-store and
first-hit labels in both capture/consume, same original AOT. New capture35/33blobs and read-only
consumer36loads/35correlated driver accepts/1reject/0fallback qualify only those scopes. Capture95raw
includes46complete phase frames and49timing-only; consume97raw has97complete phases. Budgets remain
red (1/6/11 and1/9/11); no original20 retry or production renderer admission. Root and source inverse
receipts are under round7/lead, new runtime under shader-observed-runtime. Current local Release ZIP
is not changed or requalified by this private candidate.
Task53 was unqualified at its original stop; retain failed drafts and stop receipt. A later bounded
readback observed-pair-review-v2.json now checks actual ready/quit/log references and counters; it
still uses the root identity bridge and is not an independent full frame attribution or performance pass.
Real GPU artificial-shader opaque/alpha pairs also match32768 bytes; changing candidate red tint on
GPU produces1152 differing bytes and natural red1 before original-state green0. This is bounded pixel
evidence, not full product/debug-label equivalence. Owner's local checkpoint commits are complete
(43cfb07/22b9846/71fba84/f440d68). The no-added-trace private DLL is now
`C65C5AD538301D0F45586391663CED3D660C16A2205EBEBE4EA73608570773CB`, derived closure
`7FA1F59A40EE667ADDD9C78041F2472F6D9DEE8D19A9C068C61421F72DB12587`; one identity TU and
link qualified 3535 reused objects/246 actual includes without SDK/OUT mutation, not fresh full-source.
第9轮两次start前失败（尺寸界26raw、八区块失败551raw）及curl/Schannel TLS失败保持未资格。
第10轮同产品core的匿名文本接口一次HTTP200（14项/13非空封面）提供新的有限路由证据；
不解释旧失败共同根因，不读取真实账号/凭据。私有main首显前主屏守卫真隐窗红1/绿0已验证，
随后修订为编译宏+原合法SOURIN_TASK_NO_ACTIVATE，原AOT不改。初版多传PRIMARY环境hook
导致Dart入口异常、Quit未注册和强制清理，保留失败；静态环境门现能拒绝同非法注入。

修订main对象401239C3…6098 + 同C65DLL/AOT，两臂各一次实际完成原20动作和700ms窗口，
当前主屏ready1592×904/DPR1、8区块154卡片，各18实际加载包映像匹配；原Quit自然0/无force、
双空≥8秒。capture原decoder验证39descriptor/38blob/506424B，manifest
`3156F44CCCA7D1E17515ED90C7573E0B398716FDBFB3692C63F2E0452EB7EB18`；
consumer98文件材料只读，41load/39driver accepted/2reject/0fallback，同nonce关联，消费后原件及
39文件副本hash未变。不要把2reject隐藏或从计数推原因。消费者预检59固定值错误在GUI前已拒绝，
仅修读侧成员门并用缺材料/多成员负控验证，原AOT和capture不重跑。

capture830preQuit含18尾帧，consumer925含17尾帧，原严格全帧预算仍红：7/156/301与8/150/263。
consumer最大build/raster/total52550/372920/690855μs；冷115帧、窗外199帧不删。
root亲查capture首页占位/consumer有图，设置末图同hash，不证明全程像素等价或因果提速。
采样状态非连续历史，也不归因Owner/历史caller；原helper静态false不转绿。
根原件 `sourin-performance-20261120-round10/lead/ROUND10_PRIMARY_FULL20_PAIR_ROOT_READBACK_V1.json`
SHA9554E764…46F55D。当前pair已完成且预算失败，禁止重播挑成绩；继续需明确受影响owning input
和新的可证成本，不重做旧seek/API/像素/已资格构建。私有main/GLPB均未生产采用或安装。

The latest product source is compiled into Release AOT `58131BEB…CA9361E`, with all 3483 actual
kernel inputs matched. Asset checks qualify reuse of 58 non-AOT files (including actual rebuilt
font equality). New candidate runtime59 manifest `B8C63848…61D1E20` is staged in round6
`release-candidate-v1`, but old three-exit/16-action/ZIP receipts do not transfer. Fresh owned
exit/cover wiring is independent of the completed seek. New playing/switch/pending cases now all
exit naturally on this exact package with 18 matching loaded images and dual empty Job ≥8 seconds.
The original 16-action smoke also naturally passes on this package. A separate real HTTP+visible
cover run matches 9/9 tiles and 225/225 pixels and exits naturally. Local candidate ZIP43,831,371 bytes
`FBBFFD3B…6237F13` has all59 entries/content/CRC verified in `release-local-package-v1`.
This is current-source local package-phase acceptance, not formal release or the whole goal.

Owner's concurrency requirement is retained in goal rev10 (introduced in rev9): keep independent substantive agents active, with
disjoint writes and root review. Only dependent steps or the owned measurement/GUI window are serial.
Do not repeatedly poll/re-audit when a concrete source or executable boundary can be advanced.

Ordinary unmodified startup/exit, Top 20 exact cover, real-account external-chain acceptance,
historical minimize attribution and formal full-goal delivery remain open. The latest-source local
package binding is now qualified only for the explicit synthetic/noactivate scope above.

### 2026-11-20 — Round 11 remaining gates and formal performance boundary

The four bounded read-only reviews in round11 are now root-read and hash-bound.
Top20 exact share to canonical response to poster bytes remains false: donor=0, empty cover 2→2, disabled child remains disabled, and current real DB/config state is unknown. Ordinary unmodified startup is BLOCKED_NOT_ACCEPTED because no separate authorized interactive session or VM was supplied; a passive session-1 metadata sample is not authorization and task NO_ACTIVATE cannot substitute. Historical native minimize events are directly observed, but initiating caller and historical cause remain unknown.
The new GLPB-off path is now executed once, with exact new AOT85BCA990…DA7E9, native-off EXE437813E1…46D1B1 and unchanged DLL09B0BCCB…926648/main/core/assets. Original20 completes, pre-Quit1096 raw frames include20 extra tail records, original Quit naturally exits0/noForce/dualempty8.0651/8.0664 seconds. Strict build/raster/total exceed3/12/26; max47640/704219/999204us, p95=985/4570/10584us. All cold20, timed792, outside284 frames remain. Root views Home mixed decoded posters/placeholders and visible Settings, not pixel equivalence. FrameTiming stays for measurement, GLPB Dart channel/receipts removed and native config off; no runtime GLPB invocation-count claim. rootBundle import compile1 and loader-closure error predecessors retained; corrected fresh AOT and read-side gates pass, actual raw mutations reject. The sample is consumed: no replay to select timing. Whole18+12 remains active; seek/Release unchanged.
Receipts: sourin-performance-20261120-round11/top20-review/task-70-top20-exact-review-v1.json; ordinary-startup-review/ORDINARY_STARTUP_READ_ONLY_REVIEW_V1.json; minimize-caller-review/MINIMIZE_CALLER_BOUNDARY_REVIEW_V1.json; perf-formal-review/ROUND11_FORMAL_PERFORMANCE_PREAUDIT_V1.json.
