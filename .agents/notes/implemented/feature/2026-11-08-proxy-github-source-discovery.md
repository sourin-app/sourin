# Agent Note: Proxy-required GitHub discovery with manual source installation

Status: implemented

Applies: 2026-11-08, Rust discovery commands and Flutter source management.

Independent: Keyword audit of proposed/implemented/rejected notes found no GitHub discovery contract. Per-source plugin proxy routing concerns installed playback providers, while source-composer and aggregate editing concern explicit user imports. Those decisions remain unchanged; this feature has a distinct strict discovery transport and candidate state.

## Problem

Finding public configurations requires manual repository searches. Automatically registering every result would bypass user source choices. Ordinary provider probes can dispatch script implementations that do not use an injected HTTP client, so reusing that whole probe path would silently bypass a required proxy.

## Decision

Discovery requires an explicit HTTP/HTTPS/SOCKS5 proxy. Its client disables environment proxy bypass, upgrades SOCKS5 to remote DNS, and has no direct fallback. Search, trees, raw configuration reads, redirects, validation and revalidation all use it. Responses are capped at 2 MiB, redirects at three, and each request has connection/response deadlines. Public HTTP targets only; no downloaded script or plugin is executed.

Search inspects up to five topic repositories and twelve likely configuration files, with a per-repository share of the budget and native entries prioritized inside each configuration. Up to 48 distinct candidates are validated with concurrency four. Collection has a 90-second deadline and the whole scan a 105-second guard, both below the FFI client's 120-second timeout. Partial results survive the time budget; failed repository/config requests produce a visible warning instead of claiming a successful empty scan. Native JSON catalog candidates need valid category ids/names and at least one content id/title. Their API normalization is identical to the installed native provider. Script types are listed as unsupported until every underlying request can be proven to use the required proxy.

Candidates, provenance, settings and thirty notices persist in github-discovery.json. Corrupt files fail without replacement. The latest 200 uninstalled candidates are retained; installed provenance is retained. Status derives installed state from the registry so deletion permits reinstall while preserving attribution. Automatic discovery is opt-in and checks once per day while the application runs; isolated test environments suppress autostart.

Manual enable revalidates, uses the existing TVBox builder, and persists a disabled gate before writing any source record. Source-list mutation holds its write lock and does not restore an old whole-list snapshot. Metadata and aggregate membership complete before the durable enabled gate changes. Failed intermediate writes leave the source disabled across restart. A persisted pending-install marker keeps retry available even after bootstrap has loaded the incomplete record; later discovery preserves this marker. Existing registered providers are never overwritten. The regular TVBox updater receives no GitHub subscription URL; discovery provenance is separate, preventing that updater from downloading the repository outside this proxy boundary.

The discovery page provides proxy settings, candidates, explicit enable and persistent messages. Settings, source management and unread homepage notices link to it. Enabled sources and aggregate children show GitHub origin. Validation covers catalog availability, not playback or future uptime. Normal playback follows its existing per-source networking policy after the user enables the source.

## Alternatives considered

- Reuse all TVBox probes: script dispatch can ignore the strict client.
- Fall back to direct networking: contradicts the requested proxy requirement.
- Auto-enable successful results: overrides user source selection.
- Treat stored providerId as installed forever: removal makes a candidate impossible to reinstall.

## Consequences

Eight core tests pass with NO_PROXY=* and local HTTP proxy fixtures: request routing, no auto-install, revalidation/provenance/reinstall, unavailable-proxy zero-origin-requests, URL semantics, malformed data/redirect/response limits, interrupted install followed by retry on the newly bootstrapped state and newest-candidate retention. The UI test observes calls and only enables after a click; it also verifies reinstall and read notifications.

A separate real GitHub request through the configured local proxy completed in 7.69 seconds, found 24 script candidates and recorded two incomplete requests. All 24 were correctly unsupported; zero real sources were installed. This establishes external discovery transport for that run, not a usable remote native source or playback. Reconsider unsupported script handling only when its entire network path can honor this boundary.
