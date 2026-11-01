# Agent Note: 迅雷/百度分享页取直链 —— 取证粒度扩到取流 + 验证型分批接入

Status: implemented

与 [2026-10-31-tvbox-source-update-time.md](../feature/2026-10-31-tvbox-source-update-time.md)
同批次的网盘线：T1a 只接了夸克/UC（转存→直链），T1b 只做了五家预检
（pan_check）；Owner 实机《驯龙高手》迅雷/百度线报「本机没有接入」——
缺的是**取流**（分享→下载直链）那一段。本批把它接上（迅雷全链、百度到已证边界）。

## Problem

取流协议不在参考 APK 里（在运行时下载的插件里，T2 已如实声明）；
APK 内的取流签名（hp0.z）被字符串加密。T2 的预检取证停在"能不能播"，
取流（端点/参数/签名/头部）颗粒度缺失。

## Decision

**方法换轨：从 dex 静态取证改为真网 web 客户端 JS 取证**——
拉 pan.xunlei.com / pan.baidu.com 的 SPA chunk（webpack 清单全量枚举后
定向挖掘），产物 `.probe/xl-forensics/`（18 个 JS）与 `.probe/baidu-forensics/`。

**迅雷：全链实现**（`csp/pan_xunlei_play.rs`，协议逐字在案）：

```text
GET  drive/v1/share?share_id=&pass_code=…     清单（share_status_text="OK" 判据）
POST drive/v1/share/restore                    转存（body 逐字：parent_id:""/
     pass_code_token/ancestor_ids:[]/file_ids/specify_parent_id:true）
GET  drive/v1/tasks/{id}                       轮询（预算封顶 10 次×1s，超时如实报）
GET  drive/v1/files/{id}?usage=CONSUME         文件详情 ⇒ web_content_link = 直链
DELETE drive/v1/files/{id}?space=              清理临时转存
鉴权 Authorization: Bearer <access_token> + x-device-id/x-client-id
```

登录态复用仓内设备码链（pan_login_device → pan_auth 钥匙串，零硬编码）。
转存纪律照搬夸克族：播完不删、**下次解析开头**清上一次；降级重试认
"限制类"错误字样（≤3 个候选）。**captcha_sign 不用带**（如实考证）：
web 端签名由 per-host signKey + 远端动态下发的混淆代码计算——静态不可逆
（这正是参考 APK 把它加密的原因）；但带 Bearer 的取流请求 web 客户端都不挂
withCaptcha ⇒ 本链路不依赖那个签名。

**百度：已证跳接线 + 诚实边界**（`csp/pan_baidu_play.rs`）：

```text
verify ：POST /share/verify → errno=0 → randsk（= BDCLND cookie = sekey）
列表   ：/share/list（hp0 shorturl 形态 + web 的 sekey 形态逐字）
dlink  ：/api/(download|sharedownload) 端点族在案（boot.js 逐字 regex），
         但请求参数形状在登录后懒加载 chunk 里 ⇒ **未取证，不实现**。
```

活链接取证实测受挫（如实）：钥匙串百度凭据**服务端已失效**——带 BDUSS
访问分享页渲染出的是登录页（探针归档 `.probe/baidu-forensics/archive/`）。
⇒ dlink 跳停在这里，用户侧动作=重新登录百度；接线后用活链接补一次取证即可闭环。

**接线点**：provider.rs 的 resolve 出口钩子加一支——`pan.rs` 的 9 族判据
（parse_share）认出迅雷/百度 ⇒ 交各自 resolve；pan_share_play.rs 的夸克/UC
判据与它的 5 条门禁一字未动。

## Alternatives considered

### A. 等参考 APK 的运行时插件 jar 下载下来再取证

**最强理由**：插件里就是逐字答案，省去协议考古。

**否掉的原因**：插件的下载地址/协议本身又是一条未取证链路；且 Owner 的
问题是"现在不能播"——web 客户端 JS 是公开可达的同源协议，取证当天闭环。

### B. 迅雷走免转存路（share/play_url）

**最强理由**：不占用户网盘空间、少一次转存。

**否掉的原因**：`share/play_url` 端点逐字在案但**参数在懒加载播放器
chunk 里未逐字**；转存路的每一跳都逐字在案。取证不全的路不先走。

### C. 百度 dlink 按公开工具的常识补参数（sign=md5(sign3+sign1) 等）

**最强理由**：BPCS-Go 等开源实现都这么发，大概率能通。

**否掉的原因**：违反本仓"逐字取证不猜参数"纪律；猜错参数的失败归因
会把"我们猜错了"伪装成"百度限速"。宁可如实停。

## Consequences

**收益**

- 迅雷分享线（《驯龙高手》那类）真机登录后即可播；转存残留由"下次播放
  先清上一次"的节律兜住。
- 百度线从「尚未接入」变成「登录态活性检查 + 提取码校验 + 列表」全通，
  停在一个**指向明确的**诚实错误上（重新登录 → 补取证 → 闭环）。

**代价与边界**

- 迅雷**建目录端点未逐字取证** ⇒ 转存落根目录（parent_id=""），残存文件
  靠下次播放清理/手动删——sourin-temp 同款纪律待二期取证建目录后并进。
- 迅雷直链的 **UA 约束未取证** ⇒ 带桌面 Chrome UA 交给真机验收暴露；
  tasks/清单响应的次要字段形状按防御性解析（认不出 ⇒ 带原文的清晰错误）。
- 百度 dlink 仍是"未取证"状态——在取得有效登录态+活链接前，百度线不可播
  （与此前一致，但错误文案从"没接入"变成"差哪一跳"）。
- provider.rs 的混合线路场景（一条 play 返回多家分享）：任一家失败会让
  该次 resolve 整体 Err——与夸克/UC 既有语义一致，未单独设计部分成功。

## Testing

```text
csp::pan_xunlei_play  8 条：全链回放（真 HTTP 假服务，restore body 逐字断言 +
  Bearer/x-device-id 服务端记账断言 + 第二次解析触发 DELETE）、NEED_LOGIN
  （无凭据/坏形状凭据）、share_status_text!=OK 如实报、轮询封顶（次数正好
  上限、时长有界）、对不上名不盲删、纯函数（清单防御解析/token 解析/降级词）
csp::pan_baidu_play   5 条：NEED_LOGIN、登录页渲染=凭据失效（探针实锤形态）、
  verify→list 全跳 + sekey 形态逐字、verify 拒绝带 errno、锁码无码如实报
provider 出口钩子分支 + pan_share_play 既有 5 条回归全绿
全量：cargo test --lib --release → 2012 passed / 0 failed / 93 ignored
注入证红：摘 get_json 的 bearer_auth ⇒ 全链门禁红在"缺 Bearer"（已还原，
  diff/源码双向 grep 零残留）
```
