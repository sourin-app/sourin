# Agent Note: Automatic danmaku no-match is a search notice

Status: implemented

Applies from 2026-11-09 to ExternalDanmakuClient and the player quick panel.

## Problem

A successfully decoded public video can have no corresponding danmaku entry.
Automatic matching and its search fallback reported that as a playback-overlay
failure, including an internal fileName parameter. This looked like playback
failed even though decoded positions continued to advance.

## Decision

Throw a specific DanmakuNoMatch subtype after the existing matching/fallback
chain returns no entries. Keep the exception contract for core callers; its
message contains no file name. The player clears obsolete match/error metadata,
records a neutral empty status, and shows it next to the direct search field in
the existing Miuix quick panel. No failure toast is emitted for this outcome.
The normal empty badge still expires. Request errors retain their existing
handling, including actionable authentication feedback and session guards.

## Alternatives considered

Matching localized exception text would couple behavior to wording. Returning
an arbitrary empty success from the core would hide the distinction from callers
that need to know matching failed. Suppressing all errors would hide real outages.
Adding another modal would obstruct playback and duplicate the search entrance.

## Consequences

A mounted-player test drives the real load path through successful empty HTTP
responses, checks both matching and fallback requests, then opens the actual
quick panel and inspects the visible notice and search entry. The old behavior
fails; the new behavior passes. A 403 control retains its error and toast.
The related binding/session suite passes 21 native-media cases. The first run
without --run-skipped skipped the suite and is not validation; an initial control
cleanup needed its toast timer to expire. Verified red/green runs are separate.
Native public-video verification and final suite results are recorded in the
implementation plan.

The related [search-error privacy note](2026-11-07-danmaku-search-error-display-privacy.md)
remains in effect. This change classifies a successful empty match; it neither
removes transport details nor grants account or cloud-file authorization.

The final combined protocol/player/home suite passes 109 cases. Native playback
advances at 1280x720 while automatic matching finishes empty, with neither a
danmu error state nor a failure toast. The first native image exposed inherited
light-theme text on the dark quick panel; reusing PopoverGroupLabel fixes its
contrast and the reopened panel image was inspected. The source line is updated
once when the request starts, so all outcomes preserve the same actual route.
