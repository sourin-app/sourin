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

Final artifact and account follow-up, recorded separately from those earlier
pending checks:

- `playback-ux-core-build-20261104.result.json` is exit 0. New core SHA256 is
  `25DA90D8F1FDA85D7F9FC0FB224A55D50D06213A8E1B88023814A576237DF7D7`.
  `playback-ux-windows-build-evidence-v3-repair1-20261104/summary.json` confirms
  a fresh complete Windows build, 258 unchanged source inputs and 43 package
  files. Root independently hashes every package file; core and libmpv match
  the native playback instruments. App and UI were not launched.
- `app99-headless-v3-20261104-203507` uses that new core. Both NSYS and PAN1
  second-episode native decode and closed-consumer checks exit 0. Root views
  both third-frame images and observes clear scene, person and credits.
- `panfile-account-play-v8-20261104-live1/summary.json` is exit 0, no timeout:
  production precheck is Ok, detail has 31 real file references, and original
  fid, complete episode ID, filename 02.mp4 and order 2 all match. Production
  resolve and same-consumer closure pass, with every media header preserved.
  Native decode records 68 real new frames and three distinct nonblack images;
  Root views frames 01 and 03. Sampling remains second 20 to about 22.72, not
  twenty seconds of continuous playback, complete-episode or Flutter UI proof.
- V3-V5 account instruments initially misreject the production's legal Base64
  padding. V6 fixes only that parser, retaining the entire original ID hash;
  actual mutation proves the rejection. V6 then stops before decoding because
  profile isolation hides user-installed Pillow. V7 binds only the hash-locked
  existing Pillow package without exposing user site paths or startup scripts;
  removal is actual red and isolated qualification is green.
- V7 proves native decoding but exits 1 because the live SQLite handle prevents
  worker-local file deletion. Its original report stays frozen. V8 defers only
  local filesystem cleanup after an otherwise verified chain; parent observes
  worker exit 0 and actually removes the isolated data after process exit before
  reporting success. Main failures, nonzero exits, timeouts and failed parent
  cleanup never recover. Both adversarial mutations fail and 18 offline groups
  pass before live use. Server-side cloud deletion remains not independently
  observed; an accepted FFI cleanup receipt is not that proof.
- Baidu full-file playback remains unresolved in
  `baidu-account-playback-status-20261104.md`. Physical UI/line-switch acceptance
  and the Owner's five interaction changes still require direct client review.
  The full user goal remains active.

## Relations

[Selected episodes and real line switching](2026-11-04-selected-episode-parser-and-real-line-switch.md)
retains the selected-file identity, precheck and ownership decisions. This note
adds the Quark download-23018 video fallback without replacing those decisions.

[Quark bounded self-heal](2026-11-01-quark-retry-404-21001-purge-race-and-selfheal.md)
retains its 21001 policy. The new video fallback applies to a different business
code and does not broaden self-heal retry counts or cloud modification scope.
