# Agent Note: 弹窗外壳的真机像素验收要「自带量具 + 入库存档」

Status: implemented

Independent: 与 [e2e 截图落到 git 跟踪路径 + 证据 manifest 门禁](../process/2026-10-20-e2e-shots-evidence-outdir-and-manifest-gate.md)
同族（都讲「证据本身要能复核」），但那篇讲**图会消失**；本篇讲**判据本身会骗人**——
同一批图，量错节点或量错采样区，能把满屏面板判成合格卡片，也能把合格卡片判成裁切。

## Problem

R4 把 11 处 `AlertDialog` 换成自建外壳（`AppGlassDialog`）。这类改动的失效面
（`MaterialLocalizations.of` 为空、缺 `Material` 祖先、`DefaultTextStyle` 覆盖颜色）
**只在真机暴露**：`flutter_test` 全绿很常见，第 66 轮计划里这一项长期写着
「未做：真机隔离启动验收，只有单测证据」。

本轮做真机取证时，前两版量具都给出了错误结论：

```text
① 按「最大的 AppGlassDialog 元素」取 rect ⇒ 取到整屏路由根 (0,40,1280,760)
   ⇒ 每一张都判「宽 1280 ≠ 380、圆角 0、墨迹贴边」，看起来像产品全线崩了
② 采样矩形不内缩 1px ⇒ 卡片自身 1px 描边被算成墨迹 ⇒ 9 张全报「底边余量 1」
   （Lead 用 PIL 复核：y=552 那行是 (117,119,125) 的描边，不是文字）
```

两次都是**量具错、产品对**。而当时的产物形态让复核也困难：图在 `.probe/`（gitignored），
读数只有屏幕上的文字。

## Decision

1. **取证走产品自己的渲染结果**：探针 `lib/t105_r4_dialogs_probe.dart` 用
   `RenderRepaintBoundary.toImage(pixelRatio: 1.0)` 出图——不截屏、不 `CopyFromScreen`、
   不抢焦点、不合成 OS 输入。根 widget 用产品自己的 `SourinApp`，弹框走产品的
   `showAppDialog` 与真实入口（托盘三键直接调 `AppTray.onWindowClose()`）。
2. **每张图自带机器可读判据行**：`CENTER` / `WIDTH`（§3.5 白名单 460/560/820）/
   `FILL`（占屏比）/ `KEYS`（多键同排 `sameY`）/ `RADIUS`（标定后对 `Radii.lg`）/
   `ringInk`（卡片 10px 环内不许有墨迹）/ `CONTRAST`（卡底/标题/正文 WCAG 比）/
   `SHRINK`（采样内缩声明）。读数进日志，图进 `.probe/`。
3. **判据要能双向自证**：内缩修复做了反向实验——`SOURIN_T105_NOSHRINK=1` 时 9 张必须
   红回来；对比度量具用存档图做 `SELFTEST`（修前图必须 BAD、Material 白卡必须 OK）。
   量具无判别力时，绿不算绿。
4. **修前/修后成对入库**：`docs/notes/evidence/round-66-r4/` 存 15 张 + `manifest.json`
   （sha256 逐张登记），笔记 `docs/notes/round-66-r4-device.md` 给「同一 case、同一判据、
   两个读数」表。`.probe/` 里保留全量工作副本。

## Alternatives considered

- **`PrintWindow(PW_RENDERFULLCONTENT)` 从外部抓窗口**：对 Flutter 常返回纯黑/1×1；
  且它是「抓屏幕像素」路线，一旦成功就是把 Owner 桌面拍进 `.probe/`（2026-10-18 事故）。
  放弃。
- **`flutter test` + `pumpWidget` 判像素**：能跑，但默认字体没有 CJK 字形（会渲染成豆腐块），
  且它证明的是 tester 环境，不是真机——恰是本轮要证的东西。放弃作主证据。
- **在探针里复制一份 `AlertDialog(builder)`**：像素好看且"证明"了豁免档没坏，但那是
  自建进程出的图，不是产品路径 ⇒ 假证据（还让全仓 R4 门禁因裸 `AlertDialog(` 变红）。
  已删掉，改为真点击主题页「粘贴 JSON」按钮弹产品自己的框。
- **只存图不存判据行**：人眼看图能发现"满屏"，但发现不了"4.74 只比阈值高 5%"这类
  边界，也无法在改动后批量复算。放弃。

## Consequences

- 改一次产品码，`-NoBuild` 复跑探针即可得到同一把尺子的新读数；判据行进日志，可 diff。
- 已知未覆盖（笔记 §9 有完整清单）：备份面板「含登录态」三键框无法真机触发（私有点击链，
  需要真云盘凭据）；深色主题未跑；玻璃"折射质感"无法用像素断言，只能靠 2× 裁切人眼判。
- 修好正文对比度（2.06 → 4.74）的代价是垫层不透明 ⇒ 浅色主题下玻璃折射看不见，视觉上是白卡。
  这是设计取舍，不是像素验收能定的，已如实写进笔记 §7。
