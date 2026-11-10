# Agent Note: Selected File Session Handoff And Playback Error Privacy

Status: implemented

## Problem

Owner reports two new failures on November 5. A Quark detail already shows
seven concrete files and highlights episode 03, but playback reports that
the share contains multiple videos and asks for another file selection.
A FatNiu NBY failure displays a full signed playback address and token.
Owner's earlier success does not establish current success for either item.

The player can initially resolve an unexpanded share while detail loads.
Its old list-only backfill leaves that unresolved request alive even after
concrete file IDs arrive. In-place listless sessions also fall back to the
original immutable widget's episode for resolve, resume, saved progress and
the title bar. Provider item fallback independently picks the first detail
entry instead of applying the actual selected episode and line.

App99 additionally lets a media-looking suffix bypass a configured nonzero
parser type. The original DEX selects the player type before deciding
whether to call the configured parser.

## Decision

Keep the explicit listless episode ID and title as mutable session state.
Use that state for resolve, progress publication and persistence, resume,
current session reporting and the title bar. Source switching retires that
state along with the old session. List backfill retains a selected file by
ID and line, not its previous position or the first occurrence of an ID
shared by multiple lines.

If no stream is resolved and a generic share becomes a concrete panfile,
backfill advances the existing playback generation and resolves the selected
file. Old result/error completions cannot override the new generation.
Healthy ordinary streams and already-selected concrete files do not restart.
A vanished concrete file retains its explicit identity; it never becomes a
different file merely because the list is shorter or reordered.

Provider bare-item fallback filters the requested line, uses the shared
strict episode selector, preserves supplied title/order, and rejects missing
or ambiguous selections before playback. A sole unexpanded share is an
intermediate listing entry, not a concrete episode; it carries the actual
selection to the existing validity and file resolver.

App99 honors the configured parser type for media-shaped inputs, preserving
the selected URL and allowed parser IDs in the actual signed/encrypted POST.
Native shares still go through the native share pipeline.

Playback display sanitation hides external URLs and credential values in
error cards, interruption banners and the modified failure-log paths.
Classification continues to read the unsanitized error; unknown details
also use the display version. URL sanitation covers parentheses, apostrophes
and Unicode, and retains a same-line HTTP diagnostic after an address.
Hard-wrapped address continuations remain hidden.

Scheme-less playback references are also private. Known open-failure messages
hide root-relative, network-path and path-relative addresses, including opaque
path components, signed query parameters and wrapped continuations. Standalone
root-relative media references use the same neutral display marker. Address
token boundaries retain directly adjacent CJK explanations and trailing sentence
punctuation. Ordinary readable errors, slash-separated codec names and HTTP
status attribution remain intact; classification continues to read the raw
error. The already-connected error card and interruption banner need no separate
sanitizer or player-page wiring change.

## Alternatives considered

- Restarting every detail backfill interrupts healthy streams and loses
  position. Only an unresolved generic share becoming a concrete file
  qualifies for the generation handoff.
- Picking the first or largest share file plays a different episode.
  Stable file identity and strict selection remain authoritative.
- Reusing the original widget's episode after applySession mixes identities
  between two titles. The session owns its current mutable selection.
- Testing another FatNiu line does not accept the failed NBY line.
  Original-line failure remains open even when alternative lines decode.
- Removing media prechecks on a token-consumption hypothesis lacks evidence.
  No such production change is made.
- Hiding an entire diagnostic line removes useful HTTP status and error
  text. Hide the address/credentials, not the surrounding explanation.

## Consequences

New concrete file lists can take over an unresolved share request without
discarding explicit file identity or silently selecting another episode.
Listless resume/save/title and duplicate-ID line backfill now share the same
current session identity. Selected-file validity, transfer, cleanup ownership
and account handling remain in their existing modules.

The implementation and offline gates are not whole-application acceptance.
Quark candidate playback proves only that candidate, not recovery of the
original screenshot share identity. Short native samples do not establish
whole-episode playback, source-wide availability or native Flutter UI.

## Verification

Evidence is preserved under `.probe`, including rejected and incomplete runs.

- `playback-selected-parser-red-1105`: real Rust assertions fail for three
  selected-item cases and the media-shaped parser case, cargo exit 101.
- `playback-selected-parser-full-green-1105`: full release library regression
  runs 2151 passed / 0 failed / 94 ignored. All 145 frozen inputs are unchanged.
- `playback-core-fixed-v3-1105`: production DLL build passes with the same
  frozen inputs. DLL SHA256 is
  `531D572BC139752138EB4958DE53DABCEFBBC941B35C5104F811E0A88BE13577`.
- `playback-ux-listless-resume-red-v3-20261105`: actual resume path executes,
  7 passed / 2 failed. Earlier v1/v2 attempts have separate invalid-red audits.
- `playback-ux-listless-persistence-red-20261105`: four normal assertions fail
  for save/title/source-switch identity. Its initial restored run passes all
  13 identity cases; the formatted-input rerun also passes 13.
- `playback-ux-duplicate-line-red-20261105`: 9 passed / 1 failed at the actual
  backfill episode index, without timeout or native crash.
  `playback-ux-identity-reviewed-green-20261105` passes all 14 handoff,
  resume, save, title and duplicate-ID line cases with unchanged inputs.
- `playback-ux-privacy-review-red-20261105`: 11 passed / 4 failed for full
  special-character URL hiding and same-line HTTP explanation retention.
  `playback-ux-privacy-review-green-20261105` passes 57 tests, including both
  existing loopback/classification attribution guards.
- `playback-ux-listless-resume-joint-green-20261105` is not green: 36 passes
  precede tests that do not complete. Its evidence is not deleted or recast
  as a proven loader diagnosis.
  The subsequent `playback-ux-native-reviewed-joint-20261105` completes all
  54 current native-tagged tests across handoff/persistence, consumer epochs,
  line switching, remote-shaped controls and actual player/detail/danmaku
  session paths. Inputs are unchanged and the child exits 0.

Native `app99-fixed-core-exact-native-1105` decodes the full recovered item
766930 on ffm3u8 and 234900 on ffm3u8/lzm3u8. Item 234900 NBY still reports
parser 1 returning no media address. The four-digit logged prefixes do not
recover the missing full 2193 item identity.

`app99-nby-version-abba-live-20261105` compares omitted versus DEX api_version
v1 headers with reversed parser orders and both handshake variants. All eight
NBY parser results have empty data. It does not load account credentials,
run userInfo, consume media or prove server-side causality. This header
difference does not justify claiming NBY fixed or changing prechecks.

`quark-owner-native-1105-matching-sevenfile-candidate-live-01` obtains the
matching seven-file order, independently checks validity, resolves the selected
03 file through the production account/core, and renders 65 new libmpv frames
with position 20.0 to 22.7358 seconds. Root inspects the three nonblank animation
images. Scoped cleanup receipt and expired closed-consumer rejection pass;
ephemeral local files are removed after worker exit. Original share identity,
global uniqueness, native application UI and independent cloud deletion
verification remain unproven.

Earlier CJK error/banner widget shots and two homepage HTML templates have
separate headless evidence. They do not replace current native Settings,
WebView2, line switching, login completion or playback UI acceptance.

Targeted Dart analysis reports no compile errors, but exits 2 with warnings
and existing informational diagnostics in the owning large modules. It is
not reported as a clean analysis gate.

## Relations

[Selected episodes and real lines](2026-11-04-selected-episode-parser-and-real-line-switch.md)
owns the initial native selection and line-switching pipeline.

[Supported share handoff](2026-11-04-supported-share-candidate-handoff.md)
owns the source-to-host share candidate boundary.
