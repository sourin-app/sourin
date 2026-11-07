# Agent Note: Baidu first rejected list entry typed observation

Status: implemented

Relations: [Selected Baidu episodes](../bug-fix/2026-11-05-baidu-selected-episodes.md) retains actual traversal, file identity and playback requirements. This observation does not change or establish any of those live results.

## Problem

The actual production initial-list caller returned fileEntryRejected after JSON
parsing, errno0 and a nonempty list. Its fixed public error does not identify
which entry predicate rejected the response. The existing report retained no
entry values, so the failure cannot be attributed to a specific field or login.

## Decision

Keep the exact valid_file_entry predicate and error. Replace all(valid) with
the equivalent first find(!valid), preserving short-circuit order. An optional
task-local Cell stores only the first rejected entry's fixed JSON type enums
and exact predicate rejection booleans. The caller gets the original result
and this projection after its single scoped operation.

With no scoped observer, no projection is constructed or retained. Non-object
entries have notApplicable field types and no inferred field predicate result.
An absent isdir remains accepted. The projection includes no response values,
discovered keys, filenames, identifiers, paths, URLs, credential data or hashes
of response content. No endpoint, request, traversal bound or cookie changes.

## Alternatives considered

Relaxing the validator, skipping entries or guessing a string-valued isdir
would change behavior without actual field evidence. A separate HTTP caller
would duplicate production protocol and require another request. Raw response
capture would unnecessarily retain access-bearing or user data.

## Verification

Five Rust tests cover predicate equivalence, nine field kinds, unarmed and
valid scope behavior, first-only task-local isolation and fixed-schema JSON.
Root's offline locked release run terminated successfully: five passed,
zero failed, 2259 filtered out. Proxy variables were cleared and the build
used BelowNormal priority with two Cargo jobs. The existing frozen test
executable under the separate probe target was not overwritten.

Root then ran the entire pan_baidu_play test module using that same compiled
test executable: 43 passed, zero failed. This adds module regression coverage,
not a newly built DLL or live initial-list observation.

The separate offline model deliberately selects the last invalid entry first:
1681 ordered pairs reject that mutation. Restored first-invalid selection
matches the original guard on 50 fixtures and 2500 ordered pairs. This model
is preparation evidence, not compiled production or live protocol acceptance.

## Consequences

Actual first-invalid-entry types still require one production scoped list
call on a newly bound core. The earlier accepted viewer check does not prove
file listing, and this list failure does not prove expired credentials.
No live list, selected file or media decode is established by these changes.
Owner process, package, profile, sources, accounts and history are untouched.
