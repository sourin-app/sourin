# Agent Note: Source-switch search accepts only the latest request

Status: implemented

Applies from 2026-11-10 to SourceSwitchDialog keyword resubmission.

Related: [excluding the current provider](../feature/2026-10-27-source-switch-excludes-current-provider.md)
owns candidate filtering, matching and the existing transport fixture seam.
[Discovery request ordering](2026-11-09-source-discovery-request-order-and-page-lifecycle.md)
owns a different page's shared snapshot and persisted mutations. The note audit
found no existing owner for source-switch query generations. Those decisions
remain active; no note is superseded.

## Problem

The keyword editor can submit another search while the original request remains
pending. Both callbacks checked only whether the dialog was mounted, so a late
hit or miss from the old keyword entered the new candidate list. The old
request's success or error completion also cleared the new request's searching
state and enabled the retry button before the new search finished.

## Decision

Give each nonempty submitted request a revision. The injected runner and normal
search transport share one event callback, which accepts events only while that
revision is current and the dialog remains mounted. Returning false rejects and
cancels the obsolete stream through the existing callStream contract when the
next business event reaches that callback. This is not an immediate network
abort at resubmission; no native cancellation token is exposed by this API.

After awaiting the provider list, recheck ownership before setting its count or
starting the stream. Only the active request reports its error and clears the
searching state. Disposal invalidates all pending reads, event callbacks and
completion handlers; the scheduled initial search checks mounted before reading
the text controller.

Keep the actual keyword submission, current-provider exclusion, similarity
ordering, selected media identity and original episode/position handoff. No
resolver, player, transport API or user preference changes are required.

## Alternatives considered

Disabling the visible retry button alone leaves the editor's search action able
to submit. Checking mounted alone cannot distinguish two requests in the same
dialog. Clearing candidates at the start cannot prevent an earlier stream from
appending later. A second fixture-specific event handler would fail to guard the
production path; both branches therefore share the same callback.

## Consequences

The behavior test opens the real dialog, edits its rendered text field and sends
the search input action while the first request is held. It checks real candidate
text, stale callback rejection, visible progress and the retry button after late
hits, misses, success and error completion. The positive control selects a
current result and retains its provider/native identity, title, episode index,
position and eventual dialog removal.

Root's qualified RED records three failures and one passing positive control.
The initial positive failed only because its fixed wait ended before route exit;
it now waits for the actual settled dialog after its sole runner completes,
retaining all selection and removal assertions. Test bytes remain fixed across
the qualified RED and the four-case GREEN. These four dynamic cases cover UI
query ownership through the existing runner seam; the normal provider-list
await boundary and disposal ordering are currently covered by source review,
not dedicated delayed-transport behavior cases. Related regressions, analysis
and native interaction acceptance remain separate root-owned checks.
