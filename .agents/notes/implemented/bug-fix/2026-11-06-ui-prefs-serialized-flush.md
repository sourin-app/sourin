# Agent Note: Serialized UI Preference Writes

Status: implemented

## Problem

The mounted danmaku workflow repeatedly found malformed scratch preference
JSON when the scheduled flush overlapped a source-control explicit flush.
The original UiPrefs.flush cleared dirty before awaiting writeAsString,
returned early to a concurrent clean caller, and allowed newer dirty data
to start a second write to the same file.

This concerns shared preference persistence, not a proven explanation for
Owner source loading or the original playback failures.

## Decision

One in-flight future owns writes before the first asynchronous file operation.
All flush callers join it; the owner drains newer dirty snapshots serially.
Each write captures its file and generation. Setters remain synchronous.

Keep the 300 ms coalescing policy with a cancellable Timer. Explicit flush,
reset, and load cancel pending scheduling. Reset does not discard an existing
write owner. Load waits for that owner and rejects obsolete read results.
Preserve the existing missing-file memory behavior and JSON format.

A failed current-generation write remains dirty and completes nonfatally,
without an automatic retry loop. A later flush or edit can retry it.

## Verification

- Actual old-source RED:
  .probe/ui-prefs-write-serialization-1106/red-01/receipt.json,
  2 passed, 7 failed. Controlled File futures prove premature flush completion,
  overlapping writes, lost retry state, stale loads, and stale scheduling.
- Same nine tests GREEN:
  .probe/ui-prefs-write-serialization-1106/green-01/receipt.json,
  9 passed, none failed. Standard IOOverrides injects the held File; no new
  production test API or replacement serializer is used.
- Existing preference regressions:
  .probe/ui-prefs-write-serialization-1106/regressions-01/receipt.json,
  43 passed, none failed. Covers update settings, ignore persistence, volume,
  both exit-flush paths, and home-source catalog failures.
- The real temporary-file test verifies valid shorter JSON and reload.
  It does not deterministically reproduce OS-level overlapping corruption.
- Root reviewed the production diff and actual RED/GREEN/regression receipts.
  Each phase kept source hashes unchanged and used an isolated profile.
- Final mounted danmaku scenario:
  .probe/native-danmaku-1106/offline-v17/sandbox/mounted-result.json,
  all nine stages pass with this source and without preference sleep workarounds.
  Native images and provider playback are not part of that offline result.

## Alternatives considered

- Add delays around UI controls. They obscure the shared writer race and do
  not give flush its required awaitable completion semantics.
- Change to another storage package or format. The existing File API supports
  serialized writes without dependencies or migration.
- Retry failures continuously. Persistent disk errors must remain nonfatal
  without a busy background loop.
- Release writer ownership during reset. The old file operation is still
  outstanding; keep ownership until it settles.

## Consequences

Awaiting flush now includes pending writes and the latest dirty snapshot.
Storage failures preserve session memory and retryable state.

This does not provide crash-atomic writes, cross-process locking, native
visual acceptance, or evidence that Owner preferences were corrupted.
No Owner preference file was read, repaired, or rewritten.

Related: [Explicit PlayRequest Fails Closed](2026-11-06-explicit-playrequest-fails-closed.md).
