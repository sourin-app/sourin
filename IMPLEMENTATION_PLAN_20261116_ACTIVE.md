# IMPLEMENTATION_PLAN_20261116_ACTIVE

Status: active — executable plan for remaining objective; historical evidence remains in IMPLEMENTATION_PLAN_20261108.md.

## Objective and hard constraints

Complete only with receipts bound to the same current source/package. Use isolated owned windows/processes/jobs; no Computer Use, foreground activation, system mouse/keyboard injection, existing client, account, keyring, user data, or system audio. Native/compiler jobs BelowNormal on affinity 0xC000; Cargo/Flutter/CMake serial. Local commits allowed; push/PR/tag/release unauthorized.

## Current checkpoint

Product inputs remain unchanged since af2afab; subsequent commits record evidence. Existing accepted fixes: Home cold-cache normalization; JS mutation/reload ownership; remote reinstall/delete; Release inventory/owner lifecycle; independent task-profile restart; bounded anonymous playback/UI; bounded independent local decoder PCM control pair; current default ask/cancel/quit callbacks; source order and danmaku instance cold-restart persistence/restoration. Reuse qualified subsets until their source/package/input changes. Known open: Profile budget, ordinary default-user Release startup, complete protocol/UI/cover breadth and final integrated acceptance.

## Acceptance matrix

| Gate | Current state | Required evidence |
|---|---|---|
| Performance | RED: same-core Profile max build 34291us, raster 606279us, total 906398us | Current source + same core, same workload, raw frames, within 16667us or truthful RED with identified cause |
| Default startup/close | Default ask/cancel/quit callbacks green in current-source diagnostic runtime; ordinary Release startup remains open | Default semantics, Home ready, nonforeground, production close exit0, Job0>=8s, no force |
| Independent restart | Green in task profile | Reuse until package/source changes |
| Playback/UI/covers | Bounded local/public evidence | Named current-package scenarios, screenshots/JSON, truthful cover failures |
| Source settings persistence | Current diagnostic UI callbacks plus two independent cold restarts passed for order and danmaku selection/restoration | Reuse until relevant source/package changes; populated disabled/live, address/provider and network breadth remain open |
| Audio | Independent local decoder PCM passed; device/audible claims remain false | Reuse exact packaged libmpv/local TS, negative/positive samples and RMS/peak; keep PlayerPage/device scope separate |
| Whole goal | False | All gates green without scope inflation |

## Execution phases

### 1. Current-source performance
Freeze source and namespace; build Profile/AOT serially; bind app/assets/core; run source-posters unchanged; extract raw max/p95 and exact frames; if RED inspect worst frame and make one smallest production optimization, rebuild and rerun. Never lower budget, discard frames, or substitute component tests.

### 2. Default startup/close
Use current Release only after source binding; isolated roots with default closeAction and no preset preference. Keep window/style/foreground/Home/exit/Job assertions separate. A task-only authenticated interface may invoke an actual mounted original dialog callback to qualify ask/cancel/quit semantics; label this diagnostic callback evidence separately from ordinary Release startup. Do not substitute direct preference writes or cleanup quit for the dialog callback.

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

- 2026-11-16 source/danmaku persistence accepted: original rendered callbacks select public instance B and swap the first two of 49 providers, then save; another fresh process reads both values, clears the endpoint/token through the original Clear action and restores provider order through original Save; a third fresh process confirms defaults and the exact restored 49-id order. Every owner exits zero, removes its window and drains naturally for at least eight seconds without force; logs have zero unhandled/Flutter/AXTree/overflow errors. Search returns one actual provider and the negative query returns no rows. Populated JS/aggregate filters were observed; live/disabled filters only have empty fixtures and are not positive coverage. Audit rehashes 59 files, 3587 inputs and 22 screenshots and rejects four altered controls. Receipt `SOURCE_DANMAKU_PERSISTENCE_ACCEPTED_V1.json`. Retained harness failures: v1 incorrectly required an empty built-in token; v2 owner-2 requested an unnecessary ambiguous scroll after cold-restart checks passed. Corrected successor reuses the successful first owner without reseeding later owners. No product change or whole-goal acceptance.

- 2026-11-16 current-source diagnostic UI/default-close accepted: initial preference absent/default ask; owned SC_CLOSE renders the original dialog; original mounted Cancel preserves ask/unset; second owned SC_CLOSE plus original Quit callback exits zero, saves quit, removes owned window and naturally drains Job for 8.0286492s. Original settings callbacks render source and danmaku pages; LAN disclosure expands/restores without starting remote service; live/follow/cache empty states and Home return render. Final Home return shows 20/20 visible poster widgets decoded, while initial screenshot was still loading (4/20). This does not accept all providers or populated library covers. Independent audit rehashed 59 runtime files, 3586 frozen build inputs and 11 screenshots; four corrupted receipt controls were rejected. Receipt `CURRENT_UI_DEFAULT_CLOSE_ACCEPTED_V2.json`; raw `ui-audit-current-v2/result.json`. Test-only entry/native nonactivation remains separate from ordinary Release startup; no product source change or whole-goal acceptance.

- 2026-11-16 owned local decoder PCM completed: exact packaged libmpv decodes the retained anonymous MPEG-TS into a fresh three-second s16le stereo/44100Hz WAV. Muted control has zero nonzero samples; positive has 264483/264598 nonzero samples, channel RMS 0.0506358/0.0495964 and peak 0.2774353/0.2875061. Both exit0, natural Job0 8.0369/8.0381s, no force; second parser uses standard-library wave. Receipt `DECODER_PCM_LOCAL_ACCEPTED_V1.json` and raw pair `decoder-pcm-local-v1/result.json`. This accepts independent decoder PCM only; device/audible and the prior PlayerPage PCM tap remain separate. Product bytes unchanged.

- C2 plain-navigation A/B attempt: the isolated plain bottom-bar variant compiled after fixing a Miuix color API, but the real Profile harness failed before workload at `Actual shell navigation is not unique` and later `Home content did not stabilize within 90 seconds`; the log still shows actual Home rendered 154 cards. This is a harness/variant qualification failure, not performance evidence or product GREEN. Receipt: `.probe/goal-resume-20261115-evening/profile-performance-plain-nav-v4/result.json`. The isolated variant was not committed or copied to product source.

- C1 surface-only shader prewarm A/B 实测：隔离变体编译并运行同一20-window workload，baseline max build/raster/total `34291/606279/906398us`，prewarm candidate `31829/326657/549032us`，delta `-2462/-279622/-357366us`。候选仍超16667us预算，故性能不接受；这是任务隔离诊断结果，未改生产源，不能直接作为交付优化。receipt：`SURFACE_PREWARM_PERFORMANCE_AB_V1.json`。

- C3 shadow A/B 实测：隔离诊断变体关闭导航玻璃shadow后，20-window workload结果 max build21140us/raster408598us/total558899us，相对baseline `34291/606279/906398us`改善但仍超16667us；exit0、Job0 8.026s、无force。未修改生产源、性能不接受。receipt `GLASS_SHADOW_NONE_PERFORMANCE_AB_V1.json`。

- C3结论：shadow disabled可显著降低诊断包首帧峰值，但候选max raster仍408598us、total558899us，且是隔离变体；在没有明确可交付视觉/性能契约与同包全量验证前不合入生产。隔离worktree诊断行已清除，生产源无改动。下一性能动作需重新设计首帧渲染资源/driver链路，而不是继续重复shadow A/B。

- C5 early-window show A/B attempt: isolated source gated `_showDesktopWindow()` behind `SOURIN_PROFILE_SKIP_EARLY_SHOW=1`; Profile build succeeded, but runtime failed the task-local launcher namespace contract before Home readiness (`Use the task-local profile launcher`). No performance data was accepted, no production source was committed, and the diagnostic line remains isolated. Receipt: `.probe/goal-resume-20261115-evening/profile-performance-skipshow-v1/result.json`.

- C1/C3/C5收敛：surface prewarm与shadow A/B都明显降低诊断首帧峰值但仍远超预算，且未证明可直接合入的视觉/交付契约；skip early show在任务launcher契约阶段失败。未对生产源做未经证实的优化，下一轮需若继续性能应先获取 renderer timeline/资源级证据；否则转默认启动/PCM/UI缺口。
