# Agent Note: 笔记门禁在三处会静默放行

Status: implemented

## Problem

三道笔记门禁（tree / format / archived）加上 supersession 与 coverage 两道附加门禁，
一直在 CI 上跑、一直是绿的。2026-10-22 拿真实仓库逐条试它们的**否定面**，发现三处
「本该红的地方是绿的」，而且都发生在最需要门禁的场景：

1. **archived 对「基线查不到」一律放行。** 旧实现是
   `git show <baseRef>:archived/manifest.json` 包在 `try/catch {}` 里，注释写的是
   「manifest absent at baseline — nothing to compare」。于是这三种情况都
   `exit 0` 并打印 `ok: 1 archived note(s) verified`：
   `AGENT_NOTE_ARCHIVE_BASE_REF=refs/heads/不存在`、`…=40 个 0`、以及不在 git 仓库里。
   第二种不是理论情形 —— **CI 在新分支首次 push 时 `github.event.before` 就是 40 个 0**，
   而那正是「有人刚建立分支、准备第一次改动封存区」的时刻。
   封印的 append-only 属性因此在这条路径上等于不存在。

2. **supersession 把合法链接判成「没写链接」。** markdown 里指向另一篇笔记的相对链接有三种
   合法写法：普通行内链接、圆括号里用 `< >` 包住路径（**路径含空格时只能这样写**）、
   以及路径后追加一个双引号包裹的标题。旧正则只认第一种，后两种一律判「没写链接」。
   后果不是放行而是**误拒**：一篇明明带了互链的合规笔记被挡下，提示还让人「去加链接」。
   误报的门禁会被绕过，这条比放行更贵。

   > 本段刻意不写示例源码：tree 门禁按行扫 `.md` 里的链接语法，
   > 写在这里的示例会被当成真链接去解析（同一轮里踩过）。示例放在
   > `notes-selftest.mjs` 的用例名里 —— 那份是 `.mjs`，不进链接扫描。

3. **archived 在路径别名下红在与内容无关的地方。** 清单路径原来用
   `relative(repoRoot, manifestPath)` 算。`repoRoot` 来自 git
   （`C:/Users/<长用户名>/…`），`manifestPath` 来自 Node 的路径解析
   （Windows 8.3 短名 `C:\Users\IUUUUU~1\…`）。两个字符串指向同一目录但字面量不同，
   `relative()` 算出 `../../../../IUUUUU~1/…`，`ls-tree` 直接报
   `is outside repository`。**门禁红了，但红的原因与封印一个字节无关** ——
   这种红会训练人「反正它老红」。

三处共同点：没有任何测试会让它们变红。门禁写错时唯一的外部表现是一个
看起来正常的退出码，所以只能靠人偶尔去试否定面才可能发现。

## Decision

三道判断改成可证伪的：

- **archived 基线 fail-closed。** 顺序是：全零 ref → 直接失败（文案说明「本次没有可比
  基线，append-only 校验没有执行」，并指向 merge-base / PR base）；
  `git rev-parse --verify --end-of-options <ref>^{commit}` 解析失败 → 失败；
  唯一放行是 `baseRefRaw === "HEAD"` 且 `git rev-parse --verify --quiet HEAD` 为空
  （仓库还没有第一个提交）。用 `git --literal-pathspecs ls-tree --full-tree -z <oid> -- <manifestRel>`
  区分「基线里确实没有清单」（无可比）与「查询失败」（红）——
  `git show` 对这两种都抛同样的错，分不开。
- **CI 侧把基线算出来，而不是赌 event 字段形状。** 顺序：PR → `base.sha`；
  push → `event.before`（仅当它是真提交：非全零、`rev-parse` 通过）；
  兜底 → 默认分支的 merge-base。三条都拿不到就 `::error::` 退出。
  **不回落 HEAD**：HEAD 自比自 = 当前 manifest 跟自己比，一个字节都不会变红。
- **supersession 认三种链接写法。** 正则改成
  `\]\(\s*(?:<([^>]+\.md)(?:#[^>]*)?>|([^)\s]+\.md)(?:#[^)\s]*)?)(?:\s+"[^"]*")?\s*\)`，
  取值 `m[1] ?? m[2]`（与 `dsh-agent-notes` 插件的同一处修复逐字一致，避免两处各长一个样）。
- **清单路径不跨体系比较。** git 只回答「仓库根→当前目录」这一段
  （`git rev-parse --show-prefix`），「当前目录→清单」这一段用 Node 的 `process.cwd()`
  算：两边各自只比自己体系的路径。

## Alternatives considered

- **保留 `catch {}`，只在文档里写清「基线缺失时不做 append-only 校验」。**
  这条最强的地方是「不误伤」：环境不完整时（浅克隆、无 git 的发布包）门禁不挡人。
  但它把「我知道没查」这个事实只留在注释里 —— 而 CI 日志里写的是一句
  `ok: 1 archived note(s) verified`，读日志的人不会去翻脚本注释。
  一个报「已校验」却什么都没校验的门禁，比没有门禁更坏：它消耗的正是对绿勾的信任。
- **基线缺失时打印 warning 并放行（只对全零 sha 放宽）。**
  这是最省事、也最容易被采纳的选项：CI 全绿，日志里多一行黄字。
  否决理由是概率而非洁癖：全零 sha 出现的时刻（新分支首推）恰好是
  「有人开始碰封存区」的时刻，把唯一的检查降级成 warning，等于在最需要它的那一天关掉它。
  真要放宽，应当放宽到「能算出 merge-base」这种**有真实基线**的情形，而不是放宽到「没有基线也行」。
- **给 supersession 加 `--allow-plain-links-only` 之类的开关，让 CI 用严格模式、本地用宽松模式。**
  否决：同一个判据在两处表现不同，本地绿 CI 红的原因就会变成「你用了哪个模式」，
  而不再是「你的笔记缺什么」。误拒一次的成本远低于这种迷雾。
- **把清单路径改成硬编码 `archived/manifest.json`。**
  在本仓（脚本总在仓库根跑）当下是对的，但它把「cwd 一定在仓库根」变成隐含前提，
  谁哪天从子目录调一次就拿到一个假红。用 `--show-prefix` 只多一次 git 调用。

## Consequences

- **收益**：三处判据现在**能红**，且红的原因指向内容本身（封印被改写、ref 拼错、
  笔记没声明关系），而不是路径或环境。`notes-selftest.mjs` 把这件事变成可执行事实：
  15 条用例逐条断言具体退出码，正向（应 0）与反向（应非 0）成对。
- **代价与已知上限**：
  - CI 多了一步 `npx`/`node` 探测与一次 `git fetch`（算 merge-base 用，失败不致命）。
    私有 fork 且无远端时 merge-base 取不到 → 会红。这是有意的，但**需要知道**：
    纯本地仓库第一次被 CI 跑时会遇到它。
  - archived 门禁现在会对「浅克隆 + 无可用基线」红。`ci-gate-needs-full-git-history`
    那篇记的就是这件事，两者是同一个前提，不是新约束。
  - supersession 的正则仍未覆盖参考式链接（正文 `[文字][ref]` + 定义行 `[ref]: 路径.md`）。
    认不出的方向是**少算链接**，
    即可能仍误拒 —— 但那种写法在本仓零使用（grep 过），且新增写法时 selftest 会先红。
    重访信号：一旦有人开始用参考式链接。
  - 「基线里没有清单」仍然放行。这是真正无可比（该提交早于封存区建立），
    不是漏查；但**它无法区分**「封存区是这次才建的」与「有人把 manifest 从历史里删了」。
    重访信号：如果哪天要给封存区做「不许删」的强保证，就得改成对照首个含封存区的提交。

## Verification

```bash
# 三道门禁 + 空树判据
node .agents/notes-scripts/notes-gate.mjs                  # → 三道全过（130 篇）

# 否定面：基线不可用必须红
AGENT_NOTE_ARCHIVE_BASE_REF=refs/heads/nope node .agents/notes-scripts/verify-archived-agent-notes.ts   # exit 1
AGENT_NOTE_ARCHIVE_BASE_REF=$(printf '0%.0s' {1..40}) node .agents/notes-scripts/verify-archived-agent-notes.ts  # exit 1
AGENT_NOTE_ARCHIVE_BASE_REF=HEAD node .agents/notes-scripts/verify-archived-agent-notes.ts              # exit 0

# 全部判据（夹具在临时 git 仓库里现造现删）
node .agents/notes-scripts/notes-selftest.mjs              # → 17/17
```

2026-10-22 晚补记：本篇说的「判据写错时没人发现」后来又遇到第三个实例 ——
format 门禁的遮蔽器只认围栏代码块、不认行内代码，导致一篇记录 HTML 注释语法的笔记
把自己后面的 `## Consequences` 遮掉，门禁报「缺小节」而笔记里明明写着。
那个缺陷**会被本仓的自测漏掉**，因为自测夹具里没有「笔记正文出现自己的元字符」这种形态。
详见 [./2026-10-22-note-format-gate-masks-inline-code.md](./2026-10-22-note-format-gate-masks-inline-code.md)。
本篇的三处判定不放宽，只在自测里补了那两条对照用例。

相关：[门禁必须有能力红](../testing/2026-10-12-gates-must-be-able-to-fail.md)、
[笔记门禁需要自测](../process/2026-10-22-note-gates-need-a-selftest.md)、
[格式门禁遮蔽行内代码](./2026-10-22-note-format-gate-masks-inline-code.md)。
