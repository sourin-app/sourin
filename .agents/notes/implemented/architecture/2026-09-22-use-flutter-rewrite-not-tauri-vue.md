# Agent Note: 用 Flutter 重写，而不是继续修 Tauri + Vue 版

Status: implemented

## Problem

Tauri 版跑在 WebView2 上、走 Media Foundation 解码，而 Windows 默认不注册 HEVC
解码器 MFT（实测 61 个 MFT 里零个 HEVC）。用户一遇到 HEVC 内容就黑屏，
而这恰恰是目标内容里最常见的一种编码。

问题不在应用层：无论怎么改前端代码，解码都要落到系统那条 MFT 链上。
只要平台没装对应解码器，播放就是黑的。

## Decision

整个客户端重写为 Flutter（UI）+ Rust（业务）双栈，取代最初的 Tauri + Vue 实现。
播放走 libmpv（自带完整 FFmpeg，完全不碰 Media Foundation）。

## Alternatives considered

- **在 Tauri 版里塞第三方解码器** —— 它最强的论据是改动面最小：保住已有的 Vue 界面
  与全部业务代码，只换解码路径。否决理由：解码仍要经过系统的媒体管线，
  等于在一条缺失能力的链上打补丁；而 libmpv 方案是**绕开**那条链，不是修补它。

- **让用户自己装 HEVC 扩展** —— 它最强的论据是零开发成本、由平台方维护解码器。
  否决理由：把运行前提转嫁给用户，装不上就是黑屏，且失败时应用无法给出可行动的提示。

## Consequences

- **收益**：从根上摆脱 Media Foundation 的 HEVC 缺失，解码能力随 libmpv 走，
  不再依赖用户机器上装了什么。
- **代价与已知上限**：整个 UI 层重写，Vue 代码不可复用（Rust 业务约 81% 可原样复用）；
  重写期间与原版的行为对齐只能靠交互契约文档兜住。
- **重访条件**：所有目标平台都自带可用的 HEVC 硬解与字幕/音轨处理能力，
  且 libmpv 在某个目标平台被证明不可用（许可证、商店政策、包体）。
