# Agent Note: Reveal selected sources using actual pill geometry

Status: implemented

Applies from 2026-11-10 to the shared source selection rail.

Related decision: [shared selector](../feature/2026-10-31-liquid-glass-selector-unify.md)
owns the single source pill component; [Miuix navigation](../feature/2026-11-08-miuix-navigation-and-settings.md)
owns component choice. Neither appearance decision changes.

The proposed/implemented/rejected note audit found these overlapping owners and
no separate owner of selected-source scroll positioning.

## Problem

The rail scrolled to index times 108 pixels. Pill widths vary with source names.
A real click could therefore scroll its selected pill out of the viewport. A
selection restored at creation was not revealed at all. Reordering also retained
an obsolete scroll location.

## Decision

Keep stable item keys and index mapping for the lazy list. Reveal an already
mounted selected/focused pill from its actual rendered bounds, and leave fully
visible pills stationary. For an unmounted selection, approach using nearby
laid-out item offsets, then correct from the selected pill's bounds. Do not mount
every Miuix glass surface or duplicate its text/spacing calculations.

Schedule on first mount and changes to selection, focus or source configuration.
A revision guard cancels stale work and unmount; a new request stops an older
driven scroll even when the new choice is already visible. Filtering still uses
the shared enabled-and-working rule.

## Alternatives considered

Changing the guessed width only moves the failure to another set of labels. An
eager Row would trade the bug for building every source during startup. Using
Scrollable.ensureVisible on all ancestor scrollables could move the page as well
as the horizontal rail; the implementation only moves its own controller.

## Consequences

Three new real-widget cases fail before correction: clicking a visible short
name, restoring a far selection, and selecting/reordering mixed widths. A second
regression catches an old animation continuing after a new selection. Controls
cover reverse movement, rapid selection and unmount, a bounded number of mounted
pills, and disabled/unavailable source filtering. The former filtered-index
source-string assertion is replaced by actual selected-pill geometry. Existing
mouse/touch drag, keyboard, theme, sticky header and cache-first-frame tests stay
required. Native rendered/hit-test evidence is recorded in the implementation plan.
