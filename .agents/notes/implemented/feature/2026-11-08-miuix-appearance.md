# Agent Note: Miuix appearance and one product color mode

Status: implemented

Applies: 2026-11-08, Flutter product shell.

Partially supersedes: [dialog migration](../architecture/2026-10-24-alertdialog-to-glass-dialog-migration.md), only the theme import and large preview entry points. The remaining dialog shell contract stays in force. The [shared shell decision](2026-10-19-dialog-shell-unification-and-hover-sticky-bit.md) remains applicable. Keyword audit also found the R4 device acceptance and N7 glass frame-cost testing notes; those concern measurements, not appearance selection, and are retained unchanged.

## Problem

A stored theme pack can override requested brightness and give window chrome a different palette from page controls. Appearance exposes many unrelated theme packs while the requested interface has one light/dark/system choice. Glass styling alone does not provide the requested Miuix controls.

## Decision

The complete component migration extends this initial appearance decision through [shared controls and framework bridge](2026-11-08-miuix-controls-and-framework-bridge.md), [navigation and settings](2026-11-08-miuix-navigation-and-settings.md), [menus and dialogs](2026-11-08-miuix-shared-menus-and-dialogs.md), [source discovery and search](2026-11-08-miuix-source-discovery-and-search-controls.md), [player controls](2026-11-08-player-miuix-controls.md), and [notification interaction](2026-11-08-miuix-feedback-controls.md). These use actual Miuix components, including navigation rail/bar, menus, popup layouts, inputs and controls. The controlled SDK bridge supplies only dependencies required by the library's internal widgets; it is not a second visible component system.

The [home-card surface contract](../bug-fix/2026-11-08-home-card-and-motion-boundaries.md) applies the shared surface-container role to compact library cards.

The [OS4 glass shader patch](../bug-fix/2026-11-09-miuix-glass-shader-material-call-site.md) preserves actual Miuix and its sampling contract while consolidating material call sites; material pixel comparison passed, and ordinary startup performance validation remains pending.

Use flutter_miuix 1.3.0 actual theme, cards, buttons and switches. This is the Flutter community implementation; the reference Android application uses the Kotlin Miuix implementation. AppThemeHost injects both Miuix and the existing material_ui theme using a shared palette. Neutral page/card layers preserve hierarchy. The primary color supports small white text at 4.5:1; alpha text roles are composited before entering existing contrast calculations.

The production shell does not initialize or wrap `liquid_glass_widgets` (2026-11-09).
All visible product consumers use Miuix, so the former package's three eager
shader loads, theme wrapper and `SOURIN_NO_GLASS` accessibility override have no
product consumer. Miuix's own glass assets, backdrop and theme remain intact.
The dependency remains for explicitly separate historical probes/tests; removing
it from pubspec would break those callers. Its old first-frame measurements are
historical evidence, not a requirement to preload an unused engine. Startup
benefit must be measured from actual AOT linking and FrameTiming, not inferred
from fewer imports.

AppScaffold supplies the Miuix background role explicitly when its caller does
not choose a container color. The upstream scaffold delegates to MiuixSurface,
whose default is surface; using that default makes white page gutters and white
cards indistinguishable in light mode and collapses their dark-mode layers too.
The shared page header uses the same background default; callers may override it.
Cards retain surfaceContainer. Explicit page backgrounds, including the black
video surface, take priority. Rendered pixel tests verify both neutral layers
in light/dark modes and preserve the explicit-black override, alongside the
existing nested-keyboard-inset and child-lifetime assertions.

AppScaffold also supplies an inherited onSurface text color for Flutter Text
children. MiuixSurface publishes MiuixContentColor, which MiuixText reads but
ordinary Text does not. Without that bridge, custom list contents inherit black
text even in dark mode. Explicit child styles and nested themed pages retain
precedence. Regression checks read rendered paragraph colors in both modes and
require contrast of at least 4.5:1; the dark case fails at 1.247:1 without this
bridge. Native dark/light ordering-page screenshots verify readable names and
sequence numbers alongside the separate page/header/card layers.

The shared ListTile adapter supplies Miuix headline1 (medium weight) and body2
styles to its custom title and summary content. Leading text and icons inherit
the row state color; disabled titles and summaries use Miuix disabled colors.
Without this adapter, the BasicComponent custom-content path bypasses its
MiuixText styles and leaks unrelated ancestor typography. Explicit child
styles retain precedence. Rendered paragraphs, disabled activation and the
independent trailing keyboard actions are covered together in controls tests.

The primary ListTile component merges its selection annotation with the named
row's existing enabled state and tap action. Both selected and unselected
states remain explicit, including on disabled rows and after a selection
change. The merge surrounds only the primary component; independent trailing
buttons retain their own labels, enabled state, actions and keyboard stops.
This adapter contract applies to the player's selected stream/live rows,
whose callers already pass their current selection. Controls regressions read
the exposed semantics nodes and invoke the real accessibility tap action;
they do not load a native player or establish native playback acceptance.

Product AppTheme resolves light/dark/system independently of legacy pack selection. Explicit pack preview tooling remains available to its callers, but the product appearance page provides direct modes and an interactive switch preview. Shared settings controls use the actual Miuix widgets, including keyboard activation.

## Alternatives considered

- Copy the Android UI library into Flutter: incompatible widget and rendering runtimes.
- Keep pack priority and only replace colors: a stored pack still defeats mode changes.
- Repaint existing glass controls to resemble Miuix: misses framework interaction and theme behavior.

## Consequences

The 2026-11-09 shell cleanup passes 45 existing theme/navigation/source/safe-area
regressions. Ordinary Windows callback and screenshot checks retain Miuix light
and dark surfaces and restore the prior system mode; the old package is absent
from loaded production libraries. One same-profile AOT before/after observation
removes exactly three program links (81 to 78), with aggregate linking 5.324 to
4.039 seconds and maximum pipeline wait 3.673 to 2.661 seconds. Raster peak does
not improve (61.919 to 75.073 ms). These are bounded observations, not a cold-cache
benchmark, all-page pixel proof or completion of the performance goal.

Existing stored pack data remains intact but does not select the product appearance. Theme import and large-preview dialogs are absent from the appearance page; their old tests assert the new direct interaction. Other dialogs retain their existing contracts. Reconsider the package choice if platform interaction or accessibility cannot meet the same constraints.

Historical verification of the initial appearance change: 83 focused Flutter tests passed, covering rendered controls at 360/1280 widths, keyboard activation, contrast, legacy pack isolation and explicit preview tooling. A clean checkout of 2b9410e with those tests produced four intended assertion failures (pack priority, missing Miuix cards at both widths, old appearance structure), with one existing keyboard behavior still passing. Those results predate the complete component migration and do not establish its native acceptance. Current component behavior and evidence belong to the linked notes and the coordinating validation report.
