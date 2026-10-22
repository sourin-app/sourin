# Agent Note: 格式门禁的遮蔽器只认围栏、不认行内代码

Status: implemented

- 日期：2026-10-22
- 适用：`.agents/notes-scripts/verify-agent-note-format.ts`、`.agents/notes-scripts/notes-selftest.mjs`

接在 [../process/2026-10-22-note-gates-need-a-selftest.md](../process/2026-10-22-note-gates-need-a-selftest.md)
与 [./2026-10-22-note-gates-passed-vacuously.md](./2026-10-22-note-gates-passed-vacuously.md)
之后：那两篇讲的是「门禁判错时没人发现」，本篇是**第三个实例**，
而且是那两篇建立的自测体系**抓不到**的一类 —— 判据在特定**笔记内容**下才错。

## Problem

`maskSource()` 先把笔记切成「围栏代码块」与「HTML 注释」两种不透明区，
`isProseLine()` 再把落在这些区里的行排除掉，之后格式判据（`## Decision` 等必备小节）
只看剩下的散文行。这个设计本身没问题，问题在它的状态机怎么认注释：

```ts
const openIdx = inComment ? -1 : l.indexOf("<!--");
const closeIdx = l.indexOf("-->");
```

`indexOf` 直接扫**原始行文本**，于是**行内代码里的 `<!--` 也被当成真注释的开头**。

2026-10-22 触发它的是一篇记录 `<!--` 这个语法的笔记
（[./2026-10-22-release-notes-renderer-shows-markup-as-text.md](./2026-10-22-release-notes-renderer-shows-markup-as-text.md)）。
它必须写出 `<!--` 才能说明问题，而这串字符出现在行内代码里、且**同行没有 `-->`**：

```text
第 54 行  ③ 注释未闭合：从 `<!--` 起全部跳过
第 70 行  **② 只在「源头」拦：把 `<!--`、`---` 加进生成器的校验…**
第 78 行  **③ 把 `<!--` 当正文但**转义**显示。**
```

`inComment` 在 54 行打开，之后没有任何一行带 `-->` ⇒ 一路吃到文末。
第 82 行明明写着 `## Consequences`，却因为落在注释区被判成非散文行 ⇒
CI 报 `missing one of ["## Consequences", …]`，而笔记里那句话就摆在那里。

**为什么本地也复现、CI 也红，却一直没被当成门禁的错**：报错文案说的是「缺小节」，
第一反应永远是「笔记写漏了」。只有把第 54/70/78 行的 `<!--` 临时改掉、门禁立刻转绿，
才能确认是判据错而不是笔记错。也就是说 —— **这个 bug 会让人去改笔记，而不是改门禁**，
而笔记里那些 `<!--` 恰恰是它该记录的事实。这是最坏的一种门禁缺陷：
它诱导维护者销毁证据来迁就工具。

## Decision

新增 `blankInlineCode(line)`，把行内代码**抹成等长空格**，`maskSource()` 用它做状态机判定：

```ts
const scan = blankInlineCode(l);
if (!inComment && /^\s{0,3}```/.test(scan)) { … }
const openIdx = inComment ? -1 : scan.indexOf("<!--");
const closeIdx = scan.indexOf("-->");
```

三条实现约束：

1. **等长替换**（`" ".repeat(close + ticks - i)`），不是删除 —— 字节偏移不变，
   同一行内后续内容的列位置不变，报错行号仍等于原文件行号。
2. **闭合反引号串必须等长**：`` `x` `` 与 ``` ``x`` ``` 是两种围栏，
   `line.indexOf("`".repeat(ticks), i + ticks)` 才对得上。
3. **找不到闭合就按字面保留反引号**，不吞掉本行其余内容 —— 与 Markdown 语义一致
   （未闭合的反引号就是普通字符）。这一条防的是「遮蔽器把整行抹掉」这种更隐蔽的假绿。

`lines` 仍返回**原文**（`isProseLine` 读原文），只有状态机读遮蔽后的文本。

## Alternatives considered

**① 在笔记里避开 `<!--`（改写、转义成 `&lt;!--`、或说「注释起始符」）。**
最强的理由：一行字就能让门禁转绿，成本几乎为零，而且是当下的阻塞。
否掉的原因：这篇笔记的**全部价值**就是记录 `<!--` 这个语法在更新说明里会造成什么后果。
把 `<!--` 改写成 `&lt;!--`，读者要在大脑里做一次反转义才能看懂问题；
而「说『注释起始符』」等于用自然语言描述一个精确的字节序列，正是这类笔记最不该做的事。
更根本的是：**这个缺陷不是只对这篇笔记成立** —— 任何笔记只要记录 HTML 注释语法、
或者贴一行带 `<!--` 的 shell 片段（未闭合），都会中招。改笔记只是把地雷推给下一个人。

**② 只把 `indexOf` 换成「排除行内代码的正则匹配」。**
最强的理由：改动更小，不引入新函数。
否掉的原因：正则要同时处理反引号配对、等长围栏、跨行状态，写出来的表达式没人能读、
也没法加正向/反向对照用例。抹空格的做法把「哪些字节不是内容」这件事变成一个
可单独测试的纯函数，`notes-selftest.mjs` 能直接钉住它。

**③ 顺手把三个兄弟脚本（tree / supersession / archived）一起加同样的遮蔽。**
最强的理由：同一套遮蔽逻辑，四份复制迟早漂移。
否掉的原因：实测 grep（`indexOf|inFence|commented`）确认**只有 format 这一个脚本**
做注释遮蔽，其余三个根本不解析注释 ⇒ 加进去是没有输入的空逻辑。
真要复用，应当先有第二个消费者再抽公共模块，而不是现在猜一个。

## Consequences

收益：

- 记录 HTML 注释语法的笔记不再把后面的必备小节吞掉；门禁不再逼人改笔记。
- 遮蔽器有了**正向 + 反向**两条自测：正向（行内 `<!--` 未闭合 ⇒ 必须绿）
  证明遮蔽生效，反向（真的未闭合注释 ⇒ 必须红）证明没把注释遮蔽整个废掉。
  只有正向会退化成「注释永远不生效」，只有反向会退化成「行内代码永远不生效」。
- 报错行号仍等于原文件行号（等长替换的直接结果），不需要另做行号映射。

代价：

- 状态机读的文本与 `lines` 返回的文本**不再是同一份**。这是刻意的（一个给判据、
  一个给报错），但它是一个新的隐含契约：以后谁在 `maskSource()` 里加新判据，
  必须知道「读 `scan` 还是读 `l`」是有区别的。函数注释里已写明。
- 遮蔽器仍只认反引号这一种「非内容」容器。缩进式代码块（4 空格）里的 `<!--`
  依然会打开注释状态。**没有修**：本仓笔记规范要求围栏代码块，缩进块不在约定内，
  真出现时应当先补规范而不是先补遮蔽。
- 这是「按内容触发的判据缺陷」的第三个实例（前两个见上面两篇）。它们共同的教训是
  **门禁的自测必须包含「笔记里出现自己的元字符」这类用例**，否则自测只覆盖了
  自测作者想到的形态。

## Verification

- `node .agents/notes-scripts/notes-gate.mjs` ⇒
  `ok: 137 note(s) verified` + `ok: 1 archived note(s) verified, 1 seal(s) in manifest`
  + `三道门禁全部通过（138 篇笔记）`（修前：`format:` 那行报缺 `## Consequences`）
- `node .agents/notes-scripts/notes-selftest.mjs` ⇒ `notes-selftest: 17/17 通过（runner=node）`
  （原 15 条 + 本篇新增的正向/反向 2 条）
- **红过才算数**：新增的两条用例里，正向那条在修 `blankInlineCode` 之前是红的
  （`exit 1`，正是 CI 报的同一个错）；反向那条在修前修后都必须绿，用来证明
  遮蔽器没有把「真注释」也一起放过。
- 手工复现：`AGENT_NOTE_ROOT=<临时树> npx tsx .agents/notes-scripts/verify-agent-note-format.ts`
  ⇒ 修前 `missing one of ["## Consequences", …]`，修后 `ok: 1 note(s) verified`
