# Agent Note: CSP exposes real playback lines and filters selected episodes

Status: implemented

This supplements the [YunDuo selected identity decision](2026-11-12-yunduo-selected-episode-tagged-tuple.md): its tagged tuple, old ID bytes and protobuf boundaries remain unchanged. The [selected episode and real line switch decision](2026-11-04-selected-episode-parser-and-real-line-switch.md) retains its App99, cloud-file and UI scope. The [global CSP routing decision](../architecture/2026-11-09-csp-global-routing-retains-engine-recipes.md) continues to own HTTP policy; this change groups provider results without replacing engine clients.

## Problem

The current packaged core retrieves eight real episodes for the public YunDuo item 疯狂动物城2 (86421), with flags PAN1:3, NBY:1, qsvip:2 and BBA:2. CspProvider exposes one default source with count eight and advertises multi_source=false. Its inherited episodes implementation ignores sourceCode, and item fallback only uses the separate flag argument. A caller selecting a line through sourceCode can receive other lines or hit cross-line name ambiguity.

## Decision

Supported CspProvider instances advertise line selection. Detail creates one PlaySource per normalized episode flag, in first-seen order with actual counts. Empty flags share the default group. Episode IDs and original flags retain their bytes; display titles and order use the count within each line. A source-index map avoids repeatedly scanning all preceding sources.

The episodes override filters by the requested source and reports an unknown source as NotFound. An empty source retains the old full-list behavior. Persisted default sessions also retain that list when no real default group exists; when such a group exists, default returns only its episodes.

Resolve uses an explicit flag when supplied, otherwise a non-default sourceCode supplies the line. Conflicting non-default source/flag pairs fail before playback. Item fallback filters to that line and passes the selected episode's actual flag into the original engine play method. Default-only fallback selects a real default group when present. Unnamed entries use line-local display numbering during fallback, and ambiguous names across unspecified lines fail. Old default plus explicit flag requests remain compatible. Direct episode identity recognition and cloud-file ownership continue through their existing paths.

## Alternatives considered

- **Keep the default source**: it preserves the old presentation, but conceals real line choices and cannot make sourceCode-only callers select the requested line. The narrow default-session compatibility preserves old calls without hiding current lines.
- **Group in the UI**: the UI already has episode flags, but core API and remote callers would still receive an unfiltered list. The common CspProvider boundary supplies the same contract to every caller.
- **Change each CSP engine**: engine-specific grouping can retain special metadata, but engines already return actual flags. Grouping the adapter's existing output avoids changing request recipes and identity parsers.

## Consequences

The provider exposes source choices corresponding to real episode flags and honors line-only selection. Changing this shared bridge affects every supported CSP provider, so owning provider and YunDuo protocol/identity/proxy compatibility are separate checks. An advertised capability means the bridge supports the operation; it does not claim a given source has multiple lines or that an upstream line is playable. Legacy default behavior intentionally permits an unfiltered list only at the stated compatibility boundary.

## Verification

The public defect receipt is `.probe/goal-resume-20261115-evening/CURRENT_YUNDUO_SOURCE_COLLAPSE_RED_V1.json`. The original packaged core stops at the multi-source assertion before media requests, exits1 and naturally drains its exact Job for 8.0130186 seconds without force. This is a catalog defect observation, not a playback result.

The frozen business baseline is `csp-lines-baseline-v4/FROZEN_BASELINE.json` under the same directory. It retains the actual Release test EXE and 267 Rust/Cargo inputs. Six baseline assertions produce five business failures and one legacy compatibility positive, with exit101 and natural Job zero for at least eight seconds. The three earlier setup failures remain separate. The candidate's frozen actual test EXE SHA256 is `709AFD61D7221EA4DB4209521CE1B5CEBA399388A7030FA30129C06D2451A99C`. The original Cargo Release owning-module run passes 56 tests, including the nine line assertions, with zero failed and zero ignored, unchanged 267 inputs, exit0, natural Job zero for 8.0310000 seconds and no force/cleanup errors. The same EXE passes all 27 YunDuo identity/protobuf/playback/proxy compatibility tests, excluding only the explicitly named live case, with zero failed/ignored, exit0 and natural Job zero for 8.0310000 seconds without force.

The independent `CSP_LINES_FIX_OWNING_TESTS_ACCEPTED_V1.json` audit rehashes the baseline/candidate inputs, actual test executables and raw logs, matches each of the five old business failures to a candidate pass, and rejects altered force/exit/executable/input controls. Those test runs build a test EXE. A separate production Release DLL build binds the unchanged 267 inputs to core `19CF2E7F1AB4544FB3B9CFBE06072572F03A5734D252D217AA683F198F1D30E3`, exits0 and naturally drains Job zero for 8.0406773 seconds without force. `CSP_LINES_RELEASE_BYTES_ACCEPTED_V1.json` rehashes all 59 package files, 267 core inputs and 3604 unchanged frontend inputs. It retains 58 existing production Dart/native files and replaces only the core. This is package byte qualification, not ordinary startup.

`CURRENT_YUNDUO_MULTI_LINE_PUBLIC_AUDIT_V3.json` qualifies the original packaged API for the actual public item 86421: all four sources and counts match real detail flags, and each get_episodes response contains only the requested line. Exact selected qsvip HD中字 and BBA HD英语 requests produce actual HLS and MP4 media through the original All-scope forwarding path and an endpoint-restricted task CONNECT relay. The exact packaged libmpv produces muted/nonzero s16le stereo44100Hz WAV pairs at three seconds. Independent wave parsing confirms 264598 samples with 264483 nonzero on qsvip and 264600 samples with 244948 nonzero on BBA; muted controls have zero nonzero samples. Owner32276 exits0, natural Job zero 8.0320000 seconds, no force. API, bytes and PCM are verified; device/Audible/PlayerPage claims remain false.

PAN1 returns an actual decode code0 rejection. NBY resolves a real HLS candidate but its application/octet-stream getM3u8 response lacks a recognized suffix and retains external child URIs, so its uniform-forwarding/decoder check fails and remains open. The v2 successor retains pre-media wrapper assumptions and forced drain-query failure; it is not a runtime qualification. PlayerPage line switch, covers, ordinary startup, performance and final integrated acceptance remain open. The UI v1 pre-client list/tuple setup failure, v2 endpoint-blocked covers, v3 cover transport failure and v4 unavailable normal-bottom-bar callback in the actual error state remain separate failed receipts, with natural cleanup where recorded. The v4 retained screenshot also exposes a detail-area RenderFlex overflow despite zero counted log patterns; those counts do not establish visual acceptance.


The original current-source PlayerPage successor v5 is independently audited by `CURRENT_YUNDUO_PLAYER_CALLBACKS_AND_LIMITS_V1.json`. It uses the visible error overlay onLines callback after PAN1 failure, then original line and explicit-episode callbacks select qsvip HD中字 and BBA HD英语 in the same PlayerPage/Player identity. Settings, panel, return and default ask/Quit callbacks complete, owner24860 exits0 and naturally observes Job zero for8.0355784 seconds; a distinct original-ABI task seed owner drains for8.0271877 seconds.59 runtime files,3597 frozen frontend inputs and415 product-parity files plus eight PNGs are checked. The adapter only appends observations/callbacks and suppresses task window activation.

The screenshot/content review rejects broader playback/UI acceptance: qsvip displays the Walt Disney opening at1920x800 with6238s duration; BBA displays a720x404,10.410s 视频不见了 placeholder. That URL produces real decoded PCM but does not deliver the selected film. The initial target Home cover is not decoded, and the detail area visibly says BOTTOM OVERFLOWED BY71 PIXELS even though counted raw log patterns are zero. `CURRENT_YUNDUO_MULTI_LINE_PUBLIC_SCOPE_CORRECTION_V1.json` binds this finding to the earlier physical PCM report. Actual two-film-lines, full covers, layout, ordinary startup, performance and whole-goal acceptance remain false. The v5 callback/decoder subset is not reclassified as complete UI acceptance.


The numeric screenshot reading is corrected by `CURRENT_YUNDUO_DETAIL_OVERFLOW_SCOPE_CORRECTION_V2.json`: a six-times enlargement of the retained original PNG reads BOTTOM OVERFLOWED BY71 PIXELS. The original receipt retains its earlier711 reading as historical data. Raw owning layout measurement remains481px above the episode area, while the narrow stacked detail allocation is475.2px. The correction does not accept the layout or supersede any failure.
