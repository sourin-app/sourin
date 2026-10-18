# Agent Note: 插件 HTTP 读不到「按源配置的代理」

Status: implemented

## Problem

用户给某个源单独配了代理（或配成直连），插件发出的请求**完全不理会这份配置**。

具体表现：设置页里明明配好了，实际请求却走的是另一个出口。
某些源**必须直连**——走代理会被服务端按风控拒掉（实测同一 URL：
直连 200 / 走代理 403）。用户看到的就是「配了也没用」。

## Decision

把**真实 provider id** 一路透传到建 HTTP 客户端的地方。

改前：

```rust
// plugins/mod.rs
let client = match proxy {
    Some(px) => px.client_for("plugin", None)...  // 字面量 key
    None => default_client(),
};
```

UI 侧存配置用的是 `widget.providerId`（真实插件 id），
插件侧查的却是 `"plugin"` 这个 key ⇒ 永远查不到 ⇒
落到 `ProxyConfig::default()` ⇒ `mode = Direct` ⇒
`build_client` 里走 `.no_proxy()` ⇒ **强制直连**。

改后：`do_http` / `do_http_full` / `probe_url` 三个函数都加
`provider: &str` 参数，四个调用点传 `&pid`。

### 为什么 `fetch_plugin_source` 保留字面量

它是「安装插件时下载插件源码」——此刻插件还不存在，
没有 provider id 可用。用固定 key 是语义正确的，不是漏改。
函数内已加注释说明，新门禁也把它算作唯一例外。

## Alternatives considered

**「让 ProxyStore 支持一个通配 key，查不到真实 id 就回落到通配」**
放弃了。理由：回落会让「用户没配这个源」和「用户配了但读不到」
两种情况长得一模一样，日后同类 bug 更难发现。
宁可让它明确地读不到、由测试盯着，也不要一个会兜底的模糊语义。

**「把 provider id 塞进 ProxyStore 的查询上下文（thread-local）」**
放弃了。隐式上下文比显式参数更难追，而且 `do_http` 是 async，
跨 await 的 thread-local 本身就有坑。

## Consequences

收益：按源配置的代理真的生效了；「某源必须直连」这类需求有了支撑。

代价：三个公开函数签名变了，所有调用点必须跟着改
（本轮改了 4 个生产调用点 + 10 个测试调用点）。
签名变化是编译期错误，不会静默漏掉。

## Testing

新增 `rust/sourin_core/tests/zz_t64_proxy_per_provider.rs`，5 条：

| 用例 | 防什么 |
|------|--------|
| `proxy_config_is_keyed_by_real_provider_id` | 按真实 id 存/读；`"plugin"` 不该命中 |
| `unconfigured_provider_defaults_to_direct` | 未配置必须 Direct |
| `do_http_does_not_hardcode_plugin_key` | 源码断言：代码行里硬编码只许 1 处 |
| `do_http_signature_takes_provider` | 签名必须带 provider 且透传 |
| `both_http_call_sites_pass_pid` | GET/POST 两个调用点都必须传 `&pid` |

**故障注入验证**（把 `.client_for(provider, None)` 改回 `"plugin"`）：

```text
注入后： test result: FAILED. 4 passed; 1 failed
恢复后： test result: ok.    5 passed; 0 failed
```

⇒ 门禁真的会红，不是摆设。
