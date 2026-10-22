# 本轮可复跑工具索引

> **核对时刻：2026-10-18 15:47**（本仓路径/行号几小时内会漂；引用前重新 `ls` / `grep`）
>
> 本文档只收录**本轮（第 66 轮）新造**的验证工具。
> 每条都回答三个问题：**能证明什么 / 不能证明什么 / 复跑一次要多久**。
> 所有命令都在写作时**实际跑过**，跑不了的单独标注原因。

---

## 用法速查

| 工具 | 一句话 | 复跑耗时 | 需要什么 |
|---|---|---|---|
| [`tools/commit_scope_guard.ps1`](#toolscommit_scope_guardps1) | 提交前检查暂存范围 | < 1 秒 | 无 |
| [`tools/live_probe_count.ps1`](#toolslive_probe_countps1) | 数直播探测的真实请求次数 | 2~5 分钟 | 构建 + 真实插件 |
| [`rust/.../tests/zz_n10_yield_verify.rs`](#zz_n10_yield_verifyrs) | 让路窗口是否真让出带宽 | **9.2 秒** | 无 |
| [`rust/.../tests/zz_n10_switch_source_measure.rs`](#zz_n10_switch_source_measurers) | 切集/换源干扰测量 | **1.2 秒** | 无 |
| [`rust/.../bin/n10_throttle_upstream.rs`](#n10_throttle_upstreamrs) | 确定性限速上游（本地 HTTP） | 手动启动 | 一个 mp4 |
| [`test/zz_t66_live_embed_bounds_test.dart`](#zz_t66_live_embed_bounds_testdart) | 内嵌播放器 12 组视口不越界 | 1.3 秒 | 无 |
| `.probe/t66_size_sweep.txt` | 上面那条的**原始探针读数** | — | 未入库，见注释 |

---

## `tools/commit_scope_guard.ps1`

**用途**：提交前检查「暂存的行数」是否 = 你以为的行数，防止整文件 `add` 带走别人的改动。

**为什么需要它**：本轮出现过 4 次「整文件 add 夹带别人代码」，其中一次是
`8e8be90`（Lead 的提交）。肉眼看 `git diff --cached` 在几百行时不可靠。

**用法**：

```bash
git add lib/ui/foo.dart
pwsh -NoProfile -File tools/commit_scope_guard.ps1 -ExpectFile "lib/ui/foo.dart" -ExpectAdded 19
```

参数：

| 参数 | 含义 |
|---|---|
| `-ExpectFile` | 你认为是自己的文件（可多个）。**其他被暂存的文件 = 红旗** |
| `-ExpectAdded` | 你预期的总新增行数；`-1`（默认）= 不检查行数 |
| `-Report` | 只报告，永不失败（快速看一眼用） |

**预期输出**：

```text
相符 ⇒ 通过信息 + exit code = 0
不符 ⇒ [FAIL] added lines = 51, but you expected 0 => 51 line(s) are NOT yours
        + exit code = 1
```

**实跑验证（2026-10-18 15:47，无暂存内容时）**：

```text
$ pwsh -NoProfile -File tools/commit_scope_guard.ps1
  nothing staged -- nothing to check
EXIT=0
```

**⚠️ 退出码读法陷阱（这条是工具作者踩过的真实坑）**：

```bash
# ❌ 错：$? 读到的是 tail 的退出码，永远 0
pwsh -File tools/commit_scope_guard.ps1 | tail -3 ; echo "EXIT=$?"

# ✅ 对：不带管道，或用 pwsh 自己的 $LASTEXITCODE
pwsh -NoProfile -File tools/commit_scope_guard.ps1
echo "EXIT=$?"
```

> ★ 我自己在写这份文档时**又踩了一次**：`pwsh ... | tail -5; echo "EXIT=$?"`
> 打出 `EXIT=0`，而当时 `pwsh` 根本不在 PATH 里（命令没执行成功）。
> ⇒ 这个陷阱不是历史教训，是**活的**。

**① 能证明什么**：本次暂存的内容**恰好**是这些文件、恰好这么多行。
**② 不能证明什么**：
- 不检查**删除**的行数（只看 added）
- 不检查内容是否正确（只数行数）
- 不替代 `git show --name-only` 的**归属**核实（它不知道"谁该改这个文件"）
**③ 复跑耗时**：< 1 秒。**依赖**：无（纯 PowerShell）。

**作者**：playback-fix（`89a7888` + `eb12cd4`）

---

## `tools/live_probe_count.ps1`

**用途**：数直播页**真实发出**的探测请求次数，验证「不再每次启动全量探测」。

**为什么需要它**：Owner 的 P0 是「迟早要被拉黑」。
源码断言只能证明「代码写了缓存判断」，**证明不了「真实进程真的没发请求」**。
这个工具数的是 Rust 核心 `get_live_stream` 的**真实调用次数**。

**原理**（重要，决定了它能证明什么）：

```text
Rust 核心在 SOURIN_LIVE_PROBE_COUNT 被设置时，每次真实 get_live_stream 调用
**追加一行到文件**（SOURIN_LIVE_PROBE_FILE）。
★ 不写 stderr —— Windows 上重定向的管道是块缓冲，
  进程被强杀时整个缓冲区会丢 ⇒ 会数出 0。

get_live_stream 是直播页探测频道的**唯一**路径 ⇒ 行数 = 请求数。
```

**用法**：

```bash
pwsh -NoProfile -File tools/live_probe_count.ps1 -Scenario nocache
pwsh -NoProfile -File tools/live_probe_count.ps1 -Scenario fresh -Reuse
```

参数：

| 参数 | 含义 |
|---|---|
| `-Scenario` | `nocache`（默认）/ `stale` / `fresh` |
| `-WatchSeconds` | 观察上限，默认 **200**（30 秒延迟探测 + 1268 频道需要约 2 分钟）；证据到位就提前退出 |
| `-Reuse` | 复用上次的数据目录（`fresh`/`stale` 场景**必须**用，否则缓存不跨进程存活） |
| `-NoBuild` | 跳过构建 |

**⚠️ 依赖**：

- 需要**已构建的 Release 包**（`build\windows\x64\runner\Release\sourin_spike.exe`）
- 需要**真实插件**（否则没有频道可探）
- 会把 `APPDATA` 指到临时目录（不碰用户真实数据）

**① 能证明什么**：真实进程在指定场景下**实际发出**多少次探测请求
（本轮实测：改前 1269 次 → 改后 1 次）。
**② 不能证明什么**：
- **不能证明**「永远不会被上游判定为滥用」—— 只证明「10 分钟内重启不重复探测」
- 不证明 UI 上的灰/红点显示正确
**③ 复跑耗时**：2~5 分钟（含构建则更久）。**依赖**：Release 构建 + 真实插件。

**作者**：playback-fix

---

## `zz_n10_yield_verify.rs`

**路径**：`rust/sourin_core/tests/zz_n10_yield_verify.rs`

**用途**：验证 seek 让路窗口**真的**让出了带宽 —— 而不是「代码里调了让路函数」。

**为什么需要它**：perf-player 的 7 条 Dart 门禁全是**源码断言**
（调了某个函数、定时器到点、状态恢复…）。
它们证明「接线正确」，**证明不了「带宽真的让开了」**。

**用法**：

```bash
cd rust/sourin_core
cargo test --test zz_n10_yield_verify
```

**预期输出（实跑，2026-10-18 15:46）**：

```text
running 4 tests
test n10_yield_window_restores_previous_state_not_unconditional_on ... ok
test n10_yield_window_state_machine_invariants ... ok
test n10_consecutive_remote_seeks_cost_during_yield ... ok
test n10_yield_window_really_frees_bandwidth ... ok

test result: ok. 4 passed; 0 failed; 0 ignored
finished in 9.23s
```

**关键常量（想推翻结论就改这些）**：

| 常量 | 值 | 位置 |
|---|---|---|
| `TOTAL` | `8 * 1024 * 1024` | `:56` |
| `CHUNK` | `64 * 1024` | `:58` |
| `CHUNK_DELAY_MS` | `50` | `:63` |

**① 能证明什么**：让路窗口内，前台读取的带宽开销从 **+25% 降到 +4%**
（≈ 等于预取关闭时的水平）。这是让路机制**唯一的作用原理**，直接测它比测端到端更接近因果。
**② 不能证明什么**：
- **不证明**「用户在 UI 上一定感觉更快」—— 体感对照未做（真实网络抖动会盖过信号）
- 用的是**确定性限速上游 + 合成数据**，不是真实 CDN
- 是**必要条件不是充分条件**
**③ 复跑耗时**：**9.2 秒**（测试本身；含编译约 16 秒）。**依赖**：无网络、无设备。

**作者**：playback-fix

---

## `zz_n10_switch_source_measure.rs`

**路径**：`rust/sourin_core/tests/zz_n10_switch_source_measure.rs`

**用途**：测量切集/换源时的干扰量级。

**用法**：

```bash
cd rust/sourin_core
cargo test --test zz_n10_switch_source_measure
```

**预期输出（实跑，2026-10-18 15:46）**：

```text
running 2 tests
test stream_table_size_after_many_registrations ... ok
test old_prefetch_interference_measurement ... ok

test result: ok. 2 passed; 0 failed; 0 ignored
finished in 1.16s
```

**① 能证明什么**：切集/换源干扰 **+121~125ms**（A/B = 1.88×），
且证明「服务端会及时停」。
**② 不能证明什么**：
- 这是 **512 KB/s 窄带下的上界**，宽带下干扰会小得多
- 用 reqwest 模拟断开，**不证明 mpv 一定会及时断**
**③ 复跑耗时**：**1.2 秒**。**依赖**：无。

**可推翻性**：改限速值（512 → 5120）重跑，干扰应从 121ms 降到约 8ms。

**作者**：perf-player

---

## `n10_throttle_upstream.rs`

**路径**：`rust/sourin_core/src/bin/n10_throttle_upstream.rs`

**用途**：起一个**确定性限速**的本地 HTTP 上游，供手动复现带宽争抢。
是上面两个 Rust 测试用的同一个测试台的**手动版**。

**用法**：

```bash
cd rust/sourin_core
cargo run --bin n10_throttle_upstream -- <file.mp4> [bytes_per_sec] [port]
```

参数（来自源码 `:152-155` 的用法串）：

```text
用法: n10_throttle_upstream <file.mp4> [bytes_per_sec] [port]
```

**预期输出**：

```text
[UPSTREAM] ready at http://127.0.0.1:<port>/video.mp4
READY http://127.0.0.1:<port>/video.mp4
```

★ 第二行 `READY ...` 打到 **stdout**（供脚本捕获），其余打到 **stderr**。
⇒ 脚本里要读 **stdout** 那一行拿 URL。

**① 能证明什么**：在**可控带宽**下复现「预取与前台抢同一条上游」。
**② 不能证明什么**：它只是测试台，本身不产出任何结论；
真实 CDN 的限速行为与它不同。
**③ 复跑耗时**：编译后启动 < 1 秒，**但它是个常驻服务**（要自己 Ctrl-C）。
**依赖**：一个本地 mp4 文件。

**作者**：playback-fix

---

## `zz_t66_live_embed_bounds_test.dart`

**路径**：`test/zz_t66_live_embed_bounds_test.dart`

**用途**：断言直播页内嵌播放器在 6 种视口 × 宽/窄两分支下**都不越界**。

**背景**：Owner 报「左侧播放区域,视频控件都有一半在视窗外了」。
这个门禁把当时的探针读数（`.probe/t66_size_sweep.txt`，12 组）**转正**成可复跑的门禁。

**用法**：

```bash
flutter test --concurrency=1 test/zz_t66_live_embed_bounds_test.dart
```

**预期输出（实跑，2026-10-18 15:43）**：

```text
00:01 +13: All tests passed!
```

13 条 = 6 视口 × 2 分支 + 1 条阴性对照。

**三条判据**：

```text
① 播放器 rect 在 ClipRRect 内（L/R/B 各 <= 0.5px）
② 所有 Icon 的 global x >= 0 且右边界在视口内
③ 全渲染树无 x<0 的 RenderBox
```

**故障注入（已验证）**：

| 注入 | 结果 |
|---|---|
| 播放器加 `Transform.translate(Offset(-60, 0))` | **6 红** |
| 把一个 Icon 挪到 `x = -1` | **6 红** |
| 阴性对照：故意放 `x = -40` 的元素 | 扫描器**数得到**（否则 12 条全不可信） |

**① 能证明什么**：`LiveEmbeddedPlayer` 在这 12 组视口下**代码层面不越界**。
**② 不能证明什么（★ 不许单独引用这条）**：
- **只覆盖直播页的内嵌播放器**。若现象出现在**全屏播放页**（`PlayerPage`），
  本门禁**不覆盖**，需另行验证。
- 「代码不越界」≠「Owner 看到的问题不存在」：
  若 12 组都不越界，现象只能来自**窗口本身**
  （被拖到屏幕边缘外 / 窗口大于屏幕可用区），不是 UI 布局 bug。
- 用的是**测试夹具复刻的几何**，不是真实页面（真实页面还有滚动、抽屉等状态）。
**③ 复跑耗时**：**1.3 秒**。**依赖**：无。

**可推翻性**：在 `_wide()` 里给播放器加任意负 offset 重跑 ⇒ 应红（已实测 6 红）。

**作者**：live-ux

---

## `.probe/t66_size_sweep.txt`（本地工具，未入库）

**为什么未入库**：`.probe/` 被 `.gitignore` 挡住，这是本仓既有设计
（同 `perf-player` 的 `positive_control_switch.py` 也在此列，它判断「不该 `-f` 强加」是对的）。

**它的价值已被吸收**：读数与结论已转正成上面的
`zz_t66_live_embed_bounds_test.dart`（门禁）+ `round-66-final.md` §二·⑧（结论+边界）。

**原始读数要点**（12 组）：

```text
视口：1444×845 / 1280×720 / 1024×768 / 900×600 / 899×600 / 640×480
宽屏分支（右侧 300px 列表）：
  1444×845  clip 1124 宽   播放器 L=0 R=0 B=-118.4
  1280×720  clip  960 宽   播放器 L=0 R=0 B=-102.0
  1024×768  clip  704 宽   播放器 L=0 R=0 B=-198.0
   900×600  clip  580 宽   播放器 L=0 R=0 B=-148.9
   899×600  clip  579 宽   播放器 L=0 R=0 B=-149.2
   640×480  clip  320 宽   播放器 L=0 R=0 B=-162.0
窄屏分支：播放器铺满宽，L=0
全部 12 组：Icon 全在视口内，x<0 的 RenderBox = 0
```

---

## 通用提醒（写工具和读工具时都适用）

```text
★ 记录注入/替换结果时，必须同时给出「注入确实生效」的证据（标记计数 ≥1）。
  否则「注入后门禁绿」有两种完全相反的解释：
    · 门禁弱
    · 注入压根没写进去
  ⇒ 修法完全不同（前者重写门禁，后者修注入）。

★ 读退出码时不要经过管道。`cmd | tail; echo $?` 读的是 tail 的退出码。

★ 「可复跑」的门槛：给出完整命令 + 预期输出 + 依赖。
  只说"跑那个测试"不算 —— 下一个人不知道要 cd 到哪、要不要网络。
```
