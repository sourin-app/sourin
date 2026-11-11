# Agent Note: Completed HTML cover recovery and check publication

Status: implemented

This extends [library cover recovery](2026-11-08-library-cover-lifecycle.md)
and [expired singleton refresh](2026-11-10-expired-library-cover-refresh.md).
[Global routing](2026-11-10-cover-global-proxy-routing.md) and
[inline image headers](2026-11-10-inline-cover-request-headers.md) retain
transport ownership. No prior decision is superseded or archived.

## Problem

A stored cover can return HTTP 200 with HTML. Treating that complete body as an
unknown image prevents recovery from a valid older cover with the exact same
provider/native identity, and prevents an enabled singleton's detail refresh.
Root URLs and HTML MIME values alone are insufficient: both can serve images.

The singleton repair also publishes its completed-check entry before saving
the replacement. A real SQLite failure rolls back the rows but leaves a
ten-minute check entry that prevents an immediate retry.

## Decision

Image dimensions still take precedence. A bounded body beginning with an HTML
or HTML-doctype tag, after optional UTF8 BOM and ASCII whitespace, becomes
definite non-image evidence only after EOF. Tag matching ignores case and
requires a whitespace or closing-angle boundary. The body must be smaller than
64 KiB; reaching the limit, truncation, response errors and unknown formats
remain uncertain. URL shape and MIME do not decide invalidity.

Use the existing exact-identity donor/detail recovery, current proxy and
headers, conditional cover-only transaction and bounded work. Remember a
singleton check only after its proposed replacement transaction succeeds.
A save error leaves the old key due for retry. No additional writer, queue,
timer or transport is introduced.

A successful conditional transaction can change zero rows if another writer
already replaced the captured values. Its checked key still describes the old
provider/native ID/URL and does not affect a new URL or claim a saved change.
Reintroducing that same old URL during the existing TTL remains a bounded
staleness case, as before this publication-order change.

## Alternatives considered

Rejecting root paths or HTML MIME would discard valid images. Classifying every
unknown body as invalid would mistake incomplete or unsupported image formats
for evidence to replace a stored cover. Publishing before saving suppresses
retries of writes that never succeeded; the existing repair mutex already
serializes overlapping passes.

## Verification

The clean dc5d1da baseline compiles thirteen frozen loopback/real-SQLite cases:
seven intended failures and six controls. Adding only HTML classification
passes twelve and leaves the independent save/cache failure. The complete
production implementation passes all seventeen library_covers cases, including
the four prior dimension/deadline controls, with no ignored cases and unchanged
source snapshots.

The save test installs a real SQLite trigger that aborts the third cover-table
update. It compares full favorites/progress/history records after rollback,
checks that the old key was not remembered, removes the trigger and immediately
repairs all three cover fields. Other controls preserve foreign identities,
wrong-detail identity rejection, non-cover metadata, old history donors outside
the preview, misleading MIME, opaque/prefix-lookalike/truncated/over-limit bodies
and singleton cooldown. Related integration passes all 21 library-cover and
four cross-process cover-cache cases, without ignored tests. Its first run had
two expected-contract failures because the old unknown-format response was
complete HTML. Replacing only that response with opaque unknown bytes keeps
all zero-write, full-metadata, call-count and cooldown assertions unchanged;
the thirteen frozen HTML cases retain independent positive coverage. The owning
non-test Cargo library check passes with the ten existing warnings.

## Consequences

Definite HTML errors can use existing recovery without changing source
ownership, progress or ordering. Save failure no longer delays retry behind a
success check. Bodies with leading comments, XML declarations, fragments or
exactly 64 KiB remain unknown. A recognized error still needs a valid donor or
matching enabled-source detail; this does not invent artwork or bypass routing.

The checks use isolated data and strict loopback fixtures. They do not establish
current upstream availability, native decoded pixels, an installed package or
desktop acceptance. No visible client, loaded DLL or real user data is changed.
