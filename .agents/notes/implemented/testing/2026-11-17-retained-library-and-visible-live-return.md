# Agent Note: Retained library and actual visible live restoration

Status: implemented

Applies: 2026-11-17, product inputs at `6bb7e49` and subsequent test/document-only commits.

Related: [Current UI and default close callback verification](2026-11-16-current-ui-default-close.md)
and [actual detail/library page contracts](2026-11-17-detail-follow-behavior-contracts.md).
The existing library loading and live membership decisions remain in force;
this note qualifies their native observations without changing product behavior.

## Problem

A selected live row and native dimensions can coexist with a black return
screenshot. A cold library fixture can also report success while merely
recreating its records. Both observations need independent rendered and
persistent-data checks. The prior live observer additionally requires a new
playlist request, although same-URL restoration resumes the existing handle.

## Decision

Reuse the exact task profile and package in a fresh process without reseeding.
Read the actual core favorites, following and progress rows. Require two exact
provider/native identities, stable ordering, creation/update times, selected
episode identities and at least eight seconds of progress before and after
reading the three actual library subtabs. Every visible poster must have a
decoded image. Require two exact task cache entries with decoded covers and
unchanged local episode paths. No player may mount during this cold recovery.

For live restoration, use the original visible channel callback and original
navigation callback. Observe pause while hidden, unchanged channel/provider
and player identities after return, muted native playback and advancing
progress. Capture successive complete windows and independently compare a
video-only rectangle. Two nonblack pictures must contain changing pixels and
advancing timestamps. Retain every initial black attempt. Keep actual playlist
and segment requests in the ledger, but do not require needless same-URL
playlist refetch as a prerequisite for restoration.

Rehash all package files, actual loaded package modules, consumed build inputs,
the copied prelaunch profile, scene helpers and screenshots. Independently
check normal exit, exact window removal, raw errors and eight seconds of empty
owned Job membership. Mutated evidence must fail on lost progress, changed
order, missing decoded cover, wrong channel, black/still return or forced exit.

## Alternatives considered

Selection-only or decoder-dimensions-only checks accept black rendered output.
Preseeding a new library hides cold persistence failures. Requiring a new
playlist request forces an implementation detail unrelated to preserved media
ownership and contradicts ordinary resume of the same stream. Discarding the
initial black pictures hides actual startup latency.

## Consequences

The actual cold successor preserves two records, both eight-second progress
values and all three original subtab orders, plus two decoded cache covers.
The prior setup scene stays failed; only its observed persisted records and
the successful cold successor are accepted. The complete native UI batch
separately qualifies delayed comments, exact binding and late live selection.

The live successor restores channel 55 and the same native player. The final
pair changes 136733 video pixels; two earlier fully black captures remain.
Both new processes exit zero and retain natural empty Job membership for
8.0251791 and 8.0105996 seconds respectively. Raw Flutter, native crash,
accessibility-tree and layout-overflow counts are zero. The independent audit
rejects all seven altered controls.

Evidence is retained in
`.probe/goal-resume-20261115-evening/TAKEOVER_LIBRARY_LIVE_20261117_AUDIT_V1.json`.
The fixture repeats a short HLS sample, so global timestamp monotonicity and
full-film playback are unqualified. This is cold-process restoration using
retained caches, not cold-disk-cache acceptance. Ordinary default-focus
startup, rendering performance and whole-delivery acceptance stay separate.
