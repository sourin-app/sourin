# Agent Note: Package only the Windows runtime build inventory

Status: implemented

Applies from 2026-11-08.

Relations: extends [normal product entrypoint and data directory binding](2026-11-05-owner-package-data-directory-binding.md).
The entrypoint, define and approved core hash checks remain mandatory.

## Problem

The Release directory can contain data and browser caches created by earlier
launches. Recursively copying it packages unrelated runtime data; requiring a
clean package to match that entire directory rejects the correct deliverable.

Requiring a root native_assets.json also rejects a fresh current Windows build.
That file is a Flutter build intermediate; the bundle installs its bytes as
data/flutter_assets/NativeAssetsManifest.json.

## Decision

Packaging and verification share the CMake install manifest inventory, with the
runner executable and WebView loader added when not recorded there. Require
data/flutter_assets/NativeAssetsManifest.json among installed entries, including
when its native-assets map is empty. Do not require or import an unlisted root
native_assets.json. Reject empty manifests, missing required runtime files, paths outside
Release and known runtime-data roots. Create only a new package directory.
Verify its complete inventory and every file hash, the normal product entrypoint,
the absence of DATA_DIR_OVERRIDE and the explicitly supplied core hash.

## Alternatives considered

Deleting unknown Release contents would destroy evidence or unrelated data.
An extension whitelist could omit fonts, native assets and future plugins.
Copying the whole folder preserves stale caches. The build install manifest
already records installed runtime assets and is the narrower authoritative input.

## Consequences

Tests execute the real PowerShell assembler and verifier against synthetic builds
containing private-data decoys. They reject changed bytes, missing dependencies,
extra files, wrong targets, test defines, invalid core hashes and manifest escapes.
Hidden files also count toward the complete inventory. The install manifest is
decoded as UTF-8 explicitly, including under Windows PowerShell 5.1. Tests include
a hidden extra file, a real adjacent-directory escape and a Chinese asset path
read by the legacy shell.
Native-asset coverage uses the installed runtime path and rejects a missing
installation entry even when that file still exists on disk. It also rejects a
missing build file or changed/missing delivered manifest, and excludes an
unlisted root build intermediate. Assert these paths and bytes explicitly:
correct and incorrect synthetic shapes can have the same total file count.
Tests require Windows and PowerShell, matching the scripts' deployment platform.
Pure old-verifier comparison rejects the otherwise valid clean package because
the build directory contains additional runtime caches.

The guard binds to the supplied successful build and does not reverse-engineer
AOT code or establish native playback acceptance. New build-side runtime outputs
must be added when CMake cannot record them in its install manifest.
