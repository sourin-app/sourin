# CS-1 备份五步：可执行的驱动探针（第 66 轮）

## 一句话

`docs/notes/round-66-e2e-verify.md` 自报「CS-1 真机 56 ✓ / 7 张截图」，但全盘
`t66-cs1*` = 0、`.probe/e2e/` 只剩 3 张弹幕代理图 —— 那 7 张从来没落在自报路径上。
根因之一是 `tools/e2e_shots.ps1` **只到页签级**：CS-1 的「导出 → 设口令 → 导入 →
错口令 → 对口令」这 5 步，没有任何工具驱动得了，所以「跑过」只能靠嘴说。

本轮把这条路做成可执行的：一个探针入口 + 一条命令 + 探针自己落的报告文件。

## 交付物

| 文件 | 性质 | 状态 |
| --- | --- | --- |
| `lib/t107_cs1_flow_probe.dart` | 探针入口（1299 行，untracked 资产） | `flutter analyze` ⇒ **No issues found!** |
| `tools/run_t107.ps1` | 运行脚本（编 + 跑 + 打印报告） | 语法解析 **PARSE OK**，硬闸 ① 实测拦住 |
| `docs/notes/round-66-cs1-driver.md` | 本文（判据表 + 未验证清单） | — |

探针的根是产品自己的 `runApp(RepaintBoundary(SourinApp(coreError:, coreDataDir:)))`，
截图走 `RenderRepaintBoundary.toImage(pixelRatio: 1280/逻辑宽)` ⇒ 断言物理尺寸
**精确 1280×800**，不是「大概 1280」。

## 五步：实现位置与双证据

每条判据都是「**文件/请求事实** + **UI 事实**」，`cs1BothFacts()` 取与 —— 任一为假
就是 BAD（只看控件在不在，会被「面板画了但什么都没做」骗过去）。

| 步 | 产品入口（真点） | 文件/请求事实 | UI 事实 | 位置 |
| --- | --- | --- | --- | --- |
| ⓪ 进面板 | 设置页「备份与恢复」行 | — | `BackupPanel` 真的挂上来 | `:862-883` |
| ① 导出 | 面板「导出」填充按钮 | 产物存在、`bytes>0`、ZIP 魔数 `PK\x03\x04`、`backupInspect` 报 `credentials.included=true` | 面板回执「已导出到 …」 | `:885-1020` |
| ② 设口令 | 知情提示「设口令并加密」→ 口令框 | 带口令的包 `included=true`；**对照**：不带口令的包 `included=false` | 口令框出现、口令确实进了输入框 | `:924-1056`（对照 `:1022-1044`） |
| ③ 导入（对口令） | 「选择文件」→「确认导入」→ 口令框 → 「导入」 | 导入前 `providers=0`，导入后 `providers≥1` | 面板「导入完成」 | `:1058-1132` |
| ④ 错口令 | 同上，输错口令 | `providers` 前后都 `=0`（**没被恢复**） | 面板出现「口令不正确…」，且**不出现**「导入完成」 | `:1134-1208` |
| ⑤ 再输对口令 | 同上，输正确口令 | `providers≥1` | 面板「导入完成」 | `:1210-1264` |

两处「可观测」的设计值得记一笔：

1. **③/④ 之前先把本机登录态清成 0**（删掉隔离目录里那份假凭据文件）。不这么做，
   `providers` 恒 ≥1，「恢复成功」和「什么都没发生」读数一样 —— 判据就没有判别力。
2. **② 自带对照组**：同一个产品接口，不给口令导一份，断言包里 `included=false`。
   只断言「带口令那份 included=true」无法排除「口令根本没起作用、永远 included」。

`providers` 的唯一来源是 `SourinApi.credentialsStatus()`（后端每次重读
`plugins/.data/*.json` 并剔除缓存 key），所以它是文件事实、不是 UI 事实。

## 每张图判什么（8 张，`<数据目录>\shots\cs1_*.png`）

| 图 | 步骤 | 人眼该看到什么 | 机器判据（红在哪条） |
| --- | --- | --- | --- |
| `cs1_00_panel.png` | ⓪ | 设置页里「备份与恢复」面板展开（两组卡片：导出 / 导入） | 尺寸 1280×800；`BackupPanel` 已挂载 |
| `cs1_01_export_consent.png` | ① | 含登录态的知情提示：说清「要加密这些登录态吗？」「口令不会进包」 | 三个文案断言（标题 / 加密问句 / 不进包） |
| `cs1_02_passphrase.png` | ② | 「设置导出用口令」对话框，口令框里已填**假口令**（不显示明文） | 对话框出现 + 口令真的进框（`via=…` 记录走的是哪种输入通道） |
| `cs1_03_export_done.png` | ① | 面板回执「已导出到 …」 | 回执文案 + ① 的机器可读行 `verdict=OK` |
| `cs1_04_import_confirm.png` | ③ | 选完文件后的确认区：「确认导入」按钮 + 包摘要 | 确认区出现（`openStub.calls≥1` 证明走的是产品选路那一跳） |
| `cs1_05_import_ok.png` | ③ | 面板「导入完成」 | 回执 + `providers≥1` |
| `cs1_06_wrong_pass.png` | ④ | 面板上的红色错误行「口令不正确（或这个备份包已被改动），登录态没有导入」 | 错误文案 + `providers` 仍 0 + 无「导入完成」 |
| `cs1_07_final_ok.png` | ⑤ | 面板「导入完成」 | 回执 + `providers≥1` |

命名刻意避开 `tabshot_` 前缀（那类文件会被 stale 清理吃掉）。

## 机器可读行

`<数据目录>\cs1-lines.txt`，每条一行，字段固定：

```text
CS1|<step>|file=<path>|bytes=<n>|sha256=<16>|ui=<断言>|verdict=OK|BAD
```

`<step>` 取值：`1_export` / `2_passphrase` / `3_import_ok` / `4_wrong_pass` / `5_ok`。
`ui` 字段里的竖线与换行先被换成 `/` 和空格，保证分列不被打断（有专门的一条自检覆盖它）。

三个纯函数（`cs1Sha256Short` / `cs1LogLine` / `cs1BothFacts`）是探针里**唯一能在
无窗口环境验证**的部分，本轮用临时 `flutter test` 跑过 **`+4 All tests passed!`**
（临时文件跑完即删，不留在 `test/` 里）。它们只保证「探针不会把 OK/BAD 算错」，
**不替代真机读数**。

## 怎么跑

```powershell
.\tools\run_t107.ps1                    # 编 + 跑；产物在 .probe\round66_cs1\<时间戳>\
.\tools\run_t107.ps1 -Run r6b-cs1        # 指定本次运行目录名
.\tools\run_t107.ps1 -NoBuild            # 只跑（复用上次编进去的数据目录）
```

脚本三个硬闸：

1. **数据目录必须落在 `.probe\round66_cs1\` 下**，且不许像真实用户数据目录。
   探针会写（导出包、删/放一份假凭据文件）—— 指错目录就是拿用户数据陪跑。
   探针自己也有一道同源的闸（`DATA_DIR_OVERRIDE` 不含 `round66_cs1` ⇒ `exit(3)`）。
   实测：`-Run '..\..\evil\app.sourin.player'` ⇒
   `ERROR: 数据目录像是真实用户数据目录，拒绝运行`。
2. **产物不许比源码旧**（`exe.LastWriteTime < t107 源码` ⇒ 直接退出）。这条是拿
   2026-10-20 的现场换来的：`build\` 里躺着 10-18 的 exe，跑起来一切「正常」，
   出的是两天前的像素，而且不会报错。
3. **判据只认探针自己写的文件**：GUI 子系统的 exe 没有 stdout，重定向可能一个字都
   拿不到 ⇒ 脚本打印 `cs1-report.txt`（逐条 ✓/✗ + `---- 结果：OK=n BAD=m`）、
   `cs1-lines.txt`、`cs1-trace.txt` 尾部与截图清单，再按 BAD 行数与张数给退出码。

跑之前请确认没有别的窗口在抢前台：本探针**不**调用 `SetCursorPos` /
`mouse_event` / `SetForegroundWindow` / `CopyFromScreen`（AGENTS §8），点击是
`WidgetsBinding.instance.handlePointerEvent` 直接投递到渲染树；系统文件选择器被
`FileSelectorPlatform` 替身接管 —— **真弹出文件选择器就说明走错了路**。

## 未验证清单（本轮没有窗口，如实标注）

| 项 | 为什么没验证 | 卡在哪 |
| --- | --- | --- |
| 五步在真窗口里能跑通 | 任务明令不 build、不跑真机窗口 | 需要 build 窗口（`flutter build windows --release -t lib/t107_cs1_flow_probe.dart`） |
| 截图真的 1280×800 且内容如上表 | 同上 | 同上 |
| `FileSelectorPlatform` 替身能接管产品实际调用的 `openFile` / `getSaveLocation` | 只能读 `file_selector` 的接口签名确认形状（`extends` 而非 `implements`），没法在无窗口环境真跑一次 | 真机首次运行（若探针报「选路径没被接管」，红点会在 ① 的 `saveStub.calls≥1`） |
| 各 `waitUntil` 的超时是否够（15/25/40/60 s） | 真窗口的耗时（尤其是 Rust 侧导出/加密）只能实测 | 真机首次运行 |
| 产品在**空数据目录**下「备份与恢复」面板的默认可见性 / band 滚动位置 | 代码里按 `debugSwitchTo(AppTab.settings)` + 滚动到带内实现，没跑过 | 真机首次运行 |
| ⑤ 之后是否需要重启才让其它平面刷新 | 不在本任务范围 | 未涉及 |

## 顺带记录的两处产品瑕疵（只记录，不在本任务范围改）

1. 不带口令导出的 `credentialsNote` 里有 Markdown 星号（`**不含登录态**`），
   面板是按纯文本渲染的 ⇒ 用户会看到字面星号。
2. 错口令时面板显示的是异常的 `toString()`，带宿主类名
   （`SourinCoreException(other): 口令不正确（…）`），与「只显示原文」的口径不一致。

两条都会在 ④ 的日志里被 `note()` 记下来（`★` 开头），不参与 OK/BAD 判定。
