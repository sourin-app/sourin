# Agent Note: Detach native listeners before isolate exit

Status: implemented

Applies: 2026-11-16, Rust async/stream FFI and the desktop quit path.

Related: [stream cancellation terminal handling](2026-11-12-stream-cancel-terminal-handlers.md)
owns per-request completion while the isolate is alive. This decision governs
terminal listener lifetime and preserves that active-session contract.
[Media player shutdown](2026-11-17-media-players-before-engine-close.md) waits
for the separate media wakeup and video callbacks before this core fence.
[Address input semantics](2026-11-16-source-address-submission-semantics.md) concerns
a separate UI tree fault exposed by the same native workload. Other keyword
matches govern loading, playback or login requests and do not own core teardown.

## Problem

Rust async commands retain a NativeCallable listener address after dispatch.
Normal window destruction tears down the Dart isolate while commands may still
finish. A real failing owner records the listener's native pointer before quit;
the Windows access-violation address matches it exactly, with the same PID and
process birth. UI generation checks cannot protect a freed native function pointer.

## Decision

Before the desktop quit path disables window close prevention, synchronously
detach this isolate's async and stream listener addresses through the core ABI.
Keep listener objects alive until isolate exit so already-posted messages can
still be consumed. Reject new Dart async/stream calls after terminal detachment.

Rust checks the address at every async result and stream event publication,
including early errors and the terminal event. A read guard spans native posting;
detachment takes the write guard and therefore waits for posting already in
progress. Results for detached addresses are dropped before native string
allocation. Stream producers stop when publication is rejected. Other addresses
retain normal delivery. Repeated detachment is harmless.

## Alternatives considered

Sleeping before closing does not bound arbitrary network completion. Closing
NativeCallable first invalidates a pointer still retained by Rust. Checking only
before command dispatch misses jobs finishing later. Waiting for every command
can block quit for network deadlines. A check followed by an unlocked callback
leaves the same use-after-detach race. Globally disabling all callbacks would
affect unrelated isolates.

## Consequences

The fence is terminal for the selected listener addresses and does not claim
support for reusing a detached address during hot restart. Listener callbacks
must post asynchronously rather than synchronously invoke detachment while the
read guard is held. The bundled Dart/core ABI must be rebuilt together.

Tests exercise detached versus unaffected delivery, null/idempotent detach,
and detachment concurrent with an in-flight post. Three owning-module tests
pass; a copy removing the detached-address check fails. The rebuilt native DLL
and real Dart NativeCallable deliver a positive callback, then survive 128
async and 128 stream requests to the detached and closed listener pointers.
This isolated check lives eight seconds and drains naturally without force.

The original Windows Event 1000 and failing native owner independently match
PID 38960, process birth, exception 0xC0000005 and the exact listener/fault
address 0x1e5ef470030. The same source-control/cold-restart workload now runs
under three distinct native owners; each retains a live listener before quit,
observes the fence exactly once, exits zero, removes its window and drains
naturally for at least eight seconds. All UI/native error counts are zero.
The audit and its altered pointer/fence/PID controls are retained in
`SOURCE_ADDRESS_CALLBACK_CLOSE_ACCEPTED_V1.json`. The new core SHA256 is
A59BB48FE00802575E5CACBA848DBD146AE6E31741A64A01F110125C1A47D7B3.

This qualifies the diagnostic cohort's terminal callback lifetime. Ordinary
Release, affected playback/protocol evidence and the final package must be
rebuilt and rebound to this core; performance and whole-goal acceptance remain
false. Compiled tests alone would not establish those broader claims.

The production Release Dart bundle and core have now been rebuilt together,
and all 59 packaged file bytes are independently qualified. A normal-entry
private-desktop attempt fails before Flutter with Windows DLL initialization
error; it does not accept ordinary startup. A same-core Profile baseline and
actual GPU warm-up diagnostic both complete the real 20-window workload, observe
the terminal fence and exit zero with natural Job drain and zero UI errors.
They extend the new-core quit evidence to AOT/Profile, while their performance
budgets remain RED and ordinary Release/default-close remains open.
