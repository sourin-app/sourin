# IMPLEMENTATION_PLAN_20261116_ACTIVE

Status: active — executable plan for remaining objective; historical evidence remains in IMPLEMENTATION_PLAN_20261108.md.

## Objective and hard constraints

Complete only with receipts bound to the same current source/package. Use isolated owned windows/processes/jobs; no Computer Use, foreground activation, system mouse/keyboard injection, existing client, account, keyring, user data, or system audio. Native/compiler jobs BelowNormal on affinity 0xC000; Cargo/Flutter/CMake serial. Local commits allowed; push/PR/tag/release unauthorized.

## Current checkpoint

HEAD at ff3a0c72b5738baa13b28780acb7e3d29e7f571b. Existing accepted fixes: Home cold-cache normalization; JS mutation/reload ownership; remote reinstall/delete; Release inventory/owner lifecycle; independent task-profile restart; bounded anonymous playback/UI. Do not rerun qualified JS nine-case, 12 progress, 13 cover, 59-file byte check, or two restart owners unless source/package changes. Known RED: Profile budget, nonzero PCM, default-user startup/closeAction, complete protocol/UI/cover breadth.

## Acceptance matrix

| Gate | Current state | Required evidence |
|---|---|---|
| Performance | RED: same-core Profile max build 34291us, raster 606279us, total 906398us | Current source + same core, same workload, raw frames, within 16667us or truthful RED with identified cause |
| Default startup/close | Task-isolated green only | Default semantics, Home ready, nonforeground, production close exit0, Job0>=8s, no force |
| Independent restart | Green in task profile | Reuse until package/source changes |
| Playback/UI/covers | Bounded local/public evidence | Named current-package scenarios, screenshots/JSON, truthful cover failures |
| Audio | PCM false | Owned local decoder PCM with sample/RMS/peak or explicit blocker |
| Whole goal | False | All gates green without scope inflation |

## Execution phases

### 1. Current-source performance
Freeze source and namespace; build Profile/AOT serially; bind app/assets/core; run source-posters unchanged; extract raw max/p95 and exact frames; if RED inspect worst frame and make one smallest production optimization, rebuild and rerun. Never lower budget, discard frames, or substitute component tests.

### 2. Default startup/close
Use current Release only after source binding; isolated roots with default closeAction, no injected choice. Keep window/style/foreground/Home/exit/Job assertions separate. If ask cannot be resolved without input, report blocker, do not select it artificially.

### 3. Playback/UI breadth
Use named current public item for one additional line/episode/return scenario if available; bind provider/id/flag/episode/package; inspect settings/danmaku/follow/favorite/history and cover decode; inventory 403/404/444/HTML/transparent/timeout failures.

### 4. Audio/PCM
Reject endpoint loopback mixing. Process loopback is unavailable on this OS build. Only run an owned local-file libmpv ao=pcm successor with hash, PID/birth/Job, format, nonzero samples/RMS/peak and shutdown; label decoder PCM, not audible WASAPI. Otherwise preserve nonzeroPCM=false.

### 5. Final package
After accepted product changes rebuild one 59-file Release package; verify hashes; rerun lifecycle/restart because package changed; rerun notes/diff/privacy gates; complete only if every matrix row is green.

## Stop conditions

Build/NuGet/toolchain failure, forced cleanup, crash, missing VM, identity drift, stale binary, source mismatch, vacuous test, or missing receipt is not green. Preserve raw logs. No remote operations.

## Evidence

Probes/logs/manifests/screenshots/scripts stay under .probe/goal-resume-20261115-evening/.

- C2 plain-navigation A/B attempt: the isolated plain bottom-bar variant compiled after fixing a Miuix color API, but the real Profile harness failed before workload at `Actual shell navigation is not unique` and later `Home content did not stabilize within 90 seconds`; the log still shows actual Home rendered 154 cards. This is a harness/variant qualification failure, not performance evidence or product GREEN. Receipt: `.probe/goal-resume-20261115-evening/profile-performance-plain-nav-v4/result.json`. The isolated variant was not committed or copied to product source.

- C1 surface-only shader prewarm A/B 实测：隔离变体编译并运行同一20-window workload，baseline max build/raster/total `34291/606279/906398us`，prewarm candidate `31829/326657/549032us`，delta `-2462/-279622/-357366us`。候选仍超16667us预算，故性能不接受；这是任务隔离诊断结果，未改生产源，不能直接作为交付优化。receipt：`SURFACE_PREWARM_PERFORMANCE_AB_V1.json`。

- C3 shadow A/B 实测：隔离诊断变体关闭导航玻璃shadow后，20-window workload结果 max build21140us/raster408598us/total558899us，相对baseline `34291/606279/906398us`改善但仍超16667us；exit0、Job0 8.026s、无force。未修改生产源、性能不接受。receipt `GLASS_SHADOW_NONE_PERFORMANCE_AB_V1.json`。
