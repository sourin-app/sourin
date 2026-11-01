# Agent Note: 记忆式片头跳过（T7 广告对标）—— skip_markers 之下的每条目记忆层

Status: implemented

Independent: 取证底稿 = .probe/reference-apk-benchmark.md 第 ② 节（参考 fork
无内容级广告识别（tflite 证伪），其"广告"能力 = History.opening/ending
每作品记忆 + 自动 seek）。本篇把它对齐为本仓 skip_markers 之下的**记忆层**。

## Problem

本仓 skip_markers 是**声明式**（场景表：用户/数据方标注片头片尾区间）；
参考的能力是**记忆式**（没人标注的剧，靠上次观看位置记住片头）。两层互补：
声明式覆盖数据方知道的，记忆式覆盖没人声明的长尾。

## Decision

```text
① 新表 skip_memory（同键 provider:native_id；intro_end/outro_start 列），
   Rust merge_skip 做"声明 ⊕ 记忆"字段级 fallback（声明优先），
   新命令 get_effective_skip_marker；_loadSkipMarker 一换一改调它
   （同异步模式 + gen 守卫，起播零新增调用）。
   get_skip_marker（跳过弹窗草稿预填）保持纯声明——弹窗绝不能被记忆污染。
② 写入挂钩只在 _seekByUser（六条用户 seek 唯一汇聚点），判据全在纯函数
   classifyIntroMemorySeek：出发点 ≤ max(90s, 片长5%)、前跳 ≥30s、
   落点 ≤ min(600s, 片长50%)、回跳/直播/片长未知/同值不记。
③ 开关 dsh.playprefs.skipMemory 默认关；关=读侧回纯声明+写侧拦截
   ⇒ 行为与现状逐字节等价。面板开关（player_settings_sheet，与自动跳过
   同区块）+ 远端 skip_toggle_memory，同一落库键。
④ clear_skip_marker 同操作连删记忆（三条既有清除路径自动覆盖，零新增 UI）；
   换源 repoint 补 skip_memory 搬运。
```

## Alternatives considered

- **片尾推理**：一期砍掉。误记代价 = 静默吃掉结局（用户跳后段可能是想看结尾，
  记成 outro 后下集自动跳过，且无法与几天前的一次 seek 关联）。outro_start
  列保留（二期免迁移），写路径只有 intro。声明式已能设 outro。
- **记忆行设置页展示**：本期不做，flash + 既有清除路径足够。
- **按 Rust needs_parse/声明过滤记忆对象**：与声明优先叠加会漏长尾。否决。

## 打回实录（互检 2×P1 + 2×P2 + 1×P3，全部成立）

- **P1-1 关≠不跳**：开关只拦了写侧，读侧无条件读生效值且关不删记忆行
  ⇒ 开→记住→关→下次照样跳。修：读侧分流（关=纯声明）。教训：**"关"必须
  同时管读写两侧，只拦写侧的开关是摆设**。
- **P1-2 「继续观看」误记**：浮层继续观看走 _seekByUser（from≈0，to=续播点）
  ⇒ 落点 ∈(90,600] 全部误记片头 ⇒ 下次起播静默跳掉片头。修：rewatch 与
  skip_preview（同形声明起草手势）两条路径抑制（一次性标志，置位必须在
  _seekByUser 同步段之前）。扩展到 skip_preview 是实现者的正确裁量（预览
  落点不是片头意图，且不抑制会与正在起草的声明打架）。
- **P2-1 记忆跨会话冻结**：分类器把生效值当声明 ⇒ 记忆一旦存在永远无法修正。
  修：分类器删 declared 参数（声明拦截完全由 Rust upsert 库级兜底）——
  "记忆可修正"语义恢复。教训：**"已声明"与"已记忆"在合并层必须可区分，
  否则记忆变成不可撤销的声明**。
- **P2-2 假 flash**：unawaited 无视返回值就 flash ⇒ Rust 拦截时用户看到
  "已记住"（假反馈）。修：await 返回值，false 不出反馈。
- **P3-1 短片整片跳过**：600s 绝对上限缺片长相对约束（10 分钟片 seek 0→590
  ⇒ 记 590 = 跳过全片）。修：min(600s, 片长50%)。
- 过程中另抓一个真缺陷：守卫查询把 NULL 列当 i64 取（声明行只设片尾时
  记忆写入报错）——被"字段级不是行级"测试当场打红后修。

## Consequences

- 读数：Rust lib 全量 1997/0（新增表/命令/合并/迁移/清除连带测试）；
  batch2_write.rs 另有 2 条**命令层**测试（声明拦截 + 生效值读数、0 值防呆 +
  合并 + 弹窗读法不污染 + 清除连带——穿过 dispatch 的端到端形状）；
  Dart skip_memory_test 22/22 + rewatch_gate 3/3（native-media 实跑）+
  skip 体系回归 159 + 面板夹具 113 零回归；analyze errors=0。
- UX：默认关；记忆动作必有 flash + AppLog（不静默）；清除走既有三条路径。
- 边界（如实）：二期候选 = 片尾显式/记忆设定（outro 列已留）、记忆行
  设置页展示、发送类记忆。误记风险靠"默认关 + flash + 相对上限 + 可清除"四层兜底。
- 未做真机验证（lead 部署后验收：开关开 → 拖过片头 → flash → 清除）。
