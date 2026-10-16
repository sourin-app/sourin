# 架构

> 本文原为根 [README.md](../README.md) 的「架构」一节，2026-10-15 拆分到 `docs/`，正文未改写。
> 文档地图见 [docs/README.md](README.md)；开发硬约束见 [docs/AGENTS.md](AGENTS.md)；
> 提交与评审纪律见 [CONTRIBUTING.md](../CONTRIBUTING.md)。

---

# 架构

```text
┌───────────────────────────────────────────────────────────────┐
│  Flutter (Dart)              lib/                              │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │  shell.dart        自绘标题栏 / 5 个 tab / 保活 Stack    │  │
│  │  ui/player_page   播放页（控制条 / 弹幕 / 手势 / 浮层）  │  │
│  │  ui/detail_page   详情页（剧集 / 换源 / 下载）           │  │
│  │  ui/live_page     直播页（频道 / EPG / 内嵌播放器）      │  │
│  │  ui/settings_page 设置（源 / 代理 / 同步 / 关于）        │  │
│  │  core/            FFI 绑定、API 封装、偏好、下载器       │  │
│  └─────────────────────────────────────────────────────────┘  │
└──────────────────────────┬────────────────────────────────────┘
                           │  dart:ffi（直接函数调用，无 IPC）
┌──────────────────────────▼────────────────────────────────────┐
│  Rust 核心 (cdylib)          rust/sourin_core/                 │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │  ffi.rs            C ABI 导出（7 个符号）                │  │
│  │  registry.rs       源注册表（内置 / 插件 / 声明式 / HTTP）│  │
│  │  plugins/mod.rs    QuickJS 插件沙箱（host.* API）        │  │
│  │  streamproxy.rs    本地流代理（防盗链 / 地址改写 / 预取） │  │
│  │  store.rs          SQLite（收藏 / 历史 / 进度 / 片头片尾）│  │
│  │  tvbox.rs          TVBox 配置解析（不生成 JS）           │  │
│  │  sync/             WebDAV 云同步                         │  │
│  │  remote/           手机遥控（局域网 HTTP 服务）           │  │
│  └─────────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────────┘
```

## 为什么业务逻辑放 Rust

```text
① 复用       原版 Tauri 的 Rust 业务代码 81% 可以原样搬过来，只改掉 Tauri 引用
② 性能       插件沙箱（QuickJS）、SQLite、HTTP 代理都在原生侧，Dart 侧零开销
③ 跨端       同一份 .rs 编出 Windows 的 .dll 和 Android 的三个 .so
④ 可测       cargo test 直接测业务逻辑，不需要起 UI
```

## FFI 契约

Rust 侧只导出 **7 个符号**（`rust/sourin_core/src/ffi.rs`）：

```text
sourin_core_version()     版本号
sourin_start(json)        启动核心（数据目录等）
sourin_call(json)         同步调用一个命令
sourin_call_async(json)   异步调用（阻塞池）
sourin_call_stream(json)  流式调用（边算边回，搜索用这个）
sourin_cancel_stream(id)  取消一条流
sourin_free(ptr)          释放返回的字符串
```

> ⚠️ **实现约束**（踩过坑）：`sourin_call_async` 走 `spawn_blocking` → `dispatch_blocking`，
> 绝不能在 `runtime().spawn()` 的 worker 里直接 `block_on` —— 会饿死线程池，
> 实测 8 个并发调用**全部** 120 秒超时。
