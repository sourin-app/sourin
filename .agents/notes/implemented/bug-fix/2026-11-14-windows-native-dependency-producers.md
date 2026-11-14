# Agent Note: Windows native dependency producers

Status: implemented

Applies from 2026-11-14 to the Windows Flutter backend and
flutter_inappwebview_windows 0.6.0.

Relations: extends the [runtime build inventory](2026-11-08-windows-package-runtime-inventory.md)
and complements the [WebView teardown overlays](2026-11-07-windows-webview-native-shutdown.md).
The inventory and teardown decisions remain separate and continue to apply.

## Problem

The Flutter backend produces its DLL import library, but the CMake command
declares only the DLL, headers and wrapper sources. A fresh Ninja graph rejects
the import-library input before running that backend.

InAppWebView relies on three NuGet MSBuild imports for include directories and
its WebView loader. A non-Visual-Studio generator treats those XML files as
link inputs. The existing ALL download target neither declares its loader
outputs nor orders the plugin compiler after package preparation.

The shared warning option embeds quotes in an unquoted CMake argument. Ninja
preserves those quotes in the compiler argument, so clang-cl rejects the warning
number before compiling the Flutter wrapper.

## Decision

The existing Flutter backend command declares its real DLL import library as a
byproduct. The backend continues to select and copy its own engine artifacts.

An application CMake helper leaves Visual Studio imports intact and gives other
generators the native include directories and ordinary Win32 Dynamic WebView
loader inputs. It checks the three locked package versions and exact import-list
membership, selects the target architecture, retains the existing NuGet download
commands and orders the plugin after a checked loader-output bridge. The bridge
fails on missing files and does not create or substitute libraries. The DLL is
included in the application install inventory.

The shared compiler settings spell the existing suppression as `/wd4100`, a
single argument without embedded quotes. `/W4`, `/WX` and the suppressed warning
number remain unchanged for both Visual Studio and Ninja generators.

No shared SDK or dependency-cache source is patched. The renderer, plugin source
membership, warning policy, texture support and teardown overlays keep their
existing contracts.

## Alternatives considered

Copying an older import library hides its missing producer and does not establish
a fresh frontend build. Removing a plugin or using its video fallback changes
the product graph. Importing MSBuild XML as native libraries cannot supply its
include or loader rules. Selecting the Static WebView loader would change this
plugin's documented default. Cross-directory POST_BUILD commands are invalid in
the supported CMake version; the application install graph owns the runtime copy.

## Consequences

Package-version or import-list changes require review. The non-Visual-Studio
architecture branch recognizes x64 and ARM64, while actual compilation and
runtime evidence must identify the architecture it exercised.

The first fresh unmodified Ninja build rejects the missing Flutter import-library
rule. Its source inputs and normal compiler drain are preserved. Configuration,
source review and local commits do not establish a successful complete native
build, ordinary startup, playback, UI, performance or complete-goal acceptance;
those remain distinct validation gates.
