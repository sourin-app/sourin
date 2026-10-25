# Agent Note: 加密协议的实现门槛是"能解开真实响应"，不是"能编译"

Status: implemented

## Problem

`csp_App99` 的协议是全加密的：请求体 AES、URL 追加密文、头部 SHA-256 签名、响应解密 + zlib。
写这类实现时最危险的状态是"看起来完成了"：

```text
第一版：751 行、7 条 hermetic 测试全绿（往返 / 换 key 失败 / 坏 base64 / 签名串自证）
真网络：握手"失败"
```

而"失败"的原因被我说错过两次，都是**凭代码推断而不是看真实响应**：
1. 我说"握手被服务端拒绝（user info error）" —— 实际 `systemInit` 返回 `{"code":0,"msg":"init",…}`，**是成功的**；
2. 我说"没有 token ⇒ 搜索不可用" —— 实际把 token 改成允许为空后，`[LIVE] 搜索成功：20 条`。

真正的根因在更早一轮就找到了，只是不在"测试"里而在**反汇编**里：AES 的 key 不是 `appkey`，
而是字段 `c = uuid` 去掉连字符后的 32 个 hex 字符（AES-256）。72 个候选全败就是因为它从一开始就取错了。

## Decision

**加密类实现的验收标准是"能解开一条真实响应"，不是"能编译 / 单测绿"。**

1. **真实响应落成夹具入库**：`.probe/app99-known-systeminit.json`（28,514 字节，含 `uuid` + `response_b64`），
   配一条**不联网**的普通 `#[test]`：解密 + zlib → 断言顶层含 `player`/`parser_api`，并把解出的顶层键打到日志。
   这条用例是"链路对真实数据有效"的**可复跑证据**，比一次 live 日志强。
2. **端到端要真的跑一次业务请求**：`[LIVE] 握手成功：categories=8`、`[LIVE] 搜索成功：20 条`
   ⇒ 加密 → 签名 → POST → 解密 → zlib → JSON 全通。
3. **`token` 不许当硬门槛前提**：`systemInit` 成功时可以没有 token；把它当门槛会把"能用"判成"握手失败"。
4. **覆盖口径要精确到"哪一段验过"**：App99 记"只验到 home/list"，`detail`/`play` 未验 ⇒ 不许写成"App99 已完成"。

## Alternatives considered

1. **只靠 hermetic 测试宣称完成**（往返测试能证明加密/解密自洽）。
   自洽也能在"key 取错"时成立（只要加解密用同一个错 key）。**否决** —— 这正是第一版的状态。
2. **`token` 为空就报"握手失败"**。
   语义上"没有 token 不能搜"看起来合理，但真实响应证明它不成立。**否决**，改成先试业务请求。
3. **把 `unimplemented_note` 写成"服务端拒绝"就收尾**。
   与日志不符（`code:0`）。**否决** —— 类注释是给下一个人的第一手材料，写错比不写更糟。
4. **新增 `openssl` crate 来拿 AES-CBC**。
   会引入 libssl（违反"不新增运行时"）。用 RustCrypto 的 `aes`+`cbc`（纯 Rust、无 C 依赖），
   并在 `Cargo.toml` 注释里写清"为什么不能用 `ring`"（只有 GCM、无 CBC）。**采纳后者**。

## Consequences

- 收益：第 19 项覆盖从 18/94 到 **20/94 源**（`Bili` 10 + `PanWebShare` 6 + `4KZhinan` 2 + `App99` 2），
  且 App99 的"能浏览"有**真实响应夹具 + 真网络读数**双重证据。
- 收益：`unimplemented_note(api)` 这个机制留下来了 —— 将来"实现了但被服务端挡住"的类可以给具体原因，
  而不是让用户看到笼统的"尚未实现"。
- 代价：`aes` + `cbc` 进了依赖树（纯 Rust，编译时间略增）。
- 残留（如实）：`detail` / `play` 未做真网络验证；`POST /app/userInfo` 被拒（`code:1 user info error`），
  只影响登录态。⇒ 覆盖表写"App99 只验到 home/list"，不写"已完成"。
- 教训（已写进汇报）：**我给执行者的两个前提都被实测推翻**（"握手被拒"、"无 token 不可搜"）。
  ⇒ 对加密协议，**推断必须让位于真实响应**；"看起来合理"的语义假设要先用一条真请求打掉。

## Relations

- 同族（互链）：[2026-10-26-csp-honest-contract.md](2026-10-26-csp-honest-contract.md)
  —— 那篇立了 csp 类的四条硬约束（空即报错、镜像汇总、直连复测、不新增运行时）；本篇补第五条：
  **加密类要以"能解开真实响应"为门槛**。
- 同族（互链）：[../bug-fix/2026-10-26-unreachable-tiers-are-not-fixes.md](../bug-fix/2026-10-26-unreachable-tiers-are-not-fixes.md)
  —— 都是"看着做完、其实没通"的形态：前者在归因档位，后者在协议实现。
