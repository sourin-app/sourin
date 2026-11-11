# Agent Note: YunDuo retains selected line, title and opaque playback value

Status: implemented

The [global CSP routing decision](../architecture/2026-11-09-csp-global-routing-retains-engine-recipes.md)
owns the adapter's HTTP policy. The
[selected-episode and real-line-switch decision](2026-11-04-selected-episode-parser-and-real-line-switch.md)
retains its App99, cloud-file and native/UI scope. This decision supplements
YunDuo's own detail-ID encoding and explicit-selection recognition.

## Problem

YunDuo's old detail ID concatenates line, display title and opaque playback value
with `|`. A pipe in the selected title becomes part of the value sent to the
decoder. A pipe in the selected line changes the parsed line and rejects the
selection before the decoder. The provider also needs to recognize this
adapter's explicit selected ID rather than sending it back through item detail.
Returning a media candidate alone does not establish selected-episode equality.

## Decision

Keep the existing detail-ID bytes when line and title contain no pipe. For the
ambiguous forms, use `yunduo:` plus URL-safe base64 of a three-string JSON tuple
containing line, title and opaque value. This is a tagged tuple with no version
field. The production parser accepts that tuple and the old pipe form, retaining
reserved bytes in the legacy opaque value. YunDuo's
`accepts_selected_episode_id` hook uses the same parser to recognize explicit
selection through the existing `CspProvider::resolve` path. The adapter retains
its existing request implementation and CspHttpContext policy.

The four regression assertions in
`rust/sourin_core/src/csp/yun_duo_identity_next_tests_v1.rs` exercise the real
detail/provider/decoder path against a local valid protocol fixture. They cover
a pipe in the selected title, a pipe in the selected line, ordinary detail-ID
bytes, and persisted legacy opaque-value bytes. The fixture returns a valid
decoder envelope even for wrong identity; the counterexamples fail on business
assertions instead of fixture transport failure.

## Alternatives considered

- **Keep the concatenation**: it preserves all old bytes, but the actual title
  and line counterexamples fail in the production parser/request path.
- **Escape only the title**: it addresses title/value ambiguity while leaving a
  pipe in the selected line ambiguous. The tuple carries all three fields.
- **Replace every detail ID**: one representation is simpler, but unnecessarily
  changes ordinary persisted IDs. Ordinary bytes remain a compatibility control.
- **Broaden the generic provider heuristic**: it avoids an adapter hook but
  gives unrelated CSP formats a new meaning. YunDuo's parser owns its recognition.

## Consequences

Line, title and opaque value have independent boundaries for ambiguous detail
IDs. Ordinary and legacy values retain their existing bytes. The additional
tagged form remains adapter-specific; it does not change account, cloud-file,
generic provider or routing contracts. The
[AppDrama protocol decision](../feature/2026-11-11-app-drama-public-protocol.md)
owns a different versioned opaque ledger and does not define this tuple.

The local fixtures prove selected identity under the specified legal inputs.
The public observation proves anonymous catalog access and a decoded media
candidate in that run. Neither establishes a current upstream pipe collision,
a user-specified episode's live outbound equality, fetched media bytes, native
first frame, playback progress, line-switch interaction, Owner acceptance or a
correctly bound formal package. `external_playback_restored` remains false.

## Verification

Actual C16 pair:
`.probe/source/next-yunduo-selected-identity-run-v2/pair-yunduo-c16-v2.json`, SHA256
`1738D3E450BCF328091A7391CE433015B1C0EF1FA18B6B7E7FBE5F982C6AE2C8`.
Baseline runtime completes two business-assertion failures and two positive
controls, with zero ignored cases. Candidate runtime completes 4 passed,
0 failed, 0 ignored. Both original compile receipts retain forced cleanup after
the eight-second descendant-drain gate fails; their compiler Job gates remain
failed. Each accepted runtime uses the same newly compiled owning EXE as its
own original compile, exits without force or cleanup errors, drains normally,
and observes continuous Job zero for 8.02724 / 8.03234 seconds respectively.
The candidate owning EXE SHA256 is
`C855B6F8D0363E436F158202E38A9CBBB608CB9D011DFAA1A7524F2F715E4C3C`.

Existing owning compatibility:
`.probe/source/next-yunduo-selected-identity-actual-compat-v3/runs/yunduo-c16-existing-v3/result.json`,
SHA256 `DF3774BFD0C0EA0E2764CD5E44124EE69189B92EB46DDA492EE640E44DCF1893`.
The same actual candidate EXE completes all 23 named existing cases, with
0 failed and 0 ignored, no forced cleanup, no cleanup errors and 8.04257 seconds
of stable Job zero. This excludes the four new assertions and the sole live
case. The combined four/existing review is
`audit-yunduo-c16-v3-four-and-existing.json` in the same entry, SHA256
`8CC99DD33CB81080B25AB6B4279485BBE21B56431FA73529B4C239DFC25D8D55`.

Public anonymous observation:
`.probe/source/next-yunduo-public-boundary-run-v2/runs/yunduo-public-v2/result.json`,
SHA256 `0ADFE56B4275EAA2855E08967803DCA0EBB7177408F367FFA958ADC31D5DCDB8`.
The same EXE's exact ignored live case completes home/list/detail/search and
production play returns one media candidate, with no play error. Runtime and
API business qualifications are both true, with no forced cleanup, no cleanup
errors and 8.02943 seconds of stable Job zero. The case chooses the source's
first item and episode directly through YunDuo; it does not exercise a live
specified selection or the provider hook, fetch the media URL, or decode a frame.

All these actual runs retain the tested source SHA256
`B91B8CC2DF50A9D78256FBEFB11858522A606D3589AF65BFCB4C5DD62F2AE71A`.
The final source SHA256 is
`646BF1C40C1B2639FE6002E92B71B36FAD608AE62046B2080BAA35685BB37981`.
Its sole difference is line 227, `use a versioned JSON tuple` to
`use a tagged JSON tuple`; reversing that replacement reproduces the entire
tested source. Logic, tests and line endings remain identical. C16 is not
repeated for the comment correction; fresh release/package builds bind the final
source separately. The fixed test payload SHA256 is
`920AC75F56D2D81E09CE4A6EC8C554FDA2AD87B41CB25427C1FC3C0FD6BC7188`.
