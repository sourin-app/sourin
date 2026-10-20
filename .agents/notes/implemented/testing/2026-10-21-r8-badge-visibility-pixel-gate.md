# Agent Note: 缓存徽标的「可见性」门禁必须是像素判据，不是元素存在

Status: implemented

Independent: 与 [弹窗外壳的真机像素验收要「自带量具 + 入库存档」](2026-10-20-r4-dialog-device-pixel-acceptance.md)
同族（都讲「判据本身会骗人」），但那篇讲**量错采样区把合格判成不合格**；
本篇讲**判据的层级错位把不合格判成合格**——同一批 R8 门禁，
查的是「元素在不在」，而用户抱怨的是「看不看得见」。

## Problem

R8 修的是「缓存页整剧删除徽标对触屏/遥控永远不可见」。
修完后有两个门禁守着（`zz_t66_r8_cache_more_visible_test.dart` / `_sticky_bit_review_test.dart`），
但它们断言的全是**元素存在 + 状态位**：

```text
像素类计数（toImage|toByteData|luma|contrast|WCAG）= **0**（实测）
实际断言：expect(op, 1.0) / expect(ig, false) / debugSeenMouse / 读源码字符串
```

这在 R8 这一例上**恰好够用**，因为原缺陷是 `opacity: _hover ? 1 : 0` ⇒ 触屏 hover 恒 false
⇒ opacity **恒为 0** ⇒ 按钮「根本没画」。opacity 是 0 还是 1，元素层就能读到。

但它留下一个**层级缺口**：

```text
opacity = 0     ⇒ 根本没画     ⇒ 现有门禁抓得住（expect(op, 1.0)）
opacity = 0.1   ⇒ 画了但看不清 ⇒ **现有门禁抓不到**（op==0.1 不等于 1.0，但也不等于 0）
```

而「看不清」正是 Owner 原话「缓存删除徽标看不清」的字面意思。
⇒ 现有门禁能证明「按钮会显示」，**证明不了「显示出来看得清」**。

## Decision

1. **新增像素门禁** `test/zz_t66_r8_pixel_gate_test.dart`，读真渲染结果：
   `RenderRepaintBoundary.toImage` → `rawRgba` → WCAG 2.x 相对亮度 →
   `(L1+0.05)/(L2+0.05)`。徽标矩形从**真实 RenderBox** 读（`find.byKey` + `localToGlobal`），
   不写死尺寸（第一版写死 36.0，而真树是 28×28，几何全错）。

2. **判据分两类，缺一不可：**

   ```text
   A. 真实徽标 3 档 opacity（0 / 0.1 / 1.0）
      · opacity 0    ⇒ contrast < 1.5   （实测 1.00）
      · opacity 0.1  ⇒ contrast < 3.0   （实测 1.17）← 现有门禁的缺口
      · opacity 1.0  ⇒ contrast > 3.0   （实测 5.60）
      · 单调递增：c(0) < c(0.1) < c(1.0)

   B. 阳性/阴性对照（**独立成条，不靠注入**）
      · 已知可见（白图标 + 纯黑底）  ⇒ contrast > 3.0（实测 10.08）
      · 已知不可见（同色图标同色底） ⇒ contrast < 1.5（实测 1.00）
      ⇒ 这两条若红，说明**量具坏了**，「真实徽标通过」是假绿
   ```

   阈值全部来自实测，不是拍的。三档余量：0.50 / 1.83 / 2.60。

3. **三条自检把探针的三次设计错误变成代码：**

   | 自检 | 防的错误 | 实现 |
   |---|---|---|
   | 2a | 采样区采空（`more_horiz` 是三个点，中心 6×6 落在空隙） | `iconHits > 0` |
   | 2b | 两个采样区**几何重叠** | `kIconRadiusFraction(0.34) < kBgRadiusFraction(0.36)` |
   | 3 | 注入时同时改两个变量 | 两次注入只变图标色，底色不传 |

   ★ 自检 2b 的由来值得记：**先写的是「图标像素占比 > 0.5」，实测但它没判别力**——
   把图标半径从 0.34r 改到 0.40r（伸进纯底色环带），占比仍是 100%（more_horiz 三个点
   间隙极小，内圆盘几乎全被图标覆盖），自检照样通过。⇒ 换成**几何不相交**判据才拦得住。

4. **覆盖度必须打印**：`[R8-PIX] 采样：3 档 opacity × 1 组真实徽标 = 3 格`。

## Alternatives considered

**① 把像素判据塞进现有两个 R8 门禁** —— 否决。
那两个文件已经在守「能力判据 + 粘滞位 + listener 生命周期」，职责不同；
混进去会让「这条红是像素问题还是状态问题」难以分辨。

**② 只做注入（图标换纯黑），不做阳性/阴性对照** —— 否决。
注入验证的是「量具对变化敏感」，对照验证的是「量具在已知答案上正确」。
前者通过而后者失败是可能的（读数会变，但变的基数错）⇒ 两条都要。

**③ 用「矩形内最亮 vs 最暗」算对比度** —— 实测否决。
白图标时 max=图标、min=底色；黑图标时 max=底色、min=图标
⇒ 两次注入都读 **21.00** ⇒ 判据对注入不敏感 ⇒ 假绿。
⇒ 改成**分别采样**图标区与底色区，再算两者对比度。

**④ 真跑 worktree 里的旧代码取「改前」读数** —— 裁定不需要。
本次要证的不是「旧代码有问题」（op==0 已由现有门禁覆盖），
而是「新门禁能抓住 opacity 缺陷」—— 用参数化 3 档（含 0.1）**比旧代码更强**。
★ 但报告里写明了「这是参数化模拟不是真跑旧代码」，不伪装成真跑。

## Consequences

### 当前读数（2026-10-21，DPR=1.0，深色主题）

```text
[R8-PIX] SPLIT|POSITIVE|contrast=10.08 iconHits=69
[R8-PIX] SPLIT|NEGATIVE|contrast= 1.00 iconHits= 0
[R8-PIX] 采样：3 档 opacity × 1 组真实徽标 = 3 格
[R8-PIX] OPACITY|0.0|contrast=1.00|iconHits= 0|iconRatio=  0.0%
[R8-PIX] OPACITY|0.1|contrast=1.17|iconHits=64|iconRatio= 92.8%
[R8-PIX] OPACITY|1.0|contrast=5.60|iconHits=69|iconRatio=100.0%
[R8-PIX] INJECT|icon=BLACK|contrast=1.50 iconL=0.0000 bgL=0.0252
[R8-PIX] INJECT|icon=WHITE|contrast=5.60 iconL=0.0472 bgL=0.4943
```

### 故障注入（每条先确认 analyze 0 error）

```text
A. opacity=1.0 档图标与底色改同色（等价"画了但看不见"）
   ⇒ contrast 5.60 → **1.00**，门禁红 ✓
B. 把 0.1 档改成 1.0（消灭"看不清"这一档）
   ⇒ 单调性与「0.1 必须 < 3.0」同时红 ✓
C. 图标采样半径 0.34r → 0.40r（与底色区重叠）
   ⇒ 自检 2b 红：「Expected: a value less than <0.36> / Actual: <0.4>」✓
还原后 +4 全绿。
```

### 门禁能力的边界（必须写在纸面上）

```text
本门禁证明的是「在给定底色 + 给定透明度下，图标与底色的 WCAG 对比度」。
**不覆盖**：
· 封面是真实图片（本门禁用纯色 #6E6E78 模拟最不利情况）
  ⇒ 若某张封面恰好与徽标同色，对比度会低于本门的读数
· 不同主题（本门禁只跑深色）
· 真机 DPR（本门禁 DPR=1.0；DPR>1 时徽标 = 28×DPR 像素，抗锯齿像素占比下降，
  对比度读数可能略高）
⇒ 若要覆盖这三点，阈值需按最坏情形重新实测，不能沿用本表的数。
```

### 何时该翻案

- 若产品把徽标底色从 `black@45%` 改掉 ⇒ 本表全部读数失效，需重测
- 若 `more_horiz` 换成别的图标（笔画分布不同）⇒ 自检 2a 的 `iconHits` 基准要重测
- 若将来做真机 DPR 验证且读数与 DPR=1.0 差异 > 20% ⇒ 补 DPR 维度
