# round-66 CS-1 证据目录（git 跟踪，**可复核**）

## 这里放什么

CS-1（登录态同步 / 导出导入）真机验收的截图 + 一份 `manifest.json`。
放这里而不是 `.probe/`，是因为 `.probe/` 被 `.gitignore` 覆盖、每次跑还会清
stale —— 第 66 轮 CS-1 自报「真机 56 ✓ / 0 ✗（7 张截图）」之后，盘上一张图
都找不到，那个读数只能算「自报」。

## 当前状态：**2 张，widget 层渲染**（门禁绿）

```text
cs1-sync-disabled.png   1280x900   84,060 B  口令未设置（「凭据未同步（未设置口令）」）
cs1-sync-enabled.png    1280x900   87,453 B  口令已设置（「凭据将同步：2 个源（仅上行…）」）
```

### ⚠️ 这批图**不是真机截图**

它们由 `flutter test` 里的 widget 层渲染产生（`RenderRepaintBoundary`
的 `OffsetLayer.toImage`），**不是** `sourin_spike.exe` 真窗口截屏。

```text
能证明什么：
  ✓ SyncPanel 在两种凭据状态下的**真实排版与文案**
    （含「上传的是密文，网盘那边解不开」那句关键告知）
  ✓ 状态行在「未设口令 / 已设口令」下文案确实不同
  ✓ 布局在 1280x900 下不溢出、不重叠
  ✓ ★ DPI 缩放：已量化（见下节），100%/125%/150%/175% 四档布局均正常
```

### DPI 缩放：已量化（2026-10-21）

模拟「物理屏幕 1920×1080 固定、Windows 显示缩放 100%→175%」：

```text
缩放    DPR   逻辑宽   溢出  状态行   关键告知   按钮
100%    1.00  1920    无    1 行     可见       5/5
125%    1.25  1536    无    1 行     可见       5/5
150%    1.50  1280    无    1 行     可见       5/5
175%    1.75  1097    无    1 行     可见       5/5
```

状态行 `422.9x12.0` 四档**完全一致**（它是单行短句，逻辑宽 1097 时仍富余）。

**阳性对照**（证明判据有判别力）：逻辑宽 480 时状态行变成 `396.0x24.0` → **2 行**，
探针能测出折行。⇒ 上面四档的"正常"不是探针太弱。

```text
不能证明什么：
  ✗ 真实 FFI 后端返回的数据（本批用 SourinApi 注入点造状态）
     ⇒ 由 tools/run_t107.ps1 五步驱动覆盖，读数 OK=45 BAD=0
  ✗ 真实点击链路的端到端行为
     ⇒ 同样由 run_t107.ps1 覆盖
  ✗ 字体的**真实字形**（见下节，这条比想象的严重）
```

### ★ 字体：一个必须说清的差异（2026-10-21 量化）

```text
本仓产品主题：fontFamily = TargetPlatform.windows ? 'Microsoft YaHei UI' : 'Noto Sans CJK SC'
             （lib/ui/app_typeface.dart:44）

flutter test 里 defaultTargetPlatform = **TargetPlatform.android**
             ⇒ 主题选的是 'Noto Sans CJK SC'，不是真机的雅黑

更关键：flutter_tester 的中文宽度是**固定 12.000 px/字**，
        对所有字族都相同 —— 包括 'Ahem' 和 null：
          Microsoft YaHei UI → 12.000/字
          Noto Sans CJK SC   → 12.000/字
          Roboto             → 12.000/字
          Ahem               → 12.000/字
          (null)             → 12.000/字
        ⇒ 这说明测试环境的字体回退是一条**固定度量**路径，
          `loadRealFonts` 加载的 msyh.ttc 对纯中文**没有真正生效**。
```

**这意味着什么**：

```text
· 本批图里的**字宽是等宽的**（每个汉字一样宽），而真机雅黑是比例字宽
  ⇒ 文字块的**总宽度**在真机上会有差异，可能 ±5~10%
· 但**布局结论不受影响**：状态行在逻辑宽 1097 时仍有大量富余
  （实测 422.9 宽 vs 1097 可用），即使宽度差 20% 也不会折行
· 字形细节（笔画、抗锯齿）与真机不同 ⇒ **不能拿这批图判断视觉精致度**
```

⇒ 这一条**不是"未知"了，是"已知且已量化"**：
  字宽是等宽的、与真机有差异；但**布局鲁棒性有四档 DPR 读数支撑**。

⇒ **manifest 的 `criterion` 字段已逐张写明「widget 层渲染，非真机」**，
将来有人看 manifest 不会误以为这是真机图。

真机截图仍归 `r4-device`（窗口独占）。若之后补上真机图，
**必须重新封存 manifest**（图改了不重封 ⇒ 门禁红）。

**绝对不要**为了让它变绿而手写 `manifest.json` 或塞占位图 —— 那会直接把这条
门禁变成假绿的起点（本仓明令禁止）。本批图由
`tools/e2e_shots.ps1 -ManifestOnly` 生成，非手写。

## 出图后怎么封存

两种情况都行，manifest 里会记 `commit / generatedAt / 每张的 name,w,h,bytes,sha256,criterion`：

1. 图已经躺在本目录（例如 r4-device 拷进来的真机图）：

   ```powershell
   pwsh -NoProfile -File tools/e2e_shots.ps1 `
        -OutDir docs/notes/evidence/round-66-cs1 -ManifestOnly `
        -Criterion "CS-1 登录态同步页：两源 enabled 但仅一个填了口令"
   ```

   `-ManifestOnly` 不 build、不 launch、不碰窗口。

2. 让脚本自己跑一遍抓图（会自己写 manifest.json）：

   ```powershell
   pwsh -NoProfile -File tools/e2e_shots.ps1 `
        -OutDir docs/notes/evidence/round-66-cs1 -Prefix cs1-
   ```

## 怎么验

```powershell
# ① 门禁：门禁逐张核 sha256 / 尺寸 / 条目数（红=证据与 manifest 不匹配）
flutter test test/zz_t66_cs1_evidence_manifest_test.dart --concurrency=1

# ② 像素侧：非空 / 尺寸 / 互不相同 / 不是全屏模态盖住页面
pwsh -NoProfile -File tools/verify_shots.ps1 -InDir docs/notes/evidence/round-66-cs1
```

⚠️ **不要**给第二条传 `-Tabs`：本目录的文件名不是 AppTab 名，传了会
`FAIL: requested tab 'home' has no PNG`（已实测）。

## 硬规则

- `manifest.json` 由 `tools/e2e_shots.ps1` 生成，**只增不改**；图改了必须重封。
- 目录里有图但 manifest 没登记 ⇒ 门禁红（旧图没有 sha256 就没有证据效力）。
- `-OutDir` 指到被 `.gitignore` 覆盖的路径时脚本会**拒绝写入**并打印命中的
  规则 —— 别绕。
