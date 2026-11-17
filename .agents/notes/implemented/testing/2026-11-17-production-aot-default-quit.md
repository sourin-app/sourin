# Agent Note: Production AOT default Quit under isolated native diagnostics

Status: implemented

Related: [Current UI default close verification](2026-11-16-current-ui-default-close.md)
and [task-only nonactivating window show](../bug-fix/2026-11-16-task-noactivate-window-show.md).
Their diagnostic-entry and startup scopes remain separate. This note qualifies
the normal production Dart entry with task-private native components.

## Problem

An earlier Debug callback run does not establish that final production Release
AOT reaches the original close dialog. Untagged hide messages cannot identify
the main or shadow window. A minimized window fails the visible-dialog gate,
and restoring it can activate the desktop window.

## Decision

Use the final Release `lib/shell.dart` AOT without a Dart test entry or service
extension. Keep 57 runtime files byte for byte. Rebuild only the qualified
task-isolated runner and window-manager library with owned HWND, PID, class,
placement, system-command and minimize-entry logging. Retain nonactivation and
private profile guards. Never restore a minimized window. Validate invalid
flags, namespaces, profile roots and reparse ancestors before the accepted run.

After Home settles, require a complete visible window for at least five
seconds. Capture Home, request its original close dialog, read the real
accessibility tree, capture the dialog and invoke its original Quit semantic
action. Require saved quit preference, normal exit, exact window removal and
eight seconds of naturally empty owned Job membership. Reuse the qualified
accessibility helper and its inert guard controls. With a task-only media
fixture, also invoke the original Home card and original episode control.
Require changing pixels inside the native video rectangle, selected episode
and source requests, five-second visible scenes, and the original ask/Quit.
Use the actual accessibility parent/child tree: an episode's labelled text
anchors its direct button parent. Source-level button flags do not establish
the emitted accessibility role or action target.

For a request that must remain waiting through Quit, qualify each helper's
primary exit and ownership before proceeding, while independent owned threads
observe its eight-second empty Job concurrently. Gather every observer receipt
before accepting the run. Keep the native timeout and all five-second visible
scenes. Require the loaded-module plan's complete actual path/hash set at its
original sampling point; a failure before sampling retains executed=false.

Independently rehash build inputs, loaded modules, runtime files, screenshots
and raw receipts. Bind accepted Debug observations to their own package,
without transferring UI or active-player acceptance to Release. Reject forged
AOT, core, decoder, package, minimized-window, forced-exit and scope evidence.

## Alternatives considered

- Debug callbacks exercise widgets but do not run production AOT.
- Removing stability or visible-window gates hides observed failures.
- Restoring a minimized window triggers the foreground guard in a retained failure.
- Untagged hide messages cannot identify the hidden owned window.

## Consequences

Production input `6bb7e49` retains AOT SHA256
`B308E2D6494E75AE1ECA81E94E094266FE2459B0D098CF33D3228D9A2D853029`.
The window remains visible for 5.054454 seconds after settling. Two 1280x800
screenshots show the complete shell and original three-choice dialog. Original
Quit exits zero, saves quit and leaves the Job naturally empty for 8.041078
seconds without force, accessibility errors or overflow. All ten hide records
belong to the owned shadow; main-window minimize observations are zero.

The affected-input audit rechecks 3605 live and frozen Release inputs, 35
compiled assets, 269 core inputs and every runtime file. It revalidates four
Debug scenes with 3677 inputs and 416 product-parity rows. Twelve altered
controls fail. Evidence is retained in
`.probe/release-parallel-20261117/CURRENT_FINAL_AOT_DEFAULT_ASK_QUIT_DIAGNOSTIC_AUDITED_V1.json`
and `CURRENT_AFFECTED_INPUT_PACKAGE_REUSE_AUDITED_V1.json` in that directory.

The idle scene settles to a network error and has no active player; it does
not establish content. Two additional production-AOT scenes qualify the
task-only two-episode video fixture. Original card playback produces a
960x540 first frame and 33271 changing pixels inside a 300000-pixel video
rectangle. Home and Player stay visible for 5.095417 and 5.054515 seconds;
original ask/Quit exits zero with natural Job zero for 8.033101 seconds.

Original Episode Two uses the labelled text's direct button parent, with
identical bounds and adjacent depths. The actual second source request and
production current-episode notification agree; both episodes produce native
frames. Their respective video pairs change 36333 and 43204 pixels, and the
second episode stays visible for 5.054110 seconds. Original ask/Quit exits
zero with natural Job zero for 8.036261 seconds. Both scenes retain all 59
runtime files, unchanged production AOT, no Dart test entry and no physical
input. Independent audits reject four altered controls per scene.

Retained evidence is in
`.probe/goal-root-acceptance-next-20261117/CURRENT_RELEASE_ACTIVE_PLAYER_INDEPENDENT_AUDIT_V2.json`
and `CURRENT_RELEASE_EPISODE_SWITCH_INDEPENDENT_AUDIT_V1.json` there.
Pending-request Quit requires the native request still to be pending when
Quit is invoked. A held server body alone cannot establish that condition
after the native player has timed out. The retained initial run fails that
condition. Two subsequent pending runs fail the unchanged visible-window
gate. Both retain a native `minimize` method entry, plugin call on the actual
main window, `SC_MINIMIZE`, then `SIZE_MINIMIZED` with iconic state. Their hide
records belong to the shadow. The first run has only a read-tree helper and
fails before its original card action; the second invokes the original
Episode Two parent button and its helper drains naturally for 8.041545 seconds.
The application's forced cleanup in these failed runs is not natural Quit.

The independent audit rechecks 39 original inputs and frozen copies and
rejects ten altered controls. Native logs establish the main-window minimize
chain but lack a common clock and calling Dart origin. The source title-bar
callback is a candidate, not an attributed cause. Preserve production AOT for
minimal native/helper QPC diagnostics; a Dart calling-stack diagnostic would
require a separately bound AOT and cannot retain this production-AOT claim.
Evidence is in
`.probe/goal-root-acceptance-next-20261117/visibility-review-v1/INDEPENDENT_VISIBILITY_ATTRIBUTION_AUDIT_V1.json`.
Ordinary foreground startup and performance remain unqualified. Earlier
minimized-window and foreground-guard failures remain failed.

A fresh targeted production-AOT run qualifies original pending ask/Quit with
the shared-QPC native pair. All 57 retained runtime files include production
AOT; only the runner and window-manager logging components change. Home,
original first-episode video and pending scenes stay visible for 5.068432,
5.057103 and 5.061644 seconds. Two empty pending transfers have no native
failure or second first frame before Quit; the oldest is 9.154535 seconds old
at the pre-Quit observation, within the unchanged 10.33-second timeout.
Original Quit exits zero, removes the exact window and retains 160 naturally
empty Job samples spanning 8.040445 seconds without force.

All seven helpers qualify naturally, including four concurrently observed
eight-second drains. The complete fourteen-module plan executes with actual
paths and hashes. Independent root verification rehashes 113 explicit inputs,
CRC-decodes and views all five screenshots, verifies changing native video
inside its video-only rectangle and rejects eight altered controls. Evidence
is in
`.probe/goal-root-acceptance-next-20261117/CURRENT_RELEASE_PENDING_ORIGINAL_QUIT_ROOT_AUDIT_V1.json`.
The release branch independently validates native/helper QPC, lifecycle and
screenshots. This accepts the one pending lifecycle; no minimize event occurs
in this run, so the older calling origin and root cause remain unresolved.

A separately staged V3 Dart calling-origin recorder now passes seven direct-VM
owned headless Jobs, each exiting zero and naturally empty for at least eight
seconds. Its explicit bootstrap runs immediately after binding initialization;
cold FFI LastError effects are recorded there. Business callbacks use only a
ready prebound clock. Diagnostic entry/exit work preserves LastError, while
the original callback runs synchronously once and preserves its exact Future
or thrown exception. Missing, failed, disabled or wrong-environment bootstrap
retains original callback behavior. The original lazy clock's two cold failures
remain rejected even though its warm samples passed.

The seven Jobs cover static ownership, fake contracts, the real ready QPC,
bootstrap failure, missing bootstrap, wrong environment and the disabled
compile flag. They retain 187 worker checks, 67 independent checks and 22
durable real-QPC events. Root rehashes 3064 inputs, including the full staged
source and four reversible AST additions, and admits build preparation only.
One redundant non-null assertion warning remains in the staged recorder.
The independently bound diagnostic AOT cannot reuse unchanged-production-AOT
acceptance. No actual minimize or old
calling origin is attributed by headless qualification. Root evidence is
`MINIMIZE_V3_SOURCE_HEADLESS_ROOT_AUDIT_V1.json` under
`.probe/goal-root-acceptance-next-20261117/`.

The independently staged diagnostic AOT is now generated. The first kernel
attempt fails because the current SDK also requires package_graph.json.
Its successor copies the exact paired graph: 117 package identities, all 116
dependency versions from the frozen lockfile and the original root version.
The kernel compiler exits zero with natural Job-zero for 8.038322 seconds.
Its external output list is empty because app.dill is a target-internal output;
that postprocessing failure remains failed. The actual target stamp and input
list jointly bind 3488 unique inputs, including one newly generated source,
and exactly one deduplicated 63044896-byte kernel output.

A separately admitted gen-only successor consumes that exact kernel without
repeating the kernel or constructor. It exits zero and retains 160 naturally
empty Job samples spanning 8.0309392 seconds without force. The diagnostic AOT
SHA256 is `11E01ABB77D1D12FB34E91E2382905FF16C3203C8DC5679EBB3BCE496BF98336`.
Root rehashes 15366 frozen inputs and all 59 runtime files; only app.so changes
from the qualified native package. ELF64 little-endian x64 headers and the
three current snapshot symbols have exact section/PT_LOAD mappings. Diagnostic
bootstrap and callback markers exist in the new AOT and are absent in the old
production AOT. This establishes code presence, not runtime initialization.
The root receipt is `MINIMIZE_V3_ACTUAL_AOT_AND_STATIC_PACKAGE_ROOT_AUDIT_V1.json`
in the same root evidence directory. The separately bound single diagnostic
GUI now observes exactly one bootstrap-ready event and completes the original
Home, first video, episode-two pending and Quit lifecycle. The process exits
zero without force and retains 160 empty owned-Job samples spanning 8.0378271
seconds. All 59 runtime files and 685 frozen plan inputs remain unchanged;
18 loaded package modules bind to the package. Root CRC-decodes and views all
five screenshots, including changing pixels inside the video-only interior.
Independent release review passes 152 checks over the original nine natural
Jobs and retained lifecycle evidence. A parser predecessor incorrectly uses
Boolean identity for actual Win32 integer success fields; that failed parser
and its corrected successor remain retained.

Actual Dart minimize-callback and native method-entry counts are both zero.
This qualifies the diagnostic bootstrap and one pending lifecycle, leaving
the historical caller unattributed. The zero-event successor cannot explain
the older retained native minimize events. Read-only helper audit finds no
proven titlebar misrouting or system-input injection; callback keyboard/focus
reachability is a source candidate without historical input or Dart evidence.
The sole consumed GUI is not repeated. Root runtime evidence is
`MINIMIZE_V3_SINGLE_GUI_RUNTIME_ROOT_AUDIT_V1.json` in the same directory.
Original production lifecycle acceptance stays scoped to its own AOT.

The parallel renderer branch now records the selected-only actual runtime as
qualified but rejects its empty native census and original all-frame budget.
A combined three-source Profile AOT is also compiled in isolation; changed
window/shimmer hit semantics hold that V1 before plain execution while a private
behavior-preserving successor is prepared. None of these diagnostic/Profile
packages replaces the accepted production AOT or reopens unrelated lifecycle
scenarios. The hitfix successor passes actual dynamic hit/pixel parity,
full24/72/20 pixels and its own source-to-Profile-AOT bridge. Its sole quiet
plain runtime naturally completes all twenty windows and retains1174 frames/
156 startup records, but original-budget build/raster/total-span failures1/8/14
reject renderer admission. The V15 thirty-row matrix rehashes128 reports and
rejects twenty-one scope mutations; performance and the old minimize caller
remain open. Rebind
affected functional owning inputs only after a renderer is admitted to product.
