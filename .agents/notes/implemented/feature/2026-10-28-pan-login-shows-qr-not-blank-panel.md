# Agent Note: 网盘源的「登录」必须是二维码弹窗 —— 空面板的根因与分流

Status: implemented

## Problem

Owner 的第三点是两句话：

```text
> 要逐类标注，像这种应该内部支持，
> 然后 tvbox 聚合源播放的时候，如果是需要网盘登录 应该提示
> 然后点击登录出现二维码进行登录，而不是 点击登录 出现空白
```

前半句（逐类标注）已在 `2026-10-28-needs-ext-per-class-annotation.md` 落地。
这里解决后半句：**点「登录」出现了空白**。

根因（读代码确认，不是猜）：

```text
播放页的「登录」按钮 → showProviderLoginDialog(providerId, providerName)
  → Dialog 里画 ProviderLoginPanel(providerId)
  → 那个面板画的是**源自己声明的登录字段**（账号 / 密码 / cookie / token）
而网盘类 csp 源（csp-pan115 等）**一个登录字段都没有** —— 它们的凭据是扫码拿的
⇒ 面板里没有任何东西 ⇒ 用户看到一片空白。
```

也就是说：不是"登录坏了"，是**这个面板的形状与这类源不匹配**，而分流判据只看"有没有登录字段"没看"这类源该怎么登录"。

## Decision

三层改动，全部复用已经跑通的扫码链路（`pan_settings_page` 的 ② 区）：

```text
① 新弹窗 lib/ui/widgets/pan_qr_login_dialog.dart
   pan_qr_login_start(kind) → QrView 出二维码 → 每 2 秒 pan_qr_login_poll(kind,key)
   → status=confirmed ⇒ pop(true)（调用方据此重试播放）
   文案：标题带盘种名（"扫码登录 115 网盘"）+ 一句"这个源要用你的 115 网盘账号才能取到播放地址"

② 分流：showProviderLoginDialog 里，先按**源 id** 判断是不是网盘源
   （panKindOfProvider：csp-pan115 → 115 / csp-pan-ali → aliyun / …），
   是就弹扫码窗，否则走原来的 ProviderLoginPanel。
   分流**必须在画面板之前**（否则空面板已经画出来了）。

③ 后端配合：ProviderError 加 `login_kind`（serde 默认 + skip_if_none ⇒
   不用登录的错误序列化结果逐字不变）；csp 实现层的 `NEED_LOGIN:<kind>|<人话>`
   前缀在 classify_err 里翻译成 `Unauthorized` + login_kind；
   另外"网盘类 + 要登录的字眼"（请重新登录 / 未登录 / InvalidSessionKey /
   AccessTokenInvalid / errno=99 / code=20101 …）也映射成 Unauthorized，
   **只对 `login_kind_of_class` 命中的网盘类生效** —— 普通影视源出现同样字眼不许被误判。
```

## Alternatives considered

1. **让每个网盘类自己返回结构化的 `ProviderError`**（而不是字符串 + 前缀约定）。
   最强理由：类型安全，不依赖文案。
   **否决（本轮）** —— `CspSite` 的 trait 签名是 `Result<_, String>`（几十个类都按它写），
   改成 `ProviderError` 要动全部实现与门禁。而"分类"本来就已经有一个集中点
   （`classify_err`），在那里判定只改一处、且可测。
   将来若 trait 升版，这段判定可以自然下沉到各类里。
2. **保留 ProviderLoginPanel，给网盘源补"登录字段"（比如手输 cookie）**。
   最强理由：不动 UI 分流，一套面板管所有源。
   **否决** —— 网盘凭据是"扫码 → token → cookie"三步，手输 cookie 既难拿又易过期；
   而且 Owner 明确要"出现二维码"。
3. **在播放页直接内联二维码（不做弹窗）**。
   最强理由：少一层交互。
   **否决** —— 播放页已经有"错误横幅 + 登录按钮"的结构（既有门禁钉着），
   内联会把那个结构改乱；弹窗还能复用 `pan_settings_page` 里同一套 start/poll 语义。
4. **按错误文案里的盘名（"115"、"阿里云盘"）反推盘种**。
   **否决** —— 文案是我们自己写的、将来会改；按**源 id** 映射是稳定判据。

## Consequences

- 收益：网盘源点「登录」不再是空白 —— 直接出该盘的二维码，扫完自动重试播放
  （`_loginAndRetry` 本来就在成功时 `_load()`，这里只是让它拿到 true）。
- 收益：后端第一次能告诉 UI"**是哪个盘**要登录"（`login_kind`），
  以后要做"播放页直接内嵌二维码"或"批量引导登录"都不用再猜。
- 代价：`login_kind` 是 `ProviderError` 的新字段 —— 所有构造点走 `ProviderError::new`
  的自动补 `None`，但**手工 `ProviderError { .. }` 的地方会编译失败**（好事：编译器逼着处理）。
- 代价：`panKindOfProvider` 是一张手写映射表。新增网盘类时忘了加 ⇒ 该源登录仍是空白。
  门禁 `zz_pan_login_qr_dialog_test` ① 守现有 9 条映射与非网盘源的反向判据，
  但报不出"新类忘了加"。如实记在这里。
- 验证：注入删掉 `csp-pan115` 那条映射 ⇒ ① 真红（`.probe/pan-qr-inject.log`），
  还原 md5 一致、复跑 3 绿；Rust 侧注入式断言（非网盘类不许被误判）在 provider 单测里。

## Relations

- 前情：[./2026-10-28-needs-ext-per-class-annotation.md](./2026-10-28-needs-ext-per-class-annotation.md)
  —— 同一条 Owner 反馈的前半句（哪些源不该摆出来）。
- 相关：[../bug-fix/2026-10-28-windows-ime-composition-read-by-runner.md](../bug-fix/2026-10-28-windows-ime-composition-read-by-runner.md)
  —— 同一轮的另一个"看起来能用其实一片空白"的缺陷。
