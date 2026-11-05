# Agent Note: Native pan login confirmation routing

Status: implemented

Relations: [Authentication freshness](2026-11-04-pan-web-auth-session-freshness.md) remains authoritative for baseline comparison and explicit consent. This note adds a Windows confirmation route without relaxing authentication freshness.

[Native toolbar ownership and verification](2026-11-05-pan-web-native-toolbar-and-completion.md) records the supported composer, DPI layout, native lifetime and production-include fixture separately.

## Problem

Owner reached the Baidu personal file list but the application's confirmation dialog was obscured by its native browser. The draft native callback restarted detection without explicit existing-session consent, so an unchanged valid browser session was never saved.

## Decision

Windows login creation uses `sourin-pan-login-v1` composer arguments. The `sourin/pan-web-login` channel accepts `confirm` only for the mounted, uncancelled current browser ID. Confirmation invokes `_recheck(confirmExisting: true)`, which rereads target cookies, saves through the existing credential command, and requires the existing local account readback before returning success. Busy detection rejects duplicate confirmation. Disposal unbinds the channel. Outbound state carries only fixed waiting/busy/error enumerations and an integer browser ID.

## Alternatives considered

Automatically accept any existing cookie: rejected because stale browser profiles do not prove a new user-authorized login. Detect success from the page URL: rejected because navigation does not prove usable credentials. Keep confirmation only in the obscured parent dialog: insufficient for Owner's actual workflow; the parent fallback remains for non-Windows platforms.

## Verification

The real method-channel widget host first failed with exit 1 and zero save/readback calls. After the consent-routing fix the eleven-file login bundle passed 100 tests with exit 0. Evidence: `.probe/dart-native-confirm-red-20261105.log` and `.probe/dart-native-confirm-joint-green-20261105.log`. Fixtures use synthetic credentials only and do not read keyring or operate Owner's windows.

Follow-up busy interaction gate first failed with exit 1 (one pass, one failure). Ordinary background polling now keeps confirmation available. A confirmation arriving during a background read is coalesced once and reruns a fresh read with explicit consent; duplicates during an actual confirmation or save are ignored. Closing removes the handler, and a save failure sends error state then permits an explicit retry. The twelve-file bundle including all ten freshness tests passes 113 tests. Evidence: `.probe/dart-native-busy-red-20261105.log`, `.probe/dart-native-freshness-freeze-20261105.log` and `.probe/dart-native-freshness-freeze-analyze-20261105.log`.

## Consequences

Local account readback does not prove remote authentication or complete episode playback. Native toolbar build and actual visible UI acceptance are separately required. Cancellation cannot retract an already submitted keyring write; existing session guards prevent subsequent readback or success completion.
