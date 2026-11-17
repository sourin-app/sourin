# Agent Note: More menu scrolls within the player's available height

Status: implemented

Applies: 2026-11-17, `PlayerMoreMenu` inside the bottom-bar popover layer.

This extends [Miuix player controls](../feature/2026-11-08-player-miuix-controls.md)
and preserves [popover focus lifetime](2026-11-08-player-popover-focus-lifetime.md).
The note audit also found [live danmaku control gating](2026-10-20-player-live-danmaku-controls-not-rendered.md):
its group membership and live/VOD conditions remain unchanged. Shared dialogs'
scrolling contract applies to a different host; this fix is local to More.

## Problem

The actual 860x904 combined playback page leaves a 388.8-pixel player region.
Its popover is further constrained by the measured bottom bar. Opening the
complete More menu overflows its Column by 181 pixels, paints menu rows across
the bottom controls and makes lower actions unreliable. The screen height is
not the menu's available height.

## Decision

Keep the complete grouped menu in a SingleChildScrollView within the existing
PlayerPopoverSurface. The inherited finite popover constraints bound the
scroll viewport; the Column retains its natural content height. A larger
player still sizes the card to its contents. This follows the existing
danmaku quick panel's bounded scrolling arrangement.

Group the menu's focus traversal with WidgetOrderTraversalPolicy. Once rows
can scroll, the surrounding page's reading-order traversal otherwise
interleaves offscreen menu items with bottom-bar controls. The observed
scroll-only candidate reaches the source row, then leaves the menu and its
focus owner closes it before the final actions. A local group preserves menu
order without changing the other popovers or trapping focus at the page level.

Keep MiuixPressable rows, their padding, fonts, disabled behavior, trailing
controls and callbacks. Scrolling must not dismiss the menu. Selecting an
enabled row still closes the popover before invoking its original action;
trailing controls remain independently actionable. The existing focus owner
keeps keyboard traversal open, and traversal reveals focused offscreen rows.

## Alternatives considered

Clipping the Column hides actions without making them reachable. Smaller text
or removed groups changes the product rather than accommodating the actual
player size. A screen-based maximum ignores the combined page's local height.
Moving this policy to every popover would change unrelated menus unnecessarily.

## Consequences

The regression uses the real bottom bar and sibling popover layer, the measured
bottom inset and the reproduced local player height. It includes complete
groups, mouse-wheel and touch scrolling, disabled and trailing actions,
keyboard traversal/activation, and a taller-player positive control.

The clean earlier product passes the tall-player control and fails all three
short-player cases with a 214-pixel overflow. The fuller synthetic menu includes
an extra previous-episode action, so this differs from the original native
181-pixel measurement. Both are retained as separate observations.

The final four cases pass with all menu entries retained. Nine enabled focus
targets follow the expected order; the last row becomes visible, survives the
existing focus/hover delay, and Enter closes before invoking its action.
The combined More, hover/exit retention, anchor geometry and duplicate-entry
regression run passes 17 cases. Targeted analysis reports no issues after a
test-only braces correction. The accepted runs exit zero and naturally drain
their owned Job for at least eight seconds, without forced cleanup. Results
are under `.probe/goal-resume-20261115-evening/line-sync-more-menu-*`.

Current native integration and updated package binding remain the coordinating
agent's next step. Widget results do not establish the new package's runtime
or performance acceptance.
