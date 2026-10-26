# Agent Note: 中插广告跳过（多段区间 + 落库 + 换源迁移合并）

Status: implemented

Independent: 与既有"失败必须可查"（[2026-10-25-failure-must-be-queryable.md](2026-10-25-failure-must-be-queryable.md)）不同 ——
那篇管的是"错误信息能不能被上层查到"，本篇是**播放期跳过判定的区间模型与落盘格式**，
两者只在"用户设置不能被静默吞掉"这一点上气质相同，机制上没有交集。

## Problem

Owner 要"去广告"。改造前的跳过只有 **两对边界**：`introStart/introEnd`、`outroStart/outroEnd`，
表达不了"片中间有 N 段广告"；而且判定逻辑**内联在 `player_page.dart`（1.1MB）里**，
没有独立可测的入口 —— 想加第三种区间，只能在那个巨型 build 方法里再抄一段 `if`。

同时有三条约束互相拉扯：

```text
① 片尾不是 seek：它走 `_startNextCountdown()`（让用户看完再切集）。
   若把片尾也塞进"统一窗口"，语义会从"倒计时"变成"直接跳到末尾" —— 那是行为变更。
② 片头现行语义是"区间内必跳"（无容忍）；而通用 skipTarget 的默认 tolerance 是 1s
   （"距窗口末尾不足 1s 不跳"）⇒ 直接复用会**悄悄改掉片头行为**。
③ 用户主动拖过进度条后的 2s 内不许自动跳（"让用户赢"），这条已存在，
   且边界是 `age <= 2s`（含端点）—— 新判据不能变成 `< 2s`。
```

另外 `SkipMarker` 是**落盘结构**（SQLite `skip_markers` 表），加字段会同时影响：列清单（3 处硬编码）、
旧库迁移、坏数据容错、**换源迁移**（`repoint_item`）。

## Decision

**1. 判定抽成纯函数，Dart 侧唯一入口**

`lib/core/skip_window.dart`：`SkipWindow{start,end,kind}`（`intro`/`midroll`/`outro`）、
`windowsOf({introStart,introEnd,outroStart,outroEnd,midrolls})`、`skipTarget({position,windows,lastUserSeekAt,grace,tolerance})`。
无 Flutter 依赖 ⇒ 可单测。`player_page.dart:_maybeSkip` 改为调它，**只替换判据，不动 seek 动作本身**
（计数器、落点、`_beginPrefetchYield()`、`_flash`、AppLog 文案逐条保留）。

**2. 片尾永不进 `windowsOf`**

`_maybeSkip` 里片尾继续走原来的倒计时分支。`windowsOf` 只负责 `introStart/introEnd + midrolls`。
理由：片尾的语义是"等用户看完"，不是"跳过"；把两者统一会让片尾行为发生实质变化。

**3. 片头语义用参数保住，不靠"默认值刚好合适"**

调用点传 `tolerance: Duration.zero`（保持"区间内必跳"），grace 在调 `skipTarget` **之前**处理
（命中窗口 ⇒ 标记已处理 + 不跳 + 原日志 + `return`），随后以 `lastUserSeekAt: null` 调纯函数
—— 避免 grace 判据出现两份。grace 边界保持 `<=`（与 `_withinUserSeekGrace` 逐字一致）。

**4. 中插幂等按"窗口起点秒"记账**

`_midrollSkippedStarts: Set<int>`（片头/片尾沿用各自的布尔位）。位置流每秒 tick ⇒
没有这条，同一个中插窗口会被反复 seek（用户看到画面反复回跳）。

**5. 落库：`skip_markers` 加 `midrolls TEXT`（JSON 数组）**

```text
· :650  ALTER TABLE skip_markers ADD COLUMN midrolls TEXT（照 intro_start/outro_end 的既有补列手法，不动 schema 版本）
· :1536 SKIP_COLS 新列**加末尾**（新列索引 = 10，不扰动既有 0..9）
· :1554 row_to_skip：解析失败 ⇒ 空数组，绝不 panic（与 Dart 侧 `?? const []` 同口径）
· :1602 upsert：列清单 + ?11 + serde_json::to_string；ON CONFLICT 用 COALESCE
· :2346 repoint_item：?11 + midrolls=excluded.midrolls + **merge_spans(&f,&t)**
```

**6. 换源迁移里中插用"并集"而不是"FROM 优先"**

片头/片尾各只有一对端点 ⇒ `f.intro_start.or(t.intro_start)` 是对的；
中插是**多段**，`or` 会静默丢掉另一侧用户标过的广告（换源后广告又冒出来，用户以为设置丢了）
⇒ 合并 + 按起点排序 + 去重（`merge_spans`）。

## Alternatives considered

1. **把片尾也统一进 `windowsOf`**（一套逻辑处理三种区间，代码更少）。
   最诱人的理由是"减少分支"，但现行片尾是倒计时（`_startNextCountdown()`）而不是 seek，
   统一后行为变成"直接跳末尾" —— 用户不再看到片尾。**否决**：收益是代码美观，代价是功能改变。
2. **直接用 `skipTarget` 的默认 `tolerance`（1s）**，不传 `Duration.zero`。
   少一个参数，但会让"片头区间最后 1s 不跳"——现行行为是必跳。**否决**：
   新能力不该顺手改旧行为，要改就单独立项。
3. **grace 只靠 `skipTarget` 的 `lastUserSeekAt` 参数处理**（调用点不再前置判断）。
   更简洁，但两侧语义不同：现行实现是"grace 内命中窗口 ⇒ **标记已处理** + 不跳"，
   `skipTarget` 只是"返回 null 不跳"。**否决**：少了标记，用户拖过之后每秒 tick 都会重新判定。
4. **中插做成多列（`midroll_1_start/…`）或每段一行**。
   列表达不了 N 段；每段一行要改主键语义（会与 `repoint`/去重/`updated_at` 全部打架）。
   **否决**：JSON TEXT 一列 + 解析失败退化空数组，改动面最小且向后兼容。
5. **加 `user_version` + 迁移脚本框架**（为这一列引入版本化迁移）。
   更"正规"，但本仓既有补列模式（`PRAGMA table_info` + 幂等 `ALTER TABLE`）已经能覆盖，
   引入版本号会让后续每一列都要写脚本。**否决**：与既有手法保持一致。
6. **换源迁移时中插给 `Vec::new()`**（简单；"中插是新增字段，旧记录本来没有"）。
   这正是"静默丢用户数据"——用户换源后已标的中插消失且界面无提示。**否决**。

## Consequences

- 收益：中插可跳过（端到端实测 `marker(midroll 300→330) pos=305s ⇒ skipSeekCalls 0→1，
  lastSkipSeek=0:05:30`，落在窗口 end、再 tick 幂等）；片头/片尾/grace 行为**逐字保持**（既有 `+6` 仍绿）；
  重启后中插仍在（单测：写入 → 关连接 → 重开库 → 读回）；换源迁移带着走。
- 代价：每次跳过的判定要构造窗口列表（可忽略）；`skip_markers` 多一列 TEXT，
  空数组也会写盘 —— `COALESCE(excluded.midrolls, …)` 对非 NULL 的 `"[]"` 会**清空**旧中插，
  这是**有意**的（用户删掉中插就该生效），已在注释写明，但读代码的人容易误判成 bug。
- 边界（未收口）：**真机重启读回未验** —— 只有单测级证据（写入→关连接→重开库）。
  FFI 层若不暴露写 skip marker 的入口，这条就只能停在单测级；发布说明里按"已实现、真机未验"如实写。
- 加字段时漏了 `repoint_item` 那处列清单（11 列 10 值 ⇒ 两条既有 repoint 测试红）。
  `SKIP_COLS` 顶上已留注释写明"本文件 `skip_markers` 的列清单共 3 处，加字段必须逐处跟"。
- 幂等键是**秒级**（`start.inSeconds`）：两条中插若起点落在同一秒，会被互相判成"已处理"。
  实测数据里没有这种数据，暂不改；要更严就用 `start.inMilliseconds`。

## Testing

- `test/zz_t1024_midroll_skip_test.dart`（`@Tags(['native-media'])`，**+4**）：片头仍跳 / 中插跳且幂等 / grace 内不跳且之后也不再跳 / 无标记零 seek；
- 既有 `test/zz_t1024_skip_respects_user_seek_test.dart` **+6** 仍绿 ⇒ 判据替换没动旧语义（这是本次最重要的回归证据）；
- `test/zz_skip_window_test.dart`（**+10**）：纯函数级 + **真实 `SkipMarker` 对象驱动**（真 JSON → `fromJson` → `windowsOf`）+ 旧 JSON 缺 `midrolls` 仍可解析；
- Rust `cargo test --lib store`（**61**）：写入→关连接→**重开库**→读回 / 老库自动补列不丢数据 / 坏 JSON 退化空数组 / 序列化往返 / **repoint 带着中插合并**；
- 五次注入均有红（含门禁外的两次交叉复核注入：去掉幂等记账 ⇒ 反复 seek；`merge_spans` 改 `Vec::new()` ⇒ 中插丢段）。