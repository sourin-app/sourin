# Agent Note: Player popovers preserve active keyboard input

Status: implemented

Applies: 2026-11-08, the player floating panels introduced before `f85abfe` and the first-level search added by [direct player controls](../feature/2026-11-08-player-direct-controls.md). This extends that interaction contract without changing search, binding or line resolution. The [sheet exit focus boundary](2026-10-23-sheet-exit-keyboard-focus-isolation.md) applies to a separate modal host. The [mouse rebuild decision](../simplification/2026-10-18-player-mouse-jank-localize-rebuilds.md) remains unchanged.

## Problem

The first-level search has a real input field, but the floating panel's mouse exit schedules an unconditional close. A user can focus the field, move the pointer aside and lose the input after 450 milliseconds. The anchor independently schedules the same close, so guarding only the panel's mouse callback leaves a second path.

PlayerPage's text-input guard also returns before its Escape handling. A focused search therefore needs a close handler inside its own focus subtree. A focus-loss callback can schedule work immediately before its panel unmounts, so the delayed close must have an owner and a matching release.

## Decision

PopoverKeepAlive observes descendant focus without taking focus itself. PopoverController holds the currently open panel for each focus owner. Every delayed mouse close checks those holds. Losing both hover and focus schedules the existing delay; explicit close, toggle and switching panels remain immediate.

The panel's Focus handles Escape before it reaches the player's text-input guard. It closes the panel and consumes the event without submitting or changing playback. Focus holds are associated with a panel id, so an old panel does not keep a different panel open. Unmounting or replacing a controller releases the focus owner and cancels only that owner's pending close.

The lightweight fixture reserves the actual measured bottom-bar height, matching the product's sibling popover layer. Without this space the fixture incorrectly places the panel over its own gear button. Tests use the rendered field, submitted text, pointer events and key events as their observations.

## Alternatives considered

- Increasing the hover delay still discards active input once the delay expires.
- Guarding only MouseRegion.onExit leaves the anchor's independent close path active.
- Keeping every opened panel forever removes ordinary hover dismissal.
- Letting Escape bubble to PlayerPage is ineffective while an input owns focus.
- Pumping away a teardown timer hides an ownership defect instead of cancelling obsolete work.
- Disabling semantics does not diagnose native accessibility-tree errors and removes accessibility behavior.

## Consequences

Pointer-only menus retain their existing dismissal delay. Keyboard navigation and editing keep their current panel open until focus leaves or an explicit close occurs. The change does not introduce page-wide rebuilds or timers on keypress.

The focused widget cases cover input surviving panel and anchor exit, ordinary dismissal after focus leaves, explicit gear close and Escape without submission. The unchanged hover cases supply the no-focus negative control. The serial widget run passes all 18 cases across quick panel, hover bridge and automatic control hiding. The same quick-panel file against clean `f85abfe` product code passes seven cases and fails the two targeted cases: Escape leaves the field mounted and pointer exit removes the active field.

Historical Windows playback evidence contains 51 native AXTree update errors, but no node or stage mapping. This focus change is not a demonstrated fix for those errors. Separate native runs must retain accessibility, map failing ids to real semantic nodes and keep semantic tracing out of performance measurements. Revisit the focus ownership contract if multiple simultaneously open panels are introduced.
