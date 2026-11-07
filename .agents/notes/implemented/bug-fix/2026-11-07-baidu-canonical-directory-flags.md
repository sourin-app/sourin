# Agent Note: Canonical directory flags across listing and selection

Status: implemented

Applies to the share resolver from 2026-11-07. Extends the
[typed list rejection observation](../testing/2026-11-06-baidu-initial-list-typed-shape.md)
and [selected episode contract](2026-11-05-baidu-selected-episodes.md).
The observation remains value-free; its older numeric-only predicate is superseded.

## Problem

A typed initial-list rejection identifies a string directory flag. Numeric-only
validation rejects that representation before file selection. Type evidence
alone does not identify the rejected value or establish account failure.

## Decision

One directory_flag helper accepts JSON integer 0/1 and exact strings "0"/"1".
It rejects other strings, floats, nonbinary integers, booleans, null and containers.
The same predicate drives initial shape projection, list entry checks, traversal
and final file validation. Missing flags retain the existing initial-list behavior
but remain invalid when collecting an actual file.

The optional task-local observer retains only fixed type enums and rejection
booleans for the first invalid initial entry. It retains no response values,
identifiers, filenames, URLs, cookies or content hashes. Without a scoped observer
no projection is constructed. This public wrapper supports bounded diagnostic
callers and its production-path tests; it is not an always-on logger.

## Alternatives considered

Parsing arbitrary numeric strings would accept whitespace and noncanonical forms.
Skipping rejected entries silently loses episodes. Picking the first file breaks
explicit identity. Dumping responses would expose private data.

## Consequences

The offline 2026-11-08 run passes all 47 resolver tests. Loopback protocol tests
cover string and mixed numeric flags across pagination and nested directories,
exact selected fid despite conflicting title/order hints, and invalid flags at
all list stages before account/sign/download calls. Existing traversal limits,
deadlines, cookies, id parsing and numeric size parsing remain unchanged.

These checks establish the resolver's synthetic protocol behavior. Actual share
selection, authorized account access, download, decoded playback and production
package acceptance remain separate. No broader account authorization is implied.
