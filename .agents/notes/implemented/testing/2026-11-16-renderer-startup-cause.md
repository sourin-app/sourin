# Agent Note: Renderer startup cause verification

Status: implemented

Related: [Current UI and default close callback verification](2026-11-16-current-ui-default-close.md).
The separate [shader quad AA rejection](../../rejected/architecture/2026-11-17-shader-quad-aa.md)
retains this diagnostic boundary and the exact appearance contract.

## Problem

Surface asset loading and shadow variants improved peaks but left performance over budget. FrameTiming identifies the long frame without identifying the work inside it. Repeating those variants cannot distinguish shader compilation, driver linking or widget work.

## Decision

Keep the untraced acceptance baseline unchanged. Parse every retained frame and separate startup localization from the acceptance calculation without removing startup frames. Build a distinct task-only Profile entry that permits exactly the engine startup-tracing switch, validates its namespace and isolated directories, and retains the default renderer and owned nonactivation.

Run the same populated source-posters workload with the accepted packaged core. Retain startup timeline chunks and frame timings, then independently match Begin/End events by process, thread, category and name. Bind the Rasterizer frame number and time interval to FrameTiming. Measure interval unions for shader compilation, cache misses, driver compilation and program linking; these scopes are nested and must not be added together.

## Alternatives considered

- Tracing the acceptance cohort directly: its explicit no-engine-switch contract rejects that.
- Guessing the cause from a large raster duration: insufficient to identify the work.
- Summing nested event durations: double counts compilation and linking.
- Excluding cold frames: changes acceptance and hides the remaining startup cost.

## Consequences

For product inputs unchanged since af2afab, the original baseline has 1101 frame records: 100 startup records with maximum raster 606279 microseconds at frame four, followed by 1001 records with maximum raster 34199 microseconds. Every record remains in the acceptance population and performance remains red.

The distinct traced run completes twenty workload windows with 154 Home cards, exits zero, removes the owned window and naturally drains Job membership for 8.026323 seconds without force. Its worst startup frame has raster duration 388540 microseconds. Thirteen shader-compilation spans occupy 374567 microseconds; thirteen driver program links occupy 336047 microseconds within that same frame and raster thread. The previous startup frame also has cold shader/cache/link spans. This identifies cold GL shader compilation and driver linking as the dominant measured startup work. It does not identify one specific widget or prove the untraced baseline has exactly the same durations.

The independent audit rehashes 59 runtime files, 3588 build inputs and thirty trace chunks containing 53006 unique events. Missing driver-link evidence and a mismatched frame interval are rejected. The default renderer is preserved; trace overhead can change timing, so this diagnostic cannot be used as performance acceptance.

Earlier failures remain retained: the original untraced entry correctly rejected startup tracing and needed forced cleanup after failing before callback installation; an old prewarm reference prevented the first diagnostic compile; and the successful successor compiler initially staged the AOT from the wrong path. Actual output was subsequently bound in a separate successful staging receipt without recompiling. None of these failed stages is counted as behavioral success.

A matching-engine/PDB owned hardware diagnostic completes all twenty workload
windows and retains 1229 frames, 39 actual program descriptors and 78 generated
GLSL captures without capture errors. Eight runtime-effect captures uniquely
match the four packaged surface assets; two engine effects remain unmatched.
The initial pre-start stability failure is retained. The successful unchanged
package retry exits zero, removes its exact window and naturally drains for
8.043807 seconds without force. Capture can affect timing; these descriptor
counts do not establish actual GL-link counts or performance acceptance.
The one-byte primitive field is read as a one-byte enum, preserving the earlier
raw four-byte observation without using its high bytes for classification.
The independent receipt is
`.probe/performance-parallel-20261117/next-driver-keys-v1/FULL_DRIVER_RETRY_AUDIT_V1.json`.

The first link-boundary preparation fails before creating an application.
Its qualified successor completes twenty windows and 1149 frames, but all
78 compile entries reject the function-table target guard. No GL link is
armed; this does not establish zero link calls. Its 156 public compiler
boundaries are 78 nested outer/inner pairs. Raw HLSL is retained, but missing
independent raw strings and ordered macros leave replay ineligible. These
failed captures and their original receipts remain unchanged.

A new embedded-engine diagnostic now retains twenty windows and 1181 frames,
including all 229 startup records. Actual function-table memory uniquely binds
the typed engine target at all 78 compile entries. Each complete 40-byte
wrapper and 32-byte buffer is persisted before validation. All 78 loaded
294-byte target bodies exactly match disk without relocation normalization.
Thirty-nine actual program keys bind 78 compile returns and 39 observed
engine link returns. The root audit rehashes 509 inputs and rejects eight
table mutations; an independent audit passes 46 checks. Exit is zero, the
owned window disappears and natural Job-zero lasts 8.037637 seconds without
force. Execution-slot coverage is bounded; observed returns do not establish
a universal link count.

All 156 observed public compiler boundaries retain exact raw strings with
their actual NUL bytes and complete ordered macros. They remain 78 actual
nested pairs. Fifty-nine unique public input closures are selected for a
separate API-only parameter review. Root verifies 245 inputs and every actual
argument, including nullable values, output slots and compiler identity.
Worker calls have no strong key/program/link attribution. Input completeness
does not authorize execution, identify a widget or measure compiler cost.
The root receipts are `ACTUAL_EMBEDDED_ENGINE_LINK_ROOT_AUDIT_V1.json` and
`ACTUAL_V3_PUBLIC_PARAMETERS_ROOT_REVIEW_V1.json` under
`.probe/goal-root-acceptance-next-20261117/`.

The separately admitted API-only batch executes all 59 exact captured inputs
once. All 59 HRESULTs are zero, all outputs are structured DXBC and all 59
local blob Releases return zero. Output totals 124304 bytes with a maximum
of 11352 bytes. The owned worker exits zero and naturally drains for 8.028296
seconds without force. Root independently checks 199 inputs and every DXBC
structure, rejecting seven mutations. Independent release review passes 31
global and 649 case checks over 276 artifacts. The earlier executor missing
imported dependencies remains rejected; complete replacement source admission
and separate batch authority do not alter the earlier static-only review.
This qualifies public API return/output behavior. Original captured binary
equality, compiler cost and strong render attribution are not established.
The consumed batch is not rerun. Root evidence is
`ACTUAL_COMPILER_API_ONLY_BATCH_ROOT_AUDIT_V1.json` in the same directory.

Frozen actual native stacks place the largest observed compile inside
`CircularRRectOp::onExecute`. A geometry-processor name alone does not prove
a spinner, widget or drawing origin. Its observed-stop residual is not a
CPU/GPU cost. Prepare a minimal typed op-entry/return diagnostic to inspect
actual bounds and the original drawing relationship. The V1 stack guard is
rejected before GUI: entry RSP plus eight identifies the adjacent actual
caller, while the named frame has its own prologue-adjusted SP. Twenty-eight
frozen native observations support the corrected predicate. V2 requires
separate native execution qualification; artificial byte controls and failed
compiler Jobs do not provide it. No actual op-origin capture is accepted yet.

Use causal evidence to review a new renderer hypothesis. Debug pauses and raw wall spans remain
diagnostic; untraced full-frame validation is still required for admission.
Rejected warm-up, shadow and repaint experiments stay rejected. Revisit this
decision if renderer, driver, shader assets, source, core or workload changes.
No product optimization is accepted; raw sources, traces and receipts stay
in the task probe directory.
