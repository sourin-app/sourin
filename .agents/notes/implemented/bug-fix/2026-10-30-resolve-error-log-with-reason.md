# Agent Note: resolve 失败日志补真实原因并脱敏 —— 67 条失败只记 kind=Other 等于没写

Status: implemented

Independent: 与 `2026-10-30-applog-file-log-writer.md`（建立 write_file_log 直写器本身）互补：
那条解决"日志能不能落盘"，本条解决"落盘的内容够不够排障"。两条都在 `.probe/play-audit-all-sources-2026-10-30.md`
的真机抽测里被验证过。

## Problem

2026-10-30 全子源实机抽测（43 源 × 124 条真机播放）产出 67 条 FAIL，翻日志看到的是：

```text
[PLAY] resolve 失败 provider=tvbox_agg id~=csp-gui-gui::6745682ca98 kind=Other needs_login=false
[PLAY] resolve 失败 provider=tvbox_agg id~=csp-hdmoli-febcad0c::285 kind=Other needs_login=false
[PLAY] resolve 失败 provider=tvbox_agg id~=csp-jpys-21388842::14118 kind=Parse needs_login=false
…（67 条，全为 kind=Other / kind=Parse）
```

`kind` 只是错误**类别枚举**，`Other`/`Parse` 这种值对排障毫无信息量 ——
**67 条失败，一个真实原因都没有**。上一批加日志的努力在这个维度上等于白做：
落盘（能看见了）与可诊断（看得懂）是两件事，之前只解决了前一件。

同时还有脱敏约束：`e.message` 里常带分享页 URL 与 token，不能原样落盘。

## Decision

两处改动，一个门禁：

```text
① playback.rs 的 resolve 失败日志追加 `msg={}`，值 = applog::scrub_err_msg(&e.message)
② applog.rs 新增 pub fn scrub_err_msg(raw) -> String：
     · 去掉每个 URL 的 `?query` 与 `#fragment`（凭据常在 pwd=/token= 里）
     · 连续 >=40 字符的 [A-Za-z0-9_-\.=] token 串整体换 <redacted>（JWT / OSS 签名 / md5）
     · 保留 host/path/HTTP 状态码/中文原文（诊断要看的都在这些里）
     · 总长截 240 字符 + 省略号
③ 门禁 file_log_gate 新增 scrub_err_msg_removes_credentials_keeps_diagnosis，4 组断言：
     ① query/fragment 去掉但 host+path 保留
     ② 长 token 换 <redacted>，且 HTTP 状态码保留
     ③ 正常中文错误文案**逐字原样**返回（脱敏不许把诊断价值一起洗掉）
     ④ 短标识（csp-4kzhinan-47098b5a::20327）不被误伤
```

## Alternatives considered

- **直接记 `e.message` 原文**：能诊断，但把分享页 URL 的 `pwd=`/`token=` 写进日志，
  违反"凭据不进日志"的硬线。否决。
- **只记 kind 不记 message（现状）**：就是本次问题本身。否决。
- **按 provider 白名单决定记不记 message**：白名单会漂，且新源接进来就漏。否决。
- **用现成 crate（如 `redact`）做脱敏**：本仓依赖面已很宽，为一个 40 行的字符串处理
  再加依赖不划算，且通用 crate 不理解"URL query 里有网盘 pwd"这个领域特征。否决。
- **只截断不脱敏（截 240 字符）**：截断救不了 `?pwd=xxx` 出现在前 60 字符的情况。否决。

## Consequences

门禁读数：`cargo test --test file_log_gate --release` ⇒ **3 passed / 0 failed**。

注入证红（实测，已回滚）：

```text
把 scrub_err_msg 改成 `raw.to_string()`（恒等函数）⇒
  test scrub_err_msg_removes_credentials_keeps_diagnosis ... FAILED
  query 必须去掉：解析失败 https://pan.quark.cn/s/abc123?pwd=x9f2&token=abc#frag
  test result: FAILED. 2 passed; 1 failed
回滚后复跑 ⇒ 3 passed（证明门禁不是恒绿）
```

效果示例（门禁固定下来的形态）：

```text
输入：解析失败 https://pan.quark.cn/s/abc123?pwd=x9f2&token=abc#frag
输出：解析失败 https://pan.quark.cn/s/abc123

输入：取直链返回 HTTP 400 Signature=<40 字符以上的串>
输出：取直链返回 HTTP 400 Signature=<redacted>

输入：该分享的文件超出夸克下载上限，请换一条线路（已尝试 1 个候选）
输出：（逐字原样，不变）
```

边界与如实记录：

- ⚠️ **本次修的是"能不能看见原因"，不是"失败本身"**。67 条 FAIL 的根因（resolver 侧）
  仍未修；本改动只是让下一次抽测能直接读出每个失败的真实原因。
- `scrub_err_msg` 的 URL 识别是**启发式**（遇 `:` 后视作进入 URL），对畸形串可能漏去 query。
  门禁钉住了常见形态；若将来出现漏脱敏，应按新读数补规则，不许放宽断言。
- 报告 `.probe/play-audit-all-sources-2026-10-30.md` 记录了这次抽测暴露的四个问题
  （本条的日志缺陷、分享页 URL 直链化缺失、遥控结果不回传、聚合覆盖度 43/107）。
