# Agent Note: Baidu Anonymous Precheck Shares The Production Protocol

Status: implemented

## Problem

The anonymous PanChecker Baidu path independently builds the old verify/list
protocol. It drops Cookie context, classifies every verify refusal as Locked,
and caches unknown list refusals as dead links. It also scans successful JSON
metadata for error keywords. That precheck can block a valid share before the
new protected Baidu resolver is reached. Nonempty lists containing null/bool
or malformed rows can conversely look valid. Awaited old-generation responses
must not trigger subsequent account requests.

## Decision

`rust/sourin_core/src/csp/pan_baidu_play.rs` owns one inspect_with protocol.
The public resolver keeps its existing signatures and missing-local-credential
NEED_LOGIN behavior. inspect_anonymous invokes the same implementation with
an empty initial Cookie store and never loads pan_auth or a stored account.
Both paths reuse the official structured query/form, request-local Cookie TTL
and scope rules, five-hop/45-second budget, response cap and strict errno parser.
There is no second request/body builder in PanChecker's Baidu branch.

Inspection returns typed Files, Empty or NeedsPasscode results, or a typed
HTTP/business/protocol/expired failure. Only successful HTTP and integer
errno=0 with valid file-list structure can report Files. Every nonempty row
must be an object with positive fs_id, nonempty server_filename and a valid
isdir when supplied. An explicitly successful empty list is No File; an
explicit HasPwd challenge remains Locked. Success metadata never enters the
error text mapper, even if file names, message fields or data contain keywords.

Only failed business envelopes retain selected top-level error message fields
and nested error message/name/code strings for classification. Debug and public
resolver errors omit these opaque fields. Unknown -6/-12, known auth/captcha
codes, schema failures and unknown HTTP remain uncacheable Uncertain. Official
verify -9 retains its explicit extraction-code refusal. Other explicit failed
error fields use the existing attribution mapper after auth/captcha filtering.
The global mapper and all Quark/UC/Xunlei/other-family branches remain unchanged.
Genuine Bad/Locked states and their existing caches are not bypassed.

The existing playback guard runs before local account loading, at inspection
entry, and before/after every request/body await. A stale private resolver
retains the exact error "播放解析请求已过期". Anonymous inspection can project a stale
failure to Uncertain, but cannot continue with another HTTP hop. A valid
No Owner invocation keeps the legacy behavior. No cloud action is added.

The test-only global checker accessor remains &'static. A thread-local,
non-Send RAII override restores prior nested state for current-thread tests.
It changes no production lookup or API semantics and lets host integration
tests use a real PanChecker with local endpoints instead of bypassing checks.

## Alternatives considered

- Patch the independent checker request builder: this fixes one request shape
  but leaves a second implementation of cookies, TTL, budgets and schema to
  diverge. Both callers use the owning production inspection workflow.
- Treat every failure as allowed: this removes false negatives by discarding
  genuine dead-link/extraction-code protection. Known Bad/Locked gates remain.
- Scan raw bodies or successful metadata: these contain arbitrary titles and
  fields, so matching them as errors corrupts states and caches. Only failed
  envelopes expose selected error strings to classification.
- Change global production APIs for integration tests: a narrow current-thread
  cfg(test) RAII accessor supplies the required fixture without runtime hooks.

## Consequences

The anonymous precheck no longer creates persistent dead-link or wrong-code
states from unknown responses. Structurally invalid rows cannot fabricate
validity. Successful metadata is isolated, Cookie/query shape is shared, and
late-generation responses cannot issue follow-up account requests.

Anonymous listing still does not prove account validity or complete selected
file playback. Public Baidu resolve still ends at the honest complete-file
dlink-not-integrated boundary after successful inspection. Root owns the
remaining host handoff, release/full build and native/media acceptance.

## Verification

The new `rust/sourin_core/src/pan_check_baidu_protocol_tests.rs` executes real
PanChecker::check_one with loopback HTTP endpoints. It covers known Bad/Locked
cache protection, unknown/cache behavior, HTTP/schema failures, real rows,
metadata isolation, query/form/Cookie capture, auth/captcha and delayed owners.

- Initial checker replay: 1 passed / 13 failed, cargo exit 101.
- Checker replay with delayed owner: 1 passed / 14 failed, cargo exit 101.
- Private resolver owner gates before the fix: old 27 passed / new 2 failed,
  cargo exit 101. Delayed and already-expired requests both send inappropriate
  requests or return the partial wall instead of the exact expired error.
- Shared anonymous implementation: 15 passed / 0 failed, cargo exit 0.
- Baidu resolver module regression: 29 passed / 0 failed, cargo exit 0.
- Complete precheck module regression: 40 passed / 0 failed, cargo exit 0,
  including the preceding 25 gates for other families and common semantics.

The protected pan_check sections compare exactly with their pre-change text;
only Baidu logic, its necessary legacy fixtures and the approved cfg(test)
accessor/include change. The file is not globally reformatted. New evidence is
append-only under `.probe/baidu-anonymous-check-http-*20261104`.

Tests use offline debug Cargo, jobs=2, test-threads=2, hidden below-normal
processes, cleared proxy variables and the existing isolated debug cache.
No OS account is read, no live share/UI/cloud write is used, no Dart/Cargo
dependency is changed, and no release/full-suite build is run here. All owned
test runners are terminal before the exclusive Cargo slot is handed to the
host integration teammate. Root owns the final unified release/full tests.

## Relations

[Baidu share preconditions](2026-11-04-baidu-share-preface-cookies-and-honest-errors.md)
defines the official request and privacy boundary.
[Cookie expiry deadlines](2026-11-04-baidu-request-cookie-expiry-deadlines.md)
retains the dynamic lifetime behavior. The preceding decisions and historical
frozen scopes remain available; current note follow-up links belong to Root's
final note maintenance. The new combined scope is
`.probe/baidu-share-preface-final-scope-v3-20261104.json`.
