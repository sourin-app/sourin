# Agent Note: Baidu Request Cookie Expiry Deadlines

Status: implemented

## Problem

The request-local Baidu Cookie store recognizes deletion at arrival but drops
future Max-Age and Expires metadata. A Cookie with Max-Age=1 remains selectable
after a two-second verify response, so the subsequent list request sends an
expired value. A future Expires date has the same defect. Correct request
preconditions require lifetime checks between hops, not only at receipt.

## Decision

`rust/sourin_core/src/csp/pan_baidu_play.rs` stores an optional CookieDeadline.
Max-Age retains receipt Instant plus Duration and uses monotonic elapsed time;
this also avoids overflowing Instant arithmetic for large ages. Expires uses
the existing RFC2822 parser and retains its absolute UTC DateTime. A valid
Max-Age takes precedence over Expires. Nonpositive Max-Age, past Expires when
not overridden, and the existing empty-value deletion remove the entry.

Both production header serialization and Cookie value lookup pass through
the same matches predicate, which checks lifetime at query time. Expired
entries can remain in the bounded invocation's map but cannot be returned or
sent. The existing origin, domain, path and Secure checks remain unchanged.
No Cookie metadata is persisted, no Cargo dependency is added, and no
credential lifetime is invented when the supplied raw Cookie string lacks it.

The full-file error boundary, request budgets, public resolver signatures and
safe error attribution remain unchanged. This fixes request-local server
Cookie expiry, not remote account validity or full selected-file playback.

## Alternatives considered

- Receipt-only deletion is simple but fails when an initially valid Cookie
  expires during an awaited request. The real local HTTP reproduction rejects it.
- Store every lifetime as a wall-clock timestamp: this unifies representation
  but lets wall-clock movement change relative Max-Age behavior. Relative ages
  use monotonic elapsed time; absolute Expires retains its existing semantics.
- Duplicate lifetime filtering in header and value: separate checks could
  disagree about which Cookie supplies request metadata. Both reuse the owning
  production matches predicate.

## Consequences

Expired Cookies no longer enter later list headers or BAIDUID-derived logid
metadata. Unexpired Cookies remain eligible, and Max-Age/Expires precedence
and immediate deletion retain their behavior.

The store does not manufacture expiry metadata for a saved credential or an
explicitly installed new share key. Capturing a credential and obtaining a
share list still do not establish a usable remote session or full-file media.
Root retains release/full regression and physical playback acceptance.

## Verification

Three additional tests in
`rust/sourin_core/src/csp/pan_baidu_play_protocol_tests.rs` invoke production
resolve_with against delayed loopback HTTP responses:

- Max-Age=1 is present in the verify request, then absent from the list header
  and value-derived logid after a 2.1-second verify response.
- A future Expires Cookie is initially present, then absent after a 3.2-second
  verify response crosses its deadline.
- Unexpired Max-Age/Expires remain present, positive Max-Age overrides past
  Expires, short Max-Age overrides future Expires, and Max-Age=0 still deletes.

The previous production implementation produces 24 passed / 3 failed,
cargo exit 101. The failures occur at actual subsequent list Cookie headers.
After the lifetime fix, the full targeted Baidu module passes 27 / 0,
cargo exit 0. All 24 prior replays remain green. These are real short-delay
HTTP tests, not copies of the jar or header implementation.

Append-only evidence:
`.probe/baidu-preface-ttl-http-red-20261104` and
`.probe/baidu-preface-ttl-http-green-20261104`.
The new runner uses the separate debug cache, offline Cargo, jobs=2,
test-threads=2, hidden below-normal processes and cleared proxy variables.
No temporary production mutation, OS keyring, real account, live share,
cloud write, UI, Dart edit, release build or full-suite run is used here.

## Relations

[Baidu share preconditions and honest errors](2026-11-04-baidu-share-preface-cookies-and-honest-errors.md)
remains the preceding decision. This note adds dynamic Cookie lifetime checks.
The previous note, frozen scope and all earlier reports are preserved;
the latest scope is `.probe/baidu-share-preface-final-scope-v2-20261104.json`.
