# Agent Note: Actual TVBox updates refresh live attribution durably

Status: implemented

Applies on 2026-11-11 to TVBox check/update and source catalog version 1.
Extends [live parent provenance](2026-11-11-tvbox-live-parent-provenance.md),
which records import attribution separately from playlist address ownership.
The [subscription update clock](../feature/2026-10-31-tvbox-source-update-time.md)
retains its success/failure and conservative deletion policy.
[Miuix source controls](../feature/2026-11-08-miuix-source-discovery-and-search-controls.md)
retain the real dialog and API command route. None of these decisions is retired.

## Problem

Import records live descendants, but actual subscription detection and update
ignore lives. A changed live list with unchanged VOD is reported as unchanged.
Refreshing by reimport bypasses user update choices and does not prove the
manual or scheduled command path. A first candidate also publishes provider
rows before their providers-file save, so failed persistence changes memory,
retries can report success without disk state, and bootstrap loses the row.

## Decision

Check reports an independent live preview without applying provider rows or
membership. Both update branches apply that same live plan. New means new to
this parent, including an already registered foreign/shared playlist.
applyNew=false neither registers new playlists nor adopts foreign playlists.
A removed live entry detaches this parent's attribution and never deletes the
independent playlist provider. deleteMissing remains a VOD-only opt-in.

Existing live implementations, names, caches, addresses, fallback success and
disabled choices remain with their independent owners. Shared playlists keep
other parents. Membership is reconciled against real registered live rows and
provider invalidation follows applied changes.

New persisted rows are cloned and staged while holding the third-party write
lock. The real providers file is saved before committing memory and publishing
new registry providers. A save error leaves those memory/registry rows unchanged.
This avoids whole-list rollback that could overwrite unrelated concurrent work.
Provider-file save and parent-catalog save are separate persistence boundaries;
this change does not claim a transaction spanning both files or old VOD updates.

Additive JSON fields distinguish live additions, removed attribution, unapplied
entries and membership changes from VOD outcomes. Old responses default to empty
live fields. The real update dialog and direct manage panel explain the default
addition policy and VOD-only deletion. Check summaries expose live-only changes,
including the application controls. Both updated and unchanged result views
render real live outcomes. A removed attribution says playlists are retained;
actual deletion text is used only for an explicit liveDeleted response.

## Alternatives considered

- Reimport on refresh: import-side attribution and settings bypass the existing
  update flags and stable VOD identity.
- Put live rows in VOD result lists: playlist URLs are not site APIs and detached
  parent attribution does not imply deletion.
- Publish then roll back the entire provider list: failed saves expose state and
  concurrent unrelated changes could be lost during rollback.
- Change an existing shared playlist to match the parent row: its address and
  user choices belong to the independent live owner.

## Verification

Four unchanged baseline core tests fail at actual update results and live fields.
The independent persistence fault injects an empty directory at the synthetic
providers temporary-file path. The original candidate fails with six collected
violations through save failure, repair/retry and bootstrap. Corrected production
passes all forty-one source_catalog cases, including those five cases.

Nine independent UI cases exercise raw JSON, the default FFI seam, real
Dialog.show, rendered check gate, switch interactions, application, outcomes and
close notification. The current-product baseline has six intended failures and
three existing VOD controls. Corrected production passes all nine and the final
related subscription/aggregate/provenance combination passes forty-six cases.
The wider run and paired baseline retain two inherited UI guards; an introduced
fixed-window guard mismatch is fixed in the owning summary expression while
its original assertions remain unchanged. No skip or assertion is removed.

Fresh serial checks use synthetic isolated storage, one build worker, two CPUs
and below-normal priority; before/after source snapshots are immutable. Fixture
setup/compiler errors are excluded from behavior evidence. Rust formatting and
minimal Dart formatting preserve frozen fixture inputs and assertions. Exact
analysis and related-core results are recorded in the current implementation plan.

## Consequences

The actual VOD-representative check/update route now handles live changes without
resetting independent owners or pretending failed provider persistence succeeded.
[Exact parent routing](2026-11-11-tvbox-origin-refresh-identity.md) extends
manual refresh and check-all to zero-VOD parents. This membership decision alone
does not prove pure-live scheduling, native UI,
external service interoperability, decoder/audio or Owner acceptance.
