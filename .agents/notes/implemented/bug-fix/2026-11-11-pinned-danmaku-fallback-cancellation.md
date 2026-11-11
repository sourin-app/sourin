# Agent Note: Cancel obsolete pinned danmaku fallbacks

Status: implemented

Applies from November 11, 2026 to the pinned-comment branch in PlayerPage;
the RED baseline is 5f7d7e98393af14b58c4c21bab350562cbd42eae.
This extends the session ownership described by
[player progress and danmaku workflow](2026-11-04-player-progress-and-danmaku-modal-workflow.md)
and preserves the normal no-match handling in
[no-match feedback](2026-11-09-danmaku-no-match-feedback.md).
Both related notes remain in effect; no decision is superseded.

## Problem

The pinned comment success branch checks the mounted player, play session and
fetch token. Its failure branch immediately falls back to matching and search.
A delayed failure can therefore start more requests for an obsolete selection
after another load, a disabled toggle or player disposal. Guards following the
fallback prevent stale UI publication but do not prevent that additional I/O.

## Decision

Check the same mounted/session/token ownership in the pinned failure branch
before logging the fallback and calling loadFor. A current failure retains the
existing matching/search behavior, normal no-match notice and error handling.
Use no new API, timer or cancellation abstraction.

## Alternatives considered

Deleting fallback would change current pinned-failure behavior. Checking only
after loadFor still sends obsolete match/search requests. Checking only mounted
does not cover another load or disabling danmaku within the same player.

## Consequences

The frozen test mounts the real PlayerPage with its existing video
initialization handshake and observes actual DanmakuTransport calls and host
panel fields. Three negative cases hold a pinned request, supersede it by a new
request, turn danmaku off or unmount, then deliver HTTP 500. A control keeps the
request current and requires match/search plus its real no-match panel state.

The clean baseline fails all three cancellation cases because the transport
receives an extra `/api/v2/match` and `/api/v2/search/episodes`; its unchanged
current-failure control passes. With only the six-line pinned failure guard,
all four named cases pass. The current control preserves the actual neutral
no-match host status and cleared error. The newer request's host status remains
current, and the disabled state remains off after the old failure finishes.

Evidence is in
`.probe/background-takeover-20261111/next-behavior-red-c3.log` and
`next-behavior-green-c2.log`, with their matching receipts. Both receipts
record unchanged sources during each command and the same formatted test
SHA256 `33015ef8751e4318c4c129985e509c5bfde88ce07808d3e07e4a489fc63fbf50`.
The tested source hashes are `05ff0369858a9fed887b2a537f17a93f4f63605c811087ea79719d82da9c885a`
and `24450da7ab78b70968f6e0d659cabd71eb08e480274a8fdea85ebe268704d657`.

Those receipts belong to a combined invocation containing other tests. The
clean baseline reports eight intended failures and six passing controls; the
guarded invocation passes all fourteen tests. The four pinned cases establish
their request boundary within that explicitly scoped combination.
The command uses `--run-skipped --no-pub --concurrency=1 --timeout=90s
--reporter=expanded`, below-normal priority and two logical CPUs, with no
desktop input or client launch.

The test substitutes HTTP responses and acknowledges the real native video's
initialization/disposal handshake. Media open is disabled; the cache directory
is isolated per case and preferences/core transport use test seams. These are
request and host-state observations, not native decode, image pixels, physical
input, external availability, account playback or final-package acceptance.

The guard ends the pinned failure continuation before its fallback begins. It
does not abort already-issued transport requests or add cancellation between
the internal matching/search steps of `ExternalDanmakuClient.loadFor`. Normal
primary/plugin aggregation keeps its existing behavior. Other external comment
entry points retain their independent fetch-token checks; this note does not
claim new playback-generation coverage for them.
