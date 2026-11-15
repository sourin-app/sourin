# Agent Note: Task-only nonactivating Windows window show

Status: implemented

Independent: this is a Windows runner test-isolation boundary; existing JS ownership, Home crash, and playback notes cover different product decisions.

## Problem

The isolated owner runner must show a task-owned window without activating it, but the normal Windows runner path uses the ordinary show command. Relaxing the observer would hide a real focus/interference failure.

## Decision

Add an environment-gated branch in Win32Window::Show: only when SOURIN_TASK_NO_ACTIVATE=1 is present, call SW_SHOWNOACTIVATE; all normal launches retain SW_SHOWNORMAL. The gate is task-only and does not read user configuration or alter production defaults.

## Alternatives considered

- Relax the owner observer: rejected because it would turn a real activation/style mismatch into false green.
- Change the default runner behavior: rejected because ordinary product startup semantics and user window interaction must remain unchanged.
- Inject focus or OS input: prohibited by the task constraints.

## Consequences

The patch requires a fresh native/Release build before runtime acceptance. The attempted clean current build remains blocked by the existing InAppWebView NuGet command failure (exit 9009), so no runtime or ordinary-startup claim is made from this patch. Remote push and release are not performed.
