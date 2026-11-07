# Agent Note: Search respects source scope and disabled replacements

Status: implemented

Applies from 2026-11-08. Partially supersedes the list-only behavior in
[aggregate editing](../feature/2026-10-29-aggregate-edit-split-and-note.md), and
extends [edit preference retention](2026-11-07-declarative-edit-preserves-source-preferences.md)
to all registry replacement callers.

## Problem

TVBox-only mode filtered the visible provider list while both search commands
still searched the full registry. The aggregate's empty selection expanded to
all enabled providers, including unimported hidden built-ins. An explicit
selection whose members became disabled could also expand silently. Provider
replacement installed a fresh enabled handle, allowing disabled sources to
search again after reload or subscription updates.

## Decision

Both search commands share a scoped registry containing only the enabled
aggregate in TVBox-only mode. It reuses the production aggregate instance and
its original child registry. Aggregate children must be enabled and have TVBox
import provenance in this mode. An explicit selection never falls back to
unselected sources, even if every selected source becomes unavailable.

Ordinary registry replacement retains the handle's enabled flag, priority and
position. Explicit priority replacement retains enabled state while applying
the requested priority. Persistent enable preferences are not rewritten by
the temporary TVBox-only mode.

## Alternatives considered

Filtering returned results still sends unwanted requests. Disabling every
registry handle disables the aggregate's own children. Treating hidden as
import provenance also admits built-ins. Falling back after an explicit empty
selection contradicts the user's selection.

## Consequences

Five regression cases inspect actual provider calls and returned items through
both production search commands, plus replacement behavior. All five fail at
the intended assertions in a clean pre-fix worktree and pass with the change.
They cover disabled aggregate, missing provenance, disabled/stale selection,
unimported selected sources and restoring normal scope when solo is turned off.
These synthetic tests use isolated data and do not assert live source availability.
