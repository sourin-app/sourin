# Agent Note: Pending detail HTTP error regression checkpoint

Status: proposed

Independent: this records a new public-error boundary regression suite. It does
not supersede proxy routing, parser access-denial policy or existing playback
acceptance notes.

## Problem

A current detail failure reported HTTP 502 alongside historical signing/debug
text. Public errors need the actual status and an appropriate next action
without disclosing request addresses, response bodies or signing material.

## Proposal

At the user's explicit request to commit the current work first, preserve the
four newly prepared loopback regression cases and their cfg(test) module wiring
as a local progress checkpoint. No production error behavior changes here.
The tests are intentionally pending qualification; this is not a completed fix
or a release-ready checkpoint. They have not been compiled or executed.

The two 502 cases target the actual detail POST and provider bridge. The 401/403
controls require one request, no fallback to the origin and no retry advice.
Fixture URLs, request IDs and body canaries are synthetic. Assertions avoid
printing the rejected public message or signing values.

## Alternatives considered

Discarding pending tests would lose the already prepared behavior contracts.
Claiming them green, skipping their assertions or silently changing production
behavior while saving work would misrepresent the current state. Keep them
explicitly pending and qualify them before implementing the error fix.

## Risks

These new expectations are anticipated to fail against the current behavior;
no RED or GREEN result exists yet. A subsequent implementation task must run the
isolated serial test workflow, inspect the failures and positive controls, then
fix and verify the production boundary without weakening the contracts.
Private diagnostic logs, accounts and runtime artifacts remain outside Git.

## Verification

Pre-commit review checked the synthetic fixture boundary and diff whitespace.
No Cargo, live network, native-client or account operation was run for this
checkpoint. Normal commit hooks remain enabled. Test-source SHA256 before
staging: 11f9e31fbdc67e8dd3c2f5277d2bdc21f6f53b2839e05472700e32279b95b922.

## Acceptance criteria

Qualify both HTTP 502 cases and the 401/403 controls against current code; then verify safe public errors, unchanged one-request routing and related provider regressions after the production fix.
