# Agent Note: Provider switches keep stable semantic ownership during submission

Status: implemented

Applies: 2026-11-17, SourceProvidersDialog in source_manager_page.dart.

This extends [Miuix semantic ownership](../feature/2026-11-08-miuix-controls-and-framework-bridge.md)
and [submission preservation](2026-11-09-dialog-submission-preserves-content.md).
[Source address semantics](2026-11-16-source-address-submission-semantics.md)
addresses the same enabled-state ancestry hazard in text input, but not this
independent provider toggle. The existing provider draft/save/cancel contract
and package focus/click behavior remain required.

## Problem

The current real U5 run completes provider selection and natural exit, but its
native accessibility bridge reports 21 AXTree errors for a provider-row node.
The actual framework snapshots place the row's full label on child node287
under node286 while enabled. Save disables the row; the full label moves to
node286 and node287 disappears. The native bridge then rejects updates for287.

MiuixSwitchPreference combines a BasicComponent checkbox-state/onTap node,
another MiuixPressable tap and a child switch toggled-state/onTap node. Removing
the enabled actions permits their implicit merge shape to change. The data
identifies the affected row and transition; native closure still requires a
successor run after any candidate.

## Decision

Give each provider row one explicit application-owned Semantics container with
its existing title/summary, actual toggled value, enabled state and one tap.
Exclude only the redundant semantics beneath that boundary while retaining the
real MiuixSwitchPreference and its pointer/keyboard behavior. Share the guarded
draft-update helper between accessible activation and the original onChanged.
Keep the Miuix widget's existing key so observation and ordinary UI actions
continue to target the same mounted component. Do not disable accessibility
or change the package globally.

## Alternatives considered

Ignoring AXTree messages hides a real native failure. Adding MergeSemantics
alone retains conflicting checked/toggled states and duplicate actions. Leaving
rows enabled while saving permits draft changes after the submitted selection
was frozen. A vendor-wide patch expands scope before a caller-level fix has
been behaviorally qualified.

## Consequences

Widget identity/role/action checks can demonstrate the risky merge transition
and accessible behavior, but do not execute the Windows AXTree bridge. A new
native U5 run must retain the exact error criterion and original lifecycle.

## Verification

The three actual SourceProvidersDialog cases all fail against the clean e6dbe9a
baseline: the complete label lacks toggled state, and disabling during failed
or successful saves changes its semantic node ID. The candidate passes all
three and the four existing provider/address submission regressions, for seven
passes. Semantic activation changes the actual draft once; pending-save
activation does nothing, failed submission restores the same node and parent,
and successful route disposal removes those nodes.

The serial runs preserve original logs and inputs, exit naturally and keep
the owned Job empty for at least eight seconds without forced cleanup.
Targeted analysis has no errors or warnings; six pre-existing source-file info
diagnostics remain and none concerns the new helper or test. The exact
candidate is initially qualified in its separate worktree for coordinating
review/application. No package source changes are needed. A rebuilt native U5
successor is still required to demonstrate zero AXTree errors in the Windows
bridge; these widget results do not claim that native closure.
