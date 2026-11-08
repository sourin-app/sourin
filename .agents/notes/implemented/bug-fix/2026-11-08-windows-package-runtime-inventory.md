# Agent Note: Package only the Windows runtime build inventory

Status: implemented

Applies from 2026-11-08.

Relations: extends [normal product entrypoint and data directory binding](2026-11-05-owner-package-data-directory-binding.md).
The entrypoint, define and approved core hash checks remain mandatory.

## Problem

The Release directory can contain data and browser caches created by earlier
launches. Recursively copying it packages unrelated runtime data; requiring a
clean package to match that entire directory rejects the correct deliverable.

## Decision

Packaging and verification share the CMake install manifest inventory, with the
runner executable, WebView loader and native asset manifest added as build-side
outputs. Reject empty manifests, missing required runtime files, paths outside
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
Tests require Windows and PowerShell, matching the scripts' deployment platform.
Pure old-verifier comparison rejects the otherwise valid clean package because
the build directory contains additional runtime caches.

The guard binds to the supplied successful build and does not reverse-engineer
AOT code or establish native playback acceptance. New build-side runtime outputs
must be added when CMake cannot record them in its install manifest.
