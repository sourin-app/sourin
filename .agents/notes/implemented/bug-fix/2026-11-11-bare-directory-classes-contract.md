# Agent Note: Bare directory resources and classes envelopes

Status: implemented

Applies to production baseline `76a1a5e` on 2026-11-11. Related:
[object directory loading](2026-11-11-object-ext-themed-directory-contract.md)
owns request bounds, routing, caching and restored classes;
[stable category identity](2026-11-11-themed-directory-stable-duplicate-ids.md)
owns duplicate normalization. This decision extends the declared resource and
envelope forms without changing either contract.

## Problem

The requested configuration has seven plain HTTP(S) ext resource strings. The
engine previously recognized only object `json` resources and only the `class`
array. A real current-native read of the first declared bare resource succeeds
with HTTP 200 and a different supported-data shape: `classes` plus a singular
`filter` object and a `cookie` string. Treating this as an unrelated general
catalog loses the declared recipe. The observer's initial missing-`class` error
is an instrument parsing error, not a bad remote response.

Safe retained evidence records 16,626 bytes and body SHA256
`b9bbfec2a1511f3da2119cfc5fc130828a624b9de559e6ebd26c57807b8bb8b9`.
Its 35 valid unique string category IDs all take the local reference's ordinary
keyword branch; zero match its account/uploader/history/latest/partition special
branches, and zero are numeric IDs. The one response does not establish the
other six resources' schemas or anonymous media availability. Cookie values,
addresses and category labels are not copied into this note or its fixtures.

## Decision

A declared absolute HTTP(S) ext string selects directory-resource mode while
the existing object `json` form and empty-ext numeric-region behavior remain.
The same bounded configured HTTP context, cache identity and exact ID/name model
serve both forms. No cookie resource is followed, account header attached or
media requested. Restored bare-directory providers bypass stale general classes.

Envelope precedence is deterministic and preserves the existing behavior:
presence of `class` makes it authoritative. Validate that value completely.
Only when `class` is absent may `classes` supply the array. Do not merge arrays
or fall through from a present invalid/null/empty `class` to a valid `classes`.
Thus adding an alias cannot replace a previously accepted canonical directory
or turn a previously rejected canonical schema into a silent success. Valid
`class` plus a different `classes` must preserve the original exact output.
This is a host compatibility rule; no captured body currently contains both.

Ignore `cookie`, `filter` and other unsupported filter values entirely. Their
presence, types and contents must not cause account/resource follow-up requests,
change category parsing or supply keyword/filter request fields. Supporting the
directory envelope does not implement interactive filtering. The existing
reference defaults remain `order=totalrank` and `duration=0`.

Special-entry handling belongs to the selected directory category request after
exact membership validation and before WBI nav/search. Keep valid directory rows
visible; `CspCategory` currently has only ID/name and no disabled/reason field.
Selecting an unsupported special ID returns an explicit `unsupported:` error,
without pretending an account or partition recipe is an ordinary keyword.
Apply this rule to both directory modes, leaving the ordinary empty-ext numeric
region path unchanged. Near-matching words must remain normal keywords.

The precise retained reference is `categoryContent`, code offset 2374852:
instructions 0–12 perform the exact following check; 13–25 check prefix
`bili_up_`; 26–38 check exact history; 39–51 check exact latest; 52–64 check exact
partition-menu. Instructions 65 onward use the remaining ID as a keyword and
the existing order/duration defaults. Use these exact predicates, not a broad
substring or numeric-ID heuristic. The test fixture contains synthetic marker
values solely to exercise those public protocol branches.

## Alternatives considered

Always preferring `classes` changes an existing `class` result. Merging the two
arrays gives ambiguous identity/order. Falling back when canonical `class` is
malformed hides a schema failure. Rejecting both-key responses discards an
existing valid canonical catalog merely because an unused alias is present.
Keep canonical presence authoritative and validate it.

Rejecting an entire directory with one special entry blocks valid public
categories. Silently dropping the row changes the declared catalog. Treating
every special-looking substring as restricted rejects ordinary words. Keep the
directory and reject only exact unsupported selections before network actions.

## Consequences

The observed `classes` resource can use the existing directory/keyword engine
without silently substituting a general catalog. Canonical presence remains
authoritative, and unsupported special selections fail before side effects.
The singular `filter` metadata remains unused; no interactive filtering or
account source capability is introduced. Extending the parser does not establish
the six uncaptured resources' schemas or any media entitlement.

## Verification

Eight loopback tests are prepared in `csp/bili_bare_directory_tests.rs` and wired
only under the provider's `cfg(test)` module. Wiring waited for the coordinating
task's native observation to finish so its exact provider-source binding stayed
valid during that observation. They are qualified against the old behavior and
then retained unchanged for GREEN as described below.

Cases inspect real declared-resource, proxy/origin, nav and WBI requests rather
than reading an implementation mode constant or mocking the engine result.
An independent known mixin vector checks actual signed query fields. The cases
cover restored classes, bare HTTP classes, actual HTTPS CONNECT rejection,
canonical object/class controls and both-key precedence, numeric thematic IDs,
invalid schemas, empty-ext regions, exact special selections and ordinary
near-matching keywords. The HTTPS case proves routing/refusal only; it does not
claim a successful TLS resource GET or inspect encrypted origin headers.

The coordinating task mechanically adds only the new test file/module to a fresh
`76a1a5e` baseline. The serial locked offline run of
`csp::provider::bili_bare_directory_tests::` compiles in 4m47s and executes in
0.05s: six expected behavior failures and two passing controls, source snapshot
unchanged. Evidence is retained as `native-verify-v59/v59-bare-directory-red`
receipt/log under the ignored task directory. The frozen test SHA256 is
`8c437bf049108465bd211945435e3f312f09ad81c01aeffa82c7b3598049c151`.
The original 21 directory/cache/duplicate cases remain unchanged.

The production implementation loads bare HTTP(S) resources through the existing
loader; canonical `class` presence precedes the `classes` alias.
Exact special-entry predicates reject selection before WBI calls, and the
provider's existing mode predicate now supersedes stale classes for bare URLs as
well. Cookie/filter values are not inspected or added to requests. Bounds,
configured proxy, cache identities, first-ID order and ordinary mode remain as
before.

The coordinating task runs the locked offline Rust manifest with `--lib` and
`-- --test-threads=1`, keeping all source snapshots unchanged:

- `csp::provider::bili_bare_directory_tests::`: 8 passed, 0 failed, 0 ignored;
  compilation 4m32s, execution 0.07s.
- `bili_`: 47 passed, 0 failed, 5 existing live-network cases ignored; compilation
  0.51s, execution 4.19s. This includes the previous 21 directory/cache/duplicate
  cases and new eight cases; overlapping scopes are not added into a new total.
- `csp::provider::`: 45 passed, 0 failed, 0 ignored; compilation 0.42s, execution
  0.29s.

Receipts/logs are `v59-bare-directory-green`, `v59-directory-related-green` and
`v59-provider-related-green` in the same ignored v59 evidence directory.

## Remaining verification

Fresh-core native verification of this bare-resource mode remains pending. The
resource read stays anonymous and within the existing size/time/route boundaries.
Repeated or returned cookie URLs must never be followed. Actual native category,
list, detail, exact episode and decoder frames/progress remain separate gates.
Neither eight local cases nor one external directory establishes seven supported
sources or playable media.

## Note audit

The proposed/implemented/rejected keyword audit finds the two linked directory
notes as the owners of partially overlapping behavior. Their bounds, historical
test results, duplicate policy and incomplete playback gates remain in force.
Routing owns transport, not bare-resource schemas; runtime registry/UI theme
notes are unrelated. No prior implemented Decision is rewritten or archived.
