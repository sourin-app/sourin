# Agent Note: Recognize opaque HLS without buffering ordinary media

Status: implemented

This supplements the [CSP line and selected episode decision](2026-11-16-csp-source-lines-and-selected-episodes.md). Its source groups, episode identity and resolve filtering remain unchanged. The [global CSP routing decision](../architecture/2026-11-09-csp-global-routing-retains-engine-recipes.md) still owns transport policy and engine request recipes.

## Problem

A retained public NBY candidate responds with HTTP200 and application/octet-stream at an extensionless getM3u8 endpoint. Its body begins with #EXTM3U and contains absolute child URLs. The existing forwarding boundary recognizes only MIME or requested/effective filename suffixes, so it returns those children unchanged. A decoder can bypass the configured route and original header token even though it entered through the core wrapper. A separate retained decoder trace confirms that the initial playlist request can include Range: bytes=0-; a200 response ignoring that header is still a complete response.

## Decision

The shared media forwarding boundary keeps known MIME and effective suffix behavior. Successful full200 responses with a generic/missing/plain-text MIME and no Content-Range or nonidentity Content-Encoding receive a signature check. It copies at most eleven leading bytes for comparison and retains consumed HTTP frames as zero-copy Bytes for replay. The check accepts #EXTM3U followed by a line ending or actual EOF, optionally preceded by a UTF-8 BOM, and stops at the first mismatch or the configured250ms pending-read timeout.

A match enters the original playlist decoder and URI rewrite path using the existing registered token, original headers and effective response URL. The reader joins the retained prefix only for a recognized manifest and strips its leading BOM. Negative or slow prefixes are replayed before the remaining original byte stream. Opaque partial responses and encoded generic bodies retain their original bytes and response headers. The outgoing request still carries the caller's Range header; a full200 manifest can be recognized even when the origin ignores that requested range. Known MIME/suffix playlists retain their original decoding/rewrite behavior, including its handling of206 responses.

## Alternatives considered

- **Carry an HLS hint through every registration**: explicit provider metadata can avoid signature probing, but it requires changing the shared registration contract and does not cover untyped callers. Response recognition fixes the actual boundary while retaining those callers.
- **Collect every generic response before classification**: it identifies a manifest after arbitrary delays, but also buffers whole media objects and waits for their EOF. The prefix check limits recognition work and leaves ordinary media streaming.
- **Skip every request carrying Range**: it protects partial-response bytes, but the retained decoder's initial Range request can receive a full200 manifest. Response status and Content-Range provide the actual partial/full distinction.

## Consequences

Extensionless, generic-MIME HLS with a timely signature enters the same token/header/proxy rewrite path as labelled HLS. There is no new provider-specific URL rewrite, runtime or dependency. Encoded generic HLS, partial opaque responses and signatures not returned by the configured250ms timeout remain unrecognized by this fallback; they are not claimed as complete protocol coverage. Tokio's timeout polls the inner future, so continuously ready empty frames are not a strict wall-clock deadline guarantee. The stall test proves bounded normal waiting and lossless continuation, rather than performance acceptance. Recognizing a playlist or decoding PCM does not prove that the selected film is returned. The retained NBY playlist is approximately30s, and BBA separately returns a missing-video placeholder, so actual selected-film content still needs review.

## Verification

The actual original Release test EXE is retained in opaque-hls-baseline-v2. Its duplicate-MIME fixture failure is kept as a test-development receipt. The final frozen baseline-v4 runs five unchanged valid assertions from that same EXE: three positive controls pass and two actual extensionless-HLS/BOM assertions fail, with exit101,268 baseline Rust/Cargo inputs, natural Job zero8.016s and no force. The obsolete expectation that a full200 HLS response ignoring Range must stay unmodified is explicitly excluded; genuine opaque partial and binary200 responses are checked in the final candidate.

The final opaque-hls-candidate-v2 Release EXE SHA256 is9811CBE7D19007AC4249BFBDE2ADBD6843F801AFBA247656DCB0320939D0DB63. It passes eight real HTTP assertions, zero failed or ignored, with269 current/frozen Rust/Cargo inputs unchanged, exit0, natural Job zero8.031s and no force. The new decoder-style Range: bytes=0- request receives a full200 opaque HLS and verifies its local child URI, original Referer, query bytes and forwarded segment bytes. Original MIME/effective-redirect/gzip playlists, false binary signatures, partial206, ignored-Range200 binary, encoded generic bytes and a stalled incomplete prefix retain their stated behavior.

OPAQUE_HLS_OWNING_TESTS_ACCEPTED_V1.json independently rehashes the frozen input/actual-EXE/raw-log chain, proves the baseline owning implementation equals ed0f8fb apart from test registration, matches the original two business failures to same-name passes and rejects force/exit/input/whole-goal alteration controls. The first seven-test candidate remains a historical stage and is superseded by the final Range case. The same final EXE passes91 streamproxy tests, including the eight owning cases, with zero failures or ignores; only the previously named live bili_cdn test is excluded. Its separate HLS-facts group passes6 with zero failures/ignores. Both runs retain unchanged269 inputs, exit0, natural Job zero above8s and no force. Production DLL/package bytes and current real-media validation remain separate required checks; no ordinary startup, full UI, performance or whole-goal acceptance follows from these tests.
