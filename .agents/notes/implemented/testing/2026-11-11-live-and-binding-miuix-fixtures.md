# Agent Note: Live and binding fixtures target current Miuix behavior

Status: implemented

Applies on 2026-11-11 to the three legacy suites at production b3d7799.
This is a tests-only migration. The production live reveal and motion fixes
retain their independent regression evidence.

This preserves [provider-qualified identity](../bug-fix/2026-10-25-identity-must-carry-discriminator.md)
and [the information-panel binding contract](../feature/2026-10-27-danmaku-info-panel-default-expanded-and-bindings.md).
The [source-tab wiring fixtures](2026-11-08-danmaku-source-tabs-and-wiring-fixtures.md)
use the same bounded lexical-check policy for a different constructor.

## Problem

The v59 related run has 120 passes, two existing skipped suites and six failures.
The same six failures reproduce on clean 76a1a5e in the three selected suites
(48 passes). Two highlight checks still locate Container/BoxDecoration, two EPG
checks target retired Material controls, one empty-state check requires obsolete
copy, and one binding check requires a single-line expression. These failures
prevent those suites from checking the current user-facing contracts.

## Decision

Live selection tests inspect keyed MiuixCard rows, nearest selected semantics
and the actual painted ShapeDecoration. They compare the full provider:id set,
including inactive row paint, rather than accepting any colored card. The
keyboard test retains actual key events, checks the stream-request identity and
adds the reverse arrow. Its explicit fixture returns empty streams and rejects
unexpected commands, avoiding incidental native-library failures.

The retained EPG component tests inspect its actual Miuix progress indicator:
exactly one bar, only on the current program, with progress 0.5 within 0.01.
The disabled row requires the actual MiuixPressable to be disabled with no
callback or semantic tap action; pointer activation still leaves both business
callbacks idle. This does not reintroduce EPG into LivePage.

The empty-live test renders the real page, invokes its management action,
reaches SourceManagerPage with the live filter and returns. A disabled live
provider is visible there while the VOD provider is absent. Its read-command
whitelist and mutation callbacks reject source edits, imports and scans.
Fixtures isolate persistence and restore the prior seams after unmounting.

The static binding matcher locates the single expression-bodied host getter,
masks quoted text after comment stripping, and checks only top-level named
arguments of its constructor. It requires exactly the complete guarded binding
expression. Three independent control cases cover whitespace/comments, absent
arguments disguised by unrelated code or strings, and incorrect/duplicate
expressions. This remains a bounded lexical gate, not a general Dart parser or
proof of native binding delivery.

## Alternatives considered

Deleting assertions or adding skips would hide behavior. Color presence alone
would confuse neutral and selected rows. Updating only the empty-state literal
would not test its reachable management action. A whole-file binding substring
could accept a decoy elsewhere; a fixed whitespace pattern would repeat the
same formatting failure. Broad source/test formatting is excluded from this
migration so the diff describes the actual fixture changes.

## Verification

The first targeted execution passes 57 cases. The integrated twelve-suite run
passes 145 cases, retains the same two existing skipped suites and has no
failures. It includes the unchanged sixteen independently qualified live-reveal
and reduced-motion cases. Every tool run records unchanged Dart source/test
snapshots. Tests use --no-pub and --concurrency=1.

Initial targeted analysis identifies one unused import and four const hints;
these are corrected without changing fixture behavior. Final analysis and
post-cleanup focused execution are recorded by the coordinating task before
commit. No new skip or production change is introduced. The old six-failure
baseline diagnoses obsolete fixtures; these passing migrated tests do not
replace the production fixes' separate RED evidence.

## Consequences

Existing live identity, EPG interaction, source-management access and binding
contracts become observable again through current Miuix controls. The two
registered skipped suites remain unvalidated. Playback, native input, decoder
handoff and frame-time acceptance are separate gates.

The note audit searches proposed, implemented and rejected notes. Identity and
binding decisions partially overlap and are linked in both directions. Existing
Miuix framework/menu decisions retain their production scope; the earlier
library fixture migration owns different files. The transition-frame and
instrument-broken registration notes retain their unrelated evidence/skip
policies. No prior Decision is reversed or absorbed.
