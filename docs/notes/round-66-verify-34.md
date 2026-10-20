# 第 66 轮：③ 弹幕代理 a+b / ④ CS-1 的**独立复核**（verify-34）

> 角色：独立复核（打假），不参与实现。**只新建本文件**，未改任何源码/测试。
> 隔离：全部真跑与故障注入都在 `/d/tmp/r66-verify`（`git worktree add HEAD`）里做，
> 主工作区此刻有别人在改 11 个 lib 文件，我一次都没碰。
> 时间：2026-10-20 15:02–15:22。

---

## 判决先行

**③ 判决：18 条真绿，注入 2 处真红（红 2 条 + 红 1 条）—— 与宣称一致。**
（口径说明：`danmaku_proxy_*.dart` 四个文件 10+2+3+3 = **18**；另有
`zz_t66_verify_danmaku_proxy_shots_test.dart` **+4** 是第五个文件，若把它也算进「代理」总数则是 22 条。
宣称的 18 只对得上前四个，**口径要对齐**，否则下轮又会抄出一个新数字。）

**④ 判决：部分成立。**
- Rust `--lib` **491 / 0 failed / 9 ignored** —— ✅ 与宣称一致。
- 「新增门禁 +34」—— ❌ 实测 **+35**（`export_import_e2e` 是 **+24**，不是 +23；`ui_flow` +4、`no_markdown_leak` +7）。**差 1 条，宣称偏低**。
- 「三处故障注入有判别力」—— ✅ 我独立复现出更硬的证据（见 §B-3：假加密注入 ⇒ **4 条真红**，含「`_v1` 解开后不是明文」）。
- 「markdown `**` 原样显示已修 + 新增门禁」—— ✅ 门禁真红（静态兜底），⚠️ 但「整棵树」那半有**覆盖缺口**（§B-4）。
- 「真机 **56 ✓ / 0 ✗（7 张截图）**」—— ❌ **不可复核**：`.probe/t66-cs1-probe` 不存在，全盘 `t66-cs1-*.png` **0 个**（§B-5）。这条目前只能算「自报读数」。

---

## A. ③ 弹幕代理 a+b（宣称：`6222428` / 18 条 / 两处注入真红）

### A-1 验了什么 · 怎么验

```bash
cd /d/tmp/r66-verify
for f in test/zz_t66_danmaku_proxy{,_req,_https,_a11y}_test.dart \
         test/zz_t66_verify_danmaku_proxy_shots_test.dart; do
  flutter test "$f" --concurrency=1      # 逐文件单跑（AGENTS：必须 --concurrency=1）
done
```

### A-2 读数（原始 `+N`）

| 文件 | 读数 |
|---|---|
| `zz_t66_danmaku_proxy_test.dart` | `+10` All tests passed |
| `zz_t66_danmaku_proxy_req_test.dart` | `+2`（真 socket：`target 端口=56078 / deadProxy=56079`，打印 `targetHits 0→1`） |
| `zz_t66_danmaku_proxy_https_test.dart` | `+3`（真 HTTPS 请求 + 代理端口 accept 计数 `accepted +0`） |
| `zz_t66_danmaku_proxy_a11y_test.dart` | `+3`（`Focus 节点数=9`） |
| **合计（前四）** | **+18** ✅ 与宣称一致 |
| `zz_t66_verify_danmaku_proxy_shots_test.dart` | `+4`（另计） |

### A-3 静态审计：有没有假绿手法

- **无 `skip:`、无 `mockito`/`MockClient`/`HttpOverrides`**（`grep` 全 5 文件 0 命中）。
- `_req` / `_https` 是**真起本地 socket + 真发请求 + 真数命中**，不是桩。
- ⚠️ **已知弱项（自述、不算隐瞒）**：`zz_t66_danmaku_proxy_a11y_test.dart:18` 的
  `_Probe` 是**同构副本**，不是产品页 ⇒ 高度≥44 / 焦点 / 回调接线这三条**不覆盖产品页**。
  但 `zz_t66_verify_danmaku_proxy_shots_test.dart:8` 文件头**明确写了这件事**，且该文件
  `:164` 起挂的是**真 `DanmakuSourcePage()`**（读真实渲染文本 + 三张图 hash 互不相等）。
  ⇒ 属于「范围受限但已披露」，不是假绿；我下面的 b 注入也证明这块**有判别力**。

### A-4 故障注入（worktree 内，注入→跑→`git checkout --`→`sha256sum` 回基线）

**注入 a（代理开关判定取反）** `lib/core/danmaku.dart:808` `resolveDanmakuFindProxy`：
`case system: return null;` → `return 'DIRECT';`

```text
sha_before = c734cd7ac5ca4e3b…
sha_injected = e62141c9ac1f4e94…
→ zz_t66_danmaku_proxy_test.dart  +8 -2
   ✗ ③ 跟随系统 ⇒ null（这是"读环境变量"的唯一表达方式）
   ✗ ④ ★★ HTTPS_PROXY 存在与不存在，三种模式的解析结果必须完全一致
（_req / _https / _a11y 仍绿 —— 它们不判定 system 的语义，符合预期）
sha_after  = c734cd7ac5ca4e3b…  ⇒ RESTORE_OK
```

**注入 b（三态 UI 核心判定改坏）** `lib/ui/settings/danmaku_source_page.dart:598`：
`if (_proxyMode == DanmakuProxyMode.custom) ...[` → `if (true) ...[`（地址框三态全显示）

```text
sha_before = 34cb1788da09a990…
sha_injected = c5d28079f28fc783…
→ zz_t66_verify_danmaku_proxy_shots_test.dart  +3 -1
   ✗ ③ 代理地址框只在 custom 下出现（防止"填了却不生效"）   ← 打在产品页上
sha_after  = 34cb1788da09a990…  ⇒ RESTORE_OK
```

**③ 结论**：两处注入都真红，且红在「用户能感知的行为」上；还原后 sha 逐位相同。
`flutter analyze` 三文件 **1 issue / 0 error**（`danmaku.dart:2014 prefer_initializing_formals`，是存量 info，与注入无关）。

---

## B. ④ CS-1 登录态同步与导出导入

### B-1 Dart 侧：逐文件真跑

```bash
flutter test test/zz_t66_cs1_export_import_e2e_test.dart --concurrency=1
# 其余 5 个同法；数据目录用 --dart-define=DATA_DIR_OVERRIDE=D:\tmp\verify34\data 隔离
```

| 文件 | 读数 |
|---|---|
| `cs1_export_import_e2e_test.dart` | **+24**（宣称 +23 ⇒ **差 1**） |
| `cs1_ui_flow_test.dart` | **+4** |
| `cs1_no_markdown_leak_test.dart` | **+7** |
| `cs1_credentials_gate_test.dart` | **+23** |
| `cs1_gitignore_guard_test.dart` | **+10** |
| `cs1_render_point_uniqueness_test.dart` | **+8** |
| **合计** | **76 全绿 / 0 红 / 0 skip** |

「三项新增门禁」实测 = 24+4+7 = **35**，计划文件写 **34**。

★ 已排除「后来加过一条」：`git log --oneline -- test/zz_t66_cs1_export_import_e2e_test.dart`
只有 `626cfdb` 一次提交；`git show HEAD:<file> | grep -c "test("` = **24**。
⇒ 不是文件长了，是计划文件 `plan-round-66.md:25` 把 24 抄成了 23。

### B-2 仪器自检（这条最关键，直接决定上面 76 条是否空转）

`test/zz_t66_cs1_export_import_e2e_test.dart:296` 有一条**硬断言**：

```dart
expect(SourinCore.isLoaded, isTrue, reason: '★ … 后面所有断言都失去意义');
```

⇒ 这 24 条**真的打在 Rust FFI 上**，不是 Dart 侧假实现。
dll 新鲜度：我用的是 `rust/sourin_core/target/release/sourin_core.dll`
（`sha256 93c9923e…`，mtime **Oct 19 21:08**），晚于 Rust 侧最后一次源码提交
`bd0ac81`（**Oct 19 08:46**）⇒ 不陈旧，符合 `docs/AGENTS.md` §8。

### B-3 Rust 侧 + 故障注入「假加密」

```bash
cd rust/sourin_core && cargo test --lib      # → 491 passed; 0 failed; 9 ignored (14.12s)
cargo test                                   # 全仓：55 个 test target，649 passed / 0 failed / 65 ignored
```

**注入（真加密 → base64 明文）** `rust/sourin_core/src/sync/credentials.rs:534`
`encrypt_bundle` 里 `encrypt(password, &plain)` → `Ok(b64_encode(&plain).into_bytes())`，
`cargo build` 出 `target/debug/sourin_core.dll`（26.8 MB，15:14）覆盖仓库根 dll 后真跑：

```text
→ zz_t66_cs1_export_import_e2e_test.dart  +20 -4
   ✗ #10-③ ★★★★ _v1 解开后**不是**明文（防"base64 一下就当加密了"）   ← 核心判据，真的会红
   ✗ #11-② ★★ 错口令 ⇒ 报错文案逐字含「口令不正确」
   ✗ #11-③ ★ 对口令导入 ⇒ 凭据真被恢复，providers == 包内 2
   ✗ #11-③ ★ 导入完成后界面那句「登录态已恢复」有真实数字可写
还原后重跑：+24 All tests passed
dll  sha 93c9923e…（回基线）  credentials.rs sha 794b127b…（回基线）
```

**判据确实齐全**（不是只在文档里吹）：
`…e2e_test.dart:516` `_v1` 合法 base64 且长度合理 / `:526` **解开后不是可读明文** /
`:588` **两次导出的密文必须不同**（随机 salt/nonce）。三条都在，且我注入后 `:526` 真红。

### B-4 markdown `**` 门禁：真的会红，但「整棵树」有覆盖缺口

**注入** `lib/ui/settings/data_manage_page.dart:342`：`Text('数据目录共占用'` → `Text('**数据**目录共占用'`

```text
→ zz_t66_md_gate_test.dart  +4 -1
   ✗ 静态兜底：这三个文件里不得再有 `**粗体**` 字面量 剥注释后仍不含成对 **
→ zz_t66_cs1_no_markdown_leak_test.dart  +7（仍绿，作用域是备份面板，符合设计）
sha_after = e6bc2c14… ⇒ RESTORE_OK
```

⚠️ **缺口（可修，不是本轮拒绝项）**：我注入的那条**在屏上是给用户看的**，但
`md_gate_test.dart` 的「① 整棵树扫描」**没红** —— 因为该测试挂的 `DataManagePage()`
在空数据目录下**根本没渲染那一行**（懒构建），所以「整棵树不含 `**`」对这行是**不可见**的。
救回来的是**静态兜底**（剥注释后扫三文件字面量）。⇒ 现实是「静态兜底在守门，渲染判据只守住
首屏那几条」。**修法**：给页面喂一条合成数据（`ClipDownloader.debugSetDataDir` 已有注入点）
让列表体真的渲染，或在静态兜底里把范围写成**白名单文件清单**而不是当前 3 个文件。

**范围与防空转（我逐条核过）**：
- 范围是**这 3 个文件**，**不是全仓**，文件头 `:12–27` **自己写明了**，并写了红线
  （`danmaku.dart` 的 `****`/`***` 是**脱敏掩码**，不许按星号数量清）。
- 防空转：`expectTreeNotEmpty` 要求 Text 条数 ≥ 3 **且**含已知文案；
  数据管理页/代理面板各有「本页特征字样」断言（代理面板只有 1 条 Text，条数门槛几乎无判别力，
  它自己也承认了 —— 这一段写得是诚实的）。
- 全仓审计工具 `zz_t66_markdown_audit_test.dart` **故意永不 fail**（只出清单）。
  我实测：扫描 **200** 个 `.dart` / **224** 条命中（已剥注释）；分桶「用户可见 8 / 日志 3 / 不确定 213」。
  这 8 条「用户可见」**全部落在 `lib/` 顶层开发探针**（`delivery_test.dart`、`t493_layout_probe.dart`、
  `t74_perf_probe.dart`、`t76_live_tab_probe.dart`、`t87_cloudsync_probe.dart`），
  我的独立抽查也确认产品路径（`lib/ui`+`lib/core`+`lib/design`+`shell.dart`）里剩下的 `**`
  只有两类：`AppLog.write` 的日志串（如 `detail_page.dart:1771`）与脱敏掩码
  ⇒ 「产品路径用户可见 = 0」这个说法**成立**。但注意：**审计工具恒绿，它不能替门禁作证**。

### B-5 真机 56 ✓ / 7 张截图：**不可复核**

```text
docs/notes/round-66-e2e-verify.md:66 / :206 / :246  声称 56 ✓ / 0 ✗，7 张 1280×800，
  路径写的是 .probe\t66-cs1-*.png（63490/89670/69275/69881/79621/71630/73696 B）
实测：
  ls -d .probe/t66*                      → 空
  find . -name "t66-cs1*"                → 0
  find /d/tmp /Temp -iname "*t66-cs1*"   → 只有 flutter_test 的临时数据目录（sourin-t66-cs1-*），无 PNG
  .probe/ 现存 PNG 只有 3 张：danmaku-proxy-{custom,direct,system}.png
```

`tools/verify_shots.ps1` 是**只读校验器**（`-InDir` 扫既有 PNG），我按只读方式跑了一次：

```text
powershell -File tools/verify_shots.ps1 -InDir .probe/e2e
danmaku-proxy-custom 43,029 B 800x600 ratio 0.995 ok
danmaku-proxy-direct 40,751 B 800x600 ratio 0.993 ok
danmaku-proxy-system 41,027 B 800x600 ratio 0.993 ok
PASS 3 image(s): non-empty, expected size, distinct, no modal overlay
```

⇒ ③ 的三张截图**在、且可复现校验**；④ 的七张**已不存在**，`verify_shots.ps1` 无法重放。
**修法**：真机取证产物要么进仓（`docs/evidence/` 这种非 ignore 路径），要么把
`verify_shots.ps1` 的输入目录固定在**不随 `.probe/` 清理而消失**的位置；否则「56 ✓」下轮同样无法复核。

### B-6 文档数字一致性

- `docs/notes/plan-round-66.md:24/25`：③ 18 条、④ 491 / +34（23+4+7）/ 56 ✓ 7 张 —— 有数字。
- `docs/round-66-owner-summary.md`：**完全没有③/④ 的任何数字**（通篇是「8 个问题」与插件统计，
  `grep -E "491|56|18 条|34|CS-1|弹幕代理"` **0 命中**）⇒ 「两份文件数字对得上」这件事**无从谈起**：
  不是对不上，而是**后者不承载这些读数**。若要对外结论可追溯，owner summary 至少要落
  「Rust 491 / 门禁 35 / 真机 56」三行，或者明确写「③④ 细节见 plan-round-66.md」。

---

## C. 汇总表

| 项 | 宣称 | 实测 | 判决 |
|---|---|---|---|
| ③ 条数 | 18 | **18**（+shots 4 单列） | ✅ |
| ③ 注入 | 2 处真红 | 2 处真红（−2 / −1 条） | ✅ |
| ④ Rust | 491 全绿 | **491** / 0 fail / 9 ignored | ✅ |
| ④ 新增门禁 | +34 | **+35**（24+4+7） | ⚠️ 差 1 |
| ④ 加密判据 | 解 `_v1` 非明文 + 两次不同 | 两条都在；假加密注入 **−4** | ✅ |
| ④ markdown 门禁 | 整棵树 + 防空转 | 静态兜底真红；**渲染判据漏了懒构建区** | ⚠️ 部分 |
| ④ 真机 | 56 ✓ / 7 张截图 | **证据文件不存在** | ❌ 不可复核 |
| ④ 文档一致性 | 两份文件对得上 | owner summary 无这些数字 | ⚠️ 无法核对 |

## D. 收尾

- 注入全部还原，sha 逐位回基线：`danmaku.dart c734cd7a…` / `danmaku_source_page.dart 34cb1788…` /
  `data_manage_page.dart e6bc2c14…` / `credentials.rs 794b127b…` / `sourin_core.dll 93c9923e…`。
- `flutter analyze`（3 个被注入文件）**0 error**（1 条存量 info）。
- worktree `git worktree remove --force /d/tmp/r66-verify`；`/d/tmp/verify34/` 已删。
- 主工作区只新增本文件；**未改任何源码/测试**。

---

# 第二轮：把我自己指名的「假绿缺口」修掉（2026-10-20 15:24–15:36）

> Lead 指令（优先级最高的「禁止假绿门禁」）：活①让 `md_gate` 的「①整棵树」自己变红；
> 活②把「审计工具」变成真门禁；活③给 `_a11y` 的同构副本写清覆盖边界。
> **只改测试文件**（`test/zz_t66_md_gate_test.dart` / `test/zz_t66_markdown_audit_test.dart` /
> `test/zz_t66_danmaku_proxy_a11y_test.dart`），产品源码零改动；注入全部在
> `/d/tmp/r66-verify2`（HEAD `f273107`）里做。

## 活① md_gate「①整棵树」——从「看不见列表体」改成「真渲染」

改法选 **(a) 真渲染**（比白名单硬：白名单只证明「文件在清单里」，证明不了文案上屏）：

```dart
await t.runAsync(() async {            // ★ AGENTS §8：pumpWidget 本身必须进 runAsync，
  await t.pumpWidget(const MaterialApp(home: DataManagePage()));  // 先 pump 再 runAsync 救不回来
  for (var i = 0; i < 60; i++) {
    if (allTexts(t).any((s) => s.contains('数据目录共占用'))) break;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await t.pump();
  }
});
```

配套：临时数据目录 + `ClipDownloader.debugSetDataDir(tmp)`（`addTearDown` 里
`debugSetDataDir(null)` 并用 `try/catch` 收拾 Windows 文件占用），放一个
`合成-第01集.mp4`（真实字节）让 `_scan()` 有东西可统计。

**读数**：`MDGATE|数据管理页 Text 条数=6`（改前列表体根本不建树），
`contains('数据目录共占用')` 真上树 ⇒ 后面那条「不含 `**`」不再是恒真。

**故障注入①（worktree 内）** `lib/ui/settings/data_manage_page.dart:342`
`Text('数据目录共占用'` → `Text('**数据**目录共占用'`：

```text
只跑「① 整棵树的 Text 都没有 **」（不带静态兜底）：
  MDGATE|数据管理页 Text 条数=6
  +1 -1: Some tests failed.
  Failing: 数据管理页：用户可见文案不带 markdown 星号 ① 整棵树的 Text 都没有 **
flutter analyze lib/ui/settings/data_manage_page.dart → No issues found!
sha e6bc2c14fe493b58… → f3762511b655f896… → 还原 e6bc2c14fe493b58…（git status 空）
```

⇒ **「①整棵树」自己变红了，不是静态兜底替它红**。活①达成。

### 顺手修掉的第二条「永远红」门禁（我自己撞上的）

在**纯净 worktree**（无 `.dart_tool` 缓存、无 `sourin_core.dll`）里跑 `md_gate` 时，
`代理面板：① 整棵树的 Text 都没有 **` **本来就是红的**：

```text
Expected: (contains '代理' or contains '代理服务')
  Actual: '直连'
```

原因：该面板折叠态的标题是 `ProxyConfig.summary`（`lib/core/models.dart:2440` → `'直连'`），
**根本不含「代理」二字**；主树之所以绿，是因为主树那台机器上该源存过代理配置、
面板走「展开态」标题（'代理'）。⇒ 这条防空转断言**依赖本机数据**：
换台机器/纯净 worktree 就恒红。**永远红和永远绿一样是废门禁**。

已改成与文案状态无关的判据：

```dart
expect(find.byType(ProxyPanel), findsOneWidget, reason: '★★ 防空转：树上没有 ProxyPanel ⇒ 挂的不是这个面板');
expect(texts, isNotEmpty, reason: '★★ 防空转：面板一条文字都没渲染');
```

## 活② 审计工具 → 真门禁

`zz_t66_markdown_audit_test.dart` 原来只 `print` 清单、**永不 fail**。新增第二条 test：

```dart
test('★ 产品路径（lib/ui + lib/core + lib/design + lib/shell.dart）用户可见 `**` 必须 = 0', () {
  // 复用同一套 scanFiles + _literalsInLine + isMarkdownBoldLiteral + _bucket
  final bad = ...where((e) => e.bucket == '用户可见');
  expect(bad, isEmpty, reason: '不合规清单：\n${bad.map((e) => '  · ${e.file}:${e.line} 「${e.text}」').join('\n')}');
});
```

口径（**必须写在测试里，否则下一个人会把 213 条「不确定」当红**）：
只有 `_bucket() == '用户可见'` 计入红；`日志` 与 `不确定` **只报告不入红**。
基线 `MDGATE|产品路径扫描 153 个 .dart：用户可见 0 条 / 日志 2 条`（日志那两条是
`AppLog.write` 与 `live_embedded_player.dart:1198` 的「预算用尽仍未见画面，但**没有**…」）。

**故障注入②（worktree 内）** `lib/ui/widgets/proxy_panel.dart:437`
`_label('代理地址', colors)` → `_label('**代理地址**', colors)`：

```text
MD|lib/ui/widgets/proxy_panel.dart:437  「**代理地址**」
MDGATE|产品路径扫描 153 个 .dart：用户可见 1 条 / 日志 2 条
+1 -1: Some tests failed.
Failing: ★ 产品路径（lib/ui + lib/core + lib/design + lib/shell.dart）用户可见 `**` 必须 = 0
flutter analyze lib/ui/widgets/proxy_panel.dart → No issues found!
sha 1ccbfae835bec506… → 030c68d37e94d54a… → 还原 1ccbfae835bec506…（git status 空）
```

⇒ 门禁有判别力，且**报错直接给出 文件:行号 + 原文**。

## 活③ `_a11y` 同构副本的覆盖边界

`test/zz_t66_danmaku_proxy_a11y_test.dart` 新增第 4 条（`+3` → `+4`）：
断言「产品页三态的覆盖者必须仍然存在且真的挂产品页」——即
`test/zz_t66_verify_danmaku_proxy_shots_test.dart` 里必须有 `DanmakuSourcePage(`
且该文件仍在库；`_Probe` 只保尺寸/焦点/A11y 语义。文件头同步写明
「本文件的 `_Probe` 不覆盖产品页；产品页三态由 shots 文件承担」。

## 主树复跑（只读校验，未改产品码）

```text
flutter analyze 三文件 → 2 issue，**全是 info**（`unnecessary_brace_in_string_interps`，
  HEAD 上本来就各 2 处，不在我新增行）⇒ 0 error / 0 warning
flutter test test/zz_t66_md_gate_test.dart --concurrency=1            → +5 All tests passed
flutter test test/zz_t66_markdown_audit_test.dart --concurrency=1     → +2 All tests passed
flutter test test/zz_t66_danmaku_proxy_a11y_test.dart --concurrency=1 → +4 All tests passed
```

## 第二轮结论

**活①②③ 全部达成，且两处注入都有判别力（红在我点名的断言上，不是靠别的断言替它红）。**
新增读数：`md_gate 4 → 5 条`、`markdown_audit 1 → 2 条`、`a11y 3 → 4 条`（净 +3 条测试）。
产品源码、`plan-round-66.md`、他人文件一律未动；worktree `/d/tmp/r66-verify2` 与
`/d/tmp/verify34/` 已删。

---

## 第三轮（2026-10-20）：复核 R4 弹窗收拢 `f0cf7e0`

### 判决（一行）
**R4 收拢真绿**：干净 worktree（无 `sourin_core.dll`）整文件 `+13 All tests passed`；两处注入各自命中**对的那条**判据；「改判」经真 `showDialog` 路由实测成立。

### 读数（命令 → 原始读数）

| 验的 | 命令 | 读数 |
|---|---|---|
| 提交口径 16 files / +354 −108 | `git show --stat f0cf7e0` | 16 files, 354 insertions, 108 deletions ✓；无禁改文件 |
| 门禁（干净环境，无 dll） | `flutter test test/zz_t66_r4_dialog_consistency_test.dart --concurrency=1` | `+13 All tests passed!`（不依赖 `sourin_core.dll`） |
| 注入 A：`lib/ui/cache_page.dart` 回退成裸 `AlertDialog(` | 同上门禁 `--plain-name "①-b ★"` | **红** `· lib/ui/cache_page.dart:builder: (ctx) => AlertDialog(` + `本次扫描了 16 处构造调用`；注入版本 `flutter analyze` = **0 error**（仅 1 warning `unused_import`）；还原后 `sha256[:16]=e9c21c1ece800e98` = 基线，`git status --porcelain` 无该文件 |
| 注入 B：删掉 `lib/ui/widgets/download_panel.dart:235` 的 `// R4-EXCEPTION:` 标记 | 同上门禁 `--plain-name "④-b ★"` | **红** `★★ 豁免「lib/ui/widgets/download_panel.dart#删除整部剧的下载？」的特征串附近**找不到**豁免注释`；还原后 `sha256[:16]=62a3c5489eb9e727` = 基线 |
| 探针文件（提交称「改后 +15 全绿」） | `flutter test test/zz_t12_cache_page_probe_test.dart --concurrency=1` | `+15 All tests passed!` ✓ |

⚠️ 注入 B 的坑（留给下一个人）：用 `--plain-name "④ ★"` 只会命中「理由不许是占位话」那条，**它在删掉标记时仍是绿的**；必须精确到 `④-b ★`。

### 外壳机制实测（真 `showDialog` 路由，不是 Scaffold 垫 Material）

| 外壳 | `Material` 祖先数 | `ListTile` | 「上移」图标 | content `textAlign` |
|---|---|---|---|---|
| `AlertDialog` | 1 | 正常渲染 | 1 | **start** |
| `AppGlassDialog` | **0** | 抛 `No Material widget found.` | **0** | **center** |

仪器自检：`DefaultTextStyle(textAlign: center)` 能让 `Text` 读到 `center` ⇒ 上面的 start/center 不是仪器读错。
`AppGlassDialog` 默认 `maxWidth 380 / maxHeight 420`（构造器实测）⇒ 480×460、420 宽确实装不下。

**对照结论**：① 改判（`settings_page#调整内容源顺序`）**成立**；⑤ 的理由（外壳把多行正文逐行居中）**成立**，且指的是 `AppGlassDialog`（`app_glass_dialog.dart` 内容区 `DefaultTextStyle` 写死 `textAlign: center`）；② 的尺寸算术**成立**。

### 问题（只报不改）

1. **豁免条数口径不一致**：`_siteExemptions` 实际 **15 条**（`grep -c "^  'lib/"` = 14 + 1 条双引号键），口头/文档称「9 处豁免」。对外应统一为 15。
2. **门禁不校验「机制」本身**：①②⑤ 的机制只写在注释字符串里；门禁校验的是「键能指到真实位置」+「理由不是占位话」，机制写反也不会红。建议把三条可测机制做成渲染判据（Material 祖先 / `textAlign` / 内容尺寸是否被压）。
3. **「图片下行缩放」目前无判据**：`zz_t12_cache_page_probe_test.dart` 的改动是**锚点迁移**（`AlertDialog`→`AppGlassDialog`、`TextButton`→`AppTextButton`），文件内 **没有** 缩放探针、也**没有**「条目尺寸 ≠ 源(222,1440)」这类断言；`grep -nE "1440|222|scale|instantiateImageCodec|decodeImage" test/zz_t12_cache_page_probe_test.dart` 无命中。⇒ 该项属**未验证**，不是「已证伪」。补法：把图片最大边长 clamp 改成不 clamp（或改成钳到源尺寸）⇒ 若判据合格必须红。
4. `AppGlassDialog` 无 `Material` 宿主，单靠 `GlassContainer`；提交注释里「补透明 Material 宿主之后才可收拢」方向正确，但**别只补注释**——补完要有判据（否则下一个人会在 Scaffold 里测出假绿，正是这次踩过的坑）。

### 边界（未做）
- 未复跑真机（禁动鼠标键盘/焦点）；未改任何产品源码与他人文件；未动 `docs/notes/plan-round-66.md`。
- worktree `/d/tmp/r66-r4` 已 `git worktree remove --force`；`/d/tmp/verify34/` 已删。

---

## 第四轮（2026-10-20）：补图片下行缩放判据 / 豁免口径对账 / 机制判据设计

### 判决（一行）
- **活①：假绿洞已补上且有判别力** —— 新判据 `test/zz_t66_image_downscale_test.dart` 现树 `+5 All tests passed`；把 clamp 拆掉后 `+2 -3`（①②④ 红、③⑤ 仍绿 = 仪器健康）；还原 `sha256[:16]=7789c93be1d4378a` = 基线，`git status` 干净。
- **活②：「豁免 9」少报 6** —— 实测**15 处**绕过外壳的构造点 ↔ 登记表**15 条**，1:1；「收 7」按文档括注是 7 个**文件**，不是 7 处。
- **活③：设计已交付，未落地成 gate** —— 注入点只能落在 `lib/design/widgets/app_glass_dialog.dart`，而本轮明令不许动它 ⇒ 落地就是一条**无法验证的判据**，不如先给写法。

### 活① 读数（可手抄复跑）

```bash
export PATH="/c/Users/iuuuuuuuu/flutter/bin:$PATH"
flutter test test/zz_t66_image_downscale_test.dart --concurrency=1
```

现树（绿）：
```text
DS|dpr=3.0 kCoverDecodeMaxPx=4096
DS|coverDecodeHeightFor(148x223)=669
DS|coverImage(width).provider=ResizeImage()
DS|coverImage(height).provider=ResizeImage()
DS|222x1440 -> targetH=223 => 34x223        ← 比例 34/223=0.1525 ≈ 222/1440=0.1542 ✔
DS|800x6000 -> targetH=4096 => 546x4096     ← ★最大边长真的被 clamp（不是源 6000）
DS|instrument: raw => 800x6000              ← 仪器自检：裸解码拿到真尺寸
+5 All tests passed!
```

注入（在 worktree `/d/tmp/r66-v4`，把 `lib/ui/widgets/cover_image.dart` 两处 `.clamp(1, kCoverDecodeMaxPx)` 改成 `.clamp(1, 1 << 22)`，`flutter analyze` 0 issue）：
```text
① 布局宽 1e6×dpr 必须被夹回上限，而不是原样返回        [E]
② ★ 接线断了：解码宽直接吃未夹的布局宽                  [E]
DS|800x6000 -> targetH=300000 => 800x6000   ← ★上限没生效，解出源尺寸
④ ★ 上限没生效：解出来会是源 6000 ⇒ 内存白付            [E]
⑤ instrument: raw => 800x6000               ← 仍绿（仪器没坏，红的是判据不是环境）
+2 -3: Some tests failed.
```
还原后 `sha256[:16]=7789c93be1d4378a`（基线同名值），`git status --porcelain lib/ui/widgets/cover_image.dart` = 0 行；worktree 已 `remove --force`。

为什么这条判据不是重复劳动：`test/t74_cover_image_test.dart` 的 A1–A5 钉的是 `coverDecodeWidth` 的**逐值**、B2 钉的是 `ResizeImage.width/height` 的**契约**；没人证明过「真解码出来的位图**真的**变小了」。新文件补的正是这一段，并且带 ⑤ 防空转自检（否则「变小」可能只是解码器给不出尺寸的假象）。

### 活② 对账表（15 条，1:1 对应 15 处绕过外壳的构造点）

跑法（worktree 里临时给门禁插桩，只为了拿映射，主树未改）：
`flutter test test/zz_t66_r4_dialog_consistency_test.dart --concurrency=1 --plain-name "①-b ★"` ⇒ 打印 15 行 `EXMAP|文件:行|命中的键`。

| # | 键（`_siteExemptions`） | 源码命中 | 机制 | 来源 |
|---|---|---|---|---|
| 1 | `settings_page.dart#这一处**刻意保留** Material` | settings_page.dart:2262 | ②（TextField 需 Material；轨道 E 实测） | 遗留 |
| 2 | `t104_overlay_exit_probe.dart#真机探针，验证统一入口本身` | :301 | 无（故意测统一入口） | 遗留 |
| 3 | `theme_page.dart#contentPadding: EdgeInsets.zero` | :199 | 无标号（内边距写死 + 无 backgroundColor 参数） | 遗留 |
| 4 | `theme_page.dart#粘贴主题包 JSON` | :269 | ④+②（SizedBox 460 / 2×TextField） | 遗留 |
| 5 | `sync_panel.dart#配置云盘（WebDAV）` | :1187 | ④+②（SizedBox 420 / 4×TextField） | 遗留 |
| 6 | `settings_page.dart#调整内容源顺序` | :6648 | ②（**2026-10-20 改判**；ListTile 缺 Material ⇒「上移」=0） | 遗留（键）+ 改判（理由），本轮已实测证实 |
| 7 | `settings_page.dart#插件更新 · ` | :6933 | ①（480×460 > 380/420） | 遗留 |
| 8 | `settings_page.dart#配置「` | :7293 | ①（420 > 380） | 遗留 |
| 9 | `tvbox_source_panel.dart#订阅更新 · ` | :268 | ④+②（560×480 / TextField） | 遗留 |
| 10 | `backup_panel.dart#title: const Text('设置导出用口令')` | :1407 | ②（TextField） | **f0cf7e0 重写**（原键指不到） |
| 11 | `backup_panel.dart#这个备份包含登录态` | :1500 | ②（TextField）⚠️ 与提交信息说的「机制⑤」不一致 | 遗留 |
| 12 | `provider_login_panel.dart#constraints: const BoxConstraints(maxWidth: 460)` | :1379 | 改判「**不属于**②」（裸 `Dialog` 自建外壳） | **f0cf7e0 重写**（原键指不到） |
| 13 | `download_panel.dart#删除整部剧的下载？` | :234 | ③（内联红字被 DefaultTextStyle 冲掉） | 遗留 |
| 14 | `sync_panel.dart#width: 380,` | :1426 | ④+②（SizedBox 380 / 3×TextField） | 遗留 |
| 15 | `backup_panel.dart#builder: (ctx) => AlertDialog` | :603 | ⑤（多行左对齐清单被居中） | **f0cf7e0 新增** |

**9 vs 15 的差额从哪来**：任何一版登记表都不是 9 条——
```text
626cfdb: 0 条（该文件还没有这张表）
eee6a5e: 14 条
f0cf7e0: 15 条（+3 改写/新增、−2 被改写的旧键消失 ⇒ 净 +1）
```
⇒「豁免 9」**既不是行数、也不是文件数**（涉及 8 个文件：settings_page 4 / backup_panel 3 / theme_page 2 / sync_panel 2 / tvbox 1 / download_panel 1 / provider_login_panel 1 / t104_probe 1），而是**少报 6 处**。
「收 7」在文档里括注了 7 个文件名（app_tray/cache_page/data_manage/emby/skip/sync/download），那是**文件数**；实测 `AppDialogShell(` 在 `lib/`（除 `lib/design/`）有 **11 处构造点**（含更早轮次）。两个数不可互换。
**建议对外统一口径**：`收拢 11 处 / 豁免 15 处 / 当前仍绕过外壳的构造点 15 处（与登记表 1:1）`，并标注「按处」「按文件」分开说。

### 活③ 机制变成渲染判据：写法（本轮不落地）

三条机制都能测，但**必须相对外壳上限、不许写死 380/420**（r4-finish 正在把默认值改到 460/620 并加 `Align(center)`）：

```dart
// ①② 从树里读外壳**自己声明的**上限，而不是抄常量
final shell = tester.widget<AppGlassDialog>(find.byType(AppGlassDialog));
final limitW = shell.maxWidth, limitH = shell.maxHeight;

// 机制②（缺 Material 祖先）：真实 showDialog 路由下放一个 ListTile
//   判据 = 「不抛异常」＋「上移按钮数 > 0」；不判 Material 计数
//   （r4-finish 加透明 Material 宿主后计数会变，但"能渲染"永远该成立）
expect(tester.takeException(), isNull);
expect(find.byIcon(Icons.arrow_upward).evaluate(), isNotEmpty);

// 机制③/⑤（textAlign 被覆盖）：读渲染出来的段落对齐
final p = tester.renderObject<RenderParagraph>(find.textContaining('·'));
expect(p.textAlign, anyOf(TextAlign.start, TextAlign.left));

// 机制④（尺寸被压）：内容请求 800×900，断言被压到「外壳上限」而不是某个魔数
final box = tester.getSize(find.byKey(const ValueKey('probe-content')));
expect(box.width, lessThan(800));            // 真的被压了
expect(box.width, lessThanOrEqualTo(limitW)); // 且压到的是它自己声明的上限
expect(box.height, lessThanOrEqualTo(limitH));
```
落地时机：等 r4-finish 的 `app_glass_dialog.dart` 停手后再写（本轮禁止改该文件 ⇒ 无法做「注入→红→还原」验证，落了就是不可验证的判据）。

### 边界（未做）
- 未改 `lib/design/widgets/app_glass_dialog.dart`、`lib/t105_r4_dialogs_probe.dart`；未 build windows exe（避免与 r4-device 抢 `build/`）。
- 未改 r4-finish 的门禁文件（worktree 里的插桩与注入已随 worktree 移除）。
- 新增文件只有 `test/zz_t66_image_downscale_test.dart` 与本笔记；worktree `/d/tmp/r66-v4` 已移除，`/d/tmp/verify34/` 已删。

---

## 第五轮（2026-10-20）：复核 `55df113`（P1：弹窗满屏 + 默认 460/620）

**跑法**：主树此刻是**脏的**（`lib/design/widgets/app_glass_dialog.dart`、`lib/ui/widgets/app_dialog_shell.dart` 正被 r4-finish 改圆角；`player_page/player_bottom_bar` 是 r6b-live 的未提交改动）⇒ 全部读数取自干净 worktree `git worktree add /d/tmp/r66-v5 55df113`。

### 活① 基线（worktree @55df113，非主树）
```bash
flutter test test/zz_t66_r4_dialog_consistency_test.dart --concurrency=1   # +13 All tests passed!
flutter test test/zz_t66_glass_dialog_test.dart --concurrency=1            # +28 All tests passed!
```
⑧ 组实测读数（1280×800 视口）：
```text
[GLASS4] ⑧ rect=Rect.fromLTRB(410.0, 329.5, 870.0, 470.5) w=460.0 h=141.0
[GLASS4] ⑧ 默认宽=460.0 高=141.0
[GLASS4] ⑧ card=Rect.fromLTRB(410.0, 309.5, 870.0, 490.5)
         三键=[(610→694), (722→778), (806→834)]  三键 center.dy 全 = 450.5 ⇒ 真同排
```
⇒ 自报 `+13` / `+28` **成立**，且修前那条 P1（卡片铺满整窗）确已消失。

### 注入 a：`maxWidth 460→380`、`maxHeight 620→420`（worktree 内，`flutter analyze` 0 issue）
```text
INJ-A sha: 82f4938d5aec378e
[GLASS4] ⑧ rect=... w=380.0 h=141.0
[E] ⑧ 默认宽度 ∈ §3.5 白名单 {460,560,820}，且等于窄弹窗档 460
+27 -1: Some tests failed.
```
还原后 `sha256[:16]=e9ee836a33e50d83`（=基线），`git status --porcelain` 0 行。⇒ **与自报 `+27 -1` 一致**。

### 注入 b：拆掉 `Align(center)` 那一层（`child: Align(`→`SizedBox(` + 删 `alignment:`，analyze 0 issue）
```text
INJ-B sha: 7b477d6e48b32893
[GLASS4] ⑧ rect=Rect.fromLTRB(16.0, 16.0, 1264.0, 784.0) w=1248.0 h=768.0   ← ★又铺满整窗
[E] ⑧ 1280×800 视口：宽度非满屏 + 水平居中 + 两侧留白 > 0
[E] ⑧ 默认宽度 ∈ §3.5 白名单 {460,560,820}，且等于窄弹窗档 460
+26 -2: Some tests failed.
```
还原后 `sha256[:16]=e9ee836a33e50d83`，`git status` 0 行。⇒ **与自报 `+26 -2` / `1248×768` 一致**。

### 活① 注入 c：把托盘的**三键文案人为加长**（改测试夹具，不改产品码）
```text
[E] ⑧ 三键同排（最小化到托盘 / 彻底退出 / 取消）在 460 宽下不溢出
    ★ 三键同排在 460 宽下不许溢出        ← takeException 抓到 RenderFlex overflow
[GLASS4] ⑧ card=(410→870) 三键=[(446→642), (670→852), (880→964)]   ← 第 3 键右 964 > 卡右 870
+27 -1: Some tests failed.
```
⇒ 这条断言**有判别力**：每键加长 ~8 字就红。夹具还原后 `git status` 0 行。

### 活① 断言写法判读（⑧ 第二组是「钉规范」还是「钉巧合」？）
实际写法（`test/zz_t66_glass_dialog_test.dart`，⑧ 第二组）：
```dart
expect(const [460.0, 560.0, 820.0], contains(rect.width), reason: '★ §3.5：宽度只允许 460/560/820（380 是拍出来的数）');
expect(rect.width, 460, reason: '★ 确认框 = §3.5 的「窄弹窗」档 ⇒ 460');
expect(rect.height, lessThanOrEqualTo(620));
```
⇒ **数值是写死的**（460 出现两次、620 作为上限），**不是**跟 `AppGlassDialog.maxWidth` 联动算出来的。
- 判它属于「**钉规范**」：注释里给了规范出处（AGENTS §3.5：560 默认 / 460 窄 / 820 宽），不是从实现里抄回来的观测值；而且白名单三选一 + 再收窄到 460 是**两条独立断言**，改回 380 时正是第二条红（注入 a 实测）。
- 代价（可接受，但要知道）：**以后改默认值必须同时改测试**，否则红得像 bug。
- 另：它**没有**读 `maxWidth` 字段 ⇒ 想「跟实现联动」是做不到的（那才会让注入 a 变绿 = 没判据）。所以现状是**对的取舍**。
- `④-c` 的 `332 → 412`：实测 = `460−48`（左右各 24 padding），但它写成 `expect(rect.width, 412)` 一类的**字面量**，同样属钉规范。

### 活② 「变宽不会引入水平溢出」——实测（worktree 内临时 harness `test/tmp_v34_width_test.dart`，随 worktree 删除）
夹具逐字取自产品源码（harness 里有一条 `test('夹具必须逐字来自产品源码')` 断言 `lib/core/app_tray.dart` / `lib/ui/settings/emby_page.dart` 里真含那些文案与 `confirmLabel: '删除'` ⇒ 防同构副本漂移）。

```text
托盘三键：card 宽 × 高 | 内容 宽×高 | 三键宽 | 三键跨度 | 三键 center.dy
W380  card=380x261 | content=332x140 | btns=84,56,28 | span=224 | 行=498/498/498   ✔ 不溢出/同排/未裁切
W460  card=460x261 | content=412x140 | btns=84,56,28 | span=224 | 行=498/498/498   ✔（= 现默认）
W820  card=820x221 | content=772x100 | btns=84,56,28 | span=224 | 行=478/478/478   ✔ 但**高度从 261 掉到 221**
W260  card=260x321 | content=212x200 | btns=84,56,28 | span=224 | 行=528/528/528   ✘ `★ w=260 三键溢出` ←仪器灵敏度对照

emby 最长正文：card | 标题 | 正文 | 取消/删除 的 dy
E380  card=380x302 | title=332x42 | content=332x160 | 518/518   ✔
E460  card=460x262 | title=412x42 | content=412x120 | 498/498   ✔
E820  card=820x201 | title=772x21  | content=772x80  | 468/468   ✔（标题到 820 才单行）
E260  card=260x343 | title=212x63  | content=212x180 | 539/539   ✔（正文先换行，未溢出）
```
**结论**：
1. 这两处「上限变大 ⇒ 不引入水平溢出」**实测成立**（380/460/820 三档 `takeException()==null`、三键同排、全部落在卡片内）。
2. 但**形状确实会变**：宽度变大⇒行数变少⇒**高度变小**（托盘 261→221、emby 正文 160→120→80、标题 42→21）。所以它那句推理「不可能让原来装得下的内容装不下」只在**水平方向**成立，**不能说「什么都不变」**；也不能从这 2 处推广到 10 处。
3. `W260` 对照证明我的量具**能红**（三键跨度 224 > 卡内宽 212）⇒ 上面三个 ✔ 不是空转。

### 活③ 三个口径数（@`55df113`，worktree 内实测）
| 口径 | 实测 | 怎么数的 |
|---|---|---|
| 收拢 `AppDialogShell(` 构造点 | **11** | `grep -rn "AppDialogShell(" lib/ --include=*.dart \| grep -v "^lib/design" \| wc -l` |
| 豁免登记表条数 | **15** | 解析 `_siteExemptions`（现为 `Map<String,String>` 键→理由）键数 |
| 仍绕过外壳的构造点 | **15**，**漏网 0** | worktree 里给 ①-b 插桩打点，实跑：`SCANNED_TOTAL=15 registry=15`，15 行全部 `hit=Y` |
```text
BYPASS|lib/t104_overlay_exit_probe.dart:301|Y      lib/ui/settings/theme_page.dart:199|Y / :269|Y
       lib/ui/settings_page.dart:2262|Y / 6648|Y / 6933|Y / 7293|Y
       lib/ui/widgets/backup_panel.dart:603|Y / 1407|Y / 1500|Y
       lib/ui/widgets/download_panel.dart:234|Y      provider_login_panel.dart:1379|Y
       sync_panel.dart:1187|Y / 1426|Y                tvbox_source_panel.dart:268|Y
SCANNED_TOTAL=15 registry=15
```
⇒ 三个数**互相对得上**：收拢 11 处 / 豁免 15 处 / 仍绕过 15 处（1:1，漏网 0）。对外可以照这个讲，**但必须标「按处」**。

**发现的文档缺陷（只报不改，归 r4-finish）**：`test/zz_t66_r4_dialog_consistency_test.dart:85-88` 那句
> 「复核复刻本门禁口径…实跑 ⇒ **16 处**；注册表 16 条 ⇔ 门禁 16 处 ⇒ 当前自洽。⇒「22」已作废，别拿它对账（下面 `_siteExemptions` 那句也要按 16 读）」

**与实数不符**：实跑 `scanned=15`、表 `15` 条。⇒ 那段的「16」两处都该改成 **15**，否则下一个人照它写对账又会错一位。（「22 已作废」这个动作本身是对的。）

**上轮我提的那处矛盾已不成立（我上轮误判，这里更正）**：`backup_panel#这个备份包含登录态` 的登记理由现在明写「机制②…`_ImportPassphraseDialog`（有 TextField）」，并专门注明：
> 本条 = `title: const Text('这个备份包含登录态')`（有输入框）⇒机制②；另一条 = `title: const Text('这个备份文件含登录态')`（StringBuffer 清单，无输入框）⇒机制⑤，**两条是两个不同的弹窗**。

⇒ 我上轮把「两个只差一个字的标题」当成同一处 ⇒ **是我搞混了**，标签与说明现在是自洽的。

### 活④ CS-1「7 张截图 / 56 ✓」证据缺口的定性（只定性，不重跑）
**1) 现状（我亲手查）**
```text
find /d -maxdepth 5 -name "t66-cs1*"        ⇒ 0 个
ls .probe | grep -i t66                     ⇒ 空（连 t66-cs1-data 目录也没有）
find .probe -name "*.png" | wc -l           ⇒ 44 张（不是 3 张；我上轮只看了 .probe/e2e）
.probe 现存 png 的时间跨度                    ⇒ 2026-10-19 20:45 … 2026-10-20 16:36（现在仍在增长）
```
**2) 不是「谁把 .probe 清了」**：`.probe` 里 20:45 之前的图（danmaku-proxy 三张）**还活着**，而 CS-1 自报是 10-19 21:xx 之后跑的 ⇒ 若发生过整目录清理，先死的该是旧图。⇒ **CS-1 那 7 张从来没落在 `.probe\t66-cs1-*.png` 这两个路径上**（或写入后被单独删且全盘无副本）。
**3) 为什么会这样（根因，三个机制叠加）**
- `.gitignore:103 /.probe/` ⇒ 该目录**根本不进库**，从创建那刻起就不受 git 保护（`.gitignore:100` 自己写着「一次性探针目录」）。
- `tools/e2e_shots.ps1` **每次开跑先清 stale**：`$stale = Get-ChildItem $probeDir -Filter 'tabshot_*.png'; $stale | Remove-Item`（:403-406），且 `-OutDir` 默认就是 `.probe/e2e` ⇒ 证据目录按设计是**可回收的暂存区**。
- 另一个高概率机制（本轮无法证伪，需 r4-device 以后避免）：**图落在 worktree 里的 `.probe/`**——`git worktree remove --force` 会把 worktree 内未跟踪文件一起删掉，静默无声。本团队每轮都在建/删 worktree。
- 反证「图是产品渲染」这一条也做不到：AGENTS §8 明令 `.probe` 里的 png 必须是产品自身渲染（禁 `CopyFromScreen`），而这些图既无来源记录也无 sha256 清单。
**4) 方案：把证据落到 git 跟踪的路径（建议下一步就这么做）**
```text
docs/notes/evidence/round-66-cs1/            ← 7 张 png（git 跟踪，不进任何 ignore）
docs/notes/evidence/round-66-cs1/manifest.json
   { "commit": "<被测 sha>", "capturedAt": "...", "surface": "1280x800",
     "shots": [ { "file": "01-export-done.png", "bytes": 63490, "sha256": "...",
                  "criterion": "10-②", "expect": "已导出到 … 已加密；导入时要口令" } ] }
```
- 出图直接落该目录：`pwsh tools/e2e_shots.ps1 -Tabs home -OutDir docs/notes/evidence/round-66-cs1`（`-OutDir` 支持相对 root 的路径，**不用改脚本**；⚠️ 脚本开头只清 `tabshot_*.png`，所以证物要**改成业务名**再拷进该目录，别用 `tabshot_` 前缀）。
- 只读复跑校验：`pwsh tools/verify_shots.ps1 -InDir docs/notes/evidence/round-66-cs1`（非递归，校验非空/尺寸/同批次不同图/非整屏弹窗覆盖）＋ 逐文件 `Get-FileHash -Algorithm SHA256` 与 manifest 比对。
- **加一条防消失门禁**（治根）：CS-1 测试里断言「笔记声称 N 张证据 ⇒ `docs/notes/evidence/round-66-cs1/` 必须真有 N 个文件，且 sha256/字节数与 manifest 全等」⇒ **证据缺失本身变红**，而不是靠人记得去 `find`。
**5) 重跑一次真机取证需要的前置（派给 r4-device）**
- 构建：`flutter build windows --release` + 从 `rust/sourin_core/target/release/` 拷 `sourin_core.dll`（**先核版本新鲜度**：主树根目录那份 `sourin_core.dll` 的 sha256 曾与 release 产物不一致，属 AGENTS §8 的坑）。
- 隔离数据目录：用 `e2e_shots.ps1` 的隔离 env（它自建 `$script:DataDir` 并在结束 `Remove-Item`），**别**用真实 `%APPDATA%`；`-DataDir` 也要指到 git 外（或 `.probe` 之外）以免污染。
- 交互：seed `appupdate.autoCheck=0`（脚本已断言，否则会拍到「发现新版本」弹窗——本仓 10-19 就发生过这种假图）；导出→设口令→导入→错口令→对口令这 5 步需要真实输入，e2e_shots 只能做到**页签级**，到不了深层弹窗 ⇒ 这部分要靠探针（`lib/*_probe.dart` 走 `RenderRepaintBoundary`）驱动 + 留 7 张图。
- 验收：`verify_shots.ps1` 绿 + manifest 核对 + 人眼看图（判据 10-②/11-①②③ 的界面逐字只能人眼/OCR 确认）。

---

# 第六 / 七轮（2026-10-20）：把「证据不可复核」做进工具与门禁

> 派活：Lead 第 7 轮续派（第 6 轮我崩在收尾前，`tools/e2e_shots.ps1` 一字节未改 ⇒ 原样重派）。
> 边界：**不许 build / 不许跑真机 / 不碰 `build/` / 不占窗口**（r4-device 在跑）。真机出图归 r4-device，我只负责「让它下次出图必然可复核」。

## 判决
- **任务 A（`-OutDir` 落到 git 跟踪路径 + manifest + 拒绝 ignore 目录）：达成**，三条实跑读数见下；缺省行为逐字不变（`-Prefix` 缺省 `''` ⇒ 文件名仍是 `<tab>.png`，默认 `.probe/e2e` 不会新增任何文件）。
- **任务 B（会红的证据门禁）：达成**，主树现在 **`+3 -5`（故意红，错误信息里带重跑命令）**；worktree 里塞真 fixture 后 **`+8` 全绿**，改一位 sha ⇒ **`+7 -1`**，删一张图 ⇒ **3 条红（① ② ③）**，还原 ⇒ **`+8`**。
- **任务 C（只读复核 `verify_shots.ps1`）：可直接用，不用改**。`-InDir docs/notes/evidence/round-66-cs1` 实测 PASS；但**不能传 `-Tabs`**（见下）。

## 任务 A：`tools/e2e_shots.ps1`

### 改了什么（4 处，全部向后兼容）
1. 新增 `-Prefix`（缺省 `''`）：拷贝名从写死 `"<tab>.png"` 变成 `"$Prefix<tab>.png"`。缺省值下**逐字相同** ⇒ 老调用点零影响。
2. 新增 `-Criterion`：写进 manifest 每条的 `criterion`。
3. 新增 `-ManifestOnly`：**不 build、不 launch、不碰窗口**，只把 `-OutDir` 里已有的 `*.png` 封存成 `manifest.json` 后 `exit 0`。这条是给 r4-device 的真机图用的（他们的图不是本脚本抓的）。
4. `-OutDir` 不在 `.probe` 下时：先过 `git check-ignore -v --no-index`，命中就 **`FAIL` + 打印命中的规则**（exit 2，连目录都不建）；通过则在本脚本正常流程末尾额外写 `manifest.json`。

### 三条实跑读数（本机是 **Windows PowerShell 5.1**，不是 pwsh 7）
```
smoke A  合成 64x32 PNG → -OutDir D:\tmp\verify34\ev -ManifestOnly
         OK manifest.json (1 张) / task-a-smoke.png 64 x 32 195 B 83E09948CDBBAC72 / EXIT=0
         → {"commit":"65e1694c…","generatedAt":"2026-10-20T09:27:01Z",
            "files":[{"name":"task-a-smoke.png","w":64,"h":32,"bytes":195,
                      "sha256":"83e09948…1187","criterion":"…"}]}   首字节 7b（无 BOM）

smoke B  -OutDir build/e2e-shots（非 .probe 且被 ignore）
         FAIL (before any build/launch): -OutDir 命中 .gitignore ⇒ 拒绝写入
           dir  : build/e2e-shots
           rule : .gitignore:36:/build/	build/e2e-shots
         EXIT=2；目录**没有被创建**

smoke C  -OutDir docs/notes/evidence/round-66-cs1（空目录）
         FAIL … 里没有 *.png。拒绝写空 manifest.json —— 空清单会让门禁变成「0 张 == 0 条」的假绿
         EXIT=2；manifest.json **没有被写出**
```
`docs/notes/evidence/round-66-cs1` 本身 `git check-ignore` **不命中**（trackable）✓（根 `.gitignore:118 /*.png` 只管仓库根，管不到 `docs/` 下）。

### 三个踩坑（都已修，但下一个人会再踩）
1. **本机 `pwsh` 工具其实是 Windows PowerShell 5.1**（`PSVersion=5.1.19041 ESdition=Desktop`）⇒ `[System.IO.Path]::GetRelativePath` 不存在（.NET Core 2.1+ 才有），第一版直接 `MethodNotFoundException`。改为手算 `Substring` 相对路径。
2. **本仓 `.ps1` 是 UTF-8 **带 BOM**，而 `edit`/`write` 工具写出来是无 BOM 的 UTF-8** ⇒ 5.1 按 ANSI 解码中文，`Parser::ParseFile` 直接报 45 个错（`Unexpected token '}'`、`寮?` 乱码），**脚本整个跑不起来**。每次编辑后必须重写 BOM：
   `[IO.File]::WriteAllText($p, $txt, (New-Object Text.UTF8Encoding($true)))`。**这是我的交付物差点坏掉的地方，写进笔记。**
3. **manifest.json 必须写无 BOM UTF-8**：PS 5.1 的 `Set-Content -Encoding UTF8` 带 BOM，Dart `jsonDecode` 见 U+FEFF 直接抛 `FormatException` ⇒ 门禁会红得莫名其妙。改用 `WriteAllText(..., UTF8Encoding($false))`。
4. 已知小缺陷（**没修，只报**）：从命令行传中文 `-Criterion` 会被 5.1 控制台代码页啃成乱码（实测 `CS-1 fixture锛堝悎鎴愬浘…`）。ASCII 字段（name/sha256）不受影响，门禁也把 `criterion` 当「只报告不判红」。要写中文 criterion 就在 `.ps1`/`.cmd` 里用 UTF-8 BOM 文件调用，或先落盘再读。

## 任务 B：`test/zz_t66_cs1_evidence_manifest_test.dart`（新文件，10 处断言 / 8 条 test）

判据（全部读 manifest，不猜）：
- 仪器自检 3 条：`sha256(空)=e3b0c442…`、`sha256("abc")=ba7816bf…`（NIST 公开常量，实现坏了先红）；PNG 尺寸解析器用 24 字节合成头读出 `3 x 2`；重跑命令里的路径必须真。
- 正文 5 条：条目数 `> 0`（防空转：`0 张 == 0 条` 也是「相等」）；① 目录 PNG 数 == 条目数且**两个方向都查**（多一张、少一张都红）；② 逐张 sha256 逐字一致；③ 逐张尺寸 + 字节数一致；④ criterion 覆盖只报告不判红。

### 红 / 绿四次读数（worktree `/d/tmp/r66-v7` @ 65e1694 + 2 张合成 fixture）
| 场景 | 读数 | 红在哪 |
|---|---|---|
| 主树（无证据） | **`+3 -5`** | 5 条全部红，每条都打「证据缺失：…manifest.json 不存在」+ 可直接抄的重跑命令 |
| worktree 有证据 | **`+8` All tests passed!** | — （`EVIDENCE|criterion 已填 2/2`） |
| manifest 改一位 sha256（`…cadc`→`…cade`） | **`+7 -1`** | 「② 每张的 sha256 与 manifest 逐字一致」，打印 `manifest=…cade 实际=…cadc` |
| 删掉一张 PNG | **3 条红**（① ② ③） | ① `目录里有 1 张 PNG，manifest 登记了 2 条`；② ③ `文件不存在` |
| 从备份还原 | **`+8` All tests passed!** | `sha256sum -c` 两张 `OK`（与备份逐字相同） |

**说明**：主树此刻是红的、并且**要一直红到 r4-device 把真图封进来**。这是 Lead 明确要的「红着提醒证据没出」，`test` 文件头已写死「不要手写 manifest / 不要塞占位图」。

## 任务 C：`tools/verify_shots.ps1`（只读，未改一字节）
- **不硬编码 `.probe`**：参数是 `-InDir`（缺省 `.probe/e2e`），内部 `Resolve-Path` 后非递归扫 `*.png`。⇒ `-InDir docs/notes/evidence/round-66-cs1` **可以直接校验**。
- 实测（2 张合成 fixture）：`PASS 2 image(s): non-empty, expected size, distinct, no modal overlay`，`EXIT=0`，ratio 1.000。
- 空目录：`FAIL: no PNG files in …`，`EXIT=2` ⇒ 空证据不可能被「校验通过」。
- ⚠️ **别传 `-Tabs`**：本目录文件名不是 AppTab 名，实测 `FAIL: requested tab 'home' has no PNG`，`EXIT=1`。
- 能力边界（它治不了什么）：它只看像素统计（非空 / 尺寸 / 同批互不相同 / 中心与边缘亮度比判「全屏模态」），**不知道这是哪个页面、更读不出界面文字**。所以「56 ✓」这种**条文级**读数仍然只能靠 `flutter test`（可复核）+ 人眼/OCR（不可复核）。⇒ 证据目录**只能**证明「图是真的、没被别人换过」，证明不了「判据全过」。

## 仍未闭合的一件事（写给别人）
- `e2e_shots.ps1` **正常流程**里那段「证据模式写 manifest.json」的代码本轮**没有被执行过**（跑一次要 build + 占窗口，本轮禁止）。`-ManifestOnly` 那条路已实测三段。⇒ r4-device 第一次用 `-OutDir docs/notes/evidence/round-66-cs1` 出图时，请顺手确认 `manifest.json` 里 7 条 `name` 与目录里的图一一对应、以及有没有那条「本次没产出的旧图」警告。

## 附：Lead 问的一个色值（顺手查，不改）
`lib/design/widgets/app_glass_dialog.dart` 正文用的 `c.onSurfaceVariant`（`c` 是 `AppColors`，不是 Material `ColorScheme`）：
- `lib/ui/theme/app_colors.dart:219` → `onSurfaceVariant: mutedForeground`；
- `AppPalette.mutedForeground` 在内置浅色 = `LightTokens.textSecondary` = **`#FF60626B`**（`lib/ui/theme/light_tokens.dart:91`）；Material 侧同一来源见 `lib/ui/theme_bridge.dart:602 / :713`；
- **但**：选了主题包时 `AppColors` 取包自己的 `mutedForeground`（`lib/ui/theme/app_theme.dart:165 if (p != null) return p.palette;`）⇒ 真机量到的 `#737373` **不是**内置浅色这个 token 的原值，要么是主题包/暗色主题，要么是玻璃垫层 + 抗锯齿合成后的读数。判对比度请用 `c.onSurfaceVariant` 与**实际垫层底色**去算，别拿 `#60626B` 直接对 `#737373`。
