# Agent Note: CSP provider groups retain configuration identity

Status: implemented

Applies: 2026-11-11, `source_catalog` provider groups and their selection command.
Extends [Miuix source management](../feature/2026-11-08-miuix-source-discovery-and-search-controls.md).
The [legacy aggregate controls](../feature/2026-10-29-aggregate-edit-split-and-note.md)
remain a separate entry and decision; this changes the current catalog groups.

## Problem

A CSP API names a parser implementation. Two imported sources can share that
API and site key but supply different rule URLs or inline configuration in ext.
Grouping them by key/API alone makes one source look like an alternative
provider of another. Selecting a provider can then disable an independent source.

## Decision

The catalog group identity includes nonempty ext after trimming surrounding
whitespace, alongside the existing site key and normalized API. Missing and
whitespace-only ext retain the existing group identity. Equal configurations
remain alternatives; different configurations form separate groups.

Groups are derived on catalog reads. Provider IDs, subscription origins and
addresses keep their existing owners. Selection persists provider IDs, so
splitting an old group preserves disabled choices and does not revive sources.

## Alternatives considered

- Group by display name: names do not identify a configuration.
- Parse and canonicalize every ext as JSON: ext also contains rule URLs and
  opaque engine recipes. Conservative text comparison avoids merging unrelated
  configurations without introducing another parser contract.
- Clear disabled choices when a group splits: this would overwrite user intent.

## Consequences

Equivalent JSON with different formatting may form separate groups. A future
canonicalization change needs an engine-specific equivalence contract and
selection-isolation coverage. No ext value is added to display labels.

Three regression cases exercise production catalog and selection commands with
isolated data and synthetic providers: configuration isolation during single
and empty selection, missing/empty identity compatibility, and trimmed mirror
grouping while an independent source remains disabled. The clean 01a6495
baseline has two intended failures and eight passing controls. The initial
fixture type error is excluded from behavioral evidence.

All thirty-two production source_catalog cases pass with the source snapshot
unchanged throughout the run. Native client navigation, rendering and playback
are separate acceptance checks; these background tests do not replace them.
