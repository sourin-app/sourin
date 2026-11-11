# Agent Note: App-owned native screenshot argument and pixel storage

Status: implemented

The [native-media selection decision](../testing/2026-09-25-native-media-tag-skip-not-exclude.md)
and [first-line annotation gate](../testing/2026-10-30-native-media-tag-gate.md)
continue to govern native test execution.

## Problem

The player page requests JPEG capture with libass subtitles. In the locked
media_kit 1.2.6 helper, its two string arguments use `args.join().length` bytes
for a char-pointer array and do not explicitly write a NULL terminator. On x64,
two pointers plus a terminator need 24 bytes while the subtitles request allocates
23. Source inspection establishes an allocation/termination-contract risk; it
does not establish an observed heap overwrite or explain earlier native crashes.

The returned bgr0/bgra frame can have an unused fourth slot of zero. Treating it
as image alpha hides actual video colors in a PNG. Screenshot disposal also
requires retaining the native lock until the worker finishes with the C pointer.

## Decision

PlayerPage uses the app-owned capturePlayerScreenshot helper. Its native branch
keeps the same initialization waits, NativePlayer lock and compute boundary.
It allocates three typed pointer slots, sets the explicit NULL terminator, owns
each string and result node, and frees successful node contents and allocations
in nested finally blocks. A timeout cannot release the lock while the worker
still uses the player pointer.

The helper validates native dimensions/stride/data bounds using division,
supports existing bgr0/bgra output, copies the complete raw native byte array for
format null, and converts stride-based BGR colors to three-channel RGB for PNG
and default JPEG encoding. RGB PNG is implicitly opaque. Native code has no
fixture-sized dimensions or extra arbitrary memory cap. Non-native backends
retain the original Player.screenshot delegation and arguments/errors.

The existing locked image 4.10.1 artifact becomes an exact direct dependency;
its version and cached package contents do not change. The adapted native
implementation retains the upstream MIT notice and its reviewed internal
NativeLibrary import. Screenshot names, destination, busy guard, entry points
and feedback remain owned by PlayerPage/ClipDownloader.

## Alternatives considered

- Editing Pub cache globally avoids a local helper, but changes unrelated
  consumers and loses a repository-owned source boundary.
- Allocating extra untyped bytes leaves pointer-slot count and termination
  implicit. Typed pointer slots express the actual native command contract.
- Timeout/unlock can make a pending UI return sooner, but permits disposal while
  the worker still owns a native pointer. The lock remains held until completion.
- Keeping the native fourth slot as alpha preserves bytes in an encoded image,
  but bgr0's zero unused slot can make valid colors invisible. Raw output retains
  those bytes while encoded screenshots use RGB.

## Verification

The actual C7 app-helper run exited normally with one real test. Independent
artifact inspection matched all PNG RGB pixels to raw native BGR, recorded
57,600 zero unused fourth slots, checked default/explicit JPEG byte equality,
and observed moving pixels plus ordinary player disposal and Job active zero.

The separate C9 fallback run executed three real delegation contracts. C9 ASS
executed one tagged real native test on a fixed time-pos 2.000000 frame using
bound local MP4/ASS/font/DLL inputs. sid 1 and sub-text OWNED CAPTURE identified
the selected subtitle. Independent PNG inspection found 3,352 changed pixels
inside the declared text ROI and zero outside; disabling the subtitle restored
the exact baseline bytes. The actual Dart JPEG decode observed 3,843 changed
ROI pixels; the independent JPEG reader checked envelope/header rather than
decoding JPEG pixels. All bound sources/dependencies/tools/inputs stayed unchanged,
and ordinary player/Job cleanup completed without forced termination.

Evidence: `.probe/player-cover/native-screenshot-safety/runtime-v1/audits/native-c7-b1-independent.json`,
`.probe/player-cover/native-screenshot-safety/subtitle-v1/runtime-v1/audits/fallback-c9-b1-independent.json`,
and `.probe/player-cover/native-screenshot-safety/subtitle-v1/runtime-v1/audits/native-ass-c9-b1-independent.json`.
Final qualification analysis really exited 1 with zero errors/warnings and one
implementation_imports info. Header cleanup preserves tested import-to-EOF
bodies; native pixel-test annotation is separately checked for correct selection.

## Consequences

The app owns explicit argument and pixel storage without modifying the cache or
the dependency version. Native tests remain opt-in through first-line library
tags; skipped tests are not native passes. The readonly t63 entry counter and
sentinel save-rule tests remain scoped regression evidence.

Public SubtitleTrack.no disables/clears selection; it does not prove native
sub-remove or deletion from track-list. A disposal timer window does not observe
C destruction. Bound Arial input does not independently identify the active
font provider. The helper results do not establish real PlayerPage image saving
and path feedback, remote playback, application graceful quit or Owner package
acceptance. Revisit the internal adapter when media_kit changes its native
screenshot/locking/node contract or exposes an equivalent public API.

The final t63 More regression uses bounded production controller and animation
phases. It keeps all five cases, actual screenshot-row hit/enable/icon checks,
S-key counts, sheet gating and normal menu removal. Its qualified run has five
passes, exit 0, no forced cleanup and zero remaining Job descendants. This is
entry/lifecycle evidence; native PlayerPage capture/save/feedback remains open.
