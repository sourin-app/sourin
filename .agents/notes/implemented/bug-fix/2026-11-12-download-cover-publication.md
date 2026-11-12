# Agent Note: Validate durable download covers before publication

Status: implemented

Applies: 2026-11-12, Dart download completion and cache sidecar cover references.

Related: [Library cover lifecycle](2026-11-08-library-cover-lifecycle.md) owns display and library persistence. [Cover proxy routing](2026-11-10-cover-global-proxy-routing.md) owns registered image transport. This decision covers local download cover publication; neither existing decision is superseded. The keyword audit across proposed, implemented and rejected notes found source-update, subscription-lineage, native-catalog and package-manifest sidecar notes; those concern different sidecar data and do not govern download cover files.

## Problem

A successful cover request can return HTML, a truncated image or a fully transparent CDN sentinel. Download completion previously wrote any nonempty response up to 8 MiB as a local cover. A refresh could overwrite an existing decoded poster with unusable bytes. Rejecting those bytes alone still left a second defect: the next episode's sidecar replaced the prior valid local cover reference with null.

## Decision

Decode the first image frame before writing the temporary cover file or publishing a filename. Bound validation dimensions to 4096 pixels per axis while saving the original encoded bytes. Reject a decoded single-frame image no larger than 8 by 8 whose RGBA pixels are all transparent, matching the display cover sentinel rule.

When a new cover cannot be cached, retain the previous sidecar's filename only if it matches the generated cover filename whitelist, exists in the same work directory, fits the existing encoded size limit and passes the same actual decode. The new episode metadata still completes. Malformed sidecar data and invalid or missing prior files yield a null local reference.

Keep the existing HTTP route, encoded size limit, fixed temporary filename, same-directory completion serialization and atomic replacement retries. The cache card continues to render its network poster below the local image; that existing fallback behavior is preserved.

## Alternatives considered

- Trust response Content-Type or an encoded magic prefix: both accept misleading headers or incomplete image bodies.
- Reject invalid new bytes without preserving the sidecar reference: the file survives but the cache scanner cannot use it after the next episode completes.
- Accept an existing filename without decoding it: previously persisted HTML or transparent sentinels would become durable offline covers.
- Convert every image to a new encoding: conversion changes original encoded bytes and adds unnecessary work.

## Consequences

Local validation adds one bounded frame decode when a cover is downloaded, and when an existing reference must be retained after a failed refresh. It does not change ordinary display image decoding or playback transport.

The frozen two-arm loopback payload checks actual published files, exact encoded bytes, real first-frame decoding, two actual HLS completion events, final sidecar metadata and scanned local cover identity. A real cache card control inspects a rendered 32 by 48 image from its network fallback. Existing concurrency and atomic replacement tests keep their positive controls, byte identity, retries and fixed temporary-file assertions; their response bodies are actual PNGs of the original encoded lengths, with valid private binary ancillary padding rather than repeated non-image bytes. Large text metadata is unsuitable padding because decoding it adds unrelated work between the response gate and the disk-write window.

The concurrency positive control also holds three production callers after their real writes and flushes complete on the exact same temporary path, before allowing actual rename. Individual writes and their length checks share one test-side scheduling chain so the instrument's own next truncation cannot invalidate a prior completed write. The ordinary serialized rounds do not arm this gate. This makes the fixed-filename race deterministic even when real decoder completion times differ; no product filesystem operation or decoder is replaced.

The integrated-root-v1 run failed at the first episode's eight-second state assertion, before reaching the second episode or retained-reference assertions. Its first HLS completion arrived later (9813 ms); the failure cleanup had already cleared the queue. A later "queue complete" log alone therefore did not prove a published done state or sidecar. The cause of that earlier delay remains unlocalized.

Queue test cleanup now waits for the actual in-flight worker futures before clearing shared resolvers and directory configuration. A cancellation state is insufficient: a deterministic test holds the resolver, cancels the task, verifies that the worker and idle future remain pending, releases it and checks that the worker exits without requesting the segment or leaving files. The two-episode test retains its original eight-second deadline and all byte, sidecar, scan and decode assertions, selects the result by task ID and records HTTP, queue and drain events for failures.

Validation: `.probe/takeover-feedback-audit-parallel-20261112/cover-drain-integrated-v1/result.json` records child exitCode 0, unchanged source hashes, no forced cleanup and 8.028 seconds of continuous empty Job membership. Its raw log reports all 20 tests passed across cover validation, concurrency and sidecar race suites. Both HLS episodes finish and the second sidecar retains a decoded 32 by 48 offline cover. The cancellation control reports zero remaining workers/files; the concurrency positive control observes real collisions in all three rounds (2, 3, 2). This result does not explain the previous transient latency or establish external-source/Owner acceptance.

These checks establish local HTTP, disk and rendering behavior in isolated Flutter test processes. They do not establish external catalog image availability or Owner visual acceptance. The existing cover body acquisition budget is outside this decision. Revisit the validation rule if a supported image decoder requires different bounded frame handling or legitimate small animation behavior changes.
