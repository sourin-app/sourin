# Agent Note: Source address submission retains input semantics

Status: implemented

Applies: 2026-11-16, SourceAddressDialog and pinned Miuix TextField 1.3.0.

Related: [dialog content lifetime](2026-11-09-dialog-submission-preserves-content.md)
retains popup and draft ownership. [Miuix framework controls](../feature/2026-11-08-miuix-controls-and-framework-bridge.md)
retains input, focus and disabled behavior. Both overlap and remain active;
the keyword audit finds no earlier decision governing this redundant input
semantic parent. Source search generation concerns requests, not input ancestry.

## Problem

The padded Miuix focus gesture and its inner TextField both contribute tap
semantics. Disabling the field removes the outer semantic node and reparents
the surviving editor. Real Windows address saves report nested AXTree removal
errors at that input subtree. Invalid fallback counts also pass through generic
exception wording, so the visible message omits the actionable eight-address limit.

## Decision

Exclude only the redundant outer focus gesture from semantics. The actual inner
TextField owns its editable role, value, focus and editing actions, while pointer
taps on the surrounding padding retain the original focus callback. Pin and
reverse/replay the third vendor patch; preserve all seven shaders and earlier
shader/loader patches.

Validate the deduplicated fallback count before entering pending state and show
the fixed limit message. A pending save rejects reentry. Keep the dialog close
control mounted and use closeEnabled to suspend dismissal during persistence.
The stored draft and ordering remain unchanged on validation failure.

## Alternatives considered

An external Semantics container can still merge or reparent the editor when the
inner gesture becomes disabled; an explicit child setting still leaves that
redundant gesture node. Excluding the whole input would remove accessibility.
Waiting for more frames or suppressing native error logs would conceal the fault.

## Consequences

The original enable/disable regression changes the surviving editor's parent;
the corrected input preserves its node and parent, enabled state and draft.
The address-count regression fails on generic wording and retains its draft
for a valid retry. The final current-source input/dialog/source/FFI/tray group
passes 40 tests, including accessible focus and editing actions. Vendor
verification replays three patches, preserves seven shaders, and rejects three
altered source/patch/metadata controls.

Native address runs retain their full receipts. Zero AXTree errors do not accept
shutdown: separate runs uncover a callback-address access violation on exit,
handled by [native callback detachment](2026-11-16-native-callback-detach-before-exit.md).
With both fixes, three distinct owned native processes reject nine backups,
save two deduplicated fallback addresses, read the disabled state and edited
origin on a cold restart, restore through original Save/Switch callbacks, and
confirm enabled/default origin on a third cold start. All exit zero with
natural Job drain for at least eight seconds and zero AXTree/UI errors.
`SOURCE_ADDRESS_CALLBACK_CLOSE_ACCEPTED_V1.json` rehashes 59 runtime files,
3592 frontend inputs, 266 Rust inputs and 10 screenshots, and rejects seven
altered controls. Compiled versus main sources differ only in enumerated CRLF/LF
bytes and the exact task-only nonactivation branch. This accepts the diagnostic
cohort, not ordinary Release or performance; the changed final bundle requires
revalidation. Reconsider this patch if upstream unifies focus semantics.
