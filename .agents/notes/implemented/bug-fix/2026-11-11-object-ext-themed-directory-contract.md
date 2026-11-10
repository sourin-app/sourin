# Agent Note: Object ext themed directory contract

Status: implemented

Current duplicate-ID policy: [stable first occurrence](2026-11-11-themed-directory-stable-duplicate-ids.md)
supersedes only the duplicate-rejection sub-decision recorded below. Its local
RED/GREEN is qualified; fresh-core native directory and playback verification
remain pending. The original Decision is retained as history.

Applies to the current source on 2026-11-11. Related:
[engine-owned HTTP routing](../architecture/2026-11-09-csp-global-routing-retains-engine-recipes.md)
owns the client policy;
[honest source contracts](../feature/2026-10-26-csp-honest-contract.md)
owns malformed-response rejection. This change extends directory recipe
compatibility, not playback availability or an account capability.

## Problem

The directory engine previously ignored `ext`, so object configurations declaring
a public JSON directory returned the same general categories and numeric-region
lists. Persisted general categories also let the provider bypass the corrected
engine. Registration and category counts did not establish that the declared
thematic recipe was being used.

Retained configuration samples establish object keys `json` and `n`; the local
reference establishes the declared resource GET and the directory shape
`{class:[{type_id,type_name}],filters?:{...}}`. Ordinary thematic categories
become keyword searches with default `order=totalrank` and `duration=0`.
The exact bodies of seven separately requested plain URL ext resources have
not been captured. A prior connection timeout returned zero bytes and no HTTP
status; it is not schema or access-refusal evidence.

## Decision

The explicit object `ext.json` mode loads its declared absolute HTTP(S) resource
through the existing engine HTTP context. A five-second whole-request timeout,
512KiB decoded-body limit and maximum of 512 categories bound the load. The
engine validates every nonempty ID/name, rejects duplicate IDs, preserves the
accepted strings exactly and routes lists through the existing WBI signing and
keyword response mapping. Mode belongs to the engine configuration, including
for numeric-looking theme IDs. Default order and duration remain explicit.

Invalid JSON, invalid class entries and access denial remain failures without
becoming an unrelated general ranking. Restored object-mode providers ask the
engine for directory categories instead of trusting stale general categories.
Empty ext retains existing numeric-region behavior and its persisted-category
restoration without a new source request.

The single per-engine cache lasts five minutes and binds the declared resource,
proxy-store identity, live policy revision and provider identity. Client capture
and completed loads check the same identity. A changed or failed resource never
uses a prior recipe's success. The ordinary search and themed category paths
share the existing signer and response mapping; only themed categories add the
reference default order/duration fields.

The first scope does not implement plain URL aliases, presets, account sections,
cookie resources or interactive filters. Those require their own supported
recipe evidence and explicit contracts. No runtime or source endpoint is added.

## Alternatives considered

Inferring theme mode from a nonnumeric ID breaks numeric thematic keywords.
Fixing only new engine instances leaves restored providers on stale categories.
Reusing ordinary search without checking order/duration omits the declared
category defaults. Treating any JSON URL as a proven directory guesses the
uncaptured resources' schema.

## Consequences

Configured object directories and restored source instances use the declared
category recipe. Invalid configuration cannot silently produce a different
catalog, and hot proxy changes cannot reuse another route's cached directory.
Directory refresh can now fail where stale general categories previously hid
the failure. Accepted categories can remain cached for up to five minutes.

Plain URL aliases, presets, account sections, cookie resources and interactive
filters remain outside this scope. No account field or real profile is modified.
A native client bound to the new core has not yet verified this directory or a
selected public item's detail, exact episode, resolution and frames/progress.
The seven plain URL resource bodies remain uncaptured. The old v56 core does not
include this change. Local regressions do not establish all-source playback.

## Verification

The coordinating task qualifies the original eleven cases in a fresh `cfe8aea`
worktree with only the fixture and test-module wiring added. Compilation takes
5m34s: nine behavior cases fail and both empty-ext controls pass. Failures expose
the unrequested directory, unrelated-catalog fallback, numeric-theme region
routing and persisted classes masking the declared recipe.

The original test-source SHA256 remains unchanged through GREEN:
`966c78cb7b5ecd7c7e933a30f9e3814f390e7558af41909818a3017e682828f8`.
Actual local proxy/origin ledgers, parsed categories and provider home/category
outputs provide the observations. The WBI query is checked against an independent
known mixin vector, including keyword bytes, pagination, order and duration.
Restored cases deserialize a synthetic legacy array into the real provider
constructor and change only the API base for loopback isolation.

The six additional guards cover cache reuse, resource/source/store/revision
changes, a rejected replacement route, oversized responses, invalid absolute
resources and unknown categories. They are separate from the original RED.

All following runs use the locked offline manifest at
`rust/sourin_core/Cargo.toml`, `--lib`, and `-- --test-threads=1`:

- `bili_theme`: 17 passed, 0 failed, 0 ignored; compile 5m28s, execution 0.07s.
- `bili`: 64 passed, 0 failed, 5 existing live-network cases ignored; execution
  4.30s. This filter also selects unrelated names containing that substring.
- `csp::provider::`: 37 passed, 0 failed, 0 ignored; execution 0.25s.

Source snapshots are unchanged for each run. Receipts and logs are retained in
`.probe/parallel-astra-1108/native-verify-v57/` as `v57-theme-red`,
`v57-theme-green`, `v57-bili-related` and `v57-provider-related`. No external
directory request, account operation or native playback is part of these results.

## Note audit

The proposed/implemented/rejected keyword audit found no existing decision
owning object-ext theme loading. The routing and honest-contract notes above
own related boundaries and remain in force. The saved-source import notes own
configuration retention; generic UI theme notes and runtime registry proposals
are unrelated. No earlier decision is superseded or archived.

Follow-up (2026-11-11): the
[stable duplicate-ID decision](2026-11-11-themed-directory-stable-duplicate-ids.md)
replaces only the duplicate-rejection sub-decision after a real directory and
qualified RED expose that compatibility constraint. Local GREEN is complete;
fresh native verification remains pending. The Decision above records the
initial behavior and is retained as history.

