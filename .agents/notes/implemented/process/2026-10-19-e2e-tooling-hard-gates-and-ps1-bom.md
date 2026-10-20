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

### 2026-10-20：这条判据**已经机械化**（不再靠人记）

上面那条判据原来只活在文字里 —— 结果当天就翻车了：

```text
tools/run_round66_acceptance.ps1  在 HEAD 里 BOM=3c230a（**没有**），
                                  而它有中文 ⇒ PS 5.1 下**本来跑不起来**。
⇒ 判据写在笔记里 ≠ 判据被执行。这正是本仓反复记的「散文里的规矩等于没有规矩」。
```

⇒ 新增门禁 `test/zz_t66_ps1_bom_gate_test.dart`，三条判据：

```text
① 含非 ASCII 的 tools/*.ps1 ⇒ 前 3 字节必须 EF BB BF
   作用域收窄到「含非 ASCII」：上面那 3 个纯 ASCII 脚本无 BOM 也 0 错误，
   对它们要求 BOM 属于「为门禁而改文件」。
   ★ 这条作用域收窄是**门禁自己抓到的误报** —— 第一版写的是「所有 .ps1」，
     实测红 3 个（commit_scope_guard / live_probe_count /
     n13_single_instance_test），全是纯 ASCII、无 BOM 也 0 错误。

② 每个 tools/*.ps1 **按磁盘原样** PS 5.1 解析必须 0 错误
   与 ① 正交：① 只证明"BOM 字节在"，证明不了"这份脚本现在真能跑"。
   将来有人改坏语法，① 照样绿，② 会红。

③ 故障注入：把 ① 守的脚本**切掉 BOM 造副本**，必须解析失败
   这条是「判据的判据」—— 若切 BOM 也无害，① 就是假门禁。
```

**实测基线（2026-10-20，PS 5.1 / code page 936）**

```text
tools/e2e_shots.ps1
  有 BOM（53380 字节）⇒ PARSE_ERRORS=0
  切掉前 3 字节（53377）⇒ **PARSE_ERRORS=50**
      L196 表达式或语句中包含意外的标记"}"
      L229 表达式或语句中包含意外的标记"$("
      L229 表达式中缺少右")"
      L270 表达式或语句中包含意外的标记"manifest.json:"
```

⇒ 50 个错误不是"可移植性隐患"，是**当下就跑不起来**。

### ★ 判据的作用对象：必须"先构造副本再测"

这条是本篇最值得留给后人的坑（同一天踩了第 5 次）：

```text
❌ 直接解析磁盘上那个文件
   ⇒ 测的是「那个文件此刻能不能解析」，**不是**「无 BOM 能不能解析」
   ⇒ 而它此刻有 BOM ⇒ 永远 0 错误 ⇒ 门禁永远绿

✅ 读字节 → 断言 BOM → **构造切掉 BOM 的临时副本** → 解析副本
   副本还要两道自检：① 真的没有 BOM ② 长度正好少 3 字节
```

我第一版判据③写成了「切掉 BOM 后必须 0 错误」——**写反了**，永远红。
正确写法是「切掉 BOM 后必须**报错**」。方向搞反的判据比没有判据更费时间。

### 全量扫描读数（2026-10-20，tools/ 下 10 个 .ps1）

```text
commit_scope_guard.ps1        BOM=23203D  nonASCII=0      ERRORS=0
e2e_checklist.ps1             BOM=EFBBBF  nonASCII=381    ERRORS=0
e2e_shots.ps1                 BOM=EFBBBF  nonASCII=2778   ERRORS=0
live_probe_count.ps1          BOM=23203D  nonASCII=0      ERRORS=0
n13_single_instance_test.ps1  BOM=23203D  nonASCII=0      ERRORS=0
run_client.ps1                BOM=EFBBBF  nonASCII=3808   ERRORS=0
run_round66_acceptance.ps1    BOM=EFBBBF  nonASCII=21     ERRORS=0
run_t107.ps1                  BOM=EFBBBF  nonASCII=6147   ERRORS=0
seed_dev_data.ps1             BOM=EFBBBF  nonASCII=12791  ERRORS=0
verify_shots.ps1              BOM=EFBBBF  nonASCII=30     ERRORS=0
```

⇒ 「BOM 存在」与「含非 ASCII」**完全对应**（7 有 3 无），无一例外。

### 顺带查清的并发写入事故（2026-10-20 23:38–23:40）

`tools/e2e_shots.ps1` 在 33 秒内被两种写法交替覆盖，BOM 反复丢失/恢复：

```text
23:38:14  size=53002  BOM=EFBBBF  md5=9fa8aafa…
23:39:49  size=53377  BOM=3C230A  md5=591dbb68…   ← 丢 BOM
23:40:22  size=53380  BOM=EFBBBF  md5=fc193e7e…   ← 回来
```

同批指纹：`e2e_shots.ps1` / `run_round66_acceptance.ps1` /
`check-doc-capability-wiring.mjs` 三个文件 mtime 相差 < 1 秒
（23:40:22.974 / .979 / 23:40:23.209）⇒ 那一次是**同一执行者**批处理写的。

**具名执行者查不到**（无进程持有句柄、无风格痕迹、无 commit 归属）——
如实记「查不到」，不猜。这条事故本身的价值是：**并发写同一文件不会报错，
只会静默少掉改动**，所以本门禁要能独立于"谁写的"判定文件当前是否可用。

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