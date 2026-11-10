# Agent Note: Miuix glass uses one material call site while preserving sampling

Status: implemented

Product-scene AOT startup has been measured; residual linking waits remain. The later wide-tap runtime-loop experiment was rejected.

Applies: 2026-11-09, flutter_miuix 1.3.0 OS4 glass shader and its reproducible local dependency.

## Problem

The original AOT startup trace recorded 81 paired `impeller::LinkProgram` spans, totaling 16,797,769 us; the longest single span was 14,105,566 us. A separate per-asset load/fence diagnostic localized the dominant delay to OS4 glass. That diagnostic changes startup order and does not establish ordinary startup time or attribute every microsecond to compilation.

The original `shadeMaterial` has four static source call sites: three in the rim branch and one in its alternative. A pixel executes three or one calls, never four. Each material retains 25 wide-disc samples. Consolidating call sites targets compiler expansion; it does not reduce per-pixel sampling.

## Decision

For the non-Skia backend, put one `shadeMaterial` call site inside a runtime loop bounded at three iterations for the rim and one elsewhere. Preserve the rim predicate, left/center/right coordinates, 0.25/0.5/0.25 weights, assignment and accumulation order. Under `SKIA_GRAPHICS_BACKEND`, retain the original static branch so the Skia compilation path does not depend on this runtime loop.

Keep the actual Miuix Dart components, loaders, styles and complete seven-shader set. The ABI remains 53 float slots (indices 0–52) and sampler 0; the 25-tap wide loop, refraction/reflection, alpha handling and all other shaders remain unchanged. No blur, antialiasing sample or animation is removed.

The app resolves the verified 1.3.0 source through `third_party/flutter_miuix`. Its [patch record](../../../../third_party/flutter_miuix/SOURIN_PATCHES.md) retains upstream licensing, exact source inventory and the single shader patch. The [read-only verifier](../../../../tools/verify_miuix_vendor.py) reconstructs the upstream shader and replays that patch exactly. SDK and pub-cache edits are not part of the build.

## Evidence and limits

- `startup-v10-trace1/startup-timeline.json` supplies the original startup spans above. The 14.105566 s figure is one link span, not the total or a measured saving.
- `shader-v10-compare2/shader-paired-summary.json` reports 24/24 original/candidate material cases with zero channel-byte differences, including light/dark, shape and texture-ratio variants. Original-repeat and alpha positive controls passed. The process exited normally with source bindings intact.
- Compare2's sequential original/candidate load-to-fence intervals were 100,275,253 us and 2,844,543 us. These diagnostic intervals are not a controlled ordinary cold-start comparison, and no startup speedup follows from their ratio.

These files are under `.probe/parallel-astra-1108/profile_aot_v1/runs/`; the full pixel readback report is under `.probe/parallel-astra-1108/shader-v10-compare-renders/`. Synthetic material equality does not establish full widget composition, all backend runtime behavior, or production-package acceptance. The final vendor shader adds only an explicit modification notice to the compared compatible candidate; its identity is recorded in `SOURIN_PATCH.json`.

## Alternatives considered

Changing the 25-tap bound or adding a new uniform would change the tested ABI or sampling contract. App-level duplicate shader assets do not replace Miuix's preferred package asset. Editing a package cache would leave the build unreproducible. These alternatives are not used.

## Consequences

The [background demand-loading decision](2026-11-09-miuix-glass-program-demand.md)
adds a second pinned Dart loader patch. It does not change this shader or its
material/sampling contract; earlier statements that all Dart bytes are upstream
apply to the shader-only revision, not the current two-patch vendor.

The [appearance decision](../feature/2026-11-08-miuix-appearance.md) still requires actual Miuix controls. The earlier [N7 first-frame note](../testing/2026-10-27-n7-glass-first-frame-cost.md) concerns another glass implementation and remains applicable as measurement discipline: wait for real shader readiness, distinguish first use from steady state, and do not turn one diagnostic reduction into a product performance claim. This note does not supersede its measurements.

Ordinary startup must be measured again with the vendor-bound production scene, comparable backend/cache conditions, link totals and maximums, and subsequent frame timings. That validation remains pending at this note's creation.


## Follow-up startup evidence and rejected wide-tap loop (v19)

The current production-scene AOT launch (`startup-v19-current`) reached ready
with source/package bindings intact, 81 LinkProgram spans totaling 4.692 seconds,
a longest span of 1.767 seconds, and a maximum build-finish to raster-start wait
of 3.262 seconds. Raster max was 70.559 ms. This is one failed-Home workload
observation, not a cold-cache benchmark or a full navigation acceptance. The
process exited normally through the app's quit handler.

A separate candidate retained the exact 25 wide taps and accumulation order,
using a runtime loop and a constant offset array only for Impeller. Twenty-four
GPU material cases matched the current production shader byte-for-byte, including
repeat/alpha controls. However the product-scene trial (`startup-v19-wide-trial`)
had a 3.374-second longest LinkProgram, 7.806-second total, 5.554-second pipeline
wait, and 90.875 ms raster max. Diagnostic warm raster samples also offered no
steady-state benefit. These observations do not establish a universal slowdown,
but provide no reason to ship the candidate. **Reject this candidate.**

The production shader was restored from an exact binary backup; its SHA256 is
`fde7a5bca61710685991acfb3fc164aca1ea0449ba763c1d3c899242ee308667`, and the vendor
verifier passed again. No SDK/cache changes or sample-count reduction were used.
The trial Profile package is diagnostic and must not be delivered. Full artifacts
are under `.probe/parallel-astra-1108/shader-wide-v19-candidate`,
`profile_shader_v19/runs/wide-loop-v19-compare`, and the two AOT run directories.
Revisit only with a different hypothesis and real render-cost/startup evidence.
