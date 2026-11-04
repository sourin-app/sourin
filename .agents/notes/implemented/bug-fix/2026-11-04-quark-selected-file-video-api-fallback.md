# Agent Note: Quark Selected File Video API Fallback

Status: implemented

Scope: `rust/sourin_core/src/csp/pan_drive.rs` and
`rust/sourin_core/src/csp/pan_drive_video_tests.rs`.

## Problem

Owner requires checking a share and playing the selected real episode. The
production download endpoint rejects the known HJZhenCai second file with
integer code 23018. Treating this as the only possible playback endpoint hides
the separate authorized video API used by the official Quark web client.

## Decision

Only Quark JSON integer code 23018 activates `file/v2/play`. The request uses
the same already copied fid, without selecting another file or copying again.
The resolutions/supports request follows the first-party web 4.6.7 bundle.
Authorized variants must be ready (`accessable=true`, `trans_status=success`)
with valid HTTPS URLs; the server's default resolution sorts first stably.
Other Quark business codes, UC and successful downloads retain their paths.

Cookies rotate through both responses. The final video response replaces the
intermediate and original cookie values, and every variant receives the same
final headers. The video request checks playback ownership before starting
and after reading its response. New video errors reveal only fixed messages,
HTTP status and integer business codes; login rejection keeps NEED_LOGIN.

## Alternatives considered

- Retrying download or selecting a smaller file changes the requested content
  or repeats an endpoint that already rejects it. Preserve the selected fid.
- Returning every URL ignores entitlement and transcode state. Only expose
  ready authorized variants, preserving the official preferred quality.
- Calling an independent script a production playback test skips the owning
  resolver. The new account instrument invokes the real production core.

## Consequences

The original selected-file precheck, enumeration, copy ownership and scoped
cleanup remain in place. This fallback does not bypass quota or entitlement.
The client still needs a newly built core and UI acceptance; this note does
not claim full-episode playback or completed user acceptance.

## Verification

- First-party script v3 live1 validates the original 02.mp4, copies that file,
  receives download 23018, and decodes authorized video. Root inspected two
  distinct nonblack frames. Sampling starts at second 20 for about 2.72 seconds;
  it is not twenty seconds of uninterrupted playback or production resolver
  evidence. Both owned temporary objects have independently verified deletion.
- The initial missing-fallback production release test is 2 passed / 2 failed.
  The corrected exit-code runner independently records exit 101.
- Six production HTTP replay tests cover the exact fid/request, both cookie
  rotations, variants, original success, nonfallback business codes, sanitized
  API errors, login classification and a paused response crossing generation.
- Combined cookie/generation mutation red2 is 4 passed / 2 failed, exit 101,
  with both intended behavioral assertions failing. The preceding unresolved
  test dependency compile error is preserved and is not functional red evidence.
  Both production mutations have been restored before full release regression.
- `panfile-account-play-v3-20261104.py` forks frozen v2. It validates all of at
  most six candidates and preserves the production first item. Its fourteen
  offline qualification groups pass; wrong-quality selection, removed sampling
  offset and disabled decode validation each produce actual intended failures.
  This offline qualification does not prove production account playback.
- Final production release regression is 2087 passed / 0 failed / 94 ignored,
  exit 0, in `playback-ux-rust-full-green-20261104.result.json`. All six new
  replay tests pass. The 141 Rust source/manifest/build inputs remain unchanged
  against `playback-ux-rust-source-freeze-v2-20261104.json` after the run.
  Newly built DLL, production-account decode and physical UI acceptance remain
  separate pending checks, not inferred from an old application's DLL.

## Relations

[Selected episodes and real line switching](2026-11-04-selected-episode-parser-and-real-line-switch.md)
retains the selected-file identity, precheck and ownership decisions. This note
adds the Quark download-23018 video fallback without replacing those decisions.

[Quark bounded self-heal](2026-11-01-quark-retry-404-21001-purge-race-and-selfheal.md)
retains its 21001 policy. The new video fallback applies to a different business
code and does not broaden self-heal retry counts or cloud modification scope.
