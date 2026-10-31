# Agent Note: 非媒体预检 —— resolve 交回的 URL 可能根本不是媒体流（分享页 HTML / 解析接口 JSON 信封）

Status: implemented

Independent: 修复 T4-I（审计类 I：resolve 成功但 mpv
`Failed to recognize file format`——yinhai×3 / apprj×2 / appysv2×1）。
与 T4-C（复合 id 误判，另篇）是两个独立缺口。

## Problem

真机离线复现实证（带头/不带头响应逐字节一致 ⇒ **头不是变量，头链路两端完好**）：

```text
yinhai  ×3：resolve 交给 mpv 的 URL 是网盘分享页本身
            （alipan.com/s/…、pan.baidu.com/s/…、115cdn.com/s/…）→ 200 text/html
apprj   ×2：URL 是第三方解析接口 api.nbyjson.top:7788/api/?key=…&url=…
            → application/json，真流藏在 JSON 的 url 字段里
            （实测取出 http://…/nby/m3u8/getM3u8?… 是真 m3u8）
appysv2 ×1：iqiyi.com/v_xxx.html → text/html
同源内其它条目能播 = 那些集给的是真直链。
```

mpv 拿到 HTML/JSON 当然"格式解不了"——报错本身没错，错在**没人拦在 mpv 之前**。

## Decision

`lib/ui/player/nonmedia_guard.dart`（新增纯函数层）+ `player_page.dart`
（+37/-3，_player.open 前接入）：

```text
① URL path 去参后有媒体扩展名（.m3u8/.mpd/.mp4/…）⇒ 直通，零网络零延迟
② 看不出来 ⇒ 带【候选自带头】限时 GET 一发（dart:io HttpClient，DIRECT 不走
   环境代理，文本类只读前 64KB，视频流看头即断）：
   · JSON 且带 http(s) 的 url/data.url 字段（TVBox 解析接口通用契约）⇒ 换真流起播
   · HTML ⇒ 刮引号里的 .m3u8（相对地址按 pageUrl 补全），刮到 ⇒ 换
   · 刮不到 ⇒ 人话错误（不再"格式解不了"）
③ 视频/二进制/非 200/超时/网络失败 ⇒ 原样起播（与修复前一致，预检绝不拦播放）
```

判据全在通用机制上，**无域名硬编码**。

## Alternatives considered

- **在 streamproxy/maybe_proxy 加宽门控 + 302 跟随**：会给全源直连流多一跳，
  爆炸半径大得多。否决。
- **在 Rust resolve 侧做预检**：resolve 是纯 Rust，而预检要带候选头发请求——
  那是 P9 探测已经做过的事（probe_candidates）；再加一发=起播前多一跳网络，
  且 Dart 侧在 mpv.open 前做能拿到"人话错误 + AppLog"的 UI 语义。否决。
- **域名白名单加头**：判据落域名是本仓反复批评的形态（插件源自述不可信）。
  否决。
- **yinhai 伪造直链**：分享页要真播需网盘账号链路（T1 阿里登录的地盘），
  预检层绝不伪造。如实人话报错。否决伪造。

## Consequences

- 门禁（Lead 亲验）：`test/ui/nonmedia_guard_test.dart` **11/11 绿**（四分支 +
  头传递断言：假上游捕获到候选自带的 Referer/UA 真的随预检 GET 发出 + 明显媒体
  零网络 + 超时 keep + 短路语义）；**证红**：短路预检注入 ⇒ 2 条 FAILED，还原即绿；
  flutter analyze errors=0；Rust 侧零改动（1940/0 未触碰）。
- 真机复验（14:05，app.so 14:00:42 + DLL E7F01A71）：
  **apprj 老舅 playing=True（预检换出 nby getM3u8 真流）、兰香如故 dur=2796 全绿**；
  yinhai 从「格式解不了」变人话错误「这条给的是网页/分享页链接（HTML）…」。
- 附带发现：yinhai 的剧集 id 形如 `…::aliyunhttps://www.alipan.com/s/…`
  ——阿里盘分享。T1（阿里登录）打通后此类源有望经网盘链路真播，届时预检的
  ③人话错误自动让位给真直链。

## 边界（如实）

- 预检只读文本类前 64KB：大文件视频流只看响应头即断，不下载正文。
- 解析接口只追一跳（JSON.url 换出后直接起播，不再递归预检防循环）。
