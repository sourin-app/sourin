# Agent Note: System reduced motion for local reveals and panel size

Status: implemented

Applies from 2026-11-11 to SourceBar, MiuixSegmentedTabs and DanmakuInfoPanel.

The note audit found [selected-source reveal](2026-11-10-source-selection-reveal.md),
[shared selector appearance](../feature/2026-10-31-liquid-glass-selector-unify.md),
[Miuix navigation](../feature/2026-11-08-miuix-navigation-and-settings.md),
[panel behavior](../feature/2026-10-27-danmaku-info-panel-default-expanded-and-bindings.md),
and [home/page motion boundaries](2026-11-08-home-card-and-motion-boundaries.md).
They continue to own geometry, component choice, interactions and shell
transitions. This decision covers the three local animation owners; it does
not supersede those decisions or change vendor defaults.

## Problem

SourceBar used a fixed driven-scroll duration to reveal a mounted selected pill.
MiuixSegmentedTabs similarly used a fixed ensureVisible duration, and the danmaku
information panel used a fixed AnimatedSize duration. Those local animations
continued despite the system disableAnimations preference already handled by
MotionPrefs elsewhere. Enabling that preference during a reveal or resize also
left the old motion running.

## Decision

Use the existing MotionPrefs system contract for the owning local transitions.
Reduced motion reaches the real final selected-item or child-size geometry
without elapsed animation time and retires the old reveal or size activity.
Preference changes retain the component State. Ordinary motion keeps real
intermediate geometry and the same final target.

Only MediaQuery.disableAnimations belongs to this contract. The user-selected
PageTransitionStyle.none remains a page/content-transition preference; it does
not become a global local-component switch. No vendor-wide change is made.

SourceBar and shelf_tabs.dart's MiuixSegmentedTabs observe preference dependency
changes and schedule the current target again. They stop an old driven activity
before revealing it with MotionPrefs duration and curve. SourceBar uses jumpTo
for zero duration; segmented tabs use the framework's immediate ensureVisible
path. Normal source and segmented durations remain 260ms and 120ms. SourceBar's
actual-pill geometry, lazy approach, revision cancellation and visible no-op,
and the tabs' keyboard/focus contract remain intact.

The panel lays out its real child directly in reduced mode and creates
AnimatedSize only in ordinary mode. Entering reduced mode disposes the old size
owner instead of merely changing its duration or muting its ticker. A stable
GlobalKey on the content KeyedSubtree reparents that real content across the
mode boundary. Panel expansion, descendant State and action focus survive;
there are no copied sizes, hidden intermediate layouts or new animation-owner
keys on every build. Existing panel content, binding and close actions remain.

## Alternatives considered

- Rely on framework duration scaling: shortening a driven scroll still permits
  intermediate motion and does not retire a running owner at the boundary.
- Apply page-transition none globally: changes an independently scoped preference.
- Change vendor animation/ticker defaults: broadens behavior to unrelated press,
  hover, focus, text and glass interactions.
- Remount components on preference changes: can discard selection, scroll,
  expansion, descendant State or focus.
- Retain zero-duration AnimatedSize: the candidate exposed a real layout
  assertion when its controller synchronously notified during its own layout;
  changing duration also does not finish an already-running controller.

## Verification

The first frozen nine-case target compiled and ran on a fresh clean 76a1a5e
checkout. Six reduced-motion/running-switch cases failed on intended behavior
and all three ordinary-motion controls passed. Source and segmented targets
remained outside the viewport after zero-time layout frames. Reduced panel
expansion stayed at 31px, and an active panel retained intermediate geometry.
Source snapshots remained unchanged. Evidence:
`.probe/parallel-astra-1108/native-verify-v59/v59-ui-red.log`.
Historical first-version SHA256:
`6789b845e3ba1ecc6d7dcdb3da06874c17eceb8bb39dd94c4de608fe98bbe95a`.

The first implementation passed six motion cases but failed three. Two were
instrument defects: source and tabs had already reached the right geometry,
then the tests added a listener to an old disposed ScrollPosition. Framework
Scrollable.didChangeDependencies can replace its position while retaining the
same ScrollController. The corrected cases assert both component Element and
controller identity, then read that controller's current attachment. All target
geometry, idle/activity and subsequent pixel-notification assertions remain.
No exception is caught or suppressed to obtain a pass.

The third failure was a production-candidate defect: reduced expansion/collapse
with zero-duration AnimatedSize notified during layout and marked the same
RenderAnimatedSize dirty, producing a layout assertion. It is separate from the
old-position instrument failure. Evidence for both is `v59-ui-green.log` and its
receipt in the same v59 directory. That run was not a successful GREEN.

The final panel instrument reads actual panel/content rectangles and sizes,
requires unchanged geometry in later frames and no size-animation owner in
reduced mode. Ordinary controls still require a real RenderAnimatedSize, actual
intermediate sizes and stopped final activity. This removes the unnecessary
instrument assumption that reduced layout must instantiate an animation while
retaining the original no-motion requirement. A tenth control reads the real
content Element, close-tooltip State, focused action FocusNode, expanded content
and unchanged geometry across false/true preference roundtrips.

Root reran this complete revised ten-case target on the fresh unchanged 76a1a5e
baseline: six qualified behavior failures and four passing controls. The same
final target passes 10/10 on the implementation; the combined motion/live run
passes 16/16 with unchanged source snapshots. The extra six live cases belong
to their separate decision and are not counted as motion evidence. Final logs
under `.probe/parallel-astra-1108/native-verify-v59/` are
`v59-motion-red-v2.log` and `v59-ui-green-v2.log`, with corresponding receipts.
Final frozen target SHA256:
`3719ebe3f9f7ab35832e758256634367cfc1329be76da75cf6abd1a0370da10d`.

Root's ten related suites report 120 passes, two existing skips and six
failures, with unchanged source snapshots (`v59-ui-related.log`). The three
failing suites also run on fresh unchanged 76a1a5e: 48 passes and the same six
failure names (`v59-related-baseline.log`). This is not an all-green related
result; skips are not passes. One host-binding source anchor in
zz_t1053_danmaku_info_bindings_test requires a single-line literal while the
unchanged player implementation uses an equivalent multiline conditional.
Read-only ownership tracing confirms bindings still pass through DanmakuInfoData
and the host into the panel renderer; baseline/current player and test hashes
are identical. The diagnosis is recorded in ignored
`legacy-danmaku-diagnosis.md` in the same v59 directory. It does not diagnose the
other five failures or establish a fresh native binding interaction. No legacy
assertion or production source was changed to satisfy it. Targeted analysis is
still pending root review at this checkpoint.

The target mounts the real components in AppThemeHost and MediaQuery. Source
selection uses an actually mounted clipped lazy pill; tabs select the real
offscreen focusable capsule. Panel cases invoke current rendered production
callbacks to avoid unrelated pointer/hover springs; they are not pointer hit
tests. Scroll activity uses each owner's current ScrollPosition and pixel
notifications. Tests do not require unrelated vendor tickers to disappear or
compare source strings/duration constants instead of rendered results.

Final root verification after explicit mounted/braces cleanup: the unchanged
combined sixteen cases pass again (`v59-ui-final`); targeted analysis of the four
production files and two new test files reports no issues
(`v59-ui-analyze-final`). Source snapshots remain unchanged during both runs.
This does not convert the separately recorded six baseline failures or two
existing skipped suites into passes.

## Consequences

The selected source and segment remain reachable immediately under system
reduction, including a change during motion. The panel avoids size-animation
allocation and layout work in reduced mode while preserving its real content
and focus. Normal animation remains available and has passing intermediate
geometry controls.

The focused source fixture deliberately uses a mounted clipped pill; existing
far-selection tests retain the lazy-approach coverage. Owner-scoped activity
does not imply absence of all text, press or glass tickers. Related regression
results above include unresolved baseline failures; targeted analysis remains
coordinator-owned. Native Windows motion/accessibility, actual input and
performance acceptance remain separate; no native or frame-rate conclusion is
claimed by the widget GREEN result.


The [route pop cache](2026-11-11-route-pop-content-cache.md) concerns secondary
page rendering during exit; this local-reveal preference contract is unchanged.
