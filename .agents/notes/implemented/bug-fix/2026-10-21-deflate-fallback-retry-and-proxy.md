# Agent Note: raw-deflate 回退的重发判据与代理配置继承

Status: implemented

- 日期：2026-10-21
- 范围：`rust/sourin_core/src/plugins/mod.rs`（`do_http` / `try_raw_deflate_fallback` / `is_real_decompress_failure` / `raw_decompress_off_client`）、`rust/sourin_core/src/proxy.rs`（`AutoDecompress` / `client_for_ex` / `build_client`）
- 来源：CodeRabbit PR #32 的两条阻塞项 ①②

> 同域：[2026-10-17-plugin-http-ignored-per-source-proxy.md](2026-10-17-plugin-http-ignored-per-source-proxy.md)
> —— 那篇定的「请求必须走 per-source 代理」是本篇 ② 的前提：回退路径**重建 client**
> 时把代理配置丢了，等于把那条修复绕过去了。
> Independent of：[2026-10-18-proxy-misjudge-read-display-text.md](2026-10-18-proxy-misjudge-read-display-text.md)
> （那篇是"判据看错了对象"，本篇是"重发条件太宽 + 重建丢了配置"，不同失效点）。

## Problem

`do_http` 在 `r.text()` 失败后会**不加区分地**调用 `try_raw_deflate_fallback` 重发一次请求。这个回退本来是 2026-10-18 为「站点声明 `Content-Encoding: deflate` 但内容是 raw-deflate」修的，但它有两个问题：

1. **重发判据过宽**（CR ②）：`Err(e)` 分支不区分错误类型。`r.text()` 失败至少有四种原因，实测（本地真 `TcpListener`，2026-10-21）**四种全部 `is_decode() == true`**：

   | 场景 | `is_decode` | `is_timeout` | `source()` 第 2 层文本 |
   |---|---|---|---|
   | A 读 body 超时（头已到，body 没来） | **true** | true | `operation timed out` |
   | B 连接中途断开（`Content-Length` 不够） | **true** | false | `error reading a body from connection` |
   | C 完整 raw-deflate（真解压失败） | **true** | false | `deflate decompression error` |
   | D raw-deflate 被截断（解压中途失败） | **true** | false | `deflate decompression error` |

   后果是用户可见事故：`host.http.post` 用来发弹幕/做登录类操作，body 读到一半超时 ⇒ 回退再发一次同样的 POST ⇒ **服务端执行两次**（用户发一条弹幕，屏幕上出现两条）。GET 更糟：读超时后再等一次 `HTTP_TIMEOUT_SECS`(15s)，失败延迟最长 30s。代码注释里写的「只在正常解压失败时才走」与行为不一致。

2. **回退丢掉了代理配置**（CR ①）：`try_raw_deflate_fallback` 不使用调用方传进来的 `client`，而是从零 `reqwest::Client::builder()…build()` 新建了一个 `raw_client`。它没有 `ProxyStore::client_for` 配好的自定义代理、认证、绕过列表，也没有统一的 `user_agent`。启用自定义代理时回退可能**改走直连** ⇒ 轻则回退失败（那台站本来就得靠代理才通），重则**暴露用户真实出口 IP**（站点看到的不是代理地址）。

## Decision

**② 的判据：「source 链里出现解压失败的标志文本」才回退，不采用 CR 建议的 `e.is_decode()`。**

```rust
fn is_real_decompress_failure(e: &reqwest::Error) -> bool {
    if e.is_timeout() { return false; }          // 超时 ⇒ 请求已到达服务端，绝不重发
    use std::error::Error as _;
    let mut src = e.source();
    while let Some(s) = src {
        let lower = s.to_string().to_ascii_lowercase();
        if lower.contains("decompress") || lower.contains("deflate")
            || lower.contains("gzip") || lower.contains("brotli") || lower.contains("zlib") {
            return true;
        }
        src = s.source();
    }
    false
}
```

判据是**白名单**（「是解压错误才回退」），不是黑名单（「不是超时/不是连接错误就回退」）。白名单下将来 reqwest 新增一类 body 错误（例如 HTTP/3 流中断）时，最坏结果是少一次回退（退回原错误，用户看到真实失败原因），而不是多一次重发（用户可见事故：弹幕发两条）。

**① 的修法：同一个 `build_client`，只换「自动解压」一个开关。**

- `proxy.rs` 新增 `enum AutoDecompress { On, Off }` 与 `client_for_ex(provider, scope, decompress)`；`client_for` 变成 `client_for_ex(…, On)` 的薄包装（既有调用点零改动）。
- `build_client(provider, cfg, decompress)` 在 `decompress == Off` 时加 `.no_gzip().no_deflate().no_brotli()`；代理配置、认证、绕过列表、`user_agent`、`timeout` 全部保持不变。
- **缓存键加 `{decompress:?}`**。
- `try_raw_deflate_fallback` 的签名从 `client: &reqwest::Client` 改成 `proxy: &Option<Arc<ProxyStore>>, provider: &str`，内部调 `client_for_ex(provider, None, Off)`；无代理路径改用新增的 `raw_decompress_off_client()`（与 `default_client()` 同 timeout + 同 UA，只多三个 `no_*`）。

## Alternatives considered

**A.（针对 ②）照 CR 原话改：`if !e.is_decode() { return …; }`**

这是最省事的改法，也是 review 里明确写出来的方案，而且 `is_decode` 这个名字读起来完全就是「解码失败」的意思 —— 从语义上没人会怀疑它。**放弃它的理由是实测数据**：四种失败（超时、连接断开、真解压失败、截断解压）全部 `is_decode() == true`，因为 reqwest 把整个 `r.text()` 链都归到 `Decode` kind 下，真实原因在 `source()` 里。照这个改，A/B 两种（恰恰是会造成「重发两次」的那两种）照样会回退，缺陷原封不动。这一条在动手前用 `zz_probe_error_kinds.rs` / `zz_probe_error_kinds2.rs` 两个临时探针（已删，读数记在上表）验证过。

**B.（针对 ②）再加 `method != "POST"` 不对 POST 回退**

CR 也提了这个更保守的选项。它确实能挡住「弹幕发两条」这个具体事故，但代价是 **POST 场景下 raw-deflate 站彻底不可用** —— 而 POST 恰恰是登录、发弹幕、提交这类必须可用而且要读响应的路径。同时它不解决 GET 的 30s 延迟。用一个「牺牲整个方法类的回退能力」去换「只挡住一类错误」，是把判据放在了错误的维度上：该区分的是**错误类型**，不是**HTTP 方法**。

**C.（针对 ①）直接把调用方的 `client` 传进回退里复用**

最直觉、改动量接近零。**放弃理由是 2026-10-18 已经踩过一次**：那个 `client` 是自动解压的，`r.bytes()` 会重踩同一个解压坑，回退形同虚设（当时的注释写了要关、代码没关，二次实测才发现）。所以回退**必须**用一个自动解压关掉的客户端，不能复用现有的。

**D.（针对 ①）在 `try_raw_deflate_fallback` 里就地补代理配置**

即不改 `proxy.rs`，在回退函数内部把 `cfg.mode / url / username / bypass` 再抄一遍建 client。这样做能修掉当前这一个症状，但**代理配置的构造逻辑会出现两份**，将来 `proxy.rs` 加了新字段（例如按 provider 的 TLS 设置、超时覆盖）时回退那份会静默地不同步 —— 而且失效形态正是本 bug 的形态（回退走错出口），没有任何测试会红。所以选择把「建 client」收敛成同一份实现、只参数化一个开关。

**E.（针对 ① 的缓存键）不把 `decompress` 放进 key，靠「先建先赢」**

即两种客户端共用缓存条目。放弃理由：若先发生一次回退（建的是 `Off` 客户端），之后该 provider 的所有正常请求都会拿到 `Off` 客户端 ⇒ 那些站返回 gzip 时我们拿到原始字节 ⇒ 上层看到乱码。这是**静默**错误（不报错，只是数据不对），比崩溃更难查。

## Consequences

**读数（可证伪）**

② 判据 —— 本地服务端写完响应头后只发 10 字节就挂住，统计 accept 次数：

```text
修复后：accept = 1；失败延迟 15.0s
正面对照（真 raw-deflate）：accept = 2 且拿到明文 "hello raw deflate"（回退仍在）
故障注入（把判据改成 CR 原建议的 e.is_decode()）：accept = 2；失败延迟 25.0s ⇒ c1 变红
```

> **2026-10-22 复验修正**：上面「修复前 30.0s」的写法不准确 —— 30.0s 只是**上限**，不是这条测试的实测值。
> 用 `c1` 自己的服务端（写完头 + 10 字节后 `sleep(25s)`，accept 循环单线程顺序处理）注入
> `if e.is_decode() { return true; }` 后实测：`accept = 2`、`do_http` 返回耗时 **25.0s**。
> 机制：第一次读 body 在 15.0s 撞上 client timeout；回退请求的 TCP 已在 backlog，但服务端 accept 循环
> 正卡在上一条连接的 `sleep(25s)` 里，直到 25.0s 才被 accept 并写出响应头 ⇒ 回退随即因
> `Content-Encoding` 不含 `deflate` 而 `return None`（`plugins/mod.rs:1981`）。
> 把服务端改成「每连接一个线程、一直接受」后，第二次请求会自己等满一次 15s 超时，
> 实测总耗时 **30.03s**（`accept = 1`，第二次连接尚未被 accept 就超时）—— 那才是 15+15 的上限形态。
> ⇒ 用户可感知的代价区间是 **25.0s ~ 30.0s**（未修）vs **15.0s**（已修），两种服务端形态都验证过。

① 判据 —— 本地起最小 HTTP 正向代理并统计 accept / UA，目标地址用 `sourin-probe.invalid`（RFC 2606 保留域，直连必然 DNS 失败）：

```text
修复后：代理 accept = 2；两次请求行都是 "GET http://sourin-probe.invalid/x HTTP/1.1"；
        两次 UA 完全一致；返回 "hello via proxy"
故障注入（把回退改回裸建 client）：代理 accept = 1，
        请求行只有一条，返回 "__ERR__读取响应失败: error decoding response body" ⇒ 变红
        （同一次注入下 a2 也红：服务端只收到 1 次请求、只有 1 条 UA）
恢复后：accept = 2 ⇒ 变绿
无代理路径：两次请求都带 UA（旧代码的裸 builder 没有 UA）
```

场景 A 的错误分类复验（2026-10-22，在 `do_http` 的 `Err(e)` 分支临时打印后删除）：

```text
is_timeout=true  is_decode=true  is_body=false  is_request=false  is_connect=false
source 链：request or response body error <-- operation timed out
耗时：15.01s（client timeout 到点即失败，没有读满 Content-Length）
```

**新增/修改的测试**

- `rust/sourin_core/tests/zz_cr32_deflate_fallback_retry.rs`：`c1_timeout_must_not_retry_post`（accept=1 + 延迟<25s）、`c2_decode_error_still_falls_back`（accept=2 + 拿到明文）
- `rust/sourin_core/tests/zz_cr32_fallback_proxy.rs`：`a1_fallback_must_go_through_configured_proxy`、`a2_no_proxy_path_still_keeps_user_agent`

**代价与翻案条件**

- `is_real_decompress_failure` 依赖 reqwest/flate2 的**错误文本**。若上游改写文案（去掉 `deflate decompression error` 这类字样），回退会静默失效 —— 表现是 raw-deflate 站重新变成「读响应失败」。翻案条件：`c2_decode_error_still_falls_back` 变红就是它。届时应改用 `e.source().downcast_ref::<flate2::DecompressError>()` 这类类型判定，而不是继续加字符串。
- `AutoDecompress` 目前只有一个调用方（回退）。若将来出现第二个需要「关自动解压」的场景（例如需要原文校验签名的接口），应继续走 `client_for_ex`，不要新建第三条建 client 的路径。

## 附：为什么探针文件被删除了

`zz_probe_error_kinds.rs` / `zz_probe_error_kinds2.rs` 是**结论性探针**，不是回归测试：它们验证的是「reqwest 的四种失败各自 `is_decode/is_timeout/source()` 长什么样」。这个事实不随本项目代码变化，只随 reqwest 版本变化，读数已完整抄录在本文档的表格里。留一个永远绿的探针会让「测试通过数」里混进不保护任何东西的条目 —— 所以删掉，把读数放在笔记里，并在 Consequences 里写明「若 reqwest 改文案，`c2` 会红」。
