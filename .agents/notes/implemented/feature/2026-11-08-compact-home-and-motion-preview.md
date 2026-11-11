# Agent Note: Compact home library and visible motion selection

Status: implemented

Applies: 2026-11-08, native homepage and appearance settings.

Related: [Miuix appearance](2026-11-08-miuix-appearance.md) defines the shared light/dark palette and settings controls. [HTML home library](2026-11-04-settings-owned-html-home-library-and-source-filters.md) remains an independent optional renderer. The horizontal-rail drag decision still applies to compact cards. The transition-frame evidence note remains a verification constraint, not a competing animation policy. Audit found no existing decision requiring the tall native library cards or an animation setting without a preview.

## Problem

The native homepage library consumes too much of the first screen. Animation selection does not give visible feedback until a subsequent navigation, and system reduced-motion behavior is not explained.

## Decision

The [home-card and motion boundary contract](../bug-fix/2026-11-08-home-card-and-motion-boundaries.md) governs reduced font sizing, visible card surfaces and direct shell switches.

Only HomePage opts into compact MyShelf cards. Cards combine a small poster with title, episode text, unread count and viewing progress, retaining the existing detail action and horizontal mouse/keyboard navigation. Poster loading and retry behavior are shared. Text scaling increases the card height; the loading state reserves the same compact space. Other MyShelf users retain the original poster layout.

[Empty-caption reservation](../bug-fix/2026-11-10-compact-rail-empty-caption.md)
removes a second caption row only when the active compact rail has no projected
subtitles. Mixed rows and genuine history/favorite captions remain aligned;
header, poster and navigation geometry stay governed by this layout decision.

SettingsMotionPanel uses the production PageTransition implementation for an inline preview, repeats that preview on demand, and opens an ordinary MaterialPageRoute for navigation verification. It reads the same preference notifier as the shell. System reduced motion stays authoritative and is explained in place. No separate animation implementation or forced system override is introduced.

A system preference change to reduced motion finishes the existing preview controller at its final value. Re-enabling animations leaves the cancelled preview settled. Changing the selected style or requesting another preview starts a fresh interval. Preserve the panel State and chosen style across this change.

## Alternatives considered

- Remove the library from home: loses the user's frequent entry point.
- Shrink posters without accommodating text: overflows with accessibility text sizes.
- Force animations despite the OS setting: conflicts with Flutter animation-duration scaling and accessibility expectations.

## Consequences

At default text size, 360px and 1280px fixtures keep each card below 150px and the library region below 260px. Three layout/action tests and two animation/route tests pass, including enlarged text and reduced motion. These prove component behavior; they do not prove the user's original animation failure was caused by their system settings. Reconsider the layout after reviewing the populated native homepage in the product window.

Running-preview coverage uses the rendered action, actual card geometry and its animation owner. A zero-time reduced-motion roundtrip must keep final geometry, completed owner status and no subsequent owner notifications. The ordinary control requires intermediate movement and a fresh replay after leaving reduced mode; unrelated package tickers do not define this boundary.
