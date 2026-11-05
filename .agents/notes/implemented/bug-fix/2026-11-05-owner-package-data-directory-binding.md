# Agent Note: Owner Windows package uses the normal data directory

Status: implemented

Relations: [Native login completion](2026-11-05-pan-web-native-toolbar-and-completion.md)
and [selected Baidu episodes](2026-11-05-baidu-selected-episodes.md) retain their
behavior and isolated test evidence. This corrects only the runtime profile of
their Owner delivery package; neither implementation decision is superseded.

## Problem

Owner reports an empty TVBox homepage after the newly supplied client starts.
The native-login frontend is built with DATA_DIR_OVERRIDE pointing to an empty
probe directory. The later selected-episode package replaces its Rust DLL but
retains that isolated frontend AOT. Starting it for Owner therefore cannot read
the existing source catalog, import provenance, history or preferences.

Read-only inspection finds 72 catalog records and 68 matching import-provenance
records in the normal Windows data directory. The isolated directory has neither
catalog nor TVBox sidecar. The displayed empty-state text corresponds to a
successful empty channel list, not proof of source deletion or network failure.

## Decision

Build a fresh owner-default frontend in a separate scratch project, with
lib/shell.dart as the fixed entrypoint and no DATA_DIR_OVERRIDE. Keep the approved
selected-episode core unchanged. Build isolation and runtime data isolation are
different concerns: scratch output is appropriate for both tests and delivery,
but only automated probes should use a compile-time isolated runtime profile.

tools/verify_owner_windows_package.ps1 reads the actual generated Flutter target
and base64-encoded defines. It rejects the spike entrypoint and any explicit
DATA_DIR_OVERRIDE, including an empty one. It compares every delivered file with
the corresponding fresh Release output and verifies the approved core hash.
The build project's correspondence to the current successful build remains a
required provenance assumption; the guard does not reverse-engineer AOT code.

## Alternatives considered

Copying Owner's source/account/history files into the empty probe profile would
hide the packaging error, fork future writes and risk stale or exposed data.
Changing homepage filtering cannot recover records from a different directory
and would weaken the established imported-channel rule. Neither is used.

## Verification

.probe/owner-package-gate-checks-20261105/summary.json records four checks:
injected isolated-profile and spike-entrypoint faults each exit 1; the actual
previous package and its real generated configuration exit 1 specifically at the
data-directory check; the normal-profile configuration selftest exits 0.
All children are hidden, BelowNormal and proxy-cleared, with unchanged guard
input, no network and no user-profile writes.

An independent reviewer also rejects the actual old package, without SelfTest,
and finds no blocker in the fresh-build binding path. Malformed/duplicate build
configuration and additional delivered-file mutation cases remain useful test
extensions; configuration selftests are not UI acceptance.

The corrected package completes its Windows build with exit 0 in about 303
seconds, recorded under .probe/owner-profile-build-evidence-20261105. It freezes
262 frontend inputs and retains core SHA256
C1E2A547E0A81F0317282415E8D8E3778E91A420365FE18F607BADED6A67AC5C.
Root independently verifies all 42 delivered files against the fresh build,
the actual generated target/defines and the absence of the previous isolated
path in both UTF-8 and UTF-16 AOT content. The optional Android-path JNI library
is not generated when JVM discovery is unavailable; no old DLL is transplanted.
These build checks do not constitute Owner's visible source-loading acceptance.

The first guarded launch refuses because the old package's process is still
running. Root previously misreads mixed PowerShell table output as no remaining
process, corrects that statement, and asks Owner to exit fully. The launch guard
prevents replacement of the existing process and no new client is launched.

## Consequences

No account, source, history or preference file is copied, replaced or deleted.
The current running client is not closed during background work. Owner must
switch from the isolated package to the normal-profile package before testing
the actual source library. UI and real playback acceptance remain Owner's work;
configuration and process checks alone do not prove visible homepage content.
