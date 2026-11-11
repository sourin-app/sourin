# Agent Note: Fullscreen return owns embedded playback restoration

Status: implemented

Applies on 2026-11-11 after the cb613bf baseline. This complements
[the shell playback handoff](2026-10-23-live-shell-playback-handoff.md)
and [embedded mute/intent separation](2026-10-24-live-embedded-mute-intent-and-probes.md).
Those snapshot and native-disposal contracts remain in force.

## Problem

The real route observer publishes visible-again synchronously on pop, before
the awaited fullscreen callback adopts its exit snapshot. The generic visibility
handler can start resume using the old pause intent. A delayed volume command
then lets that resume issue play after the newly returned snapshot says paused.
Route completion, widget disposal and native disposal are distinct events.

The first native pause also yields before navigation. Without an owner claimed
before that await, two fullscreen requests can both push; failed navigation can
leave embedded playback paused. Resume itself must recheck ownership after its
native volume/play awaits when the page hides, retires or adopts a pause.

## Decision

LivePage claims the fullscreen handoff before its first await and rejects a
second entry while that handoff is active. Generic visible-again resume defers
while this owner adopts the returned snapshot. Hidden transitions still pause.
The handoff consumes the visibility pause flag and performs the return decision
once, guarded by generation, mounted state, embedded instance and visibility.
A returned paused snapshot explicitly pauses before audio-only restoration;
restorePlaying:false retains its independent metadata-only contract.

Navigation failure releases ownership in finally and attempts controlled
restoration of the previously accepted intent without hiding the original
error. The existing pending-fullscreen-channel path still preserves returned
intent. Returning while hidden retains pause/play intent for later visibility.

The embedded player gives pause/resume a command generation. A pause retires
an earlier resume before any await. Resume rechecks current native identity,
generation and visibility after volume and play. An already-issued play that
finishes while the owner still requires pause/hidden is followed by pause;
hidden volume is suppressed. Settlement rechecks its current generation after
its own awaited mute. Stream replacement and disposal also retire old work.

## Alternatives considered

Waiting only for the route transition does not stop the synchronous visibility
resume. Merely changing the final userPaused flag leaves a prior resume alive.
Changing restorePlaying:false into a hidden pause would alter its public
metadata-only contract. A full native-command serialization queue would expand
this patch beyond the qualified direction of the race.

## Verification

The original four cases use real LivePage, Navigator, ShellOcclusionObserver
and handoffLivePlayback, replacing only native command leaves and fullscreen
exit reporting. Clean cb613bf produces one paused-return behavior failure and
three controls; the unchanged four cases pass on the fix.

Six additional cases cover reentry, refused navigation, hidden return for both
intents, disposal while volume is held, and hiding while play is held. The first
double-entry instrument released a real-zone gate from the fake zone and is
excluded as qualified evidence. Its corrected version releases/drains both
original entries in the real zone, waits for both entries to reach a push or
finish boundary, and retains the exact-one-push assertion. The other five cases
are unchanged. Clean baseline now has four behavior failures and two controls,
including an observed two-push counterexample without an observation timeout.

The final related run passes all ten new cases and reports 57 passes and two
failures overall. Both failures are older source-shape guards; the unchanged
pair of suites on clean cb613bf reports nine passes and the identical two
failures. They remain explicitly unresolved. Source snapshots remain unchanged
through each serial --no-pub/--concurrency=1 run. Targeted analysis retains only
the two info-level diagnostics reproduced on baseline, with no new warning or
error. Native Windows playback remains a separate acceptance gate.

## Consequences

The subsequent [native-open request check](2026-11-11-live-open-requested-playback.md)
also uses the existing guarded resume path after initial and channel opens.

Returned pause intent has one restoration owner, and stale resume work cannot
silently take over in the qualified schedules. The tests mount a real PlayerPage
object only as the handoff report contract; its fullscreen native State is not
mounted. They do not prove outgoing decoder silence, transition release or audio
capture. The lifetime control explicitly keeps route pop, transition completion,
widget disposal and held native disposal separate.

Already-submitted native commands cannot be revoked by generation checks. The
reverse direction of a delayed old pause/mute versus a newer resume is not fully
serialized by this change; neither complete command ordering nor correct audio
for every possible interleaving is claimed. A future queued transport policy
needs its own independent schedules and native evidence.

The note audit finds the linked handoff/mute decisions as partial overlaps and
adds reciprocal links. Player seek generation, live quality menus, visible-row
reveal and selected cloud-file identity retain distinct scopes. No prior
Decision is reversed or absorbed; no new test skip or playback fixture media
request is introduced.


The subsequent [pending user request contract](2026-11-11-live-pending-user-intent.md)
qualifies the opposite pause/mute completion schedules using the installed shared
native command lock. It adds pending intent ownership rather than another queue.
Its twenty cases do not establish native Windows audio/decoder acceptance for all
possible interleavings, so that boundary remains separate.
