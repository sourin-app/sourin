# round-66 CS-1 证据目录（git 跟踪，**可复核**）

## 这里放什么

CS-1（登录态同步 / 导出导入）真机验收的截图 + 一份 `manifest.json`。
放这里而不是 `.probe/`，是因为 `.probe/` 被 `.gitignore` 覆盖、每次跑还会清
stale —— 第 66 轮 CS-1 自报「真机 56 ✓ / 0 ✗（7 张截图）」之后，盘上一张图
都找不到，那个读数只能算「自报」。

## 当前状态：**空**（门禁红，故意的）

本目录现在没有 PNG、也没有 `manifest.json`。
`test/zz_t66_cs1_evidence_manifest_test.dart` 因此**必然红**，这是设计：
红着提醒「证据还没出」。真机出图归 `r4-device`（窗口独占）。

**绝对不要**为了让它变绿而手写 `manifest.json` 或塞占位图 —— 那会直接把这条
门禁变成假绿的起点（本仓明令禁止）。

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
