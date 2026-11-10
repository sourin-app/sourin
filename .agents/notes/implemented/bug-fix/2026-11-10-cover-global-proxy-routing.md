# Agent Note: Covers follow the global API proxy policy

Status: implemented

Applies from 2026-11-10 to library display covers and streamproxy forwarding.

This extends the [existing proxy propagation decision](2026-10-17-plugin-http-ignored-per-source-proxy.md) to display images. It preserves the [library cover lifecycle](2026-11-08-library-cover-lifecycle.md); request routing and stored cover identity remain separate responsibilities. Neither prior decision is superseded.

## Problem

Registered cover URLs used the video client. With ApiOnly selected, that client
correctly bypassed the proxy for media but incorrectly bypassed it for covers.
Sources without declared cover headers returned their original URL, bypassing
core policy altogether in the Flutter image loader.

## Decision

Carry a cover/media purpose from token lookup to forwarding, including the
relative proxy route. Cover requests select the current global API client with
automatic decompression disabled; response headers and bytes remain consistent.
Video, HLS, prefetch and legacy no-store routing keep their existing behavior.
All remote display covers are registered, including no-header sources. Persisted
library data still uses original URLs; stable display tokens retain image caching.
A failed loopback startup does not return a raw direct HTTP fallback.

Because wrapping hides the original CDN host from Flutter, resolve its existing
exact-host Referer/User-Agent defaults before registration. Explicit provider
headers override defaults case-insensitively. Local/data image URLs remain intact.

## Alternatives considered

Treating ApiOnly as All would change video routing. Wrapping only while a proxy
is enabled would leave already-rendered covers on the old route after settings
change. Retrying the same raw URL cannot fix policy.

## Consequences

A local origin/proxy test first fails on the old registered-cover path, then
checks live proxy changes, bypass, direct mode, connection reuse, source headers,
video control and no direct fallback on a failed proxy. A second failing test
uses real library/detail commands without source headers; the repaired path
fetches the proxy's PNG while the direct origin serves a transparent sentinel.
The library suite passes 13 cases, including durable data, restart, header
isolation, CDN defaults/overrides and preservation of progress/history metadata.
Final stream, build and native evidence is recorded in the implementation plan.

This fixes routing, not unavailable upstream images. HTTP errors, expired remote
URLs, and cold startup performance need separate evidence. No cloud account
operation is authorized by these tests.
