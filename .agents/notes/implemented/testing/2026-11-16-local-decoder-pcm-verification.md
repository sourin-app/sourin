# Agent Note: Bound local decoder PCM verification

Status: implemented

Related: [JS ownership and bounded playback verification](../bug-fix/2026-11-15-js-mutation-ownership.md).

The [fresh selected-source media verification](2026-11-17-current-source-media-decoder-verification.md)
extends amplitude observation to original core-forwarded current media.

## Problem

An advancing audio clock, a selected codec and nonzero player volume do not prove that decoded samples have nonzero amplitude. Capturing the default system output can include unrelated audio sessions and does not satisfy isolated verification.

## Decision

Verify a bounded retained anonymous MPEG-TS sample with the exact packaged libmpv in a new owned process. Before opening the file, disable configuration, scripts, video and external tracks, restrict protocols to local files, select only the PCM output driver with no fallback, request signed 16-bit stereo at 44100 Hz, set volume zero and pause, and bind a fresh output file and a three-second media limit.

Confirm the paused decoder has actually initialized the PCM driver and the fresh file before setting the independent decoder volume. Run a zero-volume negative control and a nonzero-volume positive control against the same encoded input. Check C API return codes, actual loaded DLL identity, option readbacks, decoded/output formats, natural end-of-file, normal destruction, unchanged inputs, exact owned process exit and at least eight seconds of empty Job membership.

After normal destruction rewrites the WAV header, validate RIFF chunk boundaries, PCM subtype, channels, sample rate, alignment, complete frames and bounded duration. Compute amplitude from the data samples. Independently read the same output with the standard-library WAV parser and recompute amplitude. A completed process alone does not accept the sample gate.

## Alternatives considered

- Audio timestamps or volume alone: they do not measure sample amplitude.
- Default endpoint loopback: unrelated sessions may be included.
- A synthetic signal alone: it does not verify decoding the retained encoded media.
- Changing the existing player output: it changes the route being observed and risks emitting device audio.

## Consequences

The actual control pair outputs 132299 stereo frames per control, about three seconds. The muted control has zero nonzero samples; the positive control has 264483 nonzero samples among 264598 samples. Per-channel normalized RMS is 0.0506358 and 0.0495964; peak is 0.2774353 and 0.2875061. Both processes exit zero, drain naturally for more than eight seconds and require no forced cleanup. The packaged libmpv bytes and local encoded input remain unchanged.

This accepts the bounded independent decoder PCM route. The output is converted from AAC float planar audio to signed 16-bit PCM. It is not a tap of the previously observed PlayerPage instance, device PCM, system recording or proof of audible speaker output. Those claims remain separate. Revalidate if the decoder library, encoded input, output driver or sample gate changes. Runtime scripts, raw receipts, outputs and the second-parser audit remain in the task probe directory.
