# Agent Note: Explicit completion metadata accepts source separators

Status: implemented

Applies from 2026-11-10 to the shared PosterCard release-status classifier.

Related: [catalog card metadata](2026-11-10-catalog-card-status.md) owns source
extraction, and [library cover lifecycle](2026-11-08-library-cover-lifecycle.md)
owns saved records. The note review found these partially related; neither owns
the punctuation accepted by the shared display classifier. No note is superseded.

## Problem

A displayed source card carried `已完结,全26话`. The classifier recognized
completion and episode counts separated by middle dots but rejected commas,
so explicit completion remained below the cover as a plain subtitle.

## Decision

Accept ASCII and full-width commas as separators between the same explicit
completion and episode-count phrases. Preserve whole-string matching, numeric
normalization and the separation of source status from user notes, unread
counts and watched progress. Do not infer completion from a title or an
unrecognized descriptive suffix. Both ordering forms use the shared classifier.

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
