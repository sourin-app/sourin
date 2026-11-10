# Agent Note: CSP clients retain engine behavior under global proxy routing

Status: implemented

Applies: 2026-11-09, the shared CSP HTTP context and engines explicitly migrated to it.

## Problem

Several installed CSP engines create their own clients with direct routing. A single global proxy setting cannot govern their requests unless that policy reaches the engine's actual request helper. Replacing every client with a generic one would also change engine-specific timeouts, redirects, cookies, headers and authentication state.

## Decision

`CspHttpContext` retains an engine-owned `ClientBuilder` recipe and receives the application's `ProxyStore` plus provider identity through the CSP construction paths. It caches a client by store identity, policy revision and provider id. Clearing an in-memory per-provider route increments the same policy revision as setting a route, so external engine caches cannot keep using the removed proxy. The durable global clear already delegates to the normal setter. A routing change rebuilds only the client; the original site instance, its session fields, mirror choice, counters and caches remain alive. Helpers obtain the current client before issuing a request. Build and policy errors return an error, without substituting an unconfigured client or retrying directly.

The default environment-proxy suppression remains in engine recipes. The application policy is then deliberately applied to that builder. This distinguishes an explicit global proxy from ambient environment settings. The [earlier fallback-client rule](../testing/2026-10-28-no-proxy-gate-can-be-bypassed-by-fallback-client.md) remains relevant, but the presence of `.no_proxy()` is no longer sufficient to prove application routing. The [provider identity wiring](../bug-fix/2026-10-17-plugin-http-ignored-per-source-proxy.md) remains useful even though user configuration is now global rather than separate per-source forms.

Migration is per engine, with local request observations. A wrapper's hook does not cover independent downstream cloud/share clients. Explicitly unavailable engines do not become playable by migrating their client. Counts and execution results belong to the implementation plan; this note does not claim every historical engine is covered.

The [anonymous precheck command](../feature/2026-10-31-tvbox-pan-check-precheck.md) captures an immutable transport for each operation, including its separate Baidu recipe. Its result and cooldown namespaces include the store, originating provider and policy revision. This differs from the long-lived engine adapter because one check batch must not change route between protocol hops. Share listing uses that operation's drive/Baidu/Xunlei clients for pagination and nested folders. Selected-file playback scopes the same immutable checker around the provider resolve future, so inner share helpers, transfer, download and video fallback inherit the captured clients. The scope is Tokio task-local (not OS thread-local); no background task is introduced. Listing during that resolve also reuses the existing operation rather than recapturing a changed policy. Unbound compatibility callers retain the original direct client recipes; failure to build an application-bound operation fails before network traffic.

The FFI cleanup dispatcher captures the current application proxy and scopes all drive cleanup in the same future. It deliberately does not move this path through `with_state_async`, which would switch the execution thread and lose existing thread-scoped credential/endpoint fixtures. Cleanup still uses the original owner/account/endpoint ledger; routing does not broaden deletion rights. A failed delete keeps its ledger entry for a later routed retry. This boundary concerns cloud API routing; media proxy scope is still controlled separately by the global proxy setting.

PanWebShare checks unsuccessful HTTP status before collecting the body. Rejected endpoints may send truncated chunked bodies; collecting those first hides the received status behind a body decode error. Successful responses still use the original decompression behavior, and mirror attempts retain the existing request/total budgets and sticky selection. A failed refresh preserves cached content.

PanWebShare validates each successful response through the existing home, category, search or detail parser before accepting that mirror. An HTTP-200 error page therefore continues to the next configured address, and only parsed content earns sticky priority. Covers retain the final response URL of that successful attempt. Existing parser criteria are unchanged, including a valid homepage with categories but no initial items. All-invalid responses preserve per-mirror reasons under the same request/total budgets; no direct-route fallback or invented address is introduced. Local HTTP regressions cover all four entrypoints, redirected backup cover bases, repeated priority, all-invalid responses and the valid-empty-home control. A built-DLL FFI check additionally exercises import, catalog, search, detail and the proxied cover decoder without cloud-account operations.

The shared subscription downloader also keeps its proxy when trying user-configured backup addresses. Its GET requests carry no account authorization. An HTTP 401/403 response describes that endpoint's failure and therefore permits the next declared address, rather than terminating the whole subscription. Validation still stops a JS update on a different plugin id. Existing time/size limits, response validation and successful-address persistence remain in force; [TVBox subscription lineage](../bug-fix/2026-11-01-tvbox-subscription-lineage-adopt.md) remains a separate identity concern.

## Alternatives considered

- Use one default client for every engine: changes redirect/cookie and request behavior that some engines rely on.
- Reconstruct the whole site on policy changes: loses session identity, signed-request counters and mirror preference.
- Retry directly when the proxy fails: contradicts the chosen routing policy and makes failures misleading.
- Treat source-shape checks as full coverage: misses separate helpers, runtime/restoration construction and downstream clients.

## Consequences

Tests observe actual local proxy/origin requests, preserved headers and content, policy hot changes, construction paths and zero direct requests when the configured proxy fails. Compression and truncated-body fixtures distinguish HTTP rejection from successful-body decoding. They establish routing and lifecycle behavior, not remote availability, third-party playback or cloud-account flows.

The note audit found the routing/fallback decisions and subscription lineage partially overlapping and retained them. Source-composer, source-override, intro-marker and URL-diagnostic notes concern separate paths. No existing decision is wholly absorbed or archived. Reconsider the per-engine adapter only if all engines can express their distinct builder and state requirements through a shared typed transport contract.

[Homepage failure feedback](../bug-fix/2026-11-09-home-cache-and-section-failure-feedback.md) separately keeps request failures distinct from successful empty catalogs and retains already loaded cards. A readable failure card does not establish that an upstream endpoint has recovered.
