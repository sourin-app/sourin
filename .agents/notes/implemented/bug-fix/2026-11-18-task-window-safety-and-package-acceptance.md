# Agent Note: Task window safety and current package acceptance

Status: implemented

Independent: This guards task-owned WinAPI calls in the runner and window
plugin. Existing-instance startup and PiP transition recovery retain their
separate decisions.

Related: [existing-instance boundary](2026-11-18-task-noactivate-existing-instance.md)
and [nonactivating show](2026-11-16-task-noactivate-window-show.md).

## Problem

The task acceptance contract requires owned windows without focus stealing or
restoring minimized windows. Runner and window-plugin calls can activate or
restore windows after the initial nonactivating show. The user also confirmed
manual minimization of one obstructing final-smoke window; that failed run
cannot qualify package acceptance.

## Decision

Gate the repository-owned WinAPI wrappers with `SOURIN_TASK_NO_ACTIVATE`.
Guard activation calls, require current-process ownership for window mutation,
use nonactivating show/position flags and refuse restoration of iconic windows.
Forward original arguments, return values and last-error state on ordinary
launches. Include the guard in the runner and force-include a repository-owned
plugin preloader through `windows/CMakeLists.txt`; load Windows/Flutter/COM
declarations before aliases so SDK interface member names remain intact.

The task-private final-smoke driver places its owned visible main window at
HWND_BOTTOM once without moving, resizing or activating it. Its source-sort
exit uses the original Back action without saving; the narrow selector accepts
only the two actual observed Back structures. This driver is evidence tooling,
not an additional product window policy.

## Alternatives considered

- Broader observer or selector relaxation would remove ownership and exact
  action guarantees needed for acceptance.
- Editing the SDK or plugin cache would leave the build decision outside the
  repository and would not preserve ordinary SDK declarations.
- Changing ordinary launch behavior would alter the normal product contract.

## Consequences

Task acceptance uses an explicit opt-in native package and task-owned profiles.
Ordinary default-focus startup remains a separate external acceptance boundary.
Earlier failed builds, minimized runs and the obsolete Cancel-selector failure
stay rejected. The confirmed V4 manual action does not attribute older runs.
Performance is deferred and unaccepted by the user's priority instruction;
the full original goal remains open. There is no remote publication.

## Verification

The guard passes 189 headless behavior checks; its unguarded control fails 109.
The normal native build passes 19 stages and the guarded native successor
passes six, all with natural owned-process exit. Playing, episode-two switching
and pending-request scenes pass original ask/Quit with natural exit zero and
at least eight seconds of empty owned Job on both clocks.

The final smoke passes Home/source-bar, Settings, the original LAN disclosure
expand/collapse, source management, sort-page Back without saving, source-manager
Back and original ask/Quit. The app and all 16 helpers exit naturally with
dual-clock empty-Job duration above eight seconds. The Back helper's six build
and guard stages also pass. Independent review verifies 59 runtime files and
the limited current source/build bridge; reused objects and the core library
retain their actual lineage rather than a single-commit build claim.

The root phase receipt is
`.probe/goal-root-acceptance-next-20261117/CURRENT_STABILITY_AND_FINAL_PACKAGE_PHASE_ACCEPTANCE_V1.json`,
SHA256 `6D18B4FA8BC7D66634DBA454165198C6C2DCF5D463298E7B04CDBAB0B7A7DD54`.
V29 retains the sealed V28 historical scopes and records the current results.
