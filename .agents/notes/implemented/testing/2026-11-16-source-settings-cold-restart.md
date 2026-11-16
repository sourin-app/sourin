# Agent Note: Source settings cold-restart verification

Status: implemented

Related: [Current UI and default close callback verification](2026-11-16-current-ui-default-close.md).

## Problem

A setting visible immediately after a callback may exist only in memory. Earlier quit-preference restarts do not prove that source order or danmaku selection persists. Empty live and disabled-source fixtures also cannot prove filtering a populated list in those states.

## Decision

Extend the task-only authenticated mounted-widget interface to invoke actual instance, filter, search, ordering and save callbacks. Read resulting rendered rows and selected controls, and query the production local provider API independently. Keep runtime source and packaged core bindings explicit.

The first owned process selects the second built-in instance and swaps the first two providers through the rendered ordering arrow and save button. The next fresh process starts from the same task profile without reseeding, checks both saved values, clears the danmaku endpoint and token through the original Clear button and restores the source order through original callbacks. A third fresh process verifies the default instance, empty overrides and original order.

## Alternatives considered

- Recreating the profile between restarts: destroys the persistence condition.
- Writing preference files directly: bypasses the UI save path.
- Comparing only display names: loses provider identity and permits duplicate names.
- Accepting empty filtered fixtures as positive filtering: leaves that behavior untested.

## Consequences

For current product inputs unchanged since af2afab, all three qualified owners pass. Their process birth identities are distinct, each exits zero and naturally drains the Job for at least eight seconds, their windows disappear and their logs contain zero unhandled, Flutter, accessibility-tree or overflow errors. Exact 49-provider order persists, restores and persists again. The second built-in instance and its saved configuration survive a cold restart; the original Clear action restores empty overrides and the first default instance, confirmed in the third owner.

Search has both an actual single-provider result and a no-match result. Populated JS and aggregate rows match the independently read provider identities. Live and disabled fixtures are empty; their positive behavior remains unaccepted. The status callback is exercised directly, so the status popup interaction remains separate. No danmaku network-fetch acceptance is claimed.

An independent receipt audit rehashes 59 runtime files, 3587 build inputs and 22 screenshots. It rejects wrong restart order, missing saved instance, missing restored default and reuse of the same process identity. Earlier failures remain retained: an incorrect assumption that built-in selection must save no service token, and an unnecessary scroll request that found multiple mounted scrollables. The corrected successor reuses the qualified first owner and does not reseed subsequent owners.

Revalidate affected cases when product, core, UI callbacks or serialization changes. This diagnostic startup is separate from ordinary Release startup, populated library covers, address/provider selection, protocol breadth and performance. Machine-specific scripts and raw receipts stay in the task probe directory.
