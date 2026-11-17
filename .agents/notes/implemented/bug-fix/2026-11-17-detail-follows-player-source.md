# Agent Note: Detail follows the player's declared source

Status: implemented

Applies: 2026-11-17, DetailPage and the existing MediaPage episode callback.

## Problem

The player can select an episode from a different source while the detail pane
still holds the previous source's filtered episode list. Scrolling that list
cannot find the new episode. A remembered source can also override the player's
current episode during initial detail loading. Concurrent source requests can
replace newer episodes or clear a newer request's loading indicator.

## Decision

Resolve the reported episode's flag from the complete detail catalogue and
accept it only when that identity has one flag and the flag is declared in the
source tree, including nested sources. Initial selection prefers this source
over the saved preference. Later player reports select it and refresh episodes
through the existing getEpisodes call. This observation does not replay media,
invoke line-selection callbacks or persist a browsing preference.

While following a new source, retain that source's known catalogue episodes.
If refresh fails, the pane therefore keeps valid buttons for the selected
source. Each request captures a generation, provider, work and source; obsolete
success, failure and completion cannot affect the current list or loading flag.
Unknown or ambiguous episode identities do not infer a new source. Source-less
catalogues retain the existing full-list behavior.

The actual MediaPage per-provider/per-work key remounts the detail pane across
works. No additional state or transport is introduced in MediaPage or PlayerPage.

## Alternatives considered

- Search only the displayed list: the target source's episode is absent after
  filtering, which is the original failure.
- Parse source names from episode IDs: providers do not share an ID encoding.
- Replay or write preferences when observing a player report: would create a
  feedback loop and change user choices merely while synchronizing the display.
- Keep the old list after a failed refresh: combines old episode IDs with the
  new source code in the next playback request.

## Consequences

Following a new source issues one ordinary episode refresh. A provider whose
detail catalogue omits the reported episode cannot establish a source from this
observation; its previous display is retained instead of guessing. UI acceptance
still requires the original player callback path in a real isolated window.

This extends [direct player controls](../feature/2026-11-08-player-direct-controls.md)
and [detail line filtering](2026-10-30-right-detail-line-filter-and-badge.md).
Their within-list browsing and filtering remain. The
[live progress workflow](2026-11-04-player-progress-and-danmaku-modal-workflow.md)
guards a separate progress stream and remains unchanged. The proposed detail
HTTP-error checkpoint concerns public error privacy, not selection ownership;
the rejected offscreen warmup concerns rendering and is unrelated.

Verification uses real DetailPage widgets and the original get_detail and
get_episodes transport seam. The clean prior commit fails five of the original
eight behavior cases; a separate current-request failure control also fails
before the catalogue fallback is added. No fake native playback is inferred
from widget results.

The stale-failure case reads the actual loading placeholder as well as episode
content. Removing only the completion guard in an isolated copy fails both
stale-success and stale-failure cases (seven pass, two fail); the full current
focused suite passes 65 cases. The current native UI also follows the selected
source and episode through real playback, settings, return and normal quit.
These scoped results do not imply whole-repository or whole-package acceptance.
