# Agent Note: 设置页入口直达 + 提示统一到 showAppToast

Status: implemented

> 同域：[2026-10-18-three-broken-wirings-found-by-self-review.md](../bug-fix/2026-10-18-three-broken-wirings-found-by-self-review.md)
> 那篇发现「投屏日志的 onLog 生产环境从未接线」—— 属**同一类**问题：
> 提示机制存在但没被正确使用。本篇把 6 处遗留 SnackBar 收拢到 showAppToast，
> 是这条线的收尾；那篇是发现，本篇是统一。

## Problem

两个独立但都属于「用户找不到/看不到」的问题：

```text
① 配置入口不直达
   用户想改某个源的配置，要从设置页一级级点进去 ⇒
   Owner 反馈「配置入口直达可视化编排」。

② 提示散在两套机制里
   全仓还有 6 处遗留 SnackBar，与新统一的 showAppToast 并存。
   ⇒ 同一个产品里两种提示外观、两种消失时机、两种遮挡行为。
```

`SnackBar` 的额外问题（已在 `skip_marker_dialog.dart:1347-1400` 记录过真实事故）：

```text
`ScaffoldMessenger.maybeOf(context)?.showSnackBar(...)` 的 `?.` 形同虚设：
maybeOf 只保证 messenger 存在，不保证能显示
（showSnackBar 内部断言 `_scaffolds.isNotEmpty`）。
⇒ 2026-10-02 事故：一个 toast 抛异常把调用方的赋值吞掉 ⇒ 滑块卡死。
```

## Decision

### ① 配置入口直达

`1ed9ec3`（9 个文件）：从设置页直接进到可视化编排，不再逐级点。
同期补健康检测逐项进度。

### ② 6 处 `SnackBar` 全部换成 `showAppToast`

`d756d04`：

```text
约定：全仓只允许 showAppToast，不再出现 ScaffoldMessenger.showSnackBar
```

**关键设计点**（`app_toast.dart` 的注释里已写明）：
```text
· 不走 ScaffoldMessenger ⇒ 不依赖存在 Scaffold
· 找不到宿主时**静默 no-op**（不抛、不吞调用方的赋值）
· 时长不逐处传，单点定义 —— 否则 5 处各传不同值，又变成"五份样式"
```

## Alternatives considered

- **保留 SnackBar，只统一样式** —— 它最强的论据是改动面小，
  且 SnackBar 是 Material 提供的成熟实现。
  否决理由：本轮正在移除 Material。而且 `ScaffoldMessenger` 的两个问题
  （依赖 `_scaffolds.isNotEmpty`、异常会吞赋值）是机制层面的，样式统一治不了。

- **让 `showAppToast` 在找不到宿主时抛异常（而不是静默）** —— 它最强的论据是
  「静默失败」违反本仓的反静默原则，抛出来至少能被发现。
  否决理由：调用点常在深层回调里，抛出会打断用户正在做的操作（就是那次滑块卡死）。
  ⇒ 改为**写日志 + 静默**，让开发者能查到，而用户不被打断。

- **每处 toast 自己传时长** —— 它最强的论据是不同消息的重要性不同，
  重要的该留久一点。
  否决理由：实测会出现同一类消息在不同页面停留时间不同。
  ⇒ 时长单点定义；若某条确实需要更长，应在 `app_toast.dart` 里加一个具名档位，
  而不是调用点传裸数字。

## Consequences

- **收益**：提示外观/行为全仓一致；不会再出现「某个页面提示不显示」；
  滑块卡死那类事故的成因被消除。
- **代价**：静默 no-op 意味着「toast 没出来」在运行时不可见 ——
  只能靠日志。这是刻意的取舍（用户不被打断优先于开发者方便）。
- **判据**：`grep -c "showSnackBar" lib/` 应为 0。
- **重访条件**：当需要「必须被用户看到的提示」时（如凭据过期），
  不应复用 toast，而应走阻断式对话框。
