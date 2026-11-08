# Agent Note: Shared menus and dialogs use actual Miuix components

Status: implemented

Applies to: 2026-11-08, Flutter UI with `flutter_miuix` 1.3.0.

Partially supersedes the surface choice in [glass component replacement](../architecture/2026-10-18-glass-components-replace-material.md) and the missing shared compatibility host in [unified confirmation dialogs](../architecture/2026-10-24-alertdialog-to-glass-dialog-migration.md). The [dialog shell contract](./2026-10-19-dialog-shell-unification-and-hover-sticky-bit.md) remains in force for dimensions, scrolling and dismissal. This is the shared overlay part of [Miuix appearance](./2026-11-08-miuix-appearance.md) and [source discovery/search migration](./2026-11-08-miuix-source-discovery-and-search-controls.md).

## Problem

The current user request requires visible controls to render actual Miuix components. Retaining Material popup menus or merely recoloring the former glass dialogs leaves shared controls outside that requirement. Replacing those components must preserve menu values, disabled items, caller-provided content and positioning, plus dialog return values, busy-state dismissal guards and keyboard access.

## Decision

`showAppMenu` keeps its public value/anchor contract and renders `MiuixWindowListPopup`, `MiuixListPopupContent`, `MiuixBasicComponent` and `MiuixCard`. The custom Navigator route owns the result, and the Miuix popup owns its normal opening/closing animation. Item focus skips disabled rows, supports arrow keys/Home/End/Enter/Space/Escape and returns to the invoking control after dismissal. Caller-provided item content and destructive text/icon colors remain supported.

Menu anchors are reconstructed from the actual Navigator route layout constraints. The Miuix position provider is limited to that viewport even if MediaQuery describes a larger display; otherwise a caller anchor measured from the real overlay can produce an off-screen menu in a constrained window. It uses the constrained menu width from the first frame because the upstream host initially positions with a zero measured size, which otherwise briefly puts a right-aligned menu outside the viewport.

The library window popup has no reduced-motion option. In that mode the same actual `MiuixListPopupContent` is rendered with settled reveal/alpha progress, using the library position provider; dismissal completes immediately. It does not fall back to a Material menu or copy the library painter.

`AppDialogShell` and the compatibility-named `AppGlassDialog` share `AppMiuixDialogHost`. It registers a real `MiuixDialogLayout` in a route-local `MiuixPopupScope`, rendered by a real `MiuixPopupHost`. `MiuixCard` supplies the visible surface. The existing Navigator route retains return values, back handling and motion; Miuix transition hooks are explicit zero-duration pass-throughs to avoid double animation and retain reduced-motion behavior.

The shell retains its default width 560, compact confirmation width 460, maximum height 620, viewport/keyboard clamping, scrolling, footer/actions and close-enabled contract. Both dialog forms use a managed `FocusScopeNode` with closed-loop traversal. The host intercepts pointers, so confirmation outside taps explicitly consult the current route's `barrierDismissible` before requesting a pop. A transparent `material_ui` host keeps existing caller content compatible without supplying visible controls or a second background.

Legacy `glass` and instrumentation flags remain callable for existing code, but do not select a separate glass rendering branch. Tests now assert actual Miuix types, opaque rendered surfaces and text contrast; the former glass blur A/B assertion is no longer the requested product behavior. Route dismissal, busy-state guards, scrolling, dimensions and returned values retain behavioral coverage.

## Alternatives considered

- `MiuixOverlayDialog`: its public API forces a large-screen height cap of two thirds of the viewport or bottom placement on small screens. Its content widget is private, and 1.3.0 has no public standalone `MiuixDialog`. Using `MiuixDialogLayout` preserves the existing 620/centering contract without copying private code or supplying fabricated screen dimensions.
- A card with no Miuix dialog registration: it changes the surface but leaves the shared dialog outside the actual Miuix dialog infrastructure.
- A Material popup with Miuix colors: it does not meet the actual component requirement.

## Consequences

Existing menu and dialog call sites keep their public APIs, while the rendered subtree uses real Miuix components. A local popup host disappears with its Navigator route rather than leaving a registry entry attached to a different page.

The legacy glass appearance assertions are intentionally replaced with the new component/surface contract. Existing behavior tests remain necessary, especially Escape/outside/back dismissal, busy-state rejection, focus containment, long content and three-button confirmations.

Implementation verification by this lane is limited to Dart formatting and `git diff --check`; tests, analyzer, Windows build and native screenshots are owned by the coordinating task. No previous green test, image or package result is evidence for this migration. Revisit the adapter if a future Miuix version exposes a public dialog content component with configurable placement/height and reduced-motion support.
