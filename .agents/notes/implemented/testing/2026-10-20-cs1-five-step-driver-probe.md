# Agent Note: CS-1 备份五步的可执行驱动探针

Status: implemented

## Problem

`docs/notes/round-66-e2e-verify.md` 自报过「CS-1 真机 56 ✓ / 7 张截图」。实测反证：

```text
全盘 t66-cs1* = 0 个文件；.probe/e2e/ 只剩 3 张弹幕代理图
⇒ 那 7 张截图从来没落在自报路径上。
```

根因不是「忘记跑」，而是**没有任何工具驱动得了那五步**：`tools/e2e_shots.ps1`
只能到页签级（切页签 → 截屏），而 CS-1 要的是「点导出 → 设口令 → 选回同一个包 →
输错口令被拒 → 再输对口令成功」这种**多步有状态**流程。没有驱动 ⇒ 「跑过了」只能靠嘴说，
而嘴说的证据在审计里等于零。

第二个问题是这类探针**容易做成假绿**：

- 只断言「对话框出现了」，被「对话框出现了但什么都没做」骗过去；
- 只看 UI 不看盘上事实（文件写没写、写了几字节、是不是合法 ZIP、登录态真的回来了没有）；
- 复用一个两天前的 `build\` 产物，跑起来一切正常，出的是旧代码的像素（见
  [../testing/2026-10-19-dll-drift-silently-tests-old-code.md](2026-10-19-dll-drift-silently-tests-old-code.md)
  记的同类事故）。

## Decision

新建 `lib/t107_cs1_flow_probe.dart`（探针入口）+ `tools/run_t107.ps1`（运行脚本），
判据用「文件/请求事实 + UI 事实」双证据，任一条为假即 BAD。

1. **根用产品自己的根**：`runApp(RepaintBoundary(SourinApp(coreError:, coreDataDir:)))`，
   不用裸 `MaterialApp`。裸根会丢掉 `AppThemeHost` / `AppScaffold` 这类祖先，
   `InkWell` 找不到 `Material` 会抛异常（整页变 ErrorWidget），断言只会以「找不到 XX」失败，
   看起来像产品缺陷。截图走 `RenderRepaintBoundary.toImage(pixelRatio: 1280/逻辑宽)`
   并断言**物理尺寸精确 1280×800**。
2. **点击直投渲染树**：`WidgetsBinding.instance.handlePointerEvent` 按 `RenderBox` 中心点
   投递，**不碰** OS 输入（`SetCursorPos` / `mouse_event` / `SetForegroundWindow` /
   `CopyFromScreen` 全禁）。系统文件选择器由 `FileSelectorPlatform` 替身接管
   （`_SaveStub` / `_OpenStub`，必须 `extends` 而非 `implements`）——
   真弹出选择器就说明走错了路，而不是「环境不支持」。
3. **五步各自带可观测的前置条件**：③/④ 之前先把本机登录态清成 0，否则
   `providers` 恒 ≥1，「恢复成功」与「什么都没发生」读数一样；② 带一个**对照组**
   （同一接口不带口令导出，断言包里 `included=false`），否则排除不了
   「口令根本没起作用、永远 included」。
4. **三道硬闸写进运行脚本**：数据目录必须落在隔离目录下（探针会写、会删/放一份假凭据）；
   产物不许比源码旧；判据只认探针自己落的三个报告文件（GUI 子系统 exe 没有 stdout）。

## 为什么探针自己写报告文件

GUI 子系统的 exe 重定向 stdout 可能一个字都拿不到 —— 这不是理论：本次实测
`Start-Process -RedirectStandardOutput` 之后日志是空的。所以探针把逐条 ✓/✗ 与
`---- 结果：OK=n BAD=m` 写进 `<数据目录>\cs1-report.txt`，机器可读行写进
`cs1-lines.txt`，异常/看门狗写进 `cs1-trace.txt`，外加一个 6 分钟看门狗兜底退出。

## 为什么机器可读行要固定字段

```text
CS1|<step>|file=<path>|bytes=<n>|sha256=<16>|ui=<断言>|verdict=OK|BAD
```

固定字段是为了**下游能机械核对**（复核者不需要读中文句子就能确认「哪一步、哪个文件、
多少字节、UI 说了什么、结论是什么」）。`ui` 字段里的竖线与换行先被清洗，保证分列不被打断。

## Alternatives considered

- **扩展 `tools/e2e_shots.ps1` 让它会点按钮** —— 否决：那是页签级截图工具，
  它的职责是「切页签 + 出图」，塞进有状态的多步流程会把两件事绑在一起，
  且它没有等待/重试/判据框架。
- **用 OS 级输入注入（`mouse_event` + 截图比对）驱动** —— 否决：AGENTS §8 明令禁止；
  且注入会抢前台焦点（本轮有别人在占窗口）。
- **直接调 `SourinApi.backupExport/backupImport` 断言返回值** —— 否决：那样测的是
  Rust 接口，不是产品路径。任务要的是「走到产品真实入口」，所以导出必须点面板上的
  「导出」，只有**选路径**那一跳允许用替身。
- **把假凭据做成真凭据** —— 否决：探针只写一个自造文件名的占位数据，
  绝不碰任何真实凭据；数据目录由 `--dart-define=DATA_DIR_OVERRIDE` 指到隔离路径，
  探针内还有同源硬闸（路径不含 `round66_cs1` 直接 `exit(3)`）。

## Consequences

- **收益**：CS-1 从「自报」变成「一条命令 + 8 张图 + 5 条机器可读行」；
  假绿的三条通路（只看 UI / 复用旧产物 / 悄悄弹系统对话框）都被堵上。
- **代价**：探针是 untracked 资产，真机取证要占一次 build 窗口；
  8 张图需要人工过一眼「该看到什么」（判据表在 `docs/notes/round-66-cs1-driver.md`）。
- **未验证**：本轮没有窗口，五步在真窗口能否跑通、替身能否接管真实选择器调用、
  各 `waitUntil` 超时是否够 —— 全部如实标注在判据表的「未验证清单」里，
  没有一个写成 ✓。已验的只有：`flutter analyze` 0 error、三个纯函数逻辑自洽
  （临时 `flutter test` `+4`）。
- **相关**：[../process/2026-10-20-e2e-shots-evidence-outdir-and-manifest-gate.md](../process/2026-10-20-e2e-shots-evidence-outdir-and-manifest-gate.md)
  把 e2e 证据挪进 git 跟踪路径；本篇补的是「同一条证据链上、页签级工具够不着的那五步」。
