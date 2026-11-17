# Agent Note: Native circular clip does not preserve surface pixels

Status: rejected — all twenty complete component pairs change rendered pixels.

Related: [Renderer startup cause verification](../../implemented/testing/2026-11-16-renderer-startup-cause.md).
The established compositing and appearance decisions remain applicable.

## Problem

The isolated circular surface uses a runtime mask that contributes another
first-use shader program. A native clip could remove that draw, but its edge
coverage must preserve the complete grouped surface, child and opacity output.

## Proposal

Replace the circular candidate's custom destination-in mask with native
`clipRRect`, retaining saveLayer/group alpha, shadow, rim, child and blend order.

## Decision

Keep the overlay outside product sources. Compare twenty actual component
RGBA buffers across light/dark, direction, scale, selected state, child and
group opacity. Use separate owned roots, frozen inputs and actual output bytes.
Reject any changed pixel rather than changing the appearance threshold.

## Alternatives considered

- Comparing center pixels misses the antialiasing and group-opacity differences.
- Keeping only control behavior ignores changed rendered output.
- Timing the rejected visual variant cannot establish an admissible optimization.

## Consequences

Both owned component executions finish normally and retain at least eight
seconds of naturally empty Job membership. Their twenty pairs have zero exact
matches, 245279 changed channel bytes, 165573 changed pixels and maximum
channel difference 28. Behavior, child and opacity controls still execute, but
the visual contract fails. No Profile measurement or product merge follows.

Evidence is retained in
`.probe/performance-parallel-20261117/NATIVE_CLIP_COMPONENT_PARITY_AUDIT_V1.json`.
The earlier interrupted sessions remain separate incomplete setup evidence.
This compares two isolated circular candidates, not the current general-only
product. Revisit only with a new coverage/compositing implementation that
preserves the actual complete pixels.
