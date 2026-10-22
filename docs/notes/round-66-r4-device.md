# round-66 · R4 弹窗统一外壳：真机像素验收

> 本笔记只记**我在真机上量出来的像素事实**。产品代码一行没动（改动只落在
> `lib/t105_r4_dialogs_probe.dart`、`.probe/round66_r4_device/**`、本文件）。
> 发现的问题如实登记并指明由谁修，我没修。

## 1. 为什么需要这一轮

R4 把 6 处确认框从 `AlertDialog` 换成了自建外壳 `AppGlassDialog`
（`lib/design/widgets/app_glass_dialog.dart`）。`AlertDialog` 背后有 `Dialog`
（`Align(center)` + `Material` + `MaterialLocalizations`），自建外壳把这些
**都丢掉了**。而 `flutter_test` 里这两类缺失**常常不报警**：

- `MaterialLocalizations` 缺了 → 单测里 `pumpWidget` 用 `MaterialApp` 兜住了；
- `Material` 祖先缺了 → 只有真的放 `TextField` 才会炸；
- `DefaultTextStyle` 被改 → 单测不断言颜色，看不出来；
- **约束被拉成整窗** → 单测的 surface 恰好等于卡片尺寸，量不出来。

⇒ 只能真机起飞、真跑产品代码、量真像素。本轮的探针就是干这件事的。

## 2. 取证路线（为什么不截屏、不 CopyFromScreen）

| 手段 | 用不用 | 理由 |
|---|---|---|
| `CopyFromScreen` / 截桌面 | **不用** | 会把 Owner 的桌面拍进 `.probe/`（`docs/AGENTS.md` §8，2026-10-18 事故） |
| `PrintWindow` | **不用** | Flutter 窗口常返回 1×1 或全黑，`PW_RENDERFULLCONTENT` 也一样 |
| 产品自身 `RenderRepaintBoundary.toImage()` | **用** | 拿的是**产品自己渲染出来的位图**，一个屏幕像素都不碰 |

链条：

```text
外层 PowerShell（.probe/round66_r4_device/run_t105.ps1）
  ├─ APPDATA / USERPROFILE → .probe/round66_r4_device/{appdata,userprofile}（隔离）
  ├─ SOURIN_NO_REMOTE_AUTOSTART=1
  └─ build/windows/x64/runner/Release/sourin_spike.exe
        lib/t105_r4_dialogs_probe.dart
          ├─ runApp(RepaintBoundary(key:_shotKey, child: SourinApp()))   ← 产品自己的根
          ├─ 弹框：一律走产品的 showAppDialog() + 真实入口（见 §4）
          ├─ 抓图：_shotKey.currentContext.findRenderObject().toImage(pixelRatio:1)
          ├─ 量像素：_analyze()（几何 / 墨迹 / 圆角 / 对比度）
          └─ 全部写 .probe/round66_r4_device/<prefix>probe.log + <prefix><case>.png
```

- 编译：`flutter build windows --release -t lib/t105_r4_dialogs_probe.dart
  "--dart-define=DATA_DIR_OVERRIDE=<repo>/.probe/round66_r4_device/data"`
- 探针里有硬闸：`ClipDownloader.dataDir()` 不含 `.probe/round66_r4_device` 就
  `exit(3)`，绝不写 `%APPDATA%\app.sourin.player`。
- 窗口只 `show()`，**不 focus**；全程没有 `SetCursorPos` / `mouse_event` /
  `SetForegroundWindow`，不抢焦点、不点桌面。

## 3. 用例（11 条）

| # | 用例 | 触发方式 |
|---|---|---|
| 01 | 托盘关闭三键框「要关闭还是彻底退出？」 | `AppTray.instance.onWindowClose()`（真实入口；先断言 `closeAction==ask`） |
| 02 | 缓存「删除整部？」 | `CachePage` 真实页 + 点「删除」 |
| 03 | 设置·清理「清理「x」」 | `DataManagePage` 真实页 |
| 04 | 设置·删除源 | `EmbyPage` 真实页 |
| 05 | 跳过点确认（两键） | `SkipSettingsPage` 真实页 |
| 06 | 跳过点确认（单键，`cancelLabel==null`） | 同上，构造档 |
| 07 | 同步面板确认（两键） | 真实页 + 点删云端备份 |
| 08 | 同步面板确认（单键，`cancelLabel==null`） | 构造档 |
| 09 | **豁免对照**：主题「粘贴主题包 JSON」 | 真实页 + 点「粘贴 JSON」→ 产品自己的 `AlertDialog` |
| 10 | 窄视口 800×600 复核（托盘三键框） | 同 01，视口缩到 800×600 |
| 11 | **对照档**：`AppDialogShell` 玻璃档 | 直接 `showAppDialog(AppDialogShell(...))` |

未取证 1 条（**如实记账，不冒充绿**）：
`backup_panel.dart` 的「这个备份文件含登录态」三键框只由私有 `_exportConsent()`
弹出，而它要求云盘已连上且选到 `.sourin` 文件（无凭据时 `:535` 直接 return）。
探针不造云端凭据、也不复制它的 builder（复制品截出来的像素证明不了产品）。

## 4. 判据

几何（读**渲染树**的卡片 rect，再回像素验证）：

- `WIDTH` 宽度 ∈ {460, 560, 820}（§3.5 白名单；380 与 1280 都判 bad）
- `CENTER` 左右留白差 ≤2px
- `FILL` 卡片占视口 <90%（防"整屏遮罩式假绿"）
- `KEYS` 托盘三键：y 差 ≤1px、x 递增、全在卡片内
- `RADIUS` 圆角：raw + 4 标定（R20→16、R22→18 两次真机读数定标），目标 `Radii.lg`
- 窄视口：四边余量 >2px
- `SHRINK` 采样矩形内缩 1px（否则把卡片自身那 1px 描边算成墨迹 → 假红，
  2026-10-20 实测 `ringInk=408 = 460−26×2`）

像素：

- `ringInk` 卡内 10px 边环无墨迹 ⇒ 内边距没塌陷、文字没顶到边
- 颜色种数 >12、最大亮度 >40 ⇒ 不是纯黑 / 空白
- `CONTRAST` 对比度（见 §6）

硬判据：**渲染异常收集器 = 0**（`FlutterError.onError` + `PlatformDispatcher.onError`），
出现任何一条则整条验收作废。

## 5. 修前 → 修后（同一 case、同一判据、多个读数）

| 判据 | fix0（满屏，`f0cf7e0` 树） | fix1（`55df113`） | pre2（`a1523b4` + 垫层 v2） | **fix2（`cd03211`，终版）** |
|---|---|---|---|---|
| 卡片 rect | `(0,0,1280,800)` = 100% | `460×265` 居中 | `460×265` 居中 | `460×265` 居中 |
| `FILL` | 99.9% | 35.9% | 35.9% | 35.9% |
| `CENTER` | —（满屏无留白） | dx=0.0 | dx=0.0 | dx=0.0 |
| `RADIUS` | 量不到（满屏无角） | raw=18 → 22 = `Radii.lg` | raw=18 → 22 = `Radii.lg` | raw=18 → 22 = `Radii.lg` |
| 三键同排 | 一行，但面板拉满整窗 | yes | yes | yes（`dy=0.0`，全在卡内） |
| 卡底 | 页面色模糊（`#A1A9BC`） | `#A4ABBC` | `#FFFFFF` | `#FFFFFF` |
| body 对比度 | **2.01**（Lead PIL）/ **2.06**（本探针） | **2.06 BAD** | **4.74 OK** | **4.74 OK** |
| title 对比度 | 8.41（Lead）/ 8.61（本探针） | 8.61 OK | 19.80 OK | 19.80 OK |

结论链：**满屏 → 460 卡片**（`Align(center)` 那条修复，像素可证）；
**2.06 → 3.86 → 4.74**（实色垫层从无 → `surfaceContainerHighest` → `surfaceContainerHigh`）。

⚠️ 4.74 只比阈值 4.5 高 **5%**：垫层色一旦回退成 `#E4E8F0` 立刻掉回 3.86 红。

`fix2` 与 `pre2` 的 11 条读数**逐条相同**——两次构建的产品码相同（`cd03211`），
之间 HEAD 只多了文档/测试提交（`git diff cd03211..HEAD -- lib/` 为空）。
`fix2` 的意义是"在**已提交**的 SHA 上复跑"，而不是"数字变了"。

## 6. 对比度量具（本轮的第二个产物）

`_contrastOfCard()`：纯像素，不看渲染树 ⇒ 同一把尺子能复算**存档 PNG**。

- 卡底 = 全卡遍采样的众数色（5bit 量化，抗抗锯齿）
- 文字 = 文本带内**离卡底最远**的像素（取真实 RGB，不取桶中心色）
- title = 卡片上沿 +12px 以下的**第一条**文本带（12px 内是玻璃描边/高光，不是字）
- body = 其余带里墨迹量前 3 的**最差**一条（Lead 要求"多取几行取最差"，防抽样走运）
- 阈值 4.5（WCAG AA 正文）
- 已知局限：小字号下"离底最远"的像素仍可能是半覆盖的抗锯齿像素 ⇒ **偏保守**
  （真实对比度只会更好）

**量具自检（必须有判别力，OK 与 BAD 都要能出）**

```text
CONTRAST|selftest:fix1_01_glass|card=#A4ABBC|title=#0A0A0A|titleRatio=8.61|body=#737373|bodyRatio=2.06|verdict=BAD
CONTRAST|selftest:fix1_09_material|card=#FFFFFF|title=#0A0A0A|titleRatio=19.80|body=#60626B|bodyRatio=6.08|verdict=OK
SELFTEST PASS bad=0
```

`fix1_01` 是存档的**修前**图（无垫层玻璃卡），`fix1_09` 是存档的 Material 白卡。
Lead 用 PIL 量 `fix1_01` 得 2.01，本尺子 2.06（Δ0.05，卡底 `#A1A9BC` vs `#A4ABBC`）
⇒ 与外部量具对齐，且对合格图给 OK ⇒ 有判别力。

## 7. 逐图判读（人眼，`fix2_` 全套）

| case | 卡片 rect / 位置 | 卡底 | title / body 对比度 | 我看到的像素事实 |
|---|---|---|---|---|
| 01 托盘三键 | `460×265` @(410,288) | `#FFFFFF` | 19.80 / 4.74 | 三键「最小化到托盘·彻底退出·取消」同一基线、右下、全在卡内；正文四段居中；四角圆整 |
| 02 删整部 | `460×185` @(410,328) | `#FFFFFF` | 19.80 / 4.74 | 标题「删除整部？」单行；正文三行；动作「取消·删除」右下 |
| 03 清理数据 | `460×225` @(410,308) | `#FFFFFF` | 19.80 / 4.74 | 三段正文 + 动作「取消·清理」；段落间距均匀，无贴边 |
| 04 删源 | `460×205` @(410,318) | `#FFFFFF` | 19.80 / 4.74 | 插件文件名那行最长，仍在 460 内不换行截断；「取消·删除」 |
| 05 skip 双键 | `460×185` @(410,328) | `#FFFFFF` | 19.80 / 4.74 | 「取消·清除」；两行正文 |
| 06 skip 单键（构造档） | `460×205` @(410,318) | `#FFFFFF` | 19.80 / 4.74 | 只有一支「知道了」贴右下；标题前缀「(构造档)」明示非产品路径 |
| 07 sync 双键 | `460×225` @(410,308) | `#FFFFFF` | 19.80 / 4.74 | 正文含 ⚠ 提示行；「取消·删除」 |
| 08 sync 单键（构造档） | `460×185` @(410,328) | `#FFFFFF` | 19.80 / 4.74 | 只有「确定」 |
| 09 Material 对照 | `508×246` @(386,297) | `#FFFFFF` | 19.80 / 6.08 | 真点击弹出的 `AlertDialog`：小圆角（≈16px）、`TextField` 内 JSON、`取消·导入`(FilledButton)；页面底部印出隔离路径 `...round66_r4_device/data	hemes`（隔离自证） |
| 10 窄窗 800×600 | `460×265` @(170,188) | `#FFFFFF` | 19.80 / 4.74 | 四边余量 170/188/170/147 全 >0，不贴边；三键仍一行 |
| 11 外壳玻璃档 | `460×112` | `#16181E` | skipped | `AppDialogShell(glass:true)`：**整屏被它自带的 scrim 压暗**，深色玻璃卡 + 灰色文字，可读性明显低于前 10 张 ⇒ 只作 `info`，不报绿 |

**"玻璃质感"这一项的诚实结论**：前 10 张里卡底是**不透明** `#FFFFFF`，
肉眼看到的是一张白卡，玻璃折射被实色垫层压住了——这是"补垫层救对比度"的直接代价。
想要"既玻璃又可读"，需要设计侧决策（半透明垫层 + 更深的文字色），不是像素验收能定的。

## 8. 批末验收怎么跑（一条命令跑四段）

```powershell
# 四段全跑（编译 + t105 像素 + t106 r6b + t107 CS-1 + e2e 六页）
powershell -NoProfile -ExecutionPolicy Bypass -File tools/run_round66_acceptance.ps1

# 只跑 R4 像素段（不重编，复用现有 exe）
powershell -NoProfile -ExecutionPolicy Bypass -File tools/run_round66_acceptance.ps1 -NoBuild -SkipT106 -SkipT107 -SkipE2E -T105Prefix fix3_
```

- 每段的前置：`git rev-parse --short HEAD` 与工作树脏文件数写进表头；脏树不阻断，但**表里一定标出来**。
- 四段各自的红判据（任一红 ⇒ 脚本 exit 1）：T105 必须 `RESULT PASS … errors=0`；T106 必须 `结果：OK=n FAIL=0`；
  T107 必须 `cs1-report.txt` 里 `bad=0` 且 png≥5；e2e 必须六页非模态且互不相同。
- 产物：`.probe/round66_acceptance/acceptance-run.log`（整轮原文）+ 各段自己的目录。
- 脚本自带 `-SelfCheck`：不跑产品，只解析自己产出的四段日志格式，红/绿各一遍。

**为什么"产物比源码新"不做硬闸**（这条是实测逼出来的，不是放水）：

- runner `.exe` 只在 C++ runner 源码变化时重链，mtime 长期停在 2026-10-18 ⇒ 拿它判新鲜必假红；
- `data\app.so` 是内容寻址的增量产物：只改注释后跑一次真编译，`app.so` 字节不变、mtime 不动
  （实测：探针源码 18:54:13 比 `app.so` 18:19:22 新，而那次编译耗时 26 s 且成功）。
- 所以硬闸改为：**build 退出码必须 0** + **`data/app.so` 必须存在**；陈旧只打 `WARN` 并在表头
  打印 `app.so` 的 sha256，让读数能对回具体二进制。

## 9. 局限 / 未做（不许美化成"应该没问题"）

1. **玻璃的"模糊"无法用像素断言**（`GlassContainer` 的实时折射取决于背后内容）。
   判据只覆盖：底色实心度、圆角、内边距、三键排布、对比度；质感靠 2× 裁切图人眼判。
2. 第 11 条（`AppDialogShell` 对照档）圆角读数 `raw=1` 是**分类失败**
   （深色玻璃压浅页、边缘对比低），已降级为 `verdict=info`，既不报绿也不报红。
3. 第 11 条对比度 `skipped`（卡内只识别出 1 条文本带）⇒ 不计入 10/10。
4. 备份「含登录态」三键框未取证（§3 末）。
5. 只覆盖**浅色主题**（产品当前默认）。深色主题下垫层/文字换色，需另跑一轮。
6. 修前 18 张 `fix0_*.png` 里只有 `01` 救回（改名冲突丢了一半以上），
   其余修前证据靠 `fix0_probe.log` 的**文字读数**（`card rect=(0,40) 1280×760`）与 Lead 的 PIL 复核。
