# Agent Note: Directory IDs belong in the category request

Status: implemented

Applies to the App99 encrypted protocol adapter from 2026-11-10.

Related: [guest and detail contracts](2026-11-05-app99-dex-guest-detail-and-private-errors.md)
owns authentication, detail fields and private errors. The note audit found no
existing decision owning the category/search business-payload distinction;
those earlier decisions remain in force.

## Problem

The directory flow passed the selected category ID through the app API and
FFI correctly, but the adapter sent that ID as `kw` with the search ranking.
Selecting category `2` therefore requested titles matching the keyword `2`.
The shared `/vod/search` endpoint had hidden two different request contracts.

## Decision

Category requests send empty `kw`, string `pid` containing the selected ID,
string `page`, integer `limit=21`, `orderBy="time"` and integer `isCategory=1`.
Page zero retains the existing normalization to page one. The signed transport
continues adding the captured session token, timestamp and nonce.

Keyword search retains the trimmed user input, numeric page, monthly-hit
ranking and descending sort. A numeric user keyword remains a search. The
reference category method reads four extension-filter values but discards
them before constructing its JSON; no speculative empty filter keys are added.

The expected contract comes from the existing reference DEX with SHA256
`EC947FD1D5404A27EB5BE2029587AE335F3AF84CCACCD218A0454FCB0E100407`.
Its category method takes string ID/page arguments. At instruction 90,
`JSONObject.put(String,Object)` receives the page argument; instruction 102
receives the ID argument. Instructions 97 and 115 use the integer overload for
the limit and category flag. The search method instead uses its user keyword
and a numeric page. This establishes field types independently of the Rust
implementation.

## Verification

The dedicated tests reuse the existing loopback HTTP server and AES fixture.
They perform the production handshake and list/search calls, decrypt the
actual HTTP request bodies, verify their signature and session metadata, then
compare business fields with independent literal expectations. They cover
category `2` on page three, category switching, page-zero normalization and a
numeric keyword search control. The fixture returns distinct directory and
keyword cards.

Root's compiled baseline run selected `csp::app99::category_tests` and produced
two failures and one passing search control, with no ignored tests. The first
failure observed `kw="2"`, numeric `page=3`, monthly-hit ranking and search
sort instead of the directory fields. Evidence:
`.probe/parallel-astra-1108/native-verify-v51/app99-category-red.log` and its
matching source receipt. The coordinating agent then ran the complete adapter
test filter: 34 passed, zero failed and three pre-existing ignored cases. All
three new category/search regressions passed, and source hashes remained
unchanged throughout Cargo execution. The ignored cases were not counted as
validation.

## Alternatives considered

A shared directory/search body builder would reduce the repeated page and
limit fields, but would need separate branches for keyword/category identity,
page type and ranking. Keeping the two small payloads explicit makes their
independently observed contracts visible at each call site.

Retaining a numeric directory page would make the diff slightly smaller. The
reference method signature and argument registers establish a string page,
so only the category request follows that type; keyword search keeps its
existing numeric page.

## Consequences

The change is limited to category request construction. Loopback request and
response observations establish protocol mapping; external catalog availability,
native UI behavior and real source playback require their own acceptance.
