# task-5 网盘登录修复：阿里 bizExt / 115 换 cookie / 百度 unicast（2026-10-30）

Status: implemented（门禁绿；真机扫码验证攒到批末统一做）

部分取代（修的是这三篇里"未取证/按通行实现写"的部分，主体协议流程仍有效）：
- [../feature/2026-10-28-aliyun-qr-login-and-token-shape.md](../feature/2026-10-28-aliyun-qr-login-and-token-shape.md) —— 4.1 修正其"bizExt 是 base64 JSON(snake_case)"的假设：键名实为 camelCase、base64 是 URL-safe 字母表。
- [../feature/2026-10-28-pan115-qr-login-four-key-cookie.md](../feature/2026-10-28-pan115-qr-login-four-key-cookie.md) —— 4.2 补上其未取证的换 cookie 表单（account+app=qandroid），四键验收判据不变。
- [../bug-fix/2026-10-29-baidu-qr-is-an-image-and-longpoll.md](../bug-fix/2026-10-29-baidu-qr-is-an-image-and-longpoll.md) —— 4.3 推翻其"channel_id 与 v 都填 sign"的猜测：unicast 无 v 参数、BDUSS 在换态响应头。

执行者：rust-login（task-5）。同仓并行约束：只碰 pan 登录模块（aliyun/115/baidu），
夸克与 tvbox 聚合模块（rust-quark）未触碰；4.4 天翼维持现状未动。

## 一、取证出处（全部只读，脚本与日志在 .probe/）

| # | 证据 | 出处 |
|---|---|---|
| E1 | dex 定向扫描（bizExt/AES/unicast/login-qrcode 命中与引用定位） | `.probe/pan-login-t5-forensics.log`（脚本 pan-login-t5-forensics.py，指令长度表用 evidence-remaining §7.1 修正版，避开 r3c-dexstrings.py 已知漏报） |
| E2 | 寄存器追踪反汇编（百度 merge.b.j o/t、Qr115 全类、请求/JSON 助手、FM 变体、全 APK bizExt 扫描） | `.probe/pan-login-t5-forensics2.log` |
| E3 | Gson POJO 字段绑定（@SerializedName 逐字） | `.probe/pan-login-t5-forensics5.log` |
| E4 | merge.d.d e()/f() 与 handleAli 精确追踪 | `.probe/pan-login-t5-forensics4.log` |
| E5 | 现场真读数（图1/图2 的报错） | 本计划文档 4.1/4.2 现状 |

## 二、4.1 阿里 bizExt（图1：invalid utf-8 index 200）

**结论：没有 AES、没有密钥可取证 —— bizExt 是 base64 直接可解的 JSON；坏在我们把 URL-safe 字母表的 `-`/`_` 当非法字符跳过，位流错位后产出垃圾字节。**

dex 证据链（E1+E3+E4，逐字）：
1. 全 APK（base.apk 三个 dex + spider dex）**零** AES 调用归属阿里登录链路（AES/ 常量全在无关 spider 类：App99/Czsapp/FanKe/…，E1 §①b）。
2. spider dex 字符串池仅 1 条 'bizExt'（str#14173）且**无 const-string 引用** ⇒ 它是 Gson POJO 的注解绑定（E3）：`merge.d.d.g` 字段 `@SerializedName("bizExt")`。
3. 参考实现 `merge.d.d.e()`（E4）：`Base64.decode(bizExt) → String → Gson(merge.d.a)` → `pds_login_result.refreshToken`。merge.d.a 的 @SerializedName 全表：a='pds_login_result'、i='accessToken'、u='refreshToken'、n='expiresIn'（E3）。
4. 之后 `G.u(refreshToken, 'ali')` → `merge.b.i.t`：POST `auth.aliyundrive.com/v2/account/token`，体 `{grant_type:"refresh_token", refresh_token}`（E2 §C6）。

代码修正（pan_login.rs）：
- `b64_decode`：`-`→62、`_`→63（与 `+`/`/` 同值）。旧实现跳过它们 ⇒ 位错位 ⇒ "invalid utf-8 index 200"（中段必炸，与现场读数吻合）。
- `aliyun_token_from_body`：键名 camelCase（dex 逐字）与 snake_case（社区公开实现通行形）**双认**，camel 优先；都缺才报错，报错点名缺什么。
- `aliyun_poll` 表单对齐 dex（E2 §C4 merge.d.d.d()）：t/ck/appName=aliyun_drive/appEntrance=web/isMobile=false/lang=zh_CN/returnUrl=/fromSite=52/bizParams=/navlanguage=zh-CN/navPlatform=MacIntel（URL 的 `_bx-v=2.2.3` 保留，dex 端点串自带）。

**未竟事项（如实报）**：真实密文向量（真抓 CONFIRMED 的 qr 响应）需要真机扫码，批末随真机验证一并抓取，落 `.probe/` 脱敏后补进门禁。当前门禁用"测试内自算 URL-safe 向量 + 篡改证红"顶住（见验证结果）。

Alternatives（不采纳的原因）：
- 按 AES 解密实现（网上传言 bizExt 加密）：dex 全链路无 Cipher，无密钥常量，做了就是猜 —— 违反纪律。
- 只支持 snake_case（保持旧状）：dex 逐字是 camelCase，CONFIRMED 后必落在"缺键报错"，等于没修。
- 引入 base64 crate：零新增依赖纪律，20 行自带解码已有单测覆盖。

## 三、4.2 115 换 cookie（图2：40100000 参数错误）

**结论：换 cookie 的 POST 表单发错了字段 —— dex 逐字是 `account=<uid>&app=qandroid`，我们只发了 `uid`。**

dex 证据（E1 §②b `com.github.catvod.spider.Qr115.login`，154 insns 逐字）：
```text
form.put("account", Qr115$Token.uid)      ← 键名 account，值是 uid
form.put("app", "qandroid")               ← 与 URL /app/1.0/qandroid/1.0/ 同值
POST https://passportapi.115.com/app/1.0/qandroid/1.0/login/qrcode/
头：Qr115.head() = 只有 User-Agent: Mozilla/5.0 115disk/30.1.0
响应：data.cookie{UID,CID,SEID,KID} → 拼成 "UID=…; CID=…"（四键缺一不可）
```
扫码 status=2 已通（取码/轮询/签名都对），错在确认后的这一步，与现场读数吻合。

代码修正（pan_login.rs）：
- 新增纯函数 `pan115_login_form(uid)` → `[("account", uid), ("app", "qandroid")]`，调用点改用它。
- 错误文案 `\uXXXX` 解码：新增 `unescape_json_u`（只解 \uXXXX，坏转义原样回退）与
  `pan115_server_message`（取 message/data.message 并解码）；换 cookie 失败时文案附「（服务端：参数错误）」。
- `pan115_cookie_from_body` 四键判据不变（本来就是对的）。

Alternatives：
- 也把 `app` 值换成 URL 路径里的动态段：dex 是硬编码 "qandroid" 字符串，不引入推断。
- 对所有报错统一做 \u 解码：只服务用户可见文案，JSON 解析仍走 serde_json，不做全局字符串变换（避免误伤 base64 等内容）。

## 四、4.3 百度 unicast（一直重新获取二维码）

**结论：两处旧猜测被 dex 推翻 —— ① unicast 多带了 `&v={sign}`（参考实现没有）；② BDUSS 找错了地方：它不在 unicast 的 Set-Cookie，而在换登录态（qrbdusslogin）那一步的 Set-Cookie；确认态的载体是响应体 `channel_v` JSON。**

dex 证据（E2 §A merge.b.j.t 354 insns 寄存器追踪 + E3）：
```text
③ 轮询 GET /channel/unicast?channel_id=<sign>          ← 只有 channel_id，没有 &v
   body: errno + channel_v（JSON 串）→ {status: 0, v: "..."}
④ 换态 GET /v3/login/main/qrbdusslogin?v=<System.currentTimeMillis()>&bduss=<channel_v.v>
   → 这一步的 Set-Cookie 里才有 BDUSS（contains("BDUSS=") 逐条收集拼 Cookie）
⑤ GET pan.baidu.com/disk/main?from=homeFlow（Cookie 头带上）→ STOKEN
取图 URL = "https://" + imgurl + "&logPage=traceId%3Apc_loginv5_1742970205%2ClogPage%3Aloginv5"
```
旧实现从 unicast 的 Set-Cookie 找 BDUSS ⇒ 永远找不到 ⇒ 永远 Pending ⇒ UI 一直重取码（现场现象）。

代码修正（pan_login.rs）：
- `baidu_unicast_url`：删 `&v=`。
- 新增 `baidu_channel_v_of(body)`：解析 `channel_v` 串 → `status`/`v`；status==0 且 v 非空才算确认，否则 Pending。
- 换态：`baidu_qrbduss_url(当前毫秒, channel_v.v)`（新增 `baidu_now_millis`）。
- BDUSS 判据移到换登录态响应的 Set-Cookie；unicast/换态/disk/main 三段 cookie 合并逻辑保留。
- 取图 URL 追加 dex 逐字的 logPage 串（纯函数 `baidu_img_fetch_url`；QrSession.url 展示仍用原 imgurl）。
- 长轮询 3s 超时 ⇒ Pending 的既有读数与纪律不动。

Alternatives：
- 保留 `&v=` 兼容两种服务端：多一个未取证参数就是给 401/另一套字段留口子，dex 没有就删。
- v 参数也用 channel_v 里的其它值：dex 逐字是 currentTimeMillis，照抄。

## 五、验证结果

```text
· 门禁（新建独立文件 src/pan_login/pan_login_t5_gate.rs，14 条，cargo test --lib pan_login_t5_gate --release）
  14 passed / 0 failed。证红清单：
  - 4.1：篡改一位 bizExt ⇒ Err；camel/snake 都缺 ⇒ Err；"URL-safe 映射承重"用新旧解码路径
    结果差断言（映射被回退 ⇒ 红）；camelCase 与 snake_case 两套键各一条正向用例。
  - 4.2：四键缺一（缺 KID）⇒ Err；\u53c2\u6570\u9519\u8bef ⇒ "参数错误"；坏转义/尾随反斜杠原样回退；
    form 逐字断言（account + app=qandroid）。
  - 4.3：unicast URL 出现 &v= ⇒ 红；channel_v 坏 JSON/缺 v ⇒ None；img fetch logPage 串逐字；
    qrbdusslogin v=毫秒 逐字。
· 回归：cargo test --lib pan_login --release ⇒ 91 passed / 0 failed / 2 ignored（live 真网）。
  两个旧 in-file 测试随 dex 取证修正（aliyun_token_from_biz_ext 的报错断言、
  baidu_urls_match_the_documented_flow 的 unicast URL）—— 旧断言钉的是被推翻的旧协议。
· 未竟（批末）：真实 bizExt 密文向量（真机扫码，走 lead 协调 driver-ops）、115 真网复现
  服务端响应、百度真机扫码 —— 攒批统一做。
```

## 六、遗留给 lead 的协调项

1. 批末真机验证时：真抓一次阿里 CONFIRMED 的 query.do 响应（脱敏 bizExt 向量落 .probe/），
   门禁已有"真向量进、真 token 出"的扩展位（pan_login_t5_gate 文件头注明）。
2. 115 真网用例目标：换 cookie 响应含 cookie 段（UID/CID/SEID/KID 四键）；如仍 401，读
   `pan115_server_message` 解码后的服务端文案再定位（本轮已把 40100000 的根因修在表单字段上）。
3. 4.4 天翼按纪律未动。

## 七、真网读数（2026-10-30 06:34–06:37，Owner 已授权自行补验；证据 .probe/pan-login-t5-livenet-2026-10-30.log，一次性探针脚本已删）

**115（三态 A/B 对照）**
```text
① GET token/ → HTTP 200 {state:1, code:0, uid:40位, time, sign:32位}（脱敏后照录）
② GET get/status/?uid&time&sign → 长轮询 12s 0 字节超时（未扫的正常中途态；jar 无新增 cookie）
③ POST login/qrcode/ 同一新鲜 uid，两套表单：
   旧表单 uid-only            → {"code":40100000, "message":"参数错误！"}   ← 精确复现现场故障
   新表单 account+app=qandroid → {"code":40101017, "message":"老乡验证失败！"}
④ 40101017 语义定位：真实未扫 uid / 伪造 uid / 全零 uid 三态同码 ⇒ 防枚举的统一业务错
   （=无已确认的扫码会话），不是参数错。带 acw_tc/USERSESSIONID cookie 与否不影响。
结论：参数层已修复（40100000 消失），推进到"需要真实扫码确认"为止；扫码后是否直达
UID/CID/SEID/KID 四键，批末真机扫码验证。
```

**百度**
```text
① GET getqrcode → HTTP 200 {errno:0, sign:32位, imgurl, prompt}（与 2026-10-29 现场读数一致）
② GET unicast?channel_id=<sign>（dex 修正形态）→ 长轮询 30s 后 {"errno":1}（无事件，参数层接受）
   A/B：+&v=<sign>（旧形态）→ 同样 30s/errno:1 ⇒ 两种在未扫态都"被接受"，
   参数差异要到确认态才显形（channel_v 只在有事件时下发）——dex 逐字形态为准。
③ 换态（qrbdusslogin）需 BDUSS=channel_v.v，必须有真扫码 ⇒ 停在如实记录。
```

**阿里**
```text
① GET generate.do → HTTP 200 content.data{ck, codeContent, t, processFinished, resultCode}
   （bizExt 在 PENDING 态不存在 ✓ 与 dex 只在 CONFIRMED 读 bizExt 一致）
② POST query.do：新表单 11 字段 与 旧表单 ck/t/_bx-v 都返回
   {content.data.qrCodeStatus:"NEW", resultCode:100, success:true} ⇒ 参数层两种都接受，
   表单差异不改变 PENDING 态行为；bizExt 真实向量只能来自 CONFIRMED 响应（等 driver-ops 转发）。
```

真网侧总体：115/百度/阿里三家的取码+轮询+换态参数全部被服务端接受，全部卡点收敛到
"需要手机扫码确认"这一件事上（批末统一真机验证）。凭据/令牌零落盘（日志全部脱敏）。
