# Agent Note: Preserve native catalog lines and open direct media without HTML parsing

Status: implemented

Applies: 2026-11-08, native TVBox catalog detail and stream resolution.

Related: [Selected episode and real line switching](2026-11-04-selected-episode-parser-and-real-line-switch.md) establishes selected-episode identity through playback. [Windowed player controls](../feature/2026-11-08-player-direct-controls.md) exposes the line selector. This extends those contracts to native JSON catalog providers; it does not replace their script or cloud handling decisions.

## Problem

Native catalog detail retained only the first group of vod_play_url and discarded vod_play_from. The new windowed selector therefore had no additional lines to display. Resolution also fetched explicit MP4 URLs as HTML before trying a parser, adding delay and potentially replacing the selected media address.

## Decision

Parse every declared group and preserve its line name. Empty or repeated names get distinct labels. First-line episode ids remain the original URL, preserving saved history. Later lines include a validated line index before the URL so lines sharing media URLs still have separate selection identities. Resolution decodes this identity before opening the selected media.

Explicit file extensions use the existing direct-media classification before any HTML/parser request. Query and fragment text do not determine the extension. Existing HLS and webpage resolution remain available.

## Alternatives considered

- Only expose more UI controls: the underlying detail has already dropped the lines.
- Use raw URLs for every group: shared URLs make selected-line identity ambiguous.
- Send MP4 through webpage parsing: duplicates binary traffic and can replace a usable media address.

## Verification

Two real local HTTP tests use the production native provider. On the clean pre-change worktree both failed: four expected episodes became two, and direct MP4 resolution issued an unwanted request. With the change both pass. They observe parsed episode flags, stable first-line ids, distinct later-line ids and the actual server request count. This proves the catalog/resolve boundary; native rendering is recorded separately in the upgrade validation report.

## Consequences

The windowed player can receive every native catalog line and keep the selected episode while switching. Direct file playback avoids a redundant binary fetch. Previously saved first-line URLs stay valid. This does not establish availability of arbitrary upstream media or script providers.
