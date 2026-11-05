# Agent Note: App99 Reference OkHttp Content Type

Status: implemented

## Problem

Owner again rejected FatNiu playback on 2026-11-05. The existing controlled
NBY selection returns no media address. Earlier same-cipher decoding found
empty data/source in both production Rust and independent Java; that did not
identify a missing client decoder hop.

The App99 DEX creates a UTF-8 JSON RequestBody while supplying a caller header
of application/json. Actual reference-host OkHttp bridge normalization had
not been accounted for in the Rust request helper.

## Decision

Set only signed_post Content-Type to application/json; charset=utf-8.
Preserve encrypted body bytes, signature, numeric parser ID, all original
fields, handshake behavior and selected-line identity. Align the existing
guest-contract assertion and add a production loopback wire-capture test.

The actual reference APK bridge replaces the caller header with the body
media type. This is protocol fidelity, not an established NBY root cause.

## Verification

- Reference APK/host DEX binding and exact bridge/header-set/body chain:
  .probe/nby-okhttp-wire-1105/REPORT.md. The audited APK was not executed;
  this is bytecode evidence, not an original Android wire capture.
- Qualified RED used actual production signed_post over loopback and failed
  at the exact Content-Type assertion after body/signature/field checks.
  .probe/nby-okhttp-contract-1105/red.result.json records Cargo exit 101.
- Corrected GREEN passes that same test with identical synthetic body hash.
  Six guest-header/privacy regressions also pass. No remote requests or
  production accounts were used for those tests.
- Full offline App99 module: 27 passed, 0 failed, 3 live tests ignored.
- Full current release regression on 2026-11-06: 2159 passed, 0 failed,
  94 ignored, with unchanged source inputs. The first isolated-profile run
  failed one existing external-fixture test; its evidence is preserved.
  The passing run uses an explicitly bound copy of the preexisting temporary
  exported fixture, not the Owner production directory:
  .probe/app99-okhttp-full-release-with-fixture-1106/REPORT.md.
- Release build succeeds with unchanged 143 source inputs and Cargo files:
  .probe/playback-core-app99-okhttp-1105/build.result.json. New DLL SHA256:
  178C6F2937E489D8488EEF8F28AC5FF7E8C4F50CE64FD14C20109B913D0DB755.
- One subsequent controlled production NBY selection, content 234900 and
  episode 1, still returns no media address. No candidate, native decode or
  PNG exists for that run. Own-consumer cleanup succeeds.
  .probe/app99-current-core-okhttp-native-1105/REPORT.md explicitly excludes
  harness exit 0 as recovery and does not claim a new same-cipher observation.

## Alternatives considered

- Retain application/json because the caller map specifies it. The actual
  inspected OkHttp bridge replaces that value; mirror final transport.
- Change body/signature or add parser fields. No evidence supports those
  changes; the new gate requires the original fields and ciphertext bytes.
- Mark NBY restored because contract tests pass or use an alternate line.
  Neither establishes selected-line playback. Retain the negative result.

## Consequences

The narrowly corrected wire contract is tested. NBY recovery, original
screenshot content identity, provider/account playback, native interaction
acceptance and final Owner package acceptance remain open in the active goal.
No running Owner package or source/history/account data was changed.

Related: [App99 DEX Guest/Detail Contract And Private Errors](2026-11-05-app99-dex-guest-detail-and-private-errors.md).
