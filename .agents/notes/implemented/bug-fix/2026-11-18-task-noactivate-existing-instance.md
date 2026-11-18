# Agent Note: Task nonactivation at the existing-instance boundary

Status: implemented

Independent: This extends the task startup boundary to an existing mutex; PiP
recovery has a separate window-state contract.
Related: [nonactivating window show](2026-11-16-task-noactivate-window-show.md).

## Problem

The window-show path honors the task nonactivation flag, but the existing-mutex
branch can enumerate windows, query their processes and restore/activate an
existing instance before that show path executes.

## Decision

After closing the already-existing mutex handle and before activation, read
`SOURIN_TASK_NO_ACTIVATE`. When its first character is1, exit successfully.
Query the required buffer size and validate the second read before inspecting
the character. Ordinary launches retain activation and retry behavior. Keep
mutex creation and the existing five probe markers unchanged.

## Alternatives considered

- Bypass the mutex for this flag: permits a duplicate default-profile writer.
- Guard only window showing: leaves existing-instance activation reachable.
- Disable ordinary activation: changes normal icon-click behavior.

## Consequences

Task launches encountering an existing mutex exit before window enumeration,
process inspection or activation. New task windows retain the separate show
policy. Revisit if the flag or single-instance policy changes.

## Verification

A restricted interpretation of the exact source block with in-memory API stubs
tests18 scenarios and198 assertions. The original source fails three task-flag
cases; the changed source passes all scenarios, including ordinary retries,
probe bypass, new mutexes, handle closure and long flag values. This is source
control-flow verification, not compiled C++ or actual native-window execution.

The earlier owned compiler attempt produced an object but failed descendant
drain and required cleanup; its failed lifecycle remains retained. Missing
failure census prevents identifying that descendant. No compiler retry based
on a guessed descendant, real user window operation or historical cause claim
follows. Fresh native build and owning-input Release acceptance remain open.
