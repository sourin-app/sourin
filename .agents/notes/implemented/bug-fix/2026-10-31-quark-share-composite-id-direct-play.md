# Agent Note: 夸克「换分享 token builder error」真根因 —— 复合剧集 id 误判走 detail 二跳，控制字符污染 Referer

Status: implemented

Independent: 修复 T4-C（审计类 C：csp-hdmoli / csp-libvio ×3 全败
`夸克网盘 换分享 token 请求失败：builder error`）。与 T4-I（非媒体预检）
是两个独立缺口，本篇只管夸克链。

## Problem

"builder error" 是 reqwest 的 `Error::builder`——URL/header 构造失败，
一个字节都没发出去。真机同账号在 4kzhinan 上同函数成功 ⇒ 不是登录态、不是网络。

根因链（teammate 实证闭环，Lead 复核）：

```text
hdmoli/libvio 剧集 id = {vid}\u{1}{分享页URL}（复合形态）
⇒ provider.rs episode_id_is_direct_play 只认 `|` 与 `http://` 开头
   ⇒ 复合 id 被当裸条目 id ⇒ resolve 走 detail 二跳，把整个复合 id 拼进 detail_url
⇒ hdmoli 路由宽松（污染 URL 实测回 200 正常页）⇒ detail_of 再拼一层 \u{1} ⇒ 双重复合
⇒ split_ep_id 按第一个 \u{1} 切 ⇒ URL 段含 \x01
   ⇒ parse_share_page 在 `/` 截断 ⇒ share_id = `8efcd269e4b7\x01https:`
⇒ share_stoken 把它拼进 Referer ⇒ http crate HeaderValue 拒控制字符（\x00-\x1F/\x7F）
   ⇒ reqwest send 报 Error::builder
4kzhinan 剧集 id 是纯 URL ⇒ 直通 play 无二跳 ⇒ 同函数同 cookie 成功
   （与审计时间线吻合：4kzhinan 11:00 成功、hdmoli 11:23 失败，期间无夸克重登）
```

## Decision（4 文件，三层防御）

```text
① provider.rs：判据补"复合 id 且 \u{1} 载荷是夸克/UC 分享页 ⇒ 直通 play"
   （新 fn share_page_composite；只影响分享页复合形态，其它复合 id 源不动）
② pan_share_play.rs：parse_share_page 拒绝含控制字符的 share_id（防御纵深）
③ pan_drive.rs：新 fn share_referer(spec, share_id)——构造点校验，
   share_id 含 header 非法字节时返回带原值（Debug 转义可见 \u{1}）的明确错误；
   save/token/detail 三处 Referer 全走它 ⇒ 非法 header 从此构造不出来
④ playback.rs（Lead 裁决归属本组）：get_detail 失败补 write_file_log
   （tag=PLAY、scrub_err_msg 脱敏、id 截 24 字符）——修复审计发现的
   csp-appget 静默失败（detail 阶段零留痕，与 1214799 resolve 黑洞同构）
```

## Alternatives considered

- **只在 Referer 拼接处 trim/过滤控制字符**：把脏值洗白继续走，等于拿错数据继续播；
  拒绝 + 带原值报错才留得住事实。否决。
- **只修 split_ep_id 的切分**：那是第二层；第一层误判（detail 二跳）不修，
  双重复合还会从别处再进来。三层都要。否决只修一层。
- **把 \u{1} 判据扩成所有复合 id 直通**：sao_huo/app_get 等其它复合源不是分享页，
  会把真条目误直通。判据钉在"载荷是夸克/UC 分享页"上。否决。

## Consequences

- 门禁（Lead 亲验）：`cargo test --lib --release` ⇒ **1940 passed / 0 failed**
  （基线 1934 + 6 条新门禁；6 条全部"注入回退⇒红、还原⇒绿"实测，期间还抓到并
  修掉两条接线断言的假绿——被测试自身源码字符串骗过 contains，已收紧为只断言
  `#[cfg(test)]` 之前的代码段）。集成门禁 csp_episode_direct_play 4/0、file_log_gate 3/0。
- 真机复验（14:05，DLL E7F01A71）：hdmoli/libvio 的 builder error 消失，
  链路直通 play → 换 token → 夸克 23018（账号下载上限，分享内仅单个 9-10GB 文件）
  ——**C 类缺口清零，剩余失败属 B 类内容现实**（账号配额，非代码）。
- appget 的 detail 失败今后落 `[PLAY] detail 失败 provider=… msg=…` 日志。

## 边界（如实）

- 真机验收时 hdmoli/libvio 仍播不出——但失败原因已从"我们的链路坏"变为
  "夸克账号下载上限 + 分享单文件超大"，属 B 类。类 C 的代码缺口确认清零。
