# Agent Note: Stacked media detail retains space for reachable episodes

Status: implemented

Applies: 2026-11-16 header sizing and 2026-11-17 pending-source layout.

This supplements the [CSP source and selected episode decision](2026-11-16-csp-source-lines-and-selected-episodes.md), including its retained public UI failure. The [right detail line filter](2026-10-30-right-detail-line-filter-and-badge.md) continues to own episode filtering and badges. The [actual Miuix detail contracts](../testing/2026-11-08-miuix-detail-action-contracts.md) retain their theme, action and semantic boundaries.

## Problem

The owned public 860x904 window stacks MediaPage's player above its DetailPage. The normal title bar leaves a 475.2px detail allocation, but the panel is wide enough to select the 212px poster recipe. Its fixed header consumes 481px before the episode title and trailing space. A Flexible episode area cannot shrink an oversized fixed header. The retained screenshot reads BOTTOM OVERFLOWED BY71 PIXELS; the previous711 reading is corrected separately without changing the original receipt.

## Decision

DetailPage accepts an optional compactHeader flag, default false. MediaPage passes the inverse of its existing wide layout decision. In the header's wide row, that flag reuses the existing138px poster width; the default remains212px. The row, information, source choices, fixed outer header and episode-only scroll area retain their behavior. No second viewport breakpoint or estimated vertical budget is introduced.

During a source refresh, the placeholder list also receives the Column's
remaining height through Flexible. A noninteractive scroll viewport clips its
placeholder rows to that space. The fixed header stays outside this viewport;
the loaded episode list keeps its independent scroll behavior. An immediate
mock response cannot validate this path, so the layout fixture holds the
original get_episodes request pending across multiple rendered frames.

## Alternatives considered

- Scroll the entire panel: this would hide the fixed title and source choices and contradict the existing episode-only scrolling contract.
- Shrink the episode viewport alone: Flexible already does that; it cannot reclaim the fixed header's excess height.
- Recalculate a second width breakpoint inside DetailPage: its full width does not describe the parent's vertical allocation. The parent already knows whether the player and detail are stacked.

## Consequences

Stacked media uses a smaller poster while the standalone/default wide detail retains212x318px geometry and24px gap to information. The narrow width recipes are unchanged. This component fix does not qualify ordinary startup, native playback, full artwork, performance, a latest integrated package or whole UI acceptance. Placeholder rows can be clipped while loading; they carry no actions or source data.

This also supports [player source synchronization](2026-11-17-detail-follows-player-source.md),
whose real refresh exposed the previously unbounded loading placeholder. The
2026-11-17 public UI retained a transient 40px overflow while episodesLoading
was true. The pending synthetic receiver reproduces 50px in the stacked window
and passes the wide control before the fix; those measurements describe their
respective content. The fixed four-file layout and synchronization suite passes
63 cases. A fresh native UI run remains required for integrated acceptance.

## Verification

Retained evidence is under `.probe/goal-resume-20261115-evening/`. The original public screenshot correction is `CURRENT_YUNDUO_DETAIL_OVERFLOW_SCOPE_CORRECTION_V2.json`. A synthetic receiver mounts the real MediaPage and DetailPage under the product AppThemeHost, retaining normal title padding and suppressing native opening. The frozen original `stacked-detail-baseline-v3` fails its actual RenderFlex assertion at860x904 by81px and passes the1440x900 control. This fixture's content differs from the public screenshot;81px is not substituted for the original71px finding.

`stacked-detail-candidate-v1` runs byte-identical test input and changes only the two product Dart files. Both cases pass: the stacked player/detail geometry is388.8/475.2px, all four source choices remain, the second episode is actually hit-testable and inside the panel, and its original callback forwards the exact episode/source without moving the fixed title. The header measures376px. The primary baseline and candidate retain their source snapshots, exit1/0 respectively, stable empty Jobs for at least8seconds, and no forced cleanup/errors.

The old t61 whitespace literal is replaced with a whitespace-independent same-SizedBox/key/height check. Its old width212 expression check becomes an actual standalone1100x900 DetailPage assertion: poster212x318, title beside it with24px gap and no Flutter exception. The first compatibility run retains74passes and two obsolete-source-shape failures. After fixture migration, final comment/import corrections are bound by `stacked-detail-final-compat-v4`: seven actual selected test sources plus product/config/native fixture inputs are frozen, all76cases pass with zero skipped, and inputs remain unchanged. `stacked-detail-analyze-v2` exits0 with zero errors/warnings and one inherited brace-style info. Both jobs drain naturally for at least8seconds without force or cleanup errors.

`UI_STACKED_DETAIL_HEIGHT_ACCEPTED_V1.json` rehashes all retained snapshots, checks the byte-identical primary test comparison and final current inputs, and rejects forced-cleanup/nonzero-final-exit controls. It accepts only the scoped component layout. Earlier missing-theme-import, incomplete-theme, literal-guard and analyzer raw-image-query/forced-cleanup failures remain separate failed receipts.
