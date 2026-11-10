# Agent Note: Pending duplicate directory regression checkpoint

Status: proposed

Related: [declared directory contract](../../implemented/bug-fix/2026-11-11-object-ext-themed-directory-contract.md)
owns the current loader, routing, bounds and cache behavior. This proposed
compatibility correction does not supersede that implemented decision yet.
Applies to production baseline 4590771.

## Problem

An existing declared directory reaches the production loader but is rejected
because category IDs repeat. Rejecting the whole directory is a host constraint;
the local reference returns the declared JSON body without that rejection.
The actual body's duplicate labels and order still need diagnostic inspection.

## Proposal

Preserve four newly prepared regression cases as a local progress checkpoint at
the user's explicit request to commit outstanding work. The only loader edit
registers the new test module under cfg(test); runtime behavior is unchanged.

The behavior case proposes stable first-occurrence ID, name and order, including
nonadjacent repeats and numeric-looking IDs. It checks the real directory loader,
configured proxy route, cached results and absence of a general-catalog fallback.
Three controls retain rejection of empty IDs, empty names and a malformed repeated
row. A repeated ID must not hide invalid data. These are proposed host semantics,
not a claim that the reference implementation performs deduplication.

## Alternatives considered

Discarding the pending tests would lose the current investigation. Mixing the
one-line production correction into an unqualified checkpoint would obscure the
missing baseline evidence. Preserve the tests separately before implementation.

## Risks

The behavior case is expected to fail against the current duplicate rejection;
none of the four cases has been compiled or executed. No qualified RED or GREEN,
resource-body inspection, native playback or compatibility acceptance is claimed.
Existing directory fixtures and production behavior remain unchanged.

## Verification

Static review covers loopback-only fixtures, missing account headers, actual
request ledgers and exact category outputs. Diff whitespace and the repository
notes gate are the checkpoint checks. Normal Git hooks remain enabled.
Test-source SHA256: 9b99d627275b34ec37055f9a59705a83f933129b8c559984479207ac23f3922f.

The note audit searches proposed, implemented and rejected notes for duplicate
categories and themed directories. Only the linked implemented contract owns
this decision; it remains in force pending qualification and a production fix.

## Acceptance criteria

Qualify the four tests on an isolated current production baseline, inspect the
public resource shape through the configured proxy, implement the bounded
compatibility correction and rerun existing directory regressions. Validate the
result in a fresh client before claiming the actual directory is usable.
