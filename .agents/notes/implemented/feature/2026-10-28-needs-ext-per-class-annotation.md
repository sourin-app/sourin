# Agent Note: `needs_ext()` 逐类标注 —— 源不该以"必然报错"的样子出现在列表里

Status: implemented

## Problem

上一轮我做了「内置 csp 源自动暴露」：每个 `register_site!` 的类都变成一条用户可见的源。
Owner 试完给的反馈是**两条**，这条是第二条：

```text
> 要逐类标注，像这种应该内部支持
```

现象：源列表里 57 条，其中一批（`csp-xbpq` + 8 个网盘族）**点进去必然是「需要配置」的 Err**：

```text
· XBPQ     —— 配置驱动抓取器，ext 就是那份配置 URL/JSON，类里没有站点
· Pan115 / Pan123 / PanAli / PanTianyi / PanXunlei / PanGuangya / PanShare / PanUC
           —— 网盘族：未登录必然 Err（真网读数：115 errno=99、123 code=20101、
              阿里 401 AccessTokenInvalid、天翼 InvalidSessionKey、
              迅雷 device_id/captcha_token 缺失、光鸭 401 code=117）
```

原版里这些类**只在配置带 ext 时出现**。我上一轮"全暴露 + 靠 Err 说明缺什么"的做法，
在诚实性上没错，但在产品上是**一堆点不开的入口**。

## Decision

给 `CspSite` 加一个**带默认值**的方法：

```rust
fn needs_ext(&self) -> bool { false }   // 默认：不用 ext 也能用
```

只对有证据的 9 个类覆盖成 `true`（XBPQ + 8 个网盘类，覆盖体里逐条写明真网读数依据）。
`state.rs` 的自动暴露里加一句：

```rust
if crate::csp::class_needs_ext(class) { continue; }
```

`class_needs_ext(class)` 是个自由函数：按类名从 inventory 造一个实例再问一次
—— **唯一真相在各类自己的覆盖里**，不在 state.rs 维护第二份名单。

## Alternatives considered

1. **在 `state.rs` 里维护一份"需要 ext 的类名清单"**。
   最强理由：不用碰 trait，不改 9 个类，一处可改。
   **否决** —— 名单会和类实现漂移（新加的类忘了登记 ⇒ 又变成"点进去报错"），
   而且漂移时**没有报错**。ti 放到类自己身上，谁改这个类谁看得见。
2. **全暴露，但给"需要配置"的源在名字上加后缀（如「XX（需配置）」）**。
   最强理由：用户仍能看到全部能力，且不会被 Err 打脸。
   **否决** —— 名字后缀会污染 id/排序/收藏的语义（本项目里名字是用户可见标识），
   而且原版根本不显示这些源。**看得见但用不了** 与 **看不见**，原版选后者。
3. **按"文件里有没有硬编码 host"自动判定**（我写了个脚本跑：24 个类命中）。
   最强理由：零人工、覆盖全。
   **否决** —— 实测误报严重：`Bili` 被判定"没有硬编码 host"（它的 host 在其它常量里拼出来的），
   而它是绝对能用的。判据宁可窄（只标 9 个有证据的），也不能错标一个是"能用却不显示"——
   那正好是 Owner 最初抱怨的另一种形态。

## Consequences

- 收益：源列表 57 → **49**（实机：`listProviders 50 个 / 已启用 49 个`），
  少了 8 条"点进去必然报错"的入口。
- 收益：标注写在各文件里、带真网读数依据；`class_needs_ext` 查不到类名时会 warn
  并按 false 处理（避免"名字打错 ⇒ 源永远不出现"的静默失败）。
- 代价：需要 ext 的类**默认看不见**了 —— 用户必须导入带 ext 的站点才会出现。
  这与原版一致，但"能力被发现"要靠配置，靠不了列表。
- 代价：将来新增"需要 ext"的类，作者必须记得覆盖 `needs_ext()`。
  门禁 `zz_parity_builtin_csp_sources` 里那条 `leaked` 断言能在**它被自动暴露**时报红，
  但报不出"该标没标"（那需要语义判断）。如实记在这里。
- 验证：注入（把 state.rs 的 skip 改成 `false &&`）⇒ 真红，逐条点名 8 个类
  （`.probe/needs-ext-inject.log`）；还原 md5 一致、复跑 4 绿。

## Relations

- 前情：[./2026-10-28-builtin-csp-sources-auto-exposed.md](./2026-10-28-builtin-csp-sources-auto-exposed.md)
  —— 那篇决定"全暴露"；本篇是对它的**收窄**（Owner 试完后给的边界）。
- 同族：[./2026-10-28-aggregate-only-saw-hidden-children.md](./2026-10-28-aggregate-only-saw-hidden-children.md)
  —— 那篇让源"能被搜到"；本篇让"用不了的源别摆出来"。
