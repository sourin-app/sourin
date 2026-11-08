# Agent Note: Miuix navigation and settings controls

Status: implemented

Applies: 2026-11-08, Flutter product shell, library, live, browse, home, danmaku search and settings pages, flutter_miuix 1.3.0.

Extends [Miuix appearance](2026-11-08-miuix-appearance.md) and [compact home and motion preview](2026-11-08-compact-home-and-motion-preview.md). The note audit found the settings direct-entry decision, which remains applicable to route actions, and the player bottom-bar lifetime decision, which concerns player controls rather than shell navigation. No proposed or rejected note requires a six-item Miuix bottom bar.

## Problem

The shared palette does not migrate the hand-drawn glass navigation, shelf tabs, settings entry rows or remaining Material form controls. The package's bottom navigation accepts only two to five destinations while the app has six. Its navigation bar and tab row expose pointer gestures without application keyboard handling.

## Decision

AppScaffold uses MiuixScaffold. At widths of at least 900 logical pixels the shell uses MiuixNavigationRail with all six destinations; smaller layouts use MiuixNavigationBar with four frequent destinations and a fifth menu entry for cached media and settings. A secondary selection appears as the fifth entry's label and icon. Existing page caches, route actions, unread counts and motion preference resolution remain responsible for state and transitions.

Navigation wraps package components with one focus node per destination, Enter/Space/remote Select activation and a foreground focus ring. The package's internal focus is excluded from that branch to avoid duplicate tab stops. The non-contour MiuixTabRow serves shelf and plugin tabs, with Left/Right selection and one focus target for the group. It does not animate the selection indicator; page transitions continue to honor reduced motion through the existing production mechanism.

ShellPage's TV early key handler lets horizontal keys reach a focused SettingsTabs group or shared Miuix slider. Vertical keys keep spatial navigation so the remote can leave either control. This exemption must be tested with the real ShellPage handler mounted; testing an isolated tab row would miss the earlier interception. Direct package switch preferences, gesture buttons, compact shelf cards and built-in danmaku source cards add remote Select to the package's Enter/Space activation.

Spatial navigation treats a non-scope node with no focusable descendants as a control target. Shared adapters retain excluded Miuix focus nodes beneath their application focus node; requiring the physical focus tree to have no children would make every such control unreachable from a TV remote. FocusScopeNode is always excluded, and a container with an independently focusable descendant is excluded. The same predicate governs candidate collection and initial focus so a valid adapter control is not unexpectedly re-primed.

The existing spatial-navigation real-path suite uses this semantic leaf contract too. Its real ShellPage cold-start check proves that excluded internal nodes exist, identifies the actual home navigation control, retains the topmost-candidate and rendered-rectangle assertions, and sends one Down event to the adjacent live control. At 960 logical pixels the rail's home item also has autofocus, so this case does not independently establish initial-focus priming; the separate no-autofocus cold-start cases retain that distinction. The migration also keeps the negative test excluding scopes and containers with independently focusable controls.

Settings entries use MiuixCard and MiuixArrowPreference. The application owns the entry focus ring and excludes the preference's internal focus so returning from a route cannot leave a filled focus overlay. Buttons, text fields, switches, sliders and choices use the shared Miuix adapters. Compact library cards use MiuixCard and MiuixLinearProgressIndicator with the existing fixed poster, padding, text-size expansion and detail action.

The follow-page tabs use the same MiuixTabRow, and its continue-watching cards and progress use MiuixCard and MiuixLinearProgressIndicator. Live filters and home channel rails use MiuixCard. Browse, live, danmaku search and cache controls use the shared adapters without changing loading, selection or playback data paths.

Settings status pills use MiuixBadge. Home live-channel actions and the live all-channels action use Miuix buttons. Browse uses AppScaffold, and core-error retry/copy use the shared adapters. The custom window buttons keep their Windows hover semantics by setting the actual Miuix icon-button background from local pointer state: red with a white icon for close, neutral emphasis for minimize and maximize. Their rectangular hit regions remain the titlebar's fixed size.

SettingsDropdown uses a Miuix button and the shared Miuix popup for both pointer and keyboard activation. Returning an option index preserves nullable “all” filter values, which would otherwise be confused with popup cancellation. Package WindowDropdownMenu has pointer-only popup items in 1.3.0; using one shared popup route preserves keyboard navigation after either activation method. Live and danmaku action menus use that route as well.

AppThemeHost includes the controlled framework bridge required by the package's internal SDK Theme and localizations. The app's stateful light/dark/system preference remains the source of brightness.

The final visible-component audit found four missed surfaces. Home and cache now call the shared `ui.RefreshIndicator` adapter added by root; it renders `MiuixPullToRefresh`, keeps the existing `Future<void>` refresh callback, prevents a second request while one is pending, clears its refreshing flag in `finally`, and supplies Chinese indicator text. The caller's scroll physics and force-refresh operation remain intact. Non-cloud provider login uses `AppDialogShell` at width 460, keeps its expanded login panel, returns the existing success boolean after dismissal, and updates the completion action after a successful login. The embedded playback-settings overlay retains its `Positioned.fill`, scrim, safe-area padding, 560 by 620 bounds and section order while its visible surface is an actual `MiuixCard` with clipping.

The cast device chooser and active-session sheet keep their transparent bottom-sheet routes, keyboard inset, safe area, height constraint, device actions and theme-selected background. Their visible surfaces now use `MiuixCard`; an outer clip supplies only the existing rounded top corners, so the bottom corners stay square. These changes do not replace bottom-sheet navigation with a dialog route.

## Alternatives considered

- Force six children into MiuixNavigationBar: violates the package assertion and hides the actual supported component contract.
- Keep the custom glass pill and recolor it: does not provide the requested library components.
- Remove keyboard handling: makes the package pointer-only widgets inaccessible from a TV remote.

## Consequences

Desktop navigation is a side rail. Compact cached-media and settings entry requires the overflow menu. The old draggable glass selection pill is replaced by library navigation interaction. Reconsider the overflow grouping if the library supports six destinations without a local fork or usability evidence calls for different frequent destinations.

The focused tests inspect actual Miuix widget trees, rendered bounds, callbacks, selected states, progress and painted card surface colors. Native Windows acceptance must additionally exercise light/dark/system mode, the available logo choices, shell navigation, settings routes and keyboard focus. Formatting alone does not establish runtime or native acceptance.

The historical theme_tokens, t36_pill_drag_follow and zz_t66_glass_follow gates now mount the migrated production widgets. They check resolved text colors against painted Miuix surfaces across a live light/dark/light change, drag cancellation and single release activation, keyboard/remote navigation, actual FollowPage tab selection, continue-card progress and detail actions. They do not retain obsolete glass-gradient constants or swallow Flutter framework exceptions.

Follow fixtures replace only SourinCore's existing async transport entry with fixed command responses. The production load and tab-refresh paths still deserialize those responses and render the cards; no test sets loading flags or assumes that fake-clock pumps finish native callbacks. Shell TV tests keep the real early handler mounted while pushing the actual FollowPage and verify tab selection followed by vertical navigation and detail activation. Window hover tests mount SourinApp and intercept the window-manager method channel, reading rendered ShapeDecoration colors without sending commands to a real window.

The source-bar regression gate retains pointer selection, mouse and touch horizontal drag, counts and pinned-header behavior. Its appearance checks read Miuix ShapeDecoration and resolved RenderParagraph colors for selected and unselected items, require readable contrast, and keep the same SourceBar element, selected source, scroll offset and focus through a light/dark/light change. Remote Select reactivates the focused source once, and Tab/Enter activates the next source. Old glass-gradient alpha values no longer define the intended appearance.

The component audit distinguishes remaining visible legacy components from transparent framework hosts and domain-specific layout. A transparent Material around an already migrated control is not evidence that the visible control still uses Material. The historical GlassFieldShell name likewise resolves to a MiuixCard and MiuixTextField; names and imports alone are insufficient migration evidence.

The isolated native_ui driver reads MiuixCard ShapeDecoration paint instead of looking for a Material color. It exercises rendered shell navigation, the production Miuix search field's edit/focus/clear path, system brightness, all currently offered logo choices and decoded shell assets, while retaining motion, compact-card geometry and graceful quit checks. Its pointer and text events stay inside the diagnostic process. The driver records the navigation variant actually rendered; observing a desktop rail alone does not establish compact-layout native acceptance.

The final production edits pass Dart formatter parsing and `git diff --check`; this lane has not run Flutter, analyzer or native processes. Root's gap V2 run passed the migrated dialog-consistency and cast coverage. The obsolete QR-login exemption was removed, and measurements now read actual MiuixCard decoration while retaining the width/radius/opacity limits.

The two refresh fixtures initially reported zero requests even though real overscroll reached the release threshold. Root's diagnostic V4 run passed both tests and established the cause: the package awaits its critically damped release spring before invoking the business callback, and the actual state reached refreshing after 1,200 ms. The old fixed 1,000 ms test budget expired too soon. Notification evidence showed normal pointer-up/scroll-end delivery and no post-release ballistic overscroll. The fixture now waits for actual Miuix refreshing/idle state with a 3-second bound, retaining the real segmented pull, release-threshold, one-request/no-reentry, completion/retry and disposed-page assertions. Temporary event logging was removed after diagnosis; production thresholds and adapter behavior were not changed. This widget-test result does not establish native playback acceptance.
