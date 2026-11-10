# Agent Note: Preserve dialog content during submission

Status: implemented

Applies: 2026-11-09, AppDialogShell and SourceManagerPage.

This refines the [Miuix feedback and popup contract](../feature/2026-11-08-miuix-feedback-controls.md): the same popup instance must survive pending submission. It preserves the existing component choice and dismissal policy; only lifecycle continuity and covered-page ticker activity change.

## Problem

Some forms set `onClose` to null while submitting. AppDialogShell previously
removed its CallbackShortcuts ancestor in that state. This unmounted the actual
Miuix popup host, its focus scope and form content, then left a blank frame while
the new popup registered. Removing the close button also reduced the header
height and shifted the form. Source management additionally kept its background
indeterminate progress animation running while a modal import/editor was open.

## Decision

Keep the shortcut wrapper and Miuix popup host at the same position in the tree.
Only the shortcut bindings change when dismissal becomes unavailable. Retain the
close control's layout slot when its callback is absent. Existing busy dismissal
rules and actual Miuix controls remain in force.

Gate the source page's progress ticker by its route visibility. The action guard
and progress layout remain; modal forms own their own progress while open, and
the page's ticker resumes if work remains after the modal closes.

## Alternatives considered

- Waiting additional frames in tests hides the unmount and loses unsaved local
  form state. It does not repair the lifecycle.
- A GlobalKey on the form could conceal the defect in one caller while leaving
  the popup controller and focus scope subject to replacement.
- Removing the source action guard would permit duplicate operations; suppressing
  all progress would hide actual work. Neither is needed to stop a covered ticker.

## Consequences

The new regression changes dismissal in both directions and checks actual body
State identity, unsaved input, focus, geometry, Escape behavior and final disposal.
Both cases failed on the previous shell because the body disappeared on the first
frame. The first fix exposed a separate 10-pixel form shift caused by the close
control disappearing; preserving its slot closes that gap. The final shell and
source-management group passed all 65 tests. Native validation is recorded in the
root plan; these widget results alone are not native acceptance.

The real Settings-to-Sources import and JS editor tests also require animations
to settle within two seconds while the modal is open. Reloading JS still retains
busy controls and progress while the page itself is visible.
