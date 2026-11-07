# Agent Note: Persisted application logo selection

Status: implemented

Applies: 2026-11-08, Flutter appearance and Windows desktop branding.

Extends [Miuix appearance](2026-11-08-miuix-appearance.md) with the four approved logo choices. That note's shared palette and light/dark/system decision remains unchanged. The exploration README now records the chosen default instead of treating all designs as unselected candidates.

## Problem

The approved orbit logo was still an exploration asset. Application chrome and the Windows executable used the previous icon, and the remaining designs had no selectable entry point.

## Decision

Default to orbit (源环) and provide frames, current and screen in appearance settings. Store a stable identifier in UiPrefs, restore it before the shell and tray start, and fall back to orbit for an unknown identifier. Rebuild only the logo widget when selection changes. Serialize native tray/window icon updates and remove the listener before disposing the tray.

Generate transparent PNG and multi-size ICO assets from the approved PNG explorations. The Windows executable and default tray ICO are byte-identical. Runtime selection changes window/tray icons; the executable file's embedded icon remains the approved default.

## Alternatives considered

- Replace only the executable icon: does not provide the requested alternate choices.
- Bundle the alternate images without persistence: resets the user's choice at every launch.
- Rewrite the executable resource on selection: unnecessary file mutation and packaging complexity; the desktop plugins already support window/tray changes.

## Consequences

The application identifier is independent of content sources, accounts, playback and theme mode. Other platforms receive the selected in-app image; Windows additionally switches its native window icon. Mobile launcher icons and macOS Dock icons are not dynamically replaced. The appearance preview remains scrollable on narrow screens.

Verification records are in `.probe/logo-selection-1108/`: nine focused tests pass, exercising actual button taps, rendered title image, persisted JSON and reload, narrow/wide Miuix appearance and the existing tray exit contract. A clean 4894358 checkout with only test-support logo types/assets added fails on the missing alternate selector, as intended. Two actual Windows runs switch every logo, open a dialog, exit normally, restore the saved third logo on restart and switch back to orbit. Both runs record zero Flutter exceptions and zero native icon-update errors. Native screenshots include light and dark appearance. Final product packaging uses the CMake install manifest plus build-side runtime files to exclude old runtime caches, with per-file hashes against the actual release output.
