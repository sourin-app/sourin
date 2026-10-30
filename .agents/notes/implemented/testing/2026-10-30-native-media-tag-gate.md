# Agent Note: 全量 flutter test 恒 -6 的真因 —— 26 个文件缺 native-media 标签（含我自己造的假绿）

Status: implemented

Independent: 本批其余笔记都是"产品行为改错了"；本篇是**测试基建本身坏了**——
它让全量读数长期带着 6 条红，而那 6 条红看起来像产品缺陷，实为测试跑法问题。

## Problem

批末复跑全量 `flutter test`，读数恒为 `+5554 ~101 -6`：

```text
· 每次红**恰好 6 条**，失败形态是整文件 `did not complete`（不是单用例断言失败）
· 但每次咬到的**文件都不同**：remote_state_line / playlist_total_duration /
  sample_line / t61_panel_radius / t72_stream_sheet / zz_t12_defect_a_probe …
· 隔离单跑这 6 个文件，全部 exit=0 全绿
```

## 两次错误定性（如实记，免得后来人重走）

```text
猜①「并发负载挂起」
    ⇒ --concurrency=2 复跑：仍是**恰好 6 条**，只是换了文件
    ⇒ 并发不是原因。假设被自己的实测推翻。

猜②「隔离单跑都绿 ⇒ 产品无缺陷」
    ⇒ 只证明了用例本身写对了，**没解释全量为什么会红**。
      "单独跑绿"和"全量红"是两件事，用前者否定后者等于什么都没证。
```

**真因**在 `dart_test.yaml` 顶部 2026-09-25 的取证里早已写明，我只是没去读：

```text
MediaKit.ensureInitialized() 加载 libmpv-2.dll 时 flutter_tester **native 崩溃**
（访问违例 c0000005，进程退出码 79）；flutter_tools 在 Windows 上主动丢弃崩溃信息
⇒ 上层只看到 `did not complete`。

该文件的处置办法本就是给这类文件打 @Tags(['native-media'])（默认 skip）。
⇒ 全量那 6 条红 = 有 26 个文件调了 ensureInitialized 却**没生效地标注**。
   本批 7 个新测试文件全部中招。
```

## Decision

```text
① 补齐：26 个文件在**首行**声明 @Tags(['native-media'])
② 建门禁：zz_t20261030_native_media_tag_gate_test.dart
   ——判据钉在**行位置**上（不是"文本里有没有 native-media 这个词"）
   ——自带反向注入用例：造一个"词在但位置错"的文件 ⇒ 必须红
```

## ★ 关键坑：@Tags 是库级注解，位置错了**静默不生效**（我自己先造了假绿）

第一版门禁判据写成 `text.contains('native-media')`，我把标签插在
`void main()` 上方 —— **门禁转绿了，但全量复跑 `-6` 变成 `-8`**。
那个绿是**假绿**：注解没生效，文件照样真跑、照样崩。

位置错有三种形态，都实测到了：

```text
① 写在 void main() 上方          ⇒ 不生效
② 只在文件注释里提到这个词、根本没 @Tags  ⇒ 不生效（且会被 contains 判据误判为合格）
③ 写在 `library;` 之后           ⇒ 不生效（library; 本身已是声明）
   实测 zz_cr_panel_double_enter_test.dart 就是这一类，
   第一版判据把 library; 当可跳过项，漏判了它。
```

所以判据从"文本包含"收紧为"**@Tags 必须是 @Tags 之前只有空行/行注释/块注释**"。

## Alternatives considered

- **把崩溃文件逐个改成不碰 libmpv**：这些测试本来就是测播放器页面的，
  不加载就测不到真东西 ⇒ 等于为了读数干净把测试删了。否决。
- **全量加 `--concurrency=1`**：实测串行 8 次仍红 5 次（dart_test.yaml 已记）。否决。
- **只补本批 7 个新文件**：历史 19 个同样会随机崩，留着就是留雷。否决。
- **门禁只看"有没有这个词"**：已被反向注入证明会漏（见上）。否决。
- **把 6 条记成 known-failure 了事**：那是把"没查清"写成"已知"，喂养假绿。否决。

## Consequences

实测读数（三次全量，同一台机器）：

```text
修前      +5554 ~101  -6    崩溃类 did not complete = 6 条
标签插错位置  +5532 ~101  -8    （假绿的证据：崩得更多了）
位置修正后  +5450 ~122  -8    崩溃类 = 2 条
全部归位后  +5450 ~122  -8    ★ 崩溃类 did not complete = 0 条
```

跳过数 `~101 → ~122` 即 21 个文件从"真跑"变成"默认跳过"，与崩溃归零互相印证。

**剩余 8 条**是**真断言失败**（不是崩溃），与本批无关，如实列出：

```text
t73_search_order_test.dart   ×2  ⑧-3 _addHit 真调 rankHitGroups / ⑨-1 纯追加写法已消失
t94_emby_entry_test.dart     ×1  通用守卫：每个 *Page/*Panel/*Sheet/*Dialog 都被外部引用
t98_no_site_names_test.dart  ×1  产品代码与文档里不许出现具体视频网站名
```

这 4 条隔离单跑**照样红**（与崩溃那 6 条的"隔离绿"形成鲜明对照），
且来自 `0af8d7a`/`4e28067` 等**本批之前**的提交 ⇒ 本批未处置，按"只做被指派的事"上报 Owner。

## 留下的边界（如实）

- 崩溃**没有消失**，只是不再出现在默认全量里 —— 根因在第三方 libmpv-2.dll。
  需要真跑时用 `flutter test test/ --run-skipped --tags native-media --concurrency=1`。
- 被跳过的 122 条**既不算通过也不算失败**；`~N` 里的 N 就是"没跑"。
  用"基线全绿 vs 当前红"判回归之前，必须先确认那条用例在两边都真跑了。
