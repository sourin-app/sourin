# Agent Note: Pending live controls own the user request

Status: implemented

Applies on 2026-11-11 to the 0c193bd playback sources. This complements the
[successful-command and route receipt contract](2026-10-23-live-shell-playback-handoff.md)
and [mute intent separation](2026-10-24-live-embedded-mute-intent-and-probes.md).
The [fullscreen restoration owner](2026-11-11-live-return-playback-ownership.md)
retains its route ownership, native identity and lifecycle boundaries.

## Problem

A user pause is not reported until the native command finishes. A route can
hide and show before that completion, causing automatic playback under the
previous accepted intent. Completion while hidden is also discarded by the
old callback visibility gate. Native command serialization preserves command
order but cannot represent the user's pending request.

Mute toggles also read their completed boolean before awaiting native volume.
Two clicks can request the same volume rather than cancel each other. A hidden
return can restore positive volume while an explicit mute is still pending.

## Decision

The widget publishes a separate nullable pending-pause callback before its
first await. Native pause/play still execute, and the existing success callback
still follows successful completion. Only the latest request clears the pending
owner. Earlier native successes remain recorded, so failure of a later request
returns to the last successful command rather than an invented success.

The callback distinguishes settlement from retirement. A settled null after
success or failure may release deferred visibility against accepted intent.
A retired null clears the parent's pending field without starting old visibility
restoration while snapshot adoption or source replacement is still in progress.
LivePage keeps its visibility pause flag while a request is pending. A request
accepted before hiding may report native success while hidden. Automatic
visibility commands never publish a user request or success callback.

Playback and mute each have a retirement epoch plus an overlapping-request
ordinal. Epochs advance only when the request owner is retired. Success must
still own that epoch, native player and transport. Within one epoch, an earlier
success remains accepted while a newer request is pending; only the newest
ordinal may clear pending ownership. A new pending flag cannot revive work from
an older epoch.

The playback owner remembers the last completed or explicitly adopted pause
intent across overlapping requests. Before a new request with no pending owner,
it refreshes that accepted intent: an already-accepted automatic or fullscreen
return resume is playing intent even while native is temporarily paused. This
prevents an earlier completed embedded pause from overriding later accepted
fullscreen play after metadata-only restoration. If the latest user command fails, it restores that accepted native intent
before releasing pending ownership. This covers a visible pause arriving after
LivePage has consumed its hide flag and while an older resume has already
submitted compensating native pause. Restoration errors cannot replace the
original user-command error; no successful user callback is invented.

Mute uses a pending target for the next toggle and automatic volume gating.
The completed muted flag and rendered slider change only after native success.
The snapshot/preference/fallback restore chain and snapshot-before-zero order
remain. A newer failed toggle preserves an earlier successful mute. Resume
rechecks pending/completed mute after an awaited positive-volume restore and
reasserts native zero before play if the unmute failed while restoration waited.

Explicit volume changes retire pending mute. Snapshot adoption retires pending
playback only with restorePlaying:true. Metadata-only restoration preserves a
pending playback request and its eventual success/error callback. Stream open,
retry, replacement and disposal retire source requests. Parent channel selection
and fullscreen channel adoption retire old requests before building the next
channel's playWhenReady policy. Returned snapshots express pending user intent.

## Alternatives considered

Advancing the success callback before native completion would pretend a failed
command succeeded. An additional native queue would duplicate the installed
media_kit command lock. Updating the completed muted boolean optimistically
would violate failure/UI semantics. This change keeps pending intent separate
from the native result and retains the existing native serialization policy.

## Verification

The ten original behavioral tests mount production LivePage, Navigator,
ShellOcclusionObserver and the actual Miuix bottom-bar callback. Only native
command leaves and local core responses are controlled. Every native leaf
uses the installed synchronized Lock. A legal synthetic https .mp4 URL passes
the production jlist/model/preparer path, with native creation disabled and a
selected nonempty-stream readiness assertion. Actual pointer taps wait for the
production double-tap arena to settle. Held commands record queued/start/done;
real-zone drains and bounded disposal checks separate readiness from behavior.

Frozen tests-v5 retain the original ten scenarios and add a widget pump after
mount's completed native volume command, followed by rendered-slider readiness.
The tests-retirement-v3 file supplies six additional scenarios: paused/playing
snapshot adoption, old mute completion after replacement, failed unmute during
held visibility restoration, new-channel build ordering, and visible pause
failure following an older resume. Its second channel has a legal selected
stream; the production source replacement must dispatch and complete a fake
native open and play. No decoder or network is constructed.

Independent baseline qualification of the original sixteen cases produced ten
behavior/native-entry failures and six passing controls. The final four cases
add rapid pause/play parity, earlier pause success followed by later play failure,
failed play during a held visibility resume, and prior pause followed by accepted
fullscreen play and another failed pause. They produce two intended behavior
failures and two passing controls. The full baseline is twelve qualified failures
and eight controls; compilation, readiness, gestures and teardown all complete.
The exact frozen behavioral inputs pass all twenty cases on the implementation.
Each serial isolated run verifies unchanged Rust/Dart/test/manifest snapshots.

Earlier imports, URI, gesture and unpumped mute-locator attempts are excluded
from behavioral evidence. Their frozen inputs and logs remain retained separately.
The production test copies differ only by removing a stale candidate header and
Dart formatting and explicit blocks in synthetic response handlers; assertions
and returned fixture data are unchanged. The direct dev dependency pins the already-installed native
synchronized Lock version; offline pub get verifies no version/lock mutation.
Existing structure guards are migrated to pending-aware predicates and retain
all original assertions and bad samples. Related coverage and analysis are
recorded in the current implementation plan. Final pending-intent plus related
handoff/visibility/guard coverage passes sixty-one cases. Analysis retains only
the two info diagnostics already present in the owning baseline; no new warning
or error remains. The wider related run and its three inherited failures are
reported separately rather than called green.

## Consequences

The subsequent [native-open request check](2026-11-11-live-open-requested-playback.md)
uses this immediate request after initial/retry and channel-open awaits, where
the last widget constructor can still carry the previous pause policy.

Pending requests can protect user intent without claiming native success. Raw
native Future errors remain observable. A failed restorative native command is
reported through the original user-command failure and leaves real acceptance
unproven. These tests establish no Windows decode, audible silence, real outgoing
decoder disposal or Owner UI acceptance.

The note audit classifies shell handoff, embedded mute and fullscreen ownership
as partial overlaps and links them above; none is absorbed or reversed. Seek,
quality menu, selected cloud file identity and row reveal remain distinct scopes.
