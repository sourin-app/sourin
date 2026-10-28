# Agent Note: 兜底 `Client::new()` 让 `.no_proxy()` 形同虚设 —— 判据看不见的那一半

Status: implemented

## Problem

`.no_proxy()` 那条纪律（"真发 HTTP 的 csp 类必须关掉系统代理"）已经有一条全仓判据
（`tests/zz_r3i_no_proxy_consistency.rs`），它扫每个 class 文件、断言 `code.contains(".no_proxy()")`，
并且有反空真（`checked == files_with_builder`）。

独立复核发现它**能被绕过，而且绕过方式在仓里已经存在 18 处**：

```rust
Client::builder()
    .timeout(..)
    .no_proxy()                                   // ← 判据看见这一行，报绿
    .build()
    .unwrap_or_else(|_| reqwest::Client::new());   // ← 但真跑起来可能是它：不经过 builder ⇒ 读系统代理
```

判据看的是"**源码里出现过 `.no_proxy()`**"，而真正决定行为的是"**build 失败时用哪个 client**"。
两者不是一回事 —— 这是本仓反复出现的"判据作用在错误的对象上"的又一例，
只不过这回错的是**判据的完备性**，不是它指的对象。

真实后果：装代理的机器上（本机 `HTTP_PROXY=127.0.0.1:7890`），一旦 TLS 后端初始化失败，
请求会静默走系统代理，症状是 `error sending request` 或莫名超时 —— 而这**不是**"站点死了"。
本批已经为"代理冒充宕机"付过一次代价（见 `../bug-fix/2026-10-27-inconsistent-with-existing-convention-is-a-defect.md`）。

## Decision

两条一起改：

```text
① 代码：18 个 csp 文件里的 `.unwrap_or_else(|_| reqwest::Client::new())`
   → `.expect("HTTP client 构建失败（TLS 后端不可用）—— 不许退回无 no_proxy 的兜底")`
   ⇒ 失败就**当场炸**，而不是悄悄用一个会读代理的 client。
② 门禁：`zz_r3i_no_proxy_consistency` 新增一条 `no_bare_client_new_fallback_in_csp`：
   csp 文件里**一处 `Client::new()` 都不许出现**，并带反空真（`checked > 20`）。
```

选择"显式失败"而不是"兜底也带 no_proxy"的理由：
```text
`Client::new()` 的语义就是"默认配置"，想兜底就必须再造一次 builder
（`builder().no_proxy().build().unwrap_or_else(...)`）—— 那是**递归兜底**，
失败时仍然没有可用 client，只是把 panic 推迟一层。
⇒ 既然失败不可恢复，就让它读得懂地失败（expect 带原因），而不是静默降级成错误行为。
```

## Alternatives considered

1. **保留兜底，但兜底也用 `.no_proxy()`**（`builder().no_proxy().build()` 再兜一层）。
   最强理由：不改变"不 panic"的既有风格，运行时行为最接近原样。
   **否决** —— 见上：递归兜底只是把同一个失败推迟一层；而且它会让"到底有没有 NO_PROXY"
   这件事更难读（三层 builder）。本仓已经有"静默降级比显式失败更糟"的共识。
2. **只加门禁，不改那 18 处代码**（让门禁先红着，后面慢慢清）。
   最强理由：改动面最小，风险最低。
   **否决** —— 门禁红着就等于全仓不能交付；而 18 处替换是机械的、
   且都是"同一个坏形态"，一次改完最省事（`cargo check` 与 1000+ 条 csp 单测护航）。
3. **把判据加强成"解析 builder 链，确认 no_proxy 在 build 之前"**。
   最强理由：比"禁止 `Client::new()`"更精确，还能覆盖将来别的新兜底写法。
   **否决（本轮）** —— 需要写一个小的链式解析器，成本高于收益；
   "禁止 `Client::new()`"已经把当前唯一的绕过路径封死，将来出现新形态再加条款即可。

## Consequences

- 收益：`.no_proxy()` 这条纪律第一次有了**行为层**的保证（失败即炸，不会静默读代理）。
- 收益：门禁从"看有没有出现某个字符串"升级为"禁止某一类绕过形态"，并带反空真。
- 代价：TLS 后端不可用时，原来"降级继续"的类现在会**直接 panic**。
  判断依据：那种环境下请求本来也发不出去（且会走错代理），早炸比晚错好；
  若将来需要"可诊断的降级"，正确做法是让 provider 返回可读 Err，而不是换一个 client。
- 代价：18 个文件的 diff（机械替换），review 时要确认没有一处把 `expect` 用在
  "本来允许失败"的路径上 —— 这些位置全是 client 构造，不属于"允许失败"。

## Relations

- 前情：[../bug-fix/2026-10-27-inconsistent-with-existing-convention-is-a-defect.md](../bug-fix/2026-10-27-inconsistent-with-existing-convention-is-a-defect.md)
  —— 那篇立的 `.no_proxy()` 惯例；本篇补上它的**漏洞**。
- 同族：[./2026-10-28-extract-pure-function-to-gate-behavior.md](./2026-10-28-extract-pure-function-to-gate-behavior.md)
  —— 都在讲"判据要看行为，不要只看源码形态"。
