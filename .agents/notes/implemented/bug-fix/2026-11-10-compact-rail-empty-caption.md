# Agent Note: Compact saved rails reserve only captions they display

Status: implemented

Applies from 2026-11-10 to the compact MyShelf rail and CompactShelfCard.

This implements the narrow boundary recorded by the earlier
[regression checkpoint](../../proposed/bug-fix/2026-11-10-compact-rail-regression-checkpoint.md).
That proposed note preserves the pending state at the user's commit request;
its historical evidence is unchanged. [Compact homepage layout](../feature/2026-11-08-compact-home-and-motion-preview.md)
and [card and motion boundaries](2026-11-08-home-card-and-motion-boundaries.md)
retain their poster, title, input and navigation contracts. This extends caption
reservation only; it does not supersede their layout or motion decisions.

## Problem

CompactShelfCard always included a gap and second caption row in both its height
and rendered layout. Following entries whose release state already appeared on
the cover passed no subtitle, but still reserved the empty row. Actual HomePage
geometry measured 29 pixels below the title at text scale 1 and 38 at scale 1.6,
where only the existing eight-pixel bottom padding was needed.

## Decision

Project compact subtitles once using the existing rule: a following entry with
cover release status has no caption; otherwise keep its current subtitle. The
active rail reserves a shared subtitle row only if at least one projected
subtitle is nonempty. Every card and the rail's height calculation receive that
same reservation. An entirely empty row loses only its gap and text height;
mixed rows retain equal card heights and genuine captions.

The optional reservation defaults to true for existing height and constructor
callers. A real subtitle still renders if a caller passes false; the sizing
contract requires reserving its height whenever text exists. Production MyShelf
uses the common projected values to keep both decisions consistent. Loading
retains its existing reservation while data is unknown; empty-state UI is
unchanged.

Keep the header above the rail, 132-pixel card, 116-by-174 poster, single-line
title, cover status, viewing progress, scroll structure and actions. Source and
bottom navigation layout are unchanged. Caption space follows text scaling;
poster geometry does not shrink with it.

## Alternatives considered

Moving controls beside posters changes the approved composition without proving
it improves the homepage. Shrinking covers removes useful image area. Removing
every subtitle hides history episode text and favorite type labels. Sizing each
mixed card independently breaks rail alignment. Only the empty shared caption
space is removed.

## Consequences

The real HomePage fixture checks desktop and touch widths at text scales 1 and
1.6 using rendered poster, title and card bounds. It requires the necessary
eight-pixel bottom padding while retaining header position, source adjacency,
cover badges, single-line titles, detail actions, tabs and see-all targets.
Mixed captions and history/favorite text are positive controls.

Root's qualified RED records four empty-caption failures and two passing
controls. New and existing tests remain byte-for-byte unchanged for production
GREEN; the existing subtitle/progress, status, scroll preservation and card
action regressions remain required. Toolchain results and populated native
screenshots are separate root-owned checks. This narrow correction does not
establish complete homepage aesthetic, startup or navigation performance acceptance.

## Verification

The frozen six-case suite and five existing related suites passed together: 39/39,
with Flutter concurrency=1 and isolated test data. This includes shelf captions,
preload races, tabs, detail navigation, scroll position and text scaling.
Afterward the only test edit moved const from the section list to its enclosing
ProviderGroup to satisfy analysis; values and all behavior assertions stayed
unchanged. The six cases passed again and targeted analysis reported no issues.
The original RED/GREEN test SHA256 was a0a6ecb953cc568e8d817375d34b025646844903eb26cc522374ab999759b623;
the final const-only test SHA256 is ff43df9a8357a140c695e0f1fd5b0e280b3bc2a4a5540b5afdeeaeefdff9e39c.
Native visual verification remains separate from these widget results.
