# Sourin patch to flutter_miuix 1.3.0

This directory contains the actual upstream Miuix Dart implementation and all
seven shaders, imported from the pub.dev 1.3.0 source release. The upstream
LICENSE, copyright / SPDX headers, README acknowledgements and package name /
version are retained. Two explicit patches change upstream code: the glass shader and its Dart loader.

`UPSTREAM_FILES.json` records every included and excluded release file, its raw
byte size and SHA-256, and the verified release archive hash. The 136 retained
files include the complete lib, shaders, test and upstream root documentation.
Only the 22 example files are omitted; the runtime pubspec and library do not
reference the example font, image or source. No SDK or pub-cache files are used
at build time for this package once the app resolves its local path dependency.

The shader patch is `patches/0001-impeller-material-loop.patch`. It retains the
original material block under SKIA_GRAPHICS_BACKEND and uses the validated
single-call-site loop on the other backend. Uniform order (53 float slots), the
sampler and wide-sampling loop are unchanged. All other shader bytes and all Dart bytes except the loader
match the upstream inventory. `SOURIN_PATCH.json` binds the original, compare2
candidate, downstream annotation, final shader, patch and manifest hashes.

The final shader equals the frozen compatible-loop candidate plus the explicit
two-line Sourin modification notice. The candidate has CRLF endings while the
upstream shader has mixed endings; the patch records those byte differences.
Preserve bytes at checkout (the root repository owns its .gitattributes rules).

From the repository root, verify without writing or running a toolchain:

```powershell
python tools/verify_miuix_vendor.py
python tools/verify_miuix_vendor.py --archive PATH/TO/flutter_miuix-1.3.0.tar.gz
```

The optional archive must have SHA-256
`79557980f191131888dd6b164d460d03a70e9cae1cbce9799046942ef4719513`.
The verifier checks all retained bytes, detects missing/extra files, reverses
and reapplies both patches exactly, reconstructs the original shader, and
checks the frozen candidate after removing only the modification notice. The
second pinned patch is independently reversed and replayed against the exact
original loader from that same upstream manifest. With
`--archive`, it also checks all 158 release entries against the source archive.
It performs no downloads and writes no files. Reconstructing from that archive
consists of copying only the included paths and applying both patches;
`git apply --directory=PATH/TO/NEW/PACKAGE patches/0001-impeller-material-loop.patch`
can be used from a directory containing the patch, with a fresh upstream copy. Apply `patches/0002-demand-glass-background-programs.patch`
the same way after the shader patch.

Parent-reported compare2 used task-local material assets: 24/24 cases had zero
pixel differences and the repetition / alpha positive controls passed. This
does not establish production-package rendering, Skia runtime acceptance or a
cold-start speedup. A fresh production build and runtime checks remain required.

For upgrades, obtain and verify the new explicit upstream release, rebuild the
inventory, rebase both patches, review loader/uniform changes and repeat
backend, pixel and startup validation. If upstream adopts the fix, remove this
patch and update the dependency source. To revert this revision, reverse both
pinned patches and update the patch metadata / dependency binding together.

## Background program demand loading

`patches/0002-demand-glass-background-programs.patch` changes only
`lib/src/theme/miuix/components/miuix_glass.dart`. A surface without a backdrop
cannot sample the `glass` or `blend` program, so it loads mask/stroke/shadow/rim.
A surface gaining a backdrop requests the full set while retaining already
loaded contours; the same State repaints after completion. Requests for the same
program share a Future, including failed attempts. Stale completions cannot
mark a changed or disposed State ready. Public `load()` and `isLoaded` retain
the full-set contract. Partial load failures keep per-program fallback and a
recorded error. Shader bytes, uniforms, style, sampling and draw paths are intact.

The app regression mounts the actual widget, verifies the background programs
are absent initially, adds a real image to the same State, verifies sampled
pixels and full loading, removes the background and verifies the original
pixels. Startup and native surface rendering must also be measured; the byte
verifier is not a performance or visual acceptance test.
