# Agent Note: Shared stroke and rim program is not admitted

Status: rejected — the complete same-source comparison does not support admission.

Applies: 2026-11-17, isolated same-source Profile builds at `9368801`.

Related: [Renderer startup cause verification](../../implemented/testing/2026-11-16-renderer-startup-cause.md).
The proposed/implemented/rejected note audit finds no existing decision for
sharing these surface programs. The established Miuix appearance and program
demand decisions remain applicable; this experiment does not replace them.

## Problem

The renderer's first-use synchronous driver links dominate measured startup
raster time. Stroke and rim use separate runtime-effect assets. Combining
their immutable program code can reduce one effect-hash component, but the
two draws have different destination/layer contexts and may still need
different backend programs. A lower asset count is not a performance result.

## Proposal

Share immutable stroke/rim program code while preserving their independent
mutable uniforms and the original two draw passes.

## Decision

Keep the shared-program overlay outside product sources. The candidate
retains two independent mutable shader instances, both original draw calls,
blend modes, layer/restore and mask order. Actual compiled reflection and
24 shader pixel pairs plus 20 component pairs are unchanged. This establishes
bounded visual and ABI parity, not frame-budget acceptance.

Run the same original 20-window populated-source workload on two fresh
same-source processes: circular-specific separate programs and the shared
stroke/rim program. Keep all startup timings and the unchanged 60Hz budget.
Independently reconstruct metrics from every raw FrameTiming, confirm timing
receipt coverage, window frame membership, source/dependency hashes, exact
package inventories and natural exit.

The observed comparison does not meet the existing budget or support
admitting the larger shared effect. No renderer or shader changes are applied
to the product.

## Alternatives considered

Counting three packaged programs instead of four ignores layer, geometry and
blend-dependent backend keys. Uniform rounding and sharing mutable shader
instances do not establish fewer program keys. Removing either draw or moving
the rim inside the masked layer changes compositing. Excluding startup timings
conceals the remaining first-use work. A runtime trace can inspect actual
links, but its timings cannot replace the untraced comparison.

## Consequences

Separate/shared candidates retain 1186/1194 raw frames respectively. Startup
raster maxima are 324199/329501 microseconds; startup build-or-raster budget
violations are 5/7. Navigation raster maxima are 46345/72113 microseconds,
with 1/11 navigation build-or-raster violations. Across every retained frame,
build-or-raster violations total 7/39. Both complete all 20 windows, exit zero
and retain empty owned Jobs for 8.0289051/8.0318171 seconds without force.

The actual loaded physical surface-program mapping is four/three assets.
The independent audit rejects removed cold timing, inflated budget, false
performance acceptance and false shared-asset mapping. Receipt and package
bindings are retained in
`.probe/cold-renderer-continuation-20261117/shared-plus-program-candidate-v1/UNTRACED_SAME_SOURCE_REJECTION_AUDIT_V1.json`.

One process pair does not establish universal slowdown or a per-link cause.
Revisit only with a new bounded hypothesis and actual complete timing
improvement while retaining visible behavior and the original budget.
