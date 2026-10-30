# Agent Note: 网盘出码真网冒烟 —— 走生产代码路径验证阿里/115/百度能出二维码

Status: implemented

Independent: 与 `2026-10-30-pan-login-t5-aliyun-bizext-115-cookie-baidu-unicast.md`（协议层修复与 dex 取证）
互补而非重复：那条证明"参数按 dex 改对了"，本条证明"改完的代码在 App 的真实调用路径上真的能出码"。

## Problem

任务 4.1/4.2/4.3 的真网证据此前来自**手工构造请求**的探针（`.probe/pan-login-t5-livenet-2026-10-30.log`）。
手工请求只证明"服务端接受这些参数"，**没有证明 App 自己走的代码路径能出码** —— 中间还隔着
`command_qr_start` → `qr_login_start` 的参数组装、`PanKind` 映射、SVG 生成等环节。
Owner 的验收口径要求"真机/真网判据"，而 UI 上的扫码页要靠真实点击才能打开（当天不可用）。

## Decision

新建 `rust/sourin_core/tests/live_qr_login_smoke.rs`，**直接调 `pan_login::command_qr_start`**
（UI 按"扫码登录"时走的同一个函数），对三家各自独立断言三条判据：

```text
① key 非空            —— 会话确实建立
② url 是 http(s) 链接 —— 二维码内容可扫
③ svg 非空            —— UI 能画出码（为空只 WARN 不判红：UI 会退化成显示 URL）
```

三家独立断言、互不牵连：任何一家失败不许把其它家判红，也不许因为"这家今天不通"整体跳过。
`#[ignore]` 标记为真网测试，默认门禁不联网；显式跑法：

```powershell
cargo test --test live_qr_login_smoke --release -- --ignored --nocapture --test-threads=1
```

## Alternatives considered

- **继续用手工 curl 探针**：能证明参数形状，但绕过了 `command_qr_start` 的参数组装与 PanKind 映射，
  属于"测了服务端、没测我们的代码"。否决。
- **打开 App 设置页点扫码按钮截图**：最接近真机，但需要真实鼠标点击（Flutter 不响应 PostMessage
  合成点击，实测两次截图字节完全相同），当天 Owner 持续占用机器。作为后续补强保留。
- **用 integration_test 驱动 App**：本仓无 `integration_test` 基础设施，引入等于新增依赖 + 构建链路，
  且运行中实例占 8642 端口会冲突。否决（超出本批范围）。

## Consequences

实测读数（2026-10-30 12:12，真网，`--ignored --test-threads=1`）：

```text
[aliyun] OK key_len=32 url_host=passport.aliyundrive.com svg_len=19106 hint=用阿里云盘 App 扫这个码
[baidu]  OK key_len=32 url_host=passport.baidu.com      svg_len=2591  hint=用百度网盘 App 扫这个码（扫码后需在手机上确认）
[pan115] OK key_len=40 url_host=115.com                 svg_len=13062 hint=用 115 App 扫这个码
test result: ok. 3 passed; 0 failed
```

⇒ **三家出码链路在生产代码路径上全部打通**，任务 4.1/4.2/4.3 的"能不能出码"这一环有了真网证据。

过程中修掉一个自己写下的错：115 的 kind code 逐字是 `115`，我第一次写成 `pan115` ⇒
`kind_from_code` 如实报"认不出网盘标识 'pan115'（可用值：… / 115）"。这个报错本身也是好消息
——说明 `kind_from_code` 不做静默兜底（不会把未知值默认成某个盘）。

边界（如实记录，不注水）：

- **出码 ≠ 登录成功**。确认态（阿里 CONFIRMED 的 bizExt 真实向量、115 换 cookie 拿到 cookie 段、
  百度 channel_v 确认）必须**用户用手机真扫码**，本测试不覆盖，也无法在无人工介入下覆盖。
- 三家服务端都可能对该出口 IP 限流；失败时断言消息带原始错误类别，便于区分"参数被拒"与"网络/限流"。
- 真网测试不进门禁默认集（`#[ignore]`），需显式执行 —— 这是有意设计：门禁必须离线可复现。
