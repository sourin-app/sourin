# Agent Note: 遥控 play_item 聚合条目「找不到子站」—— 入口剥 provider 路由前缀（P1）

Status: implemented

Independent: 与 Rust 侧 `route()`（tvbox_aggregate.rs:517）是**同一契约的两半** ——
本条只修 Dart 侧"喂进去的 id 形状"；Rust 归 rust-quark，未动。

## Problem

真机读数（driver-ops 驱动器，`.probe/play-driver/results/drive-20261029-234208.json`）：

```text
play_attempts: [{provider:'tvbox_agg', id:'tvbox_agg:csp-4kzhinan-47098b5a::19106', ok:false}]
```

根因链（读源码闭环）：
```text
① 手机端搜索结果的 id 是复合串 = MediaId.as_key()（model.rs:70）
   = provider + ':' + native，native = '<子站id>::<原始id>'（wrap_item，tvbox_aggregate.rs:565）
② 遥控 play_item 把 (provider, 复合id) 原样传到 _openItemFromRemote
③ Rust get_detail（playback.rs:55）MediaId::new(provider, id) —— id 原样当 native
④ 聚合 route() 按 '::' 切 child ⇒ 'tvbox_agg:csp-xxx' ⇒ registry 没有 ⇒ 「找不到子站」
```

而 App 自己的搜索打开路径（search_page.dart `_open` :728）**总是**先按第一个 ':'
把复合 id 切成 provider + native 再往下走 —— 所以点 App 里的搜索结果一直是好的，
唯独遥控这条路径坏了。

## Decision

```text
① 纯函数 stripProviderRoutePrefix(provider, id)（shell.dart 顶层，@visibleForTesting）：
   id 以 'provider:' 开头 ⇒ 剥一次；否则原样。与 MediaId::parse 的 split-once 同源。
② _openItemFromRemote 入口剥一次，getDetail / getEpisodes / PlayRequestData
   三处全用剥过的 nativeId（resolveStream 也走 PlayRequestData.id —— 否则后续照样炸）。
③ 只剥一次：native 里本就允许 ':'（子站原始 id 可能是 '19106' 也可能是 URL），
   循环剥会把子站 id 弄坏。
```

## Alternatives considered

### A. 在 Rust 侧 get_detail 里对"native 以 provider: 开头"做容错剥离

最强理由：所有调用方（现在与将来）一次修好，Dart 不用各点防。

否掉的原因（本轮）：Rust 归 rust-quark；且"provider 前缀 + 复合 native"本身是
**调用方形状错误**，在 Rust 容错会把形状契约搅浑（native 里合法含 ':'，
容错剥离会与"native 真以别的源前缀开头"的合法场景打架）。已按预授权口径只改
Dart，并把这条作为根修候选方案报 lead 裁决。

### B. 只在 getDetail 一处剥（剧集/会话 id 不动）

否掉的原因：getEpisodes 与会话 id（resolveStream / 续播键）同样吃复合 id ——
修一半等于把炸点往后挪。

### C. 手机端搜索回传时就把 id 拆成 provider/native 两字段

最强理由：源头治本，服务器端不再需要猜。

否掉的原因（本轮）：要动遥控协议与手机端 page.html（不在本批范围/不在本仓）；
Dart 入口剥一次即可闭环，协议改造另行立项。

## Consequences

**收益**
- 手机端点聚合搜索结果直接起播（改前 ok=false、点了没反应）。
- 会话 id 从此是 native 形状 ⇒ 换源/续播/进度键不再带坏前缀。

**代价与边界**
- 幂等设计（已剥过的 id 再进来原样返回），调用方重复剥无副作用。
- 若将来手机端协议改为两字段，本函数变成 no-op（前缀不存在）⇒ 可安全退役。

## ⚠️ 事故记录（同一工作段，如实报备）

```text
做故障注入时用 PowerShell Set-Content 整文件替换 shell.dart 的三处接线，
Windows PowerShell 5.1 以 ANSI 码页读写 UTF-8 文件 ⇒ 全文件中文变乱码
（编译崩溃，且 flutter test 表现为长时间无响应而非快速报错，连续两次误判为
 libmpv 偶发崩溃）。处置：git checkout -- lib/shell.dart 恢复 HEAD（P1 改动未
 提交、按记录重放），改用编辑工具重做注入与恢复。
教训：本仓任何"整文件改写/替换"必须走编辑工具或 git apply，禁用
 Set-Content/Clear-Content 之类按行读写 UTF-8 源码的 cmdlet。
```

## 验证结果（已发生）

```text
门禁：test/t20261030_remote_play_item_prefix_test.dart → 6 passed
  ① 纯函数 4 条（聚合复合 id / URL 型原始 id / 幂等与空值 / 非聚合源）
  ② 接线 2 条（窗口内 strip 调用 + getDetail/getEpisodes/PlayRequestData 三处
    nativeId；窗口法钉函数体，不误伤 shell.dart 里续播去重那条合法的
    getDetail(provider, id)）
回归：test/remote_bridge_test.dart → 66 passed（play_item 接线/全局能力分流无回归）
analyze lib/shell.dart → 0 errors
故障注入（实测真红后恢复复绿）：三处退回原始 id ⇒ 窗口断言红
真机复验：等批末统一（部署后由 driver-ops 用 play_item 重放聚合条目，期望 ok=true）
```

## Relations

- 同批 1.4（同一条遥控协议链）：[./2026-10-30-episode-number-normalized-line-switch.md](./2026-10-30-episode-number-normalized-line-switch.md)
- 驱动器证据（输入）：.probe/play-driver/results/drive-20261029-234208.json
