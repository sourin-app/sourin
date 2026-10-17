# Agent Note: classify_error 只认中文关键词，英文前缀被抹成 other

Status: implemented

## Problem

插件按契约抛 `unsupported: xxx`，Dart 侧收到 `kind = 'other'`。

```text
实测（我做的对照实验，同一次跑）：
  抛 'unsupported: 这个源只声明了能力，没真的实现发送'
    ⇒ kind = other          ← 明明是契约规定的标准前缀
  抛 'unsupported: 不支持发送'
    ⇒ kind = unsupported    ← 只因为正文里恰好有个「不支持」
```

⇒ 靠**偶然的中文用词**决定错误分类。

根因：`classify_error`（ffi.rs）只认中文关键词表：

```text
timeout / 网络 / 请求失败 / 连接  ⇒ network
登录 / 401 / unauthor            ⇒ unauthorized
不支持 / 未配置                   ⇒ unsupported
不存在 / 未找到 / 未返回           ⇒ not_found
其它                             ⇒ other
```

它**完全不认** `unsupported:` 这种英文前缀。

影响面：`with_state_async` 在 ffi.rs 被 58 处调用（`with_state` 另 50 处），
所有走这条路的命令都受影响。前端按 ErrorKind 分支的逻辑
（「去登录」引导、「上游改版」提示）会全部失效，退化成兜底文案。

## Decision

**第 1 步（本次完成）：前缀优先，关键词兜底。**

```text
判据顺序：
  ① trim 前导空白与标点（插件可能把前缀包在引号/反引号里）
  ② starts_with 认标准前缀：
       unsupported: / unauthorized: / 401:
       not_found:   / 404: / network: / parse:
  ③ 都没有 ⇒ 落回原来的中文关键词表
```

三个细节：

```text
· 用 starts_with 而不是 contains ——
  「正文里提到过 unsupported」与「作者声明这次是 unsupported」
  是两件不同的事，后者才该决定分类。
  （专门有测试钉这一条）

· 补了 parse: —— 与 plugins/mod.rs 的 map_js_error 逐字一致。
  同一个错误在 JS 层分类对了、到 FFI 层又被抹成 other，等于白修。

· 只剥前导，不剥正文本体 —— 否则 404: xxx 会被自己的规则吃掉。
```

## 第 2 步（根治版）的成本评估 —— 结论：不做，理由有依据

「让 `ProviderError.kind` 一路带到 ffi 层」听起来更对，但**量过之后发现
改它解决不了问题**：

```text
事实：commands_backup.rs 里返回 Result<_, ProviderError> 的命令 = **0 个**
      33 个命令全部是 Result<_, String>。

也就是说 kind **在命令层就已经被压成字符串了**：
  p.danmaku_send(req).await.map_err(|e| e.message)
                                       ^^^^^^^^^ 只取 message，kind 丢掉
（同类 flatten 共 21 处：commands 3 / commands_backup 10 / home 4 / playback 4）
```

⇒ 根治版的真实工作量是：

```text
改 33 个命令的返回类型（Result<_, String> → Result<_, ProviderError>）
+ 改 21 处 map_err(|e| e.message)
+ 改 with_state / with_state_async 的泛型约束
+ 逐个修调用点（110 处 with_state* 调用）
≈ 上百处改动，跨 5 个文件
```

而**收益为零**：第 1 步已经让 kind 正确了（前缀是 `message` 字段的一部分，
**不会被 flatten 丢掉**）。这是实测的，不是推断 —— 见下方 Verification。

⇒ 结论：第 1 步不是「临时补丁」，而是**在这个代码结构下的正确解**。
  真要做第 2 步，应当等有人要动 `Result<_, String>` 这个约定时顺带做，
  而不是为它单独改上百处、零收益。

## Alternatives considered

**只加中文关键词（比如给 unsupported 加上英文词 unsupported）**
否定原因：治标。前缀是**结构化**的（`前缀: 正文`），
关键词是**文本匹配**的。后者永远会漏（`parse:` / `geo_blocked:` / `broken:` 都没有对应关键词）。
而且 `contains` 会把「正文里引用过这个词」误判成声明。

**在 Dart 侧兜（我已经在 task-41 里做了「前缀优先、kind 兜底」）**
这是**对冲**不是修复：每个调用方都要自己写一遍前缀判断，
而 71 处命令不可能都补。根因必须在 Rust 侧修 —— 已修。
Dart 侧那段保留，理由见那条注释（它同时防住「插件没按契约写前缀」）。

## Consequences

**好处**
```text
· 所有走 with_state/_async 的命令，错误分类立刻变对（不只弹幕发送）
· 与 plugins/mod.rs 的 map_js_error 判据**对齐**，两层不再互相打架
```

**代价 / 风险**
```text
· 前缀判据在前 ⇒ 若某条错误的消息**恰好以** 'network:' 开头但本意不是，
  会被按前缀分类。实际风险极低（中文错误消息不会以英文前缀开头），
  且这正是契约要求的写法，认它是对的。
· 关键词兜底顺序**一字未动** ⇒ 老插件行为完全不变（有测试钉住）。
```

**何时该翻案**
```text
· 若将来真要把 Result<_, String> 换成 Result<_, ProviderError> ⇒
  那时 classify_error 可以退化成兜底，甚至删掉。
· 若契约新增前缀（如 geo_blocked: / broken:）⇒ 同步加进 ① 那一节；
  现在这两种只能靠关键词，而关键词表里压根没有它们 ⇒ 会落 other。
  这是本修复**已知的剩余缺口**，值得记一笔。
```

## Verification

### 单测（cargo）

```text
新增 4 条：
  standard_prefix_is_recognized            5 种前缀各一条
  prefix_must_be_at_the_start_not_merely_present   钉 starts_with 语义
  prefix_survives_wrapping_punctuation     引号/反引号/空白
  prefix_is_case_insensitive               大写前缀

既有 1 条（未改）：
  error_classification_matches_frontend_rules      6 条关键词断言全绿
  ⇒ 证明「无前缀时仍走关键词兜底」没被破坏

全量：cargo test --lib ⇒ 445 passed; 0 failed
```

### 双向故障注入

```text
注入 A：把前缀识别整块删掉
  ⇒ standard_prefix_is_recognized          FAILED (left: other / right: unsupported)
  ⇒ prefix_survives_wrapping_punctuation   FAILED
  ⇒ prefix_is_case_insensitive             FAILED
  ⇒ 3 条红；关键词那条**仍然绿**（证明两组测试互不覆盖）

注入 B：把关键词兜底整块删掉
  ⇒ error_classification_matches_frontend_rules  FAILED (left: other / right: network)
  ⇒ 关键词那条红；前缀 24 条**仍然绿**

⇒ 两个方向各自独立变红，谁也不替谁兜底。
```

### 跨层端到端（最关键的读数）

```text
task41_danmaku_send_onwire_test —— 真 DLL → FFI → 真 QuickJS 插件

修复前：kind = other      （当时只能退而断言「消息带前缀」）
修复后：kind = unsupported （现在直接断言 kind）

同一次跑打印的证据：
  kind=unsupported msg=unsupported: 这个源只声明了能力，没真的实现发送
```

⇒ 这条测试已从「只能断言前缀」升级为「直接断言 kind」，
  它是唯一能证明线上行为真的变对了的读数。

## 出处

```text
rust/sourin_core/src/ffi.rs                        classify_error + 4 条新测试
test/task41_danmaku_send_onwire_test.dart          断言从「前缀」升级为「kind」
```