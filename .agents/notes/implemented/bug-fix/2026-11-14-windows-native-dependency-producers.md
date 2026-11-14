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

For Clang, the desktop WebView target compiles a private copy of its source tree.
Two hash-pinned bundled WIL headers receive exact, count-checked transformations:
template parameters have distinct names from their preserved type aliases, and
four volatile diagnostic variables are marked `[[maybe_unused]]`. Their writes
and runtime bodies remain unchanged. All target sources and plugin-owned include
paths point into the same copy so quoted includes cannot select the old headers.
The generated shutdown correction is copied into that tree before compilation.
MSVC retains the original source selection; no warning flags are weakened.

The private desktop copy also initializes Win32 structures explicitly while
preserving their zeroed fields and tooltip V2 size, and marks its two concrete
COM accessibility providers final. The media copy retains its teardown changes,
orders constructor initializers by member declaration, removes ineffective
return qualifiers, zero-initializes structures and makes libmpv's documented
read-only string arguments explicit at its untyped input boundary.

Clang plugin copies remove redundant class qualifiers, preserve include-once
behavior with an ordinary guard, and mark concrete volume COM providers final.
Two unused window-manager declarations retain their values with maybe_unused.
Dynamic color uses the existing no-argument Success overload for a null result.
The file selector retains its own exception-enabled override as one definition;
InAppWebView retains its upstream warning policy with the corrected 4100 spelling.
The runner drops an unreferenced initialization flag. Source hashes and counted
replacements stop configuration when the pinned dependencies change; generated
content checks normalize CRLF while build receipts bind actual output bytes.

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

The eight reviewed native plugin targets compiled and linked successfully in
native-build-reviewed-plugins-v1, with unchanged prepared inputs and natural
Job drain for 8.000573 seconds. The preceding full plugins-v3 build remains a
failure: InAppWebView still needs standard coroutine and explicit value-conversion
compatibility fixes. Target compilation does not constitute install/package or
runtime acceptance.
