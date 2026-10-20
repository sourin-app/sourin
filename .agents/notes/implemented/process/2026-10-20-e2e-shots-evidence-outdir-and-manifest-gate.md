# Agent Note: e2e 截图落到 git 跟踪路径 + 证据 manifest 门禁

Status: implemented

Independent: 与 [e2e 工具链硬门禁与 ps1 BOM](2026-10-19-e2e-tooling-hard-gates-and-ps1-bom.md) 同族
（都讲「证据/工具本身要先可信」），但那条讲的是**脚本别静默失败**；本篇讲的是
**证据本身活过一轮就要消失**——失效形态不是红，也不是错，而是「读数无法复核」。

## Problem

第 66 轮 CS-1 报「真机 56 ✓ / 0 ✗（7 张截图）、三处注入有判别力」。
复核时按盘找证据：

```text
find . -name 't66-cs1*.png'            → 0
.probe/t66-cs1-probe/                  → 不存在
.probe/e2e/                            → 只有 3 张 danmaku-proxy 图（别的轮次）
```

**一张都没有。** 根因不是「谁删了」，而是三层设计叠起来必然如此：

```text
① .gitignore:103 `/.probe/`        ⇒ .probe 是 scratch，不进版本库
② e2e_shots.ps1 开头先清 stale      ⇒ 下一次跑把上一次的图删掉
③ git worktree remove --force      ⇒ 连 .probe 里残留的副本一起带走
```

⇒ 「56 ✓ / 7 张图」这类**真机读数天生不可复核**：图在当场是真的，跑完就没了，
后来人只有汇报者的说法。同轮还暴露第二个洞：**没有门禁**——证据消失不会有任何
东西变红，只能靠人记得去 `find`。

## Decision

### 工具侧：`tools/e2e_shots.ps1`

| 参数 | 语义 |
|---|---|
| `-OutDir`（已有，语义扩展） | 指到非 `.probe` 的 git 跟踪路径时，出图后**额外写 `manifest.json`** |
| `-Prefix`（新，缺省 `''`） | 拷贝文件名前缀；缺省值下文件名逐字不变 ⇒ 老调用点零影响 |
| `-Criterion`（新） | 写进 manifest 每条的 `criterion`（这张图证明什么） |
| `-ManifestOnly`（新） | **不 build、不 launch、不碰窗口**，只把 `-OutDir` 里已有 PNG 封存成 manifest 后退出 |

manifest 形状（`manifest.json`，**无 BOM 的 UTF-8**）：

```json
{ "commit": "<HEAD sha>", "generatedAt": "<UTC ISO8601>",
  "files": [ { "name": "cs1-01.png", "w": 800, "h": 600,
               "bytes": 63490, "sha256": "<64 hex>", "criterion": "10-②" } ] }
```

三条硬约束（都是「防再造一个 scratch / 防假绿」）：

1. `-OutDir` 落在 `.gitignore` 命中目录 ⇒ **拒绝写入**（exit 2，连目录都不建），
   并打印 `git check-ignore -v` 的实际规则行（例：`.gitignore:36:/build/`）。
2. `-ManifestOnly` 遇到空目录 ⇒ **拒绝写空清单**（否则门禁变成「0 张 == 0 条」的假绿）。
3. 正常流程里的 manifest 由**本次运行产出的条目**生成，不是目录列表 ⇒ 目录里遗留的
   旧图会变成门禁的「manifest 里没有这张」红，而不是被悄悄吸收。

### 门禁侧：`test/zz_t66_cs1_evidence_manifest_test.dart`

读 `docs/notes/evidence/round-66-cs1/manifest.json`，判据全部来自 manifest，不猜：

```text
条目数 > 0                       ← 防空转（0 张 == 0 条也是「相等」）
① 目录 PNG 数 == 条目数           ← 两个方向都查：多一张 / 少一张都红
② 逐张 sha256 与 manifest 逐字一致
③ 逐张尺寸(w,h) + 字节数一致
仪器自检：sha256(空)=e3b0c442… / sha256("abc")=ba7816bf… + PNG 尺寸解析器合成头读 3x2
```

manifest 缺失 / 目录为空 ⇒ **直接 fail**（不许 skip / return / markTestSkipped），
错误信息里写明重跑命令：

```powershell
pwsh -NoProfile -File tools/e2e_shots.ps1 `
     -OutDir docs/notes/evidence/round-66-cs1 -ManifestOnly -Criterion "<这张证明什么>"
```

## Alternatives considered

1. **继续用 `.probe/`，把数字写进文档** —— 已被证明会丢：CS-1 就是这么丢的；
   文档里的数字还可能是手抄错的（本仓有过 11 天没更新的常量）。
2. **把 manifest 手写在 `docs/` 里（人工填 sha256）** —— 人可以编，sha 对不上实物；
   门禁若只读 manifest 就变成「验证人的诚实」，不是验证证据。
3. **门禁里用 `skip` 代替 fail** —— 那就是「证据缺失也算过」，
   与 [静默 skip 比红更危险](2026-10-19-silent-skip-is-worse-than-red-in-ci.md) 同罪；
   本条门禁的价值恰恰在于**没有证据时它是红的**。
4. **manifest 从目录列表生成（而不是从本次运行产出）** —— 放弃了「旧图混进来」的检测：
   目录里多一张旧图也会被顺手登记，计数永远相等 ⇒ 判据 ① 空转。故不采用。
5. **`-Prefix` 缺省为业务名（如 `cs1-`）** —— 会静默改掉老调用点产出的文件名，
   下游按 `home.png` 等文件名取图的地方全断。故缺省 `''`，由调用方显式给前缀。

## Consequences

- **证据缺失期门禁故意红**：主树实测 `+3 -5`（3 条仪器自检绿 / 5 条正文红）。
  这是**正确状态**，不是缺陷；补齐真图后应 `+8`。已在测试文件头写明
  「不要手写 manifest、不要塞占位图」——那正是把这道门禁变成假绿的起点。
- 判别力实测（worktree + 2 张合成 fixture）：改一位 sha256 ⇒ `+7 -1`；
  删一张 PNG ⇒ 3 条红（①②③）；备份还原 ⇒ `+8` 且 `sha256sum -c` 两张 OK。
- **PowerShell 环境两个坑**（本机 `pwsh` 实为 Windows PowerShell **5.1**）：
  1. 仓内 `.ps1` 是 **UTF-8 带 BOM**；编辑工具产出无 BOM 的 UTF-8 ⇒ 5.1 按 ANSI
     解码，`Parser::ParseFile` 报几十个错、脚本整个跑不起来。改完必须重写 BOM：
     `[IO.File]::WriteAllText($p,$txt,(New-Object Text.UTF8Encoding($true)))`。
  2. `manifest.json` 必须**无 BOM**：5.1 的 `Set-Content -Encoding UTF8` 带 BOM，
     Dart `jsonDecode` 见行首 U+FEFF 直接抛 `FormatException` ⇒ 门禁红得莫名其妙。
     用 `WriteAllText(..., UTF8Encoding($false))`。
  另：5.1 没有 `[IO.Path]::GetRelativePath`（.NET Core 2.1+ 才有）⇒ 相对路径要手算。
- **已知缺陷（未修）**：从命令行传**中文** `-Criterion` 会被 5.1 控制台代码页啃成乱码。
  ASCII 字段（name / sha256 / w / h / bytes）不受影响；门禁把 `criterion` 当
  「只报告不判红」。要写中文 criterion 就用 UTF-8 BOM 的 `.ps1`/`.cmd` 调用。
- **未覆盖**：`e2e_shots.ps1` 正常流程里那段「证据模式写 manifest」本轮**没被执行**
  （要 build + 占窗口）。已实测的是 `-ManifestOnly` 与拒绝分支。⇒ 第一次用
  `-OutDir docs/notes/evidence/<round>` 出图的人要顺手确认 manifest 与目录一一对应。
- 关联工具：`tools/verify_shots.ps1 -InDir docs/notes/evidence/round-66-cs1` 可直接
  校验该目录（不硬编码 `.probe`），但它只看像素统计（非空/尺寸/互不相同/非全屏模态），
  **不知道是哪个页面、读不出文字** ⇒ 条文级读数仍要靠 `flutter test` + 人眼。
  ⚠️ 别给它传 `-Tabs`：证据文件名不是 AppTab 名，会 `FAIL: requested tab 'x' has no PNG`。
