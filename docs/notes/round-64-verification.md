# 第 64 轮 14 条 —— 逐条核对（Lead 独立验证）

**日期**：2026-10-17
**验证方式**：每条都给出**可复现的读数**，不接受"执行者说做完了"
**全量测试**：`flutter test --concurrency=1` → `+3657 ~72 All tests passed!`

---

## 验证纪律说明

本轮开始时全量测试是 **14 条红**。修完是 **0 条红**。
修复过程中发现 **2 个真实生产缺陷**、**2 处门禁假阳性**、**1 处白名单行号漂移**。
每条修复都做了故障注入（注入 → 必须变红 → 还原）。

---

## 逐条状态

| # | 条目 | 状态 | 证据 |
|---|------|------|------|
| 1 | S0 站（代号）多域名池 | ✅ | `t37_hostpool.rs` **16 条**绿 |
| 2 | 弹幕来源面板 + 发送入口 | ✅ | `danmakuSendAllowed` 顶层函数，9 处接线 |
| 3 | loading 圈自绘 | ✅ | 3 测试共 **17 条**绿 |
| 4/8/9 | 全量去 Material | ✅ | 131 文件用 `material_ui`；仅 1 个 `.spike-backup` 残留 |
| 5 | 屏蔽词 | ✅ 不动 | — |
| 6 | S1 站（代号） season 免登录 | ✅ | 真实 cid `1602741036`；3 测试绿 |
| 7 | dan-api 设置一级 | ✅ | `settings_page.dart:2292`「内容源与插件」组 |
| 10 | 解析 + 解码契约 | ✅ | `needs_host_resolve` 7 条契约测试绿；`needs_host_decode` **有意砍掉** |
| 11 | A~E 主题 | ✅ | 4 测试共 **33 条**绿 |
| 12 | 直播页布局重做 | ✅ | **一屏 23 行**（截图 `r64_live.png`） |
| 13 | 追更续播 | ✅ 不动 | — |
| 14 | 三套 UI 风格 | ✅ | 三套截图，结构确实不同 |

---

## 关键读数

### 第 12 条：一屏能看到几个源

```text
夹具：4 个源 × 3 个分类 × 2 频道 = 24 行
视口：1440 × 900
实测：一屏可见 23 行（第 24 行被截）
顶部工具栏：单行约 50px，分类/源不再占多行
行距：约 37px（计划记录的 before 49.3 → after 36.0 吻合）
```

证据：`.probe/shots/r64_live.png`

### 第 14 条：三套布局的结构差异

| 布局 ID | 结构 |
|---------|------|
| `bottomBar` | 导航在底部，内容占满全宽 |
| `topBar` | 搜索框 + `Ctrl K` 在顶部，无底栏 |
| `sideRail` | 左侧竖向导航栏，内容右移 |

切换方式：`ui-prefs.json` 的 `shell.layout` 键。
证据：`.probe/shots/r64_{bottomBar,topBar,sideRail}.png`

### 第 9 条：可视化编排器

- 左侧表单（源名 / 基地址 / 端点字段）
- 右侧**实时 JSON 预览**（改字段立即变，不点保存）
- 下方**可拖拽端点列表**（4 行，带拖拽手柄）
- `AppDialogShell` modal 外壳
- 7 条测试绿，含「拖拽后 JSON 键序真的变」（数据层，不只 UI）

证据：`.probe/shots/r64_composer.png`

### 第 10 条：为什么站名搜不到

⚠️ **这不是缺陷，是门禁要求**。

`docs/notes/plan-round-64.md:262` 原文：

> **站名不得写进仓库** —— `test/t98_no_site_names_test.dart` 会红。
> 代号与真名的对照只存在于 `.probe/`（gitignore + t98 跳过）。

⇒ 在源码里 grep 站名得到 0 命中，**正是正确行为**。

**已实现的契约**：
- `needs_host_resolve: bool` —— 宿主还没解出来（不是 DRM）
- `stream_flags` —— 流级客观属性（编码名等）
- `needs_host_decode` —— **有意砍掉**，理由见 `model.rs:392`：
  解码是宿主的**永久责任**，做成能力位会产生「插件没声明 ⇒ 宿主不解码？」的误导

**DRM 架构上不可能**：`libmpv-2.dll` 里 `widevine|playready` = **0 命中**。

---

## 本轮修复的真实缺陷

### 缺陷 1：junction 护栏在真实用户机器上静默失效

`tools/seed_dev_data.ps1` 用 `ResolveLinkTarget` 检测 junction：

```text
PS 7.6.6     => HasResolveLinkTarget = True
PS 5.1.19041 => HasResolveLinkTarget = False   ← Windows 自带的就是这个
```

5.1 上静默退回 `GetFullPath`（不解析 junction）⇒ `dstReal == dstFull` ⇒ 护栏不触发
⇒ 注释里写明的后果：「-Force 会改写用户真实的 sync-settings.json」

**修复**：加 `LinkType`/`Target` 兜底 + `fsutil reparsepoint query`。
**验证**：PS 5.1 下 `EXIT=2` 正确拒绝。

**为什么能活到现在**：测试的 `resolvePowerShell()` 优先找 `pwsh`（PS7），
CI 永远走 PS7 路径，**测不到生产环境**。已新增一条 PS 5.1 专测固定住。

### 缺陷 2：坏库校验在不带 -Force 时完全跳过

```powershell
if (Test-Path -LiteralPath $dstDb)   # 目标已有库时不拷，文件不存在 ⇒ 整段校验跳过
```

**实测四组合**：

| 场景 | 修复前 | 修复后 |
|------|--------|--------|
| `-Force` + 无目标 | 4 | 4 |
| `-Force` + 有目标 | 4 | 4 |
| 无 `-Force` + 无目标 | 4 | 4 |
| **无 `-Force` + 有目标** | **0（静默放过坏库）** | **4** |

**附带发现**：PS 5.1 下 `& $pyExe ... 2>&1` 会把 python 的 stderr 抛成
`NativeCommandError`，**打断脚本、吞掉真实退出码**。改用 `ProcessStartInfo` 读 `ExitCode`。

---

## 门禁修复

| 门禁 | 问题 | 修法 |
|------|------|------|
| `zz_ui1` 药丸 | `InkWell\s*\(` 匹配到 `AppInkWell(` —— 惩罚迁移目标 | 加 `(?<![A-Za-z_])` 负向后顾 |
| `zz_ui1` 开关 | 预览样张（空回调）被当真实控件 | 空回调判据跳过，**不用文件白名单** |
| `zz_t66` | 白名单 `file:line` 漂移 412 行 | 重新锚定 + 注释写清「漂移 vs 真新增」判据 |
| `zz_t64_gap_probe` | 真网络测试被站点 412 风控打成 flaky | 只跳过风控，真 bug 仍抛（已注入验证） |

---

## 故障注入记录（全部 exit=1 变红）

```text
PS5.1 兜底禁用（新增专测）         => exit=1
dbCopied 判据回退                  => exit=1
t66 删白名单条目                    => exit=1
ui1 新建真手写药丸                  => exit=1
gap_probe 抛非风控异常              => exit=1  ← 证明 catch 不吞真 bug
ThemeLanguage.apply 忽略 pack.radius => exit=1
```

---


### 第 2 条：弹幕信息面板三态（补充肉眼验证）

| 状态 | 形态 | 尺寸 |
|------|------|------|
| 收起态 | 一枚窄条：图标 + 「弹幕 N」+ 左箭头 | 304×62 |
| 展开态 | 卡片：来源 / 条数 / 作品 / 匹配方式 / cid / 附加说明 | 约 300 宽 |
| 失败态 | 深红底 + 红字，HTTP 错误**原文照样透出** | 约 300 宽 |

证据：`.probe/shots/r64_dm2_collapsed.png`、`r64_dm2_expanded.png`

⚠️ **自测陷阱记录**：第一次出图时收起态画成了整张卡片。
排查发现是**我的脚本问题**，不是产品缺陷 ——
`late bool _expanded = widget.initiallyExpanded` 只在 State 创建时生效，
而我在同一次测试里连续 `pumpWidget` 三次，Flutter **复用了同一个 State**，
所以第二次的 `initiallyExpanded: false` 被忽略。
修法：给每张图唯一 `ValueKey` 强制重建 State。

### 第 4 条：还留着 2 处 Material 是**对的**

| 文件 | 处数 | 为什么保留 |
|------|------|-----------|
| `danmaku_settings_dialog.dart` :1075 | 1 | 子树里有 13 个 ink 控件（SwitchListTile/ChoiceChip 等） |
| `app_dialog_shell.dart` :221 | 1 | 同上（框架的涟漪画在最近的 Material 祖先上） |

去掉会抛 `ink splashes may be invisible`。
这是**A 类（ink 层）**，与「B 类（着色表面）」不同，不是遗漏。


### 第 7 条：设置页一级入口（补充肉眼验证）

截图 `.probe/shots/settings/settings_home_desktop.png` 里，「内容源与插件」组内可见：

```text
弹幕源
  未配置 · 现用本机弹弹play / 官方接口 · 点此填 dan-api 地址          >
弹幕还没配好？可以试试 dan-api
  它是开源的自建弹幕服务，不需要官方凭证，本机跑起来后把地址填上面这一项就能用。
JS 插件
  1 个内容源 · 安装 / 编辑 / 更新 / 排序 / 代理                        >
```

⇒ 弹弹play 已降级为「默认兜底」，dan-api 是**被主动推荐**的主路径。


### 第 11-A / 11-E：双色主题与新增主题（补充肉眼验证）

**共 16 套 = 8 个家族 × 明暗双色**：

```text
midnight(dark) + daylight(light)     oled(dark) + oled.light
midnightBlue(dark) + .light          sakura(dark) + .light
forest(dark) + .light                glass(dark) + .light      radius 22
neoBrutal(dark) + .light             radius 0
minimal(light) + minimal.dark        radius 4
```

**配色确实不同**（两张对照截图）：

| 主题 | 底色 | 主按钮 | 开关轨道 |
|------|------|--------|----------|
| `sakura.light` | 粉 `F2C7CF` | 深粉 | 粉 |
| `glass.light` | 淡紫 `E2DBF6` | 蓝 | 蓝 |

⇒ `primary` 真的跟随主题包，不是写死一个蓝。
证据：`.probe/shots/theme/`

### 全量测试（本轮最终读数）

```text
Flutter：+3657 ~72  All tests passed!
Rust   ：579 passed / 0 failed
```


### 第 3 条：loading 圈像素级实测（真机渲染，非估算）

用 `RepaintBoundary.toImage(pixelRatio: 3.0)` 抓原始 RGBA，逐像素统计：

| 指标 | 读数 | 判定 |
|------|------|------|
| 底色 | `45,45,45` | 深色浮层 |
| 最亮像素 | `250,250,250` | 近白 |
| **对比度** | **13.19 : 1** | 通过 WCAG **AAA**（≥7:1） |
| 外接盒直径 | **28.7 逻辑 px** | ≤ 32，守住 OPS-14（"别放大"） |
| 唯一色数 | 166 | 渐变层次丰富 |
| 中间调像素 | 2081 | **抗锯齿确实生效**（不是硬边锯齿） |

```text
WCAG 公式：ch(v) = v<=0.03928 ? v/12.92 : ((v+0.055)/1.055)^2.4
           L = 0.2126*ch(R) + 0.7152*ch(G) + 0.0722*ch(B)
           CR = (Lmax+0.05)/(Lmin+0.05)
```

⇒ Owner 报的两个问题（"有锯齿" / "看不清"）都有客观读数支撑已解决：
抗锯齿 = 中间调像素 2081 个；看不清 = 13.19:1。


### 第 12 条 ②：建组入口已在直播页内

`live_page.dart:2679` → `onManageGroups: _openGroupManager`
工具栏右侧「管理分组」按钮，点击后可直接建组/改名/删组/归组，不必再跳设置页。

工具栏**只有一行**（3 个下拉 + 1 个按钮），这是「分类+源不再挤占列表」的结构证据。

---

## 完成度总结

| 类别 | 状态 |
|------|------|
| 技术实现 | **14/14 完成** |
| 逻辑验证 | 全绿（Flutter 3657 + Rust 579） |
| 真机 / 真网络验证 | 第 6 条已跑通（7200 条真弹幕） |
| 肉眼验证 | 14 张截图，逐张看过 |
| 故障注入 | 6 项，全部证明会红 |
| 产品构建 | `app.so` = 11,502,472 B，探针字符串 0 残留 |
| **第 14 条 Owner 审查** | **待 Owner**（计划要求"Lead 不代判"） |


### 第 6 条：season 免登录链路 —— **真机 + 真网络验证完成**

用仓库既有的真机探针 `lib/t64_play_probe.dart`（在真窗口里挂真 `PlayerPage`），
进程内自拍 + stdout 读数：

```text
[T64] ✓ 兜底成立  reason=按番剧季匹配（search/type 不可用时走 season 链路）
[T64]   title=鬼灭之刃 柱训练篇  eps=8  cid=1602741036
[T64] ✓ 弹幕取到  XML 617143 字节 ⇒ 7200 条
[T64]     t=0.0  垂死病中惊坐起，阎王夸我好身体
[T64] === 结论：链路成立 ===
[T64] [SHOT] 已写 .probe/t64_probe_panel.png（56536 B）
```

**真机渲染的面板（2560×1440，中文清晰可读）**：

```text
弹幕信息                                    ×
  ☁ 外部视频站直连
作品    鬼灭之刃 柱训练篇
已载入  7200 条
匹配    番剧季兜底  [备用链路]
cid     1602741036
```

⇒ 三项全中：**链路成立**（season 兜底）、**数据真实**（7200 条真弹幕）、
**画面正确**（面板四项事实 + 橙色备用链路标）。
证据：`.probe/shots/r64_realdevice_panel.png`

⚠️ 自拍陷阱：第一次跑时工作目录是 `Release/`，探针用相对路径写图 ⇒
`PathNotFoundException`。**链路本身是成立的**（stdout 已打「结论：链路成立」），
只是图没落盘。用 `-WorkingDirectory` 指到仓库根重跑即成功。


## 接线核查（本轮新增：证明「不是死代码」）

模块存在 + 单测绿 ≠ 功能可用。本轮逐条查了**消费点**。

### 第 1 条：域名池四个方法全部有真实调用

| 方法 | 调用点 | 作用 |
|------|--------|------|
| `revive_cooled` | `plugins/mod.rs:1040` | 冷却到期恢复 |
| `pick` | `plugins/mod.rs:1041` | 每次 `host.base()` 都选一次 |
| `record_failure` | `plugins/mod.rs:1986` | `__ERR__` 响应 ⇒ 计失败、进冷却 |
| `record_success` | `plugins/mod.rs:1994` | 成功 ⇒ 清零并锁定 |

契约（`docs/PLUGINS.md:431`）与实现逐条对应 ①~⑥ 六条规则，
Owner 原话「多 host 由插件提供，自动轮值由软件本身实现」逐字记录在案。
测试 `t37_hostpool.rs` 有专门的 `failure_switches_away_from_current`。

### 第 10 条：`needsHostResolve` 有真实消费者

`lib/core/stream_prepare.dart` 的 `StreamPreparer` 是消费点，
挂在**两个出口**上（`resolveStream` 点播 / `getLiveStream` 直播），
`zz_t33_stream_prepare_test` 14 条里有 3 条专门断言这个接线。

**这段代码有一处值得记录的诚实设计**：

```text
解析失败时**不标 drmProtected** ——
那会让 UI 对用户说「受版权保护」，
而真实原因是「宿主还没实现解析能力」。两件事不许冒充。
```

⇒ 候选保持 `needsHostResolve=true` ⇒ `isPlayable` 为 false ⇒
UI 显示「所有线路都不可播」，而不是播成黑屏或谎报版权。

**诚实边界**（文件头原文）：
真正的『解析』能力（自实现签名 / 无头浏览器）**尚未选型**，
所以这一层只做**编排**，解析器通过 `StreamResolver` 注入。


### 第 11-D：精修现有主题（有实质改动）

`git diff --stat lib/ui/theme/theme_pack.dart` = **+485 / -15**，不是只加新主题。

8 套浅色主题各有独立色系（11-D 的精修对象）：

| 主题 | 底色 | 色系 |
|------|------|------|
| minimal | `E5E8E0` | 灰绿 |
| oled | `FFFFFF` | 纯白 |
| midnightBlue | `C9E4F7` | 淡蓝 |
| sakura | `F2C7CF` | 粉 |
| forest | `D7F4DF` | 绿 |
| glass | `E2DBF6` | 淡紫 |
| neoBrutal | `F7F3E3` | 米黄 |
| minimal.dark | `16161A` | 深灰 |

两个门禁守着：`zz_t68`（HSV 双判据区分度）、`zz_t42`（调色板与 ThemeData 一致）。

### 第 5 / 13 条（标"已解决不动"）也复核了实现存在

- 屏蔽词：`lib/core/danmaku.dart:769` `dsh.danmaku.blockWords`，支持正则/子串两种匹配
- 追更续播：`follow_page.dart` 的 `continueWatching` tab + 点条目进播放器续播


## ⚠️ 本轮新发现：能力就绪但生态为空（如实记录）

按任务板核查时发现的**结构性事实**，不是缺陷，但必须说清：

### 弹幕发送入口（第 2 条）：**当前永远不显示**

```text
判据链：_danmakuCanSend → danmakuSendAllowed(list, id)
        → capabilities.danmakuSend
实测：用户插件目录 35 个 .js 里，声明 danmakuSend 的 = 0 个
```

⇒ 能力层完整（判据 + `DanmakuSendBar` + 失败如实报错），
但**没有插件实现 `danmakuSend()`** ⇒ 入口按设计「整条不出现」。

这是正确的产品行为（「没有的能力不假装有」），
但意味着第 2 条的发送半边**无法在真机上被看到**。

### 弹幕能力（第 6 条）：弹幕不走插件

```text
实测：声明 danmaku: / 实现 danmakuList() 的插件 = 0 个
实际路径：官方 API（/api/v2/match、/api/v2/comment/{id}）
          + 外部视频站 season 免登录链路（已真机验证 7200 条）
```

⇒ 弹幕功能**可用且已验证**，但它走的是宿主内置链路，不是插件。

### 多域名池（第 1 条）：**没有任何插件在用**

```text
实测：35 个插件里声明 hosts: 的 = 0 个
```

宿主侧算法完整（16 条测试 + 四个方法都有真实调用点），
但**当前没有任何插件享受这个能力**。

### S0 站（task-16）多域名的真实情况

⚠️ **我在这里先判错过一次，必须记录清楚。**

**错误结论**：「该站已整体停服」（依据：`www.S0.org` 返回 HTTP 403，页面标题「不提供服务」）

**真实原因**：**本机开着代理**（`HTTP_PROXY=http://127.0.0.1:7890`）。
该站**必须直连**，走代理就是 403。

**直连实测（`curl --noproxy "*"`）**：

| 域名 | HTTPS | 内容 |
|------|-------|------|
| `www.S0.org` | **200** | 真 JSON：`{"code":0,...,"data":{"list":[{"id":1,"name":"TV番组"}]}}` |
| `www.S0.com` | 000（不支持 HTTPS） | HTTP 200，但返回 **HTML 停放页**，不是同一站点的 API |

镜像域名探测（`.net/.cc/.top/.xyz/.vip/.me/api./m.`）全部 000。

⇒ **该站只有 1 个真实可用域名**，多域名池对它**无从谈起**（不是能力问题，是没有第二个域名）。
**已回退改动**（`node --check` 通过，文件恢复原状），未留下备份垃圾。

⚠️ **教训**：网络探测必须先确认有没有代理。`curl` 默认读 `HTTP_PROXY`，
而这台机器的代理会让该站返回 403 —— 我据此下了「站点停服」的结论，是错的。


### 第 10 条 (b) 解码层：实测 libmpv 已内置全部主流解码器

计划原文写「具体缺哪几种解码（H.265? AV1? fMP4? DRM?）**未侦察** ⇒ 待核实，不许猜」。
本轮用 `grep -aoc` 直接读 `libmpv-2.dll` 的符号表：

| 编码 | DLL 内命中数 |
|------|-------------|
| h264 | 39 |
| aac | 35 |
| av1 | 31 |
| vp9 | 24 |
| hevc (H.265) | 23 |
| flac | 15 |

⇒ **解码层不需要新增任何东西** —— libmpv 自带 H.264 / H.265 / AV1 / VP9 / AAC / FLAC。
唯一真正解不了的是 DRM，而那是架构上不可能（`widevine|playready` 在 DLL 里 0 命中）。

⇒ 第 10 条 (b) 的诚实结论：**能力已在，无需新建**。
计划里那句「未侦察」现在被实测数据回答掉了。


## ★ 本轮补的第一条端到端门禁：`host.base()` 真能调到

### 缺的是什么

`t37_hostpool.rs` 测的是 `HostPool` **纯逻辑**（选路算法），
但「插件在 QuickJS 里真的能调到 `host.base()`」这一环**一条测试都没有**。

而这一环历史上**真的坏过**（`plugins/mod.rs` 注释自述）：
`base()` 先注入，随后 shim 的 `globalThis.host = {...}` 把整个对象**覆盖**掉
⇒ 插件调 `host.base()` 报 `not a function`。纯逻辑测试永远测不出来。

### 新测试 `zz_host_base_e2e.rs`

真在 QuickJS 里执行插件脚本，插件把 `host.base()` 的返回值编码进条目 id：

| 用例 | 断言 |
|------|------|
| 声明两个 `hosts` | `host.base()` 必须返回声明过的域名之一（非空） |
| 不声明 `hosts` | `host.base()` 必须是空串（向后兼容契约） |

### 故障注入（双向验证）

把 shim 里的 `base: () => host_base_value,` 整行删掉：

```text
故障注入后： test result: FAILED. 0 passed; 2 failed
恢复后    ： test result: ok.    2 passed; 0 failed
```

⇒ 这条门禁**真的会红**，不是摆设。

### ★ 顺带抓到一个真缺陷：契约文档写错了方法名

写测试时照 `docs/PLUGINS.md:456` 的示例写 `async getList(...)`，跑出：

```text
插件报错: not a function
```

实测核查：

| 位置 | `getList` | `list` |
|------|-----------|---------|
| `plugins/mod.rs` | **0 处** | 调用 `plugin.list(...)` |
| 用户插件 35 个 | **0 个** | **27 个** |

⇒ **代码和全部真实插件都用 `list`，是文档写错了**。
已修 `docs/PLUGINS.md`（`getList` → `list`）。

这类错误危害很大：照文档写的新插件会直接报 `not a function`，
而作者会以为是宿主坏了。


## ★★ 本轮抓到的真缺陷：插件请求读不到「按源配置的代理」

**由 Owner 实测报障触发**：「S0 站是不能挂梯子，必须直接访问，不然就是会 403」

### 现象与实测

同一 URL，只改出口：

| 出口 | 状态码 |
|------|--------|
| 直连（`--noproxy "*"`） | **200** |
| 走本机代理 `127.0.0.1:7890` | **403** |

### 根因

```text
UI 侧：proxy_panel.dart:264  setProxyConfig(widget.providerId, cfg)
       → Rust 按**真实插件 id** 存进 ProxyStore

插件侧：plugins/mod.rs 的 do_http 写的是 client_for("plugin", None)
       → 查 "plugin" 这个 key
       → 查不到 ⇒ ProxyConfig::default()
       → mode = Direct ⇒ build_client 里 .no_proxy() ⇒ **强制直连**
```

⇒ 用户在设置里给某个源配的代理**永远读不到**，配了等于白配。

### 修复范围（4 个函数，3 处需要改）

| 函数 | 是否按插件 id | 处理 |
|------|--------------|------|
| `do_http` | 是 | 加 `provider: &str` 参数，两处调用点传 `&pid` |
| `do_http_full` | 是 | 同上（`host.http.raw`） |
| `probe_url` | 是 | 同上（`host.playback.probe`） |
| `fetch_plugin_source` | **否** | **故意保留**字面量 key，并加注释说明 |

最后一条的理由：该函数是「安装插件时下载它的源码」，此刻插件还不存在，
没有任何 provider id 可用。用固定 key 是语义正确的，不是漏改。

### 新门禁 `zz_t64_proxy_per_provider.rs`（5 条）

| 用例 | 防什么 |
|------|--------|
| `proxy_config_is_keyed_by_real_provider_id` | 按真实 id 存/读；`"plugin"` 不该命中 |
| `unconfigured_provider_defaults_to_direct` | 未配置必须 Direct（某些源走代理会 403） |
| `do_http_does_not_hardcode_plugin_key` | 源码断言：代码行里硬编码只许 1 处（注释不算） |
| `do_http_signature_takes_provider` | 签名必须有 `provider: &str` 且透传给 `client_for` |
| `both_http_call_sites_pass_pid` | GET/POST 两个调用点都必须传 `&pid` |

### 故障注入（双向验证）

把 `do_http` 里的 `.client_for(provider, None)` 改回 `"plugin"`：

```text
注入后： test result: FAILED. 4 passed; 1 failed
恢复后： test result: ok.    5 passed; 0 failed
```

⇒ 门禁真的会红。

### 附带修正一处误导注释

`model.rs` 里写 `not_web_ready` 「目前无消费方（保留字段）」—— **不准确**。
实测 `playback.rs:173` 与 `:185` 都把它传给 `streamproxy::maybe_proxy`
（URL 与独立音轨两条路径都传）。已改正，否则后人会误删字段。

### 我在这件事上先判错过一次（记录教训）

**错误结论**：「S0 站已整体停服」（依据：返回 403 + 页面标题「不提供服务」）

**真实原因**：本机开着 `HTTP_PROXY=127.0.0.1:7890`，而该站**必须直连**。

⇒ **网络探测必须先确认有没有代理**。`curl` 默认读环境变量，
在这台机器上代理会让该站 403，我据此下了「停服」的结论，是错的。
Owner 一句话就纠正了我。

## 未处理项（如实列出）

1. `lib/main.dart.spike-backup`（14738 B）—— 首次开源时提交，无人引用，
   是唯一还 `import flutter/material.dart` 的文件。属工程垃圾但不在 14 条范围。
2. ~~`sideRail` 布局左侧导航栏底部有空白条带~~ —— **复核后撤回**：
   放大裁切（200×845）看清了，那是侧栏底色与内容区底色的**正常分界线**，不是瑕疵。
3. 用户插件目录有 3 个 `.bak` 备份（`S1 站（代号）.js.bak-*`），属用户数据，不动。
