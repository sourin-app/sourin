# Agent Note: Global proxy feedback belongs to the current configuration intent

Status: implemented

Applies on 2026-11-11 to ProxyPanel at baseline cb613bf. The
[global routing decision](../architecture/2026-11-09-csp-global-routing-retains-engine-recipes.md)
owns transport policy; this change owns visible configuration and diagnostics.
The earlier [danmaku probe invalidation](2026-10-23-danmaku-proxy-probe-invalidation.md)
uses a separate settings owner and remains in force.

## Problem

A connection test saves its draft before starting the native probe. Changing
mode or URL during either await lets the old completion publish a result for
the wrong view; a late save can also reset the new mode. Clearing the proxy has
the same stale-success/error problem. Comparing only mode values cannot detect
switching away and back, or a newer explicit save with unchanged field text.

## Decision

ProxyPanel tracks configuration-write and probe generations independently.
Real field edits and mode/scope changes retire the probe, remove its feedback
and end obsolete progress while controls remain usable. Clear intent does the
same. Every save claims a new configuration generation before its first await,
including the prerequisite save for an explicit connection test.

A save or clear completion updates local fields/errors only if it still owns
the current configuration. Every successful persisted operation still notifies
a mounted host through onSaved. Delayed replies therefore cannot reset newer
fields or remove a newer test's progress; successful backend writes are not
misrepresented as cancelled.

The probe checks ownership after the prerequisite save, before dispatch and
on success/error. A stale save cannot start a probe for the new view. A stale
probe cannot publish feedback or complete a newer probe's progress. URL typing
remains a draft edit and does not save automatically. The prior policy for an
already-visible save error is unchanged: editing alone does not erase it;
current successful saves and explicit tests clear it through existing paths.

These are local ownership guards. They do not abort native in-flight requests,
serialize backend writes, change routing or add unsolicited replacement probes.

## Alternatives considered

Disabling mode/address controls during tests avoids the schedule by degrading
interaction. Comparing only field/mode values fails switch-away-and-back and
explicit-save cases. Incrementing only the probe generation leaves old clear
responses able to overwrite a new explicit save. Ignoring onSaved for an old
successful write would change the host notification contract despite a real
successful operation.

## Verification

The isolated clean cb613bf baseline receives only the independent new test file.
Its final nineteen cases produce sixteen behavioral failures and three positive
controls. The first seventeen-case production fix passes all seventeen; two
additional held-clear/new-save schedules then fail that first fix. Incrementing
the configuration generation at every save addresses this independently
observed remaining boundary. Final related and analysis results are recorded
before commit.

The fixtures mount the real global settings page/ProxyPanel and real API JSON
parser. Two callback cases mount that same global panel directly to inspect its
public onSaved contract. Synthetic native responses are delayed with Completers;
fixture persistence commits before delaying replies, so the test does not invent
backend write reordering. Current success/failure controls visibly render real
parsed results. The original seventeen cases are byte-preserved when the two
extra cases are added. No skip, real endpoint, account or keyring action is used.

## Consequences

Diagnostics now describe the draft that owns them; users can edit, change mode,
clear and explicitly retest without stale UI completion taking over. Password
storage, backend operation ordering and native network cancellation remain
separate contracts. Widget results do not establish real proxy reachability.

The note audit searches proposed, implemented and rejected notes. Global routing
and the earlier settings probe contract partially overlap and are linked in both
directions. Per-source proxy forwarding and persistent summary notes retain
their separate routing/navigation decisions; hijack diagnostics and source
request support are unrelated to this local completion policy. No prior Decision
is reversed or absorbed.
