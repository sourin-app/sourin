# Agent Note: 25 个 csp 类一次落地 —— "实现" 与 "注册" 是两条判据

Status: implemented

## Problem

Owner 的要求只有一句："全部都要做，jar 没有的，你就自己去研究实现了"。
接手时盘上是 **25 个 104 字节的空壳**（`mod.rs` 的 `pub mod` 已由上一轮接好），
其中 22 个在 `lmw_classes.dex` 里有逐类常量可还原，**3 个没有参考**
（`RenRen` / `Djlh` / `ALLLive`）。

难的不是"写 25 个文件"，而是**写完之后要不要让它们出现在用户的源列表里**。
本仓已有一条判例（`csp/app_fox.rs` 头部）：某类协议写得再对，若
① 订阅里没有站 ② 拿不到 host ③ 真网取不到数据，就**做实现、不注册** ——
因为"注册了但取不到数据"＝向用户交付一个"看起来支持"的假源。

## Decision

**两条判据分开：`实现` 只看协议是否复刻成功（代码 + 门禁 + 注入），`注册` 另有三条硬条件。**

注册必须三条同时成立：

```text
① 订阅（`.probe/ref-subscription.json`）里这一类的站数 ≥ 1
② 有可用 host：ext 里给，或从 DEX 常量逐字还原（**不许猜域名**）
③ 真网真的取到数据（直连、不走系统代理；失败要读 body 才许判"死"）
```

25 个类的结果：**13 注册 / 12 只实现不注册**。

```text
注册（13）：
  TingJinxia  SportsGuazi  ShortWeiguan  QuPanSo  QingtingFM  Yidong4K
  Wogg  HJZhenCai  Juying  BiliYS  Wn4k  RenRen  ALLLive
不注册（12）与缺哪条：
  缺②（无 host）：Mipansou  PanSou  Bdjmcc  Djlh
  缺③（有 host 但取不到数据）：SeedHub（Cloudflare 403，TLS 指纹）
        JuheSo（DNS NXDOMAIN）ShortHema（设备 token 门禁）
        ShortQimao（验签失败）ShortXingya（不发 token）Sports88（线路由混淆脚本渲染）
        SportsFeiqiu（data= 形态未确定，响应是固定壳）GuanYing（PoW 过了，第二道是账号）
```

**三个无参考类的取证方式**（Owner 授权"自己研究"）：

```text
RenRen   —— 其实在 jar 里（`Lcom/github/catvod/spider/RenRen;`），前一轮的"jar 里没有"是错的；
            用 `dex_const_strings.py` 抽出 JSOUP 选择器后翻成等价 regex，真网 4/4。
ALLive   —— jar 与 GitHub 都没有；依据链是仓库里既有的 `zhibo_platform.py`（drpy 聚合器），
            其某平台签名服务域名就叫 `alive.nsapps.cn/api/AllLive/<签名服务>` ⇒ 同名同源
            按它复刻 + 逐端点真网复核（三平台各有真数据 / 真 m3u8）。
Djlh     —— 走到"**没有站**"这一步：dex 无类、全 dex 26172 条字符串只有 Djuu、
            GitHub 0、四个域名单全 DNS 不存在、`djlunhui.com` 实测是赌博站。
            ⇒ 按同类目唯一已知模板写成，host 只从 ext 取，**不注册**，文件头逐条列依据。
```

## Alternatives considered

1. **25 个全部注册**（"都做完了就该都能用"）。
   最强理由：Owner 说的是"全部都要做"，全注册最贴合字面，用户也能在列表里看到覆盖面变大。
   **否决** —— 注册 = 承诺"点进去有内容"。`Bdjmcc` / `Mipansou` / `PanSou` / `Djlh`
   连 host 都没有，注册后用户点开只会看到一个打不通的源，且错误信息会是网络层的
   `error sending request`（本批已登记过这种"含糊错"的代价）。这正是 `app_fox.rs` 判例要防的事。
2. **只做能注册的 13 个，12 个直接不写**。
   最强理由：省一半工作量，且不产生"死代码"。
   **否决** —— ① Owner 明确说全部都要做；② 那 12 个类的协议复刻本身就是资产
   （AES 密钥、签名算法、PoW 实现、设备门禁的具体形态都取证到了），
   一旦哪天有 host 或账号，补一行 `register_site!` 就能上线；
   ③ 不写就永远没人知道"卡在哪一条"。
3. **给无 host 的类猜一个域名填进去**（`bdjm.cc` / `bdjmcc.com` / `bdjm.tv` …）。
   最强理由：能凑出"有 host"这一条，看起来完成度更高。
   **否决** —— 猜出来的 host 无法证伪，写进去就是编造证据；本批 6 个候选域名全部实测 DNS 不存在，
   这条恰恰是**实测否定**的。
4. **SeedHub 换 HTTP 后端绕 Cloudflare（`reqwest` 换 `curl`/`wreq` 之类）**。
   最强理由：curl 同分钟同 IP 拿到 200/41909B，说明只差 TLS 指纹，换成能改 JA3 的后端就通了。
   **否决（本轮）** —— 本仓纪律是"不新增运行时依赖"，`Cargo.toml` 零 diff 换不了后端。
   已在文件头留实验矩阵与一行补注册的位置，等 Owner 决定要不要为它开一个依赖口子。

## Consequences

- 收益：注册类 35 → **48**（现盘实测：行首 `crate::csp::register_site!(` 48 行、无同名重复）。
  本批新增注册 13 个，全部有真网数据。
- 收益：12 个"未注册"的类不是空壳 —— 每个都有完整 6 方法实现、自带门禁、注入真红记录、
  真网失败的具体形态（403 挑战 / 验签失败 / 无 token / DNS NXDOMAIN…），
  补上缺的那一条即可上线（文件头都写了"缺哪条"和"补哪一行"）。
- 代价：仓库里有 12 个"有实现但不注册"的类，`#[allow(dead_code)]` 之外的
  未使用告警与"为什么它不出现"的疑问会一直存在 ⇒ 每类的文件头第一段就是答案。
- 代价：门禁数量大涨（全库 `cargo test --lib` 1357 → **1626 passed**），
  编译时间与并发构建的锁竞争都变重（本批实测多个执行者互相等 `link.exe` 锁）。
- 验证：`cargo check --lib` error=0；`cargo test --lib` 1626 passed / 0 failed / 77 ignored；
  `zz_r3i_no_proxy_consistency` 4 passed（全仓 `.no_proxy()` 判据）；
  `zz_r3_csp_registry` 6 passed（含同名冲突注入用例）。

## Relations

- 判例来源：[./2026-10-26-csp-honest-contract.md](./2026-10-26-csp-honest-contract.md)
  —— 那篇定的是"空结果必须 Err / 不得代理冒充宕机"，本篇把它扩成"注册也要有证据"。
- 同族：[../bug-fix/2026-10-27-inconsistent-with-existing-convention-is-a-defect.md](../bug-fix/2026-10-27-inconsistent-with-existing-convention-is-a-defect.md)
  —— `.no_proxy()` 那条惯例；本批 25 个类全部遵守，全仓判据 4 条绿。
- 反例族：[../testing/2026-10-27-upstream-dead-is-a-strong-claim.md](../testing/2026-10-27-upstream-dead-is-a-strong-claim.md)
  —— 本批多次用到它的六项复刻法（如 GuanYing 的 PoW 过了才算"活"）。
