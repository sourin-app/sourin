# Agent Note: 网盘分享直链原生转换（夸克/UC 先行）—— 三处 play() 放行接原生钩子

Status: implemented

Independent: 兑现 [2026-10-31-aliyun-bizext-lossy-and-body-dump.md](../bug-fix/2026-10-31-aliyun-bizext-lossy-and-body-dump.md)
同批的凭据地基（7 盘钥匙串在库）与 [crank 线路诊断](../../../../.probe/crank-20261031-line-diagnosis.md)
的 A 类归因（68 条 FAIL 中 35 条/51% 是"分享页需原生转换"）。

## Problem

10 个 panwebshare 类 csp 源（wogg/panwebshare×6/hjzhencai/gui-gui 等）的 play()
在分享页 URL 上直接 Err「播放需要登录账号 + 本机 5266 转发服务」——但本仓
provider.rs resolve 出口**早已有**原生转换钩子（PanDrive::resolve_share_play：
转存 sourin-temp → 直链+__puus，含 23018 降级，4kzhinan 等源真机走通）。
缺口只是：三处 play() 在到达钩子之前就 Err 了，分享 URL 根本没交出去。

## Decision

```text
pan_share_play.rs 新增纯函数 share_page_play(url, ua) -> Option<CspPlay>：
  族判别复用 parse_share_page（夸克/UC 两族既有入口判据：精确 host + /s/<id>
  + 控制字符拒认——无新域名清单）；认出 ⇒ CspPlay{url, 站点UA, label="网盘
  分享页（原生转直链）"}；其它族（百度/迅雷/115/阿里/139/光鸭）⇒ None
  ⇒ 三处 play() 维持如实 Err（文案改指 T1b，不再提过时的 5266）。
wogg.rs / pan_web_share.rs / hjzhen_cai.rs 三处 play() 在直链分支后接入：
  if let Some(p) = share_page_play(url, UA) ⇒ 返回 p。
```

未登录路径闭环（复核确认）：resolve_share_play → NEED_LOGIN:<盘种>|<人话> →
classify_err → Unauthorized + login_kind → （Dart 消费端由 nodur 组同批接通）。

## Alternatives considered

- **在 csp 层内嵌一份转存逻辑**：pan_drive 已有且带降级链，再写一份=两处真相。否决。
- **把百度/迅雷/115/阿里也一并放行**：T2 取证只有预检协议（hp0），取流在运行时
  插件里未取证；放行就是"假装能播"。维持如实 Err 等 T1b。否决。
- **按域名清单判别**：本仓反复批评的形态。复用 parse_share_page 的族判据。否决。

## Consequences

- 门禁：7 条（3×runtime 行为测试真 URL + 3×接线断言 include_str! 切生产段 +
  1×族判别单测），注入 7/7 红、还原 7/7 绿。
- 夹具：wogg 114504 / hjzhencai 754 详情页真抓（UC?public=1、夸克 /s/<hex>、
  百度?pwd=），P3 备案：具体分享 id 未持久化（判据=站点+形态）。
- 互检：fix-t73-search-gate 七项复核通过（族判别无越界/旧路径不回归/夹具真实/
  NEED_LOGIN 闭环/门禁有牙/越界/LF），测试读数被 MuMu 模拟器 CPU 饿死阻塞，
  批末窗口补跑为最终门禁。
- 预期真机效果：那 10 源的夸克/UC 线路进入"转存→直链"真链路（23018 账号上限
  仍会拦超大文件，但那是 B 类内容现实）；百度/迅雷/115/阿里线路等 T1b。

## 边界（如实）

- gui_gui 冷缓存（详情依赖进程内 last_search）未动——需 data_dir 管道，
  并入 T1b（lead 裁决）。
- yidong_4k（移动 139）维持如实 Err（T2 报告：139 的 hcy-cool-flag 头已取证
  但取流协议在运行时插件里）。
