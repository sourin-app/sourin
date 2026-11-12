# Agent Note: Windows native video disposal order

Status: implemented

Related: [Windows WebView plugin shutdown](2026-11-07-windows-webview-native-shutdown.md) establishes the private-copy compatibility mechanism; this change covers the separate media renderer/core lifetime.

## Problem

The pinned media_kit_video 1.3.1 Windows implementation replies to Dispose before its detached cleanup finishes. Its VideoOutput destructor also signals its waiter while holding the object's mutex, allowing destruction before that mutex is unlocked. Two isolated playback/back runs crashed with libmpv's `mpv_render_context_free() not called` abort and an unowned-mutex diagnostic.

## Decision

Build a private copy of the affected dependency sources using windows/cmake/media_kit_video_shutdown.cmake, following the existing WebView compatibility-patch mechanism. Keep the shared Pub cache unchanged. Free the render context on its existing worker with the EGL context current, release textures and the mutex, then signal a shared promise without further access to the object. Complete the platform Dispose reply after manager cleanup, so Dart's await precedes core destruction. Source-shape checks and a destructor digest reject unreviewed dependency changes.

Serialize render admission and the destruction flag with the texture mutex, then drain pending resize/render work before selecting the final texture for unregistration. Disable the libmpv update callback outside that mutex because it may wait for a callback that acquires it. The current Flutter reply wrapper retains and locks its messenger and explicitly supports replies from any thread.

## Alternatives considered

- Leave the detached cleanup unchanged: it preserves the dependency but reproduces the core/render-context lifetime violation.
- Edit the shared dependency cache: it makes unrelated builds depend on hidden mutable state. The existing private-copy mechanism binds the fix to this project.

## Consequences

Dispose now awaits completed native cleanup. A dependency upgrade requires review of the guarded source transformations. Final full-package validation remains pending.

## Verification

The earlier candidate patch SHA256 was 931ABB97DA22043D997F5F9F67272A0C4451931F0A6D9D0A7C3DEAD0EAD79371. Its bound native DLL was exercised in `.probe/takeover-native-surface-20261112/ui-run-takeover-root-v3/result.json`: three genuine local hardware-rendered playback/back cycles, three destructor records, positive native dimensions and first-frame state before each back, and more than ten seconds of post-dispose survival. The app exited zero through WM_CLOSE and its original AppTray/window_manager path; app and attach Jobs naturally drained and remained empty for eight seconds, with no forced cleanup. None of 5,901 foreground samples selected the test window. This is historical evidence for that earlier patch only.

The separate panel run remains failed: its position assertion rejected a real 75-second single-loop wrap. Its callbacks and absence of logged exceptions do not convert that suite into a pass. Earlier candidate VM-inspection crash, compiler-helper drain failures and runtime timeout remain recorded. The successful limited runtime does not qualify ordinary startup, audio, live/cloud playback, all desktop stability/performance, or a newly built complete package. These remain in the implementation plan.

The current patch is 9760AA14709CD401C3FE38ECC0CDEBB899EFC9C514D3DB4DD24F16E466F09346. The independently checked build-v2 receipt binds its generated sources and DLL 7CE2A30B34163423C9C2556CF395DF3139D8E36999708BBA1BC19F8DB61C4231. The exact-body pending-resize witness fails on the preceding v5 candidate because it unregisters the old texture, passes on the current candidate, and its zero-texture control passes. This comparison uses the pinned FIFO worker with substituted external APIs; it is not an untouched-upstream baseline or actual Flutter texture qualification.

The fresh `.probe/takeover-native-surface-20261112/goal-control-goal-native-v1/result.json` passes all 15 serial steps: three hardware-rendered local playback/back cycles, nine settings/danmaku panel rounds with continuing progress, current screenshot feedback/file, and the actual second local episode with native path readback. Three destructor records and ten seconds of post-dispose survival follow. A separate `goal-control-goal-active-quit-v1/result.json` passes direct production WM_CLOSE during active native playback, with one destructor record. Both applications and their attachment tools exit zero, naturally retain Job zero for at least eight seconds, report no forced cleanup or cleanup errors, and never become foreground. Final retained logs contain none of the checked native abort, unowned-mutex, Dart exception or AXTree signatures.

Both successful runs use the current native DLL with an earlier Debug frontend and explicitly modified nonactivating test startup. They establish the native patch's limited runtime and production-quit behavior, not a final complete-package or ordinary-startup acceptance. Independent source review retains an inherited manager detached-task/destruction risk that these bounded runs do not reproduce; no broader stress guarantee is claimed.
