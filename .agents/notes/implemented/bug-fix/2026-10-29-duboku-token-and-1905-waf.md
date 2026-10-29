# Agent Note: duboku 的 400 有一半是我们少发了 token；1905 是 WAF + 签名密钥双杀

Status: implemented

Independent: 与 `2026-10-29-five-failing-sources-triage.md`（HTML 站"站点自己说没片"）不同：
这两家是**接口/签名**层面：一家我们少发参数（可修），一家服务端换了密钥（不可修）。

## Problem

「全部」搜索里这两家长期报错：

```text
csp-duboku    → 上游 Duboku 返回 HTTP 400 Bad Request
csp-web1905   → 上游 1905 返回 HTTP 403 Forbidden
```

## 真读数（curl / 我们自己的代码，2026-10-29）

### duboku

```text
api.dbokutv.com（Cloudflare）：
  无参数： /  /home  /vodshow/1--------1---  /vodsearch…  /zzz-nonexistent  → 全 400 / 7B "Failure"（catch-all，连不存在的路径也一样）
  带 DEX 复刻的 ?sign=&ssid=&token=：全 417 / "Failure"（"/" 甚至 500 + CF troubleshooting JSON）
域名：duboku.tv 的 NS 已是 parklogic.com（停放商）；w.duboku.io 不解析；duboku.io TLS 失败
```

⇒ 400 的一半是**我们的 bug**：`token_query()` 早就写好了，但**请求路径从没调用过**（只有测试调）。
带上 token 后服务端行为分叉（400 → 417）证明参数层对上了；417 = worker 已转发、origin 不响应 ⇒ 站点侧已死。

### 1905

```text
www.1905.com 全入口：403 + `Ws-Action: bot` + 6072B「Embed Iframe」JS 挑战页（网宿 WAF）
  /  /robots.txt  /favicon.ico  /vod/list/…  /api/content/…  → 全 403（浏览器全套头也一样；http:// 与无 www 都 302）
profile.m1905.com（取流）：HTTP 200 但业务码分档
  参数齐全 + DEX 的 SHA-1 ⇒ {"StatusCode":403,"info":"HTTP请求不合法,请求参数可能被篡改"}
  缺 signature/page      ⇒ {"StatusCode":400,"info":"请求参数不完整或不正确"}
  52 个签名变体（page 单/双/不转义 × uuid 带后缀 × ms/s × sha1/md5 × 大小写 + 4 个简化式）⇒ 全 403
```

⇒ 参数层是对的，**服务端签名密钥/算法已变**；WAF 另有一层，没有可绕入口。

## Decision

```text
duboku：
  ① 位级复刻 DEX 的 `b()`（JavaRandom 48 位 LCG，seed=now*1000，
     nextInt(0x2faf0800)%0x2faf0801；交错 String.valueOf(now) 与 (1e8+r)+(9e8-r)；
     Base64 → '.' → 每 3 字符反转）；
  ② home/search 走 DEX 逐字路径（/home、/vodsearch?wd=），**所有入口都带 token**；
  ③ 错误分档：400=缺参数（我们修）／417·5xx=上游不可用（如实报）／403·404 各自语义。
1905：
  只做**如实分档**：`classify_http_error`（403 + `Ws-Action: bot` 或 Embed Iframe ⇒ WAF ⇒ 不可用）、
  `play_status_error`（业务 403 ⇒ 签名被拒），错误串带 Ws-Action 与 body 前 80 字。
  **不破解 WAF、不猜签名密钥**（52 个变体已经证明猜不出来）。
```

## Alternatives considered

### A. duboku：把 400 当"上游死"直接放弃

**最强理由**：站点域名已经挂到停放商，看得见的结论就是"死了"。

**否掉的原因**：400 与 417 的分叉证明**服务端在按参数分档**，而原实现连 token 都不发 ——
我们的错误描述会把"我们少发参数"和"站点挂了"混成一句话，下次换镜像时又得重新踩一遍。
修好这一层，换任何同协议镜像都能直接用。

### B. 1905：继续爆破签名（换 salt / 试其它哈希）

**最强理由**：业务码明确说"参数可能被篡改"，看起来只差一个 salt。

**否掉的原因**：52 个变体（含 DEX 逐字 SHA-1、大小写、page 编码差异、ms/s）**全 403**。
再猜就是纯粹的运气游戏，而且 WAF 那层独立存在（连 `/robots.txt` 都 403）——
即使签名猜中，列表页也进不去。⇒ 如实标"当前不可用"。

### C. 1905：上无头浏览器过 WAF

**最强理由**：WAF 是 JS 挑战，浏览器能过。

**否掉的原因**：这是架构级改动（内嵌 WebView/无头浏览器做数据抓取），
且取流那层仍需要**新密钥**——过 WAF 也拿不到播放地址。投入产出不成立。

## Consequences

**收益**

- duboku 的 token 协议被**位级复刻并固化**（4 组定值向量门禁）：换镜像即可复用，不会重蹈"少发参数"。
- 1905 的错误终于能区分「WAF 拦」与「签名被拒」——排障时不再看到一句笼统的 403。
- 两家都进"当前不可用"的如实名单，不再用假成功污染"可用源数"。

**代价与边界**

- duboku 现在**仍然搜不到**（上游 417）；1905 **仍然搜不到**（WAF+签名）。
- `md5`/`Random` 复刻是逐位照抄 DEX，若上游换算法仍要重取一次。

## 验证结果（已发生）

```text
cargo test --lib csp::duboku  --release → 18 passed / 0 failed（2 ignored = 真网 smoke）
cargo test --lib csp::web1905 --release → 14 passed / 0 failed（2 ignored = 真网 smoke）
真网（我们自己的代码，不是 curl）：
  duboku：无 token ⇒ 400 Failure；带 token ⇒ 417 Failure；home 如实失败「上游不可用」
  1905  ：WAF 403 被分类为不可用；play 业务 403 被分类为签名被拒
故障注入（已实测真红）：
  A `api_url` 丢 token ⇒ api_url_carries_token FAILED（"★ /home 少了 sign="）
  B 删 417 分档 ⇒ real_upstream_transcripts_classify FAILED
  C 删 WAF 分档 ⇒ real_waf_403_is_classified FAILED
  D 删签名分档 ⇒ real_play_status_is_classified FAILED
```

## Relations

- 同批"假红"定性：[./2026-10-29-five-failing-sources-triage.md](./2026-10-29-five-failing-sources-triage.md)
- 源数口径（谁参与搜索）：[../feature/2026-10-29-restore-auto-disabled-sources.md](../feature/2026-10-29-restore-auto-disabled-sources.md)