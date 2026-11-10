# Agent Note: Preserve queries through stream child routing

Status: implemented

Applies from 2026-11-10 to local /p and /s child requests.

Related decision: [cover/API routing](2026-11-10-cover-global-proxy-routing.md)
keeps cover and media proxy policy separate. This fix retains that policy.

The proposed/implemented/rejected note audit found no prior owner of raw child
query forwarding. HLS duration and homepage query redaction concern different
contracts and remain unchanged.

## Problem

Playlist rewriting kept query strings, but Axum Path extraction omitted them at
the receiving route. Signed segment/key requests reached upstream without their
query. The relative /s child route had the same omission. Registered root URLs
retained their own query and were not affected.

## Decision

Extract RawQuery alongside Path and append it unchanged to reconstructed /p
URLs and relative /s child URLs. Preserve percent escapes, repeated keys, empty
values and literal plus signs. Root /s requests continue to use the registered
URL; they do not replace its query with an unregistered client query.

## Alternatives considered

Parsing into a query map loses ordering, repetitions and byte representation
used by signatures. Changing playlist rewriting alone cannot recover a query
that the receiving route discarded. No global proxy change is necessary.

## Consequences

A real HTTP proxy fixture serves an HLS playlist through the production wrapper,
follows its rewritten key and segment URLs, and records actual upstream URI and
headers. Before correction the expected signed key query was absent. The fixed
case also checks relative /s requests, an unsigned child and the registered root
query. A direct-origin trap verifies all requests use the configured proxy.
This explains a concrete class of playback rejection, not every external-player
error. Build/native validation is recorded separately in the implementation plan.
