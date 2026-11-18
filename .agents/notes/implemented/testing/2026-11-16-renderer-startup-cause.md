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
frozen native observations support the corrected predicate. A separate
materialized V3 native fixture now qualifies 39 actual memory receipts, ten
op entry/return pairs, ten R9 flows and three exact caller bindings. Seven
physical data failures and eighteen actual-stack mutations reject. Its
positive exits zero with Windows Job-zero for 8.0342546 seconds and monotonic
Job-zero for 8.0342578 seconds. Two strict return denials remain exit 73,
forced and unqualified; the outer host's natural drain does not upgrade them.
Independent review passes 518 checks plus 171 import-origin/ABI checks.
Root rehashes 77 inputs and all raw observations. Compiler Jobs remain failed
despite retaining artifacts used by the independently qualified native run.
The older zero-fOpArgs fixture and unfrozen cached-import failures remain
rejected. The successor executes verified source bytes without ambient pyc.

Current engine bytes show that its constructor clears program metadata,
onCreateProgramInfo stores the returned metadata pointer, and onExecute
returns immediately if that pointer is null. The helper is not GL CreateProgram.
The fixture preinitializes metadata and its void Create entry does not qualify
actual engine cold metadata or GL CreateProgram returns. Preserve entry-null
snapshots as pending; an actual adapter must separately bind live typed memory
to the exact owned caller and actual Create entry/return. Actual op-origin
capture is established by the separately qualified actual successor below;
the fixture does not establish widget attribution or performance acceptance.
The new root receipt is `NATIVE_RRECT_V3_TYPED_DECODER_ROOT_AUDIT_V1.json`
under `.probe/goal-root-acceptance-next-20261117/`.

The single actual engine diagnostic now retains four op entry/return pairs,
eight actual Create saved-return pairs and four same-caller typed metadata/key
flows. Root independently rehashes 420 inputs and raw receipts, passes 779
checks and rejects ten scope mutations. Independent protocol review passes
826 checks over 480 associated inputs. All 36 raw receipts are durable. The
target key completes at actual op return before first-ready; entry coverage
then retires explicitly while all 1924 startup frames and 2903 total frames
across the original twenty windows remain recorded. The owned process exits
zero without force and naturally empties for 8.0242102 seconds by the Windows
clock and 8.0242131 seconds by the monotonic clock. The root audit's first
schema interpretation incorrectly treats a per-thread map of empty pending
lists as active calls; that failed checker is preserved with its successor.

Actual target bounds are `[27,65,132,99]`; its one device item has bounds
`[26.5,64.5,132.5,99.5]`, outer radius 17.5 and black alpha 0.06. OpArgs.fOp
matches the saved object, and the applied clip has no coverage processor.
Live object metadata at offset 192 matches saved actual R9 at both Create
boundaries under the exact caller guard. These are observed byte and pointer
relationships, not decoded returned sk_sp semantics, cold metadata creation,
exclusion of concurrent writes or CPU/GPU cost. The sole consumed GUI is not
rerun. Root evidence is `ACTUAL_RRECT_ORIGIN_RUNTIME_ROOT_AUDIT_V2.json` in the
same evidence directory.

The selected Home segmented-tab indicator is a bounded source candidate:
its default light color is black alpha 0.06, and its 40-high track with inset
three produces a 34-high stadium. Source layout also predicts the observed
top-left bounds. This does not uniquely identify a widget. A replacement must
pass exact component/current-composition pixels before original-budget
untraced performance; changing a paint API alone does not prove a new engine
op or shader key. In particular, a path containing an ordinary RRect may be
recognized as the same primitive. The fixed private candidate instead uses
four rational conic arcs and splits its straight segments; the reviewed Skia
source preserves it as a general path rather than assigning an RRect tag.
This is a source hypothesis, pending actual engine observation.

The candidate now passes 24 focused pixel pairs across light/dark, three
pixel ratios and four fractional positions. Its real 337-by-40 segmented row
passes 468 pairs across 36 theme/direction/background cases and thirteen
motion, text, focus, pressed, alpha and resting-track phases. Both premultiplied
and straight RGBA formats match exactly, totaling 936 format comparisons.
The original four-case/five-phase composition matrix also passes all twenty
pairs. Root CRC-decodes all associated PNGs and independently checks the
source inventory: exactly one vendor drawing file changes, with its private
implementation fixed to SHA256
`B651F279E0A47F99BB02B29BF74CD8B17859D0523AC4ED7AA6780010B8C48D0A`.
The missing-import fixture, interrupted asynchronous-I/O fixture and failed
owned-drain predecessors stay failed. A separate mask-SDF/float-color shader
candidate is rejected by sixty differing alpha pixels, maximum difference
three; its failed hash-case parser does not invalidate the independent raw
pixel rejection or upgrade the failed executor.

The exact private path candidate is compiled into a separate Profile AOT.
Root rehashes 6853 frozen bindings and 425 copied sources, verifies package
URI remapping and all ELF64 x64 snapshot mappings, and checks all 59 runtime
files. Only app.so changes from the baseline native/assets package. The
17154952-byte AOT SHA256 is
`A4C06692C8D10D7F42F52C319ABB1FA6A25B6AC211AABAA04088DA0C3C3314BB`.
The compiler exits zero without force and naturally empties for 8.0278476
seconds. This qualifies compiled source and static packaging, leaving runtime
and performance unaccepted. Preserve the original build and manifest; a new
Python observer needs its own execution admission and is not compiled into
the AOT. Root receipts are `SEGMENTED_INDICATOR_COMPONENT_STRICT_PIXEL_ROOT_AUDIT_V1.json`,
`SEGMENTED_INDICATOR_ORIGINAL20_PIXEL_ROOT_AUDIT_V1.json` and
`SEGMENTED_INDICATOR_PROFILE_AOT_STATIC_ROOT_AUDIT_V1.json` in the same directory.

A candidate native-key census must separate the ready-request time from the
later safe-event retirement time. Retain an already observed pre-cutoff entry
and drain its actual saved return; never retire pending calls before accepting
that entry. Any absence claim covers only armed, observed and accepted
nonrecursive startup samples, not every Create call or all twenty windows.
The next plain Profile gate keeps all startup and frame records and computes
each build/raster/total-span limit as `rawUs * 60 <= 1000000`; the rounded
16667 display value cannot relax this budget. No product renderer change is
admitted until that original performance gate passes.

The sole selected-only census now completes twenty windows and naturally
drains for 8.0325351 seconds, retaining all 1097 frames and 117 startup records.
It accepts zero Create entries/returns and zero op calls. Operational runtime
qualification is separate from native observation: boundary, target-key absence
and effect gates all remain false. Its earlier positive empty-collection audit
is preserved and explicitly superseded by the empty-census rejection. Two
matching engine mappings load before ready; the later same-name registry entry
replaces the first. Neither an executed PC nor debug-register history proves
which mapping executes or whether that overwrite causes the empty capture.
The consumed census is not repeated merely to fill an empty result.

The exclusive plain original20 measurement retains 1143 frames, including all
152 startup records, and naturally drains for 8.0341365 seconds. Under the exact
budget, build/raster/total-span failures are 1/15/31 and their maxima are
19491/346259/499690 microseconds. Startup contributes 1/3/7 failures; additional
failures occur during navigation, settings and between windows. This rejects
the selected-only renderer candidate under the original budget. Root rechecks
6942 inputs, both natural lifecycles and every raw frame timestamp, rejecting
eleven altered scope claims. Its receipt is
`ACTUAL_SELECTED_PLAIN_EMPTY_CENSUS_ROOT_AUDIT_V1.json` in the root evidence
directory. No renderer cost or backend elimination is attributed by timing.

A new three-file general-path candidate combines the selected indicator,
WindowFrame clipping and the actual Home breathing skeleton. Correct focused
fixtures use the inherited material_ui Theme, assert actual black/white colors
and alpha10/11/15/20, and pass 144 dual-format comparisons per candidate. The
old focused fixture imported a different Theme provider: exact equality remains
valid for its fallback color, while complete theme qualification is withdrawn.
The real poster is 148-by-266, its title130-by-20 and row stride334. Combined
actual24 and original20 pairs pass all 68 RGBA comparisons with zero changed
bytes. The composed AppTheme dark onSurface is approximately0.908 RGB rather
than pure white; independent pixel review checks its actual opaque-floor blend.

The combined V1 Profile AOT compiles with 425 sources/7274 frozen bindings and
natural Job-zero8.0401913 seconds; native59 changes only app.so. Root verifies
all source and snapshot mappings in
`COMBINED_V1_PROFILE_AOT_STATIC_ROOT_AUDIT_V1.json`. Its copied plan scope text
incorrectly says one source; exact source parity establishes three changed
product sources, and the original receipt remains unchanged. Pixel and static
compile qualification do not admit behavior or plain execution: the original
default ClipRRect has no custom clipper and keeps rectangular child hits,
whereas the new ClipPath rejects corner hits. The original shimmer decoration
tests RRect membership, whereas CustomPaint without a painter hitTest accepts
the full rectangle. Prepare a separately frozen private render-object successor
preserving both original hit semantics before and after paint, then requalify
pixels/source/AOT before one original-budget quiet run. V1 remains held and
all predecessors stay retained; no combined GUI or product change is admitted.

The separately frozen hitfix successor now restores both original behaviors.
Its private WindowFrame RenderClipPath uses rectangular current-size child/self
dispatch; the shimmer RenderCustomPaint uses current-size BorderRadius RRect
membership and updates its radius through updateRenderObject. No paint-size
cache or new repaint boundary is added. Exact reverse source comparison leaves
the V1 painting, color, animation, layout and fullscreen branch unchanged.
Actual dynamic tests pass 77220 queries per cohort across 180 before/after-paint
cases, including resize and same-size radius updates, and ninety full image
pairs in both RGBA formats. Two earlier fixture schedule failures stay failed;
their successor explicitly schedules the test frame without advancing animation
time. This fixture repair is separate from formal runtime measurement.

Candidate-only combined24/focused72/original20 pixels pass 212 raw-format and
116 PNG comparisons with zero changed bytes. The old baselines are not rerun:
all 417 source files and exact private-widget test suffixes are rebound. The
focused fixture retains B651 in both cohorts and is scoped to actual WindowFrame
and Shimmer; combined24/original20 use the original indicator baseline. A new
Profile AOT compiles naturally with 425 sources/7276 frozen bindings and
Job-zero8.0314306 seconds; native59 changes only app.so. Root receipts are
`COMBINED_HITFIX_PRIVATE_SOURCE_ROOT_AUDIT_V1.json`,
`COMBINED_HITFIX_ACTUAL_DYNAMIC_HIT_PIXEL_ROOT_AUDIT_V1.json`,
`COMBINED_HITFIX_24_72_ORIGINAL20_ROOT_PIXEL_AUDIT_V1.json` and
`COMBINED_HITFIX_PROFILE_AOT_STATIC_ROOT_AUDIT_V1.json` in the root directory.
Private inner render-object identity and an actual semantics tree are not
directly observed. Independent review verifies normalized child/self/ancestor
hit paths and the inherited approximate-clip/semantics contract in source.

The fixed once-only plain observer loads seven exact Python modules under a
separate 7348-input admission, without the census observer. Root verifies that
startup, workload, timing and lifecycle code equals the earlier qualified plain
runner after removing only the new source/once guards and admission names.
All three task branches stop Jobs and scans during the measured interval.
The sole hitfix runtime completes twenty windows naturally, retaining all1174
frames and 156 startup records, with Job-zero8.0258834 seconds. Original-budget
build/raster/total-span failures are1/8/14, maxima23510/344067/482420us and
startup failures1/5/7. First heavy frames2/3 retain raster162275/344067us.
Other failures occur in first search/settings, revisited Home and between
windows. Root rechecks7353 inputs and all raw timestamps, rejecting nine scope
mutations; independent release review checks8701 predicates. The root receipt
is `COMBINED_HITFIX_ACTUAL_PLAIN1174_BUDGET_REJECTION_ROOT_AUDIT_V1.json`.

This rejects the hitfix candidate for product admission. Do not repeat its
measurement merely to improve the numbers, infer shader cost from frame spans,
or claim task no-activate flags establish an actual foreground history. The
V15 matrix retains thirty rows/128 reports and rejects twenty-one scope claims.
Next prepare independent engine mapping identities, physical RIP/allocation-base
and loaded-code witnesses with actual nonempty Create boundaries. Registry
overwrite remains unproven as root cause. A track source suggested by retained
337-by-40 op geometry/style may receive isolated pixel qualification; geometry
does not uniquely identify a widget or measured cost. Product rendering remains
unchanged and the goal stays active.

The track-only successor passes468 full-component pairs with936 raw pixels,
468 encoded PNG and468 decoded PNG comparisons, all byte-identical. Root
rehashes4953 inputs with29328 checks and the exact single row-local delta.
Native outer/inner contains comparisons total95040 per cohort at three scales;
actual event dispatch and complete semantics are not claimed. Old operation7
retains six full native onExecute memory-graph receipts, white alpha.10,
Canvas stroke.8 and radius20. Shadow24 is a source default, not established by
that old operation; the AA-expanded radius band is not Canvas stroke width. Historical
geometry/style does not establish unique widget identity, current key effect
or measured cost. No track AOT or formal budget is admitted.

Mapping coreV3 executes85 pure controls. AdapterV4 uses one immutable prior
readback per stopped event to fix shared-return drift in12 actual inherited
fake cases. Root's83-check review confirms both returns use Dr7=5 before
rotation5/1/0, preserving V3's second-return rejection. Real suspended-thread
Dr7 requests0/1/5/1024/1025/1029 read0/1/5/0/1/5. Dr7 zero clears all addresses;
nonzero Dr7 keeps requested addresses, including a disabled slot. Root's wrong
individual-disabled-slot clearing expectation remains a failed V1 audit before
corrected V2's548 checks/313 rehashed inputs, without a fixture rerun. Original
and duplicate task-owned native handles pass PID/birth/Job controls. These
preparations do not prove an engine debug event. A separately admitted single
diagnostic must bind actual RIP/allocation-base/full568-byte Create code and
nonempty current inputs to original saved returns. Captured boundaries and
complete mapping absence remain distinct. V16 has thirty rows/139 rehashed
reports and22 rejected scope mutations. Performance, historical minimize caller
and product renderer acceptance remain false.

The separately admitted existing-AOT diagnostic is consumed and rejected.
Exact7376-source/19-module preparation and prefix pass, but the first actual
Create stop rejects Dr7=1025 against same-thread prior arm Dr7=1. All four
address registers match and only fixedbit10 differs. CoreV3's exact rejection
is reproduced from the unchanged source. Root rehashes7504 files with7640
checks; independent review checks155. Full568-byte receipts are from mapping
load stops34/37; the current entry buffer was read but not persisted before the
Dr7 guard rejected it, so full current-entry code equality is unqualified. The
second mapping is transient, loading37/unloading38. Actual accepted Create/key
counts are zero, ready/retirement/drain are absent, original20 is incomplete and
cleanup is forced. No natural empty8-second receipt is claimed for this run.
A debugger error and early exit do not establish a product crash cause.

The source successor keeps exact arm readback and every address/global/RW/LEN/
Dr6 guard, qualifying the executing hardware-stop fixedbit10 rule separately
with a new windowless native fixture. Current bytes/region/context/prior arm
must persist before any strict guard, including rejected samples. The original
GUI/approval and every source/failed predecessor remain frozen; a successor
requires new source, controls, exact closure and one separate admission. Track
AOT remains unbuilt at that failed-run boundary. V17 retains30 rows/155 rehashed reports with22 rejected
scope mutations. Performance and historical minimize caller remain open.

The separately admitted successor now qualifies actual execution. Windowless
hardware-stop evidence supports only DR7 bit10 variation for masks1/4/5; ordinary
ARM Set/Get stays exact. Core650, source362, inherited206, Release7865 and Root15468
checks close the fresh7601-input package. The sole successor diagnostic naturally
exits0, retains160 empty Job samples over8.035059 seconds and completes original20.
All36 accepted inputs and original saved returns qualify with current entry568
bytes, return16 bytes, thread birth, actual RIP and one mapping generation. The
target8F7A44 key is present once at call28. Root20896/8040, independent8806 and
protocol4405/889 audits retain every old failed run and pre-guard packet; the
packets remain strictGuardQualified=false before the qualified witness is formed.
Current-run mapping count is one, unlike the failed predecessor's transient two.
Positive capture does not qualify absence, unique widget, driver cost, GL link
count or target effect. Diagnostic946-frame timings remain ineligible for formal
performance acceptance. V18 reconciles30 rows/181 reports with26 scope mutations
rejected. A fresh425-source/8609-input single-track AOT compile is separately
approved after source/toolchain reviews; no product renderer is admitted.

The single track AOT compile subsequently succeeds naturally, with dual empty
8.0034857 seconds,425 source files/8609 unchanged inputs and runtime59 containing
only a new app.so. Root9176/8675 and Release18114 qualify that source/runtime
bridge. Its sole untraced original20 run is now consumed and naturally exits0
with dual empty8.0332484 seconds. All1130 delivered frames and178 startup records
remain. Exact raw integer budget failures are build2/raster73/total-span164, with
maxima26621/407274/572170 microseconds; startup failures1/5/10 remain included.
First heavy raster frames2/3 are194268/407274 microseconds. Root8903/8709 checks
confirm all original20 actions, all raw frames, session, once authority and
natural lifecycle, while preserving the older failed hitfix plain run. Runtime
completion qualifies; original-budget performance and product adoption do not.
No timing-difference cause, key effect, unique widget or compiler cost follows.
Do not repeat this candidate for timing; the next hypothesis needs new causal
evidence while retaining468 pixel/contains and source parity receipts.
V20 reconciles30 rows/206 rehashed reports and rejects25 scope mutations.
Original-budget performance and the historical minimize caller remain open.

The frozen track source graph distinguishes two stroke branches: loaded stroke,
shadow and mask retain resolve/silhouette scalar uniforms and drawShader's
Canvas.drawRect recipe; fallback and clipping consume the new contour. The
contour is still constructed before the loaded-stroke guard, so no unchanged
CPU-cost claim follows. Existing old target28 metadata has a64-byte/16-word key,
actual ProgramInfo R9 input with CircleGeometryProcessor class6 and one
CircularRRectEffect class7 with a null child. This positive old-AOT input is not
an operation7/widget join or a compiler-cost measurement. A fresh track-AOT
diagnostic package preserves all cold20/startup/firstReady retirement/original
saved returns. Its separately approved sole actual run now qualifies38 nonempty
Create/input/original-return pairs in one current engine mapping. The old target
key survives at new call30; all972 diagnostic frames and original20 windows
remain retained. Root14009 checks rehash491 actual references, reuse the complete
prelaunch input proof and verify each current568-byte entry and16-byte saved
return with the same thread/mapping and staged debug registers. Retirement
takes0.0817083 seconds; natural exit0 and continuous owned Job zero exceed8
seconds on both clocks. Key presence does not identify the track widget or
measure compilation cost. The consumed plain run remains the performance
rejection; diagnostic timing cannot replace it.
V21 retains30 requirements,231 rehashed reports and31 rejected scope mutations.
All failed checker predecessors remain available; no renderer is adopted.

The74-key independent contrast preserves35 shared canonical key/GP/FP inputs,
observes three new keys including PDB Conic class26, and scopes one old key as
not seen only in the fresh accepted set. Old target28/new30 retains64 raw bytes
and Circle6/CircularRRect7 with a null child. These results support a distinct
child-clip experiment without widget or cost attribution. The private candidate
adds a nullable childClipShape to shared Glass/Panel, with null retaining the
old shape, and supplies a native rounded child clip only for segmented track.
The complete general outer shape and renderer remain source equal. Root33
checks and Release's new source preparation qualify this two-file delta;
fresh pixel/contains/hit/semantics and AOT are pending. V22 retains30 rows and
242 rehashed reports, reusing the existing31 scope controls.

Use causal evidence to review a new renderer hypothesis. Debug pauses and raw wall spans remain
diagnostic; untraced full-frame validation is still required for admission.
Rejected warm-up, shadow and repaint experiments stay rejected. Revisit this
decision if renderer, driver, shader assets, source, core or workload changes.
No product optimization is accepted; raw sources, traces and receipts stay
in the task probe directory.
