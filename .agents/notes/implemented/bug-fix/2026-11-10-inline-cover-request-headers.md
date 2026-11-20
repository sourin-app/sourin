# Agent Note: Decode inline TVBox cover request headers

Status: implemented

Applies from 2026-11-10 to registered cover requests.

Related decisions: [cover proxy routing](2026-11-10-cover-global-proxy-routing.md)
owns API proxy policy and defaults; [library cover lifetime](2026-11-08-library-cover-lifecycle.md)
owns durable storage; [catalog extraction](2026-11-09-relative-catalog-covers.md)
owns HTML decoding and response-relative resolution.

The proposed/implemented/rejected note audit found these overlapping owners.
Their decisions remain intact. This note adds per-image request metadata, not a
replacement CDN or a change to media transport.

固定 URL 的前端 provider 重复解析与 hash 复用由
[封面 provider 身份复用](../simplification/2026-11-19-cover-provider-identity-reuse.md)持有；
本篇的传输头解释和持久化规则保持不变。

## Problem

A fetched PanWebShare catalog contains poster URLs ending in
`?@Referer=...@User-Agent=...`. The old registered cover request sent the suffix
as part of the URL and used source-wide/default headers instead. A local HTTP
endpoint requiring the declared per-image request returned 403.

## Decision

Decode recognized Referer/User-Agent suffixes only when registering covers.
Accept the observed empty-question-mark form and suffixes after normal URL/query
content. Keep real query escapes intact, decode header values once, validate
header values and Referer URLs, and leave unsupported/malformed suffixes intact.
Per-image headers override source-wide headers case-insensitively. Unrelated
headers and the selected API proxy policy remain intact.

Cover entries retain both original metadata and the actual request. Unproxying
returns the original metadata, so following, favorites, history and progress
survive restart without dropping image-specific requirements. Stable cover keys
retain the original URL and provider headers; image credentials do not collide.
Media entries and media registration are unchanged.

## Alternatives considered

Stripping metadata in the catalog parser would discard headers or lose them on
restart. Applying it to every stream URL would broaden the playback change.
Guessing an embedded CDN from a failing relative path would invent a resource.
Only the two observed header types are supported; this is not an arbitrary
header configuration language.

## Consequences

[Completed HTML recovery](2026-11-11-html-cover-recovery-after-save.md) keeps
durable URL/header interpretation while extending invalid-body evidence and
post-save publication of singleton checks.

The real HTTP lifecycle case checks 403 before integration, decoded URI and
headers afterward, API proxy use, /s and /p routes, stable tokens, durable raw
metadata and all four library views after restart. Existing proxy, cover-header
isolation and progress-preservation checks remain required. Unit controls cover
normal @ in URLs, ordinary queries, fragments, unknown names and invalid header
values.

Two sampled public posters already returned valid images with the old request
as well as the new one. This establishes a protocol compatibility defect and its
fix, not proof that those public images were missing before the change. Other
upstream 404/444 responses and startup driver compilation remain separate.
