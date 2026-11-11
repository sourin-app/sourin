# Agent Note: Live membership refresh notifications drain serially

Status: implemented

This extends the [live list and cold-start contract](../feature/2026-10-18-live-channel-groups-and-cold-start.md)
and [channel selection ownership](2026-11-11-live-channel-selection-ownership.md).
The [fullscreen return owner](2026-11-11-live-return-playback-ownership.md)
continues to own returned playback intent. Their snapshot, selection and native
command decisions remain in force; no earlier note is superseded or archived.

## Problem

The retained live page receives membership refresh requests from tab activation
and the return from source management. A request already in progress can contain
the membership from before a subscription change. Dropping every subsequent
request leaves those removed channels visible after the source manager returns.
The dropped caller also finishes before the accepted membership is fetched.

Avoiding simultaneous full-list requests is necessary: concurrent responses can
replace each other's groups and initiate competing stream resolutions. It does
not justify discarding the notification that membership has changed.

## Decision

As of 2026-11-11, `LivePageState.loadAll` returns a shared completion future for
a serial drain. Each call contributes a pending selection policy. A running
load consumes its own pending policy before awaiting membership; notifications
received during that load coalesce into one following load. Notifications that
arrive during that following load can request a later load, so a change is not
discarded merely because the drain already performed its first continuation.

A pending explicit `keepSelection:false` dominates preserving notifications in
the same coalesced load. This retains the existing source-management reset
policy when a subsequent tab activation requests selection preservation.
Each worker otherwise uses the existing latest-selection restoration, exact
provider/native identity, fullscreen handoff and stream-request ownership.

All callers wait for the drain to become idle. An ordinary membership failure
is still displayed by the existing worker; a queued successful load can clear
that failure. Disposal prevents another queued request from starting and clears
the pending policy when the active request finishes. The already started core
request is not cancelled. One request without later notifications causes no
additional read. Health probing and disk-cache persistence keep their existing
separate policies.

## Alternatives considered

Allowing parallel full-list requests reintroduces competing publication and
stream selection. Returning the current future without recording a pending
notification fixes early completion but still loses membership changes.
Starting one additional request per caller unnecessarily repeats full plugin
enumeration. Permitting only one continuation for the entire drain loses a
subscription change received during that continuation.

## Consequences

The exact clean e232175 baseline with the final frozen six widget cases has four
intended failures and two controls. Actual raw core requests are held at their
response boundary; the tests inspect rendered channel rows, selected semantics,
the embedded stream and caller completion. They cover coalescing, active-load
failure, a notification during a continuation, reset policy, disposal and a
single-request control. The final twenty-suite combination passes all 152 cases.
The expanded run initially has 151 passes and one obsolete source-text guard
that requires cross-provider ID fallback. Its replacement inspects actual
selection and stream identity for preservation, reset and provider removal.
The clean baseline passes that behavioral guard; an isolated omission of the
real selection restoration fails at the rendered B-versus-A row assertion.
The original source bytes are restored after that fault run. No native decoder
is constructed by these fixtures.

A sustained stream of notifications can keep the shared completion pending;
membership reads remain serial and coalesce only notifications received before
the next load starts. A bounded one-follow-up policy would be appropriate only
with a separate durable membership revision that proves later changes are
already represented. External source availability, native audio/video, desktop
frame times and complete-package binding require separate acceptance.
