# Agent Note: 界面强调一律用中文引号「」，不用 markdown `**`

Status: implemented

Independent: 与本轮其它笔记都不同 —— 那几篇分别讲
[判别式的唯一实现](../testing/2026-10-19-criteria-must-distinguish-cause-and-ciphertext.md)、
[更新说明生成](../process/2026-10-19-release-notes-generated-from-git.md)、
[自审揪出的四个缺陷](../bug-fix/2026-10-19-selfaudit-found-four-real-defects.md)。
本篇是**文案的写法约定**本身。

## Problem

Flutter 的 `Text` **不解析 markdown** —— `**粗体**` 在界面上是**原样显示**的两个星号。

```text
真机截图上逐字看到：弹窗正文写「请输入 **导出这个包时** 设置的口令。」
⇒ 界面上真的出现了 ** ，用户看到的是开发者写法
```

★ 我一度断言「全仓没有 markdown 渲染器」，**被 `r3-dns` 推翻**：
`lib/ui/widgets/release_notes.dart:19 buildReleaseNotes` 是有的
（`:98` 有 `**bold**` 的正则），只是它**只用于发行说明**。
⇒ 教训：「没有 X」比「有 X」需要更多证据。

## Decision

### 强调一律用中文引号「」

跟仓库既有先例 `shell.dart:6955`。不新增 `Text.rich` / markdown 渲染器。

### 红线：脱敏掩码绝不许碰

```text
danmaku.dart:1431  '****'
danmaku.dart:1432  '${id.substring(0,4)}****'
danmaku.dart:2223  '***'
```

★ 这三个是**给用户看的打码 AppId**。判别式因此必须是
「**是否连续成串**」而不是「是否出现 `**`」——
否则一次批量替换就会把打码内容变成明文，
而这在界面上**完全看不出来**（还是一串星号）。

## Alternatives considered

**A. 在面板里引一个 markdown 渲染器（`flutter_markdown` 或自写 `Text.rich`）。**
最强理由：一劳永逸，以后写文案可以直接用熟悉的 `**`。
否决理由：① 要处理 `Text.rich` 里所有富文本分支（每处都可能引入新的省略/换行问题）
② 面板文案里混进 `Text` 与 `Text.rich` 会让"这段为什么会换行"更难推理
③ 与既有先例不一致 ⇒ **一致性本身有价值**

**B. 把 `**` 全仓换成 `Text.rich`，顺带把强调做成真正的加粗。**
最强理由：视觉上比引号更明确。
否决理由：那是一次覆盖 8 个面板的重排版改动，
风险面远超本轮剩余预算；且它**改变排版**（换行点会变），
而本轮的重点是别处的问题。

**C. 把脱敏掩码改成别的形态（`••••`）。**
最强理由：这样"星号"不再是掩码，判据可以简化。
否决理由：`•` 在某些字体里与 `·` 视觉接近，反而更容易被误读为分隔符。
★ 而且掩码形态是**与缓存页面已有的取值展示一致**的，不该在这轮单独改。

## Consequences

**改了什么**

```text
8 个面板 12 个字面量 → 「」：
  backup_panel / danmaku_settings_dialog / data_manage_page /
  proxy_panel / playback_page / sync_panel / danmaku_source_page /
  danmaku / skip_marker_dialog
```

其中 `backup_panel` 那 3 句是**补文案**（原本也在 `**` 里，
但它出现在**用户正在删东西**的界面上 ⇒ Owner 第 13 条
「删除不干净」的根源之一就是这里没把话说清楚）。

**判据（两层，且各有分工）**

```text
源码层  isMarkdownBoldLiteral  —— 放过掩码
渲染层  isMarkdownBoldRendered —— 扫屏幕文本，判「成对粗体」
★ 为什么渲染层不能朴素 contains('**')：
  `maskedAppId`（danmaku.dart:1432）会经 `statusText` 拼进状态行、
  由 `Text` 渲染（danmaku_settings_dialog.dart:2748）⇒
  用户配过 AppId 时屏幕上**真的会出现 `****`** ⇒ 朴素版会误报
```

验证：掩码 3 处全判 false；真粗体判 true（阳性对照）；
降级判别式 ⇒ 2 条门禁红；注入渲染假阳性 ⇒ `zz_t66_ui_selfaudit` 红。

**已知上限**

```text
· 存量里还有若干处 `**` **在注释里**（合法）。
  门禁只扫字符串字面量，不扫注释 —— 这是有意的
  （`stripComments` 已负责剥注释），但意味着注释里的 `**`
  不会被清理。下一个人若照抄注释里的写法会再犯一次，
  所以判别式的注释里必须写清"用户可见文案才需要改"。
· `md_gate` / `dan_asterisk_gate` / `cs1_no_markdown_leak` /
  `data_manage_md_review` 四个门禁的扫描范围**有重叠**。
  重叠不是错（多一个眼睛），但改一处判据时要四处一起看。
```

**何时该翻案**

```text
· 若将来文案需要真正的加粗（而非引号），应先在**一个**面板试点
  并对比排版差异，再决定是否全局换 —— 不要直接从 A 跳到 B。
· 若脱敏掩码形态改变（见 C），判别式必须**同时**改，
  否则会出现"掩码被当成 markdown"或反之。
```