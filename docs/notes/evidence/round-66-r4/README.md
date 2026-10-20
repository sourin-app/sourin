# round-66 · R4 弹窗外壳真机像素证据（`fix2_`）

这批图是 **R4「弹窗统一外壳」在 Windows 真机上的像素证据**：15 张 PNG，全部由**产品自己的渲染结果**写成
（进程内 `RenderRepaintBoundary.toImage`，`pixelRatio: 1.0`），没有任何屏幕抓取、没有抢焦点、没有合成 OS 输入。

## 对应哪个二进制

| 项 | 值 |
|---|---|
| 产品码 SHA | `cd03211`（`fix(round-66/R4): 弹窗正文对比度 2.06→4.74（补实色垫层）+ ⑪ 对比度门禁`） |
| 封存时 HEAD | `245b214`（其后只有文档/测试提交） |
| 等价性 | `git diff cd03211..HEAD -- lib/` 为空 ⇒ 产品码未变，本批图就是 `245b214` 的产品行为 |
| 探针入口 | `lib/t105_r4_dialogs_probe.dart` |
| 探针读数 | `RESULT PASS cases=11 ok=113 bad=0 errors=0`（渲染异常收集器全程 0） |

`manifest.json` 里的 `commit` 是**封存时**的 HEAD，不是构建时的 HEAD；以上表为准。

## 复跑

```powershell
# 1) 编探针（隔离数据目录编译期写死，绝不碰 %APPDATA%\app.sourin.player）
flutter build windows --release -t lib/t105_r4_dialogs_probe.dart `
  "--dart-define=DATA_DIR_OVERRIDE=D:/WishProject/sourin-flutter-spike/.probe/round66_r4_device/data"

# 2) 跑（隔离 APPDATA/USERPROFILE，PID 差集收尾）
powershell -NoProfile -ExecutionPolicy Bypass -File .probe/round66_r4_device/run_t105.ps1 -Prefix fix2_ -TimeoutSec 240

# 3) 只重判已有图（不启动 app）
powershell -NoProfile -ExecutionPolicy Bypass -File tools/e2e_shots.ps1 -OutDir docs/notes/evidence/round-66-r4 -ManifestOnly -Criterion "..."
```

四段一把跑（R4 像素 + r6b + CS-1 + 六页非模态）：`tools/run_round66_acceptance.ps1`。

## 清单与每张图在证明什么

| 文件 | 尺寸 | 证明 |
|---|---|---|
| `fix2_01_tray_close.png` | 1280×800 | 托盘三键框 `460×265` 居中、三键同排 `dy=0.0`、`#FFFFFF` 卡底、body 对比度 4.74 |
| `fix2_card_01_tray_close.png` | 944×554 | 同上 2× 裁切：圆角、内边距、三键不裁切，人眼判质感 |
| `fix2_02_cache_delete.png` | 1280×800 | 缓存「删除整部？」`460×185`，动作「取消·删除」右下 |
| `fix2_03_data_manage_clear.png` | 1280×800 | 设置·清理数据 `460×225`，三段正文不贴边 |
| `fix2_04_emby_delete_source.png` | 1280×800 | 设置·删除源 `460×205`，最长一行（插件文件名）不截断 |
| `fix2_05_skip_confirm_2btn.png` | 1280×800 | 跳过点确认（双键档）`460×185` |
| `fix2_06_skip_confirm_1btn.png` | 1280×800 | `cancelLabel == null` 单键档 `460×205`（标题带「(构造档)」，产品当前无此调用） |
| `fix2_07_sync_confirm_2btn.png` | 1280×800 | 同步面板确认（双键档）`460×225`，含 ⚠ 提示行 |
| `fix2_08_sync_confirm_1btn.png` | 1280×800 | 同步面板 `cancelLabel == null` 单键档 `460×185` |
| `fix2_09_exempt_theme_paste_json.png` | 1280×800 | **豁免对照**：真点击弹出的 Material `AlertDialog` `508×246`，页面底部印着隔离数据目录 ⇒ 隔离自证 |
| `fix2_card_09_exempt_theme_paste_json.png` | 1040×516 | 同上裁切：小圆角 + `TextField` + `取消·导入` |
| `fix2_10_narrow800x600_tray_close.png` | 800×600 | 窄窗 800×600：`460×265`，四边余量 170/188/170/147 全 >0，三键仍一行 |
| `fix2_card_10_narrow800x600_tray_close.png` | 944×554 | 同上的裁切 |
| `fix2_11_shell_glass_corner.png` | 1280×800 | `AppDialogShell(glass: true)` 对照档（产品唯一 glass 用法是「弹幕设置」）：**整屏被自带 scrim 压暗、深色卡 `#16181E`**，只作 `info`，不报绿 |
| `fix2_card_11_shell_glass_corner.png` | 944×248 | 同上的裁切（圆角读数 `raw=1` 属分类失败，已降级 info） |

判据全文（白名单 460/560/820、居中、占屏比、圆角 `Radii.lg`、对比度、异常收集器）见
`docs/notes/round-66-r4-device.md` §4 与 §7。

## 与 `.probe/` 的关系

`.probe/round66_r4_device/` 是**工作区**（gitignored）：整轮 `probe.log`、全部 22 张（11 全图 + 11 裁切）、
隔离数据目录 `data/`、启动脚本都在那里。本目录只放**入库的终版证据**（11 全图 + 4 张裁切，共 526 KB）
与 `manifest.json`（sha256 逐张登记）。

## 未取证（如实记）

- 备份面板「这个备份文件含登录态」三键框：只由私有 `_exportConsent()` 弹出，需要已连云盘并选到
  `.sourin` 备份文件（无凭据时提前 return）。探针不造凭据、也不复制它的 builder ⇒ **未取证**。
- 深色主题下未跑（产品当前默认浅色）。
