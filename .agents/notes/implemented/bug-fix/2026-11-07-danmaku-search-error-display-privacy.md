# Agent Note: Display-only privacy for danmaku search errors

Status: implemented

Applies to DanmakuSearchPage from 2026-11-07. Extends the
[selected-file and playback privacy contract](2026-11-05-selected-file-session-handoff-and-playback-error-privacy.md).

## Problem

Five search error displays render raw exceptions or response bodies, which can
contain signed URLs, authorization headers or cookies. Sanitizing playback
errors alone does not protect the search panel.

## Decision

Each Text or SelectableText display passes its string through the existing
PlaybackErrorText.forDisplay. Original exception objects and response bodies
remain available to the diagnostic classifier. Channel-specific causes, HTTP
status, selectable results and search/binding callbacks remain unchanged.

## Alternatives considered

Removing diagnostics loses useful causes. Mutating stored exceptions changes
diagnostic inputs. A second sanitizer would duplicate playback privacy rules.

## Consequences

Three production-widget cases cover both hot-path failures and expanded request
body details, including original object identity and useful readable text.
They pass in the 2026-11-08 precommit run. These synthetic tests do not establish
live transport, account access, native screenshot or complete product acceptance.

Related (2026-11-10): [safe detail error facts](2026-11-10-detail-upstream-errors-safe-facts.md)
owns a separate producer boundary; this note retains the search display policy.
