# Agent Note: Windows WebView plugin shutdown

Status: implemented

Applies to desktop_webview_window 0.4.0 and flutter_inappwebview_windows 0.6.0
from 2026-11-07.

Independent: these native teardown fixes do not change the
application's navigation or account flows.

Related: [native dependency producers](2026-11-14-windows-native-dependency-producers.md)
keeps the same plugins and teardown sources in non-Visual-Studio build graphs.

## Problem

The desktop WebView plugin unregisters a method handler after the engine
messenger is invalidated. InAppWebView holds composition resources in process
statics, releasing them during DLL detach after their owning thread teardown.
Both paths can crash an otherwise normally closing window.

## Decision

Version-sensitive CMake overlays compile private source copies inside the build
directory. Source anchors and target source membership are mandatory; changes
upstream fail configuration and require review. The shared package cache stays
unchanged.

The desktop plugin retains its lifetime guard and owned-window cleanup but
omits messenger unregistration in its destructor. The InAppWebView manager
counts live instances and releases compositor, graphics context, dispatcher
controller and RoHelper after view cleanup in the last manager destructor.
Constructor setup remains available for a later manager instance.

## Alternatives considered

Forced process exit hides teardown crashes. Patching the shared package cache
makes builds machine-dependent and affects unrelated projects. Ignoring source
anchor changes risks applying the compatibility fix to an incompatible version.

## Consequences

The overlays require re-review when either plugin changes. Source configuration
and compilation do not establish ordinary-window close, actual WebView navigation
or tray-quit acceptance. Current production-package runtime verification remains
separate from historical instrumented native runs.
