# Agent Note: Declarative edits preserve source order and disabled state

Status: implemented

Applies to the declaration import/edit command from 2026-11-07.

Current scope from 2026-11-09: the UI save path is superseded by
[declarative source UI retirement](../simplification/2026-11-09-declarative-source-ui-retirement.md).
The Decision below records the preference-retention rationale; it does not imply
that declarative editing remains available. Existing configuration, history and
backups remain intact. General registry preference behavior continues under
[search source scope](2026-11-08-search-respects-source-scope.md).

## Problem

The source composer saves edits through `import_declarative_provider`.
Registering the replacement removes its previous handle and appends a fresh,
enabled handle. A saved source order remains correct on disk while the next
homepage list can display the edited source at the end. A disabled source can
also rejoin registry searches while the settings list still reads its disabled
flag from disk.

## Decision

The import command obtains the existing reconciled order before registration,
then reapplies it after installing the replacement. New ids remain appended.
It also reapplies the edited id's persisted disabled flag to the new handle.
Editing does not rewrite the order or disabled preference files.

This extends the existing [source composer save path](../feature/2026-10-17-source-composer-one-screen.md)
and preserves the [explicit disabled-source rule](../feature/2026-10-29-restore-auto-disabled-sources.md).
The source override proposal, automatic CSP registration, aggregate editing,
and subscription probe-failure notes concern different paths and remain separate.
The November 4 source filtering and ordering note remains applicable.

## Alternatives considered

- Sorting only in Flutter leaves other registry readers and search eligibility
  inconsistent with the user's preferences.
- Calling the order getter only during verification hides the defect because
  that getter reorders the registry as a side effect.
- Changing all registry registrations expands this local edit fix to unrelated
  plugin, startup and subscription paths.

## Consequences

Regression checks observe `list_providers` before an order getter and inspect
`enabled_manifests`, in addition to confirming preference files are unchanged.
The implementation does not make registration and persistence transactional;
storage-write failure behavior remains a separate concern. Revisit this local
restoration if registry replacement later gains an explicit shared contract for
preserving preferences.
