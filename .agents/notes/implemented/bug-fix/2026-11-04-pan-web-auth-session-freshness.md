# Agent Note: Web Login Authentication Freshness

Status: implemented

## Problem

The Windows browser uses a persistent profile. `getAllCookies` reads that
profile, not only cookies created by this navigation. Browser creation and
`launch` completion are not proof of a newly completed login. Existing BDUSS
can therefore be saved and close the window after two seconds, before the user
finishes this login. Local credential recognition cannot prove remote validity.

## Decision

After browser creation, read authentication keys before launching the login URL.
The snapshot uses the existing filtered cookie parser, is immutable and lives
only in memory. A failed or timed-out baseline read stays unknown, not empty.
Read, launch and creation retain their existing fifteen-second limits.

Automatic saving requires complete usable authentication keys and a new or
changed required key relative to a known baseline. Tracking cookie changes do
not qualify. Existing unchanged or unknown authentication requires the explicit
`Use Current Login State` action. Ordinary recheck never grants this permission.
Confirmation rereads cookies and follows the same save/local-recognition flow;
cancelled or closed windows cannot write after a late read completes.

Actions wrap within the existing dialog instead of overflowing narrow windows.
The SDK, profile location, stored cookies and account security settings are not
modified. Success still means local credential recognition, not remote login.

## Alternatives considered

- Clearing the profile removes SSO and changes user browser state. Preserve it
  and require meaningful freshness or explicit acknowledgement.
- Reusing any stored authentication silently closes the window even when that
  cookie is remotely rejected. Separate stored-state reuse from a new login.
- Inferring login from URL or browser readiness confuses navigation with
  authentication. Keep the existing required-cookie contract.

## Consequences

Returning users can reuse a session explicitly. A successfully refreshed key
still saves automatically. Unknown baseline state requires confirmation even
if the browser has already completed login; this is intentional and bounded.
The change does not establish the cause of Owner's Baidu rejection.

## Verification

The initial real waiting-dialog replay with unchanged synthetic BDUSS fails
before the fix. The two new unknown/recheck tests also fail against that path.
The eleven new tests cover unchanged and tracking-only values, new/changed
authentication, explicit reread, cancelled late reads, retry after failure,
320x640 action layout, and real SDK transport creation/read/launch ordering.
SDK baseline read failure remains unknown. The legacy fresh-window fixture now
explicitly supplies an empty known baseline; it does not bypass filtering.

Initial two-file regression passes 26 tests. Disabling the production freshness
guard produces 7 passed / 4 failed with the expected automatic-save failures,
exit 1. The guard is restored before the final eleven-file login regression.
Evidence is in new `.probe/playback-ux-web-freshness-*20261104` directories.
No real credential, browser window, network request or remote account is used.
The final source after state-text clarification passes the separate two-file
26-test regression and three-file range analysis (no issues, exit 0). The final
strict serial eleven-file login regression then passes 110 tests, both child and
runner exit 0 (`playback-ux-web-freshness-final-serial-20261104`). Root still owns
the final package rebuild, staged-note gates and physical acceptance.

## Relations

[Independent login and local recognition](2026-11-04-pan-login-modal-and-local-recognition.md)
retains the bounded lifecycle, privacy and local readback decisions. This note
extends capture freshness and explicit reuse, without claiming remote validity.
