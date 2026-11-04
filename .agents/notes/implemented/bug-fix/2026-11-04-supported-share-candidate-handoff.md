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

[Selected episodes and real line switching](2026-11-04-selected-episode-parser-and-real-line-switch.md)
retains the existing validity, selection and ownership pipeline. This note fixes
the earlier source-to-host handoff, without replacing those decisions.

[Baidu share preconditions](2026-11-04-baidu-share-preface-cookies-and-honest-errors.md)
remains the Baidu resolver boundary. Reaching it does not establish dlink or
remote account validity.
