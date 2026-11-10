# Agent Note: Home card surfaces and direct page switches

Status: implemented

Applies: 2026-11-08, changes after f85abfe in compact homepage cards and the product shell.

Extends [compact home and motion preview](../feature/2026-11-08-compact-home-and-motion-preview.md) and [Miuix appearance](../feature/2026-11-08-miuix-appearance.md). The existing compact layout, selected animation styles and approved logo choices remain the governing decisions. The note audit found these two partially related decisions; the sheet exit focus note concerns a separate overlay lifecycle and remains independent. No proposed or rejected note prescribes shrinking a poster with text or retaining an outgoing page when transitions are disabled.

## Problem

The compact card reserves less than its fixed poster height when the system text scale is below one. Its Material card color also inherits the page background, making the full clickable region visually indistinguishable from the surrounding page.

The shell always composites the outgoing page for the transition interval. Selecting no animation, or enabling system reduced motion, only disables the entering transformation; the old page remains underneath the new page.

## Decision

Keep the fixed poster and padding as the compact card's minimum height. Larger text retains the existing height expansion. Bind the card surface to the shared Miuix surface-container role, preserving the existing geometry and full-card action.

Resolve the motion preference before starting the shell's outgoing transition. A direct switch removes the old page from painting in the first frame, cancels its transition timer, and stops the entering controller at its final value. The page remains mounted offstage so its state is preserved. Animated switches retain their existing outgoing interval and curve.

## Alternatives considered

- Shrink the poster with the font: reduces cover legibility when the user only requested smaller text.
- Change the global Material card color: affects unrelated surfaces beyond the home card.
- Only set the outgoing opacity to zero: still retains an unnecessary composed page and transition interval.
- Remove hidden page widgets: loses preserved page state and scroll position.

## Consequences

The compact-card checks read rendered poster bounds, the actual card surface and the detail callback. The shell checks read the production Offstage slots, require retained element identity, and retain an animated-switch positive control. These checks must run against both the changed tree and a clean f85abfe checkout; source-text presence or stored preference equality is insufficient.

Native acceptance must include light/dark populated home cards at normal and reduced font size, plus animated and direct tab switches. Widget results alone do not establish the absence of visible trailing content in the Windows renderer. The selected logo assets and Windows native icon bindings are outside this change.

[Homepage cache and section failure feedback](2026-11-09-home-cache-and-section-failure-feedback.md) governs when these cards become visible and how failed requests preserve them; it does not change their geometry or the shell transition contract.

## Transient tab content caching (v16)

The native Windows GLES profile identified repeated raster work during static-page transitions. Cache only the page-content subtree, inside the existing PageTransition opacity and transform widgets. Follow the incoming controller or the shell-owned leaving animation, clear the image when changing owners, and stop snapshotting when settled, hidden, reduced-motion or no-animation. The controller is disposed with the retained page state. Live is explicitly excluded because its native/video surface must keep its normal rendering path; platform views additionally use the framework's permissive fallback.

The old t1013 string ban documented a valid prior failure but rejected every placement of SnapshotWidget. It is replaced by actual shell pixel behavior tests: intermediate content pixels must change, rapidly interrupted transitions must restore the exact Home content, and settled/hidden snapshots must be released. A wrong-layer mutation moves the snapshot above the animation and fails both fade and slide pixel tests with zero changed content channels. The fixture excludes the animated navigation bar from this assertion, so navigation highlighting cannot make a frozen page pass. Existing five-style geometry, complementary-opacity, retained-State, settings-scroll, none/reduced-motion and route tests remain.

Native evidence under .probe/parallel-astra-1108/tab-content-v16 compares ordinary debug shells through current navigation callbacks. Static Home and Settings content pixels match the control exactly in rows 0–739. After rapid Settings→Home→Search→Home switches the same Home region is identical to its initial frame. The remaining Home differences are confined to the bottom navigation highlight and occur in the control too. Captured middle frames keep changing with the recorded opacity; they do not remain as the settled page. No synthetic page tree, modified animation clock or OS pointer input is involved. Screenshot sampling is not a performance measurement or pointer-hit-test result.

The independent native profile matrix uses the same failed Home content, 1592×904 window, DPR1, 60Hz and slideRight style. The initial delayed baseline has extra metadata requests; control2 is the valid timing control with one startup metadata request, matching the candidate. All preserve raw frame data and normal native shutdown. Remaining over-budget frames and startup time are reported in the implementation plan, without claiming all navigation or external playback is accepted.


The [route pop content cache](2026-11-11-route-pop-content-cache.md) extends
the same content-only rule to a top route reversing its own animation. It
does not change the shell tab cache or claim native frame-time acceptance.
