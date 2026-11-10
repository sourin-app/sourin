# Agent Note: Miuix notification lifetime and keyboard access

Status: implemented

Applies to: 2026-11-08, Flutter UI with `flutter_miuix` 1.3.0.

Extends [unified application feedback](2026-10-18-settings-direct-entry-and-unified-toast.md) and [Miuix appearance](2026-11-08-miuix-appearance.md). The former still owns the public `showAppToast` entry, no-host no-op and independence from ScaffoldMessenger. Keyword audit also found feedback call-site and static-gate notes; their distinction between mounting a host and actually displaying feedback remains applicable.

## Problem

Miuix notification rendering must preserve independent message lifetimes and keyboard actions. A shared 100 ms expiration counter can expire a later message early when it arrives between ticks. The package's Snackbar dismissal glyph uses a pointer gesture without a focus node; wrapping only the page in Escape shortcuts also leaves a focused Snackbar action outside that shortcut.

## Decision

`AppToaster` renders actual `MiuixSnackbar` cards in a stable Stack. The page remains at the same element path when the first message arrives or the last disappears. Every entry owns an expiration timer starting at enqueue time. The shared periodic timer only updates opacity; dismissing, evicting or disposing an entry cancels its expiration timer, and an empty host stops its periodic timer.

Escape shortcuts surround both the page and notifications, dismiss the newest notification first and fall through when none remain. Each Snackbar card is a keyboard close target with a visible focus outline and accessible close label. Its own action retains independent focus and supports Enter, Space and remote Select. Pointer close remains the package's real dismissal control. Performing an action retains the prior application behavior: invoke the callback while leaving the notification available until dismissal or expiration.

The global overlay's focus traversal group attaches to the active page's focus scope and follows focus changes across routes. Merely placing focusable cards next to the Navigator in `MaterialApp.builder` leaves them outside WidgetsApp's closed Navigator Scope; Tab cannot reach those siblings. The group changes focus ancestry without requesting focus when a message appears, while retaining the global visual placement. A push/pop regression exercises keyboard access before and after the focused route is removed.

Tooltip interaction tests use application `MiuixTooltipHost` anchors and rendered `MiuixPlainTooltip` content. The host owns an OverlayEntry and reconciles content/theme changes after build; [anchor visibility and overlay ownership](../bug-fix/2026-11-10-tooltip-clipped-scroll-anchors.md) governs clipped, fading and resized anchors, geometry and disposal. They cover hover delay, cancellation, exit and disposal, plus anchor focus, activation, focus-loss dismissal and Escape propagation. The application adapter supplies those interactions without adding a separate Tab stop.

Escape callback tests place the page's `DismissIntent` action inside `Scaffold.body`. Both the route's `_DismissModalAction` and Scaffold's `_DismissDrawerAction` shadow an outer action, even when those nearer actions are disabled. The test shortcut remains outside ToastHost so notification priority and eventual page delivery are both asserted. The semantics test disposes its handle in `finally` before Flutter's end-of-test verification, which runs before registered tear-down callbacks.

## Alternatives considered

- Round all expiration times onto the shared timer: shortens later lifetimes by up to one tick.
- Replace the Snackbar with a custom card: loses the requested actual Miuix component.
- Exclude descendant focus from the keyboard close target: makes the Snackbar action unreachable.
- Change the page subtree only while a notification exists: remounts unkeyed local state for direct host consumers.

## Consequences

At most four entries own expiration timers; idle hosts own none. Keyboard focus on a message can close it, and focus on its separate action invokes that action. Tests inspect rendered controls and actual callback/count/lifetime outcomes rather than the values supplied to widgets.

The coordinating task's `.probe/parallel-astra-1108/miuix-feedback-composer-poster-v3.log` records all ten tests in `miuix_feedback_controls_test.dart` passing (the file reaches `+10` before the next test file loads). This includes the actual Snackbar action/close Tab paths, Escape priority/fall-through, cross-route focus, full per-entry lifetime, stable page state, disposal and Tooltip keyboard/hover behavior. That file-level result is not a claim that the entire combined log passed; subsequent unrelated test files had their own failures.

This lane performs formatting and diff checks. Native acceptance and package verification remain owned by the coordinating task and are not established by the widget tests. Revisit the keyboard wrapper if a future Miuix Snackbar exposes a focusable dismissal slot.
