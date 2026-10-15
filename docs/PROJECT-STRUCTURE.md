# 项目结构

> 本文原为根 [README.md](../README.md) 的「项目结构」一节，2026-10-15 拆分到 `docs/`，正文未改写。
> 文档地图见 [docs/README.md](README.md)；开发硬约束见 [docs/AGENTS.md](AGENTS.md)；
> 提交与评审纪律见 [CONTRIBUTING.md](../CONTRIBUTING.md)。

---

# 项目结构

```text
sourin/
├── lib/                      Flutter 侧（约 172 个文件 / 约 17 万行）
│   ├── shell.dart            应用外壳：标题栏 / tab / 保活 / 窗口
│   ├── main.dart             ⚠️ 早期 HEVC 验收 spike，**不是产品入口**
│   ├── core/                 FFI 绑定、API、偏好、下载器、弹幕、字幕
│   │   ├── ffi.dart            Dart 侧 FFI 绑定
│   │   ├── sourin_api.dart     所有命令的 Dart 封装
│   │   ├── ui_prefs.dart       偏好读写
│   │   ├── clip_download.dart  片段下载 + 缓存淘汰
│   │   ├── hls_download.dart   HLS 整片下载（分片拼接）
│   │   ├── download_dir.dart   下载目录解析（按组存放）
│   │   ├── download_queue.dart 整片下载串行队列
│   │   ├── app_tray.dart       托盘 + 关闭确认
│   │   └── bili/ danmaku.dart  外部视频站与弹幕
│   └── ui/                   UI 页面与组件
│       ├── player_page.dart    播放页（最大单文件，约 91 万字节）
│       ├── detail_page.dart    详情页
│       ├── live_page.dart      直播页
│       ├── settings_page.dart  设置
│       ├── tokens.dart         设计令牌（间距 / 字号 / 字重 / 动效）
│       └── widgets/            复用组件
├── rust/sourin_core/         Rust 核心（src 约 29 个文件 / 约 4 万行）
│   ├── src/ffi.rs             C ABI 导出（7 个符号）
│   ├── src/registry.rs        源注册表
│   ├── src/plugins/mod.rs     QuickJS 插件沙箱
│   ├── src/streamproxy.rs     本地流代理
│   ├── src/store.rs           SQLite
│   ├── src/tvbox.rs           TVBox 配置解析
│   ├── src/sync/              WebDAV 云同步
│   ├── src/remote/            手机遥控
│   ├── plugins/*.js           内置插件（include_str! 编进二进制）
│   └── tests/                 21 个集成测试
├── test/                     Dart 测试（约 374 个文件 / 约 14 万行）
├── android/                  Android 壳 + jniLibs
├── windows/                  Windows 壳（含自绘窗口的 C++ 实现）
├── assets/                   托盘图标等资源
└── .github/workflows/        CI
```

> 上面的规模数字是**取数快照**（2026-10-15，commit 80617b8），只作量级参考。
> 取数命令：
> ```bash
> find lib -name "*.dart" | wc -l                        # lib 文件数
> find lib -name "*.dart" -exec cat {} + | wc -l         # lib 行数（test/ 同理）
> find rust/sourin_core/src -name "*.rs" | wc -l
> stat -c %s lib/ui/player_page.dart
> ```
> 数字过期是常态 —— 以命令读数为准，不要照抄本文。
