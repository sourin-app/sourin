# Agent Note: Explicit PlayRequest Fails Closed

Status: implemented

## Problem

Owner selected a concrete Quark episode, but playback still requested a
specific file from a multi-video share. The normal typed serialization and
concrete-file routing preserve identity in the inspected source. The exact
Owner request has not been observed.

Separately, the FFI resolve_stream dispatcher used serde deserialization
followed by .ok(). A present malformed request silently became None,
discarding all selected-file context. This is a proven boundary defect,
not a proven cause of the Owner screenshot.

## Decision

Parse optional PlayRequest through one private helper. Omitted or null req
remains None; an empty object remains a default request. A present non-object
or invalid typed field returns a static structured other error before state
access or provider dispatch. Never echo the supplied request or serde error.

Preserve valid request fields, concrete panfile identity, and existing
aggregate/provider routing. Do not infer a replacement file from a duplicate
filename or missing concrete identity.

## Verification

- Qualified compiled RED: .probe/quark-request-contract-1106/red-01/receipt.json.
  Six focused Rust tests: 3 passed, 3 failed, exit 101. Malformed shape and
  field tests failed against the actual old helper. The real FFI negative
  fell through to core_not_started instead of rejecting the request.
- Same focused GREEN: .probe/quark-request-contract-1106/green-01/receipt.json.
  Six passed, none failed or ignored. The real FFI negative now reaches
  optional_request with the static error and no echoed marker.
- Actual Dart typed serializer/API transport:
  .probe/quark-request-contract-1106/dart-01/receipt.json, two tests passed.
  The seven-file synthetic fixture preserves episode03 and its copy suffix,
  all typed fields, and the legacy omitted request.
- Synthetic exact-file selection rejects a missing concrete file instead
  of resolving another listed file. This does not exercise a live drive.
- Each run cleared proxies and used an isolated profile and test keyring
  namespace. Source hashes before and after each run were unchanged.
- Root full library release regression:
  .probe/root-rust-regression-1106/receipt.json, 2165 passed, 0 failed,
  94 ignored, exit 0. Root reused the exact qualified GREEN test executable
  without compilation, with four test threads and a fresh isolated profile.
  The previously exported, hash-bound fixture was copied from its existing
  probe directory, not regenerated from Owner data. Source, executable,
  and fixture hashes remained unchanged throughout the run.

## Alternatives considered

- Keep .ok() for optional requests. It conflates absent and malformed input,
  silently losing an explicit user selection.
- Make req mandatory. This breaks existing callers that intentionally rely
  on PlayRequest defaults.
- Echo serde diagnostics. They can include supplied values; a static message
  provides a useful boundary error without exposing the request.
- Declare Quark recovered from these tests. Synthetic boundary coverage does
  not prove the Owner share identity, actual UI request, or real playback.

## Consequences

Malformed explicit requests now fail closed without provider/account work.
Valid and legacy requests retain their existing behavior.

The exact Owner-selected share/file identity, valid FFI-to-drive execution,
native UI acceptance, and Quark playback recovery remain unverified.
The full Rust regression is verified; this is not a final-package baseline
or an acceptance of the ignored live tests.

Related: [App99 DEX Guest/Detail Contract And Private Errors](2026-11-05-app99-dex-guest-detail-and-private-errors.md).
