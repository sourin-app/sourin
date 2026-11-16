# Agent Note: Renderer startup cause verification

Status: implemented

Related: [Current UI and default close callback verification](2026-11-16-current-ui-default-close.md).

## Problem

Surface asset loading and shadow variants improved peaks but left performance over budget. FrameTiming identifies the long frame without identifying the work inside it. Repeating those variants cannot distinguish shader compilation, driver linking or widget work.

## Decision

Keep the untraced acceptance baseline unchanged. Parse every retained frame and separate startup localization from the acceptance calculation without removing startup frames. Build a distinct task-only Profile entry that permits exactly the engine startup-tracing switch, validates its namespace and isolated directories, and retains the default renderer and owned nonactivation.

Run the same populated source-posters workload with the accepted packaged core. Retain startup timeline chunks and frame timings, then independently match Begin/End events by process, thread, category and name. Bind the Rasterizer frame number and time interval to FrameTiming. Measure interval unions for shader compilation, cache misses, driver compilation and program linking; these scopes are nested and must not be added together.

## Alternatives considered

- Tracing the acceptance cohort directly: its explicit no-engine-switch contract rejects that.
- Guessing the cause from a large raster duration: insufficient to identify the work.
- Summing nested event durations: double counts compilation and linking.
- Excluding cold frames: changes acceptance and hides the remaining startup cost.

## Consequences

For product inputs unchanged since af2afab, the original baseline has 1101 frame records: 100 startup records with maximum raster 606279 microseconds at frame four, followed by 1001 records with maximum raster 34199 microseconds. Every record remains in the acceptance population and performance remains red.

The distinct traced run completes twenty workload windows with 154 Home cards, exits zero, removes the owned window and naturally drains Job membership for 8.026323 seconds without force. Its worst startup frame has raster duration 388540 microseconds. Thirteen shader-compilation spans occupy 374567 microseconds; thirteen driver program links occupy 336047 microseconds within that same frame and raster thread. The previous startup frame also has cold shader/cache/link spans. This identifies cold GL shader compilation and driver linking as the dominant measured startup work. It does not identify one specific widget or prove the untraced baseline has exactly the same durations.

The independent audit rehashes 59 runtime files, 3588 build inputs and thirty trace chunks containing 53006 unique events. Missing driver-link evidence and a mismatched frame interval are rejected. The default renderer is preserved; trace overhead can change timing, so this diagnostic cannot be used as performance acceptance.

Earlier failures remain retained: the original untraced entry correctly rejected startup tracing and needed forced cleanup after failing before callback installation; an old prewarm reference prevented the first diagnostic compile; and the successful successor compiler initially staged the AOT from the wrong path. Actual output was subsequently bound in a separate successful staging receipt without recompiling. None of these failed stages is counted as behavioral success.

Next inspect generated shaders/cache or reproducible render recipes and evaluate a bounded full pipeline warm-up candidate with all frame records and startup latency retained. Revisit this decision if renderer, driver, shader assets, source, core or workload changes. No product optimization has yet been accepted; raw diagnostic sources, traces and receipts stay in the task probe directory.
