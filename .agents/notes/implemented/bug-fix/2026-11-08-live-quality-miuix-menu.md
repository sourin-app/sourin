# Agent Note: Live quality selection uses the shared Miuix menu

Status: implemented

Applies: 2026-11-08, the quality selector in `LiveEmbeddedPlayer` on the ordinary live page.

This completes the live quality entry in [player Miuix controls](../feature/2026-11-08-player-miuix-controls.md) and uses the existing [shared Miuix menu contract](../feature/2026-11-08-miuix-shared-menus-and-dialogs.md), both included in `181b474`. The [duplicate-URL correction](2026-10-19-selfaudit-found-four-real-defects.md) remains applicable: independently named options must retain separate keys and callbacks even when their stream URLs match.

## Problem

The product control audit found that `LivePage` still reached a direct Material `MenuAnchor` and `MenuItemButton` through `LiveEmbeddedPlayer` and `_EmbedBar`. The quality trigger appears when at least two non-DRM options are available, so this was a visible omission from the actual Miuix migration.

Replacing this popup must preserve the stream selection callback, current-quality indication, keyboard access and the previous duplicate-URL fix. A URL alone is not a unique menu value because different options may share it.

## Decision

`_LiveQualityButton` calls `showAppMenu<int>` using the trigger's position in the root overlay. The shared implementation supplies the actual Miuix popup, card, rows, keyboard navigation, viewport bounds and dismissal behavior.

Each menu value is its option index. A snapshot of the options preserves the original selected object until the popup returns, and each custom row retains its index-plus-URL key. The first option matching the current stream URL supplies initial focus. Checkmarks keep their existing URL-based behavior, including marking both rows when two options represent the same current URL. DRM filtering and the minimum-two-options visibility rule remain in the existing player path.

The trigger owns and disposes its focus node, prevents repeated opening while the menu is active, and explicitly restores trigger focus after selection or dismissal. This covers pointer activation, where the shared menu may capture the previous primary focus before the trigger's pending focus request takes effect. The callback only runs for a returned selection while the trigger is still mounted.

The existing quality tooltip, icon and circular background remain. Labels fit the shared menu width using at most two lines and ellipsis.

## Alternatives considered

- Restyle the direct Material menu: leaves this user-visible control outside the actual Miuix migration.
- Return a URL from the shared menu: loses the identity of independently named options sharing that URL.
- Rely only on the shared menu's captured focus: can return pointer users to the control focused before the quality trigger.
- Test a copied private control or call its callback directly: misses the real player's filtering, selection and rebuild path.

## Consequences

The dedicated [live quality regression](../../../../test/t20261108_live_quality_miuix_menu_test.dart) mounts the actual `LiveEmbeddedPlayer` with its ordinary control tree. Pointer selection checks actual Miuix popup types, exact callback identity, the updated current mark after a parent rebuild, and restored trigger focus. Keyboard coverage starts from the current quality, verifies Escape without selection, then exercises ArrowUp and Enter. The duplicate-URL case keeps two distinct options independently selectable and excludes an interleaved DRM option.

The fixture bypasses only native player creation through its existing debug hook. It isolates clip data, restores debug flags and unmounts in `finally`. Bounded animation pumps are necessary because the real player's loading indicator keeps animating without a native controller; waiting for all tickers to settle would not test menu completion.

Root executed the dedicated regression, `test/t137_app_menu_test.dart`, and `test/zz_t66_r6_live_controls_test.dart`. The [v2 log](../../../../.probe/parallel-astra-1108/miuix-live-quality-final-v2.log), independently read by this lane, records all 23 cases passing with no click-hit warnings. Root's final formatting pass changed no files, and the production diff whitespace check passed.

The [v1 log](../../../../.probe/parallel-astra-1108/miuix-live-quality-final-v1.log) recorded 21 passes and two failures reading the selected menu item's focus highlight. The first case had already passed its selection callback, changed checkmark and trigger-focus assertions. Miuix inserts its window popup in a separate `OverlayEntry`; after autofocus updates AppMenu, the library defers that entry's rebuild until a frame-end callback. The test now observes both committed frames after focus changes, without adding elapsed time, forcing focus onto a menu row, or changing the production/shared menu. All original behavior assertions remain.

V1 also warned when the test tapped empty space inside a content `Row`: the event reached its interactive ancestor, but not the specified row. Pointer tests now locate and tap the actual `MiuixBasicComponent`, and the fixture makes every click-hit warning fatal while restoring the previous setting in teardown. V2 therefore confirms real event paths without suppressing the warnings.

These widget cases establish menu interaction only. They do not establish native stream switching, external-source playback, visual acceptance or formal-package delivery. Revisit the index/snapshot contract if option identity or live quality selection moves away from URL-based playback state.
