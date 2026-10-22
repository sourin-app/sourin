# 运行手册（RUNBOOK）

> 2026-10-15 建立。**只写非显然步骤** —— 发版、本机跑真机、排障的顺序与判据。
> 常规构建命令见 [BUILD.md](BUILD.md)；数据目录文件清单见 [DATA-DIR.md](DATA-DIR.md)。
>
> 每条都带日期；失效即删。

---

## 1. 发版（GitHub Actions）

```text
Actions → 构建 → Run workflow
  · build_android：要不要**同时**出 Android 包（默认不勾；勾了会多 30 分钟交叉编译）
  · release_tag：留空 = 只构建不发版；填了（如 v1.0.0）= 构建完自动建 Release 并上传
```

发布产物（由末尾的 publish job 汇总三条 rel-* artifact）：

| 平台 | 文件 |
|---|---|
| Windows | 安装包 + 免安装 zip |
| macOS | zip + dmg |
| Android | 两个 APK（手机 / TV **同一个 APK**，无需分别构建） |
| 全部 | SHA256SUMS.txt |

> ⚠️ **不让 publish job 去下载 sourin-* 那些 artifact** —— 那条下载链路要走 Azure blob 的
> SAS 重定向，实测只有几十 KB/s（125 MB 要一小时）。所以各平台 job 自己压成 rel-* 再汇合。

### 发版前的两个前置（漏了不会报错，只会静默降级）

1. **凭证 secrets**：仓库 Settings → Secrets and variables → Actions 里要有
   `DANDANPLAY_APP_ID` / `DANDANPLAY_APP_SECRET`。缺了不会失败 ——
   包里的凭证为空串，App 回落到**用户自填**凭证（功能降级但不崩）。
2. **Android 包必须在同一轮里勾上 build_android** —— 否则那轮的 Release 没有 APK。
3. **本版更新从哪来**（2026-10-22 新增）：默认由
   `tools/gen_release_notes.py` 从 git 历史自动归纳；**归纳为空 ⇒ CI 直接红**
   （这是有意的强制点，别去加 `--allow-empty` 绕）。
   若这一版的改动**自动归纳产不出来**（提交标题全是工程黑话），
   写一份人工确认稿 `docs/release-notes/<TAG>.md`（文件名 = 本次 tag），
   CI 会优先用它。稿子仍被机械校验：至少一条条目、不许表格/图片/代码块、
   不许开发用语与站名、不许占位符残留。细节见
   [release-notes/](release-notes/) 与决策笔记
   [../.agents/notes/implemented/process/2026-10-22-release-notes-manual-override.md](../.agents/notes/implemented/process/2026-10-22-release-notes-manual-override.md)。

发版前的合并检查清单见 [../CONTRIBUTING.md](../CONTRIBUTING.md)「⑦ 合并前必须满足」。

---

## 2. 版本号从哪来

```text
pubspec.yaml:  version: 1.0.0+1        ← Flutter 侧的版本（安装包用这个）
构建期注入:    --dart-define=SOURIN_VERSION=${{ env.SOURIN_VERSION }}
               ★ 恰好三条**发布用**构建步带它；诊断 job 的 --debug 构建不带（不发版）
rust/sourin_core/Cargo.toml: version = "0.1.0"   ← 与 Dart 侧独立，仅用于 crate 元数据
```

> 改动注入通道会撞到门禁 `test/t27_w11_ci_appkey_inject_test.dart`（它钉住三条发布构建
> 各带一次 `SOURIN_VERSION`）。**这是有意的** —— 少一条就是那一个平台的包不知道自己是谁。

---

## 3. 本机跑客户端（Windows）

```powershell
.\tools\run_client.ps1              # 编 + 跑（Release）
.\tools\run_client.ps1 -Rust        # 先 cargo build --release 再编再跑
.\tools\run_client.ps1 -Dev         # flutter run + 热重载 + 数据目录隔离到 %TEMP%\sourin-dev
.\tools\run_client.ps1 -Dev -DataDir D:\tmp\sourin-dev
.\tools\run_client.ps1 -BuildOnly   # 只编不跑
.\tools\run_client.ps1 -NoBuild     # 只跑已有的产物
```

**为什么要有这个脚本**（2026-10-09 真实事故）：直接 `flutter build windows --release` **漏了
`-t lib/shell.dart`** 时，构建**成功退出、一个字都不报**，产物覆盖掉正确的产品 exe，
双击起来是早期 HEVC 验收 spike。判据只有一条：`data/app.so` 的大小（产品 ~10.8 MB / spike ~4 MB），
脚本把它变成硬闸。

> ⚠️ 非 `-Dev` 的 Release 启动**会用真实数据目录**（产品正常行为）—— 脚本只启动，
> 不做任何写入型探针。要隔离就显式用 `-Dev`。
> ⚠️ 结束进程只杀**你自己启动的 PID**（`taskkill //PID <pid> //F`），绝不按进程名批量杀。

### `-Dev` 起来前会播种（2026-10-15）

`-Dev` 先调 `tools/seed_dev_data.ps1`，把真实数据目录里的**内容**播到隔离目录 ——
否则开发环境是空的（只有核心自释放的 demo 插件），插件调试 / 追更 / 播放进度一条都验不了。

```text
拷   plugins/*.js + 状态 json + dsh-media.db 三件套 + 界面偏好（按 key 过滤）
不拷 sync-settings.json / remote-pref.json / plugins/.data/（凭据类，一律不带）
```

- **只读真实目录**：跑完源目录逐文件哈希不变（有回归测试守着）。
- **默认不覆盖**已存在的文件 ⇒ 反复跑是幂等的。要拿真实数据盖掉开发目录里的改动：

```powershell
.\tools\seed_dev_data.ps1 -Target "$env:TEMP\sourin-dev" -Force
```

> ⚠️ **插件在开发目录里是「未配置」状态**（插件私有数据不搬）。这是有意的取舍 ——
> 换的是「临时目录里不出现你的凭据」。不是漏搬。
> ⚠️ 开发/探针构建**不做启动更新检查**（本地 HEAD 永远比线上新，弹了是纯噪声）。
> 要验更新流程：设置 → 关于 → 检查更新（手动入口照旧可用）。

---

## 4. 排障：按现象查

| 现象 | 先查什么 | 根因 / 处置 |
|---|---|---|
| 改了 Rust，行为没变 | 包目录里的 `sourin_core.dll` 哈希/mtime 变了吗 | `cargo build --release` 源码没改会直接跳过；旧的 `.dll` 被原样装进包。删掉包目录里的那个 `.dll` 强制重拷 |
| Android 上所有命令都超时 | `jniLibs/*/libsourin_core.so` 是哪次编的 | 它是**手动拷贝**的产物，不在 Flutter 构建链里。改过 `ffi.rs` 就要重编三个 target 并重拷（见 BUILD.md §5） |
| `Failed to lookup symbol sourin_call_stream` | 同上 | 旧的 `.so` 里没有新符号。症状伪装成「网络问题」 |
| `flutter test test/` 偶发 `did not complete` | 单跑那个文件还红吗 | `flutter_tester` 加载 libmpv 时原生崩溃（第三方库）。先单跑定位，别急着改代码 |
| 深色主题「看不见字」但处处不报错 | `test/theme_regression_test.dart` | 主题角色取值的静默回归（对比度 1.16:1 也照样编译过） |
| macOS 打包后所有请求失败 | `codesign -d --entitlements` 看有没有 `network.client/server` | 两个 entitlements 文件（DebugProfile / Release）**必须同步**；只改一个 = 「开发时好的、打包后坏的」 |
| 用户报某格式黑屏 / 只有声音 | 设置 → 播放与下载 → 硬解模式改 `no` | 部分源是 DRM 加密的直播源，**只有音频能播**，界面会明确提示「仅音频可播」 |

### 看日志

```text
<数据目录>/logs/       按天分文件；播放相关问题搜 [PLAY] / [SHELL]
<数据目录>/mpv-cache/  播放缓存，可随时删
<数据目录>/clip-cache/ 片段下载缓存，可随时删（设置页也有「清空」）
```

数据目录在各平台的位置见 [DATA-DIR.md](DATA-DIR.md)。

---

## 5. 回滚与破坏性操作

```text
· 回滚 main：需要去 GitHub Settings → Branches **临时**改分支保护规则，
  推完**记得改回来**（不改回来 = 分支保护长期失效，而没人会注意到）。
· 清 git 历史里的站名 / 插件文件：git filter-repo —— 见 CONTRIBUTING 的「历史怎么清」：
  ① git bundle create <备份> --all 并 verify  ② 跟 Owner 确认  ③ 做完全仓 grep 复验。
  ★ 这是**不可逆**操作（所有 commit hash 会变、需强推）。
```

---

## 6. CI 里几个「有意加」的核验（不是装饰，每条都对应一次真实踩坑）

| 检查 | 防的是什么 |
|---|---|
| Windows：`data/app.so` 必须 > 5 MB | 漏了 `-t lib/shell.dart` 会编出 spike 而不是客户端，**而编错了不报错** |
| Windows：显式确认 `windows/sourin_core.dll` 存在 | CMake 的拷贝会静默跳过 |
| macOS：`codesign -d --entitlements` 核验带上了 `network.client/server` | 少了它应用能启动但所有请求都失败 |
| Android：数 `.so` 里的 `sourin_` 导出符号 ≥ 7 个 | 改完 `ffi.rs` 没重编那个 ABI，症状是「所有命令都超时」 |
| Android：`aapt dump badging` 检查 `LEANBACK_LAUNCHER` | 少了它 TV 上找不到应用 |

> ⚠️ `flutter analyze` 在 CI 里带 `--no-fatal-infos --no-fatal-warnings`：本仓有约 440 条
> 既有 warning/info（探针文件与测试里的既有项），默认设置会让 CI 永远红。加了这两个 flag 之后
> **只有 error 才卡住**（实测：有 error 时仍返回 1）。

---

## 7. 复现问题的最小姿势（写报告 / 开 issue 用）

```bash
# 1. 数据目录隔离（★ 必做，否则会碰到用户真实数据）
flutter test test/<文件>.dart --concurrency=1 \
  --dart-define=DATA_DIR_OVERRIDE=<临时目录>

# 2. 要证明「修复前应当红」时，用纯净 worktree（别在带未提交改动的树上测）
git worktree add <临时目录>/red HEAD~1
```

> 对外报告里的**否定性断言必须自带可复现命令**：「X 不存在 / 没有」这类句子要么附上
> 取数命令与实测输出，要么改写成可被对方自行验证的表述。一条未自证的否定断言足以让对方
> 拿它否掉整条报告。
