# Agent Note: 业务逻辑全放 Rust，Flutter 只做 UI，dart:ffi 直调

Status: implemented

## Problem

重写到 Flutter 后要决定业务逻辑落在哪一侧。两个约束同时成立：
原版已有大量 Rust 业务代码可复用；而插件沙箱、SQLite、HTTP 代理这类能力
在原生侧更成熟，搬到 Dart 要另找实现。

## Decision

数据源解析、插件沙箱、流代理、云同步、数据库都在 `rust/sourin_core`（cdylib），
两侧用 **dart:ffi 直接调用**，不经过任何 IPC 层。Rust 侧只导出 7 个符号，命令走 JSON。

## Alternatives considered

- **Dart 侧直写业务逻辑** —— 它最强的论据是生态统一：一处语言、一处调试，
  没有跨语言边界要维护。否决理由：要重写那 81% 已可复用的 Rust 代码，
  且沙箱与代理能力在 Dart 侧需要重新找实现。

- **本地 HTTP/WebSocket 服务做前后端分离** —— 它最强的论据是边界清晰：
  两侧可独立重启、可用普通 HTTP 工具调试。否决理由：多一层进程与端口，
  引入序列化开销、端口占用与鉴权面；而这些正是 FFI 想省掉的东西。

## Consequences

- **收益**：
  - 原版 Rust 业务约 81% 原样复用。
  - 沙箱 / SQLite / HTTP 代理留在原生侧，Dart 侧零调用开销。
  - 同一份 `.rs` 编出 Windows 的 `.dll` 与 Android 的三个 `.so`。
  - `cargo test` 直接测业务逻辑，不用起 UI。
- **代价与已知上限**：FFI 边界改一次要重编 cdylib 并手动拷贝；Android 三个 target
  的 `jniLibs/*/libsourin_core.so` 是手动拷贝产物，改过 `ffi.rs` 必须重编重拷，
  否则表现为「所有命令都超时」。跨语言调试比单语言贵。
- **重访条件**：FFI 边界成为主要开发瓶颈（例如每次改动都要重编 cdylib 并手动拷贝），
  或某目标平台禁止动态库加载。
