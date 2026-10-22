# Agent Note: 门禁要的「提交区间」在 `fetch-depth: 1` 的检出上根本不存在 —— 手动发版必红

Status: implemented

> 同域：[2026-10-21-windows-only-gates-need-platform-guards.md](../testing/2026-10-21-windows-only-gates-need-platform-guards.md)
> （同期另一类：判据在别的平台上恒红）；
> [2026-10-21-gate-crashes-on-its-own-success-message.md](../bug-fix/2026-10-21-gate-crashes-on-its-own-success-message.md)
> （同期另一类：判据通过但工具在自己的成功通知上崩掉）。
> Independent: 本篇讲的是**门禁赖以工作的输入（git 历史）在 CI 检出配置里被裁掉了**，
> 既不是「平台假设错了」，也不是「输出编码崩了」——
> 那两篇的修法（加平台守卫、强制 UTF-8）对本篇的红灯一律无效。

## Problem

CI run `39540643339` 的 Windows job 在**第 10 步「笔记覆盖门禁」**红掉（4 分 51 秒）：

```text
没有可用的 base sha，改为只检查 HEAD 这一个提交。
✖ 无法读取提交区间，本次检查无效。
  git rev-list 失败: fatal: ambiguous argument 'HEAD~1..HEAD': unknown revision or path not in the working tree.
  这不是「已合规」—— 退出码 2。
##[error]Process completed with exit code 2.
```

三件事叠在一起才红：

1. **脚本要一个提交区间**。`notes-coverage.mjs` / `notes-supersession.mjs` 签的是
   `--range <base>..HEAD`，靠 `git rev-list` 列出这次要检查哪些提交。
2. **手动发版没有 base**。这一步的 env 是
   `NOTES_COVERAGE_BASE: ${{ github.event.pull_request.base.sha || github.event.before }}`。
   `workflow_dispatch` 事件里这两个字段**都不存在** ⇒ 环境变量是空串 ⇒
   `if [ -z ... ]` 走进回落分支，改用 `--range HEAD~1..HEAD`。
3. **检出只有 1 个提交**。Windows job 的 `actions/checkout@v4` 没写 `with:`，
   而 checkout@v4 的默认值是 `fetch-depth: 1`。于是 `HEAD~1` **不是一个存在的版本**，
   `git rev-list` 直接 `fatal: ambiguous argument`。

**这是「手动发版才走」的路径**：PR 事件有 `base.sha`，push 事件有 `event.before`，
两种情况脚本拿得到 base，`HEAD~1` 那句根本不执行 —— 所以它一直没被发现。
而本次要做的恰恰是「先推送分支再发版」，正是 `workflow_dispatch`。

### 为什么现在才红

Windows job 有 26 步，前面至少还有两道同类门禁。

| run | 红在第几步 | 原因 |
| --- | --- | --- |
| `39523046865` | 6 决策笔记门禁 | `.gitignore` 让两篇笔记没进 git |
| `39526450290` | 6 决策笔记门禁 | 同上（未修完） |
| `39538011233` | 9 发布说明守卫 | `python3` 在 windows runner 上不存在 |
| `39540643339` | 10 笔记覆盖门禁 | **本篇** |

★ 一个 job 里排队 N 道门禁，CI **每次只暴露第一道**。修好一道、下一道才露头。
这不是「越修越坏」，是「后面的终于轮到被看见」——
`git rev-list` 这一行日志从第一轮起就一直在，只是走不到。

### 本地为什么不红（又一次）

本机 `git rev-list --count HEAD` 是 300+ 提交，`HEAD~1` 当然在。
本地跑 `node .agents/notes-scripts/notes-coverage.mjs --range HEAD~1..HEAD` 一直 rc=0。

我在**浅克隆**里复现了它，与 CI 的报错逐字一致：

```text
$ git clone --depth 1 "file://<本机仓库绝对路径>" /tmp/shclo
$ cd /tmp/shclo && git rev-list --count HEAD
1
$ node .agents/notes-scripts/notes-coverage.mjs --range HEAD~1..HEAD
✖ 无法读取提交区间，本次检查无效。
  git rev-list 失败: fatal: ambiguous argument 'HEAD~1..HEAD': unknown revision or path not in the working tree.
  这不是「已合规」—— 退出码 2。
$ echo $?
2
```

同一区间、同一个脚本，在完整历史的仓库里 rc=0：

```text
$ node .agents/notes-scripts/notes-coverage.mjs --range HEAD~1..HEAD
笔记覆盖门禁通过（HEAD~1..HEAD）：检查了 1 个提交，每次受管改动都同批带了笔记。
$ node .agents/notes-scripts/notes-supersession.mjs --range HEAD~1..HEAD
supersession 检查通过（HEAD~1..HEAD）：1 篇新笔记都声明了与既有笔记的关系。
```

⇒ 「本地绿」证明的只是**完整历史下的本地绿**。

## Decision

给 Windows job 的检出步骤补上 `fetch-depth: 0`：

```yaml
      - name: 检出代码
        # ★★ 必须 `fetch-depth: 0`（完整历史）。checkout@v4 默认 `fetch-depth: 1`
        #   —— 只有 1 个提交，`HEAD~1` 根本不存在。
        #   …（完整理由见 workflow 里的注释）
        uses: actions/checkout@v4
        with:
          fetch-depth: 0
```

受它保护的门禁有三道，全在 Windows job 里、全按「提交区间」工作：

| 门禁 | 区间变量 |
| --- | --- |
| 决策笔记 archived 门禁 | `AGENT_NOTE_ARCHIVE_BASE_REF` |
| 笔记覆盖门禁 | `NOTES_COVERAGE_BASE` |
| supersession 检查 | `NOTES_SUPERSESSION_BASE` |

三道的变量在 `workflow_dispatch` 下**全是空串**，所以三道都要历史，不是只修露头那一道。

★ 本仓已有先例：`publish` job 的 checkout 早就写着 `fetch-depth: 0`，
注释还专门解释「默认 `fetch-depth: 1` + `fetch-tags: false`，`git describe` 工作不了」。
**同一条教训已经写下来过一次，只是没覆盖到 Windows job** ——
决定写在哪个 job 的注释里，就只保护那个 job。

### 顺带记下的一处措辞不实

两处回落分支打印的是「没有可用的 base sha，改为只检查 HEAD 这一个提交」，
但它实际执行的是 `HEAD~1..HEAD` —— **两个提交**。
语义（查最近一次改动）没错，措辞错了。

本次**不改这句话**：改措辞治不了红灯，而且它一改就得同时解释「为什么仍然要 2 个提交」。
在 workflow 注释里写清「按脚本真实行为给足历史，不去改那句话的语义」，
让下一个人读日志时不被它误导即可。

## Alternatives considered

- **让脚本容忍浅克隆**（区间读不到就退化成只检查工作区 / `HEAD..HEAD`）。
  否决：区间为空时门禁就变成空转，「通过」不再有任何含义 ——
  这正是 `notes-coverage.mjs` 那句「这不是『已合规』—— 退出码 2」要防的事。
  而且 archived 门禁判的是「**只增不改**」，没有历史在物理上不可能判。
- **`fetch-depth: 2`**。否决：`HEAD~1..HEAD` 确实只要 2 个提交，但 PR / push 事件的
  base 是**任意** sha（一次 push 带 10 个提交、或 PR 开了很久），depth=2 会再次
  `fatal`。「刚好够用」是碰巧，不是设计。要么给足，要么不给。
- **写成 workflow 级 `defaults:` 统一加**。否决：`macos` / `android` / `native-media`
  三个 job 不跑任何笔记门禁，全给完整历史只是让每次 CI 多克隆 300+ 提交与证据 PNG。
  只给需要的 job。
- **每次发版时人工传一个 `--fetch-depth` 之类的入参**。不成立：checkout 的深度是
  workflow 里的声明，不是运行时入参；能改它的地方只有 workflow 文件本身。
- **干脆去掉 `HEAD~1..HEAD` 回落、没有 base 就报「跳过」**。
  否决：等于把「手动发版」变成笔记门禁的免检通道，而手动发版正是我们最需要门禁的时候。

## Consequences

- Windows job 每次多克隆完整历史。本仓 300+ 提交 + 一批证据 PNG，
  代价在秒级（实测 `publish` job 一直这么做，没成为瓶颈）。
- 换来的是三道门禁在 `workflow_dispatch` 下**真的在跑**，而不是红在半路。
- 以后新增「按提交区间检查」的门禁，不必再想 depth —— 前提是它加在这个 job 里。
  加在别的 job 里，仍然要自己写 `fetch-depth: 0`。
- 何时翻案：仓库大到 `fetch-depth: 0` 成为 CI 时间的实际瓶颈时，
  改用部分克隆（`filter: blob:none` + `fetch-depth: 0`），
  它保留提交图、省掉文件内容，`git rev-list` 照样能用。**不要**退回 `fetch-depth: N`。

### 给下一个人的提醒

门禁「没跑到」和「跑过了」在日志里**长得不一样**，而 `set -euo pipefail`
不会替你说清楚。看到下面两句话当红处理，哪怕退出码被谁吞了：

```text
fatal: ambiguous argument 'HEAD~1..HEAD'
✖ 无法读取提交区间，本次检查无效。
```

反过来，要相信门禁真的绿了，就去日志里找它自己打印的**通过回执**
（`笔记覆盖门禁通过（HEAD~1..HEAD）：检查了 1 个提交…`）——
没有那行字，`##[error]` 不在也不代表它通过。
