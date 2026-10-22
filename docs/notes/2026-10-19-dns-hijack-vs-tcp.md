# DNS 被劫持 vs TCP 连不上 —— 内置 dan-api 用不了的归因（第 66 轮 R3-③/⑦）

> 记这份的原因：同一个现象（"连不上"）有**两种完全不同的病因**，
> 而对用户意味着**完全不同的操作**。归错类等于给错建议。
>
> 本仓记过一次"把故障伪装成空结果"，这次是它的镜像：
> **把劫持伪装成"网络不通"**。

## 1. 现象

Owner 原话（两条，同一件事）：

```text
R3-③ 弹幕来源搜不了
R3-⑦ 内置两个 dan-api 根本用不了
```

内置实例（`lib/core/danmaku.dart:1878` `kDanmakuPublicInstances`）：

```text
https://danmu-api-delta.vercel.app
https://danmu-api-kappa.vercel.app
```

## 2. 三层实测读数（可复跑）

全部在本机（Windows，2026-10-19）实测。**命令附在每条后面**。

### ① DNS 层：**能解析，但解析到的是伪造地址**

本机 `getaddrinfo`：

```bash
python -c "import socket;print(sorted({x[4][0] for x in socket.getaddrinfo('danmu-api-delta.vercel.app',443)}))"
```

```text
danmu-api-delta.vercel.app  → 74.86.17.48
                             + 2a03:2880:f117:83:face:b00c:0:25de
danmu-api-kappa.vercel.app  → 108.160.173.207
                             + 2a03:2880:f11b:83:face:b00c:0:25de
vercel.app (apex)           → 199.96.58.15
                             + 2a03:2880:f117:83:face:b00c:0:25de
```

**真值**（Cloudflare DoH，不走本机 DNS）：

```bash
curl -s --max-time 12 "https://cloudflare-dns.com/dns-query?name=danmu-api-delta.vercel.app&type=A" \
  -H "accept: application/dns-json"
```

```text
danmu-api-delta.vercel.app  → 216.198.79.3 / 64.29.17.3
danmu-api-kappa.vercel.app  → 216.198.79.67 / 64.29.17.67
vercel.app (apex)           → 216.198.79.131 / 64.29.17.131
vercel.com  (对照，能通)     → 64.239.123.129 / 64.239.123.65   ← 本机解析**一致**
```

| 域名 | 本机 DNS | DoH 真值 | 判定 |
|---|---|---|---|
| danmu-api-delta | 74.86.17.48 + `face:b00c` | 216.198.79.3 / 64.29.17.3 | ✗ 不一致 |
| danmu-api-kappa | 108.160.173.207 + `face:b00c` | 216.198.79.67 / 64.29.17.67 | ✗ 不一致 |
| vercel.app apex | 199.96.58.15 + `face:b00c` | 216.198.79.131 / 64.29.17.131 | ✗ 不一致 |
| **vercel.com（对照）** | 64.239.109.193 | 64.239.123.129 | ✓ 一致（且能通） |

伪造特征（三条独立佐证）：

```text
① 2a03:2880:…:face:b00c —— `face:b00c` 是 Facebook 的固定花样段
② 74.86.17.48      PTR = 30.11.564a.ip4.static.sl-reverse.com（SoftLayer）
   108.160.173.207  PTR = www.v.dropbox.com（Dropbox）
   199.96.58.15     无 PTR
   ⇒ 三个都不是 Vercel 的 anycast 段
③ vercel.com 解析**正确且能通** ⇒ 不是"DNS 整体坏了"，是**特定域名被针对**
```

### ② TCP 层：连不上（**但连的是错地址**）

```bash
python -c "
import socket
print(socket.create_connection(('danmu-api-delta.vercel.app',443),timeout=20))"
```

```text
TimeoutError 16.06s        ← 连 74.86.17.48（伪造地址）超时
```

对照（真·DNS 失败长什么样）：

```text
一个不存在的域名 → socket.gaierror errno 11001「不知道这样的主机」，0.03s
```

### ③ 服务层：**是活的**

```bash
# 走本机代理（代理在自己的网络里解析，绕开被劫持的本地 DNS）
curl -s -o /dev/null -w "%{http_code}\n" --max-time 15 https://danmu-api-delta.vercel.app/api/config
# → 401 Unauthorized（服务在，只是这个路径要 token）

curl -s -o /dev/null -w "%{http_code}\n" --max-time 15 \
  "https://danmu-api-delta.vercel.app/87654321/api/v2/search/anime?keyword=a"
# → 200 {"errorCode":0,"success":true,"animes":[...]}
```

## 3. 结论（正确的三层因果）

```text
① DNS 层：**被劫持/污染** —— 返回伪造地址（"能解析"不等于"解析正确"）
② TCP 层：连不上 —— 但**连的那个地址本来就是错的**
          ⇒ "TCP 超时"不是独立病因，而是 ① 的**后果**
③ 服务层：**活的**（代理下 401；带 token 前缀 200）
```

**不是**：
- ✗ "内置 dan-api 服务坏了" —— 它是活的
- ✗ "vercel.app 整片挂了" —— `vercel.com` 正常
- ✗ "只是网络不通/被墙" —— 那是把 ② 当病因

## 4. ★ 判据（本轮最该带走的一条）

> **「能解析」不是「解析正确」的同义词。**
>
> 判 DNS 是否被劫持，必须拿**权威/加密通道（DoH/DoT）**的真值做对照。
> 只看 `getaddrinfo` 有没有抛异常，会把劫持误判成"网络不通"。

我第一次就是这么判错的：只看到解析没抛异常，就写下"DNS 没被污染、断在 TCP"，
把**后果当成了病因**。Lead 用 DoH 对照后纠正 —— 两组读数并不矛盾
（确实能解析、确实 TCP 超时），矛盾只在**归因**。

## 5. 对用户可见文案的影响（产品要求）

这两句对用户意味着**完全不同的操作**，绝不能混用：

```text
dnsFailed    「域名解析失败（本机 DNS 不通）」
             ⇒ 操作：换网络 / 修 DNS

dnsHijacked  「域名被解析到了错误地址（DNS 可能被劫持）」
             ⇒ 操作：**换 DNS（DoH/DoT）或开启代理**
                —— 改弹幕地址没用
```

实现：`lib/ui/widgets/danmaku_settings_dialog.dart` 的
`DanmakuProbeFailure` / `DanmakuProbeReport`（播放页面板与设置页**共用**一份）。

判据是**纯函数** `DanmakuProbeReport.isKnownForgedAddress(ip)`，
覆盖：`face:b00c` 花样段、SoftLayer `74.86.17.*`、Dropbox `108.160.173.*`、
`199.96.58.*`、Facebook `157.240.*`、Twitter `199.16.*`。

```text
⚠️ 这张表是**证据表**，不是"黑名单防御"：只用于**解释失败原因**，
   不参与"允不允许连"（那会让误判变成功能不可用）。
⚠️ 表不可能穷举 ⇒ 另有 DoH 复核兜底：
   解析成功 + TCP 超时 + DoH 真值不同 ⇒ 同样判 dnsHijacked。
   DoH 请求自己也可能被拦 ⇒ 它只能是**佐证**，不能是前提。
```

门禁：`test/zz_t66_r3_probe_truth_test.dart` ⑥ 组
（含**反证**：真值地址不许被判成伪造，防止判据写成恒真）。

## 6. 与计划里"DNS 污染"说法的差异

计划早期写的是「`*.vercel.app` 被 DNS 污染」。
**方向是对的**（确实是劫持），但**证据链当时不完整** —— 我一度按"解析成功"
否掉了它，那是我错。

现在两者**一致**，只是把判据补严了：

```text
旧表述：*.vercel.app 被 DNS 污染              ← 结论对，缺证据
本记录：能解析但地址是伪造的（DoH 对照 + PTR 佐证 + vercel.com 对照）
        ⇒ 同一件事，现在**可复跑、可证伪**
```

以实测为准，不以计划措辞为准。
