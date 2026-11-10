# Agent Note: Declared media query fields survive scoped HLS forwarding

Status: implemented

Applies: 2026-11-10, adapters explicitly opting into the internal scoped HLS policy.

## Problem

A source can issue a signed parent playlist while its reference transport copies
selected parent query fields onto queryless media URIs. Ordinary HLS resolution
drops a parent's query when resolving a relative segment. In this protocol that
produces an HTTP-success body too slow for playback, so status, catalog results
and a readable playlist do not identify the omitted transport step.

This partially overlaps the [engine recipe and global routing contract](../architecture/2026-11-09-csp-global-routing-retains-engine-recipes.md)
and the [HLS fact probe](../feature/2026-10-30-hls-playlist-total-ms.md). Both remain
in force. This note adds a source-declared URI transformation; it does not
replace either decision or the [real-response verification requirement](../feature/2026-10-26-encrypted-protocol-needs-real-response.md).
No matching proposed or rejected decision is superseded.

## Decision

The source trait defaults to no HLS query policy. The reviewed adapter opts in
only for its canonical HTTPS playlist origin and honors explicit source
`use_proxy` zero/false. Provider conversion attaches that policy to an internal
candidate field skipped by serialization and deserialization. External plugin
JSON cannot enable it. Other sources keep their existing behavior.

Resolve registers these candidates with the existing local media forwarder
before HLS fact probing, so probing and native playback share the same origin
guard and nested-playlist semantics. Header tokens retain the source policy.
For a queryless media URI line, the forwarder resolves against the successful
response's final URL and copies only the declared parent's raw allowlisted
query pairs. Original order, duplicates, empty values, literal plus and escape
spelling remain intact. Existing child queries, including an empty question
mark, stay authoritative. Keys, timestamps, signatures and identities are never
generated or refreshed by this transformation.

Nested playlists retain that token and policy and use their own effective base
and query. KEY/MAP URI attributes use normal resolution without inventing media
query inheritance. Encoded path bytes survive the local router's decoding layer.
Undeclared origins, different ports, scheme downgrades and credential-bearing
targets are rejected before a request, including redirects. The scoped client
uses the same global media recipe and a bounded same-origin redirect policy.
ApiOnly still selects direct upstream media; All still uses the selected global
proxy, including hot configuration changes. Source `use_proxy=false` disables
the source transformation, not the application's global route.

## Alternatives considered

- Copy every parent query onto all HLS: changes unrelated sources and can leak
  access-bearing values across origins.
- Set only a header or decoder flag: does not implement the reference's URI
  transformation or reach nested media requests.
- Change retry counts or silently select another identity/episode: does not
  correct the issued URI contract and changes access decisions.
- Check origin only after an automatic redirect: the redirected request may
  already have disclosed a signed URL.
- Transform once into a data URI: bypasses the existing media route and loses
  effective bases and recursive playlist handling.

## Consequences

Loopback regressions inspect actual upstream requests for inherited raw pairs,
headers, encoded paths, nested manifests, effective redirect bases, existing
child queries and KEY/MAP behavior. Negative cases observe zero foreign-server
requests for cross-origin children, redirects and forged token paths. Route
controls compare ApiOnly and All without changing the source session. Provider
tests inspect real conversion and the nonserializable internal field.

These tests and bounded body observations establish the transport contract.
They do not establish sustained decode, complete-title playback, player
interaction, screenshots or package acceptance; those remain separate native
verification gates. Scoped sources using a previously undocumented cross-origin
media host fail explicitly until their source contract is reviewed.
