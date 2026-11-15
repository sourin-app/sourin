# Agent Note: JS mutation and reload retain commit ownership

Status: implemented

Applies on 2026-11-15 to JS plugin editing, installation, removal, update,
rollback, source edits and runtime reload. Extends the source-management scope
of [Miuix source management](../feature/2026-11-08-miuix-source-discovery-and-search-controls.md).
[Plugin HTTP proxy routing](2026-10-17-plugin-http-ignored-per-source-proxy.md)
and [exact TVBox parent refresh](2026-11-11-tvbox-origin-refresh-identity.md)
retain their separate transport and non-JS ownership contracts. Existing notes
were searched for plugin/install/update ownership; neither note is absorbed.

## Problem

An update captures local source and installation metadata before downloading.
Removing the plugin while that request is held does not revoke its completion:
the response can recreate the file and a later hydrate can register it again.
Validation, source changes, rollback and installation have the same ownership
boundary. Endpoint success previously writes the catalog inside fetch, before
an outer caller can reject an obsolete response. Reload previously unregisters
all JS providers before hydration and can publish an obsolete staged batch.

## Decision

Reuse source_catalog's existing synchronous WRITE mutex as a short commit gate.
AppState carries checked monotonic JS mutation epoch and reload sequence counters;
all reads, advances and checks occur under that gate. Lock order is WRITE before
registry/third_party. Network, asynchronous validation and hydrate remain outside
it. Named _locked helpers avoid recursively taking WRITE.

Async mutations claim their epoch before await. Update/check additionally capture
the file, full source, metadata and exact origin binding plus endpoint list. On
completion they check epoch and snapshot under WRITE before even same-content
success or catalog attribution. Downloading has no catalog side effects. A valid
success is attributed only to the captured owner and configured endpoint. Reads
capture the epoch without claiming a new mutation intent.

Actual source commits advance the epoch again so scans started during download
cannot publish the old file after commit. File, version archive, metadata and
catalog writes remain in the same synchronous critical section. Mutation-triggered
reload receives the committed epoch rather than claiming a new epoch after await.
Remote install claims before download even while its plugin identity is unknown.
This deliberately permits unrelated JS mutations to cancel one another.

Reload stages existing load_plugins_hydrated outside WRITE, retaining published
providers. It checks both captured epoch and latest reload sequence before any
unregister/register. Publication retains the existing disabled-policy calculation
and saved ordering. Preference persistence uses the same short gate, without
relaxing disabled or sorting rules.

Both source-edit entry points invalidate pending ownership and synchronize JS
metadata/catalog. Clearing removes primary, backups and successful-address state;
saving the same legacy primary URL preserves configured backups, while replacing
it clears mirrors belonging to the previous source. Removing a
JS provider finds its actual filename by @id and removes it rather than merely
unregistering a file which the next scan could revive. Missing-file fallback still
invalidates pending ownership. Removal attempts delete before unregistering, so a
filesystem failure does not silently remove the working registered instance.

Obsolete operations return an explicit expired error, including obsolete
same-content results and superseded reloads; they never report a successful old
publication. Editing an existing file now explicitly rejects changing @id; identity
migration requires installation rather than leaving old registrations behind.

## Alternatives considered

- Check exists after await: still separates the check from the actual write and
  cannot cancel metadata, source-success or registry publication.
- Hold an async lock throughout download/hydrate: delays deletion behind slow
  external work and is not needed for short synchronous commit ownership.
- Claim a new epoch in post-download reload/install code: gives obsolete work a
  fresh owner and permits resurrection after a successful deletion.
- Add per-plugin transactions, new dependencies or a lock registry: unnecessary
  for this first conservative all-JS cancellation contract.

## Verification

A task-owned exact test binary first reproduced the held-update/delete failure
(exit 101 at the file-resurrection assertion), while its no-delete control passed.
The repaired exact binary passes seven JS cases: the held update/delete pair,
source replacement/old-mirror rejection, the held hydrate/delete pair, existing
proxy/fallback/disabled-state readback, and local edit/rollback/source-clear/user
configuration retention. Unrelated missing-provider removal does not cancel a
current JS update. Twelve progress-metadata and thirteen HTML-cover recovery
regressions also pass after adapting their explicit AppState constructors.

Tests install keyring's built-in EntryOnly mock before any bootstrap, use only
loopback fixtures and retain bounded HTTP handshakes; fixture/compile failures
are not behavior RED. Actual runs exit naturally with stable empty owned Jobs
for at least eight seconds and no forced cleanup. The normal non-test core also
builds and starts through FFI in the isolated diagnostic Flutter window, renders
Home and exits via the production quit callback. This is not the ordinary
unmodified release startup, a fresh-process source-settings persistence proof,
or the final current-source full-package acceptance. The same held HTTP fixture also exercises a remote reinstall begun before its
downloaded identity is known: deletion wins over the stale response, while the
no-delete control commits version two. All nine JS cases pass in the same final
test executable. Validation/delete and two-reload completion-order combinations
remain additional coverage boundaries, not implied by these named cases.

## Consequences

Unrelated JS operations may receive an expired error and require retry. Writes
are synchronized within this process, not a cross-file disk/crash transaction or
a protocol against an unrelated external editor. Existing .data and user config
are untouched. Failed commits can leave already-written files or metadata and
return errors; no rollback compensation is introduced that could resurrect an
owner after deletion. Native playback, UI integration, external networks and the
whole product acceptance remain outside these source-ownership changes.
