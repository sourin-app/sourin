# Agent Note: TVBox refresh resolves exact parent identity

Status: implemented

Applies on 2026-11-11 to explicit TVBox check/update, check-all and source catalog
version 1. Extends [actual live refresh](2026-11-11-tvbox-live-actual-refresh.md)
and [live parent provenance](2026-11-11-tvbox-live-parent-provenance.md).
The [subscription clock](../feature/2026-10-31-tvbox-source-update-time.md) remains
separate: its VOD-derived scheduler is not covered by manual origin routing.
[Miuix source management](../feature/2026-11-08-miuix-source-discovery-and-search-controls.md)
retains the flat picker/address editor. No existing owner decision is retired.
The keyword audit classifies sixty notes: seven partially overlap and fifty-three
describe other decisions. No note is fully absorbed or archived. Legacy
[sidecar adoption](2026-11-01-tvbox-subscription-lineage-adopt.md),
[update visibility](2026-10-31-source-update-time-e2e.md) and the
[playlist parser](../feature/2026-10-25-tvbox-lives-m3u-playlist-parser.md)
retain their separate validation and ownership boundaries.

## Problem

A pure-live subscription has no VOD representative, so explicit check/update
rejects it. Deleting a final VOD makes that parent impossible to refresh after
reload. Grouping by URL also merges distinct parents that share a primary URL
and lets endpoint success or newly added VOD ownership affect the wrong parent.
The removed-only VOD dialog reports a deletion option without rendering it.

## Decision

Existing id arguments accept an actual VOD provider or an exact TVBox origin ID.
A resolver validates ownership once under the update lock before any request.
Unknown/non-TVBox targets and conflicting identities fail before requests.
Check items and both update outcomes report originId; ids contain only actual
VOD providers and may be empty. No URL, display name or ID prefix identifies a
parent. The origin fetch uses that parent's endpoint snapshot and records success
against its exact ID. VOD diffs and stamps apply only to the resolved owned IDs.

Check-all enumerates URL-backed TVBox parents as separate identities and retains
uncovered legacy sidecar rows and no-link skips. Same-primary parents keep
separate endpoint chains and results. A legacy row without a catalog owner
uses only its own sidecar address and unowned matching rows; it cannot borrow an
owned parent's fallback, attribution or success/failure stamp.
A URL-less local owner remains in the legacy pairing pool after an actual
provider-sidecar address save. Only a URL-backed foreign parent excludes a row
from that pool; text imports retain existing IDs and do not become duplicate VOD.

A valid lives array can supply a direct configuration with missing sites. Empty
arrays remain meaningful; a present malformed sites/lives section fails rather
than becoming a destructive empty dataset. The downloader and import/check/update
consumers share this shape rule. URLs-only multi-repository results remain
structured non-applicable check results and cannot be directly updated.

First VOD additions use the actual diff/probe/build/persistence path. The catalog
write lock spans synchronous VOD publication and sidecar writing through exact
raw-catalog attribution, before reconciliation can infer an owner from shared URL.
Only successfully created IDs are appended to that parent. Existing provider IDs,
explicit all-off aggregate selection, disabled playlists and independent live
address/cache state remain. Final VOD deletion leaves the URL-backed parent valid.
This lock does not create a transaction spanning the existing VOD/registry/files.

The selected parent summary opens the real update dialog with origin.id. Its
address is read-only and cannot submit/save/clear a VOD sidecar; edits use the
existing source address editor. Old provider dialogs retain editable links.
Item lookup accepts exact response originId or actual VOD ids. A removed-only
VOD result offers the actual deleteMissing switch, default false. Applying the
default reports retention; deletion requires explicit switch interaction. The
model's original hasChanges semantics remain separate from this actionable gate.
Closing an updated dialog notifies/reloads the owning source manager once.
Outside clicks, Escape, system back and the close button use one result-bearing
exit. A pending update or link save keeps its result owner mounted and prevents
dismissal. Failed updates release dismissal without inventing a source change.
The local PopScope intercepts maybePop, and the explicit close carries the
accepted changed flag; shared dialog routing is unchanged.

## Alternatives considered

- Add the origin ID to ids: hides the legitimate zero-VOD parent and conflates
  address identity with actual provider registration.
- Resolve or stamp by URL: same-primary parents can have different backups and
  independent descendants; a URL cannot establish their ownership.
- Reimport to refresh a pure-live parent: bypasses update choices, stable VOD
  identity and the existing persistence/probe path.
- Bind the first VOD after releasing publication: concurrent catalog reads can
  infer the wrong same-URL parent before the explicit binding.
- Make parent addresses editable through the VOD sidecar form: that form owns a
  provider's metadata and cannot replace catalog address editing.

## Verification

Seven independent loopback cases compile on the current committed product and
produce six intended route/identity failures and one invalid-target control.
Two additional cases reproduce malformed-live empty success and omitted
check-all pure-live parents. Independent same-address unowned-sidecar and
URL-less local-owner cases each fail on the first candidate at their actual
ownership/pairing assertion. Corrected production passes all fifty-two catalog
cases, including both boundaries, and eighty-five TVBox cases with eight
existing ignored network diagnostics. Production-only Cargo check also passes;
its ten inherited warnings are not described as clean analysis.
Frozen original seven assertions remain byte-equivalent after Rust formatting.

Five independent UI cases compile on existing Dart symbols and produce four
entry/render/gate failures plus one editable-provider-sidecar control. They use
actual parent picker/dialog callbacks, raw JSON and the default FFI seam. The
unchanged five cases pass on the implementation. UI reload fixtures describe
real callback/identity/render behavior rather than actual registry persistence.
The previous removed-only UI expectation is migrated to an explicit initially
false switch without automatic writes; the unchanged-VOD/no-application control
and all native outcome/deletion assertions remain.
Nine additional actual-dialog cases reproduce seven exit/notification failures
and two passing controls on a frozen candidate regression checkout. The
unchanged nine cases pass after the exit correction; the final eleven-suite
subscription/source-management combination passes all eighty cases. The earlier
run with a nonexistent test path is excluded from whole-run success evidence.

Final catalog/TVBox/UI results, paired diagnostics and source snapshots are
recorded in the current implementation plan. Paired seven-file analysis has the
same ninety-two warnings and seven info diagnostics with zero errors and no
normalized additions; it is not clean analysis. No fixture/compiler failure counts
as behavioral evidence. Synthetic storage, low priority, two CPUs and one worker
retain the user's desktop; no current client or real profile is accessed.

## Consequences

Manual origin refresh and check-all can handle zero-VOD parents without borrowing
another parent's identity. Provider-file, sidecar and catalog persistence remain
separate failure boundaries.
[Parent clocks and scheduled ownership](2026-11-11-tvbox-parent-clock-and-scheduler.md)
extend the actual scheduler and manual result metadata. External services, native
decoder/audio, full desktop UI/performance and Owner acceptance remain separate
requirements unproved by these background results.
