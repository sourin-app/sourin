# Source and player continuation — 2026-11-17

This continues the original scope in IMPLEMENTATION_PLAN_20261108.md. Current
product input is 6bb7e49. Local work continues without remote publication.
Historical failures and successor receipts remain intact under `.probe/`.

## Implemented and verified

- Detail/source synchronization, late-result rejection, bounded loading
  skeletons and reachable resume controls pass actual native/UI checks.
- Detail/Follow's three obsolete static checks are replaced by actual page
  behavior: 85 tests pass and four isolated behavior mutations fail.
- More actions scroll and retain keyboard order. Original native 181px and
  synthetic 214px overflows remain recorded; 17 tests and current UI pass.
- Source-provider saving uses stable semantics. Current positive and cold
  restart scenarios pass, with native AXTree errors reduced from 21 to 0.
- Five animation styles have forward/backward tab and route samples, plus
  none controls. Actual snapshot painters close the old zoom observation gap.
- Native quit now waits for active and retiring playback/live/preview players.
  The pending-HTTP baseline crashes at the exact registered media wakeup
  callback address. The 6bb7e49 successor detaches it before the core fence,
  exits zero in 5.658 seconds, and records natural Job zero for 8.029 seconds.
  Forty-five related lifecycle, preference, live, preview and transport tests
  pass. Existing analyzer diagnostics are separately tracked.
- Current production C ABI reload and save/delete races preserve ownership.
- Three anonymous protocol families return current catalogues/lists; one also
  resolves the exact direct episode. Its media probe is blocked by the task's
  API-only relay, so resolution is not claimed as decoded media.
- One-item library cold-process restoration, decoded covers, two cache covers,
  populated live playback and independent nonzero decoder PCM are qualified.
- Task-safe Release native components retain production AOT/core bytes. The
  original ask dialog and semantic Quit pass on the earlier AOT. The latest
  AOT still needs final rebuilding and binding.

Local evidence: `.probe/goal-resume-20261115-evening/` contains
`U5_SOURCE_SEMANTICS_COLD_B40_20261117_AUDIT_V1.json`,
`FINAL_MOTION_PAINTER_20261117_AUDIT_V1.json`,
`TCP_WAKEUP_EXACT_ATTRIBUTION_AUDIT_20261117_V1.json`,
`current-player-error-close-tcp-shutdown-v1/result.json`, and
`stacked-detail-player-shutdown-final-v3/result.json`.
Protocol and Release evidence are in `.probe/protocol-final-20261117/` and
`.probe/release-isolated-native-20261117-v1/` respectively.

## Work in execution

1. Finish current-package delayed danmaku, exact binding, unmount/reentry,
   late live-channel scrolling/selection, and return scenarios. Preserve the
   missing-comment-ID fixture failure and incorrect one-shot-pin observation;
   successors compare actual selected row, request identity and parsed comments.
2. Verify two library items with actual ordering, identity, timestamps, progress
   and covers, then a cold process on the same task profile. The repeated TS
   fixture resets before eight seconds. Its successor uses a retained continuous
   75-second MP4 and keeps the original eight-second assertion. This is library
   evidence, not HLS protocol evidence.
3. Finish the exit-barrier negative control and independent native audit.
4. Continue rendering optimization from measured synchronous shader links.
   The isolated circular candidate improves several untraced measurements but
   still exceeds the unchanged 16.667ms budget. A separate diagnostic frame is
   288.579ms with 236.322ms of driver links. Trace results do not replace the
   untraced measurements, and links cannot yet be attributed to individual
   assets. The rejected prewarm/shadow/repaint experiments stay rejected.
5. Rebuild final normal-entry Release AOT, combine qualified task-safe natives,
   exercise original ask/quit and bind affected-input reuse and manifests.

## Boundaries

Ordinary startup intentionally focuses its window, conflicting with the task's
no-focus restriction. Task-safe Release acceptance stays scoped accordingly.
Real cloud-account/cookie/transfer operations require separate external test
conditions; no real account or owner profile is used. Short upstream clips are
reported as short clips. No full-film-duration, physical-input or system-audio
requirement is invented. Blocked media probes remain explicit.

Heavy builds, tests and native runs remain serialized under agreed resource
limits. Successors use new run directories. Reusable evidence is bridged by
its owning inputs rather than rerunning unrelated accepted scenarios.
