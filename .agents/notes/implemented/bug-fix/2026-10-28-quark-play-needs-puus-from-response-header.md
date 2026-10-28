# Agent Note: 夸克网盘能播了 —— 403 的真因是响应头里那个 `__puus`

Status: implemented

## Problem

Owner：「我登录了夸克，我用这个源播放 夸克网盘也还是不能播放」。三处独立缺陷，一个压一个：

```text
① `PanDrive::play` 直接 return Err("取流链路尚未接通") —— **一行网络请求都没发**。
   用户登录了、点到了文件，实现根本不去要地址。
② `PanDrive::list` 只认"货架下标"，收到任何条目 id 都忽略
   ⇒ 点进目录还是根目录（实测：根 5 项全目录，点「夸克上传文件」再列，还是那 5 项）
   ⇒ 永远走不到文件 ⇒ 取直链无从谈起。
③ 就算走到 ②，`file/download` 拿到的 download_url 直接下是 **403**
   `RequestDeniedByCallback: require login [auth miss]`。
```

③ 的定位过程（真网，Owner 的登录态）：

```text
试了 6 种组合全 403：Referer ∈ {pan.quark.cn, pan.quark.cn/, drive-pc.quark.cn,
  drive-pc.quark.cn/1/clouddrive/file/download} × UA 有无 × Cookie 有无
读 403 的正文字段：<Code>RequestDeniedByCallback</Code><Message>… require login [auth …]</Message>
抓 `file/download` 响应头：**Set-Cookie: __puus=…**   ← 就是它
把 __puus 并进直链的 Cookie 头 ⇒ GET 直链 **200 OK**（实测）
```

也就是说：登录态（`ctoken/__pus/__kp/__kps/__ktd/__uid` 六键）够调 API，
但**下载 CDN 要的是 `__puus` 这个会话 cookie**，而它不在凭据里 ——
它是 `file/download` 那一刻由服务端下发的。不接这一步，地址永远 403。

## Decision

三处一起补：

```text
① play 真的去要地址：POST /1/clouddrive/file/download?{pr_fr} {"fids":[fid]} + Cookie
② list 支持两段式 id `<idx>:<fid>`（目录条目给这个；文件给裸 fid）
   —— `parse_shelf_and_dir` 纯函数，三种形态都有判据
③ **读完响应头再读 body**：把 `Set-Cookie` 里的 `k=v` 并进 Cookie（同名覆盖），
   再把 url + Cookie/Referer/UA 交给 streamproxy 转发
```

## Alternatives considered

1. **给 reqwest 开 `cookies` 特性、用 CookieStore 自动管**。
   最强理由：不用手写合并逻辑，跨请求自动带上。
   **否决（本轮）** —— 那会给 `Cargo.toml` 加一个特性开关（本批纪律是"零新增依赖"），
   而这里只需要**一次**合并（下载地址是短时的，不需要长期会话）。
   若要支持"边下边续"的多次请求，那时再开特性更合适。
2. **让 streamproxy 侧去拿 `__puus`**（播放器请求代理时再补）。
   最强理由：把"取地址"和"带凭据"彻底分开，代理层统一处理。
   **否决** —— `__puus` 是**随下载地址一起下发**的，离开那次响应就没有了；
   代理层再发一次 `file/download` 等于每次播放多打一次 API，且要重放 cookie 逻辑。
3. **分享链接也一起接通**（转存到我的网盘 → 再取直链）。
   **否决（本轮，非永久）** —— `play` 只拿到 `fid`，**没有 share_id / fid_token**；
   要做就得改 `list/detail` 的 id 协议（把 share 信息编进去）。
   那是独立的一件事，本轮不猜（宁可如实说"分享链接还不支持"）。

## Consequences

- 收益：**自己网盘里的文件能播了**（真网验证：下载地址 200；DLL 已同步 4 处）。
- 收益：点目录能进目录（此前是个死路，谁也没法验证取流）。
- 代价：`CspPlay.headers` 里的 Cookie 含 `__puus`（会话级、短时有效）——
  它只在该次播放的代理转发里用，不落盘、不进日志（日志只记键名与长度）。
- 代价：一条用例被改写。原 `list_with_non_numeric_tid_is_error` **依赖本机是否登录过网盘**
  （有凭据 ⇒ 走真网络 ⇒ 拿到真列表 ⇒ 用例红）。这类"测试读机器状态"的用例不是判据，
  已换成纯函数 `parse_shelf_and_dir` 的五条断言。
- 已知边界：**分享链接仍然不能播**（缺 share 上下文）；UC 与夸克同族，`play` 一并生效（未单独真验）。

## Relations

- 前情：[./2026-10-28-needs-ext-per-class-annotation.md](./2026-10-28-needs-ext-per-class-annotation.md)
  —— 网盘类此前"默认不暴露"，因为空 ext 必然报错；现在它们真能播了。
- 同族：[./2026-10-28-pan-login-shows-qr-not-blank-panel.md](./2026-10-28-pan-login-shows-qr-not-blank-panel.md)
  —— 那条解决"登录要能扫码"，这条解决"登录之后要能播"。
