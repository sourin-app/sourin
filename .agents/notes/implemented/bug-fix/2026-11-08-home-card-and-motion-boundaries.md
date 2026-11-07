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
