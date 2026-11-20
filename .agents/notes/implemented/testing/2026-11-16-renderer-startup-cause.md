# Agent Note: Renderer startup cause verification

Status: implemented

Related: [Current UI and default close callback verification](2026-11-16-current-ui-default-close.md).
The separate [shader quad AA rejection](../../rejected/architecture/2026-11-17-shader-quad-aa.md)
retains this diagnostic boundary and the exact appearance contract.

当前解析器的重复次数、真实帧号与独立交叉检查由
[按帧号归因](2026-11-19-frame-number-trace-attribution.md)持有；
本篇既有运行和拒绝记录保持各自冻结范围，不将它们转为新源码的性能通过。

隔离引擎的身份闭包、GLPB 采集和只读消费候选见
[同引擎同 AOT 缓存提案](../../proposed/architecture/2026-11-19-glpb-exact-engine-aot-cache.md)；
[稳定指纹任务版](../architecture/2026-11-20-stable-program-binary-caps-fingerprint.md)已有新实际 39 次驱动接受；
未获性能资格，不改变本篇旧证据或归因的范围。

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

The child-clip candidate is now rejected by actual boundary behavior. All468
component images and10 boundary raster pairs are exact, but four native
contains, four actual ShapeBorderClipper contains and one direct RenderClipPath
hit differ. The40x40 and39.999x40 cases contain the smallest positive float32
left-edge point before the change and exclude it afterward. Global dispatch,
semantics and shared default callers remain bounded positives; they cannot
override direct-hit failure. The SDK-loader-only predecessor and the actual
behavior failure retain natural exit1/no force/dual empty8 seconds. No compiler
once is consumed and no AOT is built. V23 retains30 rows/250 reports with the
prior31 scope controls. A new guarded representation is under source review,
including double sizes that become square in native float32 bounds; all9 failed
points remain in its required gate. The existing468 wide337x40 cohort can be
reused only with exact branch and native-path identity proof.

The guarded successor qualifies all9 previous failing points and native
size-rounding neighbors with12 actual sparse captures,36 branch receipts and
4888 contains comparisons, all exact. The old468 states have independently
qualified337x40 source/layout reuse; they are not fresh guarded executions.
The first fixture's SDK semantics teardown failure remains natural exit1.
An explicit body-end disposal plus guarded teardown fallback preserves all
geometry and naturally exits0 with dual empty8. The final seven-flag audit
is4C61AAF2; the actual successful owned result isB29A76F2.
Compiler v1 fails before materialization/once on a string read argument.
Its successor only canonicalizes that argument and binds a new packet; source,
entry, recipe, lifecycle and output namespace remain unchanged. The first
actual compiler succeeds naturally with dual empty8. Root510 independently
verifies425 targets/runtime59 and only a new app.so. Full startup/original20
measurement remains required; no timing, key effect or renderer is accepted.

The sole guarded plain attempt8CF06B89 subsequently fails before workload
start: Home does not stabilize within90 seconds. All8 public-source section
requests fail, leaving one group/eight sections but zero source cards. Glass
and surface demand readiness are true with no reported glass load error.
Natural exit0/no force/dual empty8 qualify its cleanup, not a completed workload.
The356 saved status snapshots report2381 frame records; the cleanup response
reports357 startup samples. These are counts only: the saved failure contains
no raw build/raster/span duration rows and completes0 of the20 windows.
The collector's ready-loop exception precedes result fetching; its finally
retrieves Quit but not raw results. Do not calculate full-budget statistics from
these counts. The existing failed-phase result/startupResult extensions retain
the original frame buffer, so a future failure-persistence repair requires no
Dart/AOT or successful workload change. Diagnose public input availability
separately without assigning shader, driver, clip or historical minimize cause.
The nine-line failure-only collector candidate is source-qualified by exact
whole-source byte inversion and remaining-module AST equality. It requests
the existing failed-phase result before Quit only when the last actual status
is failed and no full result has been saved; secondary fetch failure cannot
replace the primary error. The completed targeted headless fixture executes the
real nested RPC/extension and whole finally AST across seven branches. It
preserves all1130 legacy frame dictionaries and timing receipts, fetches result
before Quit, and keeps the primary error when that fetch fails. This validates
collector behavior only; no exited raw data or new native frames are recovered.
Two separately owned anonymous direct transport requests time out without
responses. Natural process cleanup passes, but socket10s does not meet a total
request10s bound; the actual wall limitation remains explicit. V25 retains30
requirements/294 rehashed evidence records and prior31 scope controls.
The user's latest clarification supersedes the earlier denial of manual action:
they may have minimized the window to the taskbar because it stayed on top.
Manual minimization is possible; the exact run and cause remain unconfirmed.
Persistent topmost is a user report without a bound native style observation.
Manual, task/system and programmatic alternatives remain open; old Dart/native
ingress is unbound, and no link to the Home readiness failure is established.
V26 retains30 requirements/308 records as the superseded predecessor; the
successor matrix carries this clarification and completed fixture validation.
Old private Home metadata
contains8 sections/154 positions after startup, but lacks startup per-card and
cover-byte bindings; seeded cache restore changes cold semantics. Source-only
Windows cache review finds that the common context attaches PersistentCache,
while the default Windows cache-directory implementation returns invalid.
An explicit packaged GLPB route still requires true binary payload, exact
engine/interface/caps/driver bindings and actual hit/fallback/cost evidence.
No cache producer, engine change or runtime hit is qualified.

V28 retains30 requirements/337 rehashed records. Separately committed Windows
PiP and existing-instance nonactivation repairs require fresh native/AOT and
owning-input Release acceptance; they do not adopt a renderer optimization.
The selected source routes through native Rust TVBox, not JS. All eight Home
section messages are generalized failures without a retained underlying error
class or HTTP clock. Unapplied transport proposals and an unsuccessful bundled
public fetch do not establish input recovery or a backend failure cause.

### 首动作前的有界就绪重观测

V38 在等待 timing 回执时出现迟到卡片工作：settledVisible 由 20 变 19、dirtyAncestors 由 2 变 1，
原 signature 守卫在首个导航前拒绝。该失败保留 0 窗口和 37 帧；自然 Quit、exit 0 及双时钟
空 Job 超过八秒只证明清理，runtimeQualified 仍为 false。

V39 只修任务采集入口的开始时序：记录变化快照并有界重观测，额外要求全部可见卡片已提交、
卡片 dirty 路径计数为零，再保留原 signature 一致检查。不放宽 signature，不删除原始帧。
原 20 动作、各 700 ms 窗口、默认 renderer 与对应内容 cohort、从 _run 起的动作/测量/缓冲代码，
以及整数 `rawUs * 60 <= 1,000,000` 预算均保持。冷启动和窗口外帧继续计入，不清缓冲、不预热。

已有回执完成 20 窗口、1009 帧：启动 19、窗口外 239、导航 585、滚动准备 42、设置滚动 124。
自然 exit 0、无强制清理、双时钟 Job 自然排空超过八秒；build/raster/totalSpan 超预算 2/29/66，
性能仍失败。不能由其它运行的单次读数确定优化因果，也不重复同候选挑选有利样本。

实际 preStartChecks=1、retriesObserved=0，仅覆盖首次检查成功，不能证明 retry 分支动态通过。
90 秒限制在尝试入口/之间检查，每次 drain 另有最多 30 秒 timeout，不是严格总墙钟 90 秒。
candidate/committed 签名对已有独立重算；最终完整 snapshot 未保存，finalSignatureEqual 只是运行时布尔，
不能声称独立重算最后快照。重观测改变启动到首动作的间隔时，该间隔里的原始帧也不能删除。

原回执为 `.probe/perf-frame-audit-20261119-d81ef6c9/V39_INDEPENDENT_RAW_FRAMES_AND_COLLECTOR_DELTA_V1.json`
与 `.probe/perf-product-candidate-20261119-root-v1/V39_UNTRACED_ALL_RAW_FRAME_AUDIT_V1.json`。
这是既有采集器行为与读数的补记，本次没有重跑编译、应用、解析或测试。失败阶段 raw result 在 Quit 前保存、
secondary error 不覆盖 primary error 的现有段落继续有效；它不能恢复旧运行已丢失的 duration。
收益是保留失败材料并防止迟到卡片误作稳定入口；代价是额外快照/RPC 等待与开始时点变化。
只有 collector/RPC、ready/signature 语义、buffer/落盘格式或对应输入改变时才重开影响面。

### 实际缓存全命中后仍存在的启动工作

只补取原样本没有记录的事件：同 98 文件消费者复用同 DLL/AOT/只读清单，仅开启新的隔离任务启动观察；
Profile 默认 Ring 已记录 Embedder，不加引擎开关，不调用原 20 动作。PID 70176 有 35/35 实际 binary accepted、
0 reject/fallback（只启动，不能用 39 次全工作负载作分母）。窗口非激活并准确消失，自然 exit 0、无强制清理，
151 个空 Job 样本，QPC/单调 8.036565/8.0382904 秒。首页实机截面是真实海报与灰占位并见，
与前一对字节相同首页不是相同内容就绪；不声称全场画面等价、真实库 Top 20 或普通启动通过。

真实 10298 个事件以同一 PID、栅格线程和真实 frame_number 绑定 42 帧；首批 40/8 receipt 精确追加到 Quit 前
70/13，Quit 计 70，不证明 Quit 后每帧存在。第 2 帧 raster 197597 μs，程序构建包络 133375 μs，
其中 PersistentCacheLoad 36112 μs、cache_hit 72575 μs；呈现包络另为 53379 μs。第 3 帧 raster 232241 μs，
程序构建包络 164174 μs（其中 load 22036、hit 126162），呈现包络 61346 μs；两大包络并集 225520 μs。
第 12 帧 raster 3900 μs、totalSpan 232474 μs，buildFinish→rasterStart 220531 μs 中有 220516 μs
与此前栅格 DoDraw 重叠。归因只属于该次运行；不凭零 compile/link 标记断言所有底层 driver 无编译。

shader_compile 标记包含缓存读取、emitAndInstallProcs 与 finalize（其中创建程序）；cache_hit 位于 finalize，
包含已读 payload 的解析、ProgramBinary、link 状态查询、observer 与属性设置，不包括此前的 Package::Load。
不能用任一包络或差值冒充 glProgramBinary 专属耗时。呈现还包含 EGL 绑定、
framebuffer blit、swap 与呈现通知，不能把整个 FlutterCompositorPresentLayers 当作 SwapBuffers 或 GPU CPU 时间。
读回可扰动后续帧，只做诊断；严格预算与此前 20 窗口结果保留，不复跑此次已取得的证据。
实际事件及 4 项拒绝对照见 [按帧号归因](2026-11-19-frame-number-trace-attribution.md)。

### 已保存真实原生 API 的独立子项

在统一任务目录 `sourin-glpb-startup-20261120-round6/` 中，
`driver-micro/actual-manager-v3/result.json` 绑定同源默认 Flutter EGL Manager 的 render context；
无需 HWND、Pbuffer 或 window surface。最初 MSVC wrapper 链接虽 exit 0，却遗留所属 vctip，
不能自然排空且清理强制，失败原件保留；直接 lld 后继自然链接，但旧 Pbuffer 的 EGL 指纹不符，
在任何 ProgramBinary 前 exit 1。最后只改变夹具初始化为原 Manager，精确 EGL/GL/
DXGI adapter/driver/format 与 manifest 相符，所有原材料只读，39 个程序逐一实际 LINK_STATUS=1、
GL_NO_ERROR。编译、链接及夹具各自然 exit 0、双时钟空 Job 超过八秒，不启动 Sourin。

同次 39 条 Package::Load 合计 14954.3 μs（逐次重新开文件/哈希/ABI），CreateProgram 合计419.7，
ProgramBinary 合计2421.2，紧随的 link status 查询合计137630.2，后两者合140051.4 μs。
查询可等待底层完成，但这里不观测 worker 或 GPU，不把 API 时间回填到应用第3帧。
单条 link 查询最大19700 μs，也不说明该条在真实应用以同样顺序或成本出现。

私有固定 batch=4 后继仅改变提交/查询调度，不设 compiler threads，不创建窗口或 draw；
39 程序、10批的实际 status/error 全通过。ProgramBinary API 合7159.8 μs、查询合104087，
同调用线程 submit→join 包络并集111296.7，整个 schedule138212.9（含IO/log/间隙）。
重叠的每程序 pending span 不相加；先前串行不重跑，驱动全局缓存未重置，故不是受控因果提速。
原包、SDK、引擎不变，不能将预热挪出正式启动窗口；生产还需要确切将用的 key 集、同一 context
所有者/生命周期、逐项失败回退和首次使用的完成交接。

`ROOT_SAVED_NATIVE_API_READBACK_V1.json` 对已存原始QPC独立复算与六个Job终态一致；
`binary-schedule/BATCH4_SAME_THREAD_RAW_AUDIT_V1.json` 保留1489项核对及六个离线拒绝对照。
provider-only 私有候选保留7次live reader/逐次读验，7批×256小调用的批均值中位，
旧HashBytes为0.658594 μs、新0.301563，Open/Close0.287109；不支持解释22ms加载或126ms hit。
原v1/v2编译失败、v3实际27/31 exit1和后继仅IO的6/6 exit0分开，不能追认v3全绿；
未据此修改生产或重编已验DLL。

### 真正实时指纹读取的子项

新的无窗夹具以原default Manager、原Ganesh options和稳定版Reader执行24次真实同线程读取，
不是Package或驱动提交。首次906.7 μs、后23次中位563.7；D3D完整包络中位385.5，
其中QueryInterface/GetAdapter/GetDesc/CheckInterfaceSupport合段366.2；不能指给其中
某一个API。OptionsAndCaps中位146.4（JSON dump100.4），EGL query+封装/hash11.5、
InterfaceAbi5.5。相邻QPC点是独占相邻子段，不能把包络与内部合段相加；数据只属于
该fixture，13×3×563.7与22ms load只是量级对照，不是应用逐帧归因或节省承诺。

回执在统一任务目录 `sourin-performance-20261120-round7/fingerprint-cost/` 的
`FINGERPRINT_QPC_RAW_AUDIT_V1.json`（974项及5个离线篡改拒绝），三阶段自然exit0/noForce、
双时钟Job空≥8s。原source逆除任务插点等同，实际scope/generation/expected/unbound拒绝与
重绑新epoch通过；原3534对象只核size/mtime/file-ID不变，不能说全字节重验。
不缓存driver version或caps：同device/epoch/未removed没有完整不可变性证明，Windows
声明和ANGLE的初始化快照不足以支撑跳过实时读取。后继只在新输入下拆四COM子项，不复跑旧微测。

### 呈现包络保留未归因子项

`present-path/PRESENT_PATH_READONLY_ACTUAL_RECEIPT_V2.json` 独立重读相同10298事件/42对
present，第3帧61346 μs包络内没有子scope，限定round3–6任务树未找到已存ETW。
13个呈现链源码与该实际DLL的既有canonical inputs一致；真实链是WindowSurfaceD3D→SurfaceD3D
→SwapChain11。外层还含view锁/resize、MakeCurrent、blit，以及swap之后的OnFramePresented
（可条件DwmFlush），均不能指定为当前实测根因。五个互斥CPU trace段随后按下一节生成了独立私有DLL与新运行；原未应用候选与静态回执保留，
撤掉trace添加后与原源码同字节不单独赋予运行、像素或性能资格。

### 五段呈现trace的新同DLL/AOT实际读回

私有构建实际重编compositor与唯一identity consumer两单元、复用3534个实际对象（含原caps
替代物），453条新include按父canonical读取核hash；direct lld自然link。三阶段均自然exit0
/noForce/双空≥8s，新DLL `AAEE1D80906AA920CD8A754A2C0B663656FF28515AAB7D26C921EE2F2D7BC127`、
闭包 `8F525D744F177CBFBE1FB8EDBEFB15F65171B975B783661F666C775A613BF052`。
它是父source资格继承+实际复用对象/库+两个新TU/source/command的有限派生对象闭包，
不是重新核完父32812源码或完整宿主；OUT7259/SDK112只核size/mtime/file-ID未变，不冒充全byte。
初稿的parentDll、lldhash、缺失引号、modulebasename和caps include错误在运行前由root纠正，
旧稿保留未执行。新source只加trace，不改原调用、效果、VSync或AOT。

新DLL与原 `8E68C741…0331A` AOT先做一次startup-only捕获：35项全部store、0reject，
manifest `7FF03DF213BB4444C7FBF3B0BE3DEE3BBBBF7D8E1EC8B10453C4B20A26192DE9`、
34唯一payload/460892字节；真实Finish/decoder复核后，才编新consumer任务常量。新94文件消费者
只读35物料实际35load/return/matched/binary/accepted、0fallback/reject，同native nonce。
两次均自然exit0/不激活/窗口消失，双空≥8s；不复用旧39项、更不改其标签，不调用原20动作。

捕获106raw/106present覆盖；消费84raw/44完整present覆盖，ready43全部在完整帧中，
40timing-only含正在RPC尾部的frame70。匹配与负例由[按帧号归因](2026-11-19-frame-number-trace-attribution.md)持有。
消费者frame2 raster224570 μs，其外层present80289、SwapBuffers70605、
OnFramePresented8844、OnFrameGenerated488、MakeCurrent1、blit338，其余13；
frame3 raster240528，其present49390、SwapBuffers49315、OnFramePresented1、
OnFrameGenerated6、MakeCurrent11、blit51，其余6。五段互斥，可以与outer剩余核对；
SwapBuffers仍含EGL/ANGLE验证、可能offscreen copy、DXGI调用和swap通知，不能再直接叫
DXGI Present/GPU耗时或VSync根因；OnFramePresented的8844也不能无事件地指定DwmFlush。

第3帧cache命中后程序构建仍重，未删除底层driver工作。新无窗7读COM拆分另外观测
CheckInterfaceSupport邻接段首390.9 μs、后6中位203.55；QI/GetAdapter/GetDesc各约
0.30/0.30/0.10。这只属新7读fixture，不能把旧24合段重标其独占或外推应用帧。
仍不删driver-version实时查询，不缓存未证不可变值。

所有原始帧仍按整数预算保留，capture build/raster/total超1/5/10，consume1/7/13；
它们是diagnostic，不是正式原20预算样本，性能依然未通过。root亲查两Home截面不相同：
capture有全图、consume部分占位，不能作全场视觉等价或跨运行缓存因果。回执在统一任务目录
`sourin-performance-20261120-round7/lead/ROOT_PRESENT_TRACE_STARTUP_PAIR_V1.json`。

### 本次物料中的精确DXBC重复

同次35 descriptor指向34唯一payload，460892字节；离线scanner验证前置64位长度及DXBC
container/chunk/SHDR-SHEX结构，得到68物理嵌入块（34VS/34PS）与70 descriptor引用，
48个精确stage+container字节类；13类重复、首个以外20次出现。8个长度/offset/overlap
变异按指定拒绝。它没有完整解外层ANGLE metadata，不能声称实际Create次数、runtime
资源复用、worker并发或收益；源链已确认loadBinary worker调用D3D Create，但source顺序不量化成本。

回执 `sourin-performance-20261120-round7/shader-bytecode-census/census-result.json` SHA256
`7953768B0E0796E72CFD3B450DF8E82F8478E58FFE47CCAF43D94F4CA32ACE1C`。
这个实际重复只支持准备同device/逐字节/VS-PS分离/成功后保存/限量/重置清空的task-only
shader对象候选及真实D3D fixture；不修改实时指纹、不跳过device健康、不改VSync、不移出冷启动
窗口。原ResourceManager每wrapper allocate/decr保持，cache额外COM引用和debug labels另有
生命周期风险，不能称所有状态等价；尚未编入生产或取得应用/像素/原预算资格。

### Shader对象复用候选的真实API资格与失败

只在私有header实现同device canonical IUnknown强引用、独立VS/PS、size+完整字节key、
成功Create后保存、每hit返回单份AddRef、128条/4MiB bound、实时GetDeviceRemovedReason、
Clear前后caller引用有效；默认关闭。真D3D（本次合法DXBC而非GL包decoder）通过19项，
包含同字节异blob命中、不同stage/长度、第二真实device、Clear/recreate、并发单store、
禁用原调用与invalid bytes两次原driver失败不入。API特性guard首次误写11_0（0xb000），
实际已存cohort为11_1（0xb100），故在shader前安全拒绝；校正枚举后的独立后继三阶段自然0，
原失败不升级。只去memcmp的私有负副本在full-byte-key实际检查自然exit1/noForce，
证明功能门能真正红；原19正例/source未改。这些顺序API时长不作为因果提速或应用预算。

将两个ANGLE CreateResource与release-before-device-clear、唯一identity消费者编入私有DLL，
856条实际include按派生父input核；不改Resource11/ShaderExecutable布局或原allocate/decr。
实际新DLL `BBC682A6…8CCA9F0`/闭包 `A15BECD2…97AF6B3`只在task宏显式1下启用，
3compile+link自然0/noForce/双空≥8；localstatic析构警告和debug-label共享副作用仍未取得
生产资格。新AOT未编、新捕获自己35store/0reject/0IO失败、真实Finish后自然0、86raw保留，
严格指标1/8/15仍红；没有原20动作，不再测旧包seek。

这次退出前没有打印releaseDeviceResources计数：原Dart quit路径不提供C++Renderer析构见证。
零条日志不是证明hits=0，更不是runtime cachehit阳性；该次operational通过、cacheWitness=false。
`shader-runtime-next/capture/circle-shader-capture-v1-once` 原件保留。后继只在实际publish/hit
同锁点加默认关闭、显式task启用、最多first-store/first-hit两条Win32 metadata观察，
保存LastError且无路径/key/bytecode；新DLL身份/新捕获，不通过重复同样候选挑成绩。
没有记录到的应用cache命中，不从API夹具或静态callsite猜绿。

即时观察输入的独立后继DLL为 `09C38892…495A43`、派生闭包 `42AC2EB4…DB2B1F2`；
仍同AOT、原worker/cache算法。root逆除onlyincludes/method/2call与原header逐字节相同，
独审v1两个false由切片查错，不是source反证，v1保留，v2与rootinverse核state/返回/LastError
通过。WriteFile可能失败/partial且mutex内同步阻塞，只是best-effort诊断，不许当无输出=无hit。

新startupcapture实际35store/0reject、33唯一payload/434416字节、manifest
`4BCE53AF3AEC8603A32A56BEA370EE1ACC7356C338A67D1F90F615D4306FA7BC`，
自然exit0/noForce/双空8.0386/8.0402秒。原log真实first-store hits0/misses1/stores1
(thread38564)、first-hit hits1/misses8/stores8(thread42704)，证明此owned进程cache实例
至少一次真正hit，不是GLkey或某device/完整worker历史的归因。95raw/46完整present、49
timing-only含RPCtailframe101，不补end、不删raw。

同新DLL/AOT只读93文件consumer实际36load、35package return/binary/matched/driveraccepted、
0fallback、1rejected，同session nonce6166147067304357515；不可写成全命中/0reject，也不能
仅计数回溯该次拒绝具体分支。原initialReceipt曾1attempt/0return，不能claim初态全0。
另有first-store(0/1/1thread40788)与first-hit(1/8/8thread45620)两即时标签，聚合语义同上。
97ready/preQuit/quitraw，97完整present均覆盖，Ring22411事件；自然0/noForce/双空
8.0483/8.0540秒。root亲看Home capture部分占位而consumer实际图更多，像素/内容状态
不同，不构成跨运行因果或全场视觉等价；截图物理1592×904但控件规模也异，不能默许同内容
cohort或DPR已相同。

新诊断全帧严格build/raster/total分别capture1/6/11、consume1/9/11仍超，不是正式原20，
不声称性能提升或通过，也不重复候选挑成绩。root回执
`sourin-performance-20261120-round7/lead/ROOT_OBSERVED_SHADER_STARTUP_PAIR_V1.json`，
该文件名沿用V1但schema为V2；首readchecker的regex转义/旧capture路径错误保留，由只读v2修复，不重run应用。
候选只能记为task-only object reuse实际hit+局部driver接受已见，未获production/pixel/原预算资格。
新增pair独审task53在原收束时没有成功终态，失败稿和未合格状态保留。晚到的有限
读回`observed-pair-review/observed-pair-review-v2.json`由root实际读过，修正ready/quit原件
来源后核两臂标签和36load/35accepted/1reject/0fallback；身份仍借root桥，不构成独立
完整帧算法或正式预算复核。原始应用未重采样，不把旧错误稿改成通过。

同一私有header另在真D3D人工shader绘制下覆盖opaque miss与alpha hit：独立RGBA8 RT
到staging Map两对32768字节完全一致，真实非空三角各1152像素，中心色/clear另检。先将
候选alpha的红tint常量改值，真实GPU回读1152字节差使同一门自然exit1；随后原状态自然0，
所有owned Job无force/双空≥8，root独立raw读回且亲看PNG。只证这两人工绘制状态，不代表
本次35shader/debug-label/全产品像素或性能。原件在
`sourin-shader-validation-20261120-round8/lead/pixel-execution/PIXEL_READBACK_V1.json`。
主代理原始链检查仍单独有效，正式采用需要补齐受影响行为/原预算与相应独立复核。

Use causal evidence to review a new renderer hypothesis. Debug pauses and raw wall spans remain
diagnostic; untraced full-frame validation is still required for admission.
Rejected warm-up, shadow and repaint experiments stay rejected. Revisit this
decision if renderer, driver, shader assets, source, core or workload changes.
No product optimization is accepted; raw sources, traces and receipts stay
in the task probe directory.
