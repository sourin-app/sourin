# Agent Note: PanGuangya requests follow the current global route

Status: implemented

## Problem

PanGuangya is registered and its list and signed-download calls use `post_json`, but it inherits the no-op `CspSite::set_http_context` and keeps a standalone no-proxy client. The policy delivered by `CspProvider::with_proxy` therefore cannot govern those actual sends.

## Decision

PanGuangya uses the existing [CSP routing contract](../architecture/2026-11-09-csp-global-routing-retains-engine-recipes.md). It retains its engine-owned builder, receives the store/provider identity in `set_http_context`, and obtains the current context client immediately before each `post_json` request. Policy and client build failures return errors without an unconfigured-client fallback.

The original eight-second timeout, user agent, POST method, Content-Type, Accept, Cookie value, exact body and envelope checks remain. Credentials, endpoints, account model, listing parser and signed URL parser are unchanged. Client creation becomes lazy at the first request, consistent with the shared context. No independent login or authentication protocol is inferred.

## Alternatives considered

- Retain the fixed direct client: preserves eager client construction and avoids changing the adapter, but leaves this registered engine's actual requests outside the global policy. The shared context closes that reachable helper boundary while retaining the existing recipe.
- Use a generic application client: makes routing uniform, but loses ownership of PanGuangya's user agent and eight-second timeout. The existing context instead applies policy to the engine's builder.
- Reconstruct the site when policy changes: creates a fresh transport reliably, but replaces the site to solve a client-cache problem. The shared context rebuilds its client on policy revision while the existing adapter remains alive.

## Relations

- Partial overlap, retained: [CSP global routing](../architecture/2026-11-09-csp-global-routing-retains-engine-recipes.md) owns the shared builder, provider identity, hot revision and no-fallback contract. This note records the concrete PanGuangya setter and its two request callers; it does not replace the shared architecture decision.
- Partial overlap, retained: [fallback-client rule](../testing/2026-10-28-no-proxy-gate-can-be-bypassed-by-fallback-client.md) suppresses ambient proxy and forbids a default-client substitute. Its current scope explicitly allows readable build errors for migrated engines. The local proxy observations here cover application-policy wiring beyond that source-shape rule.
- Independent, retained: [builtin source exposure](../architecture/2026-10-28-builtin-csp-sources-auto-exposed.md) owns registration visibility. This change preserves PanGuangya's class and registration; it changes its request transport.

No existing decision is fully absorbed, superseded or archived by this adapter migration.

## Verification

At qualification HEAD `5043654e7113337a9f27fb97d398c5e8d70d4061`, the same frozen four-case payload produces three intended runtime assertion failures on the baseline and one passing unbound direct control. The actual assertions observe zero proxy requests instead of two, zero first-policy requests instead of one, and an invalid direct success after configured proxy rejection. Baseline v2 reuses the actual baseline executable and passes its owned-process qualification: normal exit, continuous 8.031 seconds of Job0 and no forced cleanup. Its repository-local receipt is `.probe/qual-guangya-proxy-c15-baseline/.probe/run-guangya-c15-baseline-v2/result.json` (SHA256 `2D833AAB15BCF7302EFD0933842AD240D8C683A1FBAE2EA316A46B009B3EBC6A`).

The candidate's actual owning core is compiled from `.probe/qual-guangya-proxy-c15-candidate/rust/sourin_core` in the v2 Cargo log, and all four cases pass. That compilation run's owned-process qualification fails: one descendant remains active throughout the eight-second drain and forced cleanup is recorded. The v2 result remains a failed qualification; it does not establish a successful build-process exit gate.

Runtime v3 separately executes an ordinary byte-identical copy of that actual compiled candidate executable (SHA256 `354241C69254E01B576798195720DB4094E272890A770A8D766E5C30328E93C2`), with its compiler source/log/receipt anchors checked before and after execution. All four exact cases pass again; the owned Job drains in 0.051 seconds and stays at zero for 8.034 seconds without forced cleanup. Its repository-local receipt is `.probe/qual-guangya-proxy-c15-candidate/.probe/run-guangya-c15-runtime-v3/result.json` (SHA256 `B8E402161EB7670456903B4C969FD88C74863F06F1029AF92B6D78274FEE86C2`). This runtime result does not relabel the v2 compiler-descendant failure as success.

Compatibility reuses the same actual candidate executable and passes exactly twelve selected cases: the four routing cases and eight existing protocol/parser/home/search/registration controls. The two existing tests `csp::pan_guangya::tests::empty_listing_is_an_error` and `csp::pan_guangya::tests::every_path_without_account_says_login` read `pan_auth` and are explicitly excluded, not run or accepted. The selected harness reports 12 passed, 0 failed, 0 ignored and 2691 filtered out; those counts do not describe the whole library suite. The owned Job stays at zero for 8.039 seconds after normal exit without forced cleanup. Its repository-local receipt is `.probe/qual-guangya-proxy-c15-candidate/.probe/run-guangya-c15-compat-v2/result.json` (SHA256 `A3BCB0D55F4694F6929FDDD301A8F9FD618CE7936CD8D687830A583E8AFC9703`).

Both candidate runtime runs use their own probe-local `USERPROFILE`, `HOME`, `APPDATA`, `LOCALAPPDATA`, temporary directories and `DATA_DIR_OVERRIDE`, two logical CPUs and below-normal priority. The integrated owning source including its `cfg(test)` module is SHA256 `C2E6D5B50A61D6B8E539ADA75F1790A8180C85ADE607CD82DBD017A7C396E550`; the independent routing-test payload is SHA256 `5E0D4736E5912950277F05190D4218CD677032BC909888F34E413DA4723F590E`.

The permanent independent four-case module uses the same frozen payload as qualification; it does not contain a copy of the owning implementation.

## Consequences

The current route reaches the two existing request callers, the next request observes a policy revision, and a rejecting configured proxy cannot become direct success. The unbound direct control retains the original request recipe.

The four routing tests issue real loopback HTTP requests through `post_json` with a fixed synthetic Cookie and never read `pan_auth` or call account-facing `list/play`. The compatibility selection excludes the two existing account-reading cases rather than allowing them to consult the Owner's credentials. These results qualify helper routing and the selected protocol/parser/registration checks; they do not establish real cloud authentication, file selection, signed-media playback, native UI, ordinary application graceful quit, all-suite success or full proxy coverage.
