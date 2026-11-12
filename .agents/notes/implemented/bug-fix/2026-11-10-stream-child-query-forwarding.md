# Agent Note: Preserve queries through stream child routing

Status: implemented

Applies from 2026-11-10 to local /p and /s child requests.

Related decision: [cover/API routing](2026-11-10-cover-global-proxy-routing.md)
keeps cover and media proxy policy separate. This fix retains that policy.

[Stream header FIFO ownership](2026-11-12-stream-header-fifo-ownership.md)
keeps each retained stream's child header token alive through capacity eviction.
That lifetime contract partially overlaps at the child route and leaves URI and
redirect forwarding unchanged.

The proposed/implemented/rejected note audit found no prior owner of raw child
query forwarding. HLS duration and homepage query redaction concern different
contracts and remain unchanged.

## Problem

Playlist rewriting kept query strings, but Axum Path extraction omitted them at
the receiving route. Signed segment/key requests reached upstream without their
query. The relative /s child route had the same omission. Registered root URLs
retained their own query and were not affected.

Redirects may move playlists into a different directory. Rewriting relative
children against the registered entry sends them to the wrong location. Default
HTTP redirect handling also replaces a source-supplied Referer with the preceding
media URL, so requests no longer carry the source's declared playback headers.

## Decision

Extract RawQuery alongside Path and append it unchanged to reconstructed /p
URLs and relative /s child URLs. Preserve percent escapes, repeated keys, empty
values and literal plus signs. Root /s requests continue to use the registered
URL; they do not replace its query with an unregistered client query.

Each playlist resolves child addresses against its final response URL, including
nested playlists that redirect again. Recognition accepts the final HLS extension
for extensionless entries served as application/octet-stream, while retaining
original-extension and content-type recognition. Media clients preserve the
source-supplied Referer across redirects instead of generating a new one. Direct,
configured-proxy and compatibility clients share this header behavior; routing,
timeout budgets and redirect-sensitive credential stripping remain unchanged.

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

Real HTTP redirect fixtures follow both playlist hops, keys and segments and
check exact upstream paths, signed queries, declared Referer and zero requests
to a direct-origin trap when a proxy is configured. They also cover configured
direct routing and the compatibility client. Entry-directory and extensionless
cases fail before the URL correction; the header assertion independently exposes
the default redirect Referer replacement. These local regressions do not establish
remote media availability or native playback acceptance.

A two-host loopback regression uses distinct literal hosts for the actual
redirect, checks source User-Agent and Referer on both requests through the
ordinary Direct/All store, and observes automatic Referer replacement with a
default-client control. It preserves the existing routing and credential rules.
