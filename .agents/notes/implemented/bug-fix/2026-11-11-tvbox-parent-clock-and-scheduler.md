# Agent Note: TVBox parent clocks govern scheduled refresh ownership

Status: implemented

Applies on 2026-11-11 to source catalog version 1 and actual TVBox import,
check/update, bootstrap scheduling and the selected parent summary. Extends
[exact parent refresh](2026-11-11-tvbox-origin-refresh-identity.md),
[durable live refresh](2026-11-11-tvbox-live-actual-refresh.md), and the
[subscription clock](../feature/2026-10-31-tvbox-source-update-time.md).
[Parent provenance](2026-11-11-tvbox-live-parent-provenance.md) retains independent
playlist address/cache ownership. [Update visibility](2026-10-31-source-update-time-e2e.md) and
[Miuix source management](../feature/2026-11-08-miuix-source-discovery-and-search-controls.md)
retain their separate owners. The keyword audit finds six partial overlaps and
fifty-five unrelated decisions. No existing decision is archived.

## Problem

The scheduler samples VOD sidecar links, so a zero-VOD parent is never selected
and distinct same-primary parents collapse. Its due list can also outlive a
manual update or disabled schedule while another request holds the shared lock.
Pure-live parents have no update result time. Endpoint success only says a
configuration was fetched, and checking cannot masquerade as applying it.

A structured successful return can contain failed probes in failed[] or in a
retained configuration row's probeFailed. A final metadata save can fail after
real stable-ID source changes are already applied. Treating either case as a
simple success/error boolean loses actual outcome or reports misleading status.

## Decision

SourceOrigin has additive lastUpdateAt/lastUpdateOk/lastUpdateError fields. Rust
keeps the time optional so missing old metadata can migrate once, while an
explicit zero remains never-updated/due. URL-backed TVBox parents migrate only
their own registered VOD sidecar timestamps through the existing maximum-time,
all-stamped-failure policy. Endpoint success and unrelated playlists are never
clock donors. A parent with no stamps migrates to zero; migration is persisted.

Successful URL configuration registration initializes the parent clock. This
describes accepted configuration installation, not native playback or all-source
compatibility. Real update attempts, including unchanged content and failures,
stamp the exact resolved parent under the existing update lock. Invalid targets
do not make an update result stamp. Checking retains the prior update result.
Both failed[] and nonempty added/changed[].probeFailed mark the overall attempt
failed while preserving accepted rows. Existing plus successfully added VOD
sidecars carry that failure as well.

The real bootstrap scheduler selects URL-backed TVBox parent IDs, including
zero-VOD parents, independently of shared URLs. All owned VOD IDs are excluded
from the legacy pool even when their parent is current. Uncovered and URL-less
local-owner sidecars retain their old selection path. The scheduled branch
obtains the same update lock, reloads schedule and resolved ownership, and
rechecks the real clock before requesting. A completed manual update or disabled
schedule retires a waiting target; an already-started request may finish. Initial
60-second delay, Delay missed-tick policy and conservative deletion remain.

If the final clock save fails after content application, the successful result
retains its actual updated/changed data and gets a fixed safe updateClockWarning.
An unchanged result gets the corresponding checked-content warning. The old
clock stays on disk. Original persistence errors remain diagnostic logs; they
are not copied into the safe warning. This does not create a transaction spanning
the existing provider, sidecar, registry and catalog boundaries.

The selected TVBox parent summary formats its own clock through the existing
date/status formatter. Raw stored error values are used only to detect whether
a reason exists; visible failure hints and both warning result branches use safe
fixed text. Raw errors are not passed into userErrorText/debugPrint or Tooltips.
The manager reloads after dialog closure because unchanged and failed attempts
also change the clock. Source-change notification still requires actual changed
content. Existing address, deletion, provenance and source-count controls remain.

## Alternatives considered

- Use lastSuccessAt as freshness: checking could postpone a needed application.
- Reconstruct every zero clock from VOD: explicitly never-updated parents would
  incorrectly become current.
- Deduplicate all parents by URL: distinct backups and descendants lose owners.
- Trust a due snapshot after locking: a queued manual update or changed schedule
  can make it obsolete before any request.
- Replace applied results with a clock-save error: the UI would lose source
  notification despite real persistent content changes.
- Classify only Result::is_ok or failed[]: configuration retention reports real
  failure through probeFailed and cannot become successful status.
- Display raw stored errors: URLs, headers and values can carry private data;
  the parent summary needs actionable status rather than raw transport payloads.

## Consequences

The independent current-product core baseline compiles seventeen cases and has
thirteen intended behavior/persistence/queue failures plus four controls. It
uses actual bootstrap scheduling and real loopback requests, with only a
dev-dependency Tokio clock feature. A ready task prevents automatic virtual-time
jumps while network I/O is pending. Paused time does not substitute an update
implementation. Exact raw-file, registry, sidecar and request observations prove
the boundaries; the trailing scheduler request proves continuation past a
retired target.

Ten independent raw-JSON/default-API/actual-widget cases compile on the older
product and fail the missing UI contract; five existing provider/origin controls
pass. A rendered candidate retaining the original changed-only reload policy
independently fails two actual closure/read-count cases. Original frozen core
and UI assertions are retained. A constructor receives only new-field defaults;
two old close controls now explicitly expect a read while retaining no-write and
no-notification assertions.

The privacy case restores its temporary debugPrint capture in finally before
Flutter verifies foundation invariants. Its rendering/privacy assertions remain
unchanged; the corrected instrument still fails on the original product. The
first candidate UI run's foundation-variable cleanup failure is not a product
regression or a passing run.

Final related results, paired diagnostics and immutable source receipts are
recorded in the implementation plan: sixty-nine catalog cases, eighty-five TVBox
passes with eight existing ignored network diagnostics, and ninety related UI
cases. Production-only Cargo check passes with ten inherited warnings. Paired
eight-file analysis retains the same ninety-two warnings and seven infos with
zero errors and no normalized additions; it is not clean analysis.
Interrupted dependency compilation and a
misstarted old-source run are excluded from behavior evidence. Tests use isolated
synthetic data, low priority, two CPUs and one build worker. Native decoder/audio,
real public-service selected playback, current desktop rendering/performance,
artwork and the full eighteen-item acceptance remain separate open requirements.
