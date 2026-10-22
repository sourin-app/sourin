# Agent Note: 把「DPI 缩放/字体差异」从未知变成已量化

Status: implemented

## Problem

CS-1 证据图是 widget 层渲染的。README 里原本列着一条「不能证明什么」：

```text
✗ 真机窗口的 DPI 缩放 / 系统字体差异     ← 一直是「未知」
```

「未知」不能被渲染成「没问题」。但这一条**能查** —— 那就查掉它。

其余两条（真实 FFI 数据、真实点击链路）已有替代证据
（`tools/run_t107.ps1` 五步驱动，读数 OK=45 BAD=0），不需要在这里补。

## Decision

### 一、DPI 缩放：模拟「物理屏幕固定、逻辑区域变小」

```text
★ 不是「逻辑区域不变、DPR 变大」（那只是出图更清晰，布局完全一样）
  而是「物理屏幕 1920x1080 固定，只改 devicePixelRatio」：
    DPR 1.00 → 逻辑宽 1920   （Windows 100%）
    DPR 1.25 → 逻辑宽 1536   （125%）
    DPR 1.50 → 逻辑宽 1280   （150%）
    DPR 1.75 → 逻辑宽 1097   （175%）
  ⇒ 用户开 150% 缩放时，他看到的**逻辑空间真的变窄了**，这才可能挤爆布局。
```

读数（四档全部正常）：

```text
缩放   logic  溢出  状态行   关键告知        按钮
100%   1920   无    1 行     可见/未越界     5/5
125%   1536   无    1 行     可见/未越界     5/5
150%   1280   无    1 行     可见/未越界     5/5
175%   1097   无    1 行     可见/未越界     5/5
```

状态行 `422.9x12.0` 四档**完全一致**。

### 二、字体：量化出一个比预期严重的差异

```text
· 产品主题：fontFamily = windows ? 'Microsoft YaHei UI' : 'Noto Sans CJK SC'
            （lib/ui/app_typeface.dart:44）
· flutter test 里 defaultTargetPlatform = **TargetPlatform.android**
  ⇒ 主题选的是 Noto Sans CJK SC，不是真机的雅黑
· 更关键：flutter_tester 的中文宽度是**固定 12.000 px/字**，对所有字族相同：
      Microsoft YaHei UI → 12.000/字
      Noto Sans CJK SC   → 12.000/字
      Roboto             → 12.000/字
      Ahem               → 12.000/字
      (null)             → 12.000/字
  ⇒ `loadRealFonts` 加载的 msyh.ttc 对**纯中文**没有真正生效
```

⇒ 结论写进 README：

```text
· 本批图的字宽是**等宽**的，真机雅黑是比例字宽 ⇒ 文字块总宽会有差异（±5~10%）
· 但**布局结论不受影响**：逻辑宽 1097 时状态行只占 422.9（富余 60%+），
  即使宽度差 20% 也不会折行
· 字形细节（笔画、抗锯齿）与真机不同 ⇒ **不能拿这批图判断视觉精致度**
```

## Alternatives considered

- **只改 `toImage(pixelRatio:)` 模拟 DPI** —— 我第一版就这么做的，**错**：
  ```text
  t.view.physicalSize = logical × dpr  +  toImage(pixelRatio: dpr)
  ⇒ 图 = logical × dpr × dpr，内容只占左上 1/dpr
  ⇒ 看起来"右侧被裁"（我一度以为是真缺陷）
  ```
  实测推翻：同一视口下 pixelRatio 1.0/1.5/2.0 出图都**没被裁**，
  右侧纯背景列线性增长（16/24/32）。⇒ 那个"被裁"是探针的双重缩放。

- **用 `loadRealFonts` 后断言"字体已真实生效"** —— 否决理由：
  实测它对纯中文没生效（所有字族 12.000/字），断言会假绿。
  ⇒ 改成**如实记录这个差异**，而不是假装它不存在。

- **只报告"四档正常"不设阳性对照** —— 否决理由：
  四档全绿可能是探针量不到东西。实测：阳性对照（逻辑宽 480）必须测出 2 行，
  没有它，四档的"正常"不可信。

## Consequences

### 收益

```text
· README 那节从「三个未知」变成「一个已量化 + 两个有替代证据」
· DPI 缩放被固化成门禁（zz_t66_cs1_dpr_scale_gate_test.dart，5 条），可长期防退化
· 字体差异被如实记录：字宽是等宽的，与真机不同 —— 这是**已知**，不是未知
```

### 代价

```text
· widget 层的等宽字意味着**任何依赖字宽的推演都不能当真机结论**
  （例如"这句话在真机上会折成几行"）—— 好在四档 DPR 的读数显示富余很大
· 门禁里的 kStatusLineHeight = 12.0 是**实测常量**，
  改字号阶梯时必须同步改它，否则折行判据会失准
```

## Testing

```text
test/zz_t66_cs1_dpr_scale_gate_test.dart   +5 All tests passed
  100% / 125% / 150% / 175% 四档（每档 5 条判据）
  + 阳性对照：逻辑宽 480 时状态行必须折成 2 行

故障注入：
  把状态行限宽 200（模拟布局坏）⇒ **-4**（四档全红）
  还原 ⇒ +5 All tests passed
```

## 与既有笔记的关系

**无关**（Independent）：本笔记讲「widget 层渲染与真机的 DPI/字体差异有多大」，
不是「文案内容对不对」（那属于
[用户可见文案的两类缺陷](./2026-10-20-user-visible-copy-noise-and-disclosure.md)），
也不是「证据图从哪来」（那属于
[CS-1 证据图改由 widget 层渲染产出](./2026-10-21-cs1-evidence-widget-render.md)）。

理由：本笔记的判据对象是**渲染结果的保真度**，与另外两篇的判据对象
（文案内容 / 图片可信度）不同。三者会作用在同一张图上，但决策互不依赖。
