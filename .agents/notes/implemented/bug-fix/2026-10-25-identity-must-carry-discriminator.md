# Agent Note: 判别信息不完整时不许下结论（选中身份 / DNS 归因 / csp id）

Status: implemented

## Problem

同一批里出现三处**形态相同**的缺陷：判据手上只有"一半信息"，却给出了完整结论。

```text
① 直播选中身份只有 id —— 而列表是**跨源平铺**的
   ⇒ 两个源都有同一个频道 id 时：两行同时高亮；`_providerOf` 取第一个匹配组；
     更糟的是 stale guard 只比 id ⇒ A 源的取流结果会被 B 源那次接受（**串流**：
      标题是 B 的、流是 A 的）。

② DNS 归因只有"本机地址" —— 而"不一致"本身不足以说明劫持
   ⇒ 实网实测：Vercel 多 A/anycast，三家真 DoH 彼此就不一致（`.131` vs `.195` vs `.67`）；
     健康网络被判成"可能被劫持"，把用户推去改 DNS。
   ⇒ 另一侧：伪造段表缺 `185.45.*`，而 `resolvedAddress` 只带 OS 实际选去连的那一个
     ⇒ 走 IPv4 时**判不出**劫持，落到"连不上"，方向指向网络/代理。

③ csp 源的 id 落到 `tvbox{配置序号}` —— 而 id 应当标识"哪个源"
   ⇒ 用户在配置里插一条/删一条/重排，重新导入后 id 全变 ⇒ 旧源残留 + 收藏/进度失配。
```

三者的共同点：**判据的输出比它的输入能支持的更多**。这在本仓的门禁语汇里叫
"判据只到结论不到原因"，但更准确的说法是：**下了超出输入的结论**。

## Decision

**凡是要"下结论"的地方，输入必须包含能区分结论所需的全部判别信息；缺了就降级，不许外推。**

1. **选中身份 = `(provider, id)`**：新增 `LiveChannelSel`（`==`/`hashCode`，`rowKey` 与行 key 同拼法 `provider:id`）。
   `_providerOf` 改成三级判据（① 当前选中用它记的源 → ② 按 id 扫组 → ③ `_activeProvider` 兜底）；
   `_select`/`cycleChannel`（走 `_neighborEntry`）/`stepFullscreen`/`_loadStream` 的 stale guard/恢复选中
   全部跟到 provider。列表 API 新增可选 `selectedRow` + `onPickEntry`，**老入口保留**为兼容路径。
2. **DNS 归因分层**：`compareDanmakuDns` 加 `sameDnsSubnet`（IPv4 /24、IPv6 /48）并把"同网段"算 overlap；
   判据改成 `hijacked = different && looksForged(local)`，**新增 `dnsInconsistent` 档**
   （文案"不一致但都在正常段 ⇒ 别说劫持、别改 DNS"）。伪造段表补 `185.45.6.`（IPv4 侧）。
3. **csp id 与顺序无关**：`csp-<class 小写>-<crc32(name)>`；appleCMS 仍走原 `to_id`（它有 host 兜底，本来稳定）。
4. **附带**：`state.rs` 的失败清单改为**无条件写**（空 vec 走删除）——
   原来的 `if !is_empty()` 守卫让"病修好后旧报告永不到期"，属同一类"告警比事实更持久"。

## Alternatives considered

1. **选中身份继续用 id，只在"看起来会撞"的地方加 provider 比较**。
   这就是缺陷的成因：只要有一处忘了加，串流就回来了（`_providerOf` 有 7 个调用点）。
   **否决** —— 判别信息应当跟着数据结构走，而不是跟着每个调用点的记性走。
2. **DNS 只把 `different` 的文案改软（不改判据）**。
   文案变软但**归档仍叫 `dnsHijacked`**，下游（remedy、诊断区、日志）还会按"劫持"处理。**否决**。
3. **csp id 用 `unique_id`（同名加 `-2`）而不改算法**。
   那只是"撞了再加后缀"，顺序仍是主要输入 ⇒ 重排后依然是新 id。**否决**。
   已知残留：**同名**的两个 csp 源 crc32 相同 ⇒ 仍会退化成 `-2` 后缀，那时"顺序"是唯一可区分信息，
   这个退化是必然的（测试注释里写明，不装作已解决）。
4. **沿用 `LiveChannelRef`（`ui_prefs.dart` 的持久化分组条目）当运行时身份**。
   它带名字等字段，是"存盘结构"；拿它当比较语义会把两个概念绑死，改一个动两个。**否决**，
   另设只承担 `(provider,id)` 比较与 rowKey 还原的 `LiveChannelSel`。

## Consequences

- 收益：三处"输入不足却下结论"都被结构性堵住；第 15 项的串流、DNS 的两种误诊、csp 的 id 漂移各有注入证明。
- 代价：`LiveChannelList` 的公开 API 多了两个可选参数（`selectedRow`/`onPickEntry`），
  老入口 `selectedId`/`onPickChannel` 必须继续工作 —— 已用 4 条老用例实测（t48b 15 / t65d 25 / t1013 17 / t134 39）。
- 代价：`dnsInconsistent` 这档的文案承诺"大站多地址时这是常态"，若将来 DNS 真被劫持到**同一 /24**，
  会被判成"一致" —— 这是 /24 容差的固有代价，注释里写明；要更严需上"多源并集 + 覆盖率"而不是单对比较。
- 残留（如实登记）：`restore-failures.json` 仍**没有任何读取方**（"写了没人看"），
  这是同一族缺陷的第四处 —— 下一批补"读取方 + 界面提示"。

## Relations

部分重叠（互链，均不归档）：

- [2026-10-24-danmaku-search-draft-and-diagnostics.md](2026-10-24-danmaku-search-draft-and-diagnostics.md)
  —— 那篇讲"搜索页的诊断区与草稿"，本篇的 DNS 归因分层正是挂在同一片诊断区的**判据**上（它管"信息放哪"，本篇管"归因能推到哪一步"）。
- [2026-10-24-live-embedded-mute-intent-and-probes.md](2026-10-24-live-embedded-mute-intent-and-probes.md)
  —— 那篇是直播"静音意图"的状态契约，本篇的选中身份 `(provider,id)` 是同一层级上的身份契约（一个是状态、一个是身份）。
- [../../testing/2026-10-25-rebuild-threshold-must-not-encode-defect.md](../../testing/2026-10-25-rebuild-threshold-must-not-encode-defect.md)
  —— 同批的门禁测量方法决策：那篇讲"阈值不许编码缺陷态"，本篇讲"判据不许超出输入"。两篇一起才构成这批的"证据纪律"。

## Testing

- 第 15 项：`live_duplicate_channel_key_test` **+6**（④只有点的那行高亮 ⑤交接 provider 正确 ⑥键盘不跳源），
  3 次注入（退回纯 id ⇒ `{iptv:cctv1, other:cctv1}` 两行同亮；`_providerOf` 去掉来源优先 ⇒ `Expected other / Actual iptv`）；
  老入口兼容 **+96**；`live_page_test` 静态契约 **6 条 + 1 次注入**（删"先按身份找"那段 for ⇒ 红）。
- DoH：`t1027` **+30** / `r3_dns_hijack` **+22**，4 条注入（关 /24 容差、伪造段门禁恒 false、
  different 归回劫持、删 `185.45.6.`）各自按名字红。
- csp id：真网络 `csp_ids_survive_reorder_on_reimport` 证明重排后 id 不变；注入回退旧算法 ⇒
  `[EVIDENCE] A=tvbox1/tvbox2 B=tvbox2/tvbox1` 直接暴露漂移。
- `state.rs`：`stale_restore_failures_are_deleted_after_clean_boot`；注入把守卫加回去 ⇒ FAILED。
