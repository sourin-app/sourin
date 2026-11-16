#!/usr/bin/env python3
"""Read-only verification of the pinned Miuix source snapshot and pinned patches.

No SDK, package cache, network, compiler or generated files are used. An optional
source archive proves the complete included/excluded inventory against pub.dev.
"""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import sys
import tarfile


ARCHIVE_SHA256 = '79557980f191131888dd6b164d460d03a70e9cae1cbce9799046942ef4719513'
MANIFEST_SHA256 = '4269ccbbb61ba6d30f793bef803a4eefa41215dd6a3670ccac834e96e5f2e42c'
ORIGINAL_SHA256 = '5f673ae1719985353553ae3f87adf9ba4cab038727b46604bb8d2a599659f614'
CANDIDATE_SHA256 = 'f4b24691e8ada44e9eb6c5fc80a5793872648de9fc2aae3c3880fcd0f3c117fa'
PATCHED_SHA256 = 'fde7a5bca61710685991acfb3fc164aca1ea0449ba763c1d3c899242ee308667'
PATCH_SHA256 = '0185cbf1647403909cbbb8f45471adf71c11f0297d042142c159f3f2a692a76f'
GLASS = 'shaders/miuix_os4_glass.frag'
PATCH = 'patches/0001-impeller-material-loop.patch'
LOADER = 'lib/src/theme/miuix/components/miuix_glass.dart'
LOADER_PATCH = 'patches/0002-demand-glass-background-programs.patch'
LOADER_ORIGINAL_SHA256 = 'df4165dcfb55504c3c051ae285e5fa73473187af9434274c4c8e79cdeefe681a'
LOADER_PATCHED_SHA256 = '510d20904691f3bb1530af0f3320f9bf35471e9b4a948657fdf696d00129c438'
LOADER_PATCH_SHA256 = '67da828cdfe8bb2771111133af3014cc6a85647fae121e7f5774f8ab556c2d38'
TEXT_FIELD = 'lib/src/theme/miuix/components/miuix_textfield.dart'
TEXT_FIELD_PATCH = 'patches/0003-text-field-focus-semantics.patch'
TEXT_FIELD_ORIGINAL_SHA256 = 'fdff76549dbb0120fa150080f1a7dee46121613a5e728c8c5cd831c95d02491a'
TEXT_FIELD_PATCHED_SHA256 = 'f81b2a374555537e667b680b976e4bd9ec640025720c6009608cacb942baa008'
TEXT_FIELD_PATCH_SHA256 = 'ac4bdf3f1a1702df6d52ab9d3dc06f18535e3668d19e4f3a03afc25a563ee9f3'
ADDITIONS = {'UPSTREAM_FILES.json', 'SOURIN_PATCH.json', 'SOURIN_PATCHES.md', PATCH, LOADER_PATCH, TEXT_FIELD_PATCH}
SHADERS = {
    'miuix_bloom_stroke.frag', 'miuix_os4_glass.frag', 'miuix_os4_mask.frag',
    'miuix_os4_stroke.frag', 'miuix_os4_shadow.frag', 'miuix_os4_rim.frag',
    'miuix_os4_blend.frag',
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def safe_path(value):
    path = PurePosixPath(value)
    require(value and not path.is_absolute() and '..' not in path.parts
            and '\\' not in value and ':' not in value and str(path) == value,
            f'Noncanonical relative path: {value!r}')
    return path


def apply_patch_bytes(source, patch, *, reverse=False, target=GLASS):
    """Apply this one-file unified patch exactly, preserving mixed line endings."""
    lines = patch.splitlines(keepends=True)
    require(lines[:2] == [f'--- a/{target}\n'.encode(), f'+++ b/{target}\n'.encode()],
            'Patch must target only its pinned upstream file.')
    source_lines = source.splitlines(keepends=True)
    result = []
    cursor = 0
    index = 2
    hunks = 0
    while index < len(lines):
        match = re.fullmatch(rb'@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@[^\r\n]*\n',
                             lines[index])
        require(match is not None, 'Invalid or additional-file patch header.')
        old_start, old_count, new_start, new_count = (
            int(value) if value is not None else 1 for value in match.groups()
        )
        if reverse:
            old_start, new_start = new_start, old_start
            old_count, new_count = new_count, old_count
        source_start = old_start - (1 if old_count else 0)
        output_start = new_start - (1 if new_count else 0)
        require(cursor <= source_start <= len(source_lines), 'Overlapping patch hunks.')
        result.extend(source_lines[cursor:source_start])
        cursor = source_start
        require(len(result) == output_start, 'Patch output offset mismatch.')
        index += 1
        old_used = new_used = 0
        while index < len(lines) and not lines[index].startswith(b'@@ '):
            operation, data = lines[index][:1], lines[index][1:]
            require(operation in (b' ', b'+', b'-'), 'Unsupported unified patch line.')
            if reverse and operation != b' ':
                operation = b'-' if operation == b'+' else b'+'
            if operation in (b' ', b'-'):
                require(cursor < len(source_lines) and source_lines[cursor] == data,
                        f'Patch context differs at source line {cursor + 1}.')
                cursor += 1
                old_used += 1
            if operation in (b' ', b'+'):
                result.append(data)
                new_used += 1
            index += 1
        require((old_used, new_used) == (old_count, new_count), 'Patch hunk count mismatch.')
        hunks += 1
    require(hunks > 0, 'Patch is empty.')
    result.extend(source_lines[cursor:])
    return b''.join(result)


def verify_archive(archive_path, manifest):
    require(sha256(archive_path.read_bytes()) == ARCHIVE_SHA256,
            'Source archive SHA-256 differs from the pinned release.')
    expected = {entry['path']: entry
                for entry in manifest['includedFiles'] + manifest['excludedFiles']}
    seen = set()
    with tarfile.open(archive_path, 'r:gz') as archive:
        for member in archive.getmembers():
            safe_path(member.name.rstrip('/'))
            if member.isdir():
                continue
            require(member.isfile() and member.name not in seen,
                    f'Unsupported or duplicate source archive entry: {member.name}')
            require(member.name in expected, f'Unrecorded archive entry: {member.name}')
            seen.add(member.name)
            data = archive.extractfile(member).read()
            entry = expected[member.name]
            require(len(data) == entry['size'] and sha256(data) == entry['sha256'],
                    f'Archive file differs from manifest: {member.name}')
    require(seen == set(expected), 'Source archive inventory is incomplete.')


def verify(vendor_root, archive_path=None):
    require(vendor_root.is_dir() and not vendor_root.is_symlink(),
            'Vendor root must be an independent directory.')
    manifest_bytes = (vendor_root / 'UPSTREAM_FILES.json').read_bytes()
    require(sha256(manifest_bytes) == MANIFEST_SHA256, 'Upstream manifest hash differs.')
    manifest = json.loads(manifest_bytes)
    metadata = json.loads((vendor_root / 'SOURIN_PATCH.json').read_bytes())
    require((manifest['schemaVersion'], manifest['package'], manifest['version'])
            == (1, 'flutter_miuix', '1.3.0'), 'Unexpected upstream package identity.')
    require(manifest['archiveSha256'] == ARCHIVE_SHA256, 'Unexpected archive identity.')
    require(manifest['excludedTopLevelDirectories'] == ['example'],
            'Only the upstream example directory may be excluded.')
    included = {entry['path']: entry for entry in manifest['includedFiles']}
    require(len(included) == len(manifest['includedFiles']) == 136,
            'Unexpected included upstream inventory.')
    require(len(manifest['excludedFiles']) == 22 and all(
        entry['path'].startswith('example/') for entry in manifest['excludedFiles']),
        'Unexpected excluded upstream inventory.')
    expected_paths = set(included) | ADDITIONS
    actual_paths = set()
    for path in vendor_root.rglob('*'):
        require(not path.is_symlink(), f'Vendor must not use links: {path}')
        if path.is_file():
            actual_paths.add(path.relative_to(vendor_root).as_posix())
    require(actual_paths == expected_paths,
            f'Vendor file inventory differs; missing={sorted(expected_paths - actual_paths)}, '
            f'extra={sorted(actual_paths - expected_paths)}')
    for path, entry in included.items():
        safe_path(path)
        if path in (GLASS, LOADER, TEXT_FIELD):
            continue
        data = (vendor_root / path).read_bytes()
        require(len(data) == entry['size'] and sha256(data) == entry['sha256'],
                f'Upstream file changed: {path}')
    require({PurePosixPath(path).name for path in included if path.startswith('shaders/')}
            == SHADERS, 'The full seven-shader set is required.')
    pubspec = (vendor_root / 'pubspec.yaml').read_text(encoding='utf-8')
    declared = set(re.findall(r'^\s+- shaders/([^\s]+)\s*$', pubspec, re.MULTILINE))
    require(declared == SHADERS, 'Package shader declarations differ from the complete set.')
    require(metadata['schemaVersion'] == 1 and metadata['modifiedFiles'] == [GLASS, LOADER, TEXT_FIELD],
            'Only the three pinned shader, loader and input patches may differ upstream.')
    require(metadata['upstreamManifestSha256'] == MANIFEST_SHA256,
            'Patch metadata does not bind the upstream manifest.')
    require(metadata['patchFile'] == PATCH and metadata['patchSha256'] == PATCH_SHA256,
            'Patch metadata differs from the unique pinned patch.')
    require((metadata['upstreamSha256'], metadata['compare2CandidateSha256'],
             metadata['patchedSha256']) == (ORIGINAL_SHA256, CANDIDATE_SHA256, PATCHED_SHA256),
            'Patch metadata shader identities differ.')
    patch = (vendor_root / PATCH).read_bytes()
    require(sha256(patch) == PATCH_SHA256, 'Unique patch hash differs.')
    patched = (vendor_root / GLASS).read_bytes()
    require(sha256(patched) == PATCHED_SHA256, 'Patched shader hash differs.')
    annotation = metadata['downstreamAnnotation'].encode('utf-8')
    require(annotation and patched.count(annotation) == 1,
            'Expected exactly one explicit downstream modification notice.')
    require(sha256(patched.replace(annotation, b'', 1)) == CANDIDATE_SHA256,
            'Shader differs from the frozen candidate plus its modification notice.')
    original = apply_patch_bytes(patched, patch, reverse=True)
    require(sha256(original) == ORIGINAL_SHA256 == included[GLASS]['sha256']
            and len(original) == included[GLASS]['size'],
            'Reversed patch does not reconstruct the exact upstream shader.')
    require(apply_patch_bytes(original, patch) == patched,
            'Replayed patch does not reconstruct the exact downstream shader.')
    uniforms = lambda data: re.findall(rb'^uniform [^\r\n]+;', data, re.MULTILINE)
    require(uniforms(original) == uniforms(patched), 'Shader uniform ABI changed.')
    require(b'#if defined(SKIA_GRAPHICS_BACKEND)' in patched,
            'The original Skia branch must remain available.')
    loading = metadata['surfaceLoadingPatch']
    require((loading['file'], loading['upstreamSha256'], loading['patchedSha256'],
             loading['patchFile'], loading['patchSha256']) ==
            (LOADER, LOADER_ORIGINAL_SHA256, LOADER_PATCHED_SHA256,
             LOADER_PATCH, LOADER_PATCH_SHA256), 'Demand-loader metadata differs.')
    loader_patch = (vendor_root / LOADER_PATCH).read_bytes()
    loader_patched = (vendor_root / LOADER).read_bytes()
    require(sha256(loader_patch) == LOADER_PATCH_SHA256, 'Demand-loader patch hash differs.')
    require(sha256(loader_patched) == LOADER_PATCHED_SHA256, 'Demand-loader source hash differs.')
    loader_original = apply_patch_bytes(loader_patched, loader_patch, reverse=True, target=LOADER)
    require(sha256(loader_original) == LOADER_ORIGINAL_SHA256 == included[LOADER]['sha256']
            and len(loader_original) == included[LOADER]['size'],
            'Demand-loader reverse patch does not reconstruct the exact upstream file.')
    require(apply_patch_bytes(loader_original, loader_patch, target=LOADER) == loader_patched,
            'Demand-loader replay does not reconstruct the exact downstream file.')
    text_field = metadata['textFieldSemanticsPatch']
    require((text_field['file'], text_field['upstreamSha256'], text_field['patchedSha256'],
             text_field['patchFile'], text_field['patchSha256']) ==
            (TEXT_FIELD, TEXT_FIELD_ORIGINAL_SHA256, TEXT_FIELD_PATCHED_SHA256,
             TEXT_FIELD_PATCH, TEXT_FIELD_PATCH_SHA256), 'Text-field metadata differs.')
    text_field_patch = (vendor_root / TEXT_FIELD_PATCH).read_bytes()
    text_field_patched = (vendor_root / TEXT_FIELD).read_bytes()
    require(sha256(text_field_patch) == TEXT_FIELD_PATCH_SHA256, 'Text-field patch hash differs.')
    require(sha256(text_field_patched) == TEXT_FIELD_PATCHED_SHA256, 'Text-field source hash differs.')
    text_field_original = apply_patch_bytes(text_field_patched, text_field_patch, reverse=True, target=TEXT_FIELD)
    require(sha256(text_field_original) == TEXT_FIELD_ORIGINAL_SHA256 == included[TEXT_FIELD]['sha256']
            and len(text_field_original) == included[TEXT_FIELD]['size'],
            'Text-field reverse patch does not reconstruct the exact upstream file.')
    require(apply_patch_bytes(text_field_original, text_field_patch, target=TEXT_FIELD) == text_field_patched,
            'Text-field replay does not reconstruct the exact downstream file.')
    if archive_path is not None:
        verify_archive(archive_path, manifest)
    return {
        'verified': True,
        'package': 'flutter_miuix',
        'version': '1.3.0',
        'vendorFiles': len(actual_paths),
        'upstreamFiles': len(included),
        'unchangedUpstreamFiles': len(included) - 3,
        'shaderFiles': len(SHADERS),
        'archiveVerified': archive_path is not None,
        'archiveSha256': ARCHIVE_SHA256,
        'manifestSha256': MANIFEST_SHA256,
        'patchSha256': PATCH_SHA256,
        'originalShaderSha256': ORIGINAL_SHA256,
        'compare2CandidateSha256': CANDIDATE_SHA256,
        'patchedShaderSha256': PATCHED_SHA256,
        'exactPatchRoundTrip': True,
        'loaderPatchedSha256': LOADER_PATCHED_SHA256,
        'loaderPatchSha256': LOADER_PATCH_SHA256,
        'exactLoaderPatchRoundTrip': True,
        'textFieldPatchedSha256': TEXT_FIELD_PATCHED_SHA256,
        'textFieldPatchSha256': TEXT_FIELD_PATCH_SHA256,
        'exactTextFieldPatchRoundTrip': True,
        'runtimeValidation': 'Not performed by this read-only source verifier.',
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--vendor-root', type=Path,
                        default=Path(__file__).resolve().parents[1] / 'third_party/flutter_miuix')
    parser.add_argument('--archive', type=Path,
                        help='Optional original flutter_miuix-1.3.0.tar.gz release archive.')
    args = parser.parse_args()
    try:
        result = verify(args.vendor_root, args.archive)
    except (OSError, ValueError, KeyError, TypeError, tarfile.TarError) as error:
        print(f'Miuix vendor verification failed: {error}', file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
