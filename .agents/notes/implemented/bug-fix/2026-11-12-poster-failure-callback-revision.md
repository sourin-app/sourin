# Agent Note: Poster failure callbacks follow the current cover revision

Status: implemented

Applies from 2026-11-12 to `lib/ui/widgets/poster_card.dart` and `test/poster_failure_aba_test.dart`.

## Problem

PosterCard defers an image failure until after the frame and checks the failed cover URL before setting its placeholder state. A retained card State can traverse A, B and A in one frame. The old A failure then sees the same URL again and can remove the new pending A image or spend its retry budget. URL equality does not identify which cover revision owns the queued callback.

An ordinary URL change across completed frames does not by itself reproduce this route: the framework removes the old stream listener, and queued post-frame work normally runs at the current frame boundary. The regression must reach a real failed image build, preserve the same State and return to A before that failure callback executes. A real decoded cached B also clears the framework ImageState's earlier exception, separating the card callback from retained framework error state.

## Decision

The image error builder passes the cover and revision captured by its build into `_imageFailed`. Both the post-frame failure and its retry timer require that revision and URL to match the currently mounted card. The existing readiness callback remains byte-for-byte unchanged. URL changes still reset image readiness, failure state and the retry budget; failed current covers retain the two-retry schedule after two and four seconds.

The regression file mounts the owning production PosterCard and uses real loopback HTTP, decoded PNG/cache behavior and public layout. A read-only listener observes the actual HTTP 503 without pumping its pending error frame. A RenderProxyBox changes LayoutBuilder constraints three times in one layout so the card updates A, cached B and pending new A while preserving its State. The test neither calls the private State/error builder nor substitutes the image provider or frame.

## Alternatives considered

- Keep the URL-only guard: small and sufficient for different final URLs, but A after B has the same value as the failed old A. It cannot separate their retry ownership.
- Set the failure state immediately while the image builds: removes the queued callback, but changes State during widget building and changes the component's existing scheduling boundary.
- Rely on removal of the old ImageStream listener: prevents later delivery from an obsolete stream, but a failure callback already queued by the current build is beyond that listener boundary.
- Add a separate cover preload/cache path: could avoid a pending image, but introduces additional request and ownership behavior. A revision check resolves the existing component boundary directly.

## Relations

- Partial overlap, retained: [first decoded-frame readiness](2026-11-12-poster-first-decoded-frame-readiness.md) owns when loaded artwork retires the placeholder and binds readiness to the cover revision. This note applies that ownership rule to deferred failure and retry callbacks; its readiness block and prior decision remain unchanged.
- Partial overlap, retained: [library cover lifecycle](2026-11-08-library-cover-lifecycle.md) owns durable/display URLs, cover request behavior and the card's bounded two/four-second retries. This note adds revision ownership for those existing card retries; it does not replace persistence, recovery, request headers, timeouts or the retry bound.
- Independent, retained: [cold snapshot cover lifetime](2026-11-11-cold-snapshot-cover-lifetime.md) owns native metadata projection across runtimes. A same-State widget failure callback adds no durable/display conversion, source refresh or account behavior.

No existing decision is fully absorbed, superseded or archived. The relation audit records the relevant existing owners and the unrelated broad keyword matches separately.

## Verification

At qualification source commit `5d43449ae08bbb2c3605e3d7a3d0c69fee75e564`, the ordinary owning baseline includes the earlier decoded-readiness correction and has PosterCard SHA256 `25B3E954795D7A7D5945406D4B327254B324E4096A75FAC82F548869BF7ABA8C`. The isolated candidate has SHA256 `B95E099AA24A780A0108E3F05651A413FA436E325D6D13C6F07C3FC493D7E02C`; the identical paired four-case payload has SHA256 `E684A5DB9D20C7D320C7A49929B5604BFDB1D87CC80FBEEA9972E80AE19FA6A5`. Only the owning production file differs between the two qualification trees.

The actual baseline completes all four named cases: the one intended target fails, three controls pass, zero cases skip and the process exits 1 (`+3 -1: Some tests failed.`). The actual target failure reason and stack at test line 256 establish that the earlier real HTTP503 observation, A/B/A URL sequence, same-State assertion and RawImage count assertion have passed. Their values are expected assertions in the frozen control flow; the raw log does not print per-value route witnesses. The target reaches its missing new-A image assertion rather than a route prerequisite failure. The candidate completes the same four named cases, exits 0 and reports `+4: All tests passed!`.

The controls retain real cached A/B decode through repeated layout, ordinary same-URL successful retry after HTTP503 and the existing two-retry production limit. Both actual runs retain complete source/metadata/dependency/tool bindings and naturally reach Job0 after exit and before cleanup, with monitored zero intervals of 8.028 and 8.031 seconds. There is no forced cleanup or cleanup error.

The completed pair receipt `.probe/parallel-next-20261111/ui-performance/poster-failure-aba-v2/ACTUAL_PAIR_RESULT.json` has SHA256 `4AF707F30ECE8B38580BFAE7A93368F8122E12D7B3B3E2D36FFFFDADEC20F4A5`. The baseline/candidate receipts have SHA256 `47B61767A9A219EB0A28389186D054A319188C57E2D22452C84C75F4AEA12209` and `4951DD17367E31EAE8DDAA9559ED5BB6EABE5ECD846A63CC916E39E70357D708`; their raw logs have SHA256 `9E60658A3B8FF1B6F1EBCC37BB39104DF0EEF217CA36F43E4D008EFFE7CE5DA8` and `1A9C749CAA454A0032BFADACB2CA95530DF2FC037633F12B62FA2D5733BA8AEA`. The 39-check actual short review has SHA256 `3B0ED82C2747958977BC99EC0580DEC0F6E085F35436838990F105811600953E` at the sibling `ACTUAL_PAIR_SHORT_REVIEW.json`.

The earlier v1 fixture fails compilation because `GlobalKey.currentWidget` has the public static type Widget and no cover getter. It executes no named target or control and is retained as setup failure. V2 changes only the fixture expression to `(key.currentWidget as PosterCard?)?.cover`; the production candidate and all business assertions remain frozen. The retained v1 setup-failure review is `.probe/parallel-next-20261111/ui-performance/poster-failure-aba-v1/ACTUAL_SETUP_FAILURE_REVIEW.json` (SHA256 `8A2B5B00F574B4767E426D6F75ECCA6A253317540E5978DD4ECE5F6C2F9C3012`).

Two candidate-only single-file commands analyze the owning PosterCard and the new four-case test with machine diagnostics. Both exit 0: the source has zero errors, zero warnings and one INFO (`CURLY_BRACES_IN_FLOW_CONTROL_STRUCTURES` at line 198); the test has zero errors, zero warnings and four INFOs (one `UNNECESSARY_IMPORT` at line 8 and three `PREFER_CONST_CONSTRUCTORS` at lines 139, 143 and 145). These five INFOs remain in the frozen source/test bytes. This is zero-error analysis of the explicit two-file scope, not a diagnostic-free or library-wide result. The earlier loaded-fix analysis is not used as same-source baseline analysis of the new test.

Each analyzer command naturally drains to Job0 and retains monitored zero for 8.029 and 8.029 seconds without forced cleanup or errors. The complete analyzer input maps remain unchanged. The actual analyzer result `.probe/parallel-next-20261111/ui-performance/poster-failure-aba-scoped-analyze-v1/runs/b1/result.json` has SHA256 `744D24EB8B5E86AF8AB4769C2D14601E7A63F363FC48C40351D54E1F15B2F900`. Its source/test logs have SHA256 `6AE40CED815C1E7549849F560CB43C06FD9569DFC91F855D307F494960791D9B` and `114C1FE2806DFBBBFB370D50AF5273343426E9090D7E4434715157E5539A1CA4`; the 22-check actual raw-diagnostic/binding review is the sibling `ACTUAL_CANDIDATE_ANALYZE_REVIEW.json` (SHA256 `AA2A7298E7A29473849BA0C1F3F4DC8416AD0B0F2B0A821C200A5D9408B9A842`).

## Consequences

A stale A failure cannot replace the pending new A image or use its retry budget after a same-State A/B/A layout. Real current-cover failures, successful decode/cache display and the existing retry limits remain the component behavior. The additional comparisons use the existing revision counter and add no request, cache or persisted state.

The checks establish this selected mounted-widget failure route with real loopback HTTP/image decoding and scoped static diagnostics. They do not establish native Windows pixels, scrolling speed, upstream/CDN availability, ordinary app graceful quit, the complete cover lifecycle or Owner acceptance. Test-process Job0 describes the isolated runners; any final full-package binding and application acceptance require their own evidence.
