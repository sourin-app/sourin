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

The independent `CSP_LINES_FIX_OWNING_TESTS_ACCEPTED_V1.json` audit rehashes the baseline/candidate inputs, actual test executables and raw logs, matches each of the five old business failures to a candidate pass, and rejects altered force/exit/executable/input controls. These runs build a test EXE, not a new production DLL. The separate new-core build, public selected media/decoder, PlayerPage line switch, ordinary Release startup, performance and final integrated acceptance remain open.
