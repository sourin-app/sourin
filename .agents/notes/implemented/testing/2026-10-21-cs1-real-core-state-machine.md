# Agent Note: CS-1 第④步补验 —— 用真核心而不是加注入点

Status: implemented

## Problem

CS-1 的「设置口令 → 状态行真的切换」这一步一直**没验到**。

原因不是没时间，是**架构上的选择**：`lib/core/sourin_api.dart:2115-2121` 有一条
明确纪律：

```text
注入点只覆盖 sync_status / sync_settings_get / sync_backup_list —— 它们都只是读。
写接口（configure / test / sync / 备份 / 删除）**不给注入点**：
「注入了就等于把『按钮点了会发生什么』从测试里拿掉，那正是最该测的部分」
```

⇒ 而我原来的补救建议是「给 `setCredentialsPassphrase` 加 debug 注入点」——
**那恰好是在破坏这条纪律**。

## Decision

**不加注入点。** 让**真核心**跑起来。

```text
lib/core/ffi.dart 用 `DynamicLibrary.open('sourin_core.dll')` —— 相对路径。
⇒ 把 build 产物里的 dll 放到**当前工作目录**（仓库根）就能打开。
⇒ flutter test 的 cwd 是仓库根 ⇒ 只要 sourin_core.dll 在那里就行。
⇒ `SourinCore.startAsync(临时数据目录)` 起真核心
⇒ `setCredentialsPassphrase` 走**真实 FFI**，不是替身
```

新增 `test/zz_t66_cs1_real_core_e2e_test.dart`（2 条）：

```text
★★★ 状态机四态：都没开 / 开同步无口令 / 开同步+口令 / 清口令
★★★ 故障注入：只设口令不开开关 ⇒ 状态行不许说"凭据将同步"
```

## Alternatives considered

- **给写接口加 debug 注入点**（我上一轮的建议）—— **否决**：
  ① 它直接违反 `sourin_api.dart:2115-2121` 的既有纪律，而那条纪律的理由是对的：
     注入了写接口，就等于把「按钮点了会发生什么」测掉。
  ② 即使加上守卫（非 debug 构建为 null），它验证的仍是**替身**，
     不是真实实现。而这次真核心明显跑得起来 ⇒ 没有理由退而求其次。
  ⇒ 这个"更好"的路子一开始就在仓库里（`ffi.dart` 的注释明说过 dll 在根目录时
    「命令真的走通」），我第一轮没往这个方向想。

- **给 `willSync` 做故障注入来验证判别力** —— **试了，但无效**：
  把 `willSync => _willSync ?? (enabled && passphraseSet)` 改成 `?? passphraseSet`，
  **门禁仍然全绿**。因为后端返回的 JSON 里**已经带了 `willSync` 字段**，
  `_willSync` 非空 ⇒ `??` 右侧根本不执行。
  ⇒ 换成注入 `statusLabel` 里的 `if (!enabled)` 分支，才正确变红。
  ★ 这是一条值得记的教训：**带 `??` 兜底的派生字段，注入左边可能完全没效果。**

- **只做 backend 层验证，不碰 UI** —— 否决：那样证明不了「界面会跟着变」。
  真核心 + widget 层渲染一起做，才能回答用户视角的问题。

## Consequences

### 收益

```text
· CS-1 第④步从「未验证」变成「已验证（真实现）」
· 顺带把状态机的完整四态钉住了（此前只有替身造的两种）
· 发现了 willSync 的双条件语义：光有口令不等于会同步
```

### 代价 / 新的坑（都写进测试文件头了）

```text
坑 1：口令存在**真实系统钥匙串**里，不属于数据目录
  service = dsh-media-client-credential-key，key = credentials
  ⇒ 跨用例泄漏。症状：before.passphraseSet 一上来就是 true。
  ★ 这意味着本文件**会读写开发者机器的真实钥匙串**。

★★★ 保护（Lead 裁决后加的，比"跳过"更精准）：
  setUp 里**先读一次**钥匙串原有状态，再决定动不动：
    · passphraseSet == false ⇒ 本来就没有 ⇒ touchedKeyring = true，我负责设/清
    · passphraseSet == true  ⇒ **开发者自己设的 ⇒ 立即 skip，且绝不清空**
  tearDown 只在 touchedKeyring 为 true 时才清。
  ⇒ **结构上不可能误清别人的口令**（不是靠"记得别清"，是靠标志位隔离）。

  判据：**"清空"必须只作用于"我自己设的那个口令"，不能作用于"本来就在的"。**
  ★ 为什么不用 `@Tags` 默认 skip：那会让它变成"不被跑的检查"，
    而不被跑的检查等于没有检查（本仓已记过这个形态）。
    现在的做法是"CI/干净机器上真跑，开发者有真口令时如实跳过并说明原因"。

坑 2：没 dll 时不能假装通过
  ⇒ `ensureCoreDll()` 找不到 dll 就返回 false，用例 `markTestSkipped`。
  ★ 但"skip"和"通过"必须区分：skip 的数不会混进 +N 的绿。
```

### 保护分支的实测验证

```text
① 干净钥匙串 ⇒ 真跑
   [E2E-READY] 钥匙串原本无口令 ⇒ 本次会临时设一个，并在结束时清掉
   ⇒ +2 All tests passed

② 手动种入一个口令（模拟"开发者本来就有"）⇒ skip 且不清
   [E2E-SKIP] 钥匙串里已有口令（不是本测试设的）⇒ 不清空、不覆盖，跳过本次验证
   ⇒ +0 ~2 All tests skipped

③ skip 之后**复核口令仍在**
   [AFTER-SKIP] passphraseSet=true
   ⇒ ★ 证明 skip 分支确实没有清掉别人的数据

④ 恢复干净后重跑 ⇒ 回到 +2
```

## Testing

```text
test/zz_t66_cs1_real_core_e2e_test.dart   +2 All tests passed

四态读数（真核心）：
  ① 都没开        willSync=false  "凭据未同步（未开启）"
  ② 开同步无口令   willSync=false  "凭据未同步（未设置口令）"
  ③ 开同步+口令   willSync=true   "凭据将同步（本机暂无登录态；仅上行：…；…）"
  ④ 清口令        willSync=false  "凭据未同步（未设置口令）"

故障注入：
  删掉 statusLabel 的 `if (!enabled)` 分支（模拟"只看口令就宣称会同步"）
  ⇒ **-1**（红在「关着开关时状态行不许出现"凭据将同步"」）
  还原 ⇒ +2 All tests passed

我的 9 个 CS-1 检查合计：+72 All tests passed
```

## 与既有笔记的关系

**部分重叠**：[CS-1 证据图改由 widget 层渲染产出](./2026-10-21-cs1-evidence-widget-render.md)
解决了「界面长什么样」的证据缺口；本篇解决「**交互之后状态真的变吗**」——
那是另一类缺口（静态渲染 vs 状态迁移）。

```text
那篇：静态 —— 两种状态下界面各自渲染成什么（替身造状态）
本篇：动态 —— 点按钮之后，后端状态与界面是否真的跟着变（真核心）
```

⇒ 两篇的判据对象不同（静态快照 vs 状态迁移），本篇不取代那篇。
