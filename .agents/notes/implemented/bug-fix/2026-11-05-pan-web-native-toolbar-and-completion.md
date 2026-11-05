# Agent Note: Windows pan login completion in the browser window

Status: implemented

Relations: [Dart confirmation routing](2026-11-05-pan-native-confirm-routing.md) owns cookie capture, explicit consent, save/readback and background-read coalescing. [Authentication freshness](2026-11-04-pan-web-auth-session-freshness.md) remains authoritative; this change does not reinterpret an old browser cookie as a new login.

## Problem

Owner's screenshot shows the Baidu personal file list in a native login browser, while the Flutter confirmation dialog is obscured underneath it. This proves that the visible browser is logged in, not that the application has saved or remotely validated its session. Keeping the only explicit confirmation action in the parent dialog makes the actual login workflow unresponsive.

## Decision

`windows/runner/pan_web_login_composer.cpp` uses the installed desktop_webview_window native composer API only for `sourin-pan-login-v1`. All other browser windows retain the plugin default. The plugin continues to own the top-level window and WebView; only our child toolbar, controls and DPI font are created and destroyed here. Registration follows plugin setup, and disposal precedes Flutter engine destruction in `flutter_window.cpp`.

The browser contains a visible completion button. It sends `confirm` with an integer browser ID on `sourin/pan-web-login`. The Dart receiver must explicitly reread and accept the existing session, save through the existing credential command, and require local account readback before closing. Neither navigation URLs nor page titles authorize a save. State messages contain only an ID and the fixed `waiting`, `busy`, or `error` enum; no credentials, URLs or exception payloads cross this channel.

Native double clicks are blocked during confirmation. Result recovery requires both the browser epoch and confirmation token, so an earlier reply cannot unlock a later attempt. Missing handlers, failed replies, and a 45-second native timer restore a retryable button. Timer creation failure also restores the button immediately. Partial control creation rolls back owned controls before returning the default composer. Navigation state drives back/forward availability and reload/stop behavior. DPI fonts are replaced and released; at narrow high-DPI widths navigation is hidden to preserve the complete confirmation label.

## Alternatives considered

- Keep the action only in the parent dialog: insufficient for the obscured native-window workflow in Owner's screenshot. The parent remains a non-Windows fallback.
- Automatically save any existing cookie: rejected because existing or unknown baseline sessions require explicit consent.
- Inject a page button or infer success from DOM/URL: rejected because authentication-page content does not prove a usable saved session and is not ours to modify.
- Replace or reparent the plugin-owned window/WebView: rejected by the installed SDK ownership contract. The supported composer keeps the existing lifecycle.

## Verification

The production-include fixture in `windows/runner/tests` uses actual hidden Win32 HWND controls and the installed Flutter standard method codec. Only DWW browser control dispatch, DPI input and failure points are stubbed; it reads no credentials and performs no network calls. Its standalone CMake target accepts explicit `WRAPPER` and `DWW` dependency paths and is not added to the production application build.

- `.probe/pan-native-fixture-layout-red2-20261105/summary.json`: configuration and compilation exit 0; behavior exit 1 because the completion label does not fit 320 physical pixels at 2x DPI. The earlier v143 configuration and missing engine-header failures are instrument failures, not behavior RED.
- `.probe/pan-native-fixture-green-20261105/summary.json`: 41 checks pass, all phase exits 0. Covers default browsers, partial creation rollback, 320px/2x completion geometry, view offset, navigation, duplicate confirmation, wrong ID, retry, missing handler, timer failure, timeout, closing, font cleanup and late replies after ID reuse/disposal.
- `.probe/pan-native-token-red-20261105/summary.json`: isolated production-copy mutation removes the confirmation token guard; behavior exit 1 specifically because the earlier error unlocks the second attempt. Configuration and compilation both exit 0.
- `.probe/pan-native-token-restored-green-20261105/summary.json`: restored copy has the same production hash as the root implementation and passes all 41 checks, exit 0.
- Dart's final twelve-file login/freshness/native bundle passes 113 tests with exit 0 in `.probe/dart-native-freshness-freeze-20261105.log`; its background-read confirmation gate was first behavior RED. Scope analysis reports no issues. Details remain in the companion Dart note.
- The first complete Windows build fails at the runner's production `/W4 /WX` compilation with C4456 (shadowed integer-ID local), recorded in `.probe/pan-native-login-build-evidence-20261105/summary.json`. The fixture initially lacked that warning policy. Distinct ID variable names fix the production warning, and the fixture now uses `/W4 /WX /wd4100`: `.probe/pan-native-fixture-strict-green-20261105/summary.json` passes all 41 checks with configuration/build/behavior exits 0. This compilation failure is not presented as behavior RED.
- The v2 build-launcher preflight failure is an instrument-scope omission: the newly staged native files were absent from the explicit dirty-source allowlist. The v3 launcher lists the exact seven frontend inputs and preserves the previous reports instead of rewriting them. Complete v3 package binding and actual UI acceptance are still separate requirements.
- `.probe/pan-native-login-build-evidence-v3-20261105/summary.json`: complete production Windows release build exit 0, all six phase exits 0, 262 frontend source inputs unchanged, 43 release files hashed. The mirrored CMake injects only a probe-local frozen WebView2 SDK location; the repository and installed SDK are not edited. Plugin sources and SDK files are hash-checked before/after. Existing third-party warnings remain; the repaired runner has no composer warning/error.
- Fresh package `.probe/pan-native-login-windows-release-v3-20261105`: core SHA256 `E9F6263C760F740E5FDBF3DAE5681FDCD8CD017A7E756A232EFF21B0E8DA5BFF`, executable `BD0052CC6D9D6025411389D2B2946AF7659954E2B4BAFDAE5382DA43F621F4AD`, AOT `69881F4E3DF3474EB3B665E9F49CA05CAEEA5ACA2BD950A7C70214142D9D9923`. This binds the new UI and native runner to the previously verified core instead of reusing the old frontend binary.
- Root reruns the final twelve-file login suite with a held process handle, non-null verified exit and before/after input hashes: `.probe/pan-native-login-final-dart-tests-20261105/summary.json`, 113 passed, exit 0, inputs unchanged. No credentials are read and no real window is opened by these tests.

The package is built but not launched or accepted. Owner's current PID64740 is preserved; Root asked Owner to exit the old client/browser before starting the new visible package. Actual cookie capture and returning to the account settings still require Owner's interaction and screenshot evidence. Windows Computer Use reports its native pipe unavailable; no claim of an observed current parent modal is made.

## Consequences

Native fixture success does not prove the real WebView layout, user focus, actual account capture, remote Baidu authentication or complete episode playback. Production `/W4 /WX` Windows build and Owner-visible completion remain separate acceptance requirements. Tests are hidden and below-normal priority; the running Owner package is not overwritten or terminated. An already submitted keyring write cannot be retracted by closing the dialog; existing session guards prevent subsequent success/readback after cancellation.

The Baidu full-file protocol and complete selected-episode playback remain incomplete. A personal file list, local `loggedIn` status, or limited share preview is not a substitute for that target.
