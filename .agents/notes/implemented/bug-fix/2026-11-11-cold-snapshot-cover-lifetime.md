# Agent Note: Native durable/display projection for cold snapshot covers

Status: implemented

Applies from 2026-11-11 to the native snapshot-cover batch contract.

The note audit found existing owners for [library cover lifetime](2026-11-08-library-cover-lifecycle.md),
[global cover proxy routing](2026-11-10-cover-global-proxy-routing.md),
[inline image request metadata](2026-11-10-inline-cover-request-headers.md),
and [homepage snapshot/failure behavior](2026-11-09-home-cache-and-section-failure-feedback.md).
Those decisions remain applicable. This decision adds the native projection
boundary without a second image cache or a change to source availability.

The parallel [Dart snapshot regression decision](2026-11-11-cold-snapshot-cover-regressions.md)
owns frontend disk projection, startup order and read/write race evidence.
This note owns the native wire contract and Runtime A/B evidence; neither
replaces the other. Its implemented status does not claim completed native
client acceptance of the entire cold-snapshot flow.

## Problem

Frontend snapshots serialize media models after their covers have been wrapped
by the running core. After that process exits, the stored loopback port/token
belongs to a dead in-memory table. A cold homepage can preserve every card
while its posters fail, especially when source refresh times out. A loaded
widget flag is not proof that its image decoded.

The frontend needs to retain original cover metadata before persistence and
register that metadata under the next core's display policy. Reimplementing
unwrapping or source-header resolution in Dart would create a second policy.

## Decision

Public FFI commands `covers_to_durable` and `covers_to_display` accept
`args.items` with `{provider,id,cover}` and return `{items}`. They preserve array
length, order, provider and native id; only cover changes. Aggregate native ids
retain their complete `child-provider::native-id` identity.

A typed `CoverBatch` validates the entire packet before conversion. An items
array accepts at most 4096 rows, string provider/id fields and string/null cover
values. Missing cover is null for old snapshots; empty provider/id strings stay
unchanged. Errors identify fields without echoing cover metadata.

The batch directly calls existing `library_covers::durable` or `for_display`.
Durable conversion retains the complete original URL, including recognized
inline Referer/User-Agent metadata. Display conversion registers that metadata
using the new state's current origin-provider manifest, case-insensitive inline
overrides and the existing global API route. Unknown retired internal wrappers
become null. Non-HTTP(S) values retain existing handling, and loopback startup
failure never returns a raw direct fallback.

Conversion performs no source, detail or image request and does not read/write
library rows. Original URLs and inline metadata remain private local metadata.
The durable command uses synchronous state access; display registration uses
the existing asynchronous state boundary. The frontend owns applying this
contract to both Home representations and all personal-shelf snapshot lists.

## Alternatives considered

- Replacing only the old wrapper's port is small, but its token has no entry in
  the new core and does not identify the original URL or required headers.
- Refetching every detail before displaying cached cards could recover metadata,
  but delays rendering and repeats the source request that may already fail.
- A persistent blob/image cache could retain bytes, but adds a separate storage
  and eviction system outside this metadata-lifetime correction.
- Calling FFI before core startup preserves the old preload position, but cannot
  register a current display URL; the frontend restore boundary follows startup.

## Verification

The clean `cfe8aea` baseline compiled the integration target. Its first run
failed all four cases: three FFI cases reached the actual unsupported branch,
while the independent-runtime control received 502. That control failure was
investigated rather than counted as product RED.

The fixture used a nonblocking listener without explicitly switching accepted
streams to blocking mode before synchronous reads. An early read error was
discarded and its connection closed. Explicit blocking mode fixed the control.
No PNG, route, header, retired-listener, detail-count or database assertion was
removed. Extra diagnostics run only after an already-failed real request and
cannot turn it into a pass. The complete qualified rerun produced three
unsupported-command failures and one passing lifecycle control, with unchanged
production snapshots. The first 502 was an instrument defect, not a product
cross-runtime failure.

The same frozen integration file passes 4/4 on the implementation. Three public
FFI cases cover actual dispatch, batch shape, identity/order/null handling,
validation, bounds, full raw roundtrip and real API-proxy PNG bytes. The separate
owning-path case destroys Runtime A, proves its listener closed, binds a rejecting
trap at that port and creates independent Runtime B against the same isolated
profile. B uses a newly registered child manifest, retains inline overrides,
fetches the PNG through the API-only proxy, and preserves complete favorite,
progress and history rows with zero detail/direct/retired-listener requests.
Existing `library_covers::tests` also pass 4/4. Before/after source snapshots are
unchanged for both GREEN runs.

Evidence under `.probe/parallel-astra-1108/native-verify-v57/`:
`v57-cover-red.log`, `v57-cover-diagnostic.log`, `v57-cover-qualified-red.log`,
`v57-cover-green.log` and `v57-library-covers-related.log`, with corresponding
receipts. Frozen integration SHA256:
`3b5fa0b385a6790a9c8625d147244e3dd0e6d920ec4eccbf1636636d029078f4`.

## Consequences

Old snapshots containing only unknown retired wrappers cannot recover their
original URL. Their callers preserve cards with null covers until ordinary
refresh supplies metadata. Conversion does not fix source/API outages or the
separate origin-root empty-HTML response.

FFI globals use OnceLock and are not claimed to restart inside one process.
Runtime A/B validates native ownership and server lifetime; durable values cross
the runtime boundary in test memory. It is not an OS process restart, frontend
DiskCache load, Flutter image decode or final native-pixel observation. Those
gates require the separate Dart tests and a fresh ordinary client using the same
isolated profile after normal prior-client exit. No such native-client completion
is claimed by the Rust GREEN result.
