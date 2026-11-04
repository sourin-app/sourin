# Agent Note: Supported Share Candidate Handoff

Status: implemented

## Problem

HJZhenCai and Wogg call `share_page_play` from their real `site.play` methods.
The helper only recognizes Quark/UC, so Baidu and Xunlei fail at the source
before the provider can run its existing share validity and native resolver.
The old error incorrectly says no native handoff exists.

## Decision

Keep `parse_share_page` and `drive_for` as the Quark/UC family contract.
`share_page_play` additionally offers valid Baidu/Xunlei URLs as intermediate
candidates for the host. Structured URL parsing rejects non-HTTP schemes,
userinfo and control characters. The existing `pan::parse_share` identifies
the family and stable share ID; unsupported families, lookalikes and malformed
IDs do not qualify. New labels explicitly say the host must check and parse.
The source UA, original URL and existing direct-media/family behavior remain.

The provider production pipeline is unchanged. Its existing share intercept
must run `resolve_share`, not return an HTML page as a StreamCandidate. Baidu
still returns its honest missing-login or incomplete-file-playback error.
This handoff does not fabricate a fid or add Baidu selected-file playback.

## Alternatives considered

- Returning a fabricated `panfile` changes the selected resource and hides a
  missing production handoff. Preserve the actual source episode.
- Returning the raw URL as playable media bypasses validity and native
  resolution. Only the host may turn the intermediate candidate into media.
- Extending the Quark/UC parser to every family blurs the PanDrive contract.
  Keep family parsing separate from the broader host handoff capability.

## Consequences

HJ/Wogg Baidu and Xunlei entries can reach the host's existing checks. The new
handoff still rejects unsupported families and malformed candidates. The share still needs real validity,
account access and complete-file protocol evidence; passing handoff tests does
not establish full playback or UI acceptance.

## Verification

Six helper tests include four independent real HJ/Wogg Baidu/Xunlei `play`
calls, the unchanged family parser and strict rejection cases. Two provider
tests use the real source handler through a recording delegate, local HTTP
PanChecker and thread-bound empty credential override. The actual host runs
anonymous `share/list` then reaches Baidu's typed missing-login rejection;
it never returns a share webpage as a media candidate. Flag/id forwarding and
unchanged title/order intent are observed, not claimed as Baidu fid selection.

The eight tests fail on the original helper: 1 passed / 7 failed, cargo exit
101. After the change they pass 8/0, exit 0. Four owning-module regressions pass
HJ 12, Wogg 13, share helper 11 and provider 17, with two real-network tests
ignored. These 53 passes include the new eight and are not additive.

Disabling the new family/id guard produces 7 passed / 1 failed, exit 101,
specifically the invalid/unhandled URL gate. The guard is restored before the
final eight-test regression, which passes 8/0 with cargo exit 0. The earlier ring/debug-profile and incomplete
test-delegate compilation failures are preserved but are not functional red.
Evidence is in `.probe/pan-host-dispatch-*20261104`.

Tests use local replay only, no OS keyring, external account, cloud operation
or UI. Root owns the final release regression, DLL rebuild and real-source
production evidence. The provider file only adds a cfg(test) module.

The first subsequent full release run has 2133 passed / 1 failed / 94 ignored;
it is not green. Its sole old PanWebShare test still requires Baidu rejection
at source.play. Root updates that obsolete expectation to a host candidate,
retaining the unsupported Aliyun rejection and leaving production unchanged.
PanWebShare is also a real shared-helper consumer. A third real-provider gate
now covers its local precheck and typed Baidu missing-login response. Removing
only Baidu support produces 0 passed / 3 failed across HJ, Wogg and PanWebShare,
exit 101; restoring it gives 9/0 shared/host gates, exit 0. The whole PanWebShare
module passes 16/0 with two real-network tests ignored. A new complete release
run and rebuilt core remain Root's required follow-up; none of these local
tests proves full Baidu file playback.

## Relations

Root final release follow-up: the first whole-library run was 2133 passed /
1 failed / 94 ignored because PanWebShare still asserted the old Baidu rejection.
The same real consumer now asserts a pending host candidate and keeps an
unsupported-drive rejection. Its new full-provider gate has actual failure
evidence when Baidu support is removed. The restored final whole-library run
is 2135 passed / 0 failed / 94 ignored, exit 0, in
`.probe/baidu-share-dispatch-rust-final-full-v2-20261104.result.json`.
All 145 source/manifest inputs match the v2 freeze after that run. Current-core
production share inspection and physical UI acceptance remain separate checks;
no Baidu complete-file playback is inferred from this result.

Current-core follow-up on November 5:

- Fresh core `E9F6263C760F740E5FDBF3DAE5681FDCD8CD017A7E756A232EFF21B0E8DA5BFF`
  is bound into a new copy of the completed b842e44 frontend. The 43-file
  package is `baidu-share-dispatch-windows-release-20261105`; no app is launched.
  FatNiu NSYS/PAN1 native decoding and Quark exact 02.mp4 production precheck,
  selected-file resolve, native decode and closed-consumer checks pass with
  this same core. Root views the actual frame images. These remain short native
  samples, not Flutter UI or whole-episode acceptance.
- The initial Baidu production preface probe rejects an old hardcoded share
  association before account activation. Safe diagnostics prove the source,
  content ID and title match, but the current unique Baidu share differs.
  It is not an account-failure result and the old report remains unchanged.
- Anonymous V5 discovery obtains a schema-checked manifest for the same fixed
  source/content's current unique Baidu entry, without account activation.
  Root approves manifest SHA `05304BE17D9030119F65F01C3FA500FE0ABE5E0BDBD67B3C5D3D035425D36D60`
  before one separately authorized read-only production request. That request
  rechecks every target hash and returns an error after reaching production
  resolve; there are no cloud writes, cleanup commands or media requests.
- `baidu-production-preface-probe-v5-20261104-readonly1/summary.json` is exit 1,
  no timeout, with error SHA `5F01C1CADCFAD2F721E4B573F3CBB150DFC28F9640C231ADBA27130EBBC92CC9`.
  Root independently hashes the fixed production login-entry error and obtains
  that exact SHA. The current request does not obtain the share page; this does
  not prove stored account expiry. File-list preface, concrete Baidu file,
  complete download protocol and UI acceptance remain unverified.
- Manifest-approved current-resource inspection does not replace historical
  movie-share acceptance. Owner reports they do not know the official-browser
  state; no password, cookie, direct link or technical diagnosis is requested
  from them. A future user-operated new-client login can provide the missing
  live session evidence without background desktop interaction.

[Selected episodes and real line switching](2026-11-04-selected-episode-parser-and-real-line-switch.md)
retains the existing validity, selection and ownership pipeline. This note fixes
the earlier source-to-host handoff, without replacing those decisions.

[Baidu share preconditions](2026-11-04-baidu-share-preface-cookies-and-honest-errors.md)
remains the Baidu resolver boundary. Reaching it does not establish dlink or
remote account validity.
