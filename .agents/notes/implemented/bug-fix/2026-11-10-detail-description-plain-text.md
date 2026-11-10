# Agent Note: Detail descriptions project source HTML into plain text

Status: implemented

Applies from 2026-11-10 to the shared DetailPage information section.

Related: [player Miuix controls](../feature/2026-11-08-player-miuix-controls.md)
owns the existing detail controls and surfaces. [HTML homepage rendering](../feature/2026-10-31-webhome-html-homepage.md)
owns a separate optional document renderer. The note audit found no existing
owner for description markup projection. Neither decision is superseded; this
change renders only text and does not add an HTML view or dependency.

## Problem

A native playback screenshot showed paragraph/span tags and CSS attributes in
the right-hand introduction. Shared DetailPage decoded entities before passing
the source description to Text, but actual markup and script/style bodies were
still visible. Fixing a single provider would leave the same display defect for
other source descriptions and cached metadata.

## Decision

Apply one private presentation helper in the shared information section used by
embedded and standalone detail layouts. Keep MediaDetail, onLoaded values and
stored source descriptions unchanged. The existing two-line ellipsis stays.

Scan only a finite set of known HTML text, formatting and block tags, with
quoted-attribute awareness. Unknown tag-like text is retained literally rather
than treating every alphabetic name after an angle bracket as markup. Inline
tags lose only their markup; line and block boundaries create logical newlines.
Comments and entire script/style raw-text bodies are excluded. A closing angle
bracket inside an attribute cannot end a tag early, while plain comparisons such
as 1<2 and x<y && y>z remain text. An unterminated comment or raw-text element has
no visible body to recover; unrecognized tag-like text is retained.

Preserve text spacing and existing newlines. Whitespace between block tags does
not create extra blank lines, and block boundaries do not add leading/trailing
lines. Decode the existing entities only after actual markup has been removed.
Encoded literal tags and ampersand-escaped entities therefore receive one decode
and are not reparsed as markup. The existing entity helper's contract remains.

## Alternatives considered

A blanket angle-bracket regex mishandles quoted attributes, leaves raw-text
contents and loses paragraph boundaries. Source-specific subtitle/XML utilities
have different contracts and are the wrong dependency for shared UI. Importing
a transitive XML package would not supply an HTML fragment parser. An HTML
renderer or webview would add execution, resource loading and layout behavior
unnecessary for a plain introduction.

## Consequences

The actual DetailPage fixture initializes through the existing async transport
entry, then checks rendered Text and unchanged onLoaded metadata. Seven cases
cover styled paragraph/span markup, named/numeric entities, paragraph/line
boundaries, script/style/comments, quoted attributes, plain comparisons/spacing
and encoded literal tags, plus alphabetic comparisons and unknown tag-like text.
Root's initial qualified RED records four HTML failures and two passing
plain-text/single-decode controls. Review then reproduced the added seventh
case as a separate RED: the expected comparison/unknown-tag Text was absent.
That seven-case file stays fixed while the finite tag recognition is verified.

This is a bounded display projection, not full HTML rendering or a general DOM
parser. It does not follow URLs, apply CSS, execute scripts, change source data,
or add expansion controls. Root owns toolchain, related regressions and a fresh
native screenshot after rebuilding the frontend; no acceptance follows from
the helper's presence alone.


## Verification

Qualified pre-change RED: four HTML rendering cases fail and the two plain-text
and single-decode controls pass. The initial six-test file was unchanged for GREEN
(SHA256 2163faa3690717fccaeFB97e63174f30a7faf75346e7c17a97b31ad978755ffc).
The same cases and existing entity, right-detail line-switching and local-origin
metadata regressions pass together: 29/29, serial concurrency=1.
That result predates the finite-tag correction. The seventh comparison and
unknown-tag regression failed on the first helper, then remained frozen for the
correction (SHA256 24f1cd7fcd6a07ed8e90d8aa7a73cf03bfac45b61161d99361e29306da322825).
The frozen seventh case and final associated serial run pass: 30/30.
Final targeted analysis retains the same pre-existing info and no errors/warnings.
Targeted analysis reports zero errors/warnings and one pre-existing
curly_braces_in_flow_control_structures info in _isLocalCover, verified against
HEAD. The local-origin test cleanup retained an isolated temporary directory
because Windows still held a file; all behavioral assertions and test process
completed successfully. Native rendering confirmation remains separate.
