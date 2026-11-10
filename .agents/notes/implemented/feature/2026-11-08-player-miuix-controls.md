# Agent Note: Player controls use actual Miuix components

Status: implemented

Applies: 2026-11-08, Flutter player, episode selection, detail actions and playback settings.

Partially overlaps with [Miuix appearance](2026-11-08-miuix-appearance.md): that decision supplies the palette; this one defines playback interaction and rendering contracts. The [local rebuild decision](../simplification/2026-10-18-player-mouse-jank-localize-rebuilds.md) remains in force.

## Problem

Changing colors on legacy controls leaves the player with a separate interaction and visual system. Video controls also need a dark surface even when the surrounding application uses light mode. Replacing the progress renderer must preserve seek throttling, buffer geometry, keyboard access and updates from the real playback position.

## Decision

Use flutter_miuix components directly or through `miuix_controls.dart`. Buttons, text inputs, choice controls, sliders, tooltips and progress indicators render the actual package widgets. Popover rows, episode cells and danmaku type toggles use MiuixPressable. Player cards and inputs receive the dark Miuix theme independently of the surrounding page.

PlayerProgressSlider delegates interaction and thumb painting to the actual MiuixSlider. Drag changes update only a local preview. Release commits one seek; cancellation clears the preview without seeking. Position updates continue through the existing ValueListenableBuilder. The buffered interval is a separate layer beneath the translucent track, inset by the actual thumb radius and clamped to duration. A supplied buffer key identifies that interval, not the played range.

The buffer stack expands its slider child to the available bounds. MiuixSlider's childless CustomPaint otherwise collapses to zero width under loose Stack constraints, leaving a full-size buffer container with no usable slider. Rendering tests assert the actual painter dimensions before inspecting its thumb pixels.

Danmaku information uses an opaque dark MiuixCard so bright video frames cannot alter the text background. This partially supersedes the glass surface choice in [seven panel requirements](2026-10-19-danmaku-panel-seven-items.md) and [glass placement](../architecture/2026-10-18-glassify-where-it-is-visible.md). Their readability, source information, binding, failure reporting and measured performance constraints remain applicable. The previous inner-alpha gate is replaced by a rendered pixel comparison over white and cyan backgrounds.

Popup focus retention, Escape handling, line selection and episode identity continue through their existing controllers. The settings tab row uses keyboard-capable Miuix choice buttons. Subtitle font choices use the actual Miuix window dropdown while retaining the existing player-property callback.

The small-popover layer retains its last rendered body and anchor while the
existing opacity/slide exit completes. Controller.close changes the active
state immediately; the retained subtree immediately loses pointer, focus and
semantics interaction, then unmounts after the opacity completion. Reopening
or selecting another panel cancels obsolete removal; replacing the controller
does not retain its former panel. Keeping only an animated empty box would
provide no actual exit motion. Tests read the rendered animation's intermediate
opacity and content/anchor presence, rather than only its target value, and
check focused-editor dismissal, inaccessible exit controls, quick reopen,
replacement and disposal.
Only a closing render binds the removal completion: a controller close that
arrives immediately before the entering ticker's last frame must not let that
old entrance callback remove the retained body. The exact duration edge can
evaluate opacity to zero while the floating-point ticker is still forward;
regressions observe the following normal frame before requiring unmount.

MediaPage, standalone DetailPage and PlayerPage use AppScaffold, which mounts the actual MiuixScaffold. Windowed surfaces keep the current theme color and the fullscreen/video surfaces keep their black background. AppScaffold consumes keyboard viewInsets after applying their bottom padding, so nested media/player shells subtract the inset once. Its Padding and MediaQuery wrappers stay mounted at zero inset to preserve page state when the keyboard opens or closes.

PopoverController keeps at most one pending geometry watcher. Switching the open panel or closing and reopening before the next frame reuses that watcher; otherwise each switch adds another recurring render-coordinate traversal. The regression test counts actual `applyPaintTransform` calls through the mounted anchor tree and requires one read per supplied frame, zero while closed, and no frame scheduling by the watcher.

PopoverAnchorButton cancels its pending hover-open timer from an outer `Listener.onPointerDown`. PlayerPage's desktop double-tap recognizer delays a child single click until 300 ms; the independent 150 ms hover timer otherwise opens the panel first, and the delayed click toggles it closed. The raw listener sees the press even when the nested Miuix button wins the gesture arena. An ancestor `GestureDetector.onTapDown` did not fix the race because that recognizer lost to the child. Explicit clicking still toggles a panel that was already open before the press.

The note audit also found the [send capability decision](2026-10-17-player-danmaku-send-entry.md), which is independent of the control implementation: capability gating remains, and this change does not reinstate its historical floating placement. The [rejected buffering-spinner proposal](../../rejected/bug-fix/2026-10-18-buffering-spinner-despite-cached-range.md) stays rejected; a visible buffer interval does not establish decoder readiness.

Buffered progress is delivered through a ValueListenable scoped to PlayerProgressSlider. Native cache polling includes span and percent in change detection; unchanged endpoints still update a shrinking interval. Stop invalidates pending reads, and non-finite or negative time values are unavailable. Position, duration, seek throttling and the live progress omission retain their existing contracts.

The 4px track and 28px hit area are deliberately independent. Thumb pixel checks render the actual Miuix painter at 4x and convert centroids back to logical coordinates. A 1x white-pixel area threshold inherited from the thicker legacy thumb is not appropriate to this geometry. The pixel count threshold stays intact at 4x; making the thumb transparent must fail. Endpoint, drag, cancel, buffer-bound and live-omission assertions remain.

## Alternatives considered

- Repaint the old controls to resemble Miuix: does not satisfy the requested actual component migration.
- Draw a custom thumb above MiuixSlider: creates competing position renderers and hides package behavior from the rendering tests.
- Rebuild PlayerPage on slider movement: violates the existing local rebuild constraint and expands work on every pointer event.
- Preserve the old glass alpha assertions: measures a superseded visual choice and permits the actual text background to remain unverified.

## Consequences

Behavior tests read the actual Miuix slider painter, exercise tap/drag/cancel/keyboard paths, and retain failure, pending-input, focus and line/episode assertions. Tooltip tests locate the application MiuixTooltipHost and verify rendered MiuixPlainTooltip content; [anchor visibility and overlay ownership](../bug-fix/2026-11-10-tooltip-clipped-scroll-anchors.md) governs their lifecycle. Surface tests compare real pixels, not just input color constants. These tests require the product theme bridge when mounting actual Miuix text inputs.

The scaffold regression checks actual nested Miuix shells, content geometry and an unkeyed stateful child's lifetime across keyboard inset changes. Embedded layout/theme tests retain their existing contracts while locating the Miuix shell. The player capability import allowlist now explicitly includes flutter_miuix while preserving the rule that the settings panel does not own mpv or playback.

Root executed the actual PlayerBottomBar/Miuix mouse-click regression under a desktop double-tap ancestor. `miuix-popover-click-red-v3.log` records one failure and one passing explicit-close control: a fresh click was closed at 149 ms, open at 151 ms, then closed at 301/551 ms. The first two attempts were import failures, not behavioral RED evidence. The attempted ancestor onTapDown fix still failed (`miuix-popover-click-green-v1.log`, 12 passed / 1 failed). With the raw pointer listener, `miuix-popover-click-green-v2.log` passes all 51 cases, including the two hover/click cases, geometry watcher, ten quick-panel interactions, pixel contrast, dialog geometry and Material-boundary audits. These logs are under `.probe/parallel-astra-1108/`.

Native v5 had already decoded the synthetic A2/B2 sequence but stopped before focusing search; it did not complete native interaction acceptance. Its lifecycle trace now records actual controller transitions and call stacks without reopening or replacing a removed target. V6 confirmed that the raw-pointer fix leaves the panel/editor stable, then exposed a separate harness error: the same editor gained focus 303.625 ms after the pointer-up observation, 47.309 ms after the driver had prematurely failed at its 250 ms check. The trace retained the same panel, editor and focus-node identities, and the player typing state became true with focus.

The shared diagnostic click helper therefore retains its original 250 ms observation, waits for the original pointer-up plus kDoubleTapTimeout, then observes two frames before checking the result. The gear continues to require the same unique panel/editor across those frames. `t20261108_miuix_editor_double_tap_completion_test.dart` reproduces the real Miuix editor under a parent double-tap recognizer and checks focus through the actual mouse path; it does not request focus directly. This is a diagnostic timing correction, with no further production change. V6 stopped before the remaining interaction gates; complete native validation remains a separate root-owned run.

The child implementation checks are syntax parsing and diff validation only; focused Flutter execution, mutation checks and native window acceptance are separate root-agent validation gates. Revisit the adapter if the package changes gesture completion, keyboard, semantics or color contracts. Do not treat widget presence or successful compilation as evidence of playback acceptance.
