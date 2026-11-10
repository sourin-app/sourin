# Agent Note: Conditional progress metadata backfill

Status: implemented

Applies from 2026-11-10 to asynchronous title and cover backfill for existing
progress records.

This complements [library cover recovery](2026-11-08-library-cover-lifecycle.md)
and [expired-cover refresh](2026-11-10-expired-library-cover-refresh.md). Those
decisions own cover discovery and conditional cover repair. This decision owns
late title-backfill results competing with a refreshed playback row or repaired
cover. The note audit found no existing decision covering that competition.

## Problem

Detail lookup captures a progress record before awaiting the source. During that
wait, playback or library cover repair can refresh the same record. Replacing
the current row with the old record plus new metadata rewinds playback fields
and restores an older cover. The old default writer also calls `save_progress`,
which upserts old playback fields, changes the ordering timestamp and appends a
history entry. Fixing the frontend merge alone leaves that database path unsafe.

## Decision

Return an explicit `ProgressMetadataPatch` carrying the captured record and new
title/cover. It is not a replacement playback row. Merge only an existing exact
key and identity, retaining all current playback and ordering fields. Title and
cover compare their captured values independently. Fill a title only while it
still equals the captured blank title; replace a cover only while it still
equals the captured cover. Missing or blank candidate metadata never clears a
field. Removing a record while lookup is pending does not reinsert it.

The default writer calls `patch_progress_metadata` with provider, native ID,
episode ID, expected title/cover and candidate title/cover. Expected null covers
and null episode IDs are explicit. The command must update only an existing
episode row with the same field-level conditions. It must preserve position,
duration, completion, episode metadata and ordering, and must neither insert a
row nor append history. The Rust owning implementation normalizes expected and
candidate cover display wrappers through the existing durable-cover boundary.
Ordinary playback still uses its existing progress-saving command.

Keep the current no-network-on-render, bounded detail concurrency and per-session
attempt deduplication. A failed detail or metadata write leaves the current list
intact. The pure `withBackfilledMeta` copy helper remains available; asynchronous
results and merging use the explicit metadata patch.

## Verification

The coordinating baseline run of `progress_backfill_concurrency_test.dart`
produced two intended failures and two passing controls. A current position of
1998 became the captured 45, and an already repaired cover became the old URL.
The unchanged-record and removed-record controls passed. Evidence is retained in
`.probe/parallel-astra-1108/native-verify-v51/v52-source-backfill-red.log`.

The original behavior assertions remain. Added controls check independent title
and cover conditions, blank candidate artwork, and the actual default writer's
FFI command and payload, including explicit nulls and absence of playback
fields. Existing title-backfill cases retain their rendering, failure, dedup and
concurrency assertions with the explicit patch fixture. The coordinating agent
ran seven new Dart cases and seventeen existing title-backfill cases successfully.
The real-database baseline through the old save command produced five behavioral
failures and two passing controls. The dedicated command then passed thirteen
metadata/FFI cases with the original database assertions retained. Related
argument, write-command, store and cover suites passed; one pre-existing store
case remained ignored and was not counted as validation. All Cargo runs kept
source hashes unchanged. The command uses one UPDATE with independent field
comparisons, preserves unknown current fields, resolves cover wrappers through
the durable-cover boundary and refuses to reinterpret an expired expected
wrapper as an expected null cover.

## Alternatives considered

Merging metadata into the latest Dart row alone preserves the visible list but
still lets the old upsert overwrite the database. Reusing `save_progress` with
freshly reread fields introduces another race between that read and its write
and still changes history/ordering. A dedicated conditional database operation
owns the atomic decision.

Discarding the whole patch whenever either field changed would lose a useful
title when cover repair finished first, or lose a useful cover when the title
changed first. Independent field comparisons retain both kinds of progress.
Hiding the captured baseline in a `Progress` subclass obscures whether a value
is a row or an update; the explicit patch preserves that distinction.

## Consequences

Delayed metadata cannot rewind the frontend playback snapshot or undo a newer
cover. Atomic persistence is verified at the database boundary separately from
the pure Dart merge. These tests establish record preservation and command
wiring; they do not prove that an external source supplies valid artwork or that
a particular native placeholder has recovered.
