# Agent Note: Baidu Share Preconditions And Honest Errors

Status: implemented

Follow-up: [Cookie expiry deadlines](2026-11-04-baidu-request-cookie-expiry-deadlines.md)
retains this request/carry/error decision and adds future expiration checks to
both header and value lookup. The earlier 24-test result remains historical;
the final targeted suite includes all 27 tests.

## Problem

The Baidu resolver puts t/surl in the verify form instead of the official URL
query, drops response Cookie changes between requests, and fails to install
the verified randsk as BDCLND. A normal share containing a login widget is
classified as an expired account. Raw response snippets and transport errors
can also escape into user-facing messages. These defects precede full-file
playback; correcting them does not establish that Baidu playback works.

The prior capability note remains historical context:
`.agents/notes/implemented/feature/2026-11-01-xunlei-baidu-share-direct-link.md`.
This note supersedes its credential-expiry inference and verify-form shape,
without modifying that older note or its frozen evidence.

## Decision

`rust/sourin_core/src/csp/pan_baidu_play.rs` retains the public resolve,
resolve_with and BaiduEndpoints signatures. Requests use structured Url,
query and form APIs. Official verify sends t/bioc=1/surl in the query and
pwd/vcode/vcode_str in the form. The archived boot AJAX metadata supplies
channel/web/app_id/clienttype, page-derived bdstoken and BAIDUID-derived
logid; existing shared base64 code is reused. No dependency is added.

A request-local Cookie store carries Set-Cookie changes through page,
redirect, verify and list requests. Domain, path, Secure and deletion rules
bound propagation. A verified nonempty cookie-safe string randsk replaces
visible older BDCLND keys, including shadowing paths. BDCLND retains the raw
value; sekey uses percent-only decoding followed by structured query encoding,
so literal plus signs do not become spaces. Missing, empty, nonstring or
unsafe randsk stops before listing.

Business endpoints are official HTTPS pan.baidu.com or loopback addresses.
Redirects are same-origin, or the official HTTPS pan/passport family from the
production pan origin, with no third-origin credential forwarding. Requests
have a 45-second total budget, a maximum of five redirects, a 15-second
per-request limit, and a 2 MiB response limit. Cookie changes remain in memory
for this invocation and are not written to the keyring.

Normal share metadata or a verify form prevents login-widget false positives.
A login-only page reports that the current request did not obtain share
information, not that the saved account expired. Missing local credentials
still produce NEED_LOGIN. Other failures expose only fixed stage text plus
integer errno or HTTP status, never response text, URLs or credential values.
Noninteger/missing errno is a schema error, not an invented errno=-1.

Listing success ends at an explicit error: the share file list is obtained,
but complete-file dlink is not integrated, and listing does not prove remote
account validity. No page URL, preview, arbitrary selected file or fabricated
playback result is returned. Full selected-file playback remains incomplete.

## Alternatives considered

- Keep the former browser-symbol expiry inference: it stops obvious login
  pages early, but the same symbols can occur inside valid share pages and
  neither form proves the saved credential's expiry.
- Add a cookie feature/dependency to reqwest: a general browser cookie jar
  supplies broad standards support, but this request-local, single-provider
  correction keeps the existing dependency surface and explicitly limits
  supported origins. Broader browser-session requirements need reevaluation.
- Return a known share preview as playback: the official static selected-fid
  streaming family exists, but its operative 90-second preview and entitlement
  boundary do not prove legitimate full-file media. It is not implemented here.

## Consequences

The verified preconditions are now exercised on the production resolver path,
with in-memory synthetic credentials and actual local HTTP capture. Errors no
longer reflect authenticated payloads or turn arbitrary refusal codes into
expiry/dead-link claims. The preserved complete-file error prevents this
partial improvement from becoming a false playback success.

This is not a browser engine, a fresh remote-account validation, a completed
selected-fid model, or a verified download/signing protocol. New official
request evidence and legitimate full-file media acceptance remain necessary.

## Verification

`rust/sourin_core/src/csp/pan_baidu_play_protocol_tests.rs` calls production
resolve_with against ephemeral loopback HTTP servers. No OS keyring is read.
The legacy no-credential replay no longer performs unnecessary keyring cleanup.

- Original production path: 0/12 GREEN, 12 failed, cargo exit 101.
- Expanded original-path coverage: 0/17 GREEN, 17 failed, cargo exit 101.
- First implementation: 17/17 passed, cargo exit 0.
- Two additional boundaries: 17 passed / 2 failed, cargo exit 101, at endpoint
  origin acceptance and duplicate path-scoped BDCLND on the actual request.
- Final targeted module regression: 24 passed / 0 failed, cargo exit 0,
  comprising 19 new gates and the five existing replays.

Evidence is append-only under `.probe/baidu-preface-http-red-20261104`,
red2, green, red3 and regression directories. The runners clear proxy variables,
use hidden below-normal processes, offline debug Cargo with jobs=2 and
test-threads=2, and a separate `.probe/baidu-preface-debug-target-20261104`
cache. No release/full build, UI, real account, live share or cloud write is
used for this verification. Root owns final release/full regression and native
playback acceptance.

Primary protocol artifacts remain the archived official
`.probe/baidu-forensics/initNew-all_98048b2.js`, boot_7dd69c6.js and
common-chunks-all_8d8c3d1.js, with the request-shape reference
`.probe/baidu-auth-share-shape-v5-20261104.py` and the static review
`.probe/baidu-static-request-family-review-20261104.md`.
