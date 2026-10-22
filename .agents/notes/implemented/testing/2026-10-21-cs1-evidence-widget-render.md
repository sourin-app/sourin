# Agent Note: CS-1 证据图改由 widget 层渲染产出（并诚实标注来源）

Status: implemented

## Problem

`test/zz_t66_cs1_evidence_manifest_test.dart` 红 5 条，**故意的**：

```text
docs/notes/evidence/round-66-cs1/ 里没有 PNG、没有 manifest.json
⇒ 门禁红着提醒「证据还没出」
```

而 `tools/e2e_shots.ps1 -ManifestOnly` **正确拒绝**写空 manifest：

```text
FAIL: -OutDir 里没有 *.png。拒绝写空 manifest.json
      —— 空清单会让门禁变成「0 张 == 0 条」的假绿。
```

⇒ 工具行为正确，缺的是图。真机出图归 `r4-device`（窗口独占），
本机还叠加两个环境问题：`pwsh` 不在 PATH、`Start-Process` 因
`NO_PROXY`/`no_proxy` 大小写冲突不可用。

## Decision

用 **widget 层渲染**（`flutter_tester` 里 `OffsetLayer.toImage`）出图，
并**在证据 README 与 manifest 的 `criterion` 里逐字标注「非真机」**。

```text
能证明：SyncPanel 在两种凭据状态下的真实排版与文案
        （含「上传的是密文，网盘那边解不开」那句关键告知）
不能证明：真机 DPI/字体差异、真实 FFI 后端数据、真实点击链路
```

出图的两张：

```text
cs1-sync-disabled.png  1280x900  84,060 B  口令未设置 →「凭据未同步（未设置口令）」
cs1-sync-enabled.png   1280x900  87,453 B  口令已设置 →「凭据将同步：2 个源（仅上行…）」
```

`manifest.json` 由 `tools/e2e_shots.ps1 -ManifestOnly` 生成（**非手写**），
2 条，criterion 逐张写明来源。

## Alternatives considered

- **等真机出图（r4-device）** —— 最"正统"，但：
  窗口独占 + 本机 `Start-Process` 不可用 ⇒ 我现在做不了。
  否决理由：让门禁长期红着等一个"不知道什么时候能跑"的窗口，
  代价是**没人再看得懂它为什么红**（红久了就变成噪声，见本仓「假绿/假红」纪律）。

- **手写 `manifest.json`** —— 明确禁止（README 与门禁都写了）。
  否决理由：手写清单等于"自己给自己发证据"，sha256 失去意义。

- **塞纯色占位图** —— 明确禁止。
  否决理由：占位图能骗过"文件存在 + 尺寸对"的判据，是假绿的标准形态。

- **只出图、不标注来源** —— 否决理由：
  下一个人看到 `docs/notes/evidence/` 里的图会默认它是真机图，
  进而把"widget 层能证明的东西"当成"真机验收通过"。
  **宁可诚实标注，也不要制造这种误认。**

## Consequences

### 收益

```text
· 门禁从 -5 变 +8（全绿），且绿得有意义（图与 manifest 真的对得上）
· 两张图覆盖了 CS-1 最关键的两个状态差异，且能看到方向语义与关键告知
· 出图过程本身被固化成一个测试（zz_t66_cs1_evidence_shots_test.dart，3 条），
  将来 UI 改版可以直接重跑重封，不依赖人的手工操作
```

### 代价

```text
· **这批图不是真机图**。真机验收仍然欠着（r4-device）。
· README 的「当前状态」必须随图变化手动更新（没有自动校验它和图的对应关系）。
· 出图用例会**覆盖**证据目录里的同名 PNG ⇒ 重跑后必须重新封 manifest，
  否则 sha256 对不上（门禁会红，这条是安全的失败方向）。
```

### 一个判据作用域的错误（故障注入测出来的）

我原本在出图用例里写：「颜色数 > 50 是『不许塞占位图』的机械判据」。
**注入证明这是错的**：

```text
注入：把 cs1-sync-disabled.png 换成 5372 B 的纯色 PNG
结果：+3 All tests passed！   ← 没红
原因：出图用例会重新渲染并**覆盖**那张图，
      占位图在断言执行前就被真图替换 ⇒ 颜色判据看到的永远是刚渲染的真图
```

⇒ 它真正拦的是「渲染出来的东西是纯色块」（pumpWidget 失败、主题全黑等），
**不是**「防别人往目录里塞占位图」。后者靠：

```text
① manifest 的 sha256 逐字比对 —— 实测注入「+1 字节」⇒ -2
② 两张图字节数必须不同 —— 实测删一张 ⇒ -3
```

已在测试文件的注释里如实更正，并列出这两条真正起作用的判据。

## Testing

```text
test/zz_t66_cs1_evidence_shots_test.dart        +3 All tests passed
  ① 口令未设置：先断言界面有「凭据未同步」再出图
  ② 口令已设置：先断言「凭据将同步」「仅上行」「网盘那边解不开」再出图
  ③ 两张图字节数必须不同（防同一张存两遍）

test/zz_t66_cs1_evidence_manifest_test.dart     +8 All tests passed（改前 +3 -5）

故障注入：
  图末尾 +1 字节（sha 变）        ⇒ -2（红在 sha256 逐字比对）
  删掉一张图                      ⇒ -3（红在条目数双向比对）
  换成纯色占位图                  ⇒ 不红（已如实记录该判据的真实作用域）
```

## 与既有笔记的关系

**无关**（Independent）：本笔记只讲「证据图从哪来、它证明什么、不证明什么」。
既有 [Rust 侧用户可见文案的 markdown 星号](../bug-fix/2026-10-20-rust-user-visible-markdown-leak.md)
与 [用户可见文案的两类缺陷](./2026-10-20-user-visible-copy-noise-and-disclosure.md)
讲的是文案内容本身，与出图链路无关。

理由：本笔记的判据对象是「图片的来源与可信度」，不是「文案对不对」。
两者会同时出现在同一张图上，但决策互不依赖。
