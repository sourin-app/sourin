# Agent Note: Load the selected homepage catalog without aggregate fan-out

Status: implemented

Applies from 2026-11-09 to homepage metadata, provider selection and Rust registry dispatch.

The note search across proposed, implemented and rejected notes found the related
[home cache and failure feedback](2026-11-09-home-cache-and-section-failure-feedback.md)
decision. Its cache-first rendering and visible failure contract remain intact.
This extends that note's 30-second metadata reuse from one aggregate timestamp to
per-provider freshness. [Home card and motion boundaries](2026-11-08-home-card-and-motion-boundaries.md)
owns visual layout; this decision does not change the Miuix materials or animation.

## Problem

The homepage renders one selected provider, but previously waited for the catalog
of every enabled provider before filling that provider's sections. A slow unrelated
provider therefore added its entire timeout to otherwise fast navigation/startup.
The flat source bar already obtains its full local list independently.

## Decision

Connect a selected-provider API from HomePage through the async FFI command to the
registry. Keep the original aggregate API and its error isolation for explicit
aggregate callers. The selected API calls one enabled, working provider with an
8-second bound; a failure stays a failure. Check that the same provider instance
is still enabled after the await, so a disabled/replaced implementation cannot
publish an obsolete result. Do not hold the registry lock across network work.

Keep metadata only for visited providers, with independent completed-response
freshness. Cache hits never extend metadata freshness. Both a tab return and a
source switch may reuse it for 30 seconds; explicit refresh/configuration changes
bypass it. The selected source snapshot still appears in the first frame while
its metadata refresh runs. A cold source selection requests its own metadata and
sections. Use that source's structure fingerprint, not another source's fingerprint,
when checking and writing its snapshot.

Invalidate the previous UI load immediately on selection and reject late metadata,
content, errors and final cache writes after a newer load or configuration change.
Keep the existing local source order, labels, global proxy routing, source enablement
and library refresh behavior; source selection does not need to reload the library.

## Alternatives considered

Increasing aggregate concurrency still waits for unrelated timeouts and adds load.
Deleting the aggregate API would change other callers. Sharing one timestamp makes
freshness of one source hide stale metadata in another. Loading only the initial
source without adapting cold switching makes other source choices appear empty.
Changing shader or glass styling would not address this network dependency.

## Consequences

Behavior tests exercise the actual API transport command from HomePage, cold source
switches, rapid A/B/A metadata and content races, independent TTL and disabled-source
invalidation. All five final behavior checks fail on the previous working implementation and
pass with the selected-provider path, including late content replacing current cards. Registry tests measure that unselected providers are never called, selected
results arrive while another provider is pending, configuration changes invalidate
inflight results, and errors/timeouts remain distinguishable from empty success.

Native verification must bind the rebuilt DLL and inspect actual selected catalog
latency and populated cards. This cannot promise faster responses from the selected
upstream, eliminate Windows presentation stalls, or prove account-required playback.

The broader registry suite exposed two obsolete tests that expected TVBox children
to stay behind the aggregate entry. Their replacement checks the user-requested
flat policy: each enabled child participates once, the aggregate entry is not
called, ordinary hidden providers remain excluded, and disabling a child stops
its calls. The legacy hidden-only fallback fixture now uses a non-TVBox kind so
it still tests fallback rather than ordinary first-level TVBox inclusion.
