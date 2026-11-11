# Agent Note: TVBox live children retain separate parent provenance

Status: implemented

Applies: 2026-11-11, source catalog version 1, TVBox import and flat source UI.
Extends [Miuix source management](../feature/2026-11-08-miuix-source-discovery-and-search-controls.md).
[CSP configuration groups](2026-11-11-csp-provider-group-ext-identity.md)
continue to identify alternative VOD providers. The keyword audit finds source
scope and proxy discovery overlap in attribution but keep separate owners;
no proposed or rejected parent-live decision is superseded.

## Problem

TVBox imports register lives as independent playlist providers. Their catalog
origin owns the playlist URL, while the parent TVBox origin contains only VOD
provider IDs. Filtering by that subscription omits its live children and source
ordering cannot describe their parent. A live-only import has the same gap.

## Decision

TVBox origins persist relatedProviderIds for live descendants, separately from
providerIds, which continue to own address settings. Both the normal and
live-only import paths replace that parent's related set with the successful
import's registered live IDs. Reconciliation deduplicates the set and removes
unknown or non-live references. A playlist shared by several subscriptions may
have several parents without acquiring several address owners.

The flat manager's subscription filter and child count include related IDs.
Source rows and ordering describe the parent subscription names. The live row's
address action still edits its own live origin. TVBox address edits update only
owned VOD metadata; playlist fallback and successful-address state remain with
the live origin and continue through the existing global proxy policy.

The new JSON field has an empty default. Legacy catalogs retain their existing
owners and choices. Missing historical relationships are recovered on the next
successful parent import; provider names and playlist URLs do not establish
parent provenance by themselves. Refreshing one parent cannot erase another
parent's relationship to a shared playlist. Removing a live provider removes
the stale relationship on catalog reconciliation.

## Alternatives considered

- Put live IDs in the parent's providerIds: that conflates address ownership
  with attribution and violates same-kind reconciliation.
- Make the parent JSON the live primary address: the live loader requires a
  playlist and would fetch an unusable JSON configuration instead.
- Infer old relationships from names or URL prefixes: shared endpoints and
  independent imports make such attribution ambiguous.

## Consequences

The data/API change is additive and preserves provider IDs, history and saved
address ownership. Reimporting a parent updates only its attribution set; this
decision does not delete a previously registered playlist provider or replace
source enable choices. Local inline TVBox configurations have no remote parent
subscription and retain their existing local-live description.

Regression qualification uses a clean current-product checkout and the exact
same assertions on corrected production. Core cases exercise both real import
branches, shared-parent refresh, restart, playlist address editing and observed
HTTP fallback requests. Widget cases exercise the actual parent picker, live
filter, source-order rows and playlist editor with isolated synthetic transport.
The clean core baseline has 32 controls and four parent-relation failures; corrected
production passes 36 cases. The final widget baseline has two relation failures
and one legacy control; the six-suite corrected related run passes 23 cases.
The wider run retains six old source-layout guard failures, reproduced on the
current-product baseline. The import-scoped contract does not establish manual/scheduled refresh.
On 2026-11-11, [actual live refresh](2026-11-11-tvbox-live-actual-refresh.md)
extends the real representative check/update path.
[Exact parent routing](2026-11-11-tvbox-origin-refresh-identity.md) covers manual
zero-VOD refresh and check-all. [Parent clock ownership](2026-11-11-tvbox-parent-clock-and-scheduler.md)
extends scheduling without moving playlist addresses or cache ownership.
Fresh results are recorded in the implementation plan. These background tests
do not establish native desktop UI, third-party service or decoder acceptance.
