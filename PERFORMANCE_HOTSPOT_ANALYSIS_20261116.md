# Performance hotspot analysis - 2026-11-16

Status: diagnostic receipt; does not accept the performance gate.

## Binding

- Source: af2afabf1e1f8cf8a770cf93beb41caf8f7ebf36
- Profile namespace: goal-profile-current-head-v2
- Workload: source-posters
- Raw result: .probe/goal-resume-20261115-evening/profile-performance-current-release-core-v1/result.json
- Budget: 16666.666666666668 us/frame
- Completed windows: 20; frame records: 1101

## Worst raw frames

| frame | build us | raster us | total span us | scenario mapping |
|---:|---:|---:|---:|---|
| 4 | 12998 | 606279 | 906398 | startup / before first navigation |
| 3 | 4 | 323643 | 323705 | startup / before first navigation |
| 82 | 1024 | 76739 | 129993 | navigation or steady-state timing record |
| 88 | 434 | 68569 | 74674 | navigation or steady-state timing record |
| 94 | 806 | 61639 | 63658 | navigation or steady-state timing record |
| 172 | 705 | 34199 | 35521 | navigation or steady-state timing record |
| 157 | 2487 | 28249 | 31250 | navigation or steady-state timing record |
| 58 | 890 | 24198 | 27782 | navigation or steady-state timing record |
| 693 | 352 | 20687 | 22116 | navigation or steady-state timing record |
| 169 | 501 | 19357 | 21395 | navigation or steady-state timing record |
| 154 | 405 | 18644 | 19523 | navigation or steady-state timing record |
| 103 | 961 | 16022 | 18605 | navigation or steady-state timing record |

The startup outlier is frame 4: build 12998 us, raster 606279 us, total 906398 us. Frame 3 is also an early startup raster outlier (323643 us). These frames occur before the first navigation window, so they are not attributable to a particular tab callback.

## Observed workload state at settled Home

- page: HomePage
- selected: 发现
- mounted poster cards: 36
- visible/settled poster cards: 20
- home data cards: 154
- glass program names reported: mask, rim, shadow, stroke
- glassSurfaceReady=true, glassLoaded=false

## Diagnosis boundary

The receipt identifies a startup/render-pipeline hotspot, not a proven single production widget. The extreme frame-4 raster time is consistent with first-use GPU/shader or surface/cache work; the data does not prove that the Home poster list or navigation glass alone caused it. Later navigation windows have much smaller maxima than frame 4. Do not claim an optimization or change the acceptance budget based on this receipt.

## Next executable experiment

Run one controlled same-source/same-core Profile comparison with the exact workload and only one permitted rendering variable changed (for example, a production-supported glass/shader prewarm or equivalent existing switch). Keep raw frames and source/core/package bindings. Accept only if the full matrix remains valid and all budget metrics pass; otherwise preserve RED and revert/record the experiment.
