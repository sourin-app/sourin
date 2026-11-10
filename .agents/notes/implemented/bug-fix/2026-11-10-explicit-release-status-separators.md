# Agent Note: Explicit release metadata accepts bounded source formats

Status: implemented

Applies from 2026-11-10 to the shared PosterCard release-status classifier.

Related: [catalog card metadata](2026-11-10-catalog-card-status.md) owns source
extraction, and [library cover lifecycle](2026-11-08-library-cover-lifecycle.md)
owns saved records. The note review found these partially related; neither owns
the formats accepted by the shared display classifier. No note is superseded.

## Problem

A displayed source card carried `已完结,全26话`. The classifier recognized
completion and episode counts separated by middle dots but rejected commas,
so explicit completion remained below the cover as a plain subtitle.
Later visible catalog cards also carried update ratios and the exact label
`全剧集`, which the classifier left below the cover despite their explicit
release meaning.

## Decision

Accept ASCII and full-width commas as separators between the same explicit
completion and episode-count phrases. Preserve whole-string matching, numeric
normalization and the separation of source status from user notes, unread
counts and watched progress. Do not infer completion from a title or an
unrecognized descriptive suffix. Both ordering forms use the shared classifier.

Accept the exact `全剧集` label as completion without inventing a total. Accept
`更新至N/M集` and `更新至N集/全M集` only with positive counts and N no greater
than M, displaying both as `更新至N/M集`. Equality remains an update label and
does not infer completion. Only these explicit update-ratio phrases may end at
an ASCII or full-width comma before ancillary source information. Do not split
arbitrary notes at commas or loosen completion/descriptive-tail matching. The
existing source episode-count fallback remains separate from watched progress.

## Alternatives considered

Matching the word completion anywhere would classify `未完结` or descriptive
text incorrectly. Rewriting provider notes globally would alter source data.
The shared narrow display change keeps original metadata intact.

## Consequences

The mounted shelf regression failed for the observed comma form before this
change. It now checks ASCII/full-width forms, reversed phrase order, full-width
digits and negative incomplete/descriptive cases; the complete compact shelf
and segment suite passes eighteen tests. This proves badge classification and
rendered shelf behavior, not remote source metadata availability or cover fetches.

The later mounted search-result behavior RED records three missing labels and
eleven passing invalid/ambiguous controls. The test feeds normal result events
through SearchPage and checks the actual PosterCard output, Miuix badge bounds
inside the cover, and removal of the raw subtitle. Its negative cases retain the
original subtitle and exclude a badge. Production GREEN and fresh native
screenshots are separate root-owned validation steps; no new acceptance is
implied by this classifier change.
