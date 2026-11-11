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

The Flutter image loader reaches strict loopback URLs through a separate lazy
client, because another ambient HTTP proxy must not intercept the app's local
cover wrapper. Exact localhost and parsed loopback IP addresses qualify;
lookalike hostnames do not. The local client's proxy callback rechecks each URI:
loopback is DIRECT, while a remote redirect uses the SDK environment policy.
Initial nonloopback images retain their original client, including any custom
HttpOverrides proxy policy. Connection/body deadlines, header handling and image
decoding stay unchanged. This frontend hop does not change the core's configured
cover-origin route.

Because wrapping hides the original CDN host from Flutter, resolve its existing
exact-host Referer/User-Agent defaults before registration. Explicit provider
headers override defaults case-insensitively. Local/data image URLs remain intact.

Failed cover responses emit one bounded `COVER_FAILURE` record at the actual
forwarding response boundary. Its closed schema contains received status, final
response scheme, a known HTTPS-only marker classification, proxy-header presence
flags and conservative attribution. It contains no URL, token, username, raw
header value or body. It borrows the existing response without another request,
retry, protocol rewrite or body read. An exact known marker on a 403 is only a
proxy-advertised block, not authenticated proof of who generated the response.
Unknown/duplicate marker values and generic Via/Proxy-Status headers do not
upgrade attribution. Media failures and successful covers do not emit this
cover-specific record; client selection and routing policy are unchanged.

## Alternatives considered

Treating ApiOnly as All would change video routing. Wrapping only while a proxy
is enabled would leave already-rendered covers on the old route after settings
change. Retrying the same raw URL cannot fix policy.
Setting the original shared client globally DIRECT would also bypass unrelated
remote image policies. Leaving a local client permanently DIRECT would let a
redirect escape the remote proxy policy. Separate initial selection and per-URI
redirect evaluation preserve those boundaries.

## Consequences

[Completed HTML repair evidence](2026-11-11-html-cover-recovery-after-save.md)
uses this existing image route; it does not alter proxy ownership or diagnostics.

A local origin/proxy test first fails on the old registered-cover path, then
checks live proxy changes, bypass, direct mode, connection reuse, source headers,
video control and no direct fallback on a failed proxy. A second failing test
uses real library/detail commands without source headers; the repaired path
fetches the proxy's PNG while the direct origin serves a transparent sentinel.
The library suite passes 13 cases, including durable data, restart, header
isolation, CDN defaults/overrides and preservation of progress/history metadata.
Real local HTTP fixtures observe the registered cover request, actual final
response arguments and emitted JSON. They cover known/unknown markers, spoofed
headers, privacy, error bodies that never complete, and success/media controls.
The missing diagnostics fail on the clean prior commit. These observations do
not establish recovery of a remote cover. Final stream, build and native
evidence is recorded in the implementation plan.

The Flutter environment-policy regression mounts the real coverImage, decodes
actual local PNG responses and counts requests at an origin and proxy trap.
The qualified baseline has three intended failures and two passing controls:
IPv4/localhost wrappers and a local-to-remote redirect reach the trap instead of
the local origin, while two nonloopback hosts correctly retain proxy routing.
One control is a loopback-looking nonloopback hostname. Evidence is retained in
`.probe/parallel-astra-1108/native-verify-v55/cover-proxy-red-v3.log`.
The fixture supplies a proxy-environment map to the public HttpOverrides method,
which delegates to the real SDK parser; it does not mutate the client findProxy
property or claim a changed process environment. The earlier process-environment
attempt intercepts the test listener before loading and is disqualified. A later
cross-case connection stall is repaired by closing fixture response connections;
all five rendering/count assertions retain their original bytes. The qualified test file is unchanged for GREEN
(SHA256 c6235c8693148f581691dff29447a83c0728cb411cfda35d67f12b964ef5aace).
All five cases plus existing headers, timeouts, retry, cover sizing and library
recovery regressions pass together: 32/32 with concurrency=1. Targeted analysis
reports no issues. Native confirmation uses a fresh process and fresh wrapper
URLs; the preceding old-generation URLs are not current-cover evidence.

This fixes routing, not unavailable upstream images. HTTP errors, expired remote
URLs, and cold startup performance need separate evidence. No cloud account
operation is authorized by these tests.
