# Agent Note: Live open uses the current playback request

Status: implemented

This extends [pending user request ownership](2026-11-11-live-pending-user-intent.md)
and [fullscreen return ownership](2026-11-11-live-return-playback-ownership.md).
The existing successful-command reporting, native lock, source retirement,
visibility and snapshot contracts remain in force. Neither earlier decision
is superseded or archived.

## Problem

Initial/retry and channel-change open awaited the native open and then read
the widget's last built playWhenReady value. A completed or pending button pause
updates request ownership immediately, without rebuilding that constructor.
The stale value could therefore submit play after the requested pause.

Three older guards also failed independently of the behavior they intended to
protect: a regular expression required adjacent open/play statements, a mute
check cast the compatibility slider to the old framework type, and a fullscreen
selection scanner assumed a single-line method signature.

## Decision

Initialize the embedded playback request from playWhenReady when mounted.
After both native open paths, read the current request and visibility, then use
the existing resume method. User commands, accepted snapshots and explicit new
stream selection already maintain this request. Resume retains the existing
command-generation checks and settlement for native work already submitted.
No second native queue or whole-page rebuild is introduced.

Replace the obsolete source-shape guards with actual LivePage, navigator,
visibility, selected-stream, media construction and native-command behavior.
Read the real Miuix slider beneath its compatibility wrapper. The transport
boundary fake now implements volume writes because the real resume path also
preserves mute; its newest-stream assertion still requires one play, the correct
media identity, no error and zero muted volume.

## Alternatives considered

Rebuilding the parent on every request would still make native continuation
depend on a scheduled frame, and retirement callbacks can run during child
updates. Adding another native queue duplicates the installed command lock
without fixing stale intent. Keep the request local and reuse guarded resume.

## Verification

The original five-case input failed early on two stale widget-parameter
assertions. Removing only those preconditions preserved actual pointer input,
native queue observation, open autoplay/header checks, final playback and
disposal assertions. The old product then reproduced two actual unintended
resumes. The unchanged input passes after the fix.

A detached dc5d1da baseline with the final behavioral inputs has thirty passing
cases and four intended failures. These cover three distinct schedules: accepted
pause before retry, pending pause during retry, and pause during channel open;
the migrated consistency guard also exercises the first schedule. Normal retry,
initial false policy, a newly selected channel after an earlier pause, hidden
retry deferral, fullscreen selection and mute controls pass on the old product.

The corrected sixteen-suite related run passes 101 tests with unchanged input
snapshots. The preceding 95-pass run has one fake-boundary failure caused by
its missing setVolume method and is not counted as a fully successful run.
Minor formatting, explicit test blocks and analyzer cleanup preserve all
behavior assertions. Five isolated minimal faults each compile and fail their
intended assertion: initial autoplay, switch autoplay, hidden fullscreen stream
resolution, wrong provider, and a muted slider displaying the remembered 64
instead of zero. Final targeted analysis has zero errors or warnings and the
same two existing info diagnostics in the embedded player.
The final changed-file and naming-check run passes all 49 cases.

## Consequences

Paused retry and channel-open completion cannot restore playback from a stale
constructor value in the qualified schedules. Fresh explicit selection still
adopts its new policy. These checks control only core responses and native
command leaves; they do not establish Windows decoder progress, audible silence,
external source availability or desktop acceptance. A route Future left pending
by an intentionally failing test is not evidence of a graceful route exit.

The background-only restriction continues: isolated profiles, below-normal
priority, two logical CPUs and one compiler/test worker. The visible client,
loaded DLL and real user data are not part of these runs.

The [live selection ownership contract](2026-11-11-live-channel-selection-ownership.md) determines which selected stream may reach native open. Cache and deferred-channel ownership complement current playback intent without another native queue.
