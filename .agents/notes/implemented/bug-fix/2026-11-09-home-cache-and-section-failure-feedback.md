# Agent Note: Home renders cached sections and distinguishes request failures

Status: implemented

Applies: 2026-11-09, HomePage cache hydration, section requests and retry feedback.

## Problem

A preloaded homepage snapshot contains both section metadata and media items. Copying only its items leaves the page behind its loading skeleton until the next metadata request finishes. A cache-hit log therefore does not establish that the user can see cached posters.

Section request errors are also different from successful empty lists. Logging the error while rendering the ordinary empty placeholder hides source outages and leaves users without a local retry action.

## Decision

After resolving the enabled source list, publish the selected source's cached groups, items and non-loading state together, before awaiting metadata. The fresh metadata response still reconciles the current selection and structure; disabled sources never regain visibility from a snapshot. The first successful metadata response initializes the previously unknown fingerprint.

Keep section errors separately from items, keyed by provider and section. Failed refreshes retain previously loaded cards. The current source shows one real Miuix card containing the number of failed sections and a retry action; failed sections with no cards do not render misleading empty rails. Successful empty results retain their normal empty state. Retry sends only failed section requests, disables its action until completion, and clears each error on success. Configuration revision guards reject late errors and retry completions after source changes.

The visible transport summary includes an HTTP failure status when available, never a raw response, signed address or query string. Other failures use a short retry/switch-source message. This does not change proxy routing or upstream availability.

## Alternatives considered

- Delay all content until metadata finishes: wastes already validated cached data and makes an unrelated slow source delay the visible page.
- Treat request failure as an empty list: erases the distinction between unavailable and empty content.
- Replace the whole homepage with an error: hides successful sections and existing cached cards.
- Retry all sources or automatically loop: adds unrelated requests and makes repeated failures expensive.
- Persist transient errors in the content snapshot: couples reusable media data to a past connection failure.

## Consequences

Behavior tests hold the metadata future pending and inspect actual PosterCard geometry, opacity and selection. They also cover disabled sources, late metadata after switching, failed refreshes retaining cards, one retry action, request counts, successful empty lists and late errors after configuration invalidation. Native verification must inspect the new card and logs; this repair does not explain the separate startup raster-thread delay or prove third-party playback.

The note audit found [home card and motion boundaries](2026-11-08-home-card-and-motion-boundaries.md) partially related through the same visible page; its card geometry and transition decisions remain. [CSP routing](../architecture/2026-11-09-csp-global-routing-retains-engine-recipes.md) governs the requests whose failures are displayed here, but does not define frontend loading state. Live channel cold-start decisions concern a different page and are not absorbed. No proposed or rejected note requires treating homepage transport failure as empty content. Reconsider the per-section state only if a shared query model preserves these distinct cached/loading/empty/failed semantics and current-provider ownership.

## Short returns reuse metadata (v15)

Returning to the retained Home still refreshes the personal shelf and provider list. If the provider inputs are unchanged, reuse the last accepted full metadata response for at most 30 seconds. Cache hits never renew that deadline. Manual refresh, source configuration changes, GitHub enable, metadata errors and a clock rollback bypass reuse. Starting a new metadata request clears freshness immediately, so a later tab return cannot resurrect a pre-refresh response while that request is pending. Only the current load epoch may publish a response and renew freshness.

The existing cached-card, section-error, retry and selection contracts remain. This avoids redundant cross-provider metadata requests during navigation; it does not fix the separate glass raster cost. `regression-home-catalog-v15-red.log` reproduces the unnecessary second request; `regression-home-catalog-v15-green.log` passes the cache, failure, invalidation and source-management suite (30 cases). Native callback verification is recorded separately in the implementation plan.


## Source mutation notifications (v17)

The flat source manager previously notified Home after every delegated action,
including cancelling import, paste, edit or removal, a health check, and a failed
save caught by SettingsPage. Successful delegated saves also notified twice.
The speed-order page repeated the same mistake when there were no measurements.

Keep notification ownership with the operation that knows whether persistence
succeeded. Delegated SettingsPage actions notify once immediately after saving,
before awaiting metadata. The source manager still owns notifications for its
switches and provider selection; address dialogs, discovery and manual ordering
retain their explicit saved outcomes. A false backend toggle/removal result is
not a successful mutation. Health checks and speed sorting without measurements
refresh their own displayed data without invalidating Home/search. TVBox's
`ProviderImportCancelled(done: ...)` remains a completed import and must notify.

The rendered SettingsPage → SourceManagerPage tests exercise cancellation,
write failures, a deliberately held metadata reload, one notification after
success, JS source/link install/edit, TVBox's completed-result close, removal,
toggle and speed sorting. The original implementation failed ten of the first
twelve cases; a separate speed-sort regression caught both duplicate success
and false failure notifications. The final related suite passes 45 cases,
including metadata cache invalidation and provider-selection behavior.

The native old-client control opens and cancels the real empty import dialog
twice; it produces two source invalidations and two full Home metadata requests.
The rebuilt ordinary client repeats the same two cycles with zero source
invalidations and zero full Home metadata requests in each cycle. It retains the
same core hash and has zero AX/Flutter errors. The full source-page flow and
existing Home render-boundary capture also pass; details are in the plan. These are mounted production callback/request
observations, not OS pointer hit tests or a frame-rate claim. Static analysis
comparison reports no new findings, zero errors and the same 29 pre-existing
SettingsPage warnings; this change does not claim a warning-free whole file.


## Sparse snapshots and failure freshness (v27)

A fresh source snapshot does not prove every declared section has a result.
Only an explicit items entry, including a successfully fetched empty list,
may suppress that section request. Missing entries remain loading until the
request succeeds or fails. The section uses the shared Miuix spinner; a real
failure retains the existing retry card instead of an empty rail. Failed
sections prevent writing a newly fresh source snapshot.

The sparse-snapshot behavior fails on the previous implementation because no
request is sent. Separate reversals of the loading view and failure-cache guard
fail on the false empty view and the changed snapshot timestamp, respectively.
The related selected catalog/cache/error/invalidation suite passes 27 cases.
An explicit cached-empty control remains empty without making another request.
This repair does not make an upstream HTTP 444 response available.
