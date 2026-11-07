# Agent Note: Full-page specific cloud-file handoff regression

Status: implemented

Applies to the full MediaPage regression from 2026-11-07. Covers the
[selected-file session contract](2026-11-05-selected-file-session-handoff-and-playback-error-privacy.md).

## Problem

Direct PlayerPage tests do not cover the DetailPage right-rail callback through
MediaPage. Listing order may differ from episode numbers, with multiple versions
of the same numbered episode. A title or share address cannot identify a file.

## Decision

Mount production MediaPage, DetailPage and PlayerPage with seven synthetic file
ids, reordered episodes and duplicate episode numbers. Tap actual right-rail
entries and inspect the production API's serialized resolve_stream arguments.
Assert exact provider, item, episode id/title/flag, list order, source code,
decoded selected fid and retained MediaSession identity.

SOURIN_TEST_PAN_HANDOFF_DROP_EPISODE_ID is an opt-in receiver-only mutation.
It removes the selected id inside the synthetic transport so the same identity
assertion must fail. Production serialization and UI callbacks stay unchanged.

## Alternatives considered

Direct player mounting misses callback forwarding. Title-only comparisons fail
to distinguish versions. A hand-built serializer would bypass the contract.

## Consequences

The normal test passes in the isolated 2026-11-08 native-tag precommit run.
It skips media open and uses synthetic transport; it does not establish real
share validity, logged-in resolution or decoding. Fixture teardown unmounts the
page and drains timers. Recursive cleanup validates a plain owned temp directory.
