# Agent Note: Retry resume ownership and display-only tip privacy

Status: implemented

Applies to PlayerPage from 2026-11-07. Extends
[user-seek ownership](2026-10-23-player-user-seek-future-and-route-exit.md) and
[playback display privacy](2026-11-05-selected-file-session-handoff-and-playback-error-privacy.md).

## Problem

An older resume waiter can seek while a retry resolves a replacement stream.
Repeated retry can also prefer consumed stored progress over the current
positive in-memory position. TipBubble exposes raw signed fields even though
the main error display sanitizes them.

## Decision

_load advances the seek epoch before stream resolution. _seekAfterReady exits
its wait when that epoch changes and retains the final ownership check.
Positive in-memory progress takes priority over the once-per-session stored
resume guard. Stored history is not reread after a session has resumed.

TipBubble sanitizes only rendered text. Raw tip identity, replacement behavior
and the 1200 ms timer remain unchanged. OPS13 widget callbacks unmount and drain
pending timers before returning; assertions and shared failure cleanup remain.

## Alternatives considered

Canceling after resolution leaves an obsolete-seek window. Rereading history
on each retry can overwrite newer memory. Sanitizing the stored tip changes
timer identity. Suppressing pending-timer assertions hides fixture leakage.

## Consequences

Regression tests observe actual resume calls, pending resolution and visible tip
text. The isolated 2026-11-08 native-tag run passes 19 cases including retry,
progress transitions, selected-file handoff and OPS13. Native initialization and
synthetic requests do not prove live media playback or upstream reliability.
