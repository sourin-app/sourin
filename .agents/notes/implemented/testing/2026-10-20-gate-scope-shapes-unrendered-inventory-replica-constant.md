# Agent Note: 门禁的四种「范围形态」—— 判据在，覆盖不到

Status: implemented

Independent: 与
[恒绿断言的四种形态](2026-10-19-four-shapes-of-always-green-assertions.md)
互补而非重复：那篇讲「断言本身没在钉东西」（锚文本/只断不抛/值没进 expect/容器恒真）；
本篇讲**断言是真的、注入也会红，但它钉的对象不是产品**——四种「范围」错了的形态，
每一种都**有注入能红**，所以按「能不能红」这一条根本筛不出来。

## Problem

第 66 轮收尾复核，我名下 4 个门禁被 Lead 逐个要求「注入一处，必须红」。四个都改红了，
但改之前它们各自的**覆盖范围**都有洞，而且洞的形状完全不同：

```text
① 树还没建起来 —— 断言扫的是一棵空树
   md_gate「① 整棵树的 Text 都没有 **」：pumpWidget(DataManagePage()) + 一次 pump()
   ⇒ initState 里的 _scan() 是异步真实 IO（ClipDownloader.dataDir() / list()）
   ⇒ 那一帧树里只有骨架，`texts` 只有 3 条，注入点（汇总卡 '数据目录共占用'）压根没渲染
   ⇒ 注入 ** 进去仍然绿。而它的防空转（条数 >= 3 + 含 '数据管理'）照样通过：
     '数据管理' 在 AppBar 上，先于异步数据出现 ⇒ 防空转**锚错了对象**

② 清单工具冒充门禁 —— 只报告，永不 fail
   markdown_audit：设计上「故意不 fail」，只 print 命中条目
   ⇒ 它读到的「用户可见 8 条」永远是**信息**，不是判据；有人往产品路径塞 ** 它也不红

③ 测的是同构副本 —— 断言全对，产品没被碰
   danmaku_proxy_a11y：文件里的 `_Probe` 是**自己写的** MaterialApp + RadioGroup + 3 个
   RadioListTile 副本（高度 >= 44 / Focus >= 3 / onChanged 被调），全部断言都绿
   ⇒ 但产品页那三态的真实挂载、真实持久化，一条都没测

④ 只钉常量，不钉接线
   下行缩放的第一个念头是「断言 kCoverDecodeMaxPx == 4096」——常量改成 8192 会红，
   但把 `coverDecodeWidth()` 从 `Image.network(cacheWidth:)` 拆掉，它**仍然绿**
```

## Decision

四例各自换成**钉产品、且能红**的判据，并各做一次故障注入：

```text
① 真实 IO 的页面：pumpWidget **放进 t.runAsync 里**（AGENTS §8），
   再轮询 pump 直到汇总卡出现；防空转改成断**注入点自身**
   expect(find.text('数据目录共占用').evaluate(), isNotEmpty)
   注入 '**数据**目录共占用' ⇒ 这条红（+5 → +4 -1），不靠静态兜底替它红
② 清单加一条**真断言**：产品路径 lib/ui + lib/core + lib/design + lib/shell.dart
   用户可见 `**` 必须 == 0；不合规条目逐条打印 file:line「literal」
   防空转 = 扫描文件数 >= 150 + 两条已知字面量可抽取 + 掩码样本仍判 false
   「不确定」桶（213 条）**不计入**判红 —— 否则门禁永远红，也是废门禁
③ 文件头 + 一条显式断言写明覆盖边界：`_Probe` 不覆盖产品页，
   覆盖者是 zz_t66_verify_danmaku_proxy_shots_test.dart（断言该文件存在且
   source 里确有 `DanmakuSourcePage(`）⇒ 下一个人不会误以为 a11y 罩住了产品
④ 钉**机制**：从 `Image.image as ResizeImage` 读 width/height（`Image` 没有公开的
   cacheWidth getter，这也是第一版编译不过的地方），再用合成 PNG 走真解码验
   222×1440 → 34×223、800×6000 → 546×4096；把 clamp 改成 1<<22 ⇒ 3 条红
```

★ 通则：**「注入会红」只能证明判据有判别力，不能证明它覆盖面正确。**
收尾复核要问的第二问不是「它会红吗」，而是「它红的时候，是产品坏了，还是别的东西坏了」。

## Alternatives considered

**A. 只补注入，不动范围（把 4 个门禁原样提交）。**
最强理由：4 个门禁都有注入能红，看起来已达标。
否决理由：①的注入红了是靠**静态兜底**（扫 `lib/ui/widgets/backup_panel.dart` 字符串），
不是「①整棵树」这条自己红 —— 也就是说产品真渲染出 `**` 时，那条树断言依旧是摆设。
Lead 的原话：「不是靠静态兜底替它红」。

**B. 把「不确定」桶也算进 markdown 门禁。**
最强理由：漏判风险最小。
否决理由：213 条不确定会让门禁**永远红** ⇒ 门禁被习惯性忽略，等于没有。
口径：只判「_uiWords 命中」的那一桶，其余保持报告。

**C. a11y 直接删掉 `_Probe`（承认它没用）。**
最强理由：不留假覆盖。
否决理由：那一层还有一处真价值 —— 三态 RadioGroup 的**交互契约**（高度/焦点/回调）
在真页面上要 pump 全页面才测得到，副本版是低成本回归网。故保留 + **明写边界**。

**D. 下行缩放只断面函数，不碰 widget。**
最强理由：最稳。
否决理由：接线断了（`cacheWidth` 没传给 `Image.network`）时用户看到的是原图，
面函数再对也白搭 —— ④ 的注入正是「拆接线」，必须红。

## Consequences

- 4 个门禁全部进版本库，实测：`md_gate +5`、`markdown_audit +2`（其中一条为产品路径门禁）、
  `danmaku_proxy_a11y +4`（含覆盖边界那条）、`image_downscale +5`。
- 注入读数（worktree 内，还原后 `sha256` 回基线、`git status` 空）：
  `md_gate` 注入 `**数据**目录共占用` ⇒ 树断言红；`markdown_audit` 注入
  `_label('**代理地址**')` ⇒ 打印 `lib/ui/widgets/proxy_panel.dart:437 「**代理地址**」` 并红；
  `image_downscale` 拆 clamp ⇒ 3 条红（①②④）。
- ✅ 本轮另修掉一处「**永远红**」的防空转：代理面板那组的 anti-empty 断言锚在渲染文案
  `'代理'` 上，而折叠态真实渲染的是 `cfg.summary`（`'直连'` / `'跟随系统'` / url）
  ⇒ 无数据的工作区里它必红。改成 `find.byType(ProxyPanel)` + `texts.isNotEmpty`。
  **永远红和永远绿一样废**，且更糟：它会训练人忽略这条门禁。
- ⚠️ 未闭合（别人负责）：`markdown_audit` 的产品路径范围目前只有 `lib/**` + `lib/shell.dart`。
  真缺陷在 Rust 侧 `rust/sourin_core/src/commands_backup.rs:483` 的 `credentialsNote`
  （`**不含登录态**` 经 `backup_panel.dart:491` 到用户眼前），以及
  `lib/core/ffi.dart:218` 的 `displayMessage` 全仓 0 调用点（UI 用 `_err = '$e'` 直接把
  `SourinCoreException(other): …` 倒给用户）。两者已派 r6b-live，**当前状态：修复中**。
