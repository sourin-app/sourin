# Agent Note: `host.base()` 必须有端到端门禁

Status: implemented

## Problem

多域名池的选路算法有 16 条测试（`t37_hostpool.rs`），
但「插件在 QuickJS 里**真的能调到** `host.base()`」这一环**一条测试都没有**。

而这一环历史上真的坏过（`plugins/mod.rs` 注释自述）：
`base()` 先注入，随后 shim 的 `globalThis.host = {...}`
把整个对象**覆盖**掉 ⇒ 插件调 `host.base()` 报 `not a function`。

纯逻辑测试永远测不出这类缺陷——它测的是 `HostPool` 本身，
而坏掉的是「宿主把池子接到 JS 环境」的那一段。

## Decision

新增 `rust/sourin_core/tests/zz_host_base_e2e.rs`：
真在 QuickJS 里执行插件脚本，插件把 `host.base()` 的返回值编码进条目 id，
由测试读回来断言。

两条用例：

- 声明两个 `hosts` ⇒ `host.base()` 必须返回声明过的域名之一（非空）
- 不声明 `hosts` ⇒ `host.base()` 必须是空串（向后兼容契约）

## Alternatives considered

**「只测 HostPool 就够了，接线坏了编译会报错」**
放弃。接线坏掉**不会**编译报错：`globalThis.host` 是动态对象，
少一个字段只有运行到插件调它时才炸，而且是 JS 侧的 `not a function`，
Rust 侧只看到一句异常消息。这正是历史上真发生过的事。

**「用 `call_js` 直接 eval 一句 `host.base()`」**
放弃。`call_js` 是私有的，且那样测的是「能不能 eval」，
不是「插件在真实调用路径上能不能拿到」。
走 `list()`（Provider trait 公开方法）更接近真实使用。

## Consequences

收益：这条链路有了回归保护；故障注入能立刻变红。

代价：多一个测试文件（约 3.3 KB），跑得快（0.00s），可忽略。

## Testing

**故障注入**（把 shim 里的 `base: () => host_base_value,` 整行删掉）：

```text
注入后： test result: FAILED. 0 passed; 2 failed
恢复后： test result: ok.    2 passed; 0 failed
```

## 附带发现

写这条测试时照 `docs/PLUGINS.md` 的示例写 `async getList(...)`，
跑出 `插件报错: not a function`。实测核查：

| 位置 | `getList` | `list` |
|------|-----------|---------|
| `plugins/mod.rs` | **0 处** | 调 `plugin.list(...)` |
| 用户插件 35 个 | **0 个** | **27 个** |

⇒ 代码和全部真实插件都用 `list`，**是文档写错了**。
已修 `docs/PLUGINS.md`。这类错误危害很大：
照文档写的新插件会直接报 `not a function`，作者会以为是宿主坏了。
