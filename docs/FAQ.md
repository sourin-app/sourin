# 常见问题

> 本文原为根 [README.md](../README.md) 的「常见问题」一节，2026-10-15 拆分到 `docs/`，正文未改写。
> 文档地图见 [docs/README.md](README.md)；开发硬约束见 [docs/AGENTS.md](AGENTS.md)；
> 提交与评审纪律见 [CONTRIBUTING.md](../CONTRIBUTING.md)。

---

# 常见问题

<details>
<summary><b>HEVC / AC3 / DTS 播不了，只有声音没画面</b></summary>

Flutter 版用 libmpv，**自带 FFmpeg**，理论上都支持。如果遇到黑屏：

1. 设置 → 播放与下载 → 把「硬解模式」改成 `no`（软解）试试；
2. 看 `logs/` 里的日志，搜 `[PLAY]`；
3. 部分源是 DRM 加密的（部分直播源），**只有音频能播** —— 这种情况界面会明确提示
   「仅音频可播」，不是 bug。

</details>

<details>
<summary><b>改了 Rust 代码但行为没变</b></summary>

90% 是 CMake 没拷贝新的 `.dll`（它按时间戳判断）：

```powershell
# 直接删掉目标文件强制重拷
Remove-Item windows\sourin_core.dll -ErrorAction SilentlyContinue
flutter build windows --release -t lib/shell.dart
```

Android 侧同理 —— `jniLibs/*/libsourin_core.so` 是**手动拷贝**的，见
「从源码构建 → 5. Android 的 Rust 交叉编译」。

</details>

<details>
<summary><b>Android 上所有操作都超时</b></summary>

看 logcat 里有没有：

```text
[SHELL] ★ 核心启动失败: Failed to lookup symbol 'sourin_call_stream'
```

有的话是 `jniLibs` 里的 `.so` 太旧（改完 `ffi.rs` 没重编那个 ABI）。
重编三个 target 并重新拷贝即可。

</details>

<details>
<summary><b>开发时怎么不碰到我正在用的数据</b></summary>

**务必**用 `DATA_DIR_OVERRIDE` 指到临时目录：

```bash
flutter run --dart-define=DATA_DIR_OVERRIDE=D:\tmp\sourin-dev
```

默认数据目录里有你真实的收藏、进度、片头片尾 —— 一次写探针就可能改掉。

</details>

<details>
<summary><b>窗口跑到屏幕外面了 / 换显示器后不见了</b></summary>

窗口几何会自动夹进显示器工作区。如果还是不对，删掉这一行再启动：

```json
// <数据目录>/ui-prefs.json
"dsh.window.bounds": "571,159,1444,845"   <- 删掉整行
```

</details>

<details>
<summary><b>点 X 直接退出了，我想让它最小化到托盘</b></summary>

设置 → 通用 → 「关闭行为」，或者删掉 `ui-prefs.json` 里的 `dsh.closeAction`
让它重新问一次。

</details>
