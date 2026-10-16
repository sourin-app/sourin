# 平台支持

> 本文原为根 [README.md](../README.md) 的「平台支持」一节，2026-10-15 拆分到 `docs/`，正文未改写。
> 文档地图见 [docs/README.md](README.md)；开发硬约束见 [docs/AGENTS.md](AGENTS.md)；
> 提交与评审纪律见 [CONTRIBUTING.md](../CONTRIBUTING.md)。

---

# 平台支持

| 平台 | 状态 | 说明 |
|---|---|---|
| **Windows 10/11** | ✅ 完整 | 主开发与交付平台 |
| **Android 手机/平板** | ✅ 完整 | arm64 / armv7 / x86_64 |
| **Android TV** | ✅ 完整 | 与手机**同一个 APK**，见下 |
| **macOS** | ✅ 可构建 | 见下（有已知差异） |
| **Linux** | ⚠️ 未适配 | 缺 `linux/` 壳，依赖本身支持 |

## Android TV

**TV 不需要单独的构建** —— 同一个 APK 装上手机是手机版，装上电视是 TV 版：

```text
AndroidManifest.xml 同时声明：
  android.intent.category.LAUNCHER           → 手机/平板桌面图标
  android.intent.category.LEANBACK_LAUNCHER  → Android TV 主界面
  uses-feature android.software.leanback     required=false
  uses-feature android.hardware.touchscreen  required=false  ← 关键
```

> ⚠️ `touchscreen required=false` **不能漏**：电视没有触摸屏，不声明的话
> 应用商店会认为 TV 不兼容。而 `LEANBACK_LAUNCHER` 不能漏是因为——
> **APK 能装到 TV 上，但电视的启动器里根本看不到它**，用户装完找不到应用，
> 等于没装。（实测确认：`aapt dump badging` 里会出现 `leanback-launchable-activity`。）

运行时靠平台通道读系统 feature 判定设备类型（`MainActivity.kt` 的 `sourin/device`）：

```text
leanback          → 设备声明自己是 TV（有遥控器）
touchscreen       → 有没有触摸屏
leanbackOnly      → android.software.leanback_only
```

⇒ UI 自动切 TV 形态：整套字号放大（`AppMetrics.textScaleFor`）、
焦点用方向键移动（`spatial_nav.dart`）、播放器让方向键给选集面板。

构建时`--target-platform` 只影响 CPU 架构，**不影响** TV 能力：

```bash
flutter build apk --release --target-platform android-arm64 -t lib/shell.dart   # 现代电视盒子
flutter build apk --release --target-platform android-armv7 -t lib/shell.dart   # 32 位老盒子
```

## macOS

macOS 是**后加的**平台，可以构建、可以跑，但有两点如实说明的差异：

| | 现状 | 原因 |
|---|---|---|
| **标题栏** | 用系统标题栏，不自绘 | macOS 的红黄绿交通灯是系统约定，自绘会与那 40px 的栏重叠；产品代码里 `kIsDesktop` 包含 macOS，`_CustomTitleBar` 会照画，所以留着系统栏至少保证有可拖动/可关闭的入口 |
| **窗口几何记忆** | 可用 | `window_manager` + `screen_retriever` 都支持 macOS |
| **托盘** | 可用 | `tray_manager` 支持 macOS |
| **字体** | 自动用系统字体 | 主题里按平台选字族：Windows 用雅黑、其它端用 `Noto Sans CJK SC`。macOS 上系统会回退到苹方 —— 这正是「不内置苹果字体」那条约定的收益 |

### macOS 的权限声明（`*.entitlements`）

**这是 macOS 上最容易踩的坑**。macOS 默认把应用关进 App Sandbox，
没有声明就没有权限 —— 而且症状很有迷惑性：

```text
只声明 network.server  → 应用能启动、界面正常，但一播放就报「无法连接」
                         因为出站请求（拉 m3u8）被沙箱拦了，
                         而入站（本地流代理监听）是通的
```

所以两个 entitlements 文件里都必须有这五项（`DebugProfile` 与 `Release` **同步**）：

```text
app-sandbox                                   沙箱本身（保持开启）
cs.allow-jit                                  Flutter 引擎的 Dart VM
network.client        ★ 出站：拉流 / 插件 HTTP / WebDAV / 弹幕
network.server        ★ 入站：核心层的本地流代理要监听 127.0.0.1
files.user-selected.read-write  外挂字幕 / 导入备份
assets.movies.read-write        整片下载默认落在「视频 / 源影」
```

> ⚠️ **只改一个文件会得到「开发时好的、打包后坏的」** —— 最难查的那类。
> CI 里有一步专门用 `codesign -d --entitlements` 核验产物真的带上了这两项。

### 构建 macOS

```bash
cd rust/sourin_core && cargo build --release && cd ../..
flutter build macos --release -t lib/shell.dart
# 产物：build/macos/Build/Products/Release/sourin_spike.app
```

> ⚠️ macOS 上 Rust 核心编出的是 `libsourin_core.dylib`，由 `macos/` 的
> Xcode 工程里那个 `Embed Rust Core` 构建阶段拷进
> `sourin_spike.app/Contents/Frameworks/`（与 Windows 的 CMake 拷贝是同一角色）。
> **改完 `ffi.rs` 同样要重编** —— 症状是 `Failed to lookup symbol`。
>
> 这个阶段是**后加的**（2026-10-08）。在那之前 `macos/` 整棵树对
> `sourin_core` **零引用**，产物里根本没有这个 dylib，而 Dart 侧
> `DynamicLibrary.open('libsourin_core.dylib')` 用的是裸文件名 ——
> dlopen 走的是 dyld 搜索路径，**不会**去 `Contents/Frameworks/` 里翻
> （那个目录只对二进制里带 LC_RPATH 的调用方生效，管不到 dart:ffi）。
> 症状是 macOS 版**能启动但所有核心功能不可用**，只剩一个错误页。
> 所以 `lib/core/ffi.dart` 现在先按**包内绝对路径**找，找不到才退回裸名。

> ⚠️ `PRODUCT_NAME` 必须是 ASCII 的 `sourin_spike`：
> `project.pbxproj` 里有 3 处硬引用 `sourin_spike.app`，改中文会让产物名与引用名对不上。
> 用户看到的窗口标题由 Dart 侧的 `WindowOptions(title: '源影')` 决定，与它无关。
