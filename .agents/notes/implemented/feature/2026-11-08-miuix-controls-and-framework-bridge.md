# Agent Note: Actual Miuix controls and the framework bridge

Status: implemented

Applies: 2026-11-08, Flutter product controls and shared design wrappers.

Extends [Miuix appearance](2026-11-08-miuix-appearance.md). Partially supersedes the component choices in [glass components](../architecture/2026-10-18-glass-components-replace-material.md); focus, callback, input and disabled-state preservation remain required. [Shared menus and dialogs](2026-11-08-miuix-shared-menus-and-dialogs.md), [navigation](2026-11-08-miuix-navigation-and-settings.md), [player controls](2026-11-08-player-miuix-controls.md) and [notification interaction](2026-11-08-miuix-feedback-controls.md) own their feature contracts. The note audit also found loading-contrast and source-enablement decisions; this migration preserves their ground-color and filtering behavior.

## Problem

Changing palette tokens alone leaves the old component system in place. Flutter Miuix internally uses SDK Material dependencies, while the app uses the separate material_ui package. Without a controlled bridge, actual Miuix text inputs can lack localization and inherit the wrong theme, especially in dark player popovers.

Replacing the controls also exposes interaction differences: duplicate package focus stops can hide independent row actions, a tap does not emit the package slider's drag-finished callback, and another pointer's release must not commit the active seek.

## Decision

The compatibility API renders actual Miuix buttons, icon buttons, text fields, sliders, switches, checkboxes, basic components, progress indicators, tooltips and cards. Existing layout, callbacks and core state remain owned by callers. Design wrappers use these adapters. The source selection bar, provider utilities, source composer, backup, proxy, synchronization, Web-home settings and media metadata use the same components. Poster labels use MiuixBadge, and provider measurement actions use Miuix buttons.

MiuixFrameworkBridge is the sole SDK Material import boundary. It supplies a transparent SDK host, global Material localizations, and a matching SDK theme from the local Miuix palette. Feature widgets remain Miuix. A nested dark scope creates its own bridge when necessary; a scope outside Localizations supplies the fallback delegates. Form fields retain controller ownership, validation, reset and external-controller replacement. Label-plus-hint fields keep a persistent label above the actual Miuix placeholder.

Buttons have one application keyboard stop with Enter, Space and remote Select activation. Independent trailing row actions sit outside the row's excluded package focus subtree. Toggle rows exclude only the redundant switch or checkbox stop. Selected borders are painted with MiuixSquircleBorder; icon sizing, padding and disabled icon colors retain their functional contracts.

Each individual button or choice merges its semantic label, role and action. The package's explicit semantic tap and gesture tap otherwise split the label from the selected/button state; a complete list row must not be merged because its trailing action is independent. Switches and checkboxes likewise expose their actual state and a single enabled action. Button and choice labels flex within constrained rows so enlarged text wraps instead of overflowing narrow dialogs. Selected choices use the theme's on-primary foreground rather than the old dimmed body color.

The slider owns the initiating pointer for completion and cancellation. Taps finish after event dispatch, drag completion is exactly once, and cancellation reconstructs the package drag state before external progress resumes. Arrow keys and accessibility adjustments use the same commit contract. The existing player buffer overlay stays independent of the actual slider painter. Loading uses the actual Miuix indicator and chooses a readable color from the surface behind it, independent of the selected app theme.

Pull-to-refresh uses the actual Miuix container with application-owned asynchronous state. One pending request prevents reentry; completion clears that state only while the page remains mounted. The real touch tests observe the package's release threshold and refreshing state. Its spring dispatched the callback after 1,200 ms in the diagnostic run, so the fixture now waits for the observable state with a three-second ceiling instead of assuming a fixed one-second settle. Both lifecycle tests passed without changing the product threshold or package cache.

Cache cards use the shared Miuix menu and explicit action values. Cancelling returns no action; deletion still requires the existing confirmation and preserves neighbouring files. Real deletion and page refresh passed all 15 cache probe cases; the six visibility/cancellation cases passed after their hover target was bound to the actual PosterCard instead of an unrelated ancestor Column.

## Alternatives considered

- Keep Material controls with Miuix colors: does not satisfy the requested component replacement.
- Import SDK Material throughout feature code: creates a second visible control system and inconsistent theme ownership.
- Exclude every descendant of a clickable list row: makes edit and delete actions unreachable.
- Commit seek on every pointer release: a second touch can prematurely finish a drag.
- Remove assertions tied to prior behaviors: would hide lost callbacks, focus paths or playback semantics.

## Consequences

The adapter is intentionally explicit about package differences. Package internals remain subject to native interaction verification; a widget-tree assertion is not proof of playback or frame performance. Existing glass visual constants are superseded only where actual Miuix components replace them; user data, filtering, navigation actions and selected-media identities are preserved.

Verification so far: the new row traversal and secondary-pointer up/cancel tests produced three intended failures before their fixes, while the six existing control tests still passed. The corrected implementation passed all nine tests. The subsequent selected-border, disabled-icon and compact-icon geometry test passed, as did the nine loading-ground tests. Logs are retained under `.probe/parallel-astra-1108/`. Further integrated/native results are recorded separately and must not be inferred from these focused checks.

The actual semantic-node checks reproduced the split outlined-button and selected-choice failures before merging individual controls. The corrected interaction batch passed 48 tests and the choice/source-navigation batch passed 18 tests; toggle semantics passed 16 tests. The 420-by-360 dialog at 1.3 text scale reproduced a 5.4-pixel overflow before flexible choice labels; the same strict viewport and hit-test checks then passed in a 21-test batch including choice semantics, source selection and boundary feedback. Native playback acceptance remains a separate requirement.
