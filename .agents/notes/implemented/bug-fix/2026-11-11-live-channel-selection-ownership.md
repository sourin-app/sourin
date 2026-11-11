# Agent Note: Live channel selection owns asynchronous stream results

Status: implemented

This extends [provider-qualified identity](2026-10-25-identity-must-carry-discriminator.md)
and the [live list and cold-start contract](../feature/2026-10-18-live-channel-groups-and-cold-start.md).
The [fullscreen restoration owner](2026-11-11-live-return-playback-ownership.md),
[pending user request contract](2026-11-11-live-pending-user-intent.md) and
[native-open request check](2026-11-11-live-open-requested-playback.md) retain
their separate native command and playback-intent boundaries. No earlier
decision is superseded or archived.

## Problem

An unchanged provider/channel identity can represent different selection
requests. With A waiting, a user can click B and return to A before the original
request finishes. The original A success can replace the newly accepted A
address, and its error can clear that address. The API cache has a similar
independent race: its explicit invalidation generation does not distinguish
two ordinary misses for the same key, so a late old result can replace the new
cache value even after the visible page rejects it.

Channel-list refresh captures the selected row before awaiting membership.
A later user click can therefore be overwritten when that refresh restores
the old row. When an exact provider disappears, ID-only fallback can also
misclassify a different provider's same-ID row as the restored selection.
The paused-restoration path then retains the removed provider's stream.
Choosing a genuine replacement is insufficient if provider lookup still
borrows the old selected provider merely because native IDs match.

A separate return combination loses the channel selected in fullscreen:
returning while another tab remains active clears its pending adoption before
loading a stream. When the live page later becomes visible, native resume
cannot resolve the missing stream. Same-channel hidden-return tests do not
exercise that cleared-stream boundary.

## Decision

`loadAll(keepSelection:true)` reads the latest selected identity after the
membership await and before replacing the groups. A known nonempty provider
must match the received provider/native pair exactly. Only the legacy
empty-provider path may restore by native ID alone. The actual matched group
provider is carried into `_select`, including a genuine fallback channel;
the global `_providerOf` policy is unchanged. Same-provider paused restoration
keeps its stream and pause intent without another resolution. A removed
provider's replacement follows the existing new-selection policy.

Each actual page stream request captures a monotonically increasing generation
before its first await. Success and error both check that generation in addition
to mounted state and provider/native identity. Fullscreen selection adoption
and page disposal retire old page requests. A same-channel paused-restoration
early return intentionally leaves its valid pending stream request alive;
it does not start a new resolution or silently strand that request.

Each ordinary API cache miss also claims a distinct per-key Object owner after
the normal TTL hit path. Only the current miss with the captured explicit
invalidation generation may publish a prepared nonempty result. The original
caller still receives its own result. A superseded completion cannot publish
or release another request's owner; a latest failed or empty request releases
its owner without handing publication back to an older miss. Per-key invalidate
and global clear remove their affected owners as well as advancing the existing
invalidation clocks. Finally-based identity cleanup keeps the new owner map
limited to in-flight keys. TTL reuse and StreamPreparer remain unchanged.

A fullscreen channel returned while hidden remains pending after the exit
snapshot's pause/mute/volume fields are adopted. Once the page becomes visible
and the route handoff is finished, it resolves that selected channel with the
returned playback intent instead of resuming an empty stream. The pending
channel is consumed once; a newer explicit selection retires it. Hidden return
does not fetch or open the deferred stream, and later visibility cycles do not
reopen an already consumed channel.

The [serial membership refresh drain](2026-11-11-live-membership-refresh-drain.md)
retains notifications received while list loading is active. Each load still
uses the latest selection and the exact-provider restoration defined here.

## Alternatives considered

Identity-only guards cannot distinguish A-B-A requests. A page generation alone
leaves the shared API cache polluted for its next consumer. Invalidating every
channel switch would discard useful TTL reuse, and coalescing all same-key
misses would change the current independently returning caller contract.

Clearing pending fullscreen adoption during hidden return loses the only
remaining instruction to resolve the selected channel. Always resolving it
while hidden would violate the existing fullscreen selection-only contract.
Globally changing `_providerOf` would broaden this fix to unrelated callers;
membership restoration instead carries the provider it actually matched.

## Verification

The isolated dc5d1da baseline with the unchanged eight selection inputs has
three intended behavior failures and five controls. They exercise a held list
refresh after an actual Miuix B-row click, the two A-B-A success/error schedules,
unchanged/missing-row membership controls, distinct native IDs, the same native
ID across providers and a current held result. Raw core JSON still passes
through the real API cache, model conversion and StreamPreparer. The tests read
the actual selected-row semantics and embedded widget stream; they construct
no native decoder.

Five independent API schedules qualify three baseline failures and two controls.
They observe old success after latest success/failure, old completion while
latest remains pending, and targeted/global invalidation with a later same-key
miss. The original callers still receive their own results, cache reads must
reuse TTL without another transport request, and the current result must remain
publishable after earlier cleanup. A page-only intermediate implementation has
nine passes and four cache failures across the thirteen selection/API cases:
the page retains the correct stream, but independent cache observations still
fail. This separates the two ownership boundaries.

Three exact-provider restoration cases qualify one baseline failure and two
controls. They supply an accepted pause through the actual child success
callback, then observe it through a real same-provider refresh and rebuilt
playWhenReady policy. This does not claim to verify the preceding native pause
command. Removed-provider refresh must resolve the surviving provider's own URL
and adopt the new-selection policy; same-provider pause and an actual click to
the other provider retain their respective controls.

The five hidden-return cases qualify two behavior failures and three controls.
They use actual LivePage, Navigator, route visibility, embedded methods, media
construction and the installed native-lock command fake. Both returned playing
and paused/muted intents defer fetch/open while hidden, resolve the correct
provider once on visibility and retain mute/volume. Visible switched return and
a newer explicit hidden selection remain controls. No test mounts a fullscreen
native decoder or observes Windows audio.

The initial thirteen-suite run passes all 73 tests. After qualifying the
additional fullscreen-membership path, the final sixteen-suite run passes all
88 cases with unchanged source snapshots, adding current-member replacement,
empty-state disposal, shell-ordered visibility/list refresh and visibility during
native snapshot restoration. The shared fixture extends the existing native
leaves instead of duplicating them. Runs use isolated
profiles, below-normal priority, two logical CPUs and one compiler/test worker.
Final paired targeted analysis is recorded by the integrator separately; this
test result does not establish clean static analysis or all-repository success.

## Consequences

Selected streams, cached values and deferred channel adoption reject the
qualified stale schedules without adding a second native command queue or
changing the existing mute/volume contract. Tests make no Windows decode,
audible-silence, external-source, current desktop UI, performance or package
acceptance claim. The visible client and its loaded DLL are not updated by
these background runs.

An independent review additionally qualifies an extra hidden stream request
when membership refresh completes during fullscreen ownership. Restored and
removed-member schedules reproduce the same missing ownership boundary. The
refresh now updates the matched selected object and pending metadata, or uses
the existing selection-only fallback when the identity disappeared; it does
not resolve an embedded stream while the fullscreen handoff is active.

Empty groups and empty channel lists already unmount the embedded player.
Two early fixture failures incorrectly expected that player to remain mounted;
they are excluded from behavior evidence. Revised controls observe the actual
empty state, completed native disposal and no new commands after route return
or later visibility changes; they both pass on the original candidate. No new
internal-state clearing mechanism is needed. The full original
UI/source/playback/performance goal remains open.

## Relations

Partial overlaps retain reciprocal links and their original decisions:

- [Provider-qualified identity](2026-10-25-identity-must-carry-discriminator.md)
  owns the provider/native discriminator. This note adds request lifetime and
  exact-provider restoration when membership changes.
- [Live list and cold start](../feature/2026-10-18-live-channel-groups-and-cold-start.md)
  owns snapshot hydration and full-list loading. This note keeps a later user
  choice through that loading boundary.
- [Shell playback handoff](2026-10-23-live-shell-playback-handoff.md) owns the
  initial/exit snapshot transport; this note retains a changed channel after a
  hidden return and does not change route receipt meaning.
- [Fullscreen restoration](2026-11-11-live-return-playback-ownership.md) owns
  route/visibility/native restoration. This note adds deferred stream resolution
  for the changed-channel hidden-return combination.
- [Pending user intent](2026-11-11-live-pending-user-intent.md) owns accepted and
  pending pause/mute requests. Page selection and API publication have separate
  owners; the callback's native-success meaning remains unchanged.
- [Native-open request](2026-11-11-live-open-requested-playback.md) owns play
  policy after native open. This note controls which stream may reach that open.

Lazy-row reveal, source subscription persistence and native decoder disposal
retain their separate scopes. No earlier decision or test suite is archived.
