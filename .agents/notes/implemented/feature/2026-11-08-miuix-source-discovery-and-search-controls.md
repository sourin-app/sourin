# Agent Note: Miuix controls for discovery, subscriptions and search

Status: implemented

Applies: 2026-11-11, flutter_miuix 1.3.0 and the Flutter product UI.

Extends [Miuix appearance](2026-11-08-miuix-appearance.md) to the discovery,
TVBox aggregate, subscription management and search controls. The keyword
audit classifies [proxy discovery](2026-11-08-proxy-github-source-discovery.md)
and [source scope](../bug-fix/2026-11-08-search-respects-source-scope.md) as
overlapping behavior contracts that remain in force. Aggregate editing and
subscription update-time notes remain applicable; no existing decision is
fully absorbed.

The selected TVBox parent summary opens the real subscription update dialog
using its exact origin ID, including zero-VOD parents. The parent address remains
read-only in that dialog; the existing address editor owns edits. All accepted
update exits notify/reload the mounted source manager once. This contract is
described in [exact parent refresh](../bug-fix/2026-11-11-tvbox-origin-refresh-identity.md).

## Problem

A Miuix palette and settings card do not change the widgets used inside source
discovery and search. Material input, action and source-selection widgets
continue to produce a different interaction and surface hierarchy.

## Decision

Discovery uses Miuix input and action controls through the application adapter,
a Miuix switch preference for daily discovery, and Miuix basic components for
persisted notices. SettingsBlock supplies the shared Miuix card. Proxy
configuration, scan, explicit candidate enable, GitHub provenance, reinstall
and marking notices read keep their service callbacks.

TVBox link forms, selection checkboxes, update actions and switches use the
same actual Miuix controls. Source rows and update results use Miuix cards.
The enabled-selection filter uses a Miuix window dropdown, including the
nullable all-states choice. Unsupported sources retain disabled controls and
their complete reason. The aggregate-only explanation describes the current
enabled/imported search scope without changing persisted provider preferences.

Search retains its controller, composition-aware change handler, submit
callback and pinned geometry. Its controls sit in a Miuix card. The source
rail remains a lazy list and uses Miuix basic components; narrow layouts use
the application Miuix choice control. A source click filters the current
results without issuing a new search.

Search matching continues to use source item titles for stable group and item
ranking. Source notes are display metadata: ordinary text remains a caption;
recognized episode/completion state appears in the existing cover badge. They
never become similarity inputs.

The dedicated source-order page always lists all managed sources, independent of
the manager's current type, status or text filter. Rows show origin and disabled
state. Miuix arrow buttons and drag handles edit the same local draft; first/last
arrows are disabled, and save-in-progress disables both interactions. Explicit
save persists the displayed ids and notifies the retained settings owner. Back
without saving discards the draft. A failed save keeps it editable for retry.
The former private order-dialog entry and its uncalled dialog are removed.

This separate global order page supersedes the filtered-card ordering paragraph
in [settings-owned home and filters](2026-11-04-settings-owned-html-home-library-and-source-filters.md).
Other filtering, homepage-template, hidden-provider and mutation contracts in
that decision remain applicable. Sorting keeps provider ids; display labels do
not become persistence identities.

Provider selection persists inside its Miuix dialog. Saving freezes the choices,
bulk actions and dismissal until the command completes. A failed command leaves
the same draft and displays the returned user message for retry; closing after a
failure discards only that draft. Successful persistence notifies the retained
settings owner before the refreshed catalog arrives. Empty selection remains an
explicit request to disable every provider in the group.

[CSP configuration identity](../bug-fix/2026-11-11-csp-provider-group-ext-identity.md)
keeps different ext recipes in separate provider groups. A choice applies only
to the matching configuration; existing provider-level disabled choices persist.

Origin address editing, JS installation and live import also notify inside their
successful persistence callbacks. A dialog's return value only controls a still
mounted manager refresh. Removing its route cannot suppress notification of a
completed write; the retained settings owner checks its own lifetime before
notifying its shell or loading data. Canceled and failed writes never notify,
and a successful mounted dialog notifies exactly once.

A selected TVBox subscription shows its name, child count and Miuix address
action in the filter area. Its address form remains reachable with zero child
providers or when filters hide every child; the child rows remain flat. The
summary and row editor share the same selected origin and persistence path.
[TVBox live parent provenance](../bug-fix/2026-11-11-tvbox-live-parent-provenance.md)
adds live descendants to that filter and count. Live rows and ordering describe
their parent names while the live row editor retains the playlist address owner.
Source read failures display their error and a guarded Miuix reload action.
Loading/error states do not claim an empty match; a successful empty result keeps
the existing empty-match message. Reload does not announce a source mutation.

Narrow source-management pages scroll their filters and rows in the same lazy
list, leaving results reachable when a soft keyboard reduces the viewport. Wide
pages retain pinned filters. The manager owns the search controller so recycling
the filter row preserves the visible query. Row identity and index lookup remain
provider-based across type, origin, status and query changes. Long selected
origin names use a single ellipsized line inside the picker; the complete name
and addresses remain available in the summary/editor and stored configuration.

The uncalled `_openAggregatePage` route and its dedicated import are removed from
the settings owner. Flat source rows and the selected-origin summary own the
reachable subscription-address entries, including disabled children and rows
narrowed by type, origin and text. The
shared aggregate page file and its independent widgets remain available. Product
entry tests open Settings, edit the exact row's origin, check cancel has no write
and inspect the submitted primary address and ordered fallback list.

## Alternatives considered

- Repaint the Material controls: does not adopt Miuix interaction.
- Replace the service layer during a UI migration: risks changing the strict
  proxy and explicit-install contracts without a UI reason.
- Eagerly build every source row: regresses the streaming-search build budget.

## Consequences

The historical t73 search-order gates retain their existing names and behavior
requirements. Their direct `SourinApi.searchAllStream` callback anchor was stale
after the page introduced its existing runner seam, and the single-line subtitle
anchor no longer described the release-status projection. The revised source
check follows the actual production fallback, captured keyword, epoch guard,
hit insertion and title_match score owners. It validates bounded function
sections rather than prohibiting display metadata across the whole file.

The matching display test feeds notes that deliberately reverse title relevance
into the real SearchPage and reads actual PosterCard geometry. It requires the
title-based order, ordinary captions below the cover and explicit completion
inside the cover badge. Two source-text copies remove the item-rank call or
replace title scoring with note scoring; the same source validator must reject
both. These copies never edit production files and establish the static gate's
discrimination, not execution of a mutated app. Root owns fresh Flutter and
analysis results; the previous two anchor failures are not product regressions.

Existing behavior tests retain their service-call, selection, disabled-state,
scroll-position and input assertions while following the new component types.
Discovery, idle search and aggregate-row tests additionally inspect actual
Miuix widgets in the rendered tree. These changes require the root task's
combined Flutter test and native-layout verification; this note records no
fresh passing run or native acceptance result.

Dialog behavior tests use the production `showAppDialog` route and wait for
Miuix's registered content to mount before interaction. A dialog is a bounded
viewport layer; placing its expanding popup host in an unbounded outer scroll
view tests a different layout from the product. Standalone source-list tests
remain scrollable, and dialog actions below the viewport are scrolled into view
before taps. Selection order, errors, deduplication, note round trips and solo
callbacks remain asserted after the actual user actions.

Order tests use actual Miuix clicks, keyboard Tab/Enter, rendered row positions
and pointer drag gestures. They cover stable row identity, origin/disabled labels,
boundary buttons, explicit save, cancel, pending save, failure/retry and a narrow
viewport. The manager-entry test starts with a JS filter, reorders the complete
source list and returns to the retained filter. Disabling the up action or drag
movement, or filtering the order draft, must each make its behavioral gate fail.

Provider-submission tests inspect the command's group id and ordered provider
ids, frozen Miuix choices and bulk actions, Escape/barrier/back dismissal, retained
failure text and draft, successful retry and cancellation followed by reopening.
The failure test must fail if save closes the dialog before the command returns.
These added cases require a fresh root-run result; no passing result is implied
by their presence.

Delayed address-write tests cover dialog, child-route and owner removal as well
as ordinary completion, for edit/install/import and success/failure. The actual
Settings-to-origin test failed with expected notification count one and actual
zero before the callback notification repair. Passing and native results remain
recorded separately in the root plan.

The empty-origin address entry and initial-load recovery tests failed on the
prior UI because the summary was absent and read failure also rendered the
empty-match text. Their successful-empty negative control passed. The tests also
inspect actual Miuix controls, canceled versus saved origin writes, ordered
fallbacks, exact one-time mutation notification, and disabled duplicate retry
while a read is pending. Root owns serial execution and fresh native acceptance.

Touch-layout tests at 360 by 640 expose the previous selected-name horizontal
overflow and the filter column's bottom overflow with a 260-pixel keyboard.
The behavior gate selects the real origin popup, opens its actual editor, types
through EditableText, and checks that matching rows and a successful empty match
can be scrolled into the remaining viewport. This phone case does not lower the
Windows minimum window size. Fresh root-run and native results are recorded
separately from the implementation contract.

The source-status filter uses SettingsDropdown and its shared Miuix popup path.
The direct library dropdown opened from Enter and remote Select, but its
pointer-only option rows did not apply keyboard selection: root's behavior RED
left the disabled provider visible after Down/Enter selected the enabled status.
The replacement retains status/type/origin/query filtering and pointer selection
while using the application's existing focused menu actions. Remote Select
opening passed as a positive control; it is not a reproduced failure. The
separate origin-popup keyboard-inset test must first tap and observe its actual
editor focus before checking geometry. Its initial autofocus expectation failed
before any inset assertion, so that run does not establish keyboard occlusion.
After tapping the actual editor, root reproduced the popup bottom at 582 with
the keyboard beginning at 380. The origin popup now derives its local usable
viewport from view padding and keyboard insets, limits the existing Miuix
position provider to that viewport and caps popup height there. Its option list
uses the remaining flexible height beneath the editor, preserving scrolling and
search selection. The window host and vendor positioning code remain shared;
only this source-search caller supplies its keyboard-aware boundary. Actual
editor focus, last-option reachability, filtering and selection remain asserted.

Reconsider the adapters if they stop preserving the existing input/focus
contracts, and reconsider the source-list layout if measured native or widget
performance exceeds the established streaming-search budget.

## Flat source management construction

The management page also builds rows through the scrolling builder. Build provider-to-origin and provider-to-multiple-provider-group indices when an accepted catalog arrives, preserving the first matching origin/group. Key rows by provider id and supply index lookup across filtering and order changes. Status, progress and errors retain their leading position. This avoids eagerly constructing every Miuix card and repeatedly scanning all origins on each input or state change.

The 240-source behavior test scrolls to the last row, disables it, filters to the first row, disables that row and returns to the last. It verifies the persisted ids and provenance after each reload. The test establishes behavior, not a native frame-budget improvement.


## Live source management entry

An empty Live page offers the shared Miuix “管理直播源” button. It opens the
existing source manager with the Live type selected, including disabled live
providers, and keeps Live as the underlying tab. The retained settings action
owner is mounted lazily without selecting Settings. Reentrant taps are guarded;
when the route returns, Live reloads through its existing loader. Opening the
manager does not import, enable or reorder sources.

Entry tests exercise the Miuix button, initial Live filter, disabled providers,
and back navigation. Live selection checks inspect actual MiuixCard decoration
and MiuixPressable focus, alongside geometry, clicks, popup dismissal and scrolling.
Native pointer evidence and measured results belong in the implementation plan.

## Retained settings owner and feedback

The source route subscribes to accepted settings data through `_dataRev` for
plugin-loading failures and recovery status. Feedback uses the shell-level
ToastHost, as required by [unified settings feedback](2026-10-18-settings-direct-entry-and-unified-toast.md).
There is no second null-valued toast notifier or invisible text listener.
Source type/search/status state belongs to SourceManagerPage; the settings owner
does not keep an unused duplicate filter. A single JS editor accepts both link
and source input.

SourceManagerPage owns reload busy state and prevents duplicate requests. The
retained settings owner can finish a reload, source switch save or source-order
save after its child routes are popped, refresh data and notify the shell.
The lifetime guard belongs to this owner: checking only the removed child route
would suppress notification of a completed save that the still-mounted Home needs.
When the owner itself is disposed, completion must stop before notifying its
former shell or starting another load. This covers the shared onSourcesChanged
callback as well as the delegated reload completion.

`task43_plugins_subpage_test.dart` exercises real settings entry/menu actions,
activity refresh without rebuilding the hidden owner, success/error feedback,
duplicate reload prevention, header/Escape/remote back and completion after route
or owner disposal. Delayed switch/order replies exercise both owner lifetimes,
including the rendered disabled switch after reopening. Tests must inspect
rendered feedback and refreshed rows;
matching retired page class names or an always-null notifier is not evidence.

The updated ordering gates and rendered inverse-note controls pass in the
52-case combined source-switch/filter/order/dialog suite. Analysis of the changed
production and tests has no errors or warnings; the ordering fixture retains one
pre-existing function-declaration style info on an unchanged line. The two
source-copy faults are checked by the same gate, not executed as runtime
production mutations.
