# Agent Note: Miuix controls for discovery, subscriptions and search

Status: implemented

Applies: 2026-11-08, flutter_miuix 1.3.0 and the Flutter product UI.

Extends [Miuix appearance](2026-11-08-miuix-appearance.md) to the discovery,
TVBox aggregate, subscription management and search controls. The keyword
audit classifies [proxy discovery](2026-11-08-proxy-github-source-discovery.md)
and [source scope](../bug-fix/2026-11-08-search-respects-source-scope.md) as
overlapping behavior contracts that remain in force. Aggregate editing and
subscription update-time notes remain applicable; no existing decision is
fully absorbed.

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

## Alternatives considered

- Repaint the Material controls: does not adopt Miuix interaction.
- Replace the service layer during a UI migration: risks changing the strict
  proxy and explicit-install contracts without a UI reason.
- Eagerly build every source row: regresses the streaming-search build budget.

## Consequences

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

Reconsider the adapters if they stop preserving the existing input/focus
contracts, and reconsider the source-list layout if measured native or widget
performance exceeds the established streaming-search budget.
