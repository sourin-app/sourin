# Agent Note: skip 区里的恒红断言没人发现 —— 用「抽检台账」而不是「要求全绿」来兜

Status: implemented

> 同域三篇，分工写清楚（免得后人以为是重复记录）：
>
> · [2026-09-25-native-media-tag-skip-not-exclude.md](./2026-09-25-native-media-tag-skip-not-exclude.md)
>   —— **为什么用 `tags: {skip:}` 而不是 `exclude_tags:`**（标签机制本身）
> · [2026-10-18-skipped-test-hides-certain-red.md](./2026-10-18-skipped-test-hides-certain-red.md)
>   —— 一次**具体事故**：被 skip 藏住的过时判据（单点取证）
> · **本篇** —— 把「怎么防这类事再发生」变成**可执行台账**
>
> 前两篇讲"是什么/踩过哪些"，本篇讲"从今天起谁来保证它不会再躺一个月"。

## Problem

`dart_test.yaml` 把 `native-media` 标签设成**默认跳过**（加载 libmpv 会让
flutter_tester 偶发 native 崩溃 `c0000005`，实测交错的 A/B：加载崩 6/25、
不加载崩 0/25）。这是个正确的取舍，但它有一个**结构性副作用**：

```text
全量跑 ⇒ skip 只体现为 `~N` 计数器 +1
       ⇒ `grep "All tests skipped"` 计数 = 0
       ⇒ 这 56 个文件里**有没有恒红断言，没有任何东西会报**
```

真实事故（2026-10-21）：`player_episode_nav_boundary_test.dart` 的阳性对照
恒红躺了很久 —— 报 `Found 0 widgets with text "下一集"`，因为断言比对的对象
（`find.text`）和实际渲染的对象（tooltip）不是同一个。它一直红着，
而默认套件是绿的。

★ 这不是"某个测试写错了"，是**流程缺陷**：本仓的规矩里写着"定期抽检"，
但**没有任何东西在检查这件事**。写在散文里的纪律等于没有纪律。

## Decision

### 新增门禁 `test/zz_t66_native_media_audit_gate_test.dart`（四条判据）

```text
a) 扫到的 native-media 文件数 > 0        ← 阳性对照，防扫描器空转
b) 每个扫到的文件在台账里都有记录         ← 防"漏登记"
c) lastAudited 距今天 <= 30 天            ← 防"登记了但从不更新"
d) 台账里的每个文件名都真实存在           ← 防腐化（测试删了但台账还留着）
```

台账落盘在 `docs/notes/native-media-audit.json`，键为**相对 `test/` 的文件名**：

```json
{
  "player_episode_nav_boundary_test.dart": {
    "lastAudited": "2026-10-21",
    "audited": true,
    "result": "+6 ~0 -0",
    "note": "阳性对照曾恒红（find.text vs tooltip），已修"
  }
}
```

### ★★★ 判据测的是「有没有人定期去看」，不是「里面有没有红」

```text
❌ 「所有 skip 文件必须绿」
   ⇒ 不可能。它们挂标签**就是因为**加载 libmpv 会崩。
      2026-10-21 实测：56 个文件里 6 个稳定 exit=79（No tests were found）。

❌ 「让它不红」
   ⇒ 等于删测试。本仓已因"删掉难修的测试"记过教训。

✅ 「每个文件都有最近抽检时间，且不超过 N 天」
   ⇒ 可执行、可判定、且**不逼人改产品代码**。
```

这正是本仓那条纪律的落地：
「一个看起来像结果的东西，必须携带『我查了多少』的信息」。

### `audited` 与 `lastAudited` 两个字段的分工（这是最容易写错的地方）

```text
audited: true   ⇒ 真的跑过，且拿到了可信读数（result 里的 +N ~M -K 是实测）
audited: false  ⇒ 跑过，但没拿到读数（原生崩溃 / 超时）
lastAudited     ⇒ 「最近一次**尝试抽检**的日期」，崩了也要写
```

⇒ `lastAudited == null` **只**表示"从未抽检"，必须红。
崩溃过的文件**不该**因为 `lastAudited` 有值而掩盖"它没绿" ——
所以两个字段都要，各管一件事。

我第一版把 `lastAudited` 一刀切成"必须非空"，结果 6 个原生崩溃的文件逼我
要么编一个日期（造假），要么把测试删掉（更糟）。改成两字段后自然成立。

## 首次审计结果（2026-10-21，全部 56 个文件真的跑过）

```text
42  全绿
 8  有红（共 17 条断言失败）
 6  原生崩溃（exit=79 / did not complete，D 类环境问题）
 0  未跑
```

**那 8 个有红的**（这才是本门禁存在的理由 —— 它们一直没人看见）：

| 文件 | 读数 |
|---|---|
| `t92_bottom_bar_row_fit_test.dart` | `+0 ~0 -5` |
| `t108_danmaku_manual_search_test.dart` | `+2 ~0 -3` |
| `t27_w9_bar_linkage_test.dart` | `+13 ~0 -3` |
| `t104_overlay_exit_test.dart` | `+18 ~0 -2` |
| `player_panel_wiring_test.dart` | `+0 ~0 -1` |
| `t118_control_bars_link_test.dart` | `+15 ~0 -1` |
| `zz_cr_backbtn_backarrow_test.dart` | `+6 ~0 -1` |
| `zz_cr_dmk_c_import_test.dart` | `+3 ~0 -1` |

★ 注意：**这 8 个不是本轮引入的**（本轮 diff 未触及这些断言）。它们是存量。
本门禁**不要求**它们变绿 —— 只要求"有人定期看"，且台账里记着当前读数。

## Alternatives considered

**A. 把 `native-media` 从 `dart_test.yaml` 里去掉，让它们默认跑。**
最强理由：一劳永逸，什么都藏不住。
否决理由：实测**不行**。加载 libmpv 时 flutter_tester 崩 6/25（干净交错 A/B），
崩的形态是整文件 `did not complete` → 默认套件会**随机红** →
CI 变成"时绿时红"，几周后没人再看它。这比"藏起来"更糟。
（`dart_test.yaml` 顶部记着完整证据链 `.probe/native-media-tests.md`。）

**B. 让门禁解析"里面有没有红"，把红的列出来。**
最强理由：比台账更直接，不需要人维护 JSON。
否决理由：**门禁自己跑不动它们** —— 跑一次 56 个文件要 30+ 分钟，
且 6 个必崩。把"跑 30 分钟 + 可能崩"塞进 CI 不现实。
⇒ 只能"抽样"由人执行，机器**验证抽样发生过**。这是本设计的核心约束。

**C. 只记 `lastAudited`，不记 `result` 读数。**
最强理由：更简单，维护成本低。
否决理由：那就退回"打卡"——只要改日期就能通过，而**不反映里面到底什么状态**。
记 `result` 让"我抽检过"携带真实读数，符合本仓
「结果必须携带『我查了多少』」那条纪律。

## Consequences

**收益**

```text
· 「定期抽检」从散文变成可执行判据。从未登记 / 超 30 天 / 台账腐烂 都会红。
· 首次审计当场捞出 8 个文件里的 17 条恒红 —— 这些之前完全不可见。
· 台账本身是证据：谁在什么时候看过，读数是多少。
```

**代价**

```text
· 台账要人维护。抽检一个文件需要真的跑一次（快的 5 秒，慢的 400 秒）。
· 30 天的阈值是判断，不是事实：太短会逼人走过场，太长等于没有。
  建议每次批末统一跑一轮，把 lastAudited 全部刷新。
· 判据 d 对"文件在但已不挂标签"只打印不判红 —— 因为那可能是
  "标签被移除、测试现在默认跑"，是好事，不该红。但也不能静默，所以打印。
```

**已知上限**

```text
· 门禁**不验证**台账里的 result 是否真跑过（无法验证）。
  它只能保证"有人写了日期 + 读数"。
  ⇒ 真正的防线是"不许伪造"这条纪律 + 批末统一刷新。
· 6 个稳定崩溃的文件永远拿不到 result。它们的 lastAudited 会正常滚动，
  但 audited 永远是 false。这不是缺陷 —— 如实记录"跑不通"就是它的价值。
· 只覆盖 native-media 一类。needs-network / needs-shot-dir /
  needs-isolated-userprofile 三类同样默认跳过，同样有这个风险，尚未建台账。
```

**何时该翻案**

```text
· 若 libmpv 崩溃被上游修掉（换 media_kit 版本 / 换播放后端），
  应重新评估：也许可以去掉标签让它默认跑，那时本台账就该删掉。
· 若台账条目涨到 150+，应把"抽检"做成脚本 + 分批，而不是靠人记。
```
