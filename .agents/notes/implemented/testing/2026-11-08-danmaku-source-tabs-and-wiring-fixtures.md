# Agent Note: Danmaku source tests follow the current panel and constructor

Status: implemented

Applies to `zz_t66_r3_multi_source_test.dart`, `zz_t66_r3_wiring_test.dart`
and `zz_t66b_panel_glass_test.dart`, 2026-11-08.

This follows [player Miuix controls](../feature/2026-11-08-player-miuix-controls.md)
and the existing [source-contract guidance](2026-10-22-source-contract-gates-read-product-code.md).

## Problem

The remainder run reported 11 multi-source failures, three source-feed behavior
failures, one constructor-wiring failure and one panel tab-switch failure.
The behavior fixtures still clicked `高级`, although the current three-tab panel
renders source selection under `弹幕来源`.

The production constructor is returned by a `ValueListenableBuilder`, so the
old literal `child: DanmakuSettingsDialog(` anchor no longer identifies it.

## Decision

The behavior fixtures now click the actual `弹幕来源` tab. The multi-source
helper also requires the built-in source row before any merge assertion.
Summary reads are scoped to `danmaku-active-feed-summary`.

The wiring gate now requires exactly one uncommented constructor call,
tolerates whitespace before its opening parenthesis, and balances the call
while excluding quoted strings from the checked code. The feed argument must
still be the exact `_danmakuFeedSamples` expression, with only whitespace and
the argument delimiter following it. Missing, null or differently sourced
arguments do not satisfy the gate.

## Alternatives considered

- Change the constructor anchor to the current exact builder line: another
  formatting or wrapper change would break it without changing the contract.
- Search the whole file for the feed argument: an unrelated call or string
  could satisfy the gate after the real constructor lost its argument.
- Remove the failed source counts or deduplication assertions: that would
  discard the behavioral contracts instead of repairing the fixture.

## Consequences

The tests retain real row clicks and all existing source counts, removal,
deduplication, built-in immutability and missing-sample fallback assertions.
The panel test still requires visible source content after the real tab click.
No production behavior, exception handling or acceptance threshold changes.

This child lane performs isolated direct-Dart syntax formatting and scoped
diff validation only. The root task owns Flutter execution, analysis, builds
and native acceptance. No passing Flutter result is claimed in this note.
The constructor check is a bounded lexical source check, not full Dart AST
analysis or proof that the native player delivers source samples at runtime.
