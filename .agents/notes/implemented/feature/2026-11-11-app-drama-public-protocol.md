# Agent Note: AppDrama public catalog and selected-episode protocol

Status: implemented

The [global CSP routing contract](../architecture/2026-11-09-csp-global-routing-retains-engine-recipes.md)
owns source transport policy. The [configuration preservation decision](../bug-fix/2026-10-29-ext-sources-dropped-on-probe-failure.md)
owns import/restore even when an upstream probe fails. This change replaces the
registered AppDrama facade's fixed unsupported catalog/playback implementation;
it does not change those routing, persistence or user-enable decisions.

## Problem

The registered class accepted configuration and performed domain dispatch, but
list/search/detail/play returned a fixed not-implemented error. A permanent
capability limit then excluded its saved categories and search participation.
Domain reachability and legacy crypto round trips did not implement the actual
public request sequence or retain the selected episode identity.

The list/search mapper also needs to distinguish a recognized empty Page from
unrecognized protocol data. An explicit zero-hit or exhausted Page must reach
the provider as a normal empty result; missing fields or an unrelated protobuf
message cannot establish that the source has no content.

## Decision

Keep one registered constructor and delegate its public methods to one protocol
owner. Use the current CspHttpContext for explicit global/provider routing,
with bounded requests and response sizes. The protocol executes configured
dispatch, RSA zone bootstrap, JSON categories and protobuf list/search/detail/
selected playback. No dependency or embedded runtime is added. Legacy public
pure configuration/crypto helpers remain compatibility APIs, not the runtime
wire implementation. A test-only old dispatch helper remains solely for the
existing explicitly ignored historical diagnostic.

The normal catalog path is `CspProvider::new` through the registered
`AppDrama::new`, then `list_inner`/`search_inner` and their shared `list_from`
mapper. An empty item batch is accepted only when the nonempty envelope data
has Page field 16 as a recognized nonnegative int32 total. Missing/empty data,
unknown-only messages, wrong-wire/negative/overflow totals, malformed rows and
batches exceeding the existing 512-item bound remain failures. Existing
zero-total pagination metadata remains `total=None` and `page_count=None`.
This exception belongs to the recognized public
Page schema, not to arbitrary empty HTML extraction or every CSP adapter; the
[honest-response contract](2026-10-26-csp-honest-contract.md) still rejects
unrecognized responses rather than pretending a parser found no content.

Runtime metadata describes the Windows application without inventing a phone,
Android identity or account. The protocol uses the independently recovered
field schema and synthetic crypto vectors. Small HashMap request ordering is
modeled from the reference bucket algorithm; server acceptance of that ordering
and of desktop metadata remains a real-service verification requirement.

Typed errors retain transport/parse/unsupported distinctions without exposing
raw response text, URLs, headers or key material. Explicit NEED_LOGIN remains
first in the provider classifier. Redirects are returned as explicit failures;
no automatic cross-authority header forwarding, account promotion, alternate
host discovery or identity rotation is added. Known account-share URLs are
identified with the same parser used by the production provider and are kept
out of this anonymous media result path.

## Selected episode and session ownership

Detail parses and validates the complete episode batch before atomically
issuing opaque bound identifiers in a bounded engine-local ledger. Source/ext,
provider/store/revision, content/index/line/source/path/restriction and issued
binding must match. A missing PlayRequest flag uses the issued line; an explicit
wrong flag fails. Oversized batches fail before evicting their own siblings.
The provider preserves an explicitly selected versioned identifier instead of
using it as a content ID and picking another episode.

Bootstrap keys expire after 60 seconds; keyed failures have a three-second
cooldown. Expiry does not make an already issued episode unusable: one exact
refresh fetches the same content and checks the original index and all identity
fields before renewing that same token. Changed/missing selection is revoked,
not replaced by a similarly named episode. Concurrent refreshes serialize and
reread the ledger. Play uses the captured validated session rather than silently
bootstrapping after identity validation. The ledger is finite and local to the
engine; restart/eviction still requires fresh detail.

All protocol requests check captured route/session ownership. A delayed old
home cannot publish after generation replacement or invalidate a newer session.
Malformed home data also invalidates its captured generation and enters the
same bounded cooldown. Singular cover messages merge their fields according to
protobuf semantics while scalar fields retain last-value behavior and strict
wire/bounds checks.

## Alternatives considered

A second registered engine would leave the real public facade unsupported.
An approval-only or test-only runtime constructor would not implement user
playback. Trusting caller-edited recipe JSON would lose selected-source identity.
A permanent bootstrap cache would retain changed domains/keys. Making every
selection expire at 60 seconds would break ordinary delayed play and next-episode
use. Automatic retry, account registration and fabricated mobile identity are
not substitutes for the public protocol.

## Verification boundaries

Five unchanged public-constructor loopback tests fail on the old implementation
at placeholder/privacy boundaries, then pass through the new facade, including
the actual CspProvider selected-episode bridge. Independent synthetic fixtures
inspect/decrypt actual HTTP requests and provide protobuf/crypto response data;
returned media is not fetched. They do not call a fake site in place of the
registered constructor. Additional negative and boundary cases cover source/
route changes, malformed fields, bounds, cloud links, missing flags, exact expiry
refresh and changed identities.

`app_drama_empty_page_tests.rs` exercises `CspProvider::new` and the registered
facade with independent literal protobuf envelopes. It observes zero-hit search,
an empty category, an exhausted page's reported pagination and ordinary items
afterward on the same session. Missing/empty data, unknown-only messages,
wrong-wire/negative totals and malformed rows retain error controls. The
independent inspector decrypts actual HTTP requests; exact request counts and
zero origin requests retain the application-proxy/no-fallback boundary. These
observations cover page mapping, not real-service catalog or playback acceptance.

Three additional state tests fail the first candidate on stale home success,
repeated malformed category requests and duplicate expired-selection refresh.
The guarded implementation is tested against those same schedules. Legacy
fixed-unavailable tests are migrated to real default-constructor import/restore,
user enable choices, direct/custom routing, gzip, transport/HTTP failures and
explicit redirect refusal with zero requests at the redirect target. Unknown
unregistered-class and configuration-preservation controls remain.

The initial full test compilation failed with LLVM out of memory, not a behavior
failure. Limiting package debug information and codegen concurrency allows
compilation without changing the dependency graph. A later fixture URL import
was corrected to the existing reqwest re-export. Final test results, release
build binding and native/service observations are recorded in the coordinating
implementation plan; synthetic success does not establish public source
availability, media decoding, frames or whole-goal acceptance.

## Consequences

The source now has executable catalog/search/detail/selection paths and its
manifest reflects implementation capability without rewriting saved enable
choices. Upstream denial, unsupported shares and invalid configuration still
surface as explicit errors. Real-service interoperability and exact native
playback remain separate delivery gates.


### Qualified local verification

The final AppDrama-filtered run passes 60 tests with zero failures and the one
pre-existing ignored live diagnostic. Provider integration passes 47 tests,
CSP registry tests pass ten, and TVBox tests pass 24. These filters overlap;
their counts are not summed as unique coverage. The final restored-list check
uses the actual list_providers flat presentation (hidden=false), preserving
the user-requested top-level sources; an intermediate migrated fixture's
aggregate-only hidden=true assumption failed and was corrected against that
owning production command, without altering production presentation.

Proxy/stream-proxy related tests pass 63 cases with three existing ignored
diagnostics. All executed affected filters pass; skipped diagnostics are not
claimed as verified.
