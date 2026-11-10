# Agent Note: HTML catalog covers retain their response base

Status: implemented

Applies from 2026-11-09 to the PanWebShare catalog parser and transport.

Related decisions: [library cover lifetime](2026-11-08-library-cover-lifecycle.md)
owns durable metadata and session image registration; [CSP routing](../architecture/2026-11-09-csp-global-routing-retains-engine-recipes.md)
owns transport policy. This note covers extraction before those layers.
[Card metadata boundaries](2026-11-10-catalog-card-status.md) additionally owns
complete card selection and release status extraction; response-base rules here
continue to apply.

The proposed, implemented and rejected note search found no other owner of
relative catalog cover extraction. The older CSP honest-contract note overlaps
on empty results and mirror selection, which remain intact. Source registration,
GitHub coverage, selected-file handoff and cloud authentication notes are separate.

## Problem

Catalog pages can provide root-relative poster paths and HTML-escaped query
parameters. Rejecting non-absolute attributes discards valid image references.
Passing escaped ampersands into the image request changes its query keys. A backup
origin or redirect can also make the configured primary domain the wrong base.

## Decision

Parse quoted `data-src` and `data-original` attributes, decode HTML entities once,
and keep valid HTTP(S) or relative candidates. Reject empty, fragment-only and
non-network schemes. The existing parser stays deliberately template-specific;
no HTML parser dependency or speculative CDN address repair is introduced.

The successful HTTP response carries its final URL alongside its body. Home,
list, search and detail resolve their covers against that URL. Sticky mirror
selection keeps the configured mirror identity, so a redirect does not mutate the
user's backup list. The existing request headers, budgets, failure handling and
global proxy route are preserved.

## Alternatives considered

Resolving against the first configured domain breaks backup responses. Resolving
against only the successful configured domain still loses redirected page paths.
Repeated entity decoding corrupts intentionally escaped query values. Guessing
an external CDN from a missing relative image would fabricate a resource not
provided by the source.

## Consequences

Three regression cases fail on the previous working implementation and pass on
the corrected implementation. Local HTTP tests exercise primary failure, backup
redirect, all four catalog entrypoints, exact final cover URLs and sticky mirror
identity. Existing engine/proxy regressions remain required.

A syntactically correct URL can still return 404 or time out. The UI retains its
neutral placeholder and bounded retries; this change does not promise that every
upstream poster exists. Revisit extraction only with evidence of another template
variant, without weakening response-base or routing guarantees.
