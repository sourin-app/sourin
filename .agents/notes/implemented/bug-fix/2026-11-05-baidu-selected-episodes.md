# Agent Note: Baidu real file episodes and full download resolution

Status: implemented

Relations: [Shared anonymous precheck](2026-11-04-baidu-anonymous-precheck-shared-protocol.md) retains provider handoff and validity classification. [Native login completion](2026-11-05-pan-web-native-toolbar-and-completion.md) retains browser consent and local save/readback. Neither local recognition nor listing alone proves actual playback.

## Problem

The prior resolver discarded file/session context after root inspection and always returned an unimplemented-dlink error. The host discarded the requested Baidu fid and episode spec, and Baidu shares did not expand into selectable file episodes. This cannot satisfy Owner's requirement to validate a share and play one concrete chosen episode.

## Decision

Share inspection retains the HTTP client, scoped cookie jar, share metadata and
original 45-second deadline. A single bounded traversal serves anonymous episode
listing and authenticated selected playback. Baidu share expansion now encodes
each real fs_id as a panfile reference and forwards the selected reference back to
the same resolver. Directory and pagination limits apply after accumulation too;
malformed paths, loops, repeated IDs and control-character names fail explicitly.

The viewer is now obtained through `/api/loginStatus`, not inferred from the share owner's page. The three account/sign/download requests include the installed official HTTP defaults clienttype=0, app_id=250528 and web=1. The sign request also carries the common XMLHttpRequest header. The final media cookie is generated for the returned URL's scope; cookies are not blindly sent to unrelated CDN hosts.

## Alternatives considered

The acquired public home.6c242846.js was read as text, never executed. Its afcf
share branch uses /share/tplconfig (surl leading 5 becomes 1, fields sign,timestamp,
viewer bdstoken), then form POST /api/sharedownload. Observed knowledge-share caller
supplies uk/primaryid and channel chunlei. This is not evidence for guessed classic
password auxiliary fields. The observed /api/loginStatus fallback supplies viewer
login_info; vip_identity divided by ten is the official mapping. Do not execute
sign2, bypass permission/captcha, or substitute short streaming previews.

Keeping the previous error-only resolver cannot meet selected playback. Guessing
extra request fields would be unsafe. The observed chain with honest protocol and
permission boundaries enables local tests without making unsupported live claims.

## Verification

Initial debug runs used Normal priority/inherited environment, a deviation from the
requested Hidden/BelowNormal/proxy-cleared workflow. They are provisional evidence.
A deliberate fsid=1 production mutation compiled but made the exact selected-file
gate fail with a sanitized response-ID mismatch; the mutation was restored.
Root's compliant held-handle frozen-input run passed 35 tests, exit 0, recorded in
.probe/baidu-selected-dlink-final-green-20261105/summary.json. The subsequent reusable
anonymous listing and UI-expansion changes require another compliant Root run.

The source SHA256 is `50136B9B2345239D0F19A6E66740F794EE521BB1CA8830A29E2E38E8D2B8E756`. `.probe/baidu-static-loader-20261105/next-step-evidence.md` records the exact modules and offsets, anonymous acquisition and limits. The Acorn business-call gate first rejects a permissive-literal mutation, exit 1; restored recognition passes six checks, exit 0, in `.probe/baidu-public-business-gate-{red,green}-20261105/summary.json`. It parses, never executes, acquired JavaScript.

Root adds actual wire assertions for the installed HTTP defaults. `.probe/baidu-selected-web-defaults-red-20261105/summary.json` records child exit 101 and 0 passed/1 failed specifically because clienttype is absent from the actual loginStatus request. Compilation succeeds. After adding the defaults and sign header, `.probe/baidu-selected-episodes-web-defaults-green-20261105/summary.json` passes 35 tests with exit 0 and unchanged inputs. That later run also covers shared anonymous nested listing, file-reference encoding, selected POST, cookie rotation, second-page identity and late-generation rejection. It does not include the additional traversal/cookie-export guards being added after independent review.

Existing historical protocol tests are now explicitly inspection-only; separate selected-flow fixtures exercise the full resolver rather than using listing success as its result. Independent review finds no confirmed defect but identifies missing direct tests for cycles, repeated pages, traversal limits and exported-cookie scope. Root is adding those gates before final release regression/build and real acceptance.

Those three direct guards now exercise the real anonymous traversal and selected media export. Combined production mutation disables duplicate-ID rejection and exports the page's cookies to unrelated media: `.probe/baidu-selected-traversal-cookie-mutation-red-20261105/summary.json` has child exit 101, 1 passed/2 failed, both failures tied to those changed behaviors. The native account and network are not used. The mutation is exactly restored to its pre-mutation SHA before formatting the two touched Rust modules. `.probe/baidu-selected-guards-restored-final-green-20261105/summary.json` passes all 38 Baidu tests, child exit 0, held-handle and unchanged-input checks true. The guards also verify the 64-directory and 128-followup-request boundaries and same-domain cookie rotation versus unrelated-domain omission. Existing compiler warnings remain outside this focused change.

The common selected-file model regression `.probe/baidu-selected-episode-model-regression-20261105/summary.json` passes eight tests, exit 0, with unchanged inputs. The nineteen-file headless frontend batch `.probe/playback-ux-combined-headless-20261105/summary.json` passes 145 tests with child exit 0 and an isolated account/data namespace; native-media files are deliberately not counted as passed there. Release-wide regression, final DLL binding and actual UI/content remain separate acceptance work.

Release regression at commit 14885e8 passes 2144 tests, 0 failed and 94 ignored with exit 0, in `.probe/baidu-selected-release-full-20261105/summary.json`. This is not UI, account or playback acceptance.

Subsequent source review finds the official root share-list helper at offset 714931 removes the leading share marker before using shorturl. The initial wire gate fails specifically with actual shorturl=5Ab_Cd instead of Ab_Cd: `.probe/baidu-list-shorturl-red-20261105/summary.json`, compiled behavior exit 101, 0 passed/1 failed. Root aligns root listing with the existing verify normalization for leading 1/5, while preserving the original share ID for references and signing. `.probe/baidu-list-shorturl-final-green-20261105/summary.json` then passes all 38 Baidu tests with exit 0 and unchanged inputs. The preceding release-wide result must not be attributed to this later short-code tree; final release and DLL binding remain pending.

## Consequences

No real account, keyring/profile, external endpoint, CDN playback or UI was accessed
by this implementation agent. Root still owns live acceptance for the exact nested
episode, real viewer metadata and full playback. The knowledge-share request fields
must not be described as fully accepted by classic/password shares before that test.

The old active package/profile is not overwritten or terminated. Code implementation is distinct from a verified live account, selected file and decoded media beyond preview limits. The overall goal remains active until the new core is bound and the requested real UI/playback is observed.
