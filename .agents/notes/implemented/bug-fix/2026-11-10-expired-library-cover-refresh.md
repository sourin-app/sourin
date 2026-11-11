# Agent Note: Refresh expired singleton library covers

Status: implemented

Applies from 2026-11-10 to background library cover repair.

This extends [library cover lifecycle repair](2026-11-08-library-cover-lifecycle.md) to a single nonempty but expired cover. The [cover proxy routing decision](2026-11-10-cover-global-proxy-routing.md) governs the image requests; it does not choose replacement artwork. Existing identity and conditional-update guarantees remain in force.

## Problem

The repair pass considered missing URLs and conflicting stored variants, but
skipped a work whose records all contained the same nonempty URL. A permanently
missing image therefore remained a placeholder even when source details supplied
a new cover. Repeating the same image request could not repair its metadata.

## Decision

Check singleton covers for enabled sources after library records render. A 404,
410 or intrinsically tiny image is a reason to ask the same source for the exact
same media identity. Replace only if returned details keep that identity, the
URL changes, and the new response has poster-sized image dimensions. The existing
conditional database update changes cover fields only and cannot overwrite a
concurrent replacement. Conflicting variants also recognize definite HTTP missing
responses; network errors and unknown image formats remain uncertain.

Use the shared display URL helper so both probes and refreshed images follow the
global API proxy policy and preserve source/CDN headers. Keep work bounded to 24
identities per pass, four requests in parallel, and a four-second budget per
singleton including details and the candidate image. The per-AppState check cache
has at most 512 entries: ten minutes for healthy/updated images, one minute for
uncertain or unsuccessful checks. Overlapping passes coalesce at the existing
repair mutex. Changed URLs bypass the old key. No timer or source search is added.

## Alternatives considered

Probing every catalog image would delay browsing and duplicate image work. A
permanent success cache would miss a later expiry. Accepting the first returned
URL without checking its identity and image response could replace one broken
poster with another. Matching by title could borrow artwork from a different
work. This repair uses the existing library refresh path and exact IDs instead.

## Consequences

[Completed HTML recovery and check publication](2026-11-11-html-cover-recovery-after-save.md)
adds bounded complete-HTML evidence and leaves failed saves immediately retryable.

A real local HTTP regression first failed with zero repairs, then verified that
expired singleton covers update favorites/progress/history without changing their
other fields. Controls cover unknown/outage responses, failed or unchanged new
images, wrong detail identities and disabled sources. Thirty healthy works prove
the 24-item cap, four-request concurrency, overlapping-call coalescing, subsequent
advancement, no repeated probes and no detail calls. Seventeen lifecycle integration
cases and four dimension/deadline tests pass. Build and native observations are
recorded in the implementation plan.

The image check is a bounded dimension-header probe, not a full pixel decoder.
Upstream catalogs that keep returning missing artwork remain unresolved; this
change does not invent URLs or replace a source's metadata with another title.

A follow-up regression catches mixed records: one expired cover alongside missing
history/progress covers. Reusing that URL for the missing rows now queues its
singleton check in the same repair pass, so a cooldown/page re-entry is not needed
to discover the replacement. Disabled sources retain their existing no-detail
behavior, and the conditional update still preserves newer concurrent metadata.
