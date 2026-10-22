# Agent Note: native-media 诊断 job 从没编过 Rust 核心 —— 它的失败读数是自证的

Status: implemented

> 同域：[CI 上「静默 skip」比「红」更危险](../process/2026-10-19-silent-skip-is-worse-than-red-in-ci.md)
> ——同一族：一个永远红的 job 与一个永远 skip 的 job 都等于没有读数；本篇处理的是
> 「红得没有信息量」那一半。
> 同域：[改了 Rust 却测到旧代码 —— DLL 漂移是静默的](2026-10-19-dll-drift-silently-tests-old-code.md)
> ——同一根轴的两端：那一篇讲「被测的 dll 是旧的」，本篇讲「根本没有 dll」。
> 两者都不会让任何门禁给出可读的结论。
> Independent: 本篇既不是「skip 与红的取舍」，也不是「核验要看内容」，
> 而是**一个 job 的输入（它依赖的二进制）根本没人构建**，因此它报的每一个失败
> 都不是被测代码的失败。这是环境问题伪装成代码问题的最典型形状。

## Problem

`.github/workflows/build.yml` 的 `native-media` job 在 v1.4.0-rc3（run 39548783317，
job 119052952529）上报 `+219 ~5 -31`，日志被当成「libmpv 缺失 ⇒ 播放内核没装好」，
并写进了上一轮的结论：**「libmpv-2.dll 缺失 740 行」**。

逐行数日志（541 KB / 4412 行）后，这个结论是错的：

```text
· `Failed to load dynamic library 'sourin_core.dll'` (error code: 126)  → 723 行
· `libmpv-2.dll`                                                       → 15 行
  且这 15 行**全部是 workflow 脚本自身的回显文本**（第 6 步那段 pwsh 源码），
  不是运行期报错 —— 也就是说「libmpv 缺失」的证据一条都没有。
· `did not complete`                                                    → 1 行
  （tearDownAll of test/zz_ops13_resume_read_test.dart，即原生崩溃的余波）
```

根因在依赖图上：

```text
· 该 job 的步骤是：检出 → 装 Flutter → 装依赖 → 编 Windows 原生（拿 libmpv）
  → 核验 libmpv 就位 → 跑测试。**没有 cargo build**。
· `cargo build --release` 只出现在 windows job（:369）与 macOS job（:860）。
· 而 lib/core/ffi.dart:298 是 `DynamicLibrary.open('sourin_core.dll')` —— **裸名**，
  依赖进程的 DLL 搜索面（应用目录 / 系统目录 / **当前工作目录** / %PATH%）。
  `flutter test` 的 cwd 是仓库根，而 dll 在 rust/sourin_core/target/release/ ⇒ 找不到。
```

于是那 31 条失败是**同一个原因**、且**不是被测代码的失败**：所有打了
`--tags native-media` 的用例都要真加载 Rust 核心，核心不在 ⇒ 全部
`error code: 126`。列表（实测）：t104 / t108 / t27 / t92 / zz_cr_* / zz_ops13_* /
zz_r65_error_shots / zz_rewatch_prompt / zz_t1015b / zz_t66_danmaku_send_predicate×8 /
zz_t66_r6b_live_toggle。

## Decision

四件事，第 1 件是根因，其余是「让下一个人不再误读」：

```text
① 该 job 自己编 Rust 核心：装 Rust（dtolnay/rust-toolchain@stable）+
   Swatinem/rust-cache@v2（workspaces: rust/sourin_core）+
   `cargo build --release`（working-directory: rust/sourin_core）。
   为什么不让它下 windows job 的产物：跨 job 传二进制要 artifact 上传/下载，
   多一次存储与解压、且与「诊断」这个定位不符（诊断 job 自给自足才不会
   因为上游 job 改了就变哑）。重复 3 分钟的编译换「这个 job 的读数只取决于它自己」。

② 把 dll 放进**测试进程真的会搜的地方**，并且**按裸名真加载一次自检**：
   拷一份 sourin_core.dll 到仓库根（= flutter test 的 cwd），
   再把 rust/sourin_core/target/release 与 build/windows/x64/libmpv 两个目录
   写进 $GITHUB_PATH 并前置到当前 $env:PATH；然后用
   [System.Runtime.InteropServices.NativeLibrary]::Load('sourin_core.dll' /
   'libmpv-2.dll') 各加载一次，失败即 ::error:: + exit 1。
   ★ 为什么要这步自检：Dart 侧的失败信息只有 `error code: 126`，
     它分不清「路径没配好」与「dll 有但缺依赖」。在 pwsh 里按**同一个裸名**
     加载，就把「搜索面是否成立」这件事在测试开始前变成一句明确的红。

③ 测试步把 stdout/stderr tee 到 native-media.log，并**原样带出 flutter 的退出码**
   （$LASTEXITCODE 为 $null 时按 1 处理；不把 79 抹平成 1）。
   ⇒ 下游汇总步才有得可数，且「真红的码」不被改写。

④ 汇总步（continue-on-error: true，仍然不阻塞合并）**按读数分类**而不是堆日志：
   前置件缺失 / 无日志 / dll 加载失败为主因 / 全过 / did not complete 为主 /
   [E]>0 断言失败 / 「红在测试开始之前」（rc≠0 但 [E]、dnc、126 全为 0 ⇒
   失败发生在 fixture / pub get / flutter build 阶段）。
```

两个实现细节是踩出来的，不是想出来的：

```text
· Select-String 必须 -SimpleMatch：`[E]` 走正则会被当成字符类 ⇒ 数出假 0。
· $ErrorActionPreference 必须是 'Continue'：设成 'Stop' 时
  `2>&1 | Tee-Object` 遇到第一条 stderr 会抛 NativeCommandError 直接中断脚本，
  ⇒ $LASTEXITCODE 读不到真值 ⇒ **真红变假绿**。实测 rc=3 在 'Continue' 下才正确复现。
```

## Alternatives considered

**A. 让 native-media 下载 windows job 的 artifact（复用已编好的 dll）**
最强理由：不重复编译，3 分钟一次；而且能保证「诊断 job 测的就是要发布的那个二进制」——
这其实比自编更接近用户手上的东西。
否决理由：它引入跨 job 依赖，于是这个 job 的读数开始取决于上游 job 是否成功、
artifact 是否过期、名字是否对上；一旦上游改名，native-media 会以一堆
`error code: 126` 静默退化成「什么都没诊断」—— 与本篇要修的 bug 同形。
诊断 job 的价值是"永远能给读数"，不是"省 3 分钟"。

**B. 修 lib/core/ffi.dart，让 `DynamicLibrary.open` 带完整路径（而不是改 CI）**
最强理由：治的是产品代码本身 —— 打包后如果 cwd 不对，同一个裸名问题会在
用户机器上重演；路径解析应该由代码负责一次，而不是每个调用方各配一遍环境。
否决理由：本仓的打包产物是同目录携带 dll 的（安装包把 sourin_core.dll 放在
exe 旁边），那时裸名是对的、也是**唯一**能在安装后不同目录下工作的写法。
把它改成绝对路径会让用户机器上的安装位置写死。⇒ 真正该改的是**测试环境**
（让 cwd / PATH 模拟安装后的布局），不是产品代码。

**C. 让 job 继续红着，只把汇总步写清楚（不动根因）**
最强理由：改动最小、零风险；而且汇总步已经能把「dll 缺失」这件事说清，
下一个人不会再误读成 libmpv 问题 —— 症状治理已经达成。
否决理由：一个 100% 因为环境而红的 job 会训练所有人忽略它（这正是它现在
「失败着等于诊断价值为零」的状态）。**读数正确的红**与**读数正确的绿**是两件事，
前者不能替代后者。

## Consequences

- **收益**：native-media 变成**真的在测**那 55 条原生用例；失败信息能直接指到
  「前置件 / dll 加载 / 断言 / 未跑完 / 红在开始前」中的一类，不必再数 700 行日志。
  本轮修复前那 31 条失败是环境性的，修复后如果还红，才是真问题。
- **代价**：job 时长增加约 3 分钟（冷缓存更多），`timeout-minutes` 45→60；
  60 分钟是否够吃冷缓存**没有数据**，只能等第一次真跑。
- **仍然不阻塞合并**：`continue-on-error: true` 原样保留。原生崩溃导致的
  `did not complete` 是已知的 flaky（dart_test.yaml:57 已串行化但仍会红），
  那条不在本篇范围内。
- **未验**：CI 侧全部未验（本机 github.com 不可达、无 flutter）。
  要盯两处：`跑 native-media 硬门禁` 的 `$LASTEXITCODE` 是否真拿到 79/1；
  `Tee-Object` 在 `flutter.bat`（cmd shim）下是否完整落盘。
  pwsh 步骤在本机用 PS 5.1 近似验过（两处 5.1-only 差异已在注释里标明，
  对 runner 的 pwsh 7 不成立）。
- **何时翻案**：
  ```text
  · 若 CI 上仍然出现 `error code: 126`，说明搜索面判断错了（例如 flutter_tester
    的 cwd 不是仓库根）⇒ 应以实测 cwd 为准改 ②，而不是继续加 PATH。
  · 若 Rust 编译时间把 job 推到 60 分钟以上 ⇒ 改成复用 artifact（方案 A），
    但必须同时给 artifact 缺失加一条响亮失败，否则又会退化成静默。
  ```
