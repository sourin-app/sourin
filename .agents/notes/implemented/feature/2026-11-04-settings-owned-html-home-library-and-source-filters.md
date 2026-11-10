# Agent Note: Settings-Owned HTML Home Library And Source Filters

Status: implemented

Relations: [HTML homepage V1](2026-10-31-webhome-html-homepage.md) retains the
renderer, bridge and sandbox. This decision moves configuration to settings
and replaces its single body with a named library and compatible migration.
[Aggregate edit separation](2026-10-29-aggregate-edit-split-and-note.md) retains
its distinct command-backed editors; filtered batch controls extend site
management without changing source identities or fan-out configuration.

## Problem

Owner requires HTML homepage configuration to live in settings rather than in
either the native or HTML homepage toolbar, with multiple named configurations.
Source management already supports import, edit, ordering, subscriptions and
per-source panels, but finding a source or selecting a subset of aggregate sites
is inefficient.

## Decision

`WebHomeSettingsPage` is reached from the existing settings entry list.
Both homepage views remove their configuration action. The HTML view retains
return-to-native; its unused optional constructor callback remains for callers'
compile compatibility.

`WebHomeController` stores a v2 `webhome/library.json` catalog with named entries,
an active id and an enabled flag. HTML bodies use immutable revision filenames.
A flushed temporary body is renamed before an atomic catalog replacement.
The catalog is the commit point: failed replacement preserves the previous body
and metadata, while legacy preference synchronization cannot roll back an
already committed template. Obsolete bodies are removed only after commitment.
Refresh, save, activate, delete and disable share the serialized operation queue.

Existing `home.html` is migrated once and retained unmodified. Malformed catalogs
block mutation instead of overwriting recoverable data. An unreadable active
body causes session fallback but leaves a valid catalog editable for repair or
selection of another template. Editing/deleting an inactive template does not
clear the active homepage's session fallback. Explicit activation, active-body
replacement, active deletion or native selection clear it. Active deletion
selects native rather than silently choosing another template.

The editor supports a name, file-path import, HTML content and an explicit
save-and-activate checkbox. The checkbox receives its own transparent Material
ancestor inside the existing glass dialog, as required by `material_ui`.
The home WebView key includes selected identity and body hash so a selection or
active-body replacement recreates the view.

The source-management layout and filtered-card sorting part of this decision is
superseded by [flat Miuix source management](2026-11-08-miuix-source-discovery-and-search-controls.md).
Filtering remains local and never changes provider ids or capabilities. Hidden
providers stay excluded. The separate ordering page edits the full managed list,
shows provenance, and retains the manager filter on return. The homepage-template
storage, lifecycle and mutation decisions above remain in force.

Aggregate-site search and selected/unselected filters use the existing selection
set. Select/clear-current-results changes only visible implemented site ids,
preserving offscreen selections and unsupported-site identity. Existing
subscription management, solo mode, dedupe and save paths remain unchanged.

## Verification

- Initial pre-change behavioral gates: 0 passed / 5 failed. Missing controller
  methods were exercised dynamically; existing homepage/source wiring failed
  its explicit expectations. Launcher encoding errors and compile failures are
  not behavioral-red evidence.
- Editing an inactive template incorrectly cleared fallback: actual red, then
  repaired. A valid catalog with a missing active body could not be repaired:
  actual red, then repaired.
- Corrupted catalog overwrite was actually rejected by the new test only after
  the load-failure guard was added. Failed catalog rename preserves original
  content and removes the uncommitted new body.
- Hidden-provider mutation (`visibleProviders` bypass): 0 passed / 1 failed,
  because `hidden` appeared. Offscreen-selection mutation (empty seed set):
  0 passed / 1 failed, because `outside` disappeared. Both mutations are restored.
- Editor widget tests at 320x640 and 1280x800: actual 0 passed / 2 failed for the
  missing local Material ancestor, then green after repair.
- Combined headless regression: 140 passed / 0 failed, exit 0. This includes 15
  new catalog/filter/wiring/widget cases and 125 existing webhome, provider
  reorder/layout/import, aggregate dialog and subscription-management cases.
- Final refresh-queue, native-fallback-message and filtered-arrow adjustments:
  the same 15 new cases plus 19 provider-card cases rerun, 34 passed / 0 failed.
- The legacy preference failure test creates a directory at `ui-prefs.json`:
  the real preference write fails while the committed body/catalog remain valid
  and reload returns the selected homepage. `UiPrefs.flush` currently catches
  its own IO failure; the added outer isolation is defensive, not evidence of
  an existing propagated exception.
- Tests run BelowNormal without a visible client, with proxies cleared and
  isolated application directories. Widget filesystem IO uses `runAsync`.
  Stopped waiting runs are not counted as completed tests.
- Scoped analysis reports no errors. Existing warnings in the large settings,
  home and aggregate modules remain outside this change; new webhome brace
  notices are corrected. Notes tree/format/archive and supersession checks
  pass. Coverage in the child sees an empty staged set because staging is
  reserved to Root; Root must rerun coverage after staging the actual batch.

## Alternatives considered

- Keep homepage configuration buttons and add settings as a second entrance:
  rejected because Owner explicitly requires moving configuration into settings.
- Keep a single mutable `home.html` per selection: rejected because it cannot
  preserve multiple named configurations and can lose the old body if saving
  metadata fails. Revision bodies plus one catalog commit provide a smaller
  recoverable transaction boundary.
- Rewrite shared reorder logic to preserve nonvisible absolute slots: rejected
  because its established contract preserves relative order, not fixed slots;
  filtered controls can reuse that contract without changing all callers.
- Make batch selection replace the whole selected set: rejected because clearing
  a filtered view would also disable sites Owner cannot currently see.
- Build new source import/subscription forms: rejected because the existing
  command-backed forms and per-source panels already own those behaviors.

## Consequences

HTML homepage configuration is settings-owned, named configurations persist
independently, and source/site filtering does not change underlying identities.
Invalid or unreadable stored data does not masquerade as a successfully enabled
homepage. Catalog parsing remains strict, and legacy migration files remain
available for manual recovery.

These are offline behavior and widget-geometry results, not real-device visual
acceptance or proof that a WebView rendered a particular custom HTML document.
Root owns the unified build/deployment and direct visual acceptance. This child
does not start clients, access credentials, perform cloud playback operations,
stage or commit. Existing frozen probe scripts and evidence remain untouched.
