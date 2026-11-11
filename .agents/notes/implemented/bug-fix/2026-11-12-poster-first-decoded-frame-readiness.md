# Agent Note: Poster readiness follows its first decoded image frame

Status: implemented

## Problem

A new network cover can enter `Image.loadingBuilder` with null chunk progress before any image frame exists. PosterCard interprets that event as successful image loading and retires its neutral movie placeholder while the response is still held. The same interpretation can affect a replacement cover in a reused card State.

## Decision

PosterCard confirms readiness from `frameBuilder`: an actual non-null image frame or a synchronously decoded cache hit. `loadingBuilder` keeps its existing child/progress behavior but does not treat null chunk progress as decoded artwork.

The readiness update remains deferred until after the frame. It captures the cover and its revision from the corresponding build, then checks mounted ownership, current cover/revision, existing readiness and error state before setting `_loaded`. A cover change advances the revision and retains the existing state reset and retry-budget reset. The guard rejects an older queued readiness callback even if a later cover value returns to the same URL.

The shared cover image provider, request headers, timeouts, decode sizing, URL handling, error path, two/four-second retry schedule, cache behavior and first-frame fade remain. No source refresh, persistence, account, remote request or image-cache system is added.

## Alternatives considered

- Continue using null loading progress: requires no component change, but the same event occurs before decoded pixels and cannot distinguish the held response from a completed image.
- Preload each cover separately: could establish a decoded image before mounting the card, but adds another request/cache ownership path and delays the existing component flow. The framework already provides frame and synchronous-cache information at the current image boundary.
- Set readiness directly during image building: could remove the icon immediately, but changes State while widgets are building. A guarded post-frame update preserves the existing scheduling boundary and ties completion to the current cover.

## Relations

- Partial overlap, retained: [library cover lifecycle](2026-11-08-library-cover-lifecycle.md) owns durable/display metadata, the shared cover loader and the card's bounded two/four-second retries. This note adds the card's decoded-readiness criterion and preserves those request, timeout, retry and persistence decisions.
- Partial overlap in the problem, retained: [cold snapshot cover lifetime](2026-11-11-cold-snapshot-cover-lifetime.md) already distinguishes a loaded widget flag from actual image decoding, but owns native durable/display projection across runtimes. The first-frame card correction does not replace that wire or startup contract.
- Independent, retained: [inline cover request headers](2026-11-10-inline-cover-request-headers.md) owns registered per-image URL/header interpretation. Readiness does not change the URL, provider headers, proxy registration or media transport.
- Independent, retained: [home card and motion boundaries](2026-11-08-home-card-and-motion-boundaries.md) owns card geometry/surfaces and page transitions. This component change preserves card geometry and the existing image fade.

No referenced decision is fully absorbed, superseded or archived. This relation review is limited to the relevant existing owners; it is not an audit of every cover note.

## Verification

At qualification source HEAD `5043654e7113337a9f27fb97d398c5e8d70d4061`, the v3 baseline runs all four exact cases with two intended failures and two passing controls, without skips. Both held-response cases reach the missing-placeholder assertion (`Found 0 widgets`) after the preceding real undecoded-image check. The decode/cache and HTTP-503 same-URL retry controls pass. The baseline uses owning PosterCard SHA256 `C18C2AEDAD013D9D3A9A7E638B7FF373F2FFA37C40D384EFB9CC2F39329A88ED`.

The same frozen four-case file passes 4/4 on the candidate, without failures or skips. The owning candidate `lib/ui/widgets/poster_card.dart` is SHA256 `25B3E954795D7A7D5945406D4B327254B324E4096A75FAC82F548869BF7ABA8C`; the paired test payload is SHA256 `FFF63E7B5EE9ED5EE4F6728F5A911960B8772639C82EFE04AD7C3D4BDD1261A0`. The actual shared `lib/ui/widgets/cover_image.dart` helper is identical in both qualification inputs (SHA256 `804502FF9B869A315DAD358B9FD89328426B3AAC112F07F17D267259ACEEDBC8`), retaining its request, header, decode and timeout behavior.

Both runs bind ordinary qualification sources, metadata, dependencies and tools before and after execution. Both have Job0 after exit and before cleanup, with continuous monitored zero intervals of 8.029 seconds for baseline and 8.032 seconds for candidate, no forced cleanup and no cleanup errors. No native app or desktop input is involved. Repository-local receipts are `.probe/parallel-next-20261111/ui-performance/poster-first-frame-v3/runs/baseline-b1/result.json` (SHA256 `6F4BC20D50316DDEF0C4796643FA1E85E8E3EC31185192AD50F6DBEDBEFC6694`) and the sibling `candidate-b1/result.json` (SHA256 `676F4B40C3B00AD7FE327F5ADE78601F1F611EB40F0AADF899D2FDB360727691`). Their raw `dart.log` hashes are `E07C167C52B938C869D03682610EE739034114FE3C9DB06C0A261209825828CC` and `EE5DB8F26B48B607EBDE1CA28FCE8B3BE662D15EC017EC7DA9E5878D80DC0C95`.

The prior v2 baseline fails to compile because the fixture omits the owning `AppThemeHost` import; it runs no qualified behavioral cases. That failed result is retained separately at `.probe/parallel-next-20261111/ui-performance/poster-first-frame-v2/runs/baseline-b1/result.json` (SHA256 `2FBC9252A0E6A607B6F4043F23184B91430EB0102B193A7227B6404ED1353234`), and is not counted as product RED. V3 adds the missing fixture import without changing the production candidate or any of the four assertions.

The five unchanged existing files (`task37_poster_placeholder_test.dart`, `poster_cover_retry_test.dart`, `t50a_poster_press_test.dart`, `t50c_poster_hover_test.dart`, and `t61_progress_title_test.dart`) complete all 51 cases in both actual baseline and candidate runs. Each records 48 passing cases, the same three failing cases, zero skips, and actual process exit 1. The failures are the task37 static placeholder-color check (pointing to `lib/ui/follow_page.dart`), the press C2 no-onTap zero-layer check (which cannot find its expected InkWell), and the press D1 older constructor-parameter constraint. This candidate introduces no additional failure in these selected files. The three existing tests remain unchanged in this correction; these compatibility results are not 51/51 GREEN.

The comparison uses the new actual baseline receipt `.probe/parallel-next-20261111/ui-performance/poster-related-controls-v2/runs/baseline-b1/result.json` (SHA256 `934AD4CC90AB97CCFEB37FA47445D0BD2EB730095598511B28A6E378607FD94C`) and the previously completed actual candidate receipt `.probe/parallel-next-20261111/ui-performance/poster-related-controls-v1/runs/b1/result.json` (SHA256 `098B3CE4E24859ED1E0C8ED7DE63CCEEFEBA11DB63E307E62D1B6DF06452143F`). Their raw logs have SHA256 `7078E414B163119714BBDF4D6102C596240B36CA1843BBC2A47F8B665B917395` and `224C98B7FD23333632C26112FAEF2C2A99DF131A9367E34D39EF7DD674B5749F`. The candidate runtime is reused under root authorization after checking its exact source, dependency, metadata, tool, argument, raw-log and Job receipts against the paired inputs. Both naturally drain with zero active owned processes for at least eight seconds, no forced cleanup, no cleanup errors and unchanged bound inputs. The original candidate runner's `passed=false` and overbroad parser failure are retained; the completed 51-case run is not rewritten as a passing test suite. The 21-check actual comparison is `.probe/parallel-next-20261111/ui-performance/poster-related-controls-v2/ACTUAL_PAIRED_REUSE_REVIEW.json` (SHA256 `63021C93AA23AE9E377EDD8994394D0E2E8B7C5014ED4D3A1EBAF37305510ADF`), with `controlsAllGreen=false` and `noNewCandidateControlFailures=true`.

Scoped static analysis separately checks only `lib/ui/widgets/poster_card.dart` and the identical fixed `test/poster_first_frame_placeholder_test.dart` in both qualification trees. All four actual analyzer commands exit 0; the baseline has zero errors, warnings and INFO diagnostics, and the candidate has zero errors, zero warnings and one new INFO lint: `CURLY_BRACES_IN_FLOW_CONTROL_STRUCTURES` at the guarded `_imageLoaded` early return (line 198, column 31). The qualified candidate bytes retain that INFO; this result establishes zero errors and no new warnings within the explicit two-file scope, not a diagnostic-free or library-wide analysis. Every analyzer command naturally drains to Job0 for more than eight seconds, with no forced cleanup or cleanup errors, and its bound qualification inputs remain unchanged. The actual result is `.probe/parallel-next-20261111/ui-performance/poster-scoped-analyze-v2/runs/b1/result.json` (SHA256 `86FF8084060197338D27FBBD6A9CEB17470FE6B4B93D040C34FF4708002BF791`); its 25-check actual receipt/raw-diagnostic review is `.probe/parallel-next-20261111/ui-performance/poster-scoped-analyze-v2/ACTUAL_SCOPED_ANALYZE_REVIEW.json` (SHA256 `382947B6E78E36195E1433D9C241C04E5C43D51EC174C6DFC98AEC50E1B7999C`). The candidate PosterCard analyzer log is SHA256 `22F2D4BB5E1D4B8BEB73437FAF9044D104D41FA51EE8E545F9DC20103CD959DF`; the other three logs are empty (SHA256 `E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855`).

The fixed four-case file mounts the owning production PosterCard and serves a real 32 by 48 PNG from one bound IPv4 loopback server. Its connection factory rejects every nonfixture destination and proxy. The image provider, loading state, decoded frame and production card are not substituted.

The cases cover an initially held response; successful decode and synchronous cache reuse; replacing the URL while retaining the same real card State and holding the replacement; and the existing same-URL retry after HTTP 503. Held cases observe the actual request before inspecting the placeholder and require a real RenderImage after releasing the response. The replacement case establishes State reuse and readiness reset; it does not independently force an old queued readiness callback across a cover revision. The cover/revision guard is therefore also reviewed in the owning candidate source.

## Consequences

An unresolved network image retains the neutral placeholder until its first decoded frame. Real decoded and cached artwork still retire it, while a changed cover cannot inherit the previous cover's loaded state. Error retries remain the existing bounded behavior.

These checks establish the selected mounted-widget behavior with real loopback HTTP/image decoding. They do not establish native Windows pixel acceptance, faster scrolling, source/CDN availability, the whole cover lifecycle, cloud-account behavior or ordinary application graceful quit. Fixture HTTP closure and an owned runner's Job0 gate describe the isolated test processes.


Related retained decision: [failure callback revision ownership](2026-11-12-poster-failure-callback-revision.md). The failure-callback revision decision extends current-cover ownership to queued failures and retry timers; this readiness criterion and its qualified evidence remain unchanged.
