# Agent Note: Detail upstream errors expose safe facts

Status: implemented

Applies to the signed form adapter after the local `9ca7e2a` checkpoint on
2026-11-10. Continues the
[pending regression checkpoint](../../proposed/bug-fix/2026-11-10-detail-http-error-regression-checkpoint.md).

## Problem

A received HTTP 502 was displayed with a request address, response excerpt and
historical signing advice. Transport, malformed JSON and business-error paths
also echoed private inputs. Missing `code` was presented as a signing diagnosis
without evidence that the current response had that cause.

The provider bridge truncates messages and the FFI forwards them. Fixing only a
single widget would leave other public consumers exposed and would retain the
unsupported diagnosis.

## Decision

The adapter produces safe public messages at `post_form` and `ensure_ok`.
HTTP failures retain the actual status and return before reading the error body.
HTTP 401/403 and business codes 401/403 advise changing the source without retry
advice. Other rejections give a retry or source-change action. Business failures
retain the numeric `code`; missing code reports the missing field only.

Transport and response-read errors retain their failed stage. Invalid JSON
retains its format failure. These paths omit request addresses, identifiers,
response excerpts, arbitrary upstream `msg`, signing recipes and historical
debug explanations. The private request helper no longer takes an operation
description containing request identifiers. The existing public `ensure_ok`
signature remains compatible, but its descriptive argument is not displayed.

Request paths, methods, signed form fields, headers, proxy policy, parser
resolution and success criteria remain unchanged. This does not diagnose the
cause of a live HTTP failure or establish playback availability.

## Alternatives considered

Widget-only URL sanitization cannot recognize unsupported historical prose and
does not protect other FFI consumers. Echoing selected portions of response
text still exposes arbitrary credentials or addresses. Removing status or
business code would discard the reliable facts needed for error handling.

## Verification

Before production changes, the coordinating task compiled and executed the
loopback suite against the old behavior. The initial four cases produced two
502 privacy failures and two passing access-denial controls. The expanded eight
cases produced six privacy failures and the same two passing controls, with
real request execution taking 2.02 seconds. The Rust snapshot remained unchanged
during those runs. Private logs are retained under
`.probe/parallel-astra-1108/native-verify-v51/v56-detail-errors-red.log` and
`v56-detail-errors-expanded-red.log`.

The eight regression cases remain frozen during the production fix. They check
actual detail requests and request ledgers, the provider bridge, malformed
JSON, missing code, private business messages and a closed loopback proxy with
no origin fallback. Assertions do not print rejected messages or signing data.

The older `non_one_code_and_missing_code_are_errors` expectation is intentionally
migrated: numeric code and rejection are still required, while raw `msg` and
historical signing advice must be absent. Its prior expectation described the
behavior now demonstrated unsafe by the qualified RED cases.

At note creation, post-fix Cargo, related regressions and native UI verification
are pending. No GREEN result, live request or playback acceptance is claimed.

## Relations and note audit

The proposed checkpoint is the predecessor and remains a record of its original
pending state. The implemented/rejected/proposed keyword audit found no separate
rejected decision owning this public-message producer.

- [HTTP-first playback classification](2026-10-18-playback-failure-classify-http-first.md)
  partially overlaps: actual status remains available to its classifier.
- [Upstream availability evidence](../testing/2026-10-27-upstream-dead-is-a-strong-claim.md)
  partially overlaps: historical protocol findings remain diagnostic evidence,
  but do not prove the cause of a new response.
- [Guest/detail private errors](2026-11-05-app99-dex-guest-detail-and-private-errors.md)
  partially overlaps in privacy policy and owns a different adapter.
- [Playback display privacy](2026-11-05-selected-file-session-handoff-and-playback-error-privacy.md)
  and [search display privacy](2026-11-07-danmaku-search-error-display-privacy.md)
  partially overlap and remain responsible for their display boundaries.
- [Honest source contracts](../feature/2026-10-26-csp-honest-contract.md)
  partially overlaps in rejecting malformed success responses; request routing
  and empty-result contracts are unchanged.

Other search hits concern routing, encrypted request fields, metadata or UI
geometry and do not own this error behavior. No prior decision is archived or
silently rewritten.

## Consequences

Consumers receive shorter actionable messages, so response-specific debugging
requires separately handled diagnostics rather than the user-visible text.
Known HTTP status remains authoritative even if an error body cannot be read.
This change does not repair upstream availability, add retries, alter proxy
routing or establish successful playback. Native delivery must still bind the
rebuilt core and verify the actual detail surface.

### Post-fix verification

The full adapter filter passed 31 tests with one existing ignored live-network
test. The wider app_rj filter then passed 32 tests with that same ignored live
test; both runs recorded unchanged Rust snapshots. The eight error cases stayed
byte-identical to the expanded qualified RED (SHA256
f3e1735c1b46f0a4350f40397d953f101cdd994d48f9d761d297bdc0f0fe6ed7).
Related coverage includes signed requests across proxy changes, no origin
fallback, parser selection and access rejection. Independent read-only review
reported no new P1/P2 finding. These results do not establish upstream
availability or native playback acceptance; the ignored network test was not run.
