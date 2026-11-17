# Agent Note: Detail and library contracts use actual page behavior

Status: implemented

Applies: 2026-11-17, `test/detail_follow_test.dart` and its scoped helper.

This extends [library Miuix fixtures](2026-11-11-library-miuix-fixture-migration.md)
and [actual detail action rendering](2026-11-08-miuix-detail-action-contracts.md).
The note audit also found [source contract gates](2026-10-22-source-contract-gates-read-product-code.md),
whose compile and falsifiability requirements remain applicable. The proposed
detail HTTP-error checkpoint concerns transport error privacy, not these UI
contracts, and is unchanged. No product behavior or visual decision is replaced.

## Problem

Three existing assertions fail on both the current tree and the clean earlier
baseline. They require a trailing argument comma, a particular flat-source
conditional, and retired tab labels. These spellings do not establish whether
the selected source reaches the backend or whether the real page renders the
right selector, badges, counts and lists.

## Decision

Replace exactly those three registrations with widget behavior tests. Keep all
other cases and the original source-contract parser unchanged.

Mount DetailPage under the real theme host and intercept only its established
async core transport. Starting on source A and tapping the actual source B
control must produce exact `get_episodes` requests and replace the visible
episodes. A two-source page must render its count badge and both choices; a
one-source remount must hide the badge and picker while still loading and
showing its episodes.

Mount FollowPage with the existing library transport fixture. The real
ShelfTabs must display the current 追更/收藏/历史 labels and different counts
1/2/3. Actual taps must select and render the corresponding distinct lists.
The history total deliberately differs from its one-row preview, so an
implementation that substitutes preview length cannot satisfy the assertion.

Fixtures preserve transport state, disable real disk cache, provide no cover
URLs or accounts, reject unexpected commands, and unmount before restoration.
They do not inject page State or call private selection setters.

## Alternatives considered

Changing the source substring to a newer spelling preserves the same weak
instrument. Deleting or skipping the tests discards the contracts. Testing only
standalone selector/tab components misses the pages' request and data wiring.

## Consequences

The coordinating agent's complete `detail_follow_test.dart` run reports 85
passes, zero failures and exit zero. Its original execution is retained at
`.probe/goal-resume-20261115-evening/line-sync-detail-follow-behavior-v1/`.
Natural empty Job observation lasts 8.0401311 seconds, without forced cleanup
or cleanup errors. The file keeps 82 textual registrations and zero skips;
parameterized registrations account for the 85 executed cases. This is a
single-file widget result, not a complete repository or native acceptance.

The initial positive runner freezes its selected test and product libraries
but omits imported support helpers. A successor mutation runner freezes the
whole `test/support` tree with the selected test, dependencies and product
sources. Four clean detached worktrees contain one product mutation each:
wrong source argument, single-source picker shown, history preview count used
as total, and the retired first tab label. Each produces the expected real
business failure: the second request repeats source A instead of B; a forbidden
single-source picker is present; counts become `[1, 2, 1]` instead of `[1, 2, 3]`;
and the current `追更 1` label is absent. All four actual test processes exit one
naturally, keep Job0 for at least eight seconds and require no forced cleanup.
Compilation and fixture failures are excluded from this negative-control result.

The successor positive run freezes all imported support files and passes the
same 85 cases, exit zero, with natural Job0 8.0438917 seconds. Targeted analysis
of the two modified Dart files reports no issues and exits zero. The aggregate
receipt is
`.probe/goal-resume-20261115-evening/DETAIL_FOLLOW_BEHAVIOR_MUTATIONS_20261117_V1.json`.
These results establish the scoped tests' behavior and falsifiability. They do
not establish native UI, full-repository or whole-delivery acceptance.
