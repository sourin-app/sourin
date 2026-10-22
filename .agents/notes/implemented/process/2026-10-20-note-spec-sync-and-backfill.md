# Agent Note: 笔记规范补齐 —— 从「什么该写」到「已有笔记怎么维护」

Status: implemented

> 同域：[2026-10-17-notes-tree-is-single-decision-record.md](./2026-10-17-notes-tree-is-single-decision-record.md)
> 那篇确立了「决策只有一处出口」；本篇补的是**那个出口内部怎么维护** ——
> 出口建好了，但没人规定既有笔记该就地更新还是新开篇，树会退化成变更日志。
> 相邻：[../testing/2026-10-12-gates-must-be-able-to-fail.md](../testing/2026-10-12-gates-must-be-able-to-fail.md)
> （本篇新增的 CI 步按那篇的纪律做了三条故障注入）。

## Problem

本仓的笔记门禁一直是绿的（tree / format / archived 三线 + coverage + supersession），
但**绿得没有覆盖到真实的腐化形态**。实测两个缺口：

```text
① 37 / 95 篇 implemented 笔记**没有任何互链**（39%）
   而 supersession 门禁只查**新增**笔记 ⇒ 存量永远不会被要求声明归属
   ⇒ 笔记树事实上退化成一堆按时间排列的独立文档，
     「这篇与那篇是什么关系」只有读过两篇的人知道

② 上游 `agent-notes` 规范里有一整节讲**已有笔记怎么维护**
   （原地同步事实 / 现在时 / 决定翻转要新开篇 / 当场审计 / 取代的两种路径），
   而本仓 `docs/AGENTS.md` §7 只写了「什么该写」与骨架，
   **完全没有这一节**。
   ⇒ 结果就是：新笔记写得合规，老笔记没人动，两者逐渐脱节
```

另有一个工具链缺口：

```text
上游 skill 的 scripts/ 有 7 个脚本 + templates/ + assets/，
本仓 .agents/notes-scripts/ 只有 5 个（缺 build-board.ts、check-note-anchors.ts）
⇒ 「看板」与「锚点体检」这两项能力在本仓不存在
```

## Decision

### ① 脚本与模板整体同步到上游（逐字节）

```text
.agents/notes-scripts/ 新增 build-board.ts、check-note-anchors.ts
.agents/notes-scripts/templates/ 新增 implemented/proposed/rejected 模板 + verify-notes.yml
.agents/assets/agent-notes-board.html 新增（build-board 的硬依赖）

核对方式：7 个共有脚本用 `tr -d '\r' | sha256sum` 逐字节比对 ⇒ 全部 SAME。
（直接 diff 会因 CRLF 每行都报不同，那是假差异 —— 本项目 .gitattributes 是 text=auto）
```

### ② `docs/AGENTS.md` §7 补 7.1「笔记是现行法律，不是流水账」

六条纪律，全部来自上游规范且本仓原先缺失：

```text
① 优先就地同步事实，非必要不新建
   （在文末追加「### 2026-xx-xx 更新：…」是错的 —— 打开笔记应看到 HEAD 的绝对事实）
② 时态永保现在时
③ 决定或理由翻转 ⇒ 新开一篇并互链，禁止把 ## Decision 改成反面
④ 写新笔记前当场审计，禁止推迟
⑤ 新笔记必须声明与既有笔记的关系（三种合法路径）
⑥ 取代：部分重叠（两篇都留互链）vs 完全吸收（吸收后删或归档）
```

★ 为什么不写进 CONTRIBUTING.md：`docs/AGENTS.md` 是「开工前 10 分钟」的入口，
笔记纪律属于「写代码前必须知道」的那一类；CONTRIBUTING 是流程细则。
两者都在，但入口那份必须自洽。

### ③ 存量 37 篇孤立笔记：补 `Independent:` 声明，**不硬凑互链**

```text
逐篇判断「它是否真的独立」，31 篇补了 Independent: + 具体理由，
6 篇本来就有（早期已加）。

★ 为什么是 Independent 而不是"找一篇链上"：
  这 37 篇大多是**各讲一个独立决定**（例如「预取开关按实例读」与
  「错误分类只认中文」毫无关系）。硬加一条互链会让链接变成噪音，
  而噪音链接比没有链接更糟 —— 它让人以为两篇相关。
★ 但 Independent 必须带**具体理由**（脚本要求非空）。
  「给理由」这个动作本身会促使作者真去检索一遍 —— 这是它相对
  「留空通过」的唯一优势。
```

### ④ CI 新增一步：笔记脚本可解析性

```text
为什么需要：三个 verify 脚本跑不起来时，`npx tsx` 会非零退出 ——
但如果有人把调用改成 `|| true`，坏掉的脚本就永远不会被发现。
这一步把「脚本自身是好的」变成**独立信号**，而不是依附于门禁能否跑通。
```

判据（**每条都实测过会红**）：

```text
① 7 个 .ts + 1 个 .html 模板必须存在
   注入：mv 走 .agents/assets/agent-notes-board.html ⇒ exit 1 ✅
② check-note-anchors.ts 必须能被 tsx 真跑
   注入：往脚本末尾加 `const broken = ;` ⇒ tsx exit 1 ✅；还原 ⇒ exit 0 ✅
③ 两个 .mjs 用 node --check 做真语法检查
   注入：往 notes-coverage.mjs 末尾加语法错 ⇒ exit 1 ✅；还原 ⇒ exit 0 ✅
```

★ **写这条 CI 步时我连踩两次「假绿判据」**，都当场改掉了：

```text
第一版：`npx --yes tsx --eval "import('./$f').catch(()=>{})" >/dev/null 2>&1 || true`
  ⇒ `|| true` 吞掉一切；而且 --eval 的字符串根本没加载模块。恒绿。
第二版：`new Function(\`return import(...)\`)` 构造一个函数
  ⇒ 只构造不调用，模块从未被解析。恒绿。
第三版（当前）：真跑 tsx / 真跑 node --check，不写 `|| true`。注入能红。
```

### ⑤ `.gitignore`：放行看板模板（这里有一条 gitignore 的硬规则）

```text
`.agents/*` 把 **assets 目录本身**忽略了，而 git **不会进入被忽略的目录**
⇒ `!.agents/assets/agent-notes-board.html` 单独写**不生效**
   （git check-ignore 仍指向 .gitignore 的 `.agents/*` 那条）

⇒ 必须先放行目录、再放行文件：
     !.agents/assets/
     !.agents/assets/agent-notes-board.html
   ⚠️ 但「放行目录」会把该目录下**所有**文件一起放行 ——
      所以必须再补一条把其余文件重新忽略回去（gitignore 最后匹配生效）：
     /.agents/assets/*
     !/.agents/assets/agent-notes-board.html

判据（三条都要测，实测过）：
  · 模板文件 ⇒ 可入库 ✅
  · .agents/assets/ 下放一个 _tmp_x.txt ⇒ **仍被忽略** ✅
  · .agents/worktrees/ ⇒ 仍被忽略 ✅
```

## Alternatives considered

### ① 「37 篇孤立笔记全部补上互链，让笔记树连成一张网」

**最强论据**：链接密度是笔记树质量的直观指标；上游规范也强调互链，
一个「每篇都能从别处走到」的树比孤立文档更可导航。

**为什么否决**：**这 37 篇里绝大多数真的互不相关，硬连等于制造噪音。**

```text
实测抽样：
  · bug-fix/2026-10-08-prefetch-switch-per-instance（预取开关按实例读）
  · bug-fix/2026-10-17-classify-error-ignores-prefix（错误分类只认中文）
  两者唯一的共同点是「都是 bug-fix」，把它们链起来不表达任何决策关系。
★ 判据：**链接要表达"这篇接在那篇之后"或"这篇部分取代那篇"。**
  表达不了就别加 —— 噪音链接会让真正重要的关系更难被发现。
```

### ② 「把笔记规范写进 CONTRIBUTING.md，不碰 AGENTS.md」

**最强论据**：CONTRIBUTING 才是流程细则的归属地，AGENTS.md 应该保持精简
（它已经 380+ 行，再长就没人读了）。

**为什么否决**：**「开工前 10 分钟要读完」的东西必须自洽。**

```text
· AGENTS.md §7 已经有一大段讲笔记（骨架、必须写/免写、不建索引、三条校验）
· 只把"怎么维护"挪到 CONTRIBUTING ⇒ 读者在 AGENTS 里看到"笔记要写"，
  却看不到"写了之后怎么维护"，然后他不会再去翻 CONTRIBUTING
★ 折中：AGENTS.md 写六条**判据式**纪律（短、可执行），
  细则仍留给 CONTRIBUTING。实际就是这么做的。
```

### ③ 「CI 里把 check-note-anchors 也跑上，多一道门禁更保险」

**最强判据**：门禁越多越安全；锚点体检能发现「代码注释指向的笔记已不存在」。

**为什么否决**：**它的退出码恒 0（软报告），放进 `set -e` 链里只是让日志变长。**

```text
上游规范明确写：check-note-anchors 是**软报告，退出码恒 0，不进 CI**。
★ 判据：**一道永远绿的门禁比没有门禁更糟** —— 它让人以为"已经检查过了"。
  本项目已有 4 个「假绿」实例（见 AGENTS.md §8 那几条），不能再加一个。
⇒ 保留在本地工具位（docs/AGENTS.md §7.1 的「软报告」段），不进 CI。
```

### ④ 「用 `tsc --noEmit` 做脚本可解析性检查」

**最强论据**：类型检查比"能跑起来"更严格，能抓到类型错误。

**为什么否决**：**它需要 `@types/node`，会给 CI 引入额外依赖，而收益不匹配。**

```text
实测：`npx --yes -p typescript@5 tsc --noEmit ...`
  ⇒ error TS2307: Cannot find module 'node:fs'
  ⇒ error TS2580: Cannot find name 'process'
这些是**缺类型声明**，不是脚本有错。要消掉就得装 @types/node。
★ 而本仓的原则是「不为校验脚本引入 node_modules 与锁文件」（CI 注释里写着）。
⇒ 用 `tsx 真跑` 代替：语法错会让它非零退出（实测注入能红），
  且不需要任何额外依赖。
```

## Consequences

### 收益

```text
· 笔记树从「37 篇无归属」变成「0 篇未声明」：每篇孤立笔记都写清了为什么独立
· docs/AGENTS.md 补上 6 条维护纪律 —— 这是原先完全缺失的一节
· 工具链补齐：看板（build-board）+ 锚点体检（check-note-anchors）+ 模板
· CI 多一道「脚本自身是好的」独立信号，且三条判据都做过故障注入
```

### 读数

```text
笔记门禁（本地，AGENT_NOTE_ARCHIVE_BASE_REF=HEAD）：
  tree     ok: 98 note(s) tree and relative links verified
  format   ok: 98 note(s) verified
  archived ok: 1 archived note(s) verified, 1 seal(s) in manifest

存量审计：
  无互链 = 37 篇
  无互链且无 Independent = **0 篇**（改前 37）

supersession 门禁故障注入（新增一篇无声明笔记）：
  ✖ 有新增笔记没有声明它与既有笔记的关系。
    .agents/notes/implemented/testing/2026-10-20-zz-tmp-no-decl.md
  REAL_EXIT=1 ✅（注意：管道到 tail 会看到 0，那是 tail 的退出码）
  清理后 ⇒ 通过，exit 0
```

### 代价

```text
· `Independent:` 是**声明**，不是**证明**。它只能保证作者给过理由，
  不能保证理由正确 —— 一个偷懒的人仍能写「反正无关」蒙过去
  （脚本只查非空，不查理由质量）
· docs/AGENTS.md 又长了约 60 行。它已经 380+ 行，
  「开工前 10 分钟读完」这个定位正在被侵蚀
· 新增 CI 一步（约 5 秒），且它只验证「脚本能被解析」，
  不验证脚本逻辑正确 —— 后者归三线门禁自己
· build-board 的产物（board.html）不进仓库，所以「看板」在本仓是**本地工具**，
  下游 clone 后需要自己生成一次
```

### 还没覆盖的

```text
· 37 篇里「Independent 的理由是否成立」没有复核 —— 我只保证每篇都有具体理由，
  没有逐篇验证"它真的与其它笔记无关"
· 没有做「存量笔记的事实是否已过期」的检查（例如某篇写的路径/类名是否还存在）。
  这类腐化只能靠人读，脚本做不了 —— 也正因如此才更要「就地同步」这条纪律
· `check-note-anchors` 在本仓跑出来报告了 75+ 篇 implemented 笔记没有锚点指向。
  这是**软报告**，本轮没处理 —— 本仓的惯例是「不为了检索去补锚点」（上游也这么说）
```

### 何时该翻案

```text
① 若 docs/AGENTS.md 继续变长到影响可读性
   ⇒ 把 §7.1 整节移到 CONTRIBUTING.md，AGENTS.md 只留一句指针
   （但那时要确认「读者不会因为跳转而不读」）
② 若出现「Independent 被滥用」（大量笔记写空泛理由）
   ⇒ 加一条判据：理由长度下限 + 必须包含具体机制名
   （目前只查非空，是刻意的低门槛 —— 高门槛会诱导编造）
③ 若上游 agent-notes 规范再次变更
   ⇒ 按同样方式整体同步脚本，并核对 docs/AGENTS.md §7.1 的六条是否仍成立
④ 若将来有 CI 需要跑 build-board（例如发布时生成看板）
   ⇒ 把产物路径移出 `.probe/`，并给它加门禁（当前它是纯本地工具，无门禁）
```
