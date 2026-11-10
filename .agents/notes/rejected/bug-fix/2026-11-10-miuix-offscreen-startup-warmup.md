# Agent Note: Keep offscreen Miuix startup warmup outside the product

Status: rejected — full startup latency has no demonstrated improvement

Applies: 2026-11-10, the current Windows Skia runner and vendored Miuix surfaces.

## Problem

Navigation is smooth in the measured populated-page workload, but the first
process startup still has expensive driver program links. An offscreen render
could overlap that cost with asynchronous window/core initialization. Measuring
only frames after the render would hide its cost and cannot establish a benefit.

## Proposal

Render the actual Miuix surface widgets offscreen concurrently with normal
window/core initialization, retaining all work in the startup measurement.

## Decision

Do not add a second offscreen widget tree to product startup. A task-local AOT
experiment builds the actual light/dark Miuix glass panels, waits for the four
surface programs, and rasterizes them while the normal entry initializes.
Both arms retain the complete process-start trace and use the same executable,
360-item Home, four ready programs and populated visible card geometry.

The one-process-per-arm observation has these results (baseline / experiment):

- Process creation to first raster completion: 1199.053 / 1280.951 ms.
- First sampled opaque populated Home: 1567.499 / 1402.133 ms.
- Maximum visible raster frame: 232.380 / 145.448 ms.
- Exclusive driver-link work over the trace: 333.379 / 346.439 ms.
- The experiment adds an offscreen raster span of 157.324 ms.

Readiness polling is every 250 ms and the GPU/driver caches are not reset. These
samples do not prove an end-to-end startup improvement: first raster is later,
visible stalls remain, and total link work is not reduced. The smaller visible
peak alone does not justify another render lifecycle in production. Both runs
retain exact source/package bindings and exit normally through AppTray.

## Alternatives considered

The [current renderer policy](../../implemented/bug-fix/2026-11-09-windows-renderer-policy.md)
addresses repeated navigation. [Demand loading](../../implemented/bug-fix/2026-11-09-miuix-glass-program-demand.md)
already avoids unused background programs. Those decisions remain in force.
The [material-call-site decision](../../implemented/bug-fix/2026-11-09-miuix-glass-shader-material-call-site.md)
and rejected shader/fusion experiments are not altered. No unsupported engine
persistent-cache switch or SDK modification is introduced.

The proposed/implemented/rejected keyword audit also found the historical N7
glass first-frame measurement note (methodology only), live channel cold-start
and network first-range warmup notes (different mechanisms), and the fresh
checkout verification note (test provenance). None owns this offscreen-render
proposal or requires changing the existing decisions.

## Consequences

The product retains one ordinary widget tree and the accepted visual appearance.
Startup jank remains open; this is an unsuccessful optimization experiment, not
a fix. Revisit only with evidence for a specific bottleneck that reduces full
startup latency, and compare process creation, first raster, populated-content
readiness, all driver work and lifecycle errors together. The local v34 profile
comparison retains raw traces, frame timings and the experiment outside lib/.
