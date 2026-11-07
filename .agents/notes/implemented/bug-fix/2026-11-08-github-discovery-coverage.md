# Agent Note: Reserve GitHub discovery coverage for native catalogs

Status: implemented

Applies: 2026-11-08, Rust GitHub discovery collection and candidate persistence.

Related: [Proxy-required discovery and manual installation](../feature/2026-11-08-proxy-github-source-discovery.md) owns transport and installation safety. This note replaces that decision's single-cohort sampling strategy while preserving its strict proxy and explicit-enable boundaries. The keyword audit across proposed, implemented and rejected notes found only that overlapping discovery note; native catalog playback and general provider proxy notes govern separate behavior.

## Problem

A shared candidate budget lets large unsupported script catalogs stop collection before a later repository can contribute native entries. A recent-topic-only search misses repositories without that tag, and taking three files hides otherwise reachable configurations. Mirrors with different repository paths or keys repeatedly validate the same installed API. Expanding a single numeric limit does not address those selection biases.

## Decision

Search uses three cohorts: recently updated topic repositories, established repositories matching the configuration ecosystem by name or description, and recently updated repositories describing collection in their readme. Results interleave before the twelve-repository cap, with repository identity deduplicated. Each repository contributes up to six likely JSON/text configurations; requests interleave by repository before the 48-file cap. All reads use the existing strict proxy client, at concurrency four. Pure configuration text may be decoded through the existing bounded base64-wrapper parser; scripts are never executed.

Native candidates have 36 slots and unsupported candidates have twelve separate slots. Each group takes turns across configurations. Native identity is the installed provider's normalized API URL, so differing keys, paths, query strings and fragments do not consume duplicate validation slots. Each decoded configuration retains at most those same per-kind limits while scanning its entries, bounding candidate allocations without letting early scripts or repeated native entries hide a distinct native API at the end. Unsupported candidates are marked directly without issuing their API requests.

Collection has 55 seconds of the 95-second overall budget, leaving validation its own share under the existing 105-second scan guard. Successful repository and configuration counts, candidate counts and deduplication counts persist with the result. Notices expose the repository/configuration coverage. Failed requests and truncated upstream lists produce the existing partial-result warning.

A mirror discovered on a subsequent scan reuses the existing candidate identity. An installed or interrupted-install candidate retains its provider id, pending marker and original provenance. Retention removes duplicate uninstalled native entries while preserving installed provenance, including preexisting duplicate installations.

## Alternatives considered

- Increase the shared cap: scripts still consume the entire native discovery budget.
- Search only the most recently updated topic: topic tags and update frequency do not establish native catalog coverage.
- Execute scripts to improve the success count: their complete network path is not proven to honor the required proxy.
- Include repository identity in the native validation key: mirrored configurations still issue redundant requests.
- Replace installed attribution with whichever mirror appears first: the source page would cease to identify the configuration the user actually enabled.

## Consequences

The coverage tests inspect real proxy HTTP requests and persisted candidate state for later repositories, untagged repositories, configurations beyond the first three, mirrored APIs and installed provenance on a mirror scan. The existing proxy-routing, zero-direct-fallback, malformed-response and manual-install tests remain in force. Synthetic fixtures establish these boundaries; an external native catalog result and playback remain separate acceptance checks.

The scan is bounded discovery, not exhaustive indexing. Search rate limits, repository ordering, unsupported formats, API availability and the time budget can still yield partial or empty results. Revisit sampling caps or cohorts when real coverage evidence shows consistent omissions; do not relax the proxy or manual-enable contract to increase the ready count.
