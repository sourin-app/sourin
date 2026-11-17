# Agent Note: Shader quad antialiasing removal fails exact component pixels

Status: rejected — every retained component pair differs.

Related: [Renderer startup cause verification](../../implemented/testing/2026-11-16-renderer-startup-cause.md)
and [circular specialization rejection](2026-11-17-circular-rim-profile.md).
The proposed/implemented/rejected note audit finds no existing decision for
this one-line shader-quad AA change. These linked investigations partly
overlap in renderer admission criteria and remain applicable; this rejection
does not replace their independent timing and appearance evidence.

## Problem

Actual backend descriptors show coverage and no-coverage quad variants for
the same packaged surface shaders. Removing draw-rectangle antialiasing can
change geometry keys, but a key difference does not establish fewer links,
compiler cost or unchanged visible edges.

## Proposal

Set only the isolated shader-draw Paint's `isAntiAlias` to false, preserving
shader bytes, original clipping, saveLayer, compositing and shape inputs.

## Decision

Keep the candidate outside product sources. Compare the original twenty
physical component cases against current general-only product rendering.
Require exact RGBA bytes and reject on any difference before further demand
loading or Profile measurement. Retain the common four-program fixture,
actual asset mapping, both sixteen-control cohorts and natural owned exits.

## Alternatives considered

- A small numeric tolerance would change the existing appearance contract.
- A lower geometry-key count does not establish a lower actual link count.
- Profiling a visually rejected candidate does not satisfy renderer admission.

## Consequences

Both cohorts complete twenty captures and sixteen controls, exit zero and
retain naturally empty Jobs for at least eight seconds. All twenty component
pairs differ: 1025 RGBA bytes across 432 pixels, maximum channel difference
eight. Original raw pixels, PNGs, receipts, fixture and file hashes remain
bound. Exact four-program loading and actual asset mapping are observed.

No product change, formal Profile run or additional demand test is admitted.
Evidence is retained in
`.probe/performance-parallel-20261117/next-quad-aa-v1/QUAD_AA_STRICT_PIXEL_REJECTION_V1.json`.
Revisit only with a new bounded hypothesis that retains exact component
appearance; original full-frame budget validation remains required afterward.
