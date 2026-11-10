# Agent Note: Pending compact saved-rail regression checkpoint

Status: proposed

Related: [compact homepage layout](../../implemented/feature/2026-11-08-compact-home-and-motion-preview.md)
and [card and motion boundaries](../../implemented/bug-fix/2026-11-08-home-card-and-motion-boundaries.md)
continue to own the current layout. This pending regression suite does not
supersede either decision or change the approved navigation and shelf layout.

## Problem

The compact saved rail reserves a subtitle row even when its visible cards have
no subtitle. Release status already appears on the cover. Removing only the
unused row must preserve real history/favorite captions and aligned mixed rows.

## Proposal

At the user's explicit request to commit current work first, preserve six newly
prepared widget cases as a local progress checkpoint. No production widget is
changed. The tests have not been compiled or executed and do not establish a
completed layout fix.

Four cases measure the actual HomePage/MyShelf card geometry at desktop/touch
widths and text scales 1.0/1.6. Two controls preserve mixed subtitle alignment and
history/favorite captions. The suite retains the header above the rail, existing
poster dimensions, cover status, one-line title and original navigation actions.
Existing compact_home_shelf_test.dart is unchanged.

## Alternatives considered

Moving the tabs beside the posters would change the approved layout without
establishing a need. Shrinking the posters would affect a separate requirement.
Removing or skipping the pending tests would conceal the remaining work. Keep
this checkpoint narrowly focused on the empty subtitle row.

## Risks

The four empty-caption expectations are anticipated to fail on current code;
no qualified RED or GREEN result exists yet. Root must run Flutter serially with
isolated test data, inspect controls, implement the bounded correction and rerun
related cases. This checkpoint provides no native visual or performance acceptance.

## Verification

Pre-commit review checked the bounded fake transport, isolated temporary data
and diff whitespace. No Flutter, native-client, network or account operation was
run for this checkpoint. Normal commit hooks remain enabled. Test-source SHA256
before staging: a0a6ecb953cc568e8d817375d34b025646844903eb26cc522374ab999759b623.

## Acceptance criteria

Qualify all six cases, then verify empty captions consume no subtitle row while mixed rows, real captions, original actions and existing compact shelf regressions remain correct.
