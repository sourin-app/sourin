# Agent Note: Live Player Progress And Danmaku Modal Workflow

Status: implemented

Scope: Flutter playback/detail UI from November 4, 2026, with the pinned
failure continuation guarded from the November 11, 2026 implementation.

## Problem

The embedded detail pane receives the current episode identity, but its resume
chip reads a history snapshot loaded when the pane opens. Position changes and
successful user seeks do not update that snapshot. A later database response can
also replace a newer playback observation.

Danmaku source controls are placed in Advanced while the Sources tab is mostly
navigation. Tab navigation scrolls away. The search form and binding actions
share the results scroll region. Enter bypasses the in-flight button guard,
repeated searches retain manual assignments, and two remote episodes assigned
to the same local episode are silently collapsed by a map.

## Decision

`MediaProgressSession` is an optional read-only session capability. The real
player publishes provider/content/episode identity, consumer generation,
position and duration through a `ValueListenable`. `MediaPage` forwards the same
listenable to its real `DetailPage`; the detail pane subscribes and unregisters
on replacement/disposal. Foreign content and older generations are rejected.
An initial database read cannot overwrite an already observed live session.

Position observations are deduplicated at whole-second precision. User-seek
completion is guarded by the session generation, seek token and position
observation epoch. Its target is used only if no newer native position event
arrives while the seek is pending. Switching episodes does not infer completed
episodes or write synthetic history. Current local-file rows show the observed
ratio; switching local episodes refreshes persisted ratios with request epochs.

The settings tab control remains fixed. The Sources tab contains the genuine
feed controls, and Advanced contains service configuration. The search modal
uses `AppDialogShell` with a fixed query/channel bar, independently scrolling
results and fixed selection/preview/confirmation actions. It has an explicit
return path to the existing settings modal. Single-entry binding remains in
the entry menu, and the local-episode selector remains at the end of the row so
the center of the row still toggles its checkbox.

The search dispatch guard covers both the icon button and Enter. A new query
clears selection, manual assignments and ordering. Equivalent host episode
lists do not clear user work on routine rebuilds. Numeric-title conflicts and
manual local-target collisions both prevent confirmation.

The real player closes the search modal after an accepted single match or a
successfully stored batch. Explicit binding enables danmaku and loads only the
mapped current episode through the existing loader. A batch without a current
episode mapping does not guess one. Duplicate targets/ids and invalid indexes
are rejected before writing; a throwing save call keeps the editor open.
The search page retains its confirmed preview until the host dismisses it.
Comment loading checks the playback-session generation as well as the existing
fetch token. The one-shot selected episode pin belongs to the same generation,
so an old selection cannot leak into the next episode. The pinned failure
continuation checks mounted/session/token ownership before starting its normal
match/search fallback. A newer load, disabling danmaku or unmounting ends that
continuation without additional fallback I/O; a current failure keeps the
existing fallback. These checks do not cancel transport work already in flight
or add cancellation inside ExternalDanmakuClient.loadFor.

## Alternatives considered

- Polling the progress database on every playback tick adds I/O and still
  confuses persistence latency with the current session. Keep persistence on
  its existing path and observe the player directly.
- Adding required members to `MediaSession` forces unrelated implementations
  to implement playback observations. Use an optional capability instead.
- Treating every episode jump as completion invents watched history. A jump
  only resets the current observation until new playback position arrives.
- Keeping all navigation/actions inside the results scroll region avoids a
  layout change but makes repeated searches and confirmation needlessly costly.
- Moving the episode dropdown into the middle of each row makes ordinary row
  taps open a menu. Keep the genuine mapping control at the row end.
- Closing a batch editor before calling the host loses the confirmation state
  when its save is rejected. The host owns successful dismissal.

## Consequences

The detail pane updates independently of the player page. The playback event
is transient and cannot mark whole episodes watched or finished. A legacy
session without the optional capability keeps its existing history behavior.

Binding save follows the existing current-session contract:
`saveDanmakuBind` updates `UiPrefs` synchronously, then persistence is delayed.
The existing `UiPrefs.flush` returns no disk acknowledgement and logs disk
failures internally. This UI change does not detect or promise recovery from
disk-write failures; a disk-acknowledged binding workflow needs a separate
storage-contract decision.

Widget tests cover real production ownership and injected transport boundaries;
they do not establish platform video-texture rendering, physical remote-input
behavior or visual acceptance. The batch requires a combined build/deployment
and physical review by the lead before the user-facing goal can be closed.

Red evidence: the four workflow tests fail against their old production paths;
the two detail-owner tests fail before the observation subscription is wired.
The native owner fixture drives real player duration/position handling and
observes the real detail chip, delayed seek completion and episode changes.
Evidence is retained under `.probe/player-danmaku-ux-*20261104.*`.

The real publisher-disconnection mutation produces three failed owner checks
and one passing settings-navigation check. Removing it restores four passing
native owner checks (`native-restored-green2`). The separate real-player
binding fixture produces four functional failures before the host change and
four passes after it (`binding-host-split-red` / `binding-host-green2`).
The prematurely removed confirmation preview has its own functional red.
The nonnative eleven-file regression bundle passes 71 tests (`regression2`),
including a 360x640 viewport with 1.5x text. Early native startup failures and
test timer/scroll instrumentation failures are retained but do not count as
functional red evidence.

## Relations

[Pinned fallback cancellation](2026-11-11-pinned-danmaku-fallback-cancellation.md)
extends the existing comment-load ownership without changing the progress,
binding-storage, draft, preview or layout decisions below. Its four frozen
mounted-player cases observe transport calls and actual host state. The clean
baseline has three cancellation failures and one current-failure control pass;
the six-line guard passes all four. This is the pinned failure continuation's
I/O boundary, not native decode, pixel, physical input or package acceptance.

Post-review recovery also guards search before its local-probe await and after
the search response with the active playback generation and fetch token. Late
results/errors leave the editor explicitly stale without replacing current
results. Load ownership is reserved before the local probe, so reversed
same-session completions cannot consume a newer selected-episode pin. Manual
binding reads/writes use the active provider/content key after in-place source
switching, not the original immutable widget key.

The real PlayerPage binding fixture produced 4 passed / 7 failed before these
repairs (`playback-ux-player-recovery-red-20261104`), then 11 passed / 0 failed
with unchanged test SHA256 (`playback-ux-player-recovery-green-20261104`). Both
commands observed actual child exit codes. This remains native widget-host
evidence, not actual application visual or account playback acceptance.

The matching-note audit classifies the following as partial overlaps; all are
retained. Only the indicated entry/layout decisions are superseded:

- [Search layout](../feature/2026-10-28-danmaku-search-layout-redesign.md):
  fixed form/actions replace the former all-scroll layout and `_actionSlot`.
  Source attribution, cover rendering, stale-result protection and real row
  selection remain required.
- [Search draft and diagnostics](2026-10-24-danmaku-search-draft-and-diagnostics.md):
  source controls live in Sources rather than Advanced. Session-owned drafts,
  independent searching and expandable diagnostics remain required.
- [Feed defaults and conflicts](2026-10-24-danmaku-feeds-defaults-and-conflicts.md):
  defaults, persistence and explicit numeric conflicts remain unchanged;
  manual local-target collision detection extends those guarantees.
- [Right detail line filtering](2026-10-30-right-detail-line-filter-and-badge.md):
  current-line filtering and honest episode counts remain unchanged. This
  decision addresses progress observations, not line selection.
