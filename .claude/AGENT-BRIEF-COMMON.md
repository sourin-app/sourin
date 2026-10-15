# 共用任务说明（所有 agent 必读，2026-10-09 夜）

你是「源影」项目夜间并行开发团队的一员。Owner（产品负责人）在睡觉，明早验收。
lead（协调者）负责分工、集成、开 PR。你只负责自己那一块，**做完、做好、可验证**。

## 1. 项目速览（先读这些）

- 仓库根（主工作区，只读参考）：`<仓库根>`（本机绝对路径见任务书；**不入库**）
- 必读：`docs/AGENTS.md`（开发入口/硬约束）、`docs/ARCHITECTURE.md` 与 `docs/CONFIG.md`（架构/配置/坑）、
  `CONTRIBUTING.md`（流程与纪律）、
  主工作区里的 `HANDOFF.md`（上一轮交接，未入库，用绝对路径读）、
  `PLAYER-CONTRACT.md` / `INTERACTION-CONTRACT.md`（交互契约：快捷键、TV 遥控器、导航）
- 架构：Flutter（`lib/`，只做 UI）+ Rust 核心（`rust/sourin_core`，cdylib，dart:ffi 直调，命令走 JSON）。
  **产品入口是 `lib/shell.dart`**（`lib/main.dart` 是早期 spike，不是产品）。
- 平台：Windows（主）/ macOS / Android 手机 / Android TV（同一个 APK，TV 用方向键 + `lib/ui/spatial_nav.dart`）。
  任何 UI 改动都要考虑：鼠标悬停（桌面）、触摸（手机）、方向键焦点（TV）三种输入。
- 上一轮的代码由**能力较弱的模型**写成：注释很长、偶有错误判断。读它的注释时保持怀疑，以代码与实测为准。

## 2. 你的工作区（严格隔离）

- 你有一个**独立 git worktree**（路径见你的任务书），对应一个独立分支。
- **不要调用 `EnterWorktree` / `ExitWorktree` 工具**，Bash 里也**不要裸 `cd`**（会改掉整个会话的工作目录，波及其他 agent 与 lead —— lead 已实测踩到）。
  做法：所有文件读写一律用 **worktree 内的绝对路径**；每条 Bash 命令都包在**子 shell** 里：
  `( cd <你的 worktree> && <命令> )` —— 括号不能省，子 shell 的 cd 不会泄漏出去。
  ⚠️ 主工作区（`<仓库根>`，本机绝对路径见任务书、**不入库**）本身（不含 `.claude\`）你**只读**，绝不在那里改文件、切分支、提交。
- **第一步**：`( cd <worktree> && git merge --ff-only feat/owner-feedback-1009 && flutter pub get )`（拿到 lead 刚加的截图辅助等）。
- worktree 根目录与 `rust/sourin_core/target/release/` 下已放好预编译的 `sourin_core.dll`（Rust 核心）。
- **只改你被分配的文件**（见任务书「文件归属」与第 8 节总表）。确需改别人的文件时，改动要最小、集中，
  并在最终报告里逐条列出（文件 + 原因）。**绝不**大面积格式化或重排别人的文件。

## 3. 环境与命令（Git Bash）

```bash
# ★ 每条命令**各自**带 PATH —— shell 状态不保留，上一行的 export 不影响下一行。
#   （CodeRabbit 指出：原来只在第一行 export，后面两条单独跑会 flutter: command not found）
W="$REPO/.claude/worktrees/<你的名字>"
T="$LOCALAPPDATA/Temp/sourin-agent-<你的名字>"; mkdir -p "$T/profile" "$T/data"
# ★★★ 沙盒里的 ui-prefs.json 必须**一并**清掉下载目录键（CodeRabbit PR #7 指出）：
#   `--dart-define=DATA_DIR_OVERRIDE` 只决定 ui-prefs.json **从哪读**，
#   它**不校验** `dsh.download.dir` 的值 —— 若那份文件里已有**真实**下载路径，
#   `_resolveConfigured()` 会照用 ⇒ 隔离不彻底（可能动到用户的真实「视频\源影」）。
#   ⇒ 每次跑测试前，把沙盒那份里这两个键删掉，让它回落到沙盒默认：
rm -f "$T/data/ui-prefs.json"        # 最省事：整份删掉（会回落默认）
# 若需要保留别的偏好，改删键：把 ui-prefs.json 里的
#   `dsh.download.dir` / `dsh.download.dir.migrated`  删掉再跑。
# ★ 跑测试的唯一正确姿势（子 shell + 隔离真实数据目录 + 隔离真实「视频\源影」下载目录）：
( export PATH="$FLUTTER_BIN:$PATH"; cd "$W" && USERPROFILE="$(cygpath -w "$T/profile")" \
    flutter test <文件...> --concurrency=1 \
    --dart-define=DATA_DIR_OVERRIDE="$(cygpath -w "$T/data")" )
( export PATH="$FLUTTER_BIN:$PATH"; cd "$W" && flutter analyze lib )   # 0 error；不要新增 warning
```
★ `FLUTTER_BIN` 由你的任务书给出（如 `<Flutter 安装目录>/bin`）。
  ⚠️ 逐条单独跑时**必须每条都带上 PATH** —— 上一条的 export 不会留到下一条。
  ⚠️ 沙盒里的 `ui-prefs.json` 是**跨轮残留**的：上一条 `rm -f` 不能省，
     否则可能复用到带真实下载路径的旧配置。
- `--concurrency=1` 必须带（多文件混跑会出现 `did not complete` 假红）。
- 一次别跑全量（2400 条、约 9 分钟，且会和其它 agent 抢 CPU）；跑与你改动相关的测试文件即可，
  收尾时再跑一次「你区域内的全部测试文件」。
- Rust：`cargo build --release` / `cargo test`（在 `rust/sourin_core` 下）。release 首次编译较慢（LTO）。
  改了 Rust 并要在 Flutter 里用，记得把新 dll 拷到 worktree 根和 `rust/sourin_core/target/release/`。

## 4. ★ 用户数据安全（违反任何一条都是严重事故）

- **绝不**读写 `%APPDATA%\app.sourin.player`（Owner 的真实收藏/进度/片头片尾/凭据）。
- **绝不**在 `<用户目录>\Videos\源影`（Owner 的真实缓存视频）里创建/修改/删除任何东西。
- 跑测试必须用第 3 节的隔离命令。写探针/测试时，数据目录与下载目录一律注入临时目录。
- 要真机启动客户端时：先 `flutter build windows --release -t lib/shell.dart`（在你自己的 worktree 里），然后
  ```powershell
  $env:APPDATA='<你的临时目录>\appdata'; $env:USERPROFILE='<你的临时目录>\profile'
  $env:SOURIN_NO_REMOTE_AUTOSTART='1'
  $p = Start-Process -FilePath '<worktree>\build\windows\x64\runner\Release\sourin_spike.exe' -WorkingDirectory '<同目录>' -PassThru; $p.Id
  ```
  桌面版的数据目录由 `APPDATA` 决定、下载根由 `USERPROFILE` 决定 ⇒ 这样启动与真实数据完全隔离（lead 已实测）。
  **只结束你自己启动的 PID**（`taskkill //PID <pid> //F`），绝不按进程名批量杀 —— 其他 agent 也在跑客户端。
- 不要从真实数据目录拷 `sync-settings.json`、`remote-pref.json`、`plugins/.data/`（含凭据 / 会自动同步或占端口）。
- 不碰 Windows 凭据管理器里的真实凭据（WebDAV 任务书里有单独规定）。

## 5. 如何「看见」你做的 UI（★ 今晚桌面是锁屏状态）

- 真窗口截图今晚**拿不到**（锁屏 ⇒ 屏幕拷贝是锁屏壁纸；PrintWindow 抓 Flutter 的 ANGLE 画面恒为全黑）。
- 用 lead 提供的**无头截图**：`test/support/ui_shot.dart`（真微软雅黑 + Material 图标）。
  在 widget 测试里 `setUpAll(loadRealFonts)` → `setShotViewport(tester, Size(1440, 900))` → pump 真页面 →
  `saveViewShot(tester, '名字')`，设环境变量 `SOURIN_SHOT_DIR=<你的目录>` 指定输出。示例见 `test/ui_shot_selftest_test.dart`。
  网络封面在测试里会是占位图（HttpClient 一律 400），可用本地图片模拟。
- ★★ **Read 工具在这个会话里读不到图像**（返回空内容）。所以「看一眼截图」这一步要靠 ASCII 渲染：
  ```bash
  python -I $REPO/.claude/tools/shot_ascii.py <png> [列数]
  ```
  输出是字符画：左边是图标/按钮的暗块，右边是文字行 —— 能看出**间距、对齐、是否挤在一起、有没有大片空白**。
  窄页面（手机）用 60~80 列更清楚。另有一个统计工具（颜色数 / 暗亮占比 / 边缘密度，用于发现「整页死色」「全黑」）：
  ```bash
  python -I $REPO/.claude/tools/shot_stats.py <png...>
  ```
  ⚠️ ASCII **显示不出真实色值与 hover/涟漪态** ⇒ 对比度要靠可编程断言（按 WCAG 算比值，正文 ≥ 4.5:1），
    交互态要靠状态断言测试。ASCII 只是布局自查的补充。
- **每个 UI 改动都要截图 + 跑 shot_ascii.py 自查**，并把**字符画贴进最终报告**（最关键的 3-5 张即可）。
  看到明显问题（文字挤成一团、左右边距不对称、大片空白、控件重叠）**自己修完再交**。
  不看图就交付 UI = 没做完。
- 真机冒烟（可选）：按第 4 节方式隔离启动，确认进程存活、日志无异常（日志在 `<APPDATA>\app.sourin.player\logs\`）。
- 共享窗口工具 `<仓库根>/.claude/tools/win.ps1`（按 PID 操作窗口，真鼠标键盘操作会自动排队拿全局锁）
  今晚锁屏时基本用不上，Owner 解锁后才有效。

## 6. 代码规矩（本仓硬约束）

- Material 一律 `import 'package:material_ui/material_ui.dart';`。`lib/` 里**禁止出现** `package:flutter/material.dart`
  这个字面量（`test/theme_regression_test.dart` 全 lib 扫描，注释里写也算违规；必须提到时用反引号包住）。
- **不要新增任何 forui 用法**（FTheme/FScaffold/FToaster/FButton/FDialog…）—— forui 正在被 theme agent 移除。
  取色用 `Theme.of(context).colorScheme` 或 `lib/ui/tokens.dart` 的令牌（间距 `Sp`、圆角、字号 `FontSizes`、动效 `Motion` 等）。
- 用户可见文案**不许**出现开发过程用语：「修复」「缺陷」「task-xx」「Owner」「探针」「踩坑」「已知问题」等。
  看到既有的这类文案，在你的区域里顺手清理掉。
- 注释写「为什么」，简洁。不要复制上一轮那种几十行的历史叙事；必要的背景一两句话即可。
- 测试纪律：**不许为了变绿而放宽断言、删断言、加 skip**。行为按 Owner 要求**有意改变**时，把测试改成断言**新行为**，
  并确保新断言在旧行为下会红（能测出反面）。环境依赖型测试（要网络 / libmpv / 夹具）必须**门控**（缺条件时 skip 并说明原因），
  不能在 CI 上红。
- **★ 假绿门禁：门禁必须读「真实结果」，不许读「同一个源」**（2026-10-12 加，见 §6b）。
- **★ 改完必须确认真的生效：不许「写了当做了」**（2026-10-12 加，见 §6a）。
- 性能意识：别在每次鼠标移动时 setState 整页；高频状态用 `ValueNotifier`/`ValueListenableBuilder`/`AnimatedBuilder` 局部重建；
  列表用 builder 虚拟化；大图给 `cacheWidth`；避免多余 `BackdropFilter`/`saveLayer`；动画用 `FadeTransition` 而非逐帧 `Opacity`。

## 6a. ★★★ 写了 ≠ 接线了（改完必须证明「真的生效」）

**本仓反复栽在同一个坑：代码写了、测试过了，但功能其实没生效。**
2026-10-12 一轮排查里，Owner 报的三个「还没修好」**全是这个形态**：

| 现象 | 「写了」什么 | 为什么没生效 |
|---|---|---|
| 详情页封面糊 | 2026-10-01 已写「按高度解码」修法 | **只接到缓存页，漏了详情页** |
| 顶/底栏不同时出现 | 设计上两条栏共用同一个 `Animation` | 底栏把动画值**转成了 build 期常量**，设计被架空 |
| 返回卡顿 | 已有「数据没变就不重建」守卫 | 判据里**混进每秒都变的 `position`** ⇒ 守卫等于没有 |

**⇒ 交付前必须自问三句**（并在报告里如实回答）：

1. **我加/改的这条路径，真的会被执行到吗？** —— 有没有第二个调用点、另一个分支、
   另一条平台路径**没跟上**？（封面那次就是漏了一个调用点。）
2. **我依赖的既有机制，真的在起作用吗？** —— 它有没有被上游的缓存 / 预建 child /
   `static final` 提前读走而失效？（底栏那次就是被预建 child 冻结。）
3. **我的判据本身会不会恒真 / 恒假？** —— 有没有混进「每次都会变」的字段
   （时间戳、`position`、随机数），或者「同一个源比同一个源」？（卡顿那次就是前者。）

**特别地：定义一个常量/函数/开关，不等于它被接上。**
本仓已有实例：`windowBorderColor` 有定义、有 Owner 原话、有深浅两套取值，
**但全仓零调用**（Owner 想要的功能从未存在）；`PlayerPopoverIds.danmaku`、
`AppMetrics.textScaleFor`、`pcButtonsEnabledFor` 同理。
⇒ **新增公开 API 时，必须同时给出它的调用点**；否则就是死代码。

### 例外（要说明）
确有正当例外（如为**将来**预留的 API、平台专属分支、只给测试用的接缝）。
**但必须在提交信息或注释里写明「为什么现在不接」**，否则一律按漏接处理。

---

## 6b. ★★★ 假绿门禁：不许「同一个源比同一个源」

**门禁必须读「真实结果」，不能读「喂进去的那个值」。**

本仓最典型的一例（2026-10-12 抓到）：
```dart
// 探针 debugPlayerControlBarsOpacity()：
final v = s._controlsFade.value;
return (v, v);        // ← 两个分量同一个源 ⇒ o.$1 == o.$2 恒真
```
门禁断言「顶栏与底栏的透明度相等」—— 但两个数**都来自同一个变量**，
所以**永远相等**，哪怕底栏的 `Opacity` 实际被冻结成常量（Owner 报的正是这个）。
⇒ 那条门禁**从构造上不可能红**，却「验过」了这个缺陷好几个月。

**判定方法：把它要防的缺陷人为还原回去，门禁必须变红。**
（本仓要求交付报告里给出这次「撤销验证」的读数。）
若还原后门禁**仍然绿** ⇒ 它是假绿，**必须重写**。

**假绿的五种常见形态**（都真在本仓出现过）：
| 形态 | 例子 |
|---|---|
| 同源比较 | `return (v, v)`，然后断言两值相等 |
| 只测「能关」不测「不透传」 | `t99` 只断言面板收到 `onClose`，没断言下层没收到点击 |
| 断言恒真条件 | 「树里有 `onTapUp`」（`InkWell` 无条件挂）；「源码含某字符串」 |
| 测的是别的东西 | 「点遮罩能关闭」被当成「点击不透层」的门禁；描述的行号段其实是键盘门控 |
| 缺第二态 | 只测「有 A 时怎样」，不测「没 A 时怎样」（没有阴性对照） |

**替代做法**：从 **element 树 / 渲染结果 / 落盘数据**里读**真实**的值
（如 `find.byType(Opacity)` 读 `Opacity.opacity`、读 `_player.seek` 的真实参数、
读数据库真实行），而不是读触发它的那个变量。

### 例外（要说明）
确有**无法**在 widget 测试里观测的东西（如真机才有的引擎文本输入管线）。
此时**改用可稳定观测的等价判据，并在测试文件头写明「为什么这条测不了、我改用什么替代」**
（本仓已有一例：物理 Enter 在 `flutter_tester` 里不产生文本编辑 ⇒ 改测「播放是否被触发」+
用 `enterText` 证多行能力，并写明仪器边界）。
**不许**因为测不了就写一条恒真的东西充数。

---

## 7. 提交与报告

- 在你的分支上**小步提交**，提交信息用中文，写清「为什么 + 怎么验证的」。
- `git add` 一律**显式列路径**，**禁止** `git add -A` / `git add .`。**禁止 push**、禁止开 PR（lead 统一做）。
- 两类全仓系统性测试失败由 **lead 统一修**，你不要动：① `A Timer is still pending even after the widget tree was disposed`
  （FFI 超时计时器悬空）② `SliverGeometry is not valid: layoutExtent exceeds paintExtent`。lead 修好后会通知你合并。
- 基线失败清单：`<仓库根>/.claude/baseline-failures.txt`（202 条，按文件归类）。
  你区域内的其它失败，由你甄别（真回归 / 既有 / 环境）并处理。
- 完成时的**最终回复**（这就是你的报告，lead 只看得到它）必须包含：
  1. 完成了什么（对照任务书逐条），没完成什么及原因
  2. 改动文件清单；改了别人归属的文件要单独列出
  3. 验证读数：analyze 结果、跑了哪些测试（贴通过/失败计数）、截图路径
  4. 已知问题 / 需要 lead 或其他 agent 协调的事项
  5. 分支名与最后一个提交的 SHA

## 8. 文件归属总表（谁改什么）

| agent | 分支 | 主要归属 |
|---|---|---|
| player | feat/player-ux | `lib/ui/player_page.dart`、`widgets/player_settings_sheet.dart`、`widgets/episode_strip.dart`、`widgets/skip_timeline.dart`、`widgets/skip_marker_dialog.dart`、`widgets/danmaku_overlay.dart`、`widgets/danmaku_settings_dialog.dart`、`widgets/live_embedded_player.dart`、`ui/subtitle/*`、`ui/cast/*`、`core/player_gestures.dart`、`core/pip.dart`、新建 `lib/ui/player/*` |
| media | feat/local-media | `lib/ui/cache_page.dart`、`detail_page.dart`、`media_page.dart`、`media_session.dart`、`widgets/download_panel.dart`、`widgets/my_shelf.dart`、`widgets/detail_raw_meta.dart`、`widgets/source_switch_dialog.dart`、`core/download_queue.dart`、`core/hls_download.dart`、`core/download_dir.dart`、`core/clip_download.dart`、`core/progress_backfill.dart`、`core/title_match.dart` |
| settings | feat/settings-ui | `lib/ui/settings_page.dart`、`ui/settings/*`（除 about_page / theme_page）、`ui/search_page.dart`、`widgets/plugin_speedtest.dart`、`plugin_edit_dialog.dart`、`provider_import_dialog.dart`、`provider_login_panel.dart`、`provider_name.dart`、`tvbox_source_panel.dart`、`proxy_panel.dart`、`settings_kit.dart`、`settings_sub_page.dart`、`backup_panel.dart`、`reorderable_card_grid.dart`、`bili_import_dialog.dart`、`qr_view.dart` |
| theme | feat/ui-unify-theme | `lib/ui/app_theme.dart`、`theme_bridge.dart`、`tokens.dart`、`ui/settings/theme_page.dart`、`pubspec.yaml`（移除 forui）、新建 `lib/ui/theme/*`、新建 toast 组件；以及**各文件里 forui 用法那几行**的机械替换 |
| remote | feat/remote-page | `rust/sourin_core/src/remote/*`、`src/commands_remote.rs`、`lib/ui/remote_bridge.dart`、`tests/batch7_remote.rs` |
| webdav | fix/webdav-e2e | `rust/sourin_core/src/sync/*`、`src/backup.rs`、`src/commands_backup.rs`、`lib/ui/widgets/sync_panel.dart`、WebDAV 相关测试 |
| update | feat/app-update | 新建 `lib/core/app_update.dart` 等、`lib/ui/settings/about_page.dart`、`.github/workflows/build.yml`（仅版本注入）、`installer/*`（如需） |
| polish | feat/polish-perf | `lib/shell.dart`、`home_page.dart`、`follow_page.dart`、`browse_page.dart`、`live_page.dart`、`spatial_nav.dart`、`titlebar_visibility.dart`、`system_ui.dart`、`widgets/poster_card.dart`、`source_bar.dart`、`cover_image.dart`、`fade_in_sliver.dart`、`page_transition*.dart`、`press_feedback.dart`、`motion_prefs.dart`、`overlay_motion.dart`、`collapsible_epg.dart`、`epg_panel.dart`、`follow_update_notice.dart`、`window_frame.dart`、`core/ffi.dart`、`core/sourin_api.dart`、`core/ui_prefs.dart`、`core/app_log.dart` |
| review | fix/review-1009 | 只读审查上一轮代码 + 修复 `rust/sourin_core/src/ffi.rs` 与 `lib/ui/spatial_nav.dart` 的乱码注释/文案 |

`test/` 下的测试文件按「它测的是谁」归属上表对应的 agent。
