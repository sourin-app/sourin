# Agent Note: Catalog metadata belongs to a complete card

Status: implemented

Applies from 2026-11-10 to the PanWebShare list, home and search parser.

Related: [relative catalog covers](2026-11-09-relative-catalog-covers.md) owns
image attributes and response bases; [library cover lifecycle](2026-11-08-library-cover-lifecycle.md)
owns persistence and recovery. The note audit found no existing decision owning
card status extraction. Those decisions remain in force.

## Problem

Splitting HTML on the text `module-item` splits child classes and accepts
advertisement names. Status lives after the picture/title children, while list
and search discarded it by constructing every subtitle as None. The UI cannot
show episode/completion badges when source metadata never reaches it.

## Decision

Use complete class tokens and closing element boundaries for the known card
template. Skip comments, raw-text elements and similarly named attributes.
A new matching card invalidates an unclosed predecessor to avoid borrowing its
neighbour's fields. Extract and clean `module-item-text` within that card and
forward it through the existing subtitle mapping. Preserve quality strings
without guessing a completion status. The existing UI classifies release
metadata separately from ratings and viewing progress.

List and search share extraction, preserving search action-prefix stripping, ID
deduplication and the sixty-card limit. Cover decoding and the successful
response URL, global proxy and mirror fallback remain unchanged.

## Alternatives considered

Substring splitting cannot distinguish a card from its child classes. Searching
for the next status without closing boundaries borrows unrelated data. A new
HTML dependency and speculative template support add scope without evidence.

## Consequences

Synthetic regression cases cover complete and malformed boundaries, quoted and
unquoted class attributes, nested status markup, entities, missing metadata,
quality strings, duplicate IDs and the item cap. Provider import/list/search
tests check fields after mapping, not only parser helpers. Existing image and
mirror regressions must remain green.

This is a template-specific parser, not a general browser DOM implementation.
Changed upstream templates must fail honestly and require new observed fixtures.
A missing source status remains missing rather than inferred from a title.
