# Agent Note: Tooltip overlays require a visible anchor

Status: implemented

Applies from 2026-11-10 to MiuixTooltipHost and shared application tooltips.

Related: [Miuix feedback controls](../feature/2026-11-08-miuix-feedback-controls.md)
retains notification lifetime and tooltip interactions; [player popover focus](2026-11-08-player-popover-focus-lifetime.md)
retains panel editing and dismissal. The keyword audit found no decision owning
scroll-clipped tooltip anchors. These adjacent decisions remain applicable.

## Problem

After scrolling Home and returning from playback, restored focus can request a
tooltip on the offscreen shelf action. The render objects remain attached and
parents report that they paint their child, although a viewport clips the anchor.
The native Windows accessibility update then references a portal subtree with
no visible anchor. Node ownership snapshots identify MiuixTooltipHost beneath
MyShelf, not the media texture or the player settings panel.

An already visible tooltip can also outlive an anchor's non-scroll layout
change. Replacing its inherited visibility animation during build removes the
anchor from semantics before a deferred portal hide runs. Actual serialized
updates then contain different traversal and hit-test trees. Returning an empty
overlay child still leaves OverlayPortal's deferred traversal-child node.

## Decision

Before showing an overlay, transform anchor bounds into each clipping ancestor's
coordinates and require intersection with that ancestor's approximate paint
clip. Preserve the existing opacity, painted-child, attachment and size checks.
Partially visible anchors still support tooltips.

MiuixTooltipHost owns an OverlayEntry in the nearest Overlay. Its semantics have
ordinary overlay ancestry and do not depend on a portal traversal-parent link
whose anchor can disappear during the same frame. Entry creation, captured
theme/content refresh and state synchronization run after build. Deactivation
and disposal remove the entry. The anchor child stays at the same element path.
Captured InheritedThemes, explicit MiuixTheme, MediaQuery and text direction
preserve the anchor's appearance, local text scaling and directionality;
MiuixTheme itself is not an InheritedTheme.

Track ancestor scroll positions in both axes and dismiss any visible tooltip
when scrolling starts. Reconcile listeners on dependency changes and remove
them on disposal. Defer dismissal out of persistent frame callbacks when
necessary. Returning to a visible position does not resurrect an old tooltip;
a new focus, hover or explicit request is required.

While an entry exists, a post-frame callback rechecks current geometry and
paint visibility on frames already requested by the app. It schedules no frames
of its own. Layout movement updates the tooltip position; a zero-area or hidden
anchor closes the tooltip. Visible host rebuilds also reconcile current content
and theme after build.

The host observes ModalRoute.isCurrentOf. A covering route dismisses the
tooltip rather than leaving a top-level entry above that route; returning does
not restore an old request. Nested navigators use their own nearest overlay.

MiuixPlainTooltip remains the visible component. This does not disable semantics,
remove keyboard access, force scroll position or replace the tooltip styling.

## Alternatives considered

Hiding all semantics would remove accessibility without fixing ownership.
Changing player disposal cannot repair a shelf-owned portal. Attachment and
parent paintsChild checks alone miss viewport clipping. Tracking only the
nearest scrollable misses a vertical page containing horizontal poster rails.
Keeping invisible controls in semantics would change accessibility behavior.
Hiding a portal controller from build is forbidden by the framework; deferring
that hide alone leaves one invalid semantics update. Empty portal content also
retains a deferred traversal node, so it does not repair the ownership defect.

## Consequences

The regression first fails by rendering a tooltip on a fully clipped anchor.
It then verifies focus and retained-callback rejection, partial visibility,
scroll dismissal, a fresh visible request and teardown. Existing focus, content
rebuild, fading-control and hover cases remain required. Native validation must
repeat the scrolled-Home playback-return sequence with semantics enabled;
widget tests alone do not establish Windows accessibility acceptance.

The dynamic visibility-source regression records real SemanticsUpdateBuilder
batches and requires connected, consistent traversal and hit-test trees. The
zero-area regression reads rendered Miuix tooltip content and requires a fresh
request after the anchor returns. Tooltip crossfade checks preserve distinct,
reachable owners. Native node ids from a later failed run may already have been
removed; these regressions do not prove every historical AXTree error has the
same cause.
