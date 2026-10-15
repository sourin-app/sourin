# 从源码构建

> 本文原为根 [README.md](../README.md) 的「从源码构建」一节，2026-10-15 拆分到 `docs/`，正文未改写。
> 文档地图见 [docs/README.md](README.md)；开发硬约束见 [docs/AGENTS.md](AGENTS.md)；
> 提交与评审纪律见 [CONTRIBUTING.md](../CONTRIBUTING.md)。

---

# 从源码构建

## 前置依赖

| 依赖 | 版本 | 说明 |
|---|---|---|
| Flutter | **3.47.5**（Dart 3.13.4） | 低于 3.47 编不过（用到了 `material_ui` 拆包后的 API） |
| Rust | **1.85+** | 核心是 edition 2021 |
| Visual Studio | 2022 + 「使用 C++ 的桌面开发」 | Windows 端编译 runner |
| Android SDK + NDK | NDK **27.0.12077973** | 只有编 Android 需要 |
| CMake | 3.14+ | 随 VS 安装 |

> **Android NDK 版本必须对齐** —— 仓库里的 `rust/sourin_core/.cargo/config.toml.example`
> 写死了三个 target 的 linker 路径（模板里是 `<NDK>` 占位符）。
> 用之前先 copy 一份并填上你本机的 NDK 路径：
>
> ```powershell
> Copy-Item rust/sourin_core/.cargo/config.toml.example rust/sourin_core/.cargo/config.toml
> # 然后把 <NDK> 换成 C:/Users/<你>/AppData/Local/Android/Sdk/ndk/27.0.12077973
> ```
>
> ⚠️ `.cargo/config.toml` 本身**不在仓库里**（含本机绝对路径），只有 `.example` 进库。

## 1. 拉代码 + 装依赖

```bash
git clone https://github.com/sourin-app/sourin.git
cd sourin
flutter pub get
```

## 2. 编 Rust 核心

```bash
cd rust/sourin_core
cargo build --release
cd ../..
```

产物在 `rust/sourin_core/target/release/sourin_core.dll`（Windows）或
`libsourin_core.so`（Linux / Android）。

## 3. 把核心放进构建目录

```powershell
# Windows
Copy-Item rust\sourin_core\target\release\sourin_core.dll windows\
```

`windows/CMakeLists.txt` 会在构建时把它拷到 runner 目录。

> ⚠️ **`.dll` 必须真的重新编出来。** `cargo build --release` 在源码没改动时会
> 直接跳过，`mtime` 保持不变；此时若你只是把一个**旧的** `.dll` 拷回
> `rust/sourin_core/target/release/`，构建会把那个旧件原样装进包 ——
> 症状是「改了 Rust 但行为没变」。**改完核心请核 `sourin_core.dll` 的哈希或
> `mtime` 确实变了**。（`windows/CMakeLists.txt` 用的是 `install(FILES ...)`，
> 它会无条件复制源件，不按时间戳判断；需要强制刷新时直接删掉包目录里的那个 `.dll`。）

## 4. 编 Flutter

```bash
# Windows（注意 -t：入口是 shell.dart 不是 main.dart）
flutter build windows --release -t lib/shell.dart

# Android
flutter build apk --release --target-platform android-arm64
```

> ⚠️ **`-t lib/shell.dart` 不能漏**。`lib/main.dart` 是一个早期的 HEVC 验收 spike
> （见那个文件头的说明），不是产品入口。漏了 `-t` 会编出一个 spike 而不是客户端。

## 5. Android 的 Rust 交叉编译

```powershell
$ndk = "$env:LOCALAPPDATA\Android\Sdk\ndk\27.0.12077973\toolchains\llvm\prebuilt\windows-x86_64\bin"
$env:PATH = "$ndk;$env:PATH"

cd rust/sourin_core
foreach ($t in @("x86_64-linux-android","aarch64-linux-android")) {
  cargo build --release --target $t
}
# armv7 要额外给 cc crate 指编译器（它猜不出 v7 的名字）
$env:CC_armv7_linux_androideabi = "$ndk\armv7a-linux-androideabi24-clang.cmd"
cargo build --release --target armv7-linux-androideabi

# 拷进 jniLibs
cd ../..
$map = @{
  "x86_64-linux-android"      = "x86_64"
  "aarch64-linux-android"     = "arm64-v8a"
  "armv7-linux-androideabi"   = "armeabi-v7a"
}
foreach ($k in $map.Keys) {
  Copy-Item "rust\sourin_core\target\$k\release\libsourin_core.so" "android\app\src\main\jniLibs\$($map[$k])\" -Force
}
```

> ⚠️ **改完 `ffi.rs` 必须重编这三个 target 并重新拷贝** —— `jniLibs/*/libsourin_core.so`
> 是**手动拷贝**的产物，不在 Flutter 的构建链里。漏了会在 Android 上看到：
> ```text
> [SHELL] ★ 核心启动失败: Failed to lookup symbol sourin_call_stream
> ```
> 然后**所有命令都超时**（看起来像网络问题，实际是旧的 .so 里没有新符号）。

## 6. 验证

```powershell
# 核心里应当有 7 个导出符号
strings android/app/src/main/jniLibs/x86_64/libsourin_core.so | Select-String "^sourin_"
```

## CI

`.github/workflows/build.yml` 在每次 push / PR 时：

```text
windows  编 Rust 核心 → analyze → 全量测试 → 打包 → 上传 Artifact
macos    编 Rust 核心 → analyze → 全量测试 → 打包 .app → 上传 Artifact
android  NDK 交叉编译三个 ABI → 两个 APK → 上传（**默认关闭**）
```

Android 那个 job 默认关掉：它最慢（要 NDK + 三个 target 交叉编译），
而 Windows job 已经覆盖了 Dart 与 Rust 两侧的全部测试。
要跑就手动触发 `workflow_dispatch` 并勾上 `build_android`。

## CI 里几个有意加的核验（都是踩过的坑）

| 检查 | 防的是什么 |
|---|---|
| Windows：`data/app.so` 必须 > 5 MB | 漏了 `-t lib/shell.dart` 会编出 spike 而不是客户端，而**编错了不报错** |
| Windows：显式确认 `windows/sourin_core.dll` 存在 | CMake 的拷贝按时间戳判断，会静默跳过 |
| macOS：`codesign -d --entitlements` 核验带上了 `network.client/server` | 少了它应用能启动但所有请求都失败 |
| Android：数 `.so` 里的 `sourin_` 导出符号 ≥ 7 个 | 改完 `ffi.rs` 没重编那个 ABI，症状是「所有命令都超时」 |
| Android：`aapt dump badging` 检查 `LEANBACK_LAUNCHER` | 少了它 TV 上找不到应用 |

> ⚠️ `flutter analyze` 在 CI 里跑的是 `--no-fatal-infos --no-fatal-warnings`：
> 本仓有约 440 条既有 warning/info（探针文件与测试里的既有项），
> 默认设置会让 CI 永远红。加了这两个 flag 之后**只有 error 才卡住**
> （实测：有 error 时仍返回 1）。

## 开发流程：走 PR，不走直推 main

功能迭代走 **「开 PR → AI 审核 → 完善 → 合并」**，细则见
[../CONTRIBUTING.md](../CONTRIBUTING.md)。摘要：

```text
① 开分支   git switch -c feat/<短描述>
② 提交     git commit
③ 开 PR    git push -u origin <branch> → GitHub 上开 PR
④ 自动评审 CI 跑起来；CodeRabbit 几分钟内贴出评审
           ★ 触发条件：App 已装 + PR 目标 main + 非草稿 + 标题未命中排除词
⑤ 完善     逐条判断：真问题就修，误报就回帖说明并 resolve
⑥ 再评审   推新 commit 后自动复审增量
⑦ 合并     意见都处理完 + CI 全绿 → 合并
```

> ⚠️ **`main` 已开分支保护，任何直推都会被服务端拒绝**（GH006）。
> 下面这些改动**仍要开 PR**，只是**可以自己直接合并**、不用等人看：
> 错别字 / 注释 / 文档 / `.gitignore` 这类元数据 / 回滚刚推错的东西 /
> main 已经红了要紧急修 CI。
> 判断标准是「**这个改动有没有可能悄悄改变产品行为？**」——有就走完整流程
> （等 CI + 处理评审意见）；没有就开 PR 后直接合。

### CodeRabbit（AI 代码评审）

配置在 [`.coderabbit.yaml`](../.coderabbit.yaml)。它补的正是 CI 拦不住的那类问题：

| 只有 CI 时能拦住 | 需要有人看才能拦住 |
|---|---|
| 编译不过、测试红、analyze error | 某个分支在某种平台组合下永远走不到 |
| 依赖缺失、格式不符 | 一条断言其实**恒真**（假门禁） |
| 版本号对不上 | 改了 A 忘了同步 B（如 `.nsi` 的安装侧 / 卸载侧） |
|  | 并发 / 时序问题（测试改进程级全局量） |

右列这几类本仓**每一条都真踩过**，共同特征是「CI 全绿，问题在用户那里才爆」。

**费用**：公开仓库免费（本仓是 public），私有仓库没有免费档。

**安装**：给 `coderabbitai` 这个 GitHub App 授权本仓 ——
打开 <https://github.com/apps/coderabbitai/installations/new>，
选 `sourin-app/sourin`，授权即可（只给这一个仓库，不要给全部）。

**在 PR 里可用的命令**：
```text
@coderabbitai review          重新评审（增量：不重看已评过的提交）
@coderabbitai full review     完整评审（重看所有文件）
@coderabbitai resolve         把它的评论标记为已解决
@coderabbitai configuration   打印当前生效的完整配置
@coderabbitai help            全部命令
```

> ⚠️ 处理评审意见的纪律（写在 CONTRIBUTING.md 里，这里再强调一次）：
> **不许**用「加 ignore 注释」「放宽断言」「删掉那行」来消掉意见。
> 本仓已有一条同类教训 —— 为了让 CI 变绿而放宽断言，等于把缺陷藏进绿里。

**已实测有效**（PR #1；实测 run 的时间戳是 UTC 2026-10-08T23:11Z = 北京时间
2026-10-09 07:11）：CodeRabbit 在 PR 里贴出了 3 条行内意见，
其中一条指出本仓库文档里一处**错误的技术论断**（原在 README，现见 [PLATFORMS.md](PLATFORMS.md)），我按它的指引做了对照实验，
**实测确认它是对的、我写错了**（详见 `.coderabbit.yaml` 里那段「实测读数」）。
这说明它不是只会说「建议优化」的复读机。
