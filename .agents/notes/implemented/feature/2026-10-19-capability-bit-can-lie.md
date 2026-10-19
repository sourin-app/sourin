# Agent Note: 一个能力位可以「声明了但永不生效」，而所有既有门禁都看不见

Status: implemented

> 同域：[../process/2026-10-12-danmaku-credentials-build-time-secrets.md](../process/2026-10-12-danmaku-credentials-build-time-secrets.md)
> 相邻：[../../implemented/feature/2026-10-17-player-danmaku-send-entry.md](../feature/2026-10-17-player-danmaku-send-entry.md)
> （那篇建了发送入口；本篇讲**能力位本身可能是谎话**）。
> 方法论对照：[2026-10-19-sheet-guard-covered-two-of-ten.md](./2026-10-19-sheet-guard-covered-two-of-ten.md)（同样由「数满足点」发现）。

## Problem

新写的一条门禁（`check-capability-parity.mjs`）**第一次运行**就抓到一个缺陷：

```text
✗ <插件>: danmaku=true 但方法不存在 — 期望 danmakuList
  ⇒ 用户看到入口、点了必失败
```

核实链（四步，全是可复跑的命令）：

```text
① grep -n "danmakuList" plugins/<插件>.ts
   → 7 处，**全是注释里的说明文字**（其中一处正是记录这个缺陷的），零实现
② grep -c "danmakuList" plugins/_legacy/<旧版>.js
   → 0                       ← 旧版也没有，不是移植丢失
③ git log -S "danmaku: true" --oneline -- plugins/<插件>.ts
   → 8cbe158 "弹幕发送能力 + PGC 番剧取流（两条轨道合并）"
                             ← 是那次合并引入的
④ 宿主桥接 plugins/mod.rs:3704
   "(plugin.danmakuList ? plugin.danmakuList(req)
                        : Promise.reject(new Error('unsupported: 该源不支持弹幕')))"
   ⇒ 位 true + 方法缺失 = 界面显示"有弹幕"，取的时候 **100% 失败**
```

**它在本仓躺了几天，而所有既有门禁都是绿的：**

```text
· `check-danmaku-send-parity` 只管 danmakuSend（它有专门的语义检查：
  time×1000、mode 取值、ok:false 禁止）—— 不管 danmaku 位
· `_selftest_danmaku_parity` 同上
· `zz_n15_acceptance` 的 C0 读的是 `p.manifest().capabilities` —— 那**已经是宿主侧**，
  但没和**插件自己声明的**比
· 单元测试 `danmaku_send_is_bridged_and_returns_id` 等只测"有方法的那个能力"
```

★ **不是"没人写门禁"，而是每条门禁都只覆盖了它自己那个能力位。**

## Decision

### ① 修法：改成 `false` + `reserved:` 说明（不是去实现它）

```ts
// reserved: 未实现 danmakuList()，故声明 false。实现该方法是独立任务（拉取+解析弹幕，非发送）
danmaku: false,
```

```text
「补一个能力」与「如实声明」是两件事，后者优先。

理由：
· 实现 danmakuList = 拉弹幕 XML/JSON + 解析 + 分页 —— 与 N15（发送）无关的独立能力
· 而声明 true + 不实现 = **用户点了必失败**，比"这个源没有弹幕"更糟
  （前者让他以为软件坏了，后者是一个诚实的事实）
★ 判据：**能力位是对用户的承诺。没有兑现的手段，就不要承诺。**
```

### ② 新门禁：所有能力位的「声明 ⇔ 实现」双向核对

`tools/check-capability-parity.mjs`：

```text
对每个 plugins/*.ts：
  ① 从 definePlugin({ capabilities: {...} }) 提取声明
  ② 从实现体检测对应方法是否存在
  ③ 判据三态：
     · 声明 true  但方法不存在   ⇒ **红**（只声明不实现 = 用户点了必失败）
     · 声明 false 但方法存在     ⇒ **黄**（允许，但必须带 `// blocked:` / `// reserved:` 说明）
     · 声明 true  与方法存在     ⇒ 绿
  ④ 语义门（loginRequired / loginNeedsUsername）**不映射方法** —— 它们不是方法关
```

### ③ 关键设计：`anyOf` vs `allOf`（这个错误由故障注入打出）

```text
v1：`loginRequired` 映射到 `login`
    ⇒ 报假黄（loginRequired=false 但 login 存在）
    ⇒ 它是**语义门**不是方法关

v2：全部按 anyOf 判
    ⇒ 删掉 `qrLoginPoll` 后门禁**仍然是绿的**（qrLoginStart 还在）
    ★ 这是典型的「门禁不红，但可能是判据错而不是注入没生效」

v3：`loginQrSupported` 用 **allOf**（qrLoginStart + qrLoginPoll **必须全部存在**）
    其余按语义逐位映射
```

★ 并加了 `--debug <method>`：打印某方法命中的是哪种形态 ——
让「门禁不红时先查判据还是先查注入」从猜测变成一次可测的实验。

## Alternatives considered

### ① 去实现 `danmakuList()`（让声明变真）

**最强论据**：最彻底 —— 用户真正想要的是"这个源有弹幕"，而不是"它诚实地承认没有"。
而且宿主桥接已经写好了（只等插件实现），成本看起来只是"补一个方法"。

**为什么否决**：**它把两个独立能力绑在一起，而其中一个不在本轮范围。**

```text
实现 danmakuList = 拉取（XML/JSON）+ 解析 + 分页 + 与聚合器的字段对齐
⇒ 这是**独立的一条能力**，与 N15（发送）无关
⇒ 为了让一个声明变真而顺手塞进一条未验证的新能力，正是本仓反复吃亏的形态
★ 而且它不会立刻可用：拉回来还要与宿主 DanmakuBundle 的字段对齐，
  那是一整条链路，不是"补一个方法"。
```

### ② 删掉 `danmaku` 位（而不是设 false）

**最强论据**：字段不存在 ⇒ 不可能撒谎；也少一个需要维护的状态。

**为什么否决**：**`undefined` 与 `false` 语义不同，而调用方依赖这个区别。**

```text
· `capabilities.danmaku` 是 `bool`（Rust `pub danmaku: bool`），
  缺失时 serde 默认 false —— 表面上等价
· 但**语义上**：false = "这个源明确没有弹幕"；缺失 = "不知道"
  ⇒ 保留字段并写 false，配合 reserved 注释，读代码的人知道**这是被判断过的**
  ⇒ 删掉字段则像"从来没人想过"
★ 判据：**「明确没有」应当写在代码里，不要用「不存在」表达。**
```

### ③ 只在既有 `check-danmaku-send-parity` 里加几条

**最强论据**：不新增文件、不新增一道门禁、不新增 200ms 启动成本；
而且那个工具已经在同步链上了。

**为什么否决**：**两个工具的判据性质完全不同，混在一起会互相稀释。**

```text
check-danmaku-send-parity：
  · 深度语义（time×1000 / mode 取值 / ok:false 禁止 / 四态）
  · 只针对 danmakuSend 一个能力
  · 每条判据都要"理解"业务

check-capability-parity：
  · 广度存在性（9 个能力位 × 声明 vs 方法是否存在）
  · 与业务无关，纯结构核对
  · 新插件自动被覆盖，不需要为每个插件写检查

⇒ 若合并：存在性检查会被业务语义检查的复杂度淹没，
  而"新插件自动覆盖"这个收益会丢失（深度检查必须逐插件写）
★ 判据：**广度的自动覆盖 与 深度的逐项核对 是两件事，分开做各自都更简单。**
```

## Consequences

### 抓到并修掉的缺陷

```text
<插件>: danmaku=true 但无 danmakuList()  ⇒ 改为 false + reserved 说明
数据目录已同步（产物变了）：sha256 = 82ee7216…
```

### 读数

```text
check-capability-parity          ✅ 9 条（0 黄）
  ✓ vod=true ⇔ home/list/detail/resolve
  ✓ search=true ⇔ search
  ✓ live=false 且无对应方法
  ✓ loginSupported=true ⇔ login
  ✓ loginQrSupported=true ⇔ qrLoginStart/qrLoginPoll（allOf）
  ✓ danmaku=false 且无对应方法      ← 修复后
  ✓ danmakuSend=false 但方法存在（带 // blocked: 说明）

故障注入（两条都红）：
  A. danmaku: false → true
     ✗ danmaku=true 但方法不存在 — 期望 danmakuList
  B. qrLoginPoll 改名但保留 loginQrSupported
     ✗ loginQrSupported=true 但方法不齐全 — 缺：qrLoginPoll（这几位必须全部存在）
还原 ⇒ ✅ 9 条
```

### 同批新增的两条 Rust 验收判据（app 仓）

```text
C6 能力位桥接：插件自己声明的 vs 宿主 cement 的**逐字段相等**
   ★ C0 不够：C0 读的是 `p.manifest().capabilities`（已经是宿主侧），
     没和插件自己声明的比。真实的坑是 hydrate_capabilities 里**忘了**某一行
     ⇒ 入口永不出现且**不报错**。
   实现：对 login_qr / search 各真调一次，用 Unsupported 消息区分
        「方法不在」与「这次失败」

C7 失败必须 Err 不是 Ok(false)
   独立文件（夹具性质相反：需要"故意写坏"的插件，与验收文件混一起会互相掩盖）
   正常 ⇒ 2 passed；注入（把 if !r.ok { return Err } 改成 Ok(r)）⇒ 1 failed；还原 ⇒ 2 passed
   ★ 这条钉的是宿主 plugins/mod.rs:3766 那条纪律：
     「用户以为发出去了 → 刷新找不到 → 反复发 → 真站点可能已触发风控封禁」

C8 状态②双视角：位=false（入口不出现）+ 命令层仍给可读原因
```

```text
SOURIN_PROBE_PLUGIN=<插件>.js cargo test --test zz_n15_acceptance
  ⇒ test result: ok. 9 passed; 0 failed
cargo test --test zz_n15_c7_ok_false_injection
  ⇒ test result: ok. 2 passed; 0 failed
```

### 代价

```text
· 新增一道门禁（约 200ms node 启动）⇒ 已建议加进 sync-to-app 的链
· 能力位 ↔ 方法的映射是**人工维护**的映射表：
  新能力位需要有人加一行映射，否则它不被检查
  ⇒ 这类"门禁自身覆盖不全"的风险永远存在
  ⇒ 缓解：黄态必须带 `blocked:` / `reserved:` 说明 ⇒ 至少"声明 false 但方法存在"
    这种情况会被看见
· 只能检测"方法存在性"，不能检测"方法实现是否正确"
  （后者归 check-danmaku-send-parity 那类深度检查）
```

### 还没覆盖的

```text
· 只扫 `plugins/*.ts`（TS 源码），**不扫** `dist/`（产物）。
  若有人手改 dist 而不改源码 ⇒ 门禁看不到（但 check-dist-fresh 会红）
· `live` 位目前只检查"无对应方法"，不检查"有 liveStream 但声明 false"
  这类反向情况（因为本插件确实没有直播）
· 没有覆盖 `home` / `categories` / `rank` 这几个方法的存在性
  （它们不在 capabilities 里，属于"默认就该有"的一组）
```

### 何时该翻案

```text
① 若实现 danmakuList ⇒ 把 danmaku 改回 true 并删掉 reserved 注释
② 若出现新的"语义门"类能力位 ⇒ 映射表必须区分"方法关"与"语义门"
   （v1 的错误就是这样来的）
③ 若宿主改成"能力位由插件方法自动推导"（不再要插件手写 capabilities）
   ⇒ 这道门禁失去意义，因为它核对的两个东西合并了
④ 若能力位数量增长到映射表难以维护 ⇒ 改成从 Rust 的
   `Capabilities` 结构自动生成期望的方法清单
```
