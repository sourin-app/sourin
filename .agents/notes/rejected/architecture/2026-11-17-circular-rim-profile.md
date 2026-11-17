# Agent Note: Circular specialization and rim validity do not meet frame budget

Status: rejected — complete same-source timings remain over budget and do not support admission.

Related: [Renderer startup cause verification](../../implemented/testing/2026-11-16-renderer-startup-cause.md)
and [shared surface program rejection](2026-11-17-shared-surface-program.md).
Those diagnostic and rejection decisions remain in force.
The separate [shader quad AA rejection](2026-11-17-shader-quad-aa.md) applies
the same appearance contract before timing a different isolated candidate.

## Problem

Cold runtime-program compilation dominates observed renderer startup. Reducing
source arithmetic or specializing a circular shape can change compilation
cost, but pixel equality and a smaller peak alone do not satisfy the full
startup and navigation frame budget.

## Proposal

Use the isolated circular-specific shader path and carry original gradient
validity through rim calculation to remove one repeated length check. Retain
the original mutable instances, layers, draws, blending and child behavior.

## Decision

Keep the seven-path overlay outside product sources. Verify shader ABI and
physical RGBA output, then directly compare twenty complete components from
current general-only product sources with the complete circle/rim candidate.
Require exact bytes and original demand-loading behavior.

Run two same-source Profile packages sequentially in a quiet measurement
window. Keep the original twenty workload windows, every startup frame and
the 60Hz budget of 1000000/60 microseconds. Independently reconstruct all raw
frames, window membership, receipts, frozen inputs and package inventories.
Separate qualified execution from performance acceptance.

## Alternatives considered

- Source length-call counts do not establish final optimizer or GL link behavior.
- Comparing only against another circular candidate does not bind current product.
- Removing startup or accepting only the improved peak conceals remaining budget violations.
- Another run selected solely for a better result does not strengthen this retained pair.

## Consequences

Twelve shader pairs and twenty direct current-product component pairs retain
exact RGBA bytes. Both original demand-loading tests pass. Current general
and candidate packages bind product input `6bb7e49`, 6372 frozen inputs and
59/63 runtime files respectively. No product renderer changes are applied.

The qualified pair retains 1268/1259 frames and all twenty windows. Startup
raster peaks are 375245/303557 microseconds; navigation peaks are 36974/65974.
Startup build-or-raster over-budget counts are 4/11; all-frame counts are 9/14.
Inclusive time to stable Home is 6758.18/7449.35 milliseconds. Both processes
exit zero without force and retain naturally empty Jobs for at least eight
seconds. Four altered timing, budget and scope controls fail.

Each cohort's first run fails the unchanged pre-start Home stability guard;
one same-package retry per cohort completes. Both failed receipts and their
196/304 frame records remain intact and outside qualified workload acceptance.
The old observer lacks the pre-drain snapshot required for exact change
attribution, so no cause is inferred from their later settled state.

Evidence is retained in
`.probe/performance-parallel-20261117/profile-rim-v1/RIM_CURRENT_PRODUCT_PROFILE_AUDIT_V1.json`
and `CURRENT_PRODUCT_RIM_PIXEL_PARITY_AUDIT_V1.json` in its parent directory.
One retained pair does not establish universal slowdown or the rim-only
effect. Actual driver-link count is not inferred. Revisit only with a new
bounded hypothesis and complete timings that retain the appearance contract
and original budget.
