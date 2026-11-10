# Agent Note: Cache outgoing route content during its own pop

Status: implemented

The existing [home and motion boundaries](2026-11-08-home-card-and-motion-boundaries.md)
own shell tab caching and incoming/outgoing transforms. The
[local reduced-motion decision](2026-11-11-local-component-reduced-motion.md)
owns local reveals. This note extends the existing route content cache to its
own reverse animation without changing the transition style or preference.

## Problem

The route snapshot owner listens only to secondaryAnimation. A top page is
removed by reversing its primary animation while its secondary animation stays
dismissed. Its content therefore keeps repainting during the outgoing fade,
even though the underlying covered page already uses a content snapshot.

## Decision

The existing snapshot owner listens to both animations. Snapshotting is enabled
while secondary animation is moving or primary animation is reversing. Primary
forward entry stays live. The snapshot remains inside the opacity/transform
layers, so it cannot freeze visual motion. Both listeners are transferred when
widget animation identities change and removed on disposal. Settling releases
the cache. None/reduced-motion and the framework Zoom path remain governed by
their existing branches.

## Alternatives considered

Always caching primary animation would freeze incoming asynchronous content.
Caching the outer transition would freeze its changing opacity and transform.
Neither matches the existing live-page and motion contract.

## Verification

Two tests mount a real Navigator and MaterialPageRoute with the production
transition builder and a repaint-notifying content painter. Before the fix,
the covered-page secondary-animation control passes, while own-page pop
repaints the content (3 paints versus the expected 2), despite a changing outer
fade. The same unchanged tests pass after the fix. Settled content paints live;
the surviving covered page releases its cache after return, and the popped
page is removed. No paint counter or lifecycle assertion is replaced with a
source-text check.

The eleven-suite related run passes 77 cases covering both route tests, existing
snapshot motion, route style, clipping, scrim and global/service proxy behavior.
Targeted analysis reports no issues after removing one redundant test import.
Widget paint counts establish the missing cache boundary, not Windows frame
timing or a claim that every navigation stutter is fixed. Native verification
remains required for the broader performance goal.

## Consequences

Outgoing pop content avoids repeated repaint work during the brief animation.
The page becomes live again when the transition settles; incoming pages still
show updates. Native/video content retains SnapshotMode.permissive behavior.
The broader playback lifecycle and source-compatibility goals remain separate.
