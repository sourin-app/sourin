# Agent Note: SeedHub 解析全对但取不到数据 —— Cloudflare 只放行部分 TLS 指纹（换栈也钉不住版本）

Status: implemented

Independent: 与 `2026-10-29-five-failing-sources-triage.md`（站点自己说没片）不同，
本条是**协议层可达性**问题：页面能解析、结构完全对得上，但我们的 HTTP 栈被 CDN 挡在门外。
不改任何解析代码，产出是"要不要换 TLS 栈"这个决定的证据。

## Problem

订阅里 `csp_SeedHub`（💯Seed丨网盘资源，`ext.site` = sidhub.cc / seeduck.cc / hubdog.cc）
是**唯一有真实 host 的未实现类**，看起来最容易补一个可用源。

真读数（2026-10-29，`curl --noproxy '*'` + Chrome UA）：

```text
https://sidhub.cc/    → 302 / 143 B（跳板，Location: https://seedog.cc/）
https://seeduck.cc/   → 200 / 42104 B（同一套站）
https://hubdog.cc/    → 200 / 42104 B（字节完全一致）
https://seedog.cc/    → 200 / 42104 B
搜索 /s/老舅/          → 200 / 21179 B → 解析 1 条（id=126348「老舅」）
详情 /movies/1/       → 200 / 51750 B → 51 集（ul.pan-links 12 个 /link_start/ + ul.seeds 磁力）
分类 /categories/1/…  → 200 / 37893 B → 20 条
```

⇒ 我们的 `seed_hub.rs` 解析器**完全对得上**（三条门禁用真实片段跑绿）。

但**模块自己的客户端（reqwest/rustls）三家全 403**：

```text
403 body: <!DOCTYPE html><html lang="en-US"><head><title>Just a moment...</title>…（Cloudflare 挑战页）
```

## 真因（客户端矩阵，同一分钟 / 同一出口 IP / 同一 URL）

```text
curl 8.13 (Schannel，协商到 TLS1.2)   → 200 / 42104 B   ✔
python3   (OpenSSL 3.x，TLS1.3)       → 200 / 42104 B   ✔
.NET HttpClient (Schannel，TLS1.3)    → 403 Just a moment
reqwest/rustls (本仓唯一栈，TLS1.3)    → 403 Just a moment
```

⇒ 卡的是 **JA3/JA4 指纹 + TLS 版本**，不是缺头、不是站点死（同机换栈就通）。
已排除的无效改法：强制 HTTP/1.1、补全 `Sec-Fetch-*` / `sec-ch-ua` / `Referer`。

## Decision

```text
**不给 SeedHub 加 `register_site!`**（保持"未实现"，不造一个看起来支持却永远取不到数据的源），
把客户端矩阵与两条技术结论写进 `seed_hub.rs` 头部；
解析实现与 3 条门禁（真实片段）保留 —— 将来 TLS 栈能过 CF 时直接注册即可。
```

### 为什么连"换 TLS 后端钉 TLS1.2"这条便宜路也走不通

```text
我实现并**回滚**了一次：加 reqwest 的 `native-tls` 特性 + `native-tls` 直接依赖，
想用 Schannel **强制 TLS1.2**（curl 就是这条通的）。结果：
  · `native-tls 0.2.18` 的 `TlsConnectorBuilder` **没有** min_proto_version/max_proto_version
    （查了 cargo registry 里的源码，只有 danger_accept_invalid_certs / _hostnames）；
  · `reqwest::use_preconfigured_tls` 只接受 `native_tls::TlsConnector` ⇒ 没有别的口子。
⇒ 即使换后端，Schannel 仍会用 TLS1.3 ⇒ 依旧 403。
⇒ 要过只能上 **vendored OpenSSL**（Windows 上编译 openssl）：为 1-2 个源把全局 TLS 栈换掉，
  构建代价与回归面都不划算 —— 不做。已把 `Cargo.toml` 的 native-tls 特性/依赖与临时模块
  `http_tls.rs` 全部删除（`native-tls` 命中 0 次）。
```

## Alternatives considered

### A. 上 vendored OpenSSL（`native-tls-vendored` 或直接用 openssl）

**最强理由**：curl/python 都能过，说明只要指纹像 OpenSSL 就行；这是唯一确定能通的路。

**否掉的原因**：Windows 上要编译 openssl（CI 时间与工具链风险），且会改变**全仓** TLS 行为
（证书校验策略、TLS1.0/1.1 支持面、打包体积），为 1-2 个源换全局栈不划算。
若将来有≥5 个源都卡在 CF 指纹上，这个权衡会反转 —— 届时再做。

### B. 给 `seed_hub.rs` 加 `register_site!`，让它"能搜但报错"

**最强理由**：源列表里多一个名字，数字好看。

**否掉的原因**：那正是本仓反复禁止的形态 —— 用户点进去永远 `403 Just a moment`。
门禁 `must_not_be_registered_because_rustls_gets_challenged` 就是钉这一条（现在仍绿）。

### C. 找非 CF 镜像

**最强理由**：绕开指纹问题，成本最低。

**否掉的原因**：`ext.site` 三个 + `seedog.cc` 全在 CF；站点图床域
`sh1/sh2.pcie.pppoe.top` HTTPS 直接 TLS alert、HTTP 301 回 https ⇒ 没有可用镜像。

## Consequences

**收益**

- 「CF 按 JA3/TLS 版本放行」这条被**测成矩阵**，并留下"Rust 侧钉不住 TLS1.2"的硬约束
  （省掉后来人再花一轮去试 native-tls）。
- SeedHub 的解析与 3 条门禁保留：一旦 TLS 栈能过，注册一行就上线。
- 没有制造"看起来支持却永远失败"的源。

**代价与边界**

- SeedHub 仍然不可用（源数不加）。
- 同类风险仍在：`suoniapi`（403 Cloudflare）等 CF 站点同理不可达。

## 验证结果（已发生）

```text
cargo test --lib csp::seed_hub --release → 18 passed / 0 failed / 1 ignored
  live_2026_10_29_search_fragment_yields_the_one_real_item   （绿：items=1，id=126348）
  injection_broken_item_shell_must_yield_zero                （红：改坏条目外壳 ⇒ items=0，原 20）
  injection_broken_pan_links_loses_the_pan_episodes          （红：改坏 pan-links ⇒ 集数 51→39）
  must_not_be_registered_because_rustls_gets_challenged      （绿：确认没有 register_site!）
回滚核对：Cargo.toml 的 native-tls 命中 0 次；src/http_tls.rs 不存在。
```

## Relations

- 同批源数口径：[../feature/2026-10-29-restore-auto-disabled-sources.md](../feature/2026-10-29-restore-auto-disabled-sources.md)
- 另一类"源坏"（上游关搜索/站点死）：[../bug-fix/2026-10-29-five-failing-sources-triage.md](../bug-fix/2026-10-29-five-failing-sources-triage.md)