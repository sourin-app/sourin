# Agent Note: Reset displayed progress when playback media changes

Status: implemented

Applies to PlayerPage from 2026-11-07. Extends the
[player progress workflow](2026-11-04-player-progress-and-danmaku-modal-workflow.md).

## Problem

Three media transitions reset _position without updating its display notifier.
The next subsecond tick compares against the already-reset position, leaving
the previous episode timestamp and slider visible until the next whole second.

## Decision

_gotoEpisode, applySession and _applySwitch reset _positionNotifier alongside
_position. Same-session metadata updates preserve progress. Existing progress
throttling, native player reuse and resume intent remain unchanged.

## Alternatives considered

Waiting for another tick retains stale UI during resolution. Removing throttling
increases rebuilds. Recreating PlayerPage disrupts retained playback state.

## Consequences

Four widget tests observe the rendered timestamp and slider before another tick,
at 200 ms, and after 1200 ms. They also protect same-session metadata updates.
All pass in the isolated 2026-11-08 precommit run. Actual decoded media and the
ordinary product shell require separate acceptance.
