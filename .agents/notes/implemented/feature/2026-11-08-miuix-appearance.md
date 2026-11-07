# Agent Note: Miuix appearance and one product color mode

Status: implemented

Applies: 2026-11-08, Flutter product shell.

Partially supersedes: [dialog migration](../architecture/2026-10-24-alertdialog-to-glass-dialog-migration.md), only the theme import and large preview entry points. The remaining dialog shell contract stays in force. The [shared shell decision](2026-10-19-dialog-shell-unification-and-hover-sticky-bit.md) remains applicable. Keyword audit also found the R4 device acceptance and N7 glass frame-cost testing notes; those concern measurements, not appearance selection, and are retained unchanged.

## Problem

A stored theme pack can override requested brightness and give window chrome a different palette from page controls. Appearance exposes many unrelated theme packs while the requested interface has one light/dark/system choice. Glass styling alone does not provide the requested Miuix controls.

## Decision

Use flutter_miuix 1.3.0 actual theme, cards, buttons and switches. This is the Flutter community implementation; the reference Android application uses the Kotlin Miuix implementation. AppThemeHost injects both Miuix and the existing material_ui theme using a shared palette. Neutral page/card layers preserve hierarchy. The primary color supports small white text at 4.5:1; alpha text roles are composited before entering existing contrast calculations.

Product AppTheme resolves light/dark/system independently of legacy pack selection. Explicit pack preview tooling remains available to its callers, but the product appearance page provides direct modes and an interactive switch preview. Shared settings controls use the actual Miuix widgets, including keyboard activation.

## Alternatives considered

- Copy the Android UI library into Flutter: incompatible widget and rendering runtimes.
- Keep pack priority and only replace colors: a stored pack still defeats mode changes.
- Repaint existing glass controls to resemble Miuix: misses framework interaction and theme behavior.

## Consequences

Existing stored pack data remains intact but does not select the product appearance. Theme import and large-preview dialogs are absent from the appearance page; their old tests assert the new direct interaction. Other dialogs retain their existing contracts. Reconsider the package choice if platform interaction or accessibility cannot meet the same constraints.

Verification: 83 focused Flutter tests pass, covering rendered controls at 360/1280 widths, keyboard activation, contrast, legacy pack isolation and explicit preview tooling. A clean checkout of 2b9410e with the new tests produces four intended assertion failures (pack priority, missing Miuix cards at both widths, old appearance structure), with one existing keyboard behavior still passing. Native appearance acceptance remains a separate delivery check.
