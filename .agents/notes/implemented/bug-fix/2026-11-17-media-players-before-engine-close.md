# Agent Note: Release media callbacks before engine close

Status: implemented

Applies: 2026-11-17, desktop quit and the three production media player owners.

Related: [core callback detachment](2026-11-16-native-callback-detach-before-exit.md)
protects Rust listeners. This decision covers the separate media library's
wakeup listener. The core fence remains necessary and follows media disposal.
The existing player lifecycle notes govern navigation and visibility; they do
not establish terminal engine ownership.

## Problem

Closing the desktop engine while an HTTP media body is pending can leave a
native wakeup callback pointing into the destroyed Dart isolate. An isolated
reproduction records the actual registered media callback address. The Windows
access violation has that exact address and matching process identity. No media
post-initialization disposal or wakeup-detach event precedes window destruction. Core callback
detachment alone does not protect this separate listener.

## Decision

All three product player creation sites use AppPlayer: playback, embedded live
playback, and skip-marker preview including its pending initialization stage.
A registry retains active players and asynchronous disposals from previous
routes. Disposal is idempotent and concurrent quit calls share the terminal
Future. Shutdown rejects new players, retires owner work, and waits for native
player disposal before the core fence and window close.

The library must keep its wakeup listener alive while stop and video release
are completing; its own dispose then clears the native callback. The app does
not modify the dependency cache or detach the wakeup function early. Normal
route disposal remains asynchronous and tracked. Propagated disposal failures
prevent engine destruction rather than being counted as a completed fence.

## Alternatives considered

Sleeping or imposing an exit timeout does not establish callback safety.
Detaching wakeup before stop can prevent pending command replies. Closing only
the visible playback page misses retained live playback and pending preview
players. Relying on widget dispose after engine teardown runs too late.

## Consequences

The shutdown barrier establishes completion of the library's video release
and callback detachment, not immediate physical destruction of every native
handle: the pinned library schedules final handle destruction separately.
The library catches some video-release callback exceptions internally; a
successful Future alone does not establish success of every plugin release.
The native pending-transport reproduction remains the acceptance criterion;
unit tests alone do not qualify it. Reconsider this wrapper if the dependency
provides an equivalent application-wide shutdown contract.

The pending-HTTP successor now records video release and wakeup detachment
before the core fence and engine teardown, exits zero in 5.658 seconds, and
drains naturally for 8.029 seconds. The original fault and diagnostic remain
failed receipts. Forty-five related behavior cases pass. An isolated copy
removing only the awaited shutdown barrier fails the real AppTray close-order
assertion; its reference passes. Both sides use the same cleanup-safe test,
which waits for either disposal entry or premature quit and always releases
its test gate in finally. This avoids a hung negative control without weakening
the requirement that no close-prevention or close call precede media release.
