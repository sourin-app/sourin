# Agent Note: Remove the unused playback line preference

Status: implemented

Applies: 2026-11-09, PlayerPage and PlayerSettingsSheet.

Partially overlaps with [player Miuix controls](../feature/2026-11-08-player-miuix-controls.md): this decision removes one ineffective setting without changing the shared controls. The [direct line controls](../feature/2026-11-08-player-direct-controls.md) and [episode boundary](2026-10-30-episode-jump-duration-boundary.md) decisions remain applicable.

## Problem

The playback settings panel exposes a keep-source-on-next switch whose value is loaded, displayed and saved but never consumed by playback. Keeping a writable preference in the panel implies a choice that cannot affect the result.

## Decision

Remove the visible switch and its dedicated state, constructor arguments and callbacks. Episode navigation continues through the existing next-episode selection, episode transition and reload logic. The cleanup does not introduce a new line-selection policy.

Do not migrate, delete or rewrite user preference data. A historical `dsh.playprefs.keepSourceOnNext` entry is harmless and remains ignored. Its documentation identifies it as a legacy field.

## Alternatives considered

- Keep the switch with an explanation that it has no behavior: leaves an ineffective action in the product.
- Implement a new policy behind the preference: changes episode or line selection beyond removal of an ineffective setting.
- Delete the stored key during startup: adds a data migration without a functional need.

## Consequences

The actual panel regression checks that the unused switch and its explanatory text are absent while countdown and automatic intro skipping remain present. All settings-panel construction fixtures omit the removed arguments. Runtime validation belongs to the root-owned test and native verification sequence; the child performed source inspection and diff validation only.

Reintroducing a setting requires a defined playback decision that consumes its value and behavior evidence for both states.
