# Agent Note: 取证脚本要自带硬门禁，且含中文的 .ps1 必须带 UTF-8 BOM

Status: implemented

Independent: 与本轮其它笔记都不同 —— 那几篇分别讲
[更新说明生成](../process/2026-10-19-release-notes-generated-from-git.md)、
[判别式](../testing/2026-10-19-criteria-must-distinguish-cause-and-ciphertext.md)、
[证据型红](../testing/2026-10-19-evidence-gate-that-is-red-on-purpose.md)、
[弹窗收拢](../feature/2026-10-19-dialog-shell-unification-and-hover-sticky-bit.md)。
本篇讲**取证工具链**：脚本本身如何证明自己没坏。

## Problem

第 66 轮批末要交一份可复跑的实测清单。但「写个脚本跑一遍」这种做法，
本会话已经出过四次事故（`MEMORY` 里逐条记着）：

```text
· Playwright 首次跑要下浏览器（1.1 GB）⇒ 半路失败
· 30 个 `.dart` 全量 analyze 出 147 个 lint ⇒ 「不跑」与「跑」都不划算
· 每项都手工做，工作流里**没有任何东西会失败**
· 编码假设泄漏：按 ANSI 解码 UTF-8，「锘?=」吃掉下一行
★ 共同点：**脚本会"看起来跑过了"，而没人验证它是否真的在验东西**
```

⇒ 所以这四个脚本的每一步都必须是**硬门禁**（失败即非零退出）。

## Decision

### 每个脚本都有硬门禁

```text
e2e_checklist.ps1   5 处 exit 非零；**未知的 check type 直接硬失败**
                    （不认识的类型静默跳过 = 清单在腐烂而无告警）
e2e_shots.ps1       文件头自述三大事故；每一步都是硬门禁
verify_shots.ps1    守「截图存在 ≠ 截图是那个页面」——
                    截图必须逐张核过内容，不能只看文件在不在
e2e_checklist.json  每条**必须声明 auto / manual**
                    （不声明 = 不知道它该怎么被验）
```

★ `e2e_checklist.json` 里 43 条引用的测试文件**全部存在**（0 缺失）——
清单自身先自证。这类清单最常见的腐烂方式就是「引用的文件被改名」。

### 三个 `.ps1` 加 UTF-8 BOM

```text
现象：PS 5.1 执行时**解析崩溃**
  tools/e2e_checklist.ps1:62  Missing expression after ','.
根因：文件是 UTF-8 **无 BOM**，PS 5.1 按系统 ANSI（GBK）解码
     ⇒ 中文注释字节被吃成乱码 ⇒ 乱码吞掉换行 ⇒ param() 跨行断裂
```

⇒ 加 BOM。**这不是新发明，跟仓库先例一致**：

```text
tools/run_client.ps1         BOM=efbbbf  ← 含中文 ⇒ 带 BOM
tools/seed_dev_data.ps1      BOM=efbbbf  ← 含中文 ⇒ 带 BOM
tools/commit_scope_guard.ps1 BOM=3c230a  ← 纯 ASCII ⇒ 不需要
tools/n13_single_instance_test.ps1 BOM=23203d ← 纯 ASCII ⇒ 不需要
```

★ 判据：**脚本里有中文才需要 BOM**，纯 ASCII 的加了反而多余。

### 路径不写死

`e2e_shots.ps1` 里原先写死了本机 Flutter 路径 ⇒ 改成 `$env:FLUTTER_BIN`。

## Alternatives considered

**A. 在脚本头加 `#requires -Version 7` 或显式报错要求 pwsh 7。**
最强理由：改动最小，一行。
否决理由：**这是个假门槛**。PS 5.1 是在**解析阶段**崩的 ——
它还没执行到能读 `#requires` 那一步。
⇒ 要让 5.1 能用，只能解决编码本身。

**B. 把脚本里的中文注释全改成英文，从根上避免编码问题。**
最强理由：不需要 BOM，也不需要任何人理解编码。
否决理由：这三个脚本的价值很大程度在**中文注释**里
（它们记录的是事故与踩坑，写给中文维护者看）。
★ 而且仓库已有先例是「中文 + BOM」，改成英文反而破坏一致性。

**C. 不加 BOM，改为在文档里写「必须用 pwsh 7」。**
最强理由：文档一行，比改三个文件省事。
否决理由：`tools/` 下的脚本**任何人都会直接双击或 `powershell` 跑**，
不会先读文档。而 CI 用 `shell: pwsh` 是安全的 —— 这意味着
**只有本机用户会踩**，而他们恰恰是最需要它能跑的那批人。

## Consequences

**验证（PS 5.1，此前会崩）**

```text
三个脚本 PSParser::Tokenize ⇒ 全部 PARSE OK
e2e_checklist.ps1 -List     ⇒ exit=0，43 条正常列出
```

**已知上限**

```text
· 只在本机验证了 **Windows PowerShell 5.1**。
  pwsh 7 未在本机安装 ⇒ 「BOM 在 7 下也正常」是**推断**，
  依据是 BOM 是 Unicode 标准的一部分，PS 7 默认读 UTF-8。
  ★ 若本机装了 pwsh 7，应补一次实跑。
· `e2e_checklist.json` 的 43 条**内容正确性**没有逐条人工复核 ——
  只验证了「引用的文件都存在」。一条指向错误测试的清单项照样能过。
```

**何时该翻案**

```text
· 若将来统一要求 pwsh 7（并在 CI 里强制），BOM 就不必再加新的，
  但**已加的不要去掉** —— 去掉会让本机用户回到崩溃。
· 若 checklist 增到 100+ 条，应给它自己的门禁
  （例如「每条引用的文件仍存在」的自动检查），
  否则清单会随重构悄悄腐烂。
```