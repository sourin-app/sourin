# 第 66 轮 N15：插件弹幕发送能力 —— 一手核查

> 2026-10-20 15:00–15:20 +0800 实测。作者：队友 `n15-boundary`。
> 范围：主仓应用侧接线 + 私库（`D:\WishProject\sourin-plugins`）契约/实现/门禁/边界文档。
> 本文件是**唯一**由本次核查新建/修改的主仓文件。私库**零提交、零 push**，故障注入后已还原（§3.4 有哈希证据）。
> ⚠️ 站名不复述（`test/t98_no_site_names_test.dart` 扫全仓含 `docs/`）。私库主插件文件记作 `plugins/<主插件>.ts`。

---

## 0. 结论先行（每条都能在 §1 找到对应读数）

| # | 问题 | 读数结论 |
|---|---|---|
| 1 | 应用侧用户看到什么 | **干净地不显示**：底栏/右下角整条发送栏不渲染（`if (danmakuSend != null)`），**不存在** R6 那种「开着、零弹幕、一枚 !」的假入口。但**唯一一句解释**藏在弹幕设置对话框里，从没打开过该对话框的用户 = **零解释** |
| 2 | 私库四者是否自洽 | 声明 ↔ 实现 ↔ 门禁 **三者自洽**（基线 exit 0，实测）。**文档不自洽**：`danmaku-send-boundary.md` §七 写「改回只需两处改动，门禁自动回合法态」，实测**不够** —— 还有一条门禁把改动链锁成「必须顺手实现 `danmakuList()`」 |
| 3 | 翻案三条能否推进 | ① 按字面**不可行**（宿主无任何 WebGL/canvas 面）② **无可查证据** ③ 无候选。**但存在第四条未被测过的路径**：伪造 `dm_img_*` 常量字段（文档自己的排除表 12 组里**没有一组**试过它） |
| 4 | 改回 true 的代价 | 不是「改一处布尔」，而是 **5 处改动 + 一个新功能（`danmakuList()`）+ 一次 build**；宿主/应用侧**零改动** |

---

## 1. 一手读数（命令 + 原始输出）

### 1.1 私库基线

```bash
$ cd /d/WishProject/sourin-plugins && git status --porcelain
（空 — 干净）
$ sha256sum plugins/<主插件>.ts dist/plugins/<主插件>.js
01b817612058e7f18f22122f22222fef97a8bfa61ba527927a9cb3fec2e08dab  plugins/<主插件>.ts
82ee72167e5fe682d7fb48afc4472a4a2d254b44a7c7896353eecf07127b7270  dist/plugins/<主插件>.js
```

### 1.2 声明 / 注释 / 实现的位置（grep，非记忆）

```bash
$ grep -n "danmakuSend\s*:\s*false\|// blocked:\|// reserved:\|async danmakuSend" plugins/<主插件>.ts
1237:    // reserved: 未实现 danmakuList()，故声明 false。实现该方法是独立任务（拉取+解析弹幕，非发送）
1300:    // blocked: 上游 dm/post 要求 WebGL 指纹(dm_img_*)，QuickJS 无 window/WebGL/canvas，结构上算不出来；翻案条件见上方注释
1301:    danmakuSend: false,
1954:  async danmakuSend(req) {
$ grep -n "danmakuSend: false\|async danmakuSend" dist/plugins/<主插件>.js
553:      danmakuSend: false
990:    async danmakuSend(req) {
```

⇒ Lead 记的 `:1301` / `:1954` 与 `blocked:` 注释**都对**；产物侧 `:553` / `:990` 同态。
★ 额外发现（Lead 未记）：`:1237` 有一条 **`reserved:` 注释**，它属于**另一个能力位** `danmaku`（不是 `danmakuSend`），见 §3.3 的影响力。

### 1.3 门禁基线（真跑，不是读脚本）

```bash
$ node tools/check-danmaku-send-parity.mjs
① 源码 plugins/*.ts（1 个文件）
  ✓ <主插件> 形态：状态 ②（声明=false 实现=true）
  ✓ 声明了 danmakuSend 就必须也声明 danmaku
② 产物 dist/plugins/*.js（1 个文件）
  ✓ 状态 ②（同上）
✅ 全部通过（4 条）        EXIT=0
$ node tools/check-capability-parity.mjs
【<主插件>】声明 9 个能力位 … ✓ danmaku=false 且无对应方法 / ✓ danmakuSend=false 但方法存在（已说明）
✅ 通过（9 条）            EXIT=0
```

⇒ 两条门禁在基线上**都 exit 0**，且输出**逐条列了判据**（不是「啥都不检查就 0」）。
反假绿证据见 §3.4：**三次故障注入全部变红**。

### 1.4 应用侧接线（真实文件路径与行号）

```bash
$ grep -rn "danmakuSendAllowed" lib/
lib/ui/player_page.dart:3397:  * ★★★ 判据走**顶层函数** danmakuSendAllowed —— 与单测读同一份实现。
lib/ui/player_page.dart:3408:      canSend = danmakuSendAllowed(list, id);
lib/ui/player_page.dart:20497: bool danmakuSendAllowed(Iterable<ProviderManifest> providers, String id) {
```

```bash
$ sed -n '16043,16052p' lib/ui/player_page.dart
danmakuSend: (_danmakuEnabled &&
        _danmakuCanSend &&
        _danmakuSendProvider != null &&
        !_isLive)
    ? DanmakuSendData(provider: …, onSend: _sendDanmaku)
    : null,
```

```bash
$ grep -n danmakuSend lib/ui/player/player_bottom_bar.dart
444:  this.danmakuSend,      531:  final DanmakuSendData? danmakuSend;
1388:  if (danmakuSend != null) _danmakuSendRow(danmakuSend!),
```

★ **路径更正（Lead 的读数过期）**：`lib/ui/widgets/player_bottom_bar.dart` **不存在**
（`grep: No such file or directory`）。真实路径是 **`lib/ui/player/player_bottom_bar.dart`**；
行号 `:1388` 仍然对得上。

### 1.5 唯一一句「解释」在哪

```bash
$ grep -rn "本片源不支持发送弹幕" lib/ test/
lib/ui/widgets/danmaku_settings_dialog.dart:3634:              '本片源不支持发送弹幕（只能看）',
（test/ 命中 0 条）
```

条件在 `:3633`：`if (biliBound && !widget.canSendDanmaku)`。
⇒ 文案**存在**，但（a）只在**弹幕设置对话框**里出现，不在底栏/发现点；（b）**零测试覆盖**。

### 1.6 门禁测试（应用侧）

| 文件 | 钉住什么 |
|---|---|
| `test/task41_danmaku_send_gate_test.dart:87/93/99/105` | 判据 `danmakuSendAllowed` 四态：false⇒false、未声明⇒false、true⇒true、源不存在⇒false（不崩） |
| 同上 `:270` group ④ | 「不支持发送 ⇒ 整条**不渲染**（第 66 轮口径，旧口径已作废）」 |
| 同上 `:305-327` | **源码反向断言**：`player_bottom_bar.dart` 剥注释后不许出现 `canSend:` / `disabledReason:`（第 65 轮「置灰可见」的逃生口） |
| `test/task41_danmaku_send_onwire_test.dart:187/222-226` | 真发：本地服务器确实收到正文 + 进度 + 集 id |
| 同上 `:234/267/311` | 未实现 ⇒ `ex.kind == 'unsupported'`，**绝不假装成功** |

**覆盖缺口（实测）**：`:305` 那条源码契约只扫 `player_bottom_bar.dart`，
**没有**任何测试扫 `player_page.dart:16043` 的 AND 谓词 ⇒
把 `_danmakuCanSend` 从谓词里**删掉**（用户从此看得到入口、点了必失败）
或**加回**别的条件，测试**都不会红**。

### 1.7 顺手发现的既有红（不是本次改动引入）

```bash
$ flutter test test/t98_no_site_names_test.dart --concurrency=1
命中：
  docs/notes/plan-round-66.md  →  「<站名>」（整文件命中；原文是具体网站名，此处不复述）
  docs/notes/plan-round-66.md:21 / :54  →  「<站名>」
Some tests failed.  （+7 -1）
```

⇒ **Lead 的 `docs/notes/plan-round-66.md` 目前让全仓站名门禁变红**（它在扫描范围内，
`.agents/notes/` 已进扫描范围也是该测试自己写着的）。合并前必须改成中性词。
本文件因此**不写站名**（插件文件名一律记作 `plugins/<主插件>.ts`）。

---

## 2. 应用侧真相（用户视角）

**会发生什么**（`danmaku_send=false` 的源，例如当前两个插件都是）：

1. 播放页底栏上方、右下角：**什么都没有**。不是灰按钮、不是 !、不是点了报错。
   链路：能力位 false ⇒ `player_page.dart:3408` 判据 false ⇒ `:16043` 谓词 false ⇒
   传 `danmakuSend: null` ⇒ `player_bottom_bar.dart:1388` 整条不渲染。
2. 弹幕设置对话框里：**有一行**静音说明「本片源不支持发送弹幕（只能看）」
   （`:3634`，条件 `biliBound && !canSendDanmaku`）。

**是否违反「不许静默」（R6 先例）** —— 分两半看，别合成一个结论：

| 维度 | 判定 |
|---|---|
| 是否留下「假入口」 | **否**。与 R6 的「开着、零弹幕、一枚看不懂的 !」**不同形态**：这里是**整条不画** |
| 是否「说了但说不清」 | **否**。文案明确到「不支持发送（只能看）」 |
| 是否「静默」 | **半是**。解释只在**弹幕设置**里；一个从没打开过设置的用户，对「为什么没有发送框」得到的是**零信息**。R6 先例的要害不是「不许静默画控件」，而是**「不画」+「在旁边说一句为什么」**——现在「说一句」被放到了另一个面板 |

⇒ 这条**需要 Owner 裁决**，不是我能定的：如果口径是「解释必须出现在发现点（底栏）」，
现状不合规；如果口径是「解释只需在弹幕设置里可查」，现状合规。
（我倾向：`danmaku_send=false` 的源在**底栏**至少给一行同款静音文案，成本 1 个 `Text` + 1 条断言。）

**旁证：口径已经改过四代，注释没跟上。**
`player_page.dart:16060-16105` 那段注释仍写着第 3 代口径
「入口**常驻可见** + 源不支持 ⇒ 控件 **disabled** + **必须能看到原因**」，
而**代码是第 4 代**（整条不渲染），`gate_test:270` 的 group 标题也写着「旧口径已作废」。
⇒ 注释过期（不是代码错）。下一个人照注释改，会重现被否掉的置灰版。
`:305-327` 那条反向断言正是为拦这个而存在，但它只拦「传参」，拦不住「照注释改」。

---

## 3. 私库四者自洽性 + 门禁故障注入

### 3.1 四者清单

| 要素 | 位置 | 内容 |
|---|---|---|
| 声明 | `plugins/<主插件>.ts:1301` | `danmakuSend: false,` |
| 说明 | 同文件 `:1300` | `// blocked: 上游 dm/post 要求 WebGL 指纹(dm_img_*)…` |
| 实现 | 同文件 `:1954` | `async danmakuSend(req) {` |
| 门禁 | `tools/check-danmaku-send-parity.mjs` | 四态 + `blocked:` 强制 + 产物同态 + ⑥「声明发送必须同时声明 danmaku」 |
| 文档 | `docs/danmaku-send-boundary.md` | §二 排除表（12 组）、§三 根因、§六 现状、§七 翻案条件（**含「改回只需两处」**） |

### 3.2 自洽性判定

- **声明 ↔ 实现 ↔ 门禁 = 自洽**（基线 exit 0，状态②合法且有说明）。
- **文档 ↔ 门禁 = 不自洽**：`boundary.md` §七 写
  「改回时只需：把 `danmakuSend` 改成 `true` + 删掉那行 `blocked:` 注释。门禁会自动回到状态①」。
  **实测不够**：门禁 ⑥ 强制「声明发送就必须也声明 `danmaku`」，而 `danmaku=true` 又被
  `check-capability-parity.mjs` 强制要求 `danmakuList()` **真的存在** —— 而它**不存在**（只在注释里被提到）。
  ⇒ 改动链是 **3 处布尔/注释 + 1 个新功能**，不是 2 处。

### 3.3 门禁文件覆盖不同（容易漏 build 或漏源码）

| 门禁 | 查源码 | 查产物 `dist/` |
|---|---|---|
| `check-danmaku-send-parity.mjs` | ✅（①） | ✅（②，`:269` 同态检查） |
| `check-capability-parity.mjs` | ✅ | ❌（只 `SRC_DIR`，输出只有「① 源码 1 个插件」） |

### 3.4 故障注入（三次，全部还原）

| # | 注入 | 期望 | 实测 |
|---|---|---|---|
| ① | 删掉 `:1300` 的 `// blocked:` 注释 | 红 | `✗ 状态 ② 必须带 blocked: 注释（说明为什么关、何时能开） — ★ 缺少 `// blocked: <原因>` …` **EXIT=1** |
| ② | `danmakuSend: false→true`（**只改源码**，产物仍旧 false） | 红（同态） | `✗ … 产物与源码**不同态**` **EXIT=1** |
| ③ | 源码 + 产物都 `danmakuSend:true`，但 `danmaku` 仍 false | 红（⑥） | `✗ 声明了 danmakuSend 就必须也声明 danmaku — 「能发」但「没有弹幕可看」自相矛盾`（源码 + 产物各 1 条）**EXIT=1** |
| ④ | 源码 + 产物都 `danmakuSend:true` **且** `danmaku:true`（= 文档说的「翻案后的状态」） | 发送门禁应绿 | `check-danmaku-send-parity` **EXIT=0**（`状态 ①`，4 条全绿）；但 `check-capability-parity` **EXIT=1**：`✗ <主插件>: danmaku=true 但方法不存在 — 期望其中之一：danmakuList ⇒ 用户看到入口、点了必失败` |

⇒ **④ 是最有价值的一条**：它证明「按文档改回 true」会**直接换来另一条门禁红**，
而红的原因不是 bug，是**缺一个新功能**。

### 3.5 还原证明（字节级）

```bash
$ sha256sum plugins/<主插件>.ts dist/plugins/<主插件>.js
01b817612058e7f18f22122f22222fef97a8bfa61ba527927a9cb3fec2e08dab  ← 与 §1.1 基线一致
82ee72167e5fe682d7fb48afc4472a4a2d254b44a7c7896353eecf07127b7270  ← 同上
$ git status --porcelain   （空）
$ git diff --stat          （空）
```

★ **一处必须写清的坑**：`dist/` 在 `.gitignore:5`（`git check-ignore -v` 实测），
即**产物不受版本控制** ⇒ `git status` 干净**不能**证明产物被还原。
我第一次还原时 `git checkout -- dist/…` 直接报 `pathspec did not match any file(s)`，
产物当时仍是注入态。最终用 **`sed` 反向替换那两行 + sha256 对比基线** 才算还原
（`82ee72…` 与基线逐字节相同）。⇒ 以后动 `dist/` 必须**先备份再改**，别指望 git。

---

## 4. 翻案条件逐条裁决

### ① 宿主暴露 WebGL/canvas 给插件沙箱 —— **按字面：结构不可行**

```bash
$ grep -in "canvas\|webgl\|navigator\|window" src/host.d.ts     → 0 命中
$ grep -n "interface\|export" src/host.d.ts
HttpApi / StoreApi / ConfigApi / LogApi / UtilApi / Host   ← 全部暴露面就这些
$ grep -n "rquickjs" rust/sourin_core/Cargo.toml
171: rquickjs = { version = "0.14", default-features = false, features = ["bindgen","futures","macro","parallel"] }
$ grep -rn "canvas" rust/sourin_core/src/
plugins/mod.rs:3507:  * QuickJS 里没有 canvas / DOM，插件画不出二维码。
provider.rs:617:    // ⚠️ 二维码 SVG 由宿主画：QuickJS 里没有 canvas，
```
`Cargo.toml` 依赖清单只有 serde/tokio/reqwest/axum/rusqlite/**rquickjs**/zip…，
**无 wgpu / skia / glow / gl**。⇒ 要求宿主给插件"真 WebGL"= 引一条图形栈进 cdylib，
与「纯跨平台 crate」的既有取舍正面冲突。

**但这条判定不能推成「伪造也不行」**（文档在这里滑了一步）：
- `boundary.md:64` 自己写着 `dm_img_str = "V2ViR0wgMS4wIChPcGVuR0wgRVMgMi4wIENocm9taXVtKQ"`
  —— 解出来是**固定字符串** `WebGL 1.0 (OpenGL ES 2.0 Chromium)`，**不是**每台机器算出来的；
- `:66` 的 `dm_cover_img_str` 是**显卡型号**的 base64（可硬编码一个常见值）；
- 而 §二 那张排除表 12 组（oid/type/mode/progress/msg/Referer/Origin/dm_format/字段名/buvid3+4/WBI/端点）
  **没有任何一组**动了 `dm_img_*`。

⇒ 「QuickJS 算不出来」是**推断**（对真指纹成立），「发一次伪造常量会怎样」**从未实测**。
这不是我在主张"能绕"，而是指出：**这是文档里唯一没被排除掉的单变量**。

### ② 上游放宽闸门 —— **无可查证据**

用两条 query 检索（`dm/post dm_img_str -400 风控`、`dm_img_list dm_cover_img_str 校验`），
返回的**全是站点首页/下载页**，没有任何 changelog、接口文档或第三方实测记录能证明闸门放宽或收紧。
⇒ 结论只能是「无可查证据」，不能写成「等一等会好」。

### ③ 等价路径 —— **无候选**

`boundary.md` §二 的端点行只覆盖 `dm/post` 与 `dm/post2`（两者都 -400）。
文档里那张「需要指纹的表」是**按接口路径**列的（Lead 的提醒成立），
所以「换域不换路径」不成立；而**同域其它写路径**是否有、是否同样要求指纹，
**既没有实测也没有公开证据** ⇒ 无候选，但也不等于已被排除。

---

## 5. 给 Owner 的决策选项

### A. 保持 `false`，并把「此源不支持发送」说到发现点
- **改什么**：私库零改动；应用侧在底栏/右下角（`player_bottom_bar.dart` 发送行所在位置）
  或播放页对该源渲染一行静音文案，与 `danmaku_settings_dialog.dart:3634` 同款措辞。
- **代价**：主仓 1 个 `Text` + 1 条断言（**并给 `:3634` 那句补上门禁**，现在它零覆盖）。
- **风险**：几乎没有。**唯一风险是文案口径**：不能出现「暂不支持/已知问题」这类开发过程用语。
- **与现状的差别**：现状是「不画 + 解释藏在设置里」；A 是「不画 + 解释在发现点」。

### B. 改回 `true`（+ 接受用户点了才失败）
- **改什么**（精确清单，见 §3.2 与 §3.4④）：
  1. `plugins/<主插件>.ts:1301` `danmakuSend: false → true`
  2. 删 `:1300` 的 `// blocked:` 注释（否则门禁①红）
  3. `:1238` **`danmaku: false → true`**（否则发送门禁⑥红：源码 + 产物各 1 条）
  4. **实现 `danmakuList()`** + 删 `:1237` 的 `// reserved:` 注释（否则能力门禁红）
  5. `node build.mjs`（否则产物不同态红）
- **宿主/应用侧要不要改**：**不要**。`plugins/mod.rs:826` 已 `c.danmaku_send = flag("danmaku_send")`；
  `model.rs:758` 字段在；`commands_backup.rs:124` 桥在；应用侧 `player_page.dart:3408/16043` 自动跟随。
- **门禁会不会自动回合法态**：发送门禁**会**（实测 ④ exit 0）；
  能力门禁**只有做完第 4 步才会**（实测 ④ exit 1）。
- **代价/风险**：等于**多做一个功能域**（拉取+解析弹幕），且换来「点了必失败」的体验
  ——这正是 Lead 第 65 轮已经否掉的形态；对方文档 §八 还明确警告「反复构造请求会在真实站点积累风控记录」。

### C. 应用侧补一句可解释说明（A 的最小版）
- **改什么**：`danmaku_settings_dialog.dart:3634` 那句**已经存在**，只需（a）给它补 1 条断言，
  （b）若 Owner 认为不够，再在底栏加同款一行。
- **代价**：0~1 个控件 + 1~2 条断言。
- **风险**：把「解释」与「入口」拆在两个面板，容易被后来者当成冗余删掉（所以断言必须钉住**原因**，
  不能只钉 `contains('不支持')` —— 换个原因也满足）。

### D. 做一次「伪造指纹」单请求探针（把推断变实测）
- **代价**：1 次真实写请求（需要 Owner 的登录态与明确授权；本会话**没有**也不该用）。
- **风险**：真实站点风控记录（对方文档 §八 的警告同样适用）。
- **收益**：能一次性判定「`dm_img_*` 是硬闸门还是仅一致性检查」，从而决定 A / B 谁是对的。
- **我的立场**：这是**唯一**能把条件①从"推断"变成"实测"的动作，值得由 Owner 决定要不要。

---

## 6. 我不知道的（诚实列）

1. **宿主是否缓存插件能力位** —— 改了 `danmakuSend` 要不要重启/重新扫描才生效？没查（涉及 `plugins` 扫描缓存与 `.data`）。
2. **发一条伪造 `dm_img_*` 的真实结果** —— 没测（无凭据，且属真实写请求）。
3. **`dist/` 重建是否字节可复现** —— 我没跑 `node build.mjs`（怕把产物改成「看起来新、实不同」的状态）；
   所以「`sed` 反向还原 = 与 build 产物等价」这点只用 sha256 证明了**等于基线**，没证明**等于重建结果**。
4. **`player_page.dart:16043` 的 AND 谓词有没有别处覆盖** —— 我只到「测试文件里没有扫这个文件」这一步，
   没穷举所有测试。
5. **其它写路径是否存在** —— 同域有没有别的发送端点、要不要指纹，无公开证据、未实测。
6. **`danmakuList()` 的工作量** —— 只看到"拉取+解析"四个字，没评估（拉 `seg.so` 还是 `web/view`、要不要 WBI、解析 XML/protobuf）。
7. **`docs/notes/plan-round-66.md` 的站名红** —— 我只报了读数，没改（那不是我的文件）。

---

## 7. 第二轮（2026-10-20 15:11–15:5x）：应用侧解释搬到发现点

### 7.1 改了什么

```text
lib/ui/widgets/danmaku_settings_dialog.dart   +15 -2
  · 条件：`biliBound && !widget.canSendDanmaku` → `!widget.canSendDanmaku`
    （「能不能发」与「有没有绑定某一路」是两件事；后者为假时原来**静默**）
  · 文案：'本片源不支持发送弹幕（只能看）'
        → '弹幕可以看、调样式、合并多路来源；发送只在支持发送的片源里提供'
    （按 R6 先例给「能做什么」；原因指向**片源**，不写网络/登录/设置/出错）

test/zz_t66_danmaku_panel_semantics_test.dart  +43 -19
  ⑤ 组从 2 条扩到 3 条，判据从「有没有一行说明」收紧到「为什么」：
    a 不能发（已绑定）⇒ 存在 + 含「可以看」+ 含「片源」+ **不含**网络/登录/设置/失败/错误/暂不
    b 不能发 + **没绑定**  ⇒ 存在（就删 `biliBound &&` 才绿）
    c 能发                ⇒ 不存在
```

### 7.2 故障注入读数（两次，均还原）

| 注入 | ⑤ 组读数 | 说明 |
|---|---|---|
| 删掉整个 `if (!canSendDanmaku)` 分支 | `+1 -2: Some tests failed` | a/b 红，c 仍绿 ⇒ 存在性断言真的在盯 |
| 条件改回 `biliBound && !canSendDanmaku` | `+2 -1: Some tests failed` | **只有 b 红** ⇒ 新断言精确钉住「没绑定就静默」这个洞 |
| 还原后 | `All tests passed` | `sha256 07644dd0…` 与注入前一致 |

全文件读数：`flutter test test/zz_t66_danmaku_panel_semantics_test.dart --concurrency=1` ⇒ **+15 All tests passed**；
`test/t98_no_site_names_test.dart` ⇒ **+8 All tests passed**（新文案无站点名）。

### 7.3 待 r6b-live 落定后补的门禁（✅ 已在 §8 兑现，原文保留以存历史）

```text
lib/ui/player_page.dart:16043 的发送框挂载谓词
  _danmakuEnabled && _danmakuCanSend && _danmakuSendProvider != null && !_isLive
⇒ 四个条件里任意一个为真/假都可能偷偷改变"入口在不在"，而**没有任何测试读这个文件**
  （我只核实到"测试目录里没有扫描 player_page.dart 的用例"，没穷举全部测试）。
建议：r6b-live 交完后加一条「四条件真值表」门禁 —— 逐条把某一项置假，断言发送框消失，
      并配阳性对照（四项全真 ⇒ 发送框在）。否则这条 AND 谓词永远只能靠人读。
```

### 7.4 本轮改口径（与第 1 轮冲突处，以这里为准）

第 1 轮我把「只翻发送位 ⇒ 发送门禁绿 / 能力门禁红」写进了报告，**实测是反的**（私库已按实测改文档）：

```text
只翻 danmakuSend（源码+产物同步）  ⇒ 发送门禁 EXIT1（跨位一致性：能发但没弹幕可看） / 能力门禁 EXIT0
只翻 danmakuSend（只改源码不 build）⇒ 发送门禁 EXIT1（+ 产物不同态）          / 能力门禁 EXIT1（产物不同态）
只翻 danmaku 位（无 danmakuList）   ⇒ 未跑                                     / 能力门禁 EXIT1
```

## 8. 第三轮（2026-10-20 16:30–17:38）：把那条 AND 谓词变成「可被弄红的门禁」

新文件：`test/zz_t66_danmaku_send_predicate_test.dart`（新建，本轮之前没有）。
跑法（**默认套件跳过** —— 需要真 `sourin_core.dll` + `libmpv-2.dll`，缺任一则整文件 skip，不是通过）：

```bash
flutter test test/zz_t66_danmaku_send_predicate_test.dart \
  --run-skipped --tags native-media --concurrency=1
```

### 8.1 它到底测什么（不是白送祖先的围栏）

```text
现有 test/task41_danmaku_send_gate_test.dart 明确绕开 PlayerPage（注释写的是真核会 npative 崩），
用的是 MaterialApp+Scaffold+PlayerBottomBar 的围栏 —— 那种围栏里
player_page.dart:16043 的谓词**一个字节都没跑**，删掉 `&& _danmakuCanSend` 照样绿。

本文件 pump 的是**真的 PlayerPage**，然后读它**建出来的** PlayerBottomBar 实例上的
`danmakuSend` 值（公开字段，:531），并同时数树里 `DanmakuSendInline` 的个数 ——
两个观测量必须同向（谓词给 null ⇒ 0 个；给数据 ⇒ 1 个）。
```

真值表（逐行 `--run-skipped` 实跑读数，`PRED|` 是测试自己打印的原始行）：

| # | enabled 总开关 | canSend 源声明 | provider 认得 id | live 直播 | 期望入口 | 实测 |
|---|---|---|---|---|---|---|
| 1 | T | T | T | F | 1 | `entry=1 PASS`（**阳性对照**） |
| 2 | F | T | T | F | 0 | `entry=0 PASS` |
| 3 | T | **F** | T | F | 0 | `entry=0 PASS` |
| 4 | T | F | **F** | F | 0 | `entry=0 PASS` |
| 5 | T | T | T | **T** | 0 | `entry=0 PASS` |
| 6 | F | F | F | T | 0 | `entry=0 PASS` |
| 7 | T | F | F | F | 0 | `entry=0 PASS` |
| 8 | F | T | T | T | 0 | `entry=0 PASS` |

全文件读数：`+9: All tests passed!` / `EXIT=0`（9 = 8 行表 + 1 条源码契约）。
`dart analyze test/zz_t66_danmaku_send_predicate_test.dart` ⇒ `No issues found!`

### 8.2 三个「看起来该红其实是假红」的坑（全部实测踩过，读数在此）

```text
① 不 start 核心 ⇒ listProviders() 抛 ⇒ _danmakuCanSend 恒 false ⇒ 阳性对照假红。
   解法：setUpAll 用**沙盒数据目录**起真核心，并往 <sandbox>/plugins/ 放两枚夹具插件。
   夹具做法：复制仓库自带 rust/sourin_core/plugins/demo.js，改写 @id/id/capabilities，
   改写没命中就 throw StateError（不许"测了个原样 demo"）。
   自检读数：DIAG provider id=demo danmakuSend=true / id=demo2 danmakuSend=false

② 只 tester.pump() 不行：initState 里那条 FFI 查询的回调在 fake_async 里**不会被派发**
   ⇒ 查询永远挂着 ⇒ 恒 false。必须 tester.runAsync(400ms) 让真实事件循环跑一次。

③ 让 _load() 真去解析流 ⇒ 沙盒没有真流 ⇒ _error != null ⇒ 底栏整个消失
   （实测 bars=0，读到的 null 分不清"谓词为假"还是"页面没底栏"）。
   解法：统一走 localPath（player_page.dart:3238 附近的生产短路，完全不调 _load()），
   配一枚自己生成的最小 WAV（8kHz/8bit 单声道 0.2s 静音，1644 字节）。

④ 还有一次红**与本门禁无关**：PlayerPage 一挂起就拉起 RemoteBridge 的轮询定时器，
   不 stop 就报 "A Timer is still pending even after the widget tree was disposed"
   （读数 +7 -1）。解法 setUp/tearDown 里 RemoteBridge.instance.stop()（t103/t108 同写法）。
```

### 8.3 故障注入：每条 AND 条件都必须有 ≥1 行变红

注入脚本对 `lib/ui/player_page.dart` 做"断言 old 唯一命中 → 替换 → 跑 → 从备份还原 → 核 sha256 与 git status"，
四次注入后 `FINAL_SHA=449570bd… 与 BASELINE_SHA 相同`、`FINAL_STATUS=[]`。

| 注入 | 改法 | 读数 |
|---|---|---|
| A1 | 谓词去掉 `_danmakuEnabled &&` | EXIT=1，**#2 变红**（`entry=1 expected=0`），仅此 1 行 |
| A2 | 去掉 `_danmakuCanSend &&` | EXIT=1，**#3 变红**，仅此 1 行 |
| A3 | 去掉 `_danmakuSendProvider != null &&` | **第一次：EXIT=0、零行红**（见 8.4） |
| A4 | `!_isLive` 换成 `true` | EXIT=1，**#5 变红**，仅此 1 行 |
| A3′ | 补上源码契约后再注入 | EXIT=1，红在契约：`谓词丢了条件 _danmakuSendProvider != null` |

### 8.4 A3 第一次是绿的 —— 这不是漏测，是那一格结构上不可达

```text
_danmakuCanSend 只在 _loadDanmakuSendCapability() 里赋值：
  · id 为空时 canSend=false 且 provider=null **一起**置（:3383-3392）
  · 之后 canSend 只由 danmakuSendAllowed(list, id) 决定（:3413）
⇒「canSend 真 + provider 空」没有任何代码路径能产生 ⇒ 黑盒表**永远**钉不住第 ③ 条，
  谁删了它都是绿的。它真正的职责是：万一哪天可达，`_danmakuSendProvider!` 当场空断言崩，
  而不是渲染一个坏入口。
⇒ 补了一条**源码契约**（与 task41 对 player_bottom_bar.dart 的做法同源）：剥注释后断言
  四条子句都在、false 分支仍是 `: null`、DanmakuSendData 用的就是谓词那个字段。
  补完后 A3′ 变红 ⇒ 缺口闭合。这是本轮唯一一处「先发现门禁有洞、再把它补上」的地方。
```

### 8.5 本门禁**不**覆盖什么（诚实边界）

```text
· 只管"入口在不在"（渲染）。**不管**点了之后发不发得出去 —— 那条在
  test/task41_danmaku_send_onwire_test.dart（真发到本地服务器、断言正文/进度/集 id、
  未实现 ⇒ ex.kind == 'unsupported' 绝不假装成功）。
· 第 4 格 (canSend=T, provider=F) 不可达 ⇒ 表里没有这一行，也不该为凑满 16 格假造。
· 默认 `flutter test` **跳过**本文件（@Tags + skip），所以它不会拦日常提交；
  要它拦就必须进 CI 的 native 阶段。
· 夹具用的是 demo 插件的改写版，改的是能力位声明；插件解析/归一化走的是同一条生产路径。
```
