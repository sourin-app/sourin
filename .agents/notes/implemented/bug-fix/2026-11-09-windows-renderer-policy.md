# Agent Note: Windows defaults to Skia with an Impeller escape hatch

Status: implemented

Applies from 2026-11-09 to the Windows native runner and the pinned Flutter SDK.

## Problem

The populated Miuix homepage continues to incur short raster/presentation stalls
under the current Windows Impeller GLES backend after unrelated catalog fan-out
has been removed. Cached transition frames are fast; returning to the real page
can rebuild many offscreen passes. Changing source metadata cannot fix this.

## Decision

Set the Windows DartProject renderer policy to disable Impeller before creating
the window, using the pinned SDK's public `set_impeller_switch` API. The default
therefore uses Skia for ordinary debug, profile and release invocations, without
launcher-only flags or user preference migration. The Miuix widgets, shaders,
materials, animation duration and layout are unchanged.

`SOURIN_RENDERER=impeller` explicitly restores the previous backend on a machine
with a driver-specific problem. The comparison is case insensitive and a bounded
buffer rejects overlong values safely. The Flutter engine's explicit switches
retain their documented precedence over the DartProject policy. This setting
belongs to Windows; no Android/macOS renderer policy is changed.

## Alternatives considered

A complex-paint cache hint did not reduce the observed render passes. Prior
shader/surface fusion experiments either changed pixels or failed to improve
performance and remain rejected. Extending page snapshots indefinitely could
freeze dynamic content. A test-launcher flag alone would leave normal users on
the old backend. Removing glass changes the requested appearance.

## Consequences

The same 360-item AOT workload under the previous default has 7 over-budget frames
across 632 navigation frames. The explicit Skia experiment has 0 across 634; the
rebuilt native product default without a renderer CLI flag has 0 across 632,
with a maximum navigation raster time of 8.762 ms. Both Skia runs also complete
four settings scroll windows / 123 frames without over-budget build/raster work.
These are local-machine observations, not a guarantee across all drivers.

Cold startup remains outside 60 Hz: observed raster peaks are 396.972 ms for the
explicit Skia run and 233.521 ms for the product-default run. Record this tradeoff;
the change improves steady page navigation, not every startup frame. Readiness
and populated-page geometry are verified by the actual native renderer.

Ordinary client screenshots preserve the light Home layout and material: the
same-scene comparison has a mean RGB difference below 0.2/255, with only 1263 of
1375488 pixels differing by more than 5 in any RGB channel. This is not byte-exact
backend equivalence. Three local-video playback/panel/Back lifecycle cycles and
one public account-free 1280x720 video with progressing decoded frames pass on
Skia. Cloud authentication and every media format are outside that evidence.

The fallback's first profile run correctly selected Impeller but the probe-only
environment allowlist rejected the new variable before product startup. Its
failed evidence remains; it is not a product regression. The exact failed probe
PID was force-closed after identity validation because no product quit handler
or visible window existed. A corrected allowlist accepts only this explicit
renderer value; successful runs still use normal AppTray exit.

The note audit found [Miuix program demand](2026-11-09-miuix-glass-program-demand.md),
[material call sites](2026-11-09-miuix-glass-shader-material-call-site.md), and
[selected home catalogs](2026-11-09-selected-home-catalog.md) related but separate.
Their component, shader and request boundaries remain in effect. Revisit this
policy with a pinned-SDK or graphics-driver change and repeat native visual,
video and timing checks instead of inferring acceptance from widget tests.

The corrected environment-fallback run completes all navigation/scroll windows,
logs the Impeller renderer explicitly and exits normally through AppTray. The
product default and fallback run both bind the native runner sources in their
package receipts. This verifies the escape hatch beyond a source-string test.
