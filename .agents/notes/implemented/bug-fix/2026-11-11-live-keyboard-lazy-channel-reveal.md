# Agent Note: Keyboard channel selection reaches the lazy target row

Status: implemented

Applies to LivePage directional channel selection and LiveChannelList rendering.
The coordinating task qualified two unmounted-wrap behavior failures and four
passing controls before authorizing the single-file implementation. The unchanged
six cases now pass6/6, and root's combined live/motion run passes16/16. Related
suites, analysis and native acceptance remain separate pending checks.

The note audit found [live channel groups and cold start](../feature/2026-10-18-live-channel-groups-and-cold-start.md),
[live playback handoff](2026-10-23-live-shell-playback-handoff.md),
[source-rail selection reveal](2026-11-10-source-selection-reveal.md)
and [Miuix navigation](../feature/2026-11-08-miuix-navigation-and-settings.md).
The existing source-rail geometry approach is relevant, but owns a horizontal
source rail rather than the vertical live channel list. No note owns this lazy
channel target boundary. Those decisions remain; none is superseded.

## Problem

LivePage's normal early-key path calls cycleChannel and selects the next native
provider/channel identity. The list receives that selectedRow, but its only
reveal/focus action lives in an already mounted _ChannelTile.didUpdateWidget.
If the selected target is outside the lazy mounted window, it has no State to
run that callback. First-to-last and last-to-first wraps can therefore change
the channel while leaving its row out of view and focus on another control.
The baseline source comment explicitly records this unclosed boundary. Rapid
continuous downward movement passed the qualified baseline and is retained as
a control, not claimed as a newly reproduced defect.

The existing three-channel keyboard tests cover nearby selected rows. They
cannot prove that an initially unmounted target becomes visible or receives
focus. Reading selectedRow alone is insufficient user-visible evidence.

## Decision

The six real-widget cases in live_channel_keyboard_reveal_test.dart
mount the complete LivePage, use ordinary WidgetTester keyboard delivery and
let the real early handler, neighbor query, selection, model deserialization,
list build and Miuix tile focus run. No test directly assigns selection state or
calls a future reveal API.

The long fixture has80 primary-provider channels plus one final channel from a
second provider whose native ID equals the first channel's ID. The fixture
requires the last row initially unmounted and fewer than30 mounted channel
pressables. Up from the first must wrap to the correct final provider identity,
mount it, reveal its whole hit rectangle, give it focus and paint exactly one
selected Miuix card. The inverse case manually scrolls/clicks the final row only
as a precondition, proves the first row is then unmounted, and requires Down to
reveal/focus the first row itself. No tester scroll/ensureVisible assists after
the key whose result is asserted.

A rapid55-key case crosses the lazy boundary and requires the final channel55
identity, viewport geometry and focus. Controls retain short-list movement and
both wrap directions, reverse a pending distant selection to a newer visible
first row, and dispose while distant reveal may be pending. The fixed frame
budget allows a bounded lazy approach followed by the existing reveal motion;
it does not alter production clocks or motion preferences.

The implementation changes only lib/ui/live_page.dart.
LiveChannelListState owns its list controller, displayed identity/index map and
cancelable reveal generation. The builder creates lazy rows with stable
provider/channel ValueKeys; findChildIndexCallback preserves row State through
reorder. Row init/dispose maintains a mounted-State registry without setState.
Render geometry excludes stale offscreen focus keepalive children by their
sliver parent data. Reindexing plain filtered data is separate from animation;
each reveal pass inspects only the mounted window, never every channel widget.

A mounted target supplies actual viewport start/end offsets. An already fully
visible choice stays still. An unmounted target is approached using actual
indexed row spacing (or measured extent with one row), then corrected from its
real bounds after layout; first/last approaches use current min/max extent.
The loop has a twelve-pass bound and stops on absent/invalid/no-progress
geometry. Correction uses Motion.medium (the existing180ms duration) and the
shared Motion.easeOut curve through MotionPrefs; system reduction uses a direct
jump. No hardcoded row height or per-frame page setState is used.

Only the current target's active mounted node may receive focus after an await.
New selection, displayed-sequence change, manual scroll and disposal invalidate
old work. A newer already-visible choice still stops an older driven scroll.
User drag/wheel notifications cancel the eventual focus handoff; unrelated
focus moves are preserved. Passive same-selection rebuilds do not repeatedly
pull a manually browsed list back to the selected row. Filters hide absent
targets without being cleared, and passive filter visibility changes do not
request focus. The old tile-owned unguarded delayed reveal is removed to avoid
competing scroll/focus owners; its real FocusNode remains row-owned.

Focus handoff captures the original node and its ancestor-node identities.
Normal lazy eviction may move focus to one of those ancestors, including a
traversal-group FocusNode that is not a FocusScopeNode. That fallback still
belongs to the pending selection. A newly focused unrelated control or new
popup scope is outside the captured chain and is not overridden. No debug-label
or runtime-type string classification determines ownership.

Each approach pass reacquires the controller's current ScrollPosition. After
awaiting an animation, the code first rechecks ownership/attachment, then
compares position identity; a replacement restarts from the next current pass.
No retired position is read or written after an await. A Scrollable dependency
change may replace its position while retaining its controller and widget State.
This lifecycle guard complements the separate motion-preference change without
claiming a new live-specific preference-switch reproduction.

Source/category/search filters, provider/native identity, playback ownership
and source settings remain. No eager Column, source mutation or second
player/API request is introduced merely to reveal a row.

## Alternatives considered

Calling ensureVisible only inside didUpdateWidget cannot reach an absent State.
Asserting a public selected value without actual geometry/focus would miss the
complaint. A three-row list never crosses the lazy boundary. Eager mounting all
rows trades correctness for startup/layout cost. Bare native IDs mix channels
from different providers. Changing source filters to expose a selected target
would modify the user's view rather than its scroll position.

## Risks

Focused offscreen rows can remain mounted with stale render geometry; only
currently laid-out sliver children supply estimates. An estimate remains an
approach, never proof that the target is visible, so actual target bounds are
checked after layout. A bounded no-progress exit leaves selection intact rather
than looping. Wheel/drag cancellation and unrelated focus moves must continue
to preserve deliberate manual browsing. Filter/source-data changes can remove
or reorder a pending identity and must invalidate the captured geometry.

## Verification

No Flutter, analyzer, native/VM, network, OS input, source configuration or Git
operation is run by this lane. Root's fresh76a1a5e run with unchanged source
snapshots produces two actual failures and four controls passing. The two
wraps fail because their selected targets remain genuinely unmounted; the
media-request provider/channel ledger already identifies the correct target.
Rapid55-key downward selection, short-list movement/wraps, rapid reversal and
disposal pass. The initial predicted3/3 split was incorrect and is not used as
the evidence. Qualified log:
.probe/parallel-astra-1108/native-verify-v59/v59-ui-red.log and its receipt.
The frozen six-case file remains SHA256
C749407A20299C9D93281805DFB33CF3C324EBABF6E659B6580A51239F7BAEA0.

The first implementation candidate passes3/6 live cases. Both formerly
unmounted wrap targets are then mounted and visible, but their actual row nodes
lack focus. The previously passing pending-reversal control also fails focus.
Those are candidate product failures, not fixture errors, and the original six
tests are not weakened. The initial handoff guard accepted only the original
node, null, or any FocusScopeNode; framework fallback to a captured ordinary
ancestor was incorrectly rejected. Capturing the full original focus chain
fixes that ownership decision while avoiding blanket acceptance of new scopes.
The failed candidate log remains v59-ui-green.log.

Root's final v59-ui-green-v2.log reports6/6 unchanged live cases and10/10 separate
motion cases,16/16 combined, with production/test source snapshots unchanged.
The six-case hash above is identical across qualified RED and both candidates.
Current live production SHA256 is
B7835FE6C50F99611E833A3D2A61759B84690CFCA66D47650937A89191B2A1AA.
The position-lifetime guard was added after local Flutter source review and a
separate motion fixture's real retired-position failure; the final live cases
remain fixed and do not directly toggle ScrollConfiguration/MediaQuery.

The ten related suites report120 passes, two pre-existing skips and six
failures. Root reruns the three failed suites on fresh76a1a5e and obtains
48 passes and the same six failures by name. Five concern older live-card/EPG
fixture targets and an obsolete empty-state description; the sixth is in the
separate danmaku bindings source-shape gate. The related combination is not
claimed green. Evidence is v59-ui-related.log and v59-related-baseline.log in
the same directory. This comparison excludes new failures from this delta but
does not itself modernize or validate the old failing assertions.

After the final16-case run, two async-context infos prompted a local explicit
mounted guard immediately before reading MotionPrefs from context. No ignore
directive or behavior assertion changed. The post-guard production SHA256 is
3A12E1678EAC7407E17855EC34B96437E59F00FB902F0A0F37A164549F0A10E5.
Root owns the pending post-guard rerun and baseline analysis comparison.

The existing async transport seam returns synthetic get_live_channels JSON and
empty get_live_stream results, recording each requested provider/channel. Other
commands are rejected and must remain absent. No source URL or media address is
provided. Existing debugSkipPlayerCreation skips only native Player construction;
the player widget/layout still mounts, and forced playback state is not used.
No native-media skip tag is added. DiskCache has no data directory; UI prefs and
the in-memory live-stream cache reset for each case. Repository test config
already redirects AppLog to the test temp log directory. No real profile,
account, source config, cloud or external request is used.

All installed seams are restored, widgets unmount and hit-test warnings remain
fatal. The test reads actual Miuix tile nodes, rendered selected semantics,
paint color and viewport bounds. The keyboard query and actual requested media
identity are separate preconditions, so an incorrect key handler cannot be
mistaken for a scroll-only failure. Only initial focus is explicitly placed on
the first existing tile; every later target focus belongs to production behavior.

Final root verification after explicit mounted/braces cleanup: the unchanged
combined sixteen cases pass again (`v59-ui-final`); targeted analysis of the four
production files and two new test files reports no issues
(`v59-ui-analyze-final`). Source snapshots remain unchanged during both runs.
This does not convert the separately recorded six baseline failures or two
existing skipped suites into passes.

## Consequences

The two qualified failures and final six-case GREEN establish the local
lazy-wrap correction. Filter/search/highlight and playback ownership
regressions, targeted analysis and review remain root-owned checks. Wheel/drag versus
pending reveal, data reorder/filtering and moving focus to another control have
source-order review at this checkpoint, not distinct new held-frame behavior
evidence. These tests do not establish live playback or desktop-window input.
Native scrolling, focus visuals and performance acceptance stay root-owned.
