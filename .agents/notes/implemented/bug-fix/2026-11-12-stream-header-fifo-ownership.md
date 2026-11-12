# Agent Note: Stream headers follow their owner's FIFO lifetime

Status: implemented

Applies: 2026-11-12, stream registration and rewritten HLS child routes.

Related decision: [stream child query and redirect forwarding](2026-11-10-stream-child-query-forwarding.md) owns URI reconstruction and media header forwarding. This note defines the lifetime of the header token used by those child routes.

The proposed/implemented/rejected note audit finds no existing FIFO header lifetime decision. The scoped HLS query note retains its separate declared-query policy. The child-forwarding note partially overlaps at the consumer route; both decisions remain and link to each other.

## Problem

The stream table evicts its oldest half using registration order. The header table independently removes an arbitrary half of HashMap keys. A retained playlist can therefore keep its `/s/` registration while losing the header token used by its rewritten `/p/` children. The playlist succeeds but its next segment returns 404. Conversely, an evicted stream can leave orphan headers.

## Decision

Each stream owns exactly one header entry. Registration holds the stream table, registration order and header table locks in that order. When the FIFO removes a stream, it removes that stream's header token in the same operation. The new stream and its header are inserted under the same locks.

The existing capacity threshold and oldest-half quota remain. Headers have no separate unordered eviction. Request handlers clone the entry under their existing short lookup locks; network requests do not hold registration locks. Covers retain their independent table, index and eviction rules.

## Alternatives considered

Two independent queues would duplicate lifetime state and allow future drift. Clearing either table would invalidate currently retained streams. Increasing capacity would delay the mismatch without correcting ownership.

## Consequences

Three identical regressions run on the clean old checkout and corrected checkout. The old executable fails all three, including a real loopback playlist returning 200 followed by its rewritten segment returning 404. The corrected executable passes all three without ignored cases: all retained streams have their own headers throughout eight capacity cycles, no orphan headers survive eviction, and the actual child returns 200 with the expected bytes and source header. Both runtime Jobs exit normally with eight continuous seconds at zero processes and no forced cleanup.

The HTTP test selects an actually affected retained entry on the old implementation, or the newest retained entry when all headers are valid, and applies the same response expectations. The local fixture establishes stream/header lifetime and HTTP routing. It does not establish remote media availability, native audio/video presentation or desktop acceptance. Those remain separate full-goal checks.

Reconsider this structure if header entries acquire independent owners or reusable lifetimes; that requires an explicit ownership model rather than restoring independent eviction.
