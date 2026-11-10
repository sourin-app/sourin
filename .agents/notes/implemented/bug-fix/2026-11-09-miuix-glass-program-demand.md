# Agent Note: Miuix glass loads background programs on demand

Status: implemented

Applies: 2026-11-09, vendored flutter_miuix 1.3.0.

## Problem

The actual Home glass renderers have no backdrop and paint only contours,
strokes, shadows and rims. The upstream loader still compiles the independent
background blend and refraction programs. A previous production AOT observation
has a 1.772-second longest link; an unused program is therefore not just unused
memory. Merely changing shader arithmetic did not improve that startup path.

## Decision

Surfaces without a backdrop load the four surface programs. Adding a backdrop
to the same widget State requests the full set and triggers repaint. Existing
surface programs remain usable during this request. A generation check prevents
stale completion from affecting changed/disposed State. Program-level Futures
share overlapping partial/full requests, including failures. Public full
`MiuixGlassRendering.load()` and `isLoaded` retain their original contract;
partial success is never reported as full success. Per-program fallback and
load-error reporting remain available.

This extends the vendor scope documented by the [material call-site decision](2026-11-09-miuix-glass-shader-material-call-site.md)
with a second precisely pinned Dart patch; that shader decision and all shader
bytes remain unchanged. The [Miuix appearance decision](../feature/2026-11-08-miuix-appearance.md)
still governs real components and light/dark modes. The keyword audit found no
conflicting proposed/rejected loader policy. Historical N7 startup measurements
remain historical; they are not acceptance for this loader.

## Alternatives considered

- Eagerly load all programs for every surface: pays background compilation even
  when the current surface cannot sample any background.
- Drop refraction programs or remove their asset declarations: breaks callers
  that supply a backdrop, including a later update of an existing State.
- Turn off glass or change its sampling: changes the requested appearance.

## Consequences

The real-widget regression on the unmodified loader observes six programs when
only four are needed. The changed loader passes the same initial expectation,
then loads all six when given an actual image, samples that image in rendered
pixels, and restores the original pixels when it is removed. This is Skia widget
coverage, not Windows Impeller acceptance. Windows AOT startup and 15 navigation / four scroll windows complete with the
expected four-program surface readiness. Startup link count is 76 instead of 78;
the longest observed link is 0.166 s instead of 1.772 s and maximum pipeline wait
is 0.214 s instead of 2.661 s. These are single-pair observations, not a cold-cache
benchmark. Two navigation frames exceed 16.67 ms; raster startup max is 79.056 ms,
so all-frame 60 Hz is not established. The ordinary Windows development client also loads/requests exactly these four
programs for its 15 attached surface renderers. Light/dark Home screenshots and
repeated local-player settings/danmaku/advanced open-close/Back checks complete
without AXTree, Flutter or unhandled exceptions; the prior system mode is restored.
These callbacks do not prove pointer hit-testing or cloud playback. The vendor verifier must
pin and exactly reverse/replay both patches and reject changed bytes elsewhere.

Performance observations must retain their workload and backend boundaries.
Four loaded programs prove readiness only for this surface-only workload. A
scene with a backdrop still requires the full set; its checker must not accept
partial readiness. The seven packaged shader assets remain independently read
and verified without probe prewarming.
