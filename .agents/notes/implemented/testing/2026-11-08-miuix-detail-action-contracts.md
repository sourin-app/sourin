# Agent Note: Detail action tests follow actual Miuix rendering

Status: implemented

Applies: 2026-11-08, `test/zz_t66_glass_detail_outlined_test.dart`.

Extends [actual Miuix controls](../feature/2026-11-08-miuix-controls-and-framework-bridge.md), [shared menus and dialogs](../feature/2026-11-08-miuix-shared-menus-and-dialogs.md), and [notification interaction](../feature/2026-11-08-miuix-feedback-controls.md). Partially supersedes the outlined-button assertions described in [glass component replacement](../architecture/2026-10-18-glass-components-replace-material.md). The source scan also found the original download geometry tests; their Windows/Android distinction and same-row sizing contract remain applicable.

## Problem

The former tests looked for AppInkWell, Material density implementation comments and a future TODO marker. The actual wrapper now renders Miuix through an application adapter named `ui.OutlinedButton`; a regular expression mistook that adapter for a Material button. Those assertions describe the removed implementation without checking the requested replacement's rendered behavior.

## Decision

Mount the actual DetailPage under AppThemeHost, inject only detail data through its existing test hook, and locate favorite/follow/source/download by their existing semantic-position keys. On explicit Windows and Android platforms, every action must contain a real MiuixButton and no Material OutlinedButton. Measure all four rendered sizes, bounded widths and viewport placement, retain the download/follow width comparison, and require the platform change to exercise compact and touch heights.

Download hover must render a real MiuixPlainTooltip containing the additional label and remove it on exit. Clicking the actual download action must open the Miuix popup with both current/all-episode choices; Escape closes it. The actual Detail error-page return button must navigate back through keyboard activation.

The public outlined wrapper retains counted pointer, Enter, Space, remote Select and semantic activation. An enabled-to-disabled-to-enabled transition verifies actual callback suppression, removal of the semantic tap action, skipped Tab traversal, and restoration of pointer/keyboard activation. Light and dark tests read pixels from the real rendered MiuixButton surface in both enabled states; they verify palette output and a visible disabled-state difference rather than only inspecting constructor values.

The enabled-button regression found a real package/adapter semantics split: MiuixPressable supplies `Semantics(button: true, enabled: true, onTap: ...)` around a GestureDetector whose tap-up recognizer also contributes a semantic tap. Flutter refuses to implicitly merge configurations with overlapping action bits, so the labelled exposed node had focus/tap but no button/enabled flags. Disabled controls had no competing tap actions and did not show this split. The coordinating task wraps only the single-action `_ActionButton` and icon-button adapter in MergeSemantics, preserving the child label, role, state and one invoked action. It does not merge whole ListTiles containing independent trailing actions.

The error-route fixture mounts the route before injecting its error state; it does not wait for an indeterminate loading animation to settle before providing the data needed to leave that animation. After injection, the error label and actual keyboard return navigation remain hard assertions. Exceptions are asserted absent rather than silently drained. Semantics handles are disposed in `finally` before Flutter's end-of-test verification.

A targeted follow-up in `test/miuix_choice_semantics_test.dart` checks ChoiceChip and FilterChip because they directly wrap a MiuixButton outside `_ActionButton`. It requires the same exposed node to carry the label, button role, selected/enabled state and sole tap action, counts actual semantic activations, and verifies disabled suppression and restoration. The real RED run confirmed an unlabelled outer button/selected node and a separate labelled child with tap/focus but no button role. The coordinating task applies MergeSemantics to that single-action ChoiceChip wrapper; FilterChip inherits the fix.

## Alternatives considered

- Change the old source regex or TODO text: would leave only a naming gate without interaction or rendering evidence.
- Assert dimensions on four manually constructed buttons: misses the real DetailPage download trigger.
- Delete the disabled assertion because AppInkWell is gone: would lose keyboard, pointer and accessibility protections.

## Consequences

The legacy filename remains available to existing selectors. The coordinating task's `.probe/parallel-astra-1108/miuix-final-interaction-v1.log` records all eight outlined-action tests passing, followed by the combined interaction suite finishing at 48/48. This verifies the repaired button role and exact callback count together with the Detail geometry, tooltip, popup, error return, disabled transition and rendered colors. The later ChoiceChip/FilterChip follow-up was not part of that run.

The follow-up has independent RED/GREEN evidence: `.probe/parallel-astra-1108/miuix-choice-red-v1.log` records 0 passed / 1 failed at the labelled node's button-role assertion and prints both exposed nodes. After the scoped production fix, `.probe/parallel-astra-1108/miuix-choice-green-v1.log` records the ChoiceChip/FilterChip test passing, all 14 source-bar tests passing, and all three TV keyboard tests passing, for 18/18 total. The selection test preserves its role, selected/enabled state, sole action and exact activation-list assertions across enabled/disabled transitions.

This lane performs isolated Dart formatting and diff checks; the coordinating task owns test execution. Widget-test results do not establish native acceptance or package provenance.
