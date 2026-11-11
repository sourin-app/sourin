# Agent Note: App99 DEX Guest/Detail Contract And Private Errors

Status: implemented

Applies to App99 request/privacy contracts from 2026-11-05 and bounded media
prefix handling from 2026-11-11. The
[directory request contract](2026-11-10-encrypted-catalog-category-request.md)
owns list/search payloads and default list session binding. The
[global CSP routing contract](../architecture/2026-11-09-csp-global-routing-retains-engine-recipes.md)
continues to own transport policy.

## Problem

Owner rejected FatNiu playback again on 2026-11-05 after reporting it usable
on 2026-11-04. The screenshot shows a failed NBY media open and an error page
containing the signed media address. Separate Quark feedback shows a concrete
episode selected while resolution still asks the user to select a file.
This note covers only the newly corrected App99 request contracts and errors;
it does not close either playback acceptance requirement.

Read-only comparison against the original App99 DEX identified independent
protocol differences in `rust/sourin_core/src/csp/app99.rs`: guest device
fields were nested instead of top-level, app metadata was not nested in
`app`, the configured `LoginPath` was ignored, two handshake stages omitted
version headers, and detail requests omitted `eps`, `v`, and numeric `pl`.
HTTP errors also included response bodies, and transport errors included
request URLs. A nominal HTTP/code success is not proof of media availability.

Selected parser results can be extensionless media whose format prefix spans
HTTP response chunks. Checking only the first transport fragment discards that
candidate before its known signature is complete; accepting a candidate prefix
still does not establish decoding or recovery of the rejected original line.

## Decision

Use one signed POST helper for systemInit, userInfo, and business requests.
All stages send `version` and `api_version=v1`. The header version honors
`ext.version`, defaulting to `versionName`; the systemInit and nested app
body versions remain `versionName`. Preserve configured UUID/key identity.

The guest body follows the original DEX: top-level device constants, nested
app metadata with numeric installation/update milliseconds, independent
random DID, `apiVersion=v2`, channel, token, timestamp, and nonce. Honor
`host+LoginPath`. Guest rejection still permits anonymous browsing; neither
an empty token nor this correction establishes playback authorization.

Detail requests preserve the selected ID and send string `eps="1"`, string
`v="2.0.0"`, and numeric `pl=1`. Do not append these fields to vodParser:
its DEX contract remains parser ID plus the selected episode input.

The selected resolve/parser path checks extensionless media with the existing
`Range: bytes=0-511` GET through the current application client. The sniffer
retains and examines at most 512 prefix bytes across response chunks, returning
when the existing media signature/content-type contract succeeds, or stopping
at EOF or that byte bound. A server ignoring Range does not enlarge the retained
prefix; this is not a claim about total TCP bytes buffered by the transport.
Empty bodies, HTML/JSON types, unrecognized prefixes and HTTP/transport failures
remain errors. Selected inputs, allowed parser IDs, result URLs, headers,
existing request/parse budgets and account-share handling keep their owners.

HTTP errors retain status without echoed bodies; transport failures retain
stage/category without URLs. This is a scoped guarantee, not a claim that
every existing upstream message/capture path is private.

## Verification

`app99_media_prefix_tests.rs` follows the registered default provider's detail,
detail-issued episode selection, resolve, configured parser and extensionless
media GET. An independent AES-CBC fixture checks actual signed selected inputs
and returns MP4/HLS signatures split after three bytes. Fragmented HTML and an
unrecognized 512-byte prefix whose body stays open retain bounded-error controls.
Exact bootstrap/detail/parser/media request sequences and zero origin traffic
retain the proxy/no-fallback boundary. The fixtures contain format prefixes,
not complete decodable movies; candidate acceptance is not frame evidence.

- Original DEX SHA256: `EC947FD1D5404A27EB5BE2029587AE335F3AF84CCACCD218A0454FCB0E100407`.
  Independent read-only disassembly confirmed ciphertext:timestamp:nonce:token
  signature order, header defaults, guest field types/nesting, and detail fields.
- Compiled old guest-contract RED: `.probe/app99-guest-handshake-dex-red-20261105/summary.json`,
  0 passed / 3 failed; actual missing version/custom login path failures.
- Compiled privacy mutation RED:
  `.probe/app99-guest-handshake-privacy-mutation-red-20261105/summary.json`,
  0 passed / 3 failed in the debug profile. Restored production bytes match
  the reviewed pre-mutation SHA256 exactly.
- Qualified compiled detail RED:
  `.probe/app99-detail-dex-contract-qualified-red-20261105/summary.json`,
  0 passed / 1 failed specifically at the eps assertion after real encrypted
  handshake/detail response and request-count checks. The earlier fixture
  omitted package and failed too early; its `qualification.md` explicitly
  excludes it from intended RED evidence.
- Independent probe fixture RED/GREEN:
  `.probe/app99-detail-dex-fixture-{red,green}-1105/report.json`.
  The fixture decrypts actual requests and independently verifies fields,
  signatures, token, sequence, and each selected input.
- Fresh full guest handshake and same-session A-B-B-A detail live comparison:
  `.probe/app99-detail-dex-abba-live-1105/report.json`. Both field variants
  return the same NBY episode input SHA256
  `2481806A3086DEE0F04BAE63C4D7E8DB0B757FFF9BADDEAFC71B4A4742D15677`;
  all four parser data/source values are empty strings. This does not
  establish these protocol corrections as the cause or recovery of NBY.
- Restored full release regression:
  `.probe/app99-guest-detail-privacy-restored-full-release-20261105/summary.json`,
  2158 passed / 0 failed / 94 ignored with unchanged frozen inputs. All seven
  new guest/detail/privacy tests pass in this release run.
- New core: `.probe/playback-core-app99-guest-detail-1105/sourin_core.dll`,
  SHA256 `7F14EEB38F17747C63C3319080E1451D345C176B303110248796B519003D4812`.
  Fresh production resolver/native decoder evidence:
  `.probe/app99-current-core-guest-detail-native-1105/summary.json`.
  NBY returns no media address; ffm3u8 independently decodes H.264 at 1920x1080,
  reaches 2.7156 seconds, and captures 64 new rendered frames. Root inspected
  frame 01 and frame 03: readable opening credits, not native page/UI evidence.
- The native Settings harness compiles after probe-only canonical package
  imports and BOM-only runner repair. Its first RED launch violates the
  no-foreground policy before qualification:
  `.probe/playback-native-background-1105/runs/bootstrap-red-d14fc17bce1d4c6c8c296913a5d0333b/launch-report.json`.
  No owned visible window was observed, but an owned hidden window acquired
  foreground. The launcher stopped its owned process. This is neither a
  qualified screenshot RED nor native Settings acceptance. Engine and retained
  offstage WebView focus paths require stronger background isolation.

## Alternatives considered

- Change only the handshake headers. This has the smallest production diff,
  but leaves independently proven guest body, custom path, and detail
  contract mismatches. Correct the actual DEX contract with focused tests.
- Infer a token requirement from empty parser data. Authentication can matter,
  but the complete anonymous handshake still returns an empty token and empty
  parser response. Do not invent a token or claim an unproved auth root cause.
- Silently play an alternate line to declare NBY recovered. This can produce
  visible frames, but substitutes a different selected line and does not fix
  the failed one. Keep line identity and negative NBY evidence explicit.
- Accept any failing test as RED. It is convenient but hides fixture failures.
  The initial missing-package failure is retained and disqualified; the
  corrected fixture must fail at the intended contract assertion.

## Consequences

The request implementation now matches the observed DEX contract while
preserving anonymous fallback, cache behavior, and selected-line identity.
Focused gates cover the contracts and private HTTP/transport errors.
The bounded prefix check tolerates transport fragmentation while preserving
the existing media-recognition and rejection policy.

NBY is not accepted as playable. The exact original screenshot content ID
has not been recovered; current controlled diagnostics concern ID 234900,
NBY episode 1. Quark candidate decode is not proof of the Owner's exact share.
Baidu account/file decode and native interaction/final-package acceptance
remain separate open requirements in the active full goal.

Related: [Selected Episode Parser And Real Line Switch](2026-11-04-selected-episode-parser-and-real-line-switch.md).

Related (2026-11-10): [safe detail error facts](2026-11-10-detail-upstream-errors-safe-facts.md)
applies the same producer-side privacy policy to a separate signed form adapter.
