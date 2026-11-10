# Agent Note: Stable repeated IDs in declared directories

Status: implemented

Applies after the tests-only `23fe9aa` checkpoint on 2026-11-11. Continues the
[duplicate regression checkpoint](../../proposed/bug-fix/2026-11-11-themed-directory-duplicate-regression-checkpoint.md).
The [object directory contract](2026-11-11-object-ext-themed-directory-contract.md)
owns routing, bounds, cache identity and restored-category behavior. This
decision supersedes only its duplicate-ID rejection policy. Its other contracts
and historical verification remain in force.

## Problem

The first actual v57 directory call reaches the new object loader but fails on
its duplicate-category error. The local reference's declared `json` branch
fetches and returns the directory body directly; it has no duplicate-ID error.
The whole-directory rejection is an added host constraint.

One subsequent anonymous public-resource GET through the current application's
configured global proxy returns HTTP 200 with 80,384 body bytes. The body has
243 class rows, 242 unique string IDs and exactly one duplicated row at zero-based
positions 206/207. Both occurrences have the same name. Invalid rows: zero.
The response body SHA256 is
`9b0c78c92366a80f64a9f88d3c6e2051a52bc9551eb6c247041df550705817f4`.
Only shape/count/hash facts are published; resource addresses, category labels
and the full response remain private. No cookie/account operation is involved.

## Decision

After validating each row's nonempty `type_id` and `type_name`, the loader skips
an ID already seen and keeps the first exact ID/name and its position. It does
not sort, trim, case-fold or reinterpret IDs as numeric regions. The cache holds
the same normalized vector. This is an explicit host normalization policy,
not a claim that the local reference performs deduplication.

Validation remains before the duplicate skip. A repeated row with an empty name
must still fail rather than hide behind a previous valid occurrence. The 512
input-row limit, 512KiB body limit, five-second request budget, routing, cache
identity, category membership and no-fallback rules retain their existing scope.

## Alternatives considered

Rejecting any repeated ID keeps an unnecessary host constraint that blocks the
observed valid directory. Keeping duplicate entries makes category identity
ambiguous. Last-wins replacement changes a label after its first occurrence;
sorting changes the declared order. Stable first-wins preserves the first
unambiguous selection while leaving malformed-row rejection in place.

## Consequences

Valid repeated categories no longer reject the declared directory. The first
selection identity and label stay stable without duplicate section keys. A later
different label for the same ID is discarded; an invalid later row still rejects
the directory. This normalization does not implement a new source protocol or
establish media availability.

## Verification

The coordinating task qualifies four frozen loopback tests in the clean managed
`directory-duplicates-red` worktree at committed `23fe9aa`. Compilation takes
4m53s. The real repeated-ID behavior fails specifically with the duplicate error;
three invalid-row controls pass. Source snapshot: unchanged. Execution: 0.02s.
The command uses the locked offline Rust manifest, `--lib`, filter
`csp::bili::theme_duplicate_tests::`, and `-- --test-threads=1`.

Test SHA256 remains
`9b99d627275b34ec37055f9a59705a83f933129b8c559984479207ac23f3922f`.
The original eleven directory and six cache regression files remain unchanged.
The behavior test checks nonadjacent/numeric repeated IDs, differing later names,
first-seen order and cached output through real proxy HTTP; controls reject empty
IDs, empty names and a malformed repeated row. Request ledgers require one
declared-resource read, no direct origin fallback and no account headers.

Safe real-body evidence is retained under
`.probe/parallel-astra-1108/native-verify-v58/directory-body-once-v2/result.json`.
Qualified RED evidence is `v58-duplicates-red-receipt.json` and its log in the same
v58 directory. An earlier helper compile failure dispatched no request and is
excluded from the successful single-GET evidence.

The production edit changes only duplicate `return Err` to `continue`, after
both row validations. The coordinating task then runs the same locked offline
manifest with `--lib` and `-- --test-threads=1`:

- `bili_theme`: 21 passed, 0 failed, 0 ignored; compilation 5m32s, execution 0.08s.
  This includes the unchanged four duplicate cases and original seventeen cases.
- `csp::provider::`: 37 passed, 0 failed, 0 ignored; compilation 0.76s, execution
  0.23s.

Source snapshots remain unchanged. The v58 receipts/logs are
`v58-themes-green` and `v58-provider-related`. Independent review reports no
P1/P2 finding. These local results do not verify an external directory in the
new core or native media playback.

## Remaining verification

Native directory verification still requires a freshly built and hash-bound
core. The current v57 client continues to run the older rejection behavior.
Directory success does not establish list,
detail, selected-episode resolution, real frames/progress or the seven separate
plain URL resources whose bodies remain uncaptured.

## Note audit

The proposed/implemented/rejected duplicate-directory audit finds the two linked
notes as the owners. The checkpoint retains its original tests-only history.
The earlier implemented Decision remains historical; its dated follow-up points
here for the narrower replacement policy and pending native verification. All other
directory contracts and previous test evidence remain in force. No prior note
is archived, and no unrelated UI/runtime decision changes.
