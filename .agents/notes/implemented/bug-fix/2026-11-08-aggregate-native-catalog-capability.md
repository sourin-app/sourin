# Agent Note: Keep registered native catalogs selectable in aggregate management

Status: implemented

Applies: 2026-11-08, Rust aggregate capability responses consumed by the child-source management dialog.

Related: [Proxy-required discovery and manual installation](../feature/2026-11-08-proxy-github-source-discovery.md) owns validation, explicit enable and provenance. [Discovery coverage](2026-11-08-github-discovery-coverage.md) owns candidate sampling and mirror identity. This follow-up corrects the capability reported after a native candidate has actually been installed. It preserves both contracts and the [separate child-source management dialog](../feature/2026-10-29-aggregate-edit-split-and-note.md). A keyword audit across proposed, implemented and rejected notes also found the proposed CSP registry decoupling and existing unsupported-class test guidance; this fix does not change CSP registration and uses a synthetic unsupported class.

## Problem

The native discovery v2 run successfully installed a synthetic HTTP AppleCMS source after the real enable action. The source existed in the registry, was enabled, and belonged to the enabled aggregate set. Navigation reached its actual child-source card, where the name and GitHub origin matched, but its checkbox was unchecked and disabled.

`tvbox_aggregate::build_response` computed `implemented` solely through `csp::route(api)`. That router accepts CSP class identifiers, so an HTTP catalog was always reported as unimplemented. The dialog correctly requires both `implemented` and `enabled`; changing its assertion or selection rule would hide the backend mismatch.

## Decision

For the registered TVBox providers returned by `tvbox_sites`, an HTTP(S) API indicates the existing native AppleCMS implementation. Other entries retain the existing CSP implementation lookup. The HTTP predicate is the same one used by the native AppleCMS provider constructor.

The existing registration boundary remains essential: unsupported script configurations are rejected by source collection and cannot become selectable merely because their script URL starts with HTTP. Metadata without a corresponding registered TVBox provider remains absent. An unknown CSP class still reports `implemented=false` with its existing reason.

Capability and selection remain separate. A supported source can still have `enabled=false` after the user deselects it. This change does not alter installation, proxy transport, persistence ordering, GitHub attribution, source visibility or aggregate request scope.

## Alternatives considered

- Accept an unchecked native source card in the driver: conceals the product error and leaves users unable to select a source already in use.
- Mark every aggregate row implemented: incorrectly enables unsupported CSP rows.
- Treat arbitrary HTTP configuration entries as supported before registration: would bypass the existing rejection of script-only sources.
- Change the Flutter dialog to ignore capability: makes unavailable sources appear actionable instead of correcting the response.

## Consequences

The regression `aggregate_response_marks_registered_applecms_implemented` exercises source collection, real HTTP/HTTPS AppleCMS and supported CSP provider builders, registration, sidecar records and aggregate get/set responses. It covers unsupported CSP and script rejection, a stale unsupported CSP registry row, metadata-only script exclusion, and deselection remaining false after a response round trip. It makes no upstream catalog request and uses a new isolated profile with remote autostart and scheduled updates disabled.

Root executed and this lane read the following logs:

- [Focused regression](../../../../.probe/parallel-astra-1108/aggregate-applecms-regression-v1.log): 1 passed.
- [Aggregate regression v3](../../../../.probe/parallel-astra-1108/aggregate-regressions-v3.log): 27 passed, 0 failed, 1 ignored. The existing live-network CSP test remained ignored. The separate Owner-data fixture test `r2b_realdata_shape_fans_out_nothing` was explicitly filtered out.
- [Discovery regression v2](../../../../.probe/parallel-astra-1108/discovery-regressions-v2.log): 15 passed, 0 failed.

The preceding [aggregate v2 run](../../../../.probe/parallel-astra-1108/aggregate-regressions-v2.log) had 27 passed, 1 failed and 1 ignored: the Owner-data fixture test failed because its required copied fixture was absent from the isolated temporary root. Its assertion was not weakened and no Owner profile was accessed to manufacture that fixture. The v3 result therefore covers the runnable isolated suite, not the excluded real-data case.

The [native v2 review](../../../../.probe/source-astra-1108/NATIVE_V2_REVIEW.md) records the observed failure and repair. The [native v3 review](../../../../.probe/source-astra-1108/NATIVE_V3_REVIEW.md) records a passing rerun using the freshly built core `1CC4B1427A60A3B773BC3DBF16E432CEF8E915F4FC18C5B04FE4BE14FC6E333E`: the actual aggregate site is implemented and enabled, the real checkbox is selected and enabled, and the exact GitHub attribution matches. The strict proxy requests occur between the enable action and observed installation; the run exits with code 0 and no forced cleanup or recorded Flutter/AX errors.

All four v3 images were inspected. The first three show the notice and candidate's change from `启用` to `已加入源页面`. The source-management image showed the exact attribution but clipped the target name and most of its checked control above the viewport. A capture-only driver adjustment centers the whole card and checks its rectangle against the visible scroll viewport and route/view bounds without relaxing the selected-card assertion.

The [native v4 independent review](../../../../.probe/source-astra-1108/NATIVE_V4_REVIEW.md) closes that visual gap. Its four images were inspected; the actual management card now fully shows the blue checked control, `Synthetic GitHub catalog`, `来自 GitHub · fixture/public-config` and `appleCms` together. The card rectangle `[464, 428, 976, 498]` lies fully within the scroll viewport `[464, 253, 976, 673]`. The same fresh core remains bound to the run, the exact proxy sequence and durable provider identity pass, and the process exits with code 0 without forced cleanup or recorded Flutter/AX/fixture errors. This closes the seeded manual-install-to-real-management-card chain; live GitHub discovery in this run, restart, real upstream playback and Owner acceptance remain separate.
