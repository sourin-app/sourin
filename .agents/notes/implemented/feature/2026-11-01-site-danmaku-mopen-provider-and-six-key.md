# Agent Note: 站源原生弹幕 provider 与六键兼容解析（T8）

Status: implemented

## Problem

T2 对标取证（`.probe/reference-apk-benchmark.md` ③）发现参考 fork 内置两条本仓没有的弹幕能力：

1. **站源原生弹幕拉取**——不经过弹弹play 协议，直接打视频站自家的弹幕网关（mopen）；
2. **六键兼容解析**——各家源的弹幕 JSON 形态不一（`danmaku/data/list/result/results/items` 六键、键位任意层），参考 fork 的 `Danmaku.arrayFrom` 全都能吃，本仓只认弹弹play 的 `comments` 形态。

本仓已有完整弹幕管线（发送/屏蔽词/多来源/聚合），这是低成本补源；但播放页聚合编排在 `player_page.dart`（他人在制品，禁碰），接线点必须绕开它。

## Decision

- **站源弹幕是独立 provider**（`lib/core/danmaku_mopen.dart` 的 `MopenDanmuClient`），复用 `DanmakuTransport` 可注入底座，**不并入** `DanmakuSourceKind`/`DanmakuEndpoint` 选路——那是弹弹play 后端选路坐标，站源网关协议与之完全不同。
- **一期只做拉取（读操作）**，发送（写操作，触达站源账号）不写代码——Owner 批复 C 收紧：发送体内嵌 sign 的输入串未取证，"默认关的发送"也仍是能发出去的通路。
- **拉取解析已按 round-2 取证落地**（lead 授权补证一轮，≤3 请求）：MTOP h5 标准签名 `sign = md5(token + '&' + t + '&' + appKey + '&' + data)` 实证成立（网关回 `SUCCESS::调用成功`，probe round-2 归档）；信封 + 包裹层形态逐字取证——`data.result` 是**二次 JSON 编码的字符串**，内层 `{code:1, data:{result:[…], count:N}}`。**元素级字段名仍未取证**（样本 vid 计数 0）：元素走 `DanmakuComment.fromAnyJson` 泛化探测，并加「count>0 但解析 0 条」的**矛盾留痕**（形态对不上时抛出首元素原文，绝不静默回 0 条）。首版"secret 拼接式签名"被 round-2 实证否定（`FAIL_SYS_ILLEGAL_ACCESS`），secret 常量保留作取证锚点、不再参签。
- **六键兼容是形态探测，不是替换**：`danmakuListFromAnyJson`（纯函数）沿树找六键数组（缺层容错，深度上限 8）；挂在 `fetchComments` 里作为 **comments 未命中的回退**——既有 `comments` 形态命中走原路，零变化（Owner 批复的硬门禁，t141 有集成级红度对照）。元素解析 `DanmakuComment.fromAnyJson`：p/m wire 优先，泛化 `{time,text}` 兜底，时间 >36000 按毫秒解释（片内秒数不会超 10h）。
- **接线在设置二级页**（`danmaku_source_page.dart` 新区块，开关默认关）：用户可选面先行，进播放页自动聚合另排（需要给 `player_page` 加 feed，禁碰期内不做）。
- **风控对齐 pan_check 口径**：同 vid+mat 结果缓存 TTL 10min；失败后 30s 冷却且冷却期内零网络。⚠️ 这两样是**类级状态**（互检 P2 修）：生产唯一调用点（设置页「拉取测试」）每次按键都拿新实例，状态若挂实例上等于没声明——冷却/缓存长在类上（跨按压/跨实例生效，有「新建第二实例打同一 vid ⇒ 冷却期内零请求」的门禁钉着），UI 侧再把客户端提为页面级字段（连接池不随按压重建）。一切失败抛 `DanmakuException` 带原文（UI 侧 `DanmakuException.message` 是设计好的用户主文案，其它异常走 `userErrorText` 收口）。
- **t98 站名铁律**：文件/类名/UI 文案全中性化（"站源"）；仅 3 行真实运行期端点进 `_exemptLines` 行级豁免（理由逐条写明，沿"运行期必需真实主机名"的既有豁免先例）。

## Alternatives considered

- **进播放页自动聚合（本次就闭环）**：最强理由是"用户不用配置、开箱即用"。被否：`player_page.dart` 是他人在制品，本批禁碰；强行接线会阻塞他人全量门禁。落点改为设置二级页 + 待播放页解冻后另批。
- **响应解析在首版按"未取证就不写"收口**：round-1 只有请求侧证据，签名口径未证实 ⇒ 解析注入点 + 如实抛"未接入"，不编字段名。round-2（lead 授权补证）拿到 SUCCESS 样本后才按真实形态落地包裹层——顺序是对的：先如实边界，再补证闭环，而不是反过来。
- **并入弹弹play 后端选路（`DanmakuSourceKind` 加枚举值）**：最强理由是"来源选择一处管全"。被否：`DanmakuSourceKind` 的语义是"弹弹play 协议后端选路"（local/custom/official 探活回退），站源网关协议与之完全不同，硬塞会污染既有选路状态机并引入回归面。
- **发送一期带上（代码就绪+默认关）**：被否（Owner 收紧为"代码也不写"）——见 Decision。

## Consequences

- 代价：①元素级字段名未取证（round-2 样本 vid 计数 0）——元素解析按泛化探测，真实带弹幕的样本到手后要钉死字段映射（矛盾留痕会在对不上时如实报错，不会静默）；②六键的泛化元素字段映射（`{time,text}`）同为按探测实现的设计决定，单测钉住；③拉取依赖站源网关可用性，风控/改版都会如实报错。
- 收益：拉取链路端到端可用（MTOP 标准签名 round-2 实证 SUCCESS）；协议构造（body/sign/URL/两步令牌流/包裹层解析）全部被单测逐字钉死，签名有 python hashlib 跨实现对拍样例；六键解析给既有管线多一层容错（自建后端返回异形 JSON 时不再静默空）；既有来源零回归（comments 优先 + 开关默认关双保险）。

## Testing

- `test/t141_mopen_sixkey_test.dart`：六键六形态 + 缺层容错 + 元素形态探测 + `comments` 命中走原路的集成级对照（含"comments+data 同现时 comments 赢"的反例）。
- `test/t141_mopen_sign_test.dart`：body/URL 与 probe 归档逐字对拍，sign 与 python hashlib 跨实现对拍。
- `test/t141_mopen_provider_test.dart`：假 transport 证红——两步令牌流、失败原文照透、30s 冷却零网络、缓存 TTL、诚实空（SUCCESS+count=0 ⇒ []）、矛盾留痕（count>0 形态对不上 ⇒ 抛）、内层业务错、UiPrefs 默认零变化。
- 既有弹幕回归全量 + t98 站名门禁 + user_error_text 门禁。

相关：[danmaku-source-in-settings](2026-10-17-danmaku-source-in-settings-and-priority.md)（来源选路与设置页落点的既有决定，本篇不改变它）。
