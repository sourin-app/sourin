# Agent Note: 阿里扫码 CONFIRMED 后静默失败 —— bizExt 中段非 UTF-8 用 lossy 续解 + 原始 body 落盘

Status: implemented

Independent: 接续 `2026-10-30-pan-login-t5-aliyun-bizext-115-cookie-baidu-unicast.md`
（那篇修了 base64 字母表并如实报"密文形态超出取证范围"）。本篇用**当天拿到的真
CONFIRMED 读数**推进了那篇留下的未决问题，并修掉一个静默失败。

## Problem

2026-10-31 09:35:06 真机 CONFIRMED（Owner 真实扫码）：

```text
[PAN] 轮询 kind=aliyun 状态=confirmed 原始="CONFIRMED" … bizExt:"eyJwZHNfbG9naW5f
cmVzdWx0Ijp7InJvbGUiOiJ1c2VyI…（共 3222 字节）
—— 之后再无任何日志行（换 token 失败零留痕）
```

两个缺陷：
1. **静默失败**：`aliyun_token_from_body` 的 Err 直接冒泡，日志一行没有；
   且日志 `tail()` 只留 170 字符 ⇒ 3222 字节的真 bizExt 拿不到全量，离线分析无从下手。
2. **严格 UTF-8 整体拒绝**：解码产物 index 200 起非 UTF-8 ⇒ 上一批的"超出取证范围"
   报错路径。但前 ~200 字节是明文 JSON（`{"pds_login_result":{"role":"user"`…），
   而 accessToken/refreshToken 全是 ASCII ⇒ 中段损坏（最可能是昵称字段的非 UTF-8
   编码）**不影响** token 可取。

## Decision

```text
① dump_pan_body(kind, body)：CONFIRMED 的完整 body 落
   %APPDATA%\app.sourin.player\exports\pan-<kind>-body-<HHmmss>.json
   （凭据敏感 ⇒ 只落本机 exports，仓库外 + .gitignore 双保险，与凭据备份同待遇；
   测试进程不落）。阿里与百度两处都接。
② lossy 续解：String::from_utf8 失败 ⇒ from_utf8_lossy + 照常 JSON 解析 +
   token 存在性校验；仍解不出才报错（且报错时原始 body 已 dump）。
③ CONFIRMED 后失败必留 [PAN] 日志（换 token 失败 kind=aliyun 原因=…）。
④ 百度 channel_v 确认时同样 dump（T2 排障用）。
```

## Alternatives considered

- **换 base64 字母表重解**：`-/_` 与 `+/` 两解当前实现都认（昨日已修），字母表
  混用会导致中段垃圾——但这属于假设，需要真向量验证；lossy 已经能让"昵称损坏"
  这一最可能形态走通，先落它。若真向量证明是字母表混用，再按向量加策略。
- **strict 失败直接报错不改**：登录永远失败 = Owner 的"还是不能登陆"。否决。
- **把 bizExt 写进普通日志**：凭据敏感，绝不进日志文件正文。只落 exports。

## Consequences

- 门禁：`cargo test --lib --release` ⇒ **1934 passed / 0 failed**（含新用例
  `aliyun_token_from_biz_ext_survives_non_utf8_middle`：JSON 中段注入 0xB2 0xE2
  坏字节、token 放在损坏点之后 ⇒ 必须仍取到 AT/RT）。
- DLL 五处一致 1096ABBAD4F3DA96 已部署（pid=712）。
- **待真机闭环**：需要 Owner 再扫码一次 ⇒ CONFIRMED 后应看到
  "原始 body 已落盘 → bizExt 非严格 UTF-8 ⇒ lossy 续解 → 换 token 成功 → 凭据已落盘"
  全链日志；若仍失败，exports 里的完整 body 就是下一步取证材料。

## 边界（如实）

- "index 200 非 UTF-8 = 昵称编码问题"当前是**最优假设**（明文 JSON 前缀 + ASCII
  token 是实证），真向量落地前不写成结论。
- 静默失败不只这一处：全仓 CONFIRMED 后的失败路径本次只修了 aliyun；
  baidu 各步本就有 write_log（1389/1399/1413/1447 行），本次只补 dump。
