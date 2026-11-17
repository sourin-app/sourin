# Agent Note: Keep equal glass update guard outside the product

Status: rejected — actual navigation benefit is not demonstrated

Applies: 2026-11-17, product inputs at fadacc5 and the pinned Miuix renderer.

## Problem

The glass render object invalidates paint on every widget update, even when
effective paint inputs are unchanged. Real component tests show five redundant
paints for five equal updates. That does not establish meaningful savings in
the populated navigation workload, whose child and layout changes can invalidate
paint independently.

## Proposal

Skip the glass render object's paint invalidation when its untextured drawing
configuration is unchanged, leaving every actual paint operation intact.

## Decision

Keep the equal-update guard in an isolated diagnostic copy. The guard compares
all consumed paint inputs and applies only when both backdrops are absent;
backdrop movement and content can change without changing widget fields. Drawing
operations, shaders, sampling, layers and child handling remain unchanged.

The unchanged component test fails on baseline paint count 2 becoming 7. The
candidate keeps it at 2 and still repaints observable color, alpha, shape,
stroke, shadow, enabled and child changes. Its dynamic-backdrop demand-loading
regression passes. Twenty actual source-pill/navigation captures across four
theme/direction/density scenes have byte-identical baseline/candidate RGBA;
32 repeated/mutated image controls also pass.

The separate uninstrumented Profile pair completes the original twenty windows,
with all startup frames retained and the same 16.667ms budget. After startup,
baseline/candidate raster maximum is 23.644/49.080ms, raster p95 3.244/3.620ms,
and over-budget raster count 1/6. Total-span over-budget count is 6/14. Startup
raster maximum is 325.529/289.361ms, still outside budget in both arms.

One sequential pair does not prove a general slowdown. It provides no support
for shipping this candidate as a navigation improvement. The smaller startup
peak cannot be attributed to a guard that preserves first paint and linking.
No timing instrumentation, screenshot or SKP capture occurs in the measured
runs. Both owners exit zero and drain naturally without forced cleanup.

## Alternatives considered

- Ship from the synthetic paint-count result alone: ignores the actual workload.
- Claim improvement from the smaller startup maximum: changes are dominated by
  first-use driver work and the pair lacks causal evidence for that saving.
- Repeatedly rerun until one pair improves: introduces selection bias.
- Remove masks or layers: changes appearance and is not part of this candidate.

## Consequences

Product and vendor reconstruction records remain unchanged. Reconsider only
with an actual workload showing frequent equal updates and a repeatable benefit
under controlled paired measurements. A prepared counter experiment is not run
and cannot supply that evidence. Initial fixture failure from unsupported
package-URI resolution remains a setup failure, corrected in both parity arms
by reading their bound package configuration.

This follows [renderer startup attribution](../../implemented/testing/2026-11-16-renderer-startup-cause.md)
and the rejected [offscreen warmup](2026-11-10-miuix-offscreen-startup-warmup.md).
It does not supersede [background program demand](../../implemented/bug-fix/2026-11-09-miuix-glass-program-demand.md)
or change their accepted shader/appearance contracts. Raw evidence is retained
under the task's performance-continuation and goal-resume probe directories.
