# Agent Note: Windows runner 上跑多命令门禁必须显式 shell: bash

Status: implemented

## Problem

把笔记门禁接进 CI 时，Windows job 里写的是三条命令串跑（tree / format / archived）。
第一版没写 `shell:`，于是走 windows-latest 的默认 shell —— **pwsh**。

故意把一篇笔记的 `Status` 改错后实测：

```text
tree    → ok
format  → format: ... — line 3 must match implemented status grammar
archived→ ok
整步退出码 → 0
```

门禁报了错，但 job 是绿的。这是**假绿**：日志里有红字，而 CI 判据（退出码）说通过。
CI 上没人会逐行读日志，所以它等价于这条门禁不存在。

成因不是脚本写错：pwsh 里 `$ErrorActionPreference = 'Stop'` 只管 cmdlet 抛错，
**不管外部程序的退出码**；runner 只在脚本**末尾**补一次 `exit $LASTEXITCODE`，
于是中间那条命令的失败被后面那条的成功覆盖掉了。

## Decision

Windows job 里凡是**多命令串跑且以退出码为判据**的 step，一律显式写 `shell: bash`，
并在脚本开头 `set -euo pipefail`。

单命令 step 不必改（它末尾就是第一条，`$LASTEXITCODE` 恰好正确），
但只要出现「命令 A 失败、命令 B 成功」的可能，就必须改。

## Alternatives considered

- **保持默认 pwsh，改成逐条判断退出码** —— 它最强的论据是不改变 runner 的既有约定，
  与 job 里其它 pwsh step（例如拷 `.dll` 后 `Test-Path` 核验）风格一致。
  否决理由：每条命令后面都要跟一段 `if ($LASTEXITCODE -ne 0) { exit 1 }`，
  漏一处就复现同一个假绿；而 `shell: bash` 是一次性表达，没有可漏的点。

- **把三条命令合成一条 `npx tsx a && npx tsx b && npx tsx c`** —— 它最强的论据是
  不依赖 shell 语义。否决理由：`&&` 在 pwsh 与 bash 里都能用，但仍需确认
  runner 对整条命令的退出码取法；且出错时定位信息会被压成一行。
  `shell: bash` + 分行更易读，失败行号也更明确。

## Consequences

- **收益**：门禁的退出码与「是否真的验过」一致；改错的笔记会让 job 真红。
  实测对照：同一份坏笔记，pwsh 退出 0，bash 退出 1 且在 format 处立即停止。
- **代价与已知上限**：同一个 job 里混用两种 shell（pwsh 用于拷文件核验，
  bash 用于门禁），读 workflow 时要看清每个 step 的 `shell:`；
  Windows runner 的 bash 是 Git Bash，`npx` 在其下的路径解析与 pwsh 略有差异
  （本例实测可用）。
- **重访条件**：GitHub Actions 改变 windows-latest 的默认 shell 语义，
  或 runner 开始对每条原生命令单独检查退出码。
