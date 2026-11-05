# Agent Note: Live Danmaku Settings And Search Generations

Status: implemented

## Problem

Actual advanced-slider callbacks updated host values and scratch preferences
but left the mounted settings dialog's sliders and readouts unchanged.
The quick-panel setters deliberately do not rebuild the whole player.

Separately, Bili search compared only a panel token which unified search
did not advance on episode changes. Old results could reappear after a switch.
The enabled diagnostics search action also allowed overlapping requests:
an older completion replaced the newer result within the same episode.

## Decision

Subscribe the advanced dialog to the existing quick-values notifier and copy
its four live display fields into the current settings snapshot. Leave the
setters, persistence, quick panel, and overlay wiring unchanged.

Bili search captures play-session generation and danmaku fetch token as well
as the existing panel token. Reject stale success and both error paths, clearing
loading/error/results for the current obsolete request.

One search serial rejects superseded requests before any result, error, or
stale-clearing mutation. Do not alter media playback or binding storage.

## Verification

- Qualified untouched-slider RED and same-input immediate GREEN:
  .probe/native-danmaku-1106/offline-v4 and offline-v5. The first actual
  advanced-slider callback followed by a zero-time frame exposes the stale
  mounted slider and readout; all four corrected callbacks pass.
- Qualified episode-switch RED:
  .probe/native-danmaku-1106/offline-v14/sandbox/mounted-result.json.
  Both replies are held while E2 is active and Bili has zero results/loading.
  Releasing the old reply displays its unique title. Actual E2 comments remain
  correct, isolating search-state contamination from comment playback.
- Qualified overlapping-request RED:
  .probe/native-danmaku-1106/offline-v15/sandbox/mounted-result.json.
  The actual diagnostics action first displays the newer unique title; releasing
  the held old reply replaces it. No preference workflow is involved.
- Final complete offline GREEN:
  .probe/native-danmaku-1106/offline-v17/sandbox/mounted-result.json.
  All nine stages pass, including settings/persistence/reopen, both search
  channels, actual single-menu binding, user-confirmed swapped batch mapping,
  overlapping searches, and delayed search/comment completion across episodes.
- Sixty changing actual quick-slider callbacks cause zero whole-player builds.
  Instrumentation controls report idle zero and positive-control one build.
- Root reviewed final source and actual pre/post observations. Production,
  mirrored source, and test-module hashes remained unchanged through completion.

## Alternatives considered

- Add whole-player setState to slider setters. This breaks the established
  quick-drag rebuild invariant; subscribe the affected dialog instead.
- Compare only the panel token. It does not identify the unified search's
  active episode or distinguish overlapping requests.
- Clear state for any old reply. A superseded completion must not erase the
  newer request's result; reject its serial before clearing.

## Consequences

Advanced settings reflect actual live values without rebuilding PlayerPage.
Obsolete Bili searches cannot overwrite current search results.

The final run uses real mounted production widgets/callbacks with lower fake
transports, scratch preferences, and no media open. Named captures are not native
screenshots. Native interaction, pointer dragging, provider playback, and final
package acceptance remain pending.

Related: [Serialized UI Preference Writes](2026-11-06-ui-prefs-serialized-flush.md).
