# Agent Note: Library cover lifecycle and background recovery

Status: implemented

Applies from 2026-11-08.

Independent: the audit of proposed, implemented and
rejected cover notes found no decision owning persistence and display URL
lifetime. Existing title backfill and image decode sizing remain separate.

## Problem

Session proxy URLs in followed items become unusable after restart. History and
continue-watching lists omit required cover headers. URL-only proxy deduplication
mixes headers from different providers. Poster errors remain latched indefinitely.
Registering many posters also evicts active HLS segment headers.

## Decision

Database writes store original cover URLs. All library display commands, homepage
items and details share proxy registration, using child headers for aggregate
items. Only the internal loopback token route is considered ephemeral; ordinary
local image servers remain supported. Proxy deduplication includes required
headers, and cover entries own their headers independently from video streams.

Library views render existing records before starting shared background recovery.
Recovery reuses valid metadata across library tables or requests enabled source
details. Work is serialized, limited to 24 items with concurrency four and a
four-second detail timeout. A rotating cursor prevents permanently unavailable
items from starving later records. The frontend coalesces requests and applies
a one-minute cooldown. Compare-and-update changes cover fields only, preserving
ordering, progress, follow state and concurrently replaced covers.

Poster cards retry a failed URL twice, after two and four seconds. A URL change
resets the budget, and disposal cancels the pending retry.

The shared native Flutter cover loader bounds connection acquisition and response
headers to twenty seconds each, and cancels an image body after twenty seconds
without bytes. Actual data resets the body deadline, preserving slow progressing
posters. Non-200 responses cancel their body immediately and retain the received
status. Cancellation completes before closing progress events; late completions
are handled and failed cache entries are evicted so existing card retries work.
Gzip decoding, byte progress, CDN headers, sentinel rejection and decode dimensions
are retained. These limits apply only to covers, not video-body transport or the
web image implementation.

## Alternatives considered

Clearing stale covers alone leaves permanent placeholders. Refetching all details
before displaying the library delays navigation and repeatedly contacts sources.
Rewriting complete favorite or progress records can overwrite concurrent changes.
Sharing the video header cache with posters makes browsing affect active playback.

## Consequences

Integration tests read real database rows and local HTTP responses: origin
persistence, restart display for four library views, source-specific headers,
aggregate child headers, metadata-preserving recovery, disabled-source exclusion,
fair progress and active video segment access after 4096 cover registrations.
Widget tests observe a decoded image after a real HTTP 503 and retry; another
local HTTP case stalls headers/body, checks timeout and late-response cancellation,
then decodes the same recovered URL with gzip. A progressing image crosses the
original wait interval without timing out. The history page's decode-size check
uses its actual Image and layout at two widths; hardcoding its card width causes
the check to fail. Coordinator
tests cover concurrent callers, cooldown and synchronous failure recovery.

Bounded validation and replacement of existing stale URLs is governed by
[expired-cover refresh](2026-11-10-expired-library-cover-refresh.md); it extends
the missing-metadata recovery here without a full network scan. Recovery reads
the first 100 history/progress entries and all favorites/follows. Revisit these
bounds if the UI adds deeper history paging. These tests do not establish live
source availability or final native UI acceptance.
