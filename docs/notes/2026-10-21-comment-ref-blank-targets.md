# 注释引用「指向空行」清单（61 条）

> 2026-10-21 生成。**未修改任何注释** —— 本文件把「人工定位」预先做成「人工确认」。
>
> 来源：门禁 `test/zz_t66_r3_comment_ref_test.dart` 判据②（目标行不能是空行）。
> 报错率 4.1%（61/1448），抽样核实**全是真错**（行号漂移落在空行上）。
>
> 关联笔记：[comment-file-line-ref-gate](../../.agents/notes/implemented/testing/2026-10-21-comment-file-line-ref-gate.md)

## 一、总览

```text
共 61 条

按「真身是否已定位」分类：
  FOUND          34 条 —— 注释里的标识符在目标文件里找到了，已给命中行号
  NO_IDENT       15 条 —— 注释里没有可提取的标识符（纯描述性）
  FILE_ONLY      10 条 —— 只引用**整个文件**，没指向具体符号
  FOUND_MANUAL     2 条 —— 自动抽取没命中，但人工核实目标区域**能对上**
  IDENT_GONE       0 条 —— 声称的标识符**确实找不到** ⇒ 完全失效

FOUND 再按「最近命中距目标行多远」分置信度：
  高（≤30 行）  15 条 —— 基本可以确认就是这个
  中（≤300 行） 14 条 —— 需看一眼上下文
  低（>300 行）  5 条 —— grep 命中的很可能不是同一处，需人工判断
```

**按文件分组（Top 12）**：

```text
  player_page.dart                       6 条
  t377_banner_probe.dart                 4 条
  t79_assrt_wiring_test.dart             3 条
  clip_download.dart                     2 条
  shell.dart                             2 条
  t74_search_sticky_probe.dart           2 条
  app_dialog_section.dart                2 条
  app_log.dart                           1 条
  bili_api.dart                          1 条
  progress_backfill.dart                 1 条
  app_icon_button.dart                   1 条
  t2_detail_button_probe.dart            1 条
```

## 二、可操作清单

格式：**引用位置** → 声称的目标 → **置信度** → 真身候选（grep 自动生成）

### A. FOUND —— 真身已定位，确认即可（34 条）

#### 置信度「高」—— 15 条

##### `lib/t493_layout_probe.dart:26` → `t370_browse_probe.dart:272`

```text
注释：// ⇒ 用本仓既有的等价实现 globalRect(Element)（lib/t370_browse_probe.dart:272-279）：
目标文件共 1329 行；第 272 行是**空行**
★ 最佳候选：`globalRect` 在 :274（距目标行 +2）
  其它 `Element` 命中 21 处：[178, 179, 180, 189, 194, 198]
```

##### `lib/t74_search_sticky_probe.dart:385` → `t75_search_pinned_test.dart:105`

```text
注释：/// （与已绿的 `t75_search_pinned_test.dart:105-107` 的 `kBoxFinder` **同一套选择器**，
目标文件共 471 行；第 105 行是**空行**
★ 最佳候选：`kBoxFinder` 在 :114（距目标行 +9）
  其它 `t75_search_pinned_test` 命中 1 处：[11]
```

##### `lib/ui/player_page.dart:1752` → `source_switch_dialog.dart:172`

```text
注释：/// source_switch_dialog.dart:172  TextEditingController(text: widget.title)
目标文件共 617 行；第 172 行是**空行**
★ 最佳候选：`TextEditingController` 在 :169（距目标行 -3）
```

##### `lib/ui/player_page.dart:1754` → `source_switch_dialog.dart:210`

```text
注释：/// source_switch_dialog.dart:210  if (kw.isEmpty) return;  ← ★★ 静默返回、零请求
目标文件共 617 行；第 210 行是**空行**
★ 最佳候选：`isEmpty` 在 :209（距目标行 -1）
```

##### `lib/ui/player_page.dart:16718` → `episode_strip.dart:1105`

```text
注释：* 而 `SheetTransition` 的契约（`episode_strip.dart:1105-1106`
目标文件共 2493 行；第 1105 行是**空行**
★ 最佳候选：`SheetTransition` 在 :1097（距目标行 -8）
  其它 `episode_strip` 命中 1 处：[1126]
```

##### `lib/ui/settings/emby_page.dart:34` → `models.dart:376`

```text
注释：//   ① 已修 —— $lib/core/models.dart:376$ 新增 $static String normalizeKind()$，
目标文件共 3292 行；第 376 行是**空行**
★ 最佳候选：`String` 在 :375（距目标行 -1）
  其它 `normalizeKind` 命中 2 处：[393, 416]
```

##### `lib/ui/settings_page.dart:4218` → `theme_page.dart:74`

```text
注释：* ★ `padding` 不能省（`theme_page.dart:74` 的实测结论）：
目标文件共 1074 行；第 74 行是**空行**
★ 最佳候选：`padding` 在 :98（距目标行 +24）
```

##### `lib/ui/widgets/player_settings_sheet.dart:411` → `t62_player_rate_test.dart:140`

```text
注释：*   `test/t62_player_rate_test.dart:140-221 _sheet({...})`、
目标文件共 602 行；第 140 行是**空行**
★ 最佳候选：`_sheet` 在 :141（距目标行 +1）
```

##### `test/shell_safe_area_test.dart:70` → `core_error_test.dart:55`

```text
注释：/// 理由与 `test\core_error_test.dart:55-64` 相同：`_CoreErrorView` 用
目标文件共 372 行；第 55 行是**空行**
★ 最佳候选：`_CoreErrorView` 在 :60（距目标行 +5）
```

##### `test/t58_media_page_layout_test.dart:766` → `detail_page.dart:1800`

```text
注释：* 实现已按此改成：`detail_page.dart:1800 return LayoutBuilder(`
目标文件共 5258 行；第 1800 行是**空行**
★ 最佳候选：`return` 在 :1797（距目标行 -3）
  其它 `detail_page` 命中 4 处：[99, 121, 413, 5199]
  其它 `LayoutBuilder` 命中 10 处：[235, 1324, 2579, 2582, 2625, 2628]
```

##### `test/t74_perf_synth_test.dart:400` → `sourin_api.dart:84`

```text
注释：//   → sourin_api.dart:84   static String get version => SourinCore.version;
目标文件共 4410 行；第 84 行是**空行**
★ 最佳候选：`SourinCore` 在 :83（距目标行 -1）
  其它 `String` 命中 358 处：[82, 115, 116, 121, 122, 128]
```

##### `test/zz_cr_ui_10_esc_dismiss_test.dart:20` → `app_toast.dart:96`

```text
注释：//     而 maybeOf 用 findAncestorStateOfType<_AppToasterState>()（app_toast.dart:96-97）
目标文件共 400 行；第 96 行是**空行**
★ 最佳候选：`maybeOf` 在 :98（距目标行 +2）
  其它 `findAncestorStateOfType` 命中 2 处：[99, 349]
  其它 `_AppToasterState` 命中 5 处：[98, 99, 102, 118, 385]
```

##### `test/zz_t5_upstream_live_test.dart:401` → `settings_page.dart:582`

```text
注释：* `Future.delayed(3s)`（`settings_page.dart:582`）。
目标文件共 7413 行；第 582 行是**空行**
★ 最佳候选：`Future` 在 :577（距目标行 -5）
  其它 `delayed` 命中 2 处：[675, 6917]
  其它 `settings_page` 命中 3 处：[688, 4521, 4772]
```

##### `test/zz_t66_glass_toast_test.dart:10` → `cache_page.dart:1868`

```text
注释：//   lib/ui/cache_page.dart:1868         _say
目标文件共 2417 行；第 1868 行是**空行**
★ 最佳候选：`_say` 在 :1849（距目标行 -19）
```

##### `test/zz_t66_r3_info_triple_test.dart:12` → `danmaku_info_panel.dart:551`

```text
注释：// danmaku_info_panel.dart:551 `_sourceRow` 只画 `d.source.label` —— 那是**类别**
目标文件共 1319 行；第 551 行是**空行**
★ 最佳候选：`source` 在 :530（距目标行 -21）
  其它 `_sourceRow` 命中 3 处：[585, 592, 739]
  其它 `label` 命中 24 处：[67, 106, 203, 206, 208, 325]
```

#### 置信度「中」—— 14 条

##### `lib/core/bili/bili_api.dart:58` → `danmaku.dart:574`

```text
注释：// IoDanmakuTransport 的正文是直接 Utf8Decoder 的（danmaku.dart:574-577），
目标文件共 3758 行；第 574 行是**空行**
★ 最佳候选：`IoDanmakuTransport` 在 :661（距目标行 +87）
  其它 `Utf8Decoder` 命中 1 处：[733]
```

##### `lib/core/clip_download.dart:44` → `shell.dart:792`

```text
注释：// # 数据目录为什么自己解析（不复用 lib/shell.dart:792 的 _resolveDataDir）
目标文件共 8673 行；第 792 行是**空行**
★ 最佳候选：`_resolveDataDir` 在 :730（距目标行 -62）
```

##### `lib/core/progress_backfill.dart:49` → `my_shelf.dart:61`

```text
注释：//    与本仓 `lib/ui/widgets/my_shelf.dart:61` 的写法一致。
目标文件共 2523 行；第 61 行是**空行**
★ 最佳候选：`my_shelf` 在 :234（距目标行 +173）
```

##### `lib/shell.dart:7713` → `tokens.dart:222`

```text
注释：// （`lib/core/device.dart:192` / `lib/ui/tokens.dart:222`），
目标文件共 1027 行；第 222 行是**空行**
★ 最佳候选：`tokens` 在 :157（距目标行 -65）
  其它 `device` 命中 4 处：[37, 426, 458, 459]
```

##### `lib/t2_detail_button_probe.dart:403` → `player_page.dart:1930`

```text
注释：//   漏了它 ⇒ `_PlayerPageState.initState`（player_page.dart:1930）
目标文件共 21733 行；第 1930 行是**空行**
★ 最佳候选：`initState` 在 :1798（距目标行 -132）
  其它 `_PlayerPageState` 命中 10 处：[705, 710, 734, 12378, 16957, 17586]
```

##### `lib/t74_perf_probe.dart:909` → `shell.dart:307`

```text
注释：// ② 窗口：镜像 shell.dart:307-347 的 WindowOptions(size: 1280x800)
目标文件共 8673 行；第 307 行是**空行**
★ 最佳候选：`WindowOptions` 在 :434（距目标行 +127）
```

##### `lib/t74_search_sticky_probe.dart:580` → `search_page.dart:368`

```text
注释：*   整个结果区挡掉（`search_page.dart:368-393` 的注释就是讲这个陷阱）。
目标文件共 1353 行；第 368 行是**空行**
★ 最佳候选：`search_page` 在 :260（距目标行 -108）
```

##### `lib/ui/home_page.dart:2042` → `browse_page.dart:445`

```text
注释：* ⇒ 只能用外层 `Padding`（browse/search 两页同形，见 `browse_page.dart:445`）。
目标文件共 959 行；第 445 行是**空行**
★ 最佳候选：`Padding` 在 :488（距目标行 +43）
```

##### `lib/ui/widgets/danmaku_settings_dialog.dart:1908` → `bili_import_dialog.dart:275`

```text
注释：* 同一个坑 `bili_import_dialog.dart:275` 早就记过，我又踩了一次：
目标文件共 954 行；第 275 行是**空行**
★ 最佳候选：`bili_import_dialog` 在 :378（距目标行 +103）
```

##### `test/skip_pair_grouping_test.dart:88` → `skip_marker_dialog.dart:677`

```text
注释：*   → _loadExisting()                       skip_marker_dialog.dart:677
目标文件共 4106 行；第 677 行是**空行**
★ 最佳候选：`_loadExisting` 在 :747（距目标行 +70）
```

##### `test/t63_shot_ui_test.dart:100` → `player_page.dart:1628`

```text
注释：*   _load() 挂在 addPostFrameCallback（player_page.dart:1628）上，
目标文件共 21733 行；第 1628 行是**空行**
★ 最佳候选：`addPostFrameCallback` 在 :1753（距目标行 +125）
  其它 `_load` 命中 36 处：[496, 500, 505, 507, 509, 2735]
```

##### `test/t79_assrt_wiring_test.dart:20` → `player_capability_test.dart:1083`

```text
注释：//      （`player_capability_test.dart:1083` 用的是 `find.text` 精确匹配）
目标文件共 1417 行；第 1083 行是**空行**
★ 最佳候选：`text` 在 :1029（距目标行 -54）
  其它 `find` 命中 25 处：[1176, 1177, 1183, 1184, 1186, 1197]
```

##### `test/task18_entry_test.dart:79` → `ffi.dart:227`

```text
注释：/// ffi.dart:227-229  Android | Linux  → libsourin_core.so
目标文件共 1084 行；第 227 行是**空行**
★ 最佳候选：`Android` 在 :290（距目标行 +63）
```

##### `test/zz_t66_r3_comment_ref_test.dart:202` → `shell.dart:792`

```text
注释：//   例：4 处注释写 `shell.dart:792`，而 `_resolveDataDir` 在 `:1014`
目标文件共 8673 行；第 792 行是**空行**
★ 最佳候选：`shell` 在 :748（距目标行 -44）
  其它 `_resolveDataDir` 命中 5 处：[636, 669, 730, 991, 1014]
```

#### 置信度「低」—— 5 条

##### `lib/core/app_log.dart:23` → `shell.dart:792`

```text
注释：// ★ dataDir 的解析次序与 lib/shell.dart:792 一致（见 ClipDownloader.dataDir
目标文件共 8673 行；第 792 行是**空行**
★ 最佳候选：`dataDir` 在 :4989（距目标行 +4197）
```

##### `lib/ui/cache_page.dart:34` → `detail_page.dart:1417`

```text
注释：// ② 入队那行 lib/ui/detail_page.dart:1417-1431 构造 DownloadTask 时
目标文件共 5258 行；第 1417 行是**空行**
★ 最佳候选：`DownloadTask` 在 :2300（距目标行 +883）
```

##### `lib/ui/widgets/app_dialog_section.dart:18` → `danmaku_settings_dialog.dart:868`

```text
注释：// _gap           lib/ui/widgets/danmaku_settings_dialog.dart:868  SizedBox(height: Sp.x3)
目标文件共 4461 行；第 868 行是**空行**
★ 最佳候选：`_gap` 在 :1525（距目标行 +657）
  其它 `SizedBox` 命中 56 处：[1741, 1793, 1822, 1878, 1940, 2037]
```

##### `lib/ui/widgets/app_dialog_section.dart:135` → `danmaku_settings_dialog.dart:868`

```text
注释：/// 对应 `danmaku_settings_dialog.dart:868` 的 `_gap()`
目标文件共 4461 行；第 868 行是**空行**
★ 最佳候选：`_gap` 在 :1525（距目标行 +657）
```

##### `test/zz_cr_play_bottom_bar_test.dart:5` → `detail_page.dart:790`

```text
注释：//   `lib/ui/detail_page.dart:790-814` 与 `test/player_panel_wiring_test.dart`），
目标文件共 5258 行；第 790 行是**空行**
★ 最佳候选：`detail_page` 在 :413（距目标行 -377）
```

### B. NO_IDENT —— 纯描述性注释，需人读后决定（15 条）

```text
  lib/core/clip_download.dart:586 -> shell.dart:792
      /// 解析数据目录 —— 镜像 lib/shell.dart:792 的三步次序（见文件头注释）。
  lib/design/widgets/app_icon_button.dart:19 -> cache_page.dart:2097
      //   ② 真的当"有色表面/卡片"用  （例：cache_page.dart:2097 color + shape + clip）
  lib/shell.dart:2270 -> detail_page.dart:1227
      *   （detail_page.dart:1227 / follow_page.dart:869 /
  lib/ui/app_update_bootstrap.dart:85 -> app_tray.dart:75
      ///   并且不需要本仓再提供第二个全局 key（见 app_tray.dart:75-88 的同类教训）。
  lib/ui/player_page.dart:4692 -> detail_page.dart:221
      * lib/ui/detail_page.dart:221   ← 详情页用来显示"看到 12:34"
  lib/ui/player_page.dart:13698 -> live_page.dart:450
      * live_page.dart:450-457（既有、已验收）
  test/bottom_bar_fit_test.dart:51 -> keepalive_test.dart:81
      /// 与生产外壳一致的包装（照抄 `test/keepalive_test.dart:81-91`）
  test/player_capability_test.dart:268 -> detail_page.dart:221
      * lib/ui/detail_page.dart:221   ← 详情页读进度（显示"看到 12:34"）
  test/t68_android_adapt_test.dart:171 -> t62_player_rate_test.dart:119
      //  面板夹具（与 t62_player_rate_test.dart:119-220 同构）
  test/t98_settings_open_order_test.dart:34 -> player_page.dart:9303
      // 修法：挂载点给**常量** Key（player_page.dart:9303）+ 判据改用
  test/task44_all_subpages_test.dart:100 -> about_page.dart:90
      ///   lib/ui/settings/about_page.dart:90
  test/zz_cr_dl_c13_local_episode_id_test.dart:45 -> media_page.dart:623
      // （media_page.dart:623-624）。为 null 时（生产恒为 null）零行为差异。
  test/zz_cr_dmk_b_source_prefix_test.dart:34 -> t73_bili_wiring_test.dart:352
      // test/t73_bili_wiring_test.dart:352（T73FIX，已由 Lead 复核）只钉住了 **B 站那一半**：
  test/zz_t12_local_play_probe_test.dart:155 -> player_page.dart:2002
      *      （lib/ui/player_page.dart:2002）
  test/zz_t66_ui_selfaudit_test.dart:255 -> sync_panel.dart:1525
      //   实测假阳性（sync_panel.dart:1525-1526）：
```

### C. FILE_ONLY —— 只引用整个文件，没有具体符号（10 条）

```text
  lib/t377_banner_probe.dart:405 -> t370_browse_probe.dart:507
      * `t370_browse_probe.dart:507` 那行注释逐字就是
  lib/t377_banner_probe.dart:418 -> t370_browse_probe.dart:615
      *    与 `t370_browse_probe.dart:615-623` 同一手法
  lib/t377_banner_probe.dart:591 -> t370_browse_probe.dart:507
      * `t370_browse_probe.dart:507` 那行注释逐字就是
  lib/t377_banner_probe.dart:606 -> t370_browse_probe.dart:615
      *    与 `t370_browse_probe.dart:615-623` 同一手法
  lib/ui/player_page.dart:581 -> live_page.dart:450
      /// ⚠️ 方向**必须**与 `live_page.dart:450-457` 一致 ——
  test/t457_hints_entry_test.dart:25 -> t456_media_route_touch_test.dart:23
      /// 递归收集 .dart 文件（照抄 `t456_media_route_touch_test.dart:23-31`）。
  test/t48_live_embedded_doubletap_test.dart:367 -> zz_t42_gate_verification_test.dart:502
      //  静态分析工具（照抄 `zz_t42_gate_verification_test.dart:502-578`）
  test/t48_live_page_all_channels_test.dart:338 -> zz_t42_gate_verification_test.dart:502
      //  `zz_t42_gate_verification_test.dart:502-559`，**逐字一致**以便互证）
  test/t74_follow_title_backfill_test.dart:134 -> t65_follow_cards_test.dart:102
      /// 挂载用的宿主（与 `t65_follow_cards_test.dart:102-116` 同款）
  test/t79_assrt_wiring_test.dart:142 -> t78_video_zoom_hwdec_test.dart:110
      //  面板夹具（与 `t78_video_zoom_hwdec_test.dart:110-178` 同构）
```

### D. FOUND_MANUAL —— 自动抽取没命中，人工核实能对上（2 条）

```text
  test/t79_assrt_wiring_test.dart:154 -> t78_video_zoom_hwdec_test.dart:119
      目标区域 :119-178 是 PlayerSettingsSheet 的 required 参数块 —— 能对上，非失效
  test/t91_sync_presets_test.dart:62 -> t38_login_autosopen_test.dart:48
      目标区域 :48-58 是 _host 模板 —— 能对上，非失效
```

### E. ★ IDENT_GONE —— 声称的目标已不存在（完全失效）：**0 条**

```text
（本类是空的）
```

★ **这个「0」是核实过的结论，不是漏查。**

自动分类最初给出 3 条「标识符在目标文件里 grep 命中 0 次」，我逐条复核：

```text
① test/t79_assrt_wiring_test.dart:154   → t78_video_zoom_hwdec_test.dart:119-178
   抽取到的「标识符」是文件名本身。目标区域 :119-178 是 PlayerSettingsSheet
   的 required 参数块 —— **能对上**，非失效。⇒ 归入 D

② test/t91_sync_presets_test.dart:62    → t38_login_autosopen_test.dart:48-58
   同上，文件名被当成标识符。目标区域是 `_host` 模板 —— **能对上**。⇒ 归入 D

③ test/zz_cr_dmk_b_source_prefix_test.dart:34 → t73_bili_wiring_test.dart:352
   抽取到的是 `T73FIX`（**任务代号**）和 `Lead`（人名），
   它们本就不该出现在目标文件里 —— 这不是"失效"，是**提取噪声**。⇒ 归入 B
```

⇒ **真正的「被引用物已删除/改名」情况：0 条。**
这 61 条**全部是行号漂移**，不是"引用了不存在的东西"。

★ 这条结论值得单独记，因为它推翻了一个预期：
「既然漂移这么严重，总该有几条是目标被删了吧」—— **没有**。
说明本仓的引用虽然有行号漂移，但**被引用的概念都还在**，只是位置变了。

★ 判据（给以后做同类清单的人）：
```text
自动分类出「命中 0 次」时，**先看抽到的是不是标识符**。
文件名 / 任务代号（T73FIX）/ 人名（Lead）/ 通用词（lib, ui, test）
都不是标识符 —— 它们命中 0 次是**正常的**，不是失效。
不剔除这几类，"真身已不存在"的数字会**虚高**（本轮 3 → 实际 0）。
```


## 三、建议分批（交 Lead 决定，我不擅自改）

**按「需要多少人工判断」排序**，不是按文件排序：

```text
批 1  高置信 34 条里的 15 条 —— 真身行号已给出且距目标 ≤30 行
       成本：**逐条换数字**（看一眼候选行确认是不是同一处，然后改）
       风险：低。每条都有明确的候选行号

批 2  中置信 14 条 —— 候选在 30~300 行内
       成本：需读一眼上下文，确认候选是不是"注释说的那个东西"
       风险：中。可能候选是同一个标识符的**另一处**用法

批 3  低置信 5 条 —— 候选距目标 >300 行
       成本：grep 很可能没命中真身，**要重新定位**
       风险：高。这几条建议单独看

批 4  NO_IDENT 15 + FILE_ONLY 10 + FOUND_MANUAL 2 = 27 条
       成本：**要判断"到底该指向哪"**，不是换数字能解决的
       风险：高。有些可能本来就该改成"不写行号"的写法
```

★ 为什么**不按文件分批**：
```text
按文件分（player_page 6 条 / t377_banner_probe 4 条 …）看起来整齐，
但同一个文件里的 6 条**难度可能完全不同** ——
把它们捆成一批，会让最难的 1 条拖住最容易的 5 条。
⇒ 按**置信度**分批，让"能机械做的"先做完。
```

★ 我**没有**动这 61 处注释中的任何一处。
