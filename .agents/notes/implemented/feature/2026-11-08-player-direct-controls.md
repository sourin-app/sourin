# Agent Note: Windowed lines and first-level danmaku search

Status: implemented

Applies: 2026-11-08, product MediaPage and PlayerPage.

Follow-up: [focused panel lifetime](../bug-fix/2026-11-08-player-popover-focus-lifetime.md)
keeps the search draft open while editing and handles Escape inside the panel.

Partially supersedes [right detail line filtering](../bug-fix/2026-10-30-right-detail-line-filter-and-badge.md): the pane now has an explicit line selection control; episode filtering and counts remain. Partially supersedes [danmaku search boundary](../bug-fix/2026-10-23-danmaku-settings-search-boundary.md): the entry moves to the first floating panel, while the independent search page and single request/binding state remain. The search layout, draft/diagnostics, feed defaults and remote episode filtering notes were audited and remain unchanged.

## Problem

Windowed playback hides route choices behind other controls. Danmaku search requires opening advanced settings despite being a frequent action. Duplicating either resolver or search state would make the shortcut behave differently from the existing operation.

## Decision

DetailPage lays out all episode flags in the shared wrapping source picker. Selecting a flag updates the browsed episode list and invokes the optional MediaLineSession capability through MediaPage. PlayerPage delegates to its existing matching/position-preserving line-switch path. A new reported current episode clears the browsing override. Single-line filtering and the full episode array retain their previous semantics.

The first danmaku floating panel exposes the current keyword, a search button, Enter submission and a search-page entry. Empty input does not submit; submitted input is trimmed. The host opens its existing DanmakuSearchPage with the same draft and requests. Back returns to the floating panel. The advanced production settings no longer expose this entry.

## Alternatives considered

- Show line names without forwarding the action: changes the highlight while playback stays on the old line.
- Build a second shortcut resolver/search client: creates separate selection, resume and binding state.

## Consequences

Legacy session implementations need not implement line switching. The current product player does. Missing matching episodes retain the established fallback behavior. Reconsider separate browsing state if a future detail-only interface needs a persistent line choice across works.

Verification: the focused 35-test UI suite includes route filtering and the floating panel's Enter/button/empty-input behavior. A native MediaPage/PlayerPage fixture observes the actual serialized request change from a2 to b2, preserving episode number 2. The same test on clean 2b9410e fails because Line B is absent. This native fixture skips mpv open and does not establish decoding or real network danmaku search.
