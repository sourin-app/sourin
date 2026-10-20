# 第 66 轮 · 批末统一实测清单（verify-e2e）

> 写于 2026-10-19。用途：本轮 diff 合流后，按这张表**逐条真跑**一遍。
>
> **本文所有判据都是可观察的事实**：像素值、日志行、落盘文件、`netstat`/`Get-NetTCPConnection` 的监听项。
> 没有一条写「看起来正常」「符合预期」——这类判据无法证伪，等于没判据。

---

## 0. 复跑基建（先做这一步）

一条命令起客户端 + 按页签截图 + 精确收尾：

```powershell
.\tools\e2e_shots.ps1 -Tabs "home,live,follow,search,cached,settings" -NoBuild -OutDir .probe\e2e
```

它做四件本轮之前没人做的事：

| # | 能力 | 为什么必须有 |
|---|---|---|
| 1 | `-Tabs` 对着 `lib/shell.dart` 的 `AppTab` 枚举**逐个校验**，拼错立即 `exit 1` | 目录名/页签名靠记忆写，写错会静默拍到别的页 |
| 2 | 建 `%TEMP%\sourin-e2e-<随机>`，`APPDATA`/`USERPROFILE`/`LOCALAPPDATA` 全部指过去，并设 `SOURIN_NO_REMOTE_AUTOSTART=1` | 铁律 ①③：绝不碰 Owner 真实收藏/进度/凭据 |
| 3 | 启动前后做 **PID 差集**，只 `taskkill //PID <自己起的>` | 铁律 ④：绝不按进程名批量杀 |
| 4 | 往隔离目录写 `ui-prefs.json`（`appupdate.autoCheck=0`），关掉启动自动更新检查 | 否则 `settings.png` 拍到的是「发现新版本」弹窗，不是设置页（实测踩过） |
| 5 | 每张图打印**绝对路径 + 字节数 + PNG 尺寸**，0 字节直接 `exit 1` | 铁律「禁止恒 0 假绿」 |

**已知边界（写在这里，免得下一个人当成缺陷重查）**

```text
· 图落在 <repo>\.probe\tabshot_*.png（lib/shell.dart 里是**相对路径**硬编码），
  -OutDir 是"复制到哪个目录"，不是进程内的写入路径。
· 等待就绪靠轮询两个条件：窗口句柄存在 + stdout 出现 [SHELL] FIRST_FRAME_RENDERED。
  不看固定 sleep。
· 判定"某页已截到"用的是枚举顺序映射：phase p(1起) => AppTab.values[(p-1) % count]，
  文件名 = tabshot_<phase*10+k 三位补零>.png。这两处一旦改一边就会错位。
· 进程内探针每页停 5s、切页后 0/40/80/160/200ms 连拍 6 帧；过渡动画 Motion.base=260ms
  ⇒ 一次 burst 的**最后一帧**仍可能落在过渡中。脚本取该页最后一个 burst 的最后一帧，
  并在两张图字节相同时**显式报警**（`identical image content for: ...`），
  而不是把重复图当成"两页都拍到了"。
· flutter 位置走 `$env:FLUTTER_BIN` → PATH 两级解析，找不到就报错退出。
  ⚠️ 本文件与 tools/e2e_checklist.ps1 **不得**写死某台机器的 flutter 绝对路径
  （见 §5：本轮修掉了它，而 tools/ 下另有两处同类存量问题）。
```

---

## 1. 逐条实测清单

| # | 功能 | 怎么触发（精确到点击路径） | 判据（看什么 / 读什么数） | 本轮哪个改动会打破它 |
|---|---|---|---|---|
| 1 | **R2 起播失败文案不再说「内置代理没起来」** | 起客户端 → 发现页点任一卡片 → 详情页 → 选集 → 在 `%TEMP%` 隔离目录下把 `streamproxy` 端口占掉（或断网后点「重试」）制造一次起播失败 | ① 错误浮层 headline **逐字等于**「这一条流取不到」，且**不含**「没起来」二字；② nextStep 逐字等于「点「重试」，或者换一条线路。」**不含**「重启客户端」；③ 正文里**不出现** `127.0.0.1:<端口>` | f47d2ed 改的正是 `PlaybackFailure.headline/nextStep` 与 `classify` 的 `text`/`display` 分家（`lib/core/sourin_api.dart:3684-3721, 4028-4037`）。任何人把 `lower` 改回 `display.toLowerCase()` 会让 ① 回退成「内置代理没起来」 |
| 2 | **R2 归因不再被展示层污染（误判环没回来）** | 同上，但走**真实**错误文本 `Failed to open http://127.0.0.1:57106/s/18df9acc…/.` | `zz_r65_error_text_test` ①③⑦ 与 `zz_t65_playback_error_text_text_test` 那条样本必须 **+42 全绿**；把 `final lower = text.toLowerCase()` 改成 `display.toLowerCase()` 后必须**红 4 条**（实测：① / ③ / ⑦ / t65 样本） | 同 1。这条注入口在 `sourin_api.dart:4037`，是判断「门禁还有没有判别力」最便宜的一刀 |
| 3 | **R3-④ 弹窗事件穿透守卫** | 播放页 → 点弹幕按钮开弹幕设置弹窗 → 在弹窗**外**空白处单击一次 | 单击不得关闭弹窗、不得触发底下的播放器暂停。`zz_t66_dialog_no_passthrough_test` 全绿 | R3 假定的 `AbsorbPointer` / barrier 改动。若守卫改成 `IgnorePointer`，点击会穿透到播放器 |
| 4 | **R3 弹幕设置弹窗 7 个子项可见可搜** | 播放页 → 弹幕面板 → 逐个子项滚动到底 | 每个子项标题都在可滚动区内命中（`find.text` 非空）；「添加屏蔽词」输入框可获得焦点并能输入中文；块词无重复渲染 | `danmaku_settings_dialog.dart` 本轮改动；`blockWordsAddFieldKey` 所在区块若被挤出滚动视口会静默消失 |
| 5 | **R5 直播页内容溢出被裁（线路 chip 被 `ClipRRect` 切掉）** | 直播页 → 选一个频道 → 把窗口拉到 900×600（Owner 实测断点）| **不是**「控件不重叠」—— 真实缺陷是**溢出**：`Column` 里的 `AspectRatio` 不 flex，线路 chip 折成 2 行后底部越出 `ClipRRect`。<br>判据：chip 的 `Rect.bottom` 必须 `<= clip.Rect.bottom`（交集面积判据**测不出这个缺陷**，因为 chip 是被裁不是被压）。<br>实测读数：`clip 532×356, n=4 ⇒ chip 307.3..371.3 ✗ 溢出 15.3px`；`n=8 ⇒ 溢出 51.3px`。<br>`zz_t66_r5_player_no_overlap_test` 全绿（**文件名是历史遗留，内容测的是溢出**） | 修法是 `lib/ui/live_page.dart:3554` 的 `Flexible(child: AspectRatio(...))` 一行。★ 谁把 `Flexible` 去掉，chip 立刻重新越界 —— 门禁含阴性对照（`flexed=false` 复现修复前形状） |

| 5b | **R6 直播页没有假弹幕入口（这条前提曾被推翻）** | 直播页 → 选频道 → 逐个看控件 | ★ **更正**：`grep -c "danmaku" lib/ui/live_page.dart` = **0** ⇒ 直播页**从来不存在**弹幕控件，不存在"隐藏一个假入口"。<br>真实判据：① 可交互控件数 = 3（播放/静音/容器手势）；② 有且仅有一句说明文字「这个来源暂无弹幕」；③ 清晰度下拉在**≥2 个非 DRM 可选档**时才出现（1 档/全 DRM 一律不画）<br>`zz_t66_r6_live_controls_test` +10 | `live_embedded_player.dart`。★ 三档对照（1 档 / 3 档 / 3 档含 2 DRM）证明判据守的是「DRM 不算可用档」这个**语义**，不是"下拉有没有被删" |
| 6 | **R5 控制条不越界（不画到窗口外/被裁）** | 同 5，窗口拉到 1280×800 与 1024×640 各一次 | 控件条 `Rect.bottom <= 视口高度 - 安全区`，且 `Rect.top >= 0`。两次窗口尺寸下都要成立 | 同 5。R5 前一版把控件按"设计稿坐标"写死，窄窗就会被裁 |
| 7 | **R6 直播清晰度/线路分类** | 直播页 → 选频道 → 打开线路列表 | 分组标题逐字为实际分类；同一线路不得同时出现在两个分组；切线路后 `st.url` 的 host 变化被日志记到（`[LIVE] 起播 OK host=…`） | `live_page.dart` R5/R6 同文件改动。分类表若与 `_loadStream` 的兜底顺序不一致会出现"标称高清实为标清" |
| 8 | **R8 缓存页整剧删除徽标可见** | 底部栏 → 已缓存 → 任一已下载剧集封面右上角「更多」浮层 | ① 删除入口的命中区域 `Rect` 完全落在封面 `Rect` 内且面积 ≥ 24×24；② 该入口与封面图片的**像素对比度** ≥ 3:1（取入口图标区域与背景区域的平均色算）；③ 点击后弹出二次确认，文案含「将删 N 集 / 共 X MB」 | `cache_page.dart` R8 改动 + `PosterCard`。徽标用半透明白叠浅色封面时对比度会掉到 1.x，肉眼"有"，但确实看不见 |
| 9 | **R1 弹幕 chip 毛边** | 播放页 → 打开弹幕面板 → 看 chip 边缘 | 对 chip 边界 1px 环带取像素：**不得**出现 alpha 介于 1..254 的边缘像素（除抗锯齿允许的 ≤2 层），且环带亮度与填充区差值 ≥ 8/255 | `player_page.dart` R1 改动。阴影/描边改成半透明叠层就会重新出毛边 |
| 10 | **CS-1 导出含登录态时口令必填** | 设置 → 备份与恢复 → 导出 | ① 未设口令时导出，返回 `credentialsIncluded == false`，界面**必须**出现「未包含」字样；② 设了口令后导出，界面出现「含 N 个源的登录态，已加密」；③ 导出的包内**不得**出现明文口令字段 | `sync_panel.dart` / `backup_panel.dart` + `sourin_api.backupExport(passphrase:)`。CS-1 最容易出的错是"设了开关但没设口令 ⇒ 实际没同步，界面却说完成"（`sync_panel.dart:417` 那段注释记的就是这个） |

**★ 2026-10-19 实测读数（CS-1 收尾，全部通过）**

```text
真机（.probe/t66-cs1-probe，56 ✓ / 0 ✗，7 张截图 1280×800）
  ① 未设口令 ⇒ credentialsIncluded=false、credentialsNote 含「不含登录态」
     且界面**没有**「已加密」字样（门禁：zz_t66_cs1_ui_flow_test.dart）
  ② 设口令后导出，界面那一行逐字是：
     已导出到 …\probe-export.zip（3.9 KB）（含 2 个源的登录态，已加密；导入时要口令）
     截图 .probe/t66-cs1-04-export-done-run1.png（69881 B）
     日志  导出：成功 probe-export.zip（3.9 KB）—— 凭据 已加密包含 2 个源
  ③ 包内字节（真读 zip 中央目录，包 4019 B / 解出文本 5180 字符）：
     不含导出口令明文 / 不含合成令牌 / 不含合成密码 / 不含合成用户名
     ★ 另加一条更强的：把 _v1 解开 ⇒ **不是**可读 JSON（真加密，不是 base64 假加密）
     ★ 且两次导出的 _v1 **不相同**（随机 salt/nonce）
flutter_test（真核心驱动）
  test/zz_t66_cs1_export_import_e2e_test.dart   +23 全绿
  test/zz_t66_cs1_ui_flow_test.dart             +4  全绿
```
| 11 | **CS-1 导入时必须重新输入口令** | 设置 → 备份与恢复 → 导入一个带凭据的包 | 导入流程**弹出**口令输入框（不得复用导出时的口令）；输错口令时**明确报错**且不写入任何凭据；成功后 `credentialsProviders` 数量与包内一致 | 同上。若把口令一起打进包，这条会"通过"但安全性已破 |

**★ 2026-10-19 实测读数（全部通过）**

```text
真机
  ① 点「确认导入」⇒ **弹出口令框**（标题「这个备份包含登录态」）
     截图 .probe/t66-cs1-05-import-passphrase-run1.png（79621 B）—— 框真在窗口上
     只有两个出口：「取消导入」「导入」；**没有**「跳过凭据」
  ② 输错口令 ⇒ 界面逐字显示
       SourinCoreException(unauthorized): 口令不正确（或这个备份包已被改动），登录态没有导入
     截图 .probe/t66-cs1-06-wrong-passphrase-run1.png（71630 B）
     ★ 失败后 credentials_status.providers **仍为 0**、.data/ 目录**仍为空**
       ⇒ 确实一个字节都没写入
  ③ 输对口令 ⇒ 日志「导入：登录态已恢复 —— 本机现有 2 个源有登录态」
     credentials_status.providers = 2 == 包内 2
     截图 .probe/t66-cs1-07-import-done-run1.png（73696 B）
     ★ 含凭据的包走「选文件 → 确认导入」；**不含**凭据的包**不**弹口令框（不白问用户）
```| 12 | **弹幕代理三态：直连 / 跟随系统 / 自定义** | 设置 → 弹幕源 → 滚到底「网络代理」 | ① 三个选项**逐字**为「直连」「跟随系统代理」「自定义代理」；② 选中态与实际下发给 `HttpClient.findProxy` 的值一致：`direct ⇒ 'DIRECT'`（**不是 null**）、`system ⇒ null`、`custom ⇒ 'PROXY host:port'`；③ 代理地址输入框**只在 custom** 出现（direct/system 下 `find.text('代理地址')` 必须为 0）；④ 诊断行逐字随模式变化 | 6222428。把 `direct` 改成返回 `null` ⇒ 有 `HTTPS_PROXY` 的机器上"直连"会偷偷走代理；把 `custom` 的地址丢掉 ⇒ 代理成了摆设 |
| 13 | **弹幕代理：探活与取弹幕走同一条路** | 设置 → 弹幕源 → 点「测试连接」，然后播放一集有弹幕的片子 | 两处构造 `IoDanmakuTransport` 都必须带 `findProxy: currentDanmakuFindProxy()`（门禁数构造点数量）；真机上表现为「测试连接通过 ⇒ 弹幕能取到」，不得出现"探活通了但取不到" | 6222428 的接线。只接一处会出现 `danmaku.dart:1951` 与 `:2791` 走不同代理 |
| 14 | **弹幕代理：socks 地址必须明确拒绝** | 设置 → 弹幕源 → 自定义 → 填 `socks5://127.0.0.1:1080` | 诊断行逐字含「不支持 socks」，且实际下发值退回 `'DIRECT'`（不是 `PROXY`）。**不得**静默把 socks 当 http 代理用 | `_parseProxyHostPort`。若把 `scheme.startsWith('socks')` 的拒绝删掉，会变成"用户以为用 socks，实际是明文 HTTP 打 socks 端口" |
| 15 | **跳过点写路径失败必须可见** | 播放页 → 片头片尾 → 设置一个跳过点 → 把数据目录文件改成只读后保存 | 保存失败时**必须**出现失败态（不是静默成功）；重新进入页面读回的值仍是旧值。`zz_t66_skip_write_path_test` 全绿 | 2460801 / skip 写路径改动。这条是「写了 ≠ 写成功」的典型 |
| 16 | **跳过点读取超时必须能退出** | 播放页 → 起播后等跳过点探测（核心层人为挂住时） | 弹窗必须在有限时间内结束（不得永久转圈）；`zz_t66_sheettimer_dispose_test` 全绿 | 2460801 的超时改动。去掉超时会让核心层挂住时 UI 永久转圈 |

---

## 2. 本轮必须一起跑的既有门禁

```powershell
# 弹幕代理四件套（实测 +18，全绿）
flutter test test/zz_t66_danmaku_proxy_test.dart `
             test/zz_t66_danmaku_proxy_req_test.dart `
             test/zz_t66_danmaku_proxy_a11y_test.dart `
             test/zz_t66_danmaku_proxy_https_test.dart --concurrency=1

# R2 归因（实测 +42，全绿）
flutter test test/zz_r65_error_text_test.dart `
             test/zz_t65_playback_error_text_test.dart --concurrency=1

# 本轮新增：弹幕代理三态「真页面」取证（实测 +4，产出 3 张 PNG）
flutter test test/zz_t66_verify_danmaku_proxy_shots_test.dart --concurrency=1
```

> ⚠️ **`--concurrency=1` 不是建议**。`dart_test.yaml` 头部记着：并发跑时
> `MediaKit.ensureInitialized()` 加载 `libmpv-2.dll` 会让 `flutter_tester.exe`
> native 崩溃（`c0000005`），失败形态是整文件 `did not complete`，退出码 **79**。

---

## 3. 已知的「证据强度」缺口（不是缺陷，但别当成已验）

```text
① 幂等截图 ≠ 已验页面内容（已实测踩到，不是理论风险）
   进程内探针每页只保证"拍到了非空 PNG"。若两页字节完全相同，
   .probe/e2e_shots.ps1 会报警 —— 但报警**不会**自动变成失败，
   因为"两页恰好长得一样"在空数据目录下是可能的。
   ★ 2026-10-19 真实发生：`settings.png` 拍到的是一整个「发现新版本 1.3.0」
     弹窗，而不是设置页。字节数 142559 B、尺寸 1280×800、和其他 5 张都不同
     ⇒ 脚本的每一条自动判据**全部通过**。它之所以被抓住，只因为我打开了图。
   根因：隔离只靠 APPDATA/USERPROFILE 环境变量，而"开发模式不查更新"看的是
     编译期常量 `String.fromEnvironment('DATA_DIR_OVERRIDE')`
     （`app_update_controller.dart:165,215`）⇒ 环境变量隔离**绕过了**那个开关。
   修法：脚本新增一步，往隔离目录写 `ui-prefs.json` 的
     `appupdate.autoCheck=0`（关的是偏好本身，不只是关窗 ⇒ 也去掉了那次网络请求）。
   ⇒ 判读截图时必须人眼确认底栏高亮项，不能只看"有图"。

② flutter_test 渲染的图与真机不是像素级等同
   test/zz_t66_verify_danmaku_proxy_shots_test.dart 用 800x600 的逻辑视口 +
   注入的 SimHei。它能证明「控件存在、文案逐字、状态与配置一致」，
   但**不能**证明「真机 1280x800 下的间距/换行」。
   ⇒ 间距类判据（#5 #6 #8 #9）必须在真机进程里取 Rect，不能拿这张图顶。

③ 设置页二级页在真机上**无法用键盘到达**
   桌面端 Device.needsFocusRing=false ⇒ 空间导航关闭；实测向窗口
   PostMessage 发 WM_LBUTTONDOWN/WM_LBUTTONUP 后 [NAV] 日志 **0 次**
   ⇒ 本清单里所有"设置 → 某二级页"的路径，在自动化下只能靠
   flutter_test 渲染，或人工点一次。
   这条是基建缺口，不是产品缺陷；要真机自动化得先给设置页加可聚焦入口。

④ R1「弹幕 chip 一圈毛边」**至今未能复现**，且证据已排除掉 chip 自身
   ★ 2026-10-19 Lead 亲自跑 `test/zz_t66_r1_three_way_compare_test.dart`
   （三方 × 五帧，真实 PlayerPage 取三枚**真 widget 实例**，DPR=1.0 / 1280×800）：
   ```text
   ┌──────────┬─────────┬──────────┬────────────┬──────────┐
   │ 对象     │ edgeStd │ innerStd │ 内部众数幅度│ Δpeak    │
   ├──────────┼─────────┼──────────┼────────────┼──────────┤
   │ 弹幕chip  │    2.69 │     0.00 │        0.00 │     6.59 │
   │ 站名徽章  │   39.49 │    17.26 │      103.00 │    10.00 │
   │ 直播徽章  │    3.69 │     0.00 │        0.00 │     0.00 │
   └──────────┴─────────┴──────────┴────────────┴──────────┘
   ```
   `innerStd = 0.00`（跨帧内部标准差）⇒ **弹幕 chip 与直播徽章合成分后不透明，
   画面透不过去**；三枚里只有**站名徽章**是真半透明（`Container+BoxDecoration`
   black@0.55 直接压视频，`BoxDecoration` 不做 source-over 补齐）。
   ⇒ 「毛边」若真存在，唯一有嫌疑的对象是**站名徽章**，它恰好紧挨弹幕 chip。
   ⚠️ 该文件**整体判红**，但失败原因 `SourinCoreException(unsupported):
   end_yield_for_seek 尚未接入 FFI 层` 是**陈旧 DLL**，不是产品缺陷：
   `rust/sourin_core/src/ffi.rs:1975` **已接入**该命令，而仓库根
   `sourin_core.dll` 停在 10-18 12:15，落后于当天 08:57 的提交。
   ⇒ 修法：`.\tools\run_client.ps1 -Rust` 重新 cargo build 后再跑。
```

---

## 4. 本轮复核过程中拿到的实测读数（供批末对照）

| 项目 | 读数 | 出处 |
|---|---|---|
| 弹幕代理四件套（未注入） | `+18 -0` | 见 §2 第一条命令 |
| 弹幕代理四件套 · 注入 A（`direct` 返回 `null`） | `+16 -2`，红的正是 ① 直连 与 ④ 环境变量无关 | `danmaku.dart` `case DanmakuProxyMode.direct` |
| 弹幕代理四件套 · 注入 B（`custom` 丢弃地址） | `+14 -4`，红的含 ② 自定义下发 PROXY / ⑥ 诊断文案 / HTTPS 两条 | 同上 `case DanmakuProxyMode.custom` |
| R2 归因两件套（未注入） | `+42 -0` | §2 第二条命令 |
| R2 归因两件套 · 注入（`lower` 改回 `display`） | `+38 -4` | `sourin_api.dart:4037` |
| 恢复后 | 上述两处 `git status --porcelain <file>` 均为空，`danmaku.dart` sha256 `dd24933c…` / `sourin_api.dart` sha256 `70ed8862…` 与注入前逐字节一致 | — |
| e2e_shots 正常跑（修正 seed 路径后，最终态） | 6 页 1280×800：36590 / 28379 / 38880 / 42418 / 33269 / 73879 B，全部互不相同，`exit 0` | `.probe\e2e-t66\` |
| e2e_shots 故障注入 ① 拼错页签名 | `exit 1` — `FAIL step 1: unknown tab name(s): settigns` | — |
| e2e_shots 故障注入 ② 大小写错 | `exit 1` — `FAIL step 1: unknown tab name(s): Home (did you mean 'home'? tab names are case-sensitive)` | — |
| e2e_shots 故障注入 ③ 缩短截图超时 | `exit 1` — `FAIL step 7: timed out after 6s waiting for screenshots of: settings` | `-ShotsTimeoutSec 6` |
| e2e_shots 故障注入 ④ 空 -Tabs | `exit 1` — `FAIL step 1: -Tabs resolved to an empty list` | `-Tabs "  "` |
| e2e_shots 故障注入 ⑤ 页签藏在弹窗后 | **自动判据全部通过**（见 §3 缺口 ①）：`settings.png` 曾被「发现新版本」弹窗整页覆盖，142559 B 看着完全正常。只有人眼看图才能发现 ⇒ 已改为在 seed 步骤断言内容，并靠人眼复核 | `.probe\e2e-t66\settings.png`（历史那次 142559 B） |

### 4.1 CS-1（判据 #10 / #11）实测读数（2026-10-19）

| 项目 | 读数 | 出处 |
|---|---|---|
| CS-1 真机取证（一次跑完） | **56 ✓ / 0 ✗**；7 张截图全部 1280×800，63490 / 89670 / 69275 / 69881 / 79621 / 71630 / 73696 B | `.probe\t66-cs1-*.png` |
| 判据 10-② 界面逐字 | `已导出到 …\probe-export.zip（3.9 KB）（含 2 个源的登录态，已加密；导入时要口令）` | `.probe\t66-cs1-04-export-done-run1.png` |
| 判据 10-② 后端日志 | `导出：成功 probe-export.zip（3.9 KB）—— 凭据 已加密包含 2 个源 / 打包 142 ms / 全程 5600 ms` | 隔离日志 `.probe\t66-cs1-data\logs\sourin-2026-10-19.log` |
| 判据 10-③ 包内字节 | 包 **4019 B** / 解出文本 **5180 字符**；口令明文、合成令牌、合成密码、合成用户名 **全部搜不到** | 探针真读 zip 中央目录 |
| 判据 10-③ 追加（真加密） | `_v1` 解开后**不是**可读 JSON；两次导出的 `_v1` **不相同** | `zz_t66_cs1_export_import_e2e_test.dart` |
| 判据 11-① 口令框真在窗口上 | 标题「这个备份包含登录态」；只有「取消导入」「导入」两个出口；**无**「跳过凭据」 | `.probe\t66-cs1-05-import-passphrase-run1.png` |
| 判据 11-② 错口令 | 界面逐字 `口令不正确（或这个备份包已被改动），登录态没有导入`；之后 `providers` **仍为 0**、`.data/` **仍为空** | `.probe\t66-cs1-06-wrong-passphrase-run1.png` |
| 判据 11-③ 对口令 | `导入：登录态已恢复 —— 本机现有 2 个源有登录态`；`providers = 2` == 包内 2 | `.probe\t66-cs1-07-import-done-run1.png` |
| CS-1 门禁（未注入） | `zz_t66_cs1_export_import_e2e_test.dart` **+23**、`zz_t66_cs1_ui_flow_test.dart` **+4**；四个 CS-1 文件合跑 **+59** 全绿 | — |
| 注入 ①「没带凭据却说已加密」 | `+3 -1`，红的正是「不许说已加密」 | `backup_panel.dart` `credNote` |
| 注入 ②「没口令却说凭据同步已完成」 | `+42 -4`，红的含 e2e 那条「三档都不得出现完成/将同步」 | `models.dart` `statusLabel` |
| 注入 ③「base64 明文假加密」 | ★ **第一版判据全绿**（假绿被抓）⇒ 加强判据后同一注入 `+20 -4` | `credentials.rs` `encrypt_bundle` |
| 三处注入还原后 | `cmp` 与 HEAD **逐字节相同**：`models.dart` / `backup_panel.dart` / `credentials.rs`；`git status --porcelain` 三处均为空 | — |
| ★ 陈旧 DLL（AGENTS §8 那条坑） | 仓库根 `sourin_core.dll` 原为 **Oct 18 12:15**，CS-1 接线 `bd0ac81` 是 **Oct 19 08:46** ⇒ 首跑直接报「命令 `credentials_status` 尚未接入 FFI 层」。重拷 `target/release/sourin_core.dll`（md5 `666b2e09…`）后跑通 | — |
| 真机隔离与收尾 | `APPDATA`/`USERPROFILE`/`LOCALAPPDATA` 指到 `.probe\t66-cs1-run\`；`SOURIN_NO_REMOTE_AUTOSTART=1`；跑完 `Get-Process sourin_spike` **为空**；★ Owner 真实目录 `%APPDATA%\app.sourin.player\logs\` 里**没有一条**本探针的 `[BACKUP]` 行（全在隔离目录） | — |

### 4.1b ★ 星号缺陷（真机截图抓到，第 66 轮 CS-1 收尾）

```text
现象：Flutter 的 `Text` **不解析 markdown** ⇒ 用户可见文案里的 `**粗体**`
      **原样显示**在屏幕上。截图逐字：
      「这个备份文件会**含登录态**（2 个内容源）。」
      「请输入 **导出这个包时** 设置的口令。」
      「⚠️ 口令不对时 **整次导入会失败**（不会只导一半）」
根因：本仓**全仓没有 markdown 渲染器**
      （grep `markdown|Markdown` lib/ ⇒ 只有注释命中）
      ⇒ 凡是要显示给用户的 `**` 都是露馅
★ 仓库先例：lib/shell.dart:6955 的注释写着
      「要强调就用中文引号「」，视觉上同样醒目且不会露馅」
修法：8 处用户可见字符串的 `**粗体**` → 「粗体」（12 个字面量）
      ⇒ 用中文引号而非 Text.rich（跟仓库先例一致）
门禁：test/zz_t66_cs1_no_markdown_leak_test.dart（+7）
      · 断言**整棵树**所有可见 Text 不含 `**`（不是只断言那两条常量
        —— 只断言单条的话「改一处漏一处」会假绿）
      · ★ 防空转自检：先断言树**非空**且含已知文案「备份」
        （本会话已出三次恒真判据 ⇒ 「不含 `**`」在空树上也为真）
      · 静态兜底：源码字符串字面量里也不许有 `**`
注入：① 知情提示正文加回 `**` ⇒ +5 -2（widget 门禁 + 静态门禁都红）
      ② _dialogHint 那行加回 `**`（不同渲染路径）⇒ +4 -3
      两处注入均已还原，`cmp` 与注入前**逐字节相同**
真机复跑：56 ✓ / 0 ✗；截图 02（知情提示）与 05（导入口令框）逐字核对
      ⇒ 已是「含登录态」「不输密码」「账号密码明文」「泄露的是「密码」」
      「口令「不会」进包」「请输入「导出这个包时」设置的口令。」
      「口令不对时「整次导入会失败」」—— **无一处字面 `**`**
连带修正（行为有意改变 ⇒ 改断言为**新行为**，旧行为下必须红）：
      zz_t66_cs1_credentials_gate_test.dart  ★ 泄露的是「密码」
      zz_t66_cs1_ui_flow_test.dart            ★ 口令「不会」进包
```

### 4.2 CS-1 这轮补上的**判据**（不是"补了测试"，是"补了判据的分辨率"）

```text
① 判据必须分得清「密文」与「长得像密文的明文」
   第一版只做「逐字节搜明文字符串」⇒ base64 一下就搜不到 ⇒ 假绿。
   修法：把 _v1 **解开**，看是不是能直接读的 JSON；再加「两次导出密文必须不同」。
   ★ 这一条是 AGENTS §4「门禁不许同一个源比同一个源」的教科书案例：
     第一版比的是「导出的东西 == 我期望的样子」，而不是「加密真的发生了」。

② 判据必须精确到「为什么」
   「凭据未同步（未设置口令）」vs「凭据未同步（本机暂无登录态）」——
   两条都以「凭据未同步」开头，只断言结论 ⇒ 分不出是哪一条 ⇒ 假绿。
   （这是本轮 AGENTS §8 新增的那条坑，CS-1 侧已由既有门禁守住。）

③ 「界面上出现某句话」必须读**渲染结果**，不能 grep 源码
   本轮 10-② / 11-① 都改成在 element 树上找 / 在真机截图里看。
   ⚠️ 复制一份对话框到测试里 = 门禁与实现漂开 ⇒ 明确不做。
```

---

## 5. 提交前的隐私清理（本轮新发现，不属于 R1–R8 任一条）

**读数**（Lead 亲自跑，扫的是**整棵已发布树**，不是本次 staged diff）：

```powershell
git grep -l -E "iuuuuuuuu" HEAD -- . | sed 's/^HEAD://' | sed 's#/[^/]*$##' | sort | uniq -c | sort -rn
```

```text
      8 rust/sourin_core/tests
      4 test
      3 lib
      3 docs/notes
      2 tools
      1 .github
```

**本轮已修（属本轮 diff，不是存量）**：

```text
tools/e2e_shots.ps1     写死的 flutter 绝对路径 → $env:FLUTTER_BIN → PATH 两级解析
tools/e2e_checklist.ps1 同上，并把 -FlutterBin 默认值清空
```

**存量未修（属另一件事，需 Owner 决定是否单开一项）**：

```text
tools/run_client.ps1:56          同一个写死模式
tools/live_probe_count.ps1:122   同一个写死模式
lib/t17_cover_probe.dart         写死 C:\Users\<本机>\Videos\源影  ← ★ 这条碰真实数据目录
lib/t17_shot_probe.dart          同上
lib/t465_skip_dialog_probe.dart  注释里写了本机 flutter 路径
rust/sourin_core/tests/t84_live_8_14_probe.rs / zz_t38_*.rs（5 个） 写死本机 AppData
```

⇒ **判据**：本机绝对路径不该出现在**已发布树**里。扫 staged diff 只能证明「这次干净」，
证明不了「上次没带进去」—— 这条本轮又验证了一次（8 处 Rust 测试 + 3 个 lib 探针都是更早带进去的）。
⚠️ 本轮**不动**这些存量文件：它们不属于 R1–R8，也不属于本轮四大块，
按「只做被指派的事」不该在这一轮顺手改。要修就单开一项、单独走门禁。

---

## 6. 批末真机启动实测（取证人：`r6-live`，**本节只是步骤，执行由 Lead 做**）

> 写于 2026-10-19。本节**只给命令与判据，不含执行结果** ——
> 执行与读数由 Lead 在批末统一贴。判断依据来自
> [AGENTS.md §6「收尾必做：真机隔离启动一次」](../AGENTS.md) 的历史事故：
> 2026-10-18 那一轮 **4131 条单测全绿**，Release 起来**第一次弹窗就崩**
> （`Null check operator used on a null value` @ `MaterialLocalizations.of`）。

### 6.0 为什么单测不够（判据的性质）

```text
flutter test 全绿 ⇒ 只证明「flutter_tester（软件光栅化）里不崩」。
MaterialLocalizations 的缺失只在**真机窗口 + 真实 DialogRoute** 下暴露
⇒ 这条判据的性质是「真机可观察事实」，不是「单测可推导结论」。
★ 因此本节所有判据都必须贴**实测输出**，不接受「应该没问题」。
```

### 6.1 环境隔离（铁律 ①③④）

```powershell
# 每条命令各自带环境变量 —— shell 状态不保留，上一行的 export 不影响下一行
$env:APPDATA      = "$env:TEMP\sourin-e2e-<随机>\appdata"
$env:USERPROFILE  = "$env:TEMP\sourin-e2e-<随机>\userprofile"
$env:LOCALAPPDATA = "$env:TEMP\sourin-e2e-<随机>\localappdata"
$env:SOURIN_NO_REMOTE_AUTOSTART = 1

# ★ 启动前必查：这三个值必须**都是**临时目录，且与系统真值不同
#   （AGENTS.md §8：删环境变量 ≠ 取消隔离，会回退到 HOME=C:\Users\<user>）
echo "APPDATA=$env:APPDATA"
echo "USERPROFILE=$env:USERPROFILE"
echo "LOCALAPPDATA=$env:LOCALAPPDATA"

# ★ 绝不用 `Remove-Item Env:APPDATA` 表达「不隔离」
#   —— 三级回退 Platform.environment['APPDATA'] ?? ['HOME'] ?? '.' 会落到 HOME
```

判据读什么：

```text
· echo 出来的三个路径必须**都**含 `sourin-e2e-`，且**不含**真实用户名路径
· 事后：<临时目录>/appdata/app.sourin.player/ 存在，而 %APPDATA% 下**没有**新增文件
  （用启动前后的 mtime/文件数对比；绝不去读真实目录内容）
```

### 6.2 构建与启动

```powershell
# ★ 必须显式 -t lib/shell.dart —— 编错入口**不报错**，只会编出 spike
flutter build windows --release -t lib/shell.dart

# 硬闸：data/app.so 的大小（编出 spike 时这个数明显偏小）
(Get-Item .\build\windows\x64\runner\Release\data\app.so).Length
```

判据读什么：

```text
· 编译**零 error**；`app.so` 字节数与上一版同量级（不是几百 KB）
· 启动后 stdout 出现 `[SHELL] FIRST_FRAME_RENDERED`
· ★ grep 计数：`Unhandled Exception` **必须 = 0**（不是"看起来没崩"）
```

### 6.3 ★★ 最关心的那一条：`update_dialog` 换壳后的弹窗（§6.2 的真正风险点）

**背景（本轮改动的风险点，逐字）**：

```text
lib/ui/widgets/update_dialog.dart 头部第 20~25 行自己写着：
  「改前靠 AlertDialog 拿到 MaterialLocalizations（showDialog 的路由自带）」，
  「⇒ 外壳内部没有 MaterialLocalizations 依赖；showAppDialog 走 showDialog，路由自带。
    改完必须**真机**验一次」
```

⚠️ **不要用「设置 → 关于 → 检查更新」当触发器** —— 它**不一定弹**：

```text
lib/ui/settings/about_page.dart:91-96
    final rel = res.release;
    if (rel == null) { showAppToast(...); return; }   ← ★ 已是最新 ⇒ 直接 return
    final wantDownload = await showUpdateDialog(...);  ← 走不到这里
```

⇒ 开发版本地 HEAD 永远比线上新 ⇒ `rel == null` ⇒ **`showUpdateDialog` 根本不执行**，
点多少次都验不到那个弹窗。这正是「以为什么都测过了其实没测」的最典型形态。

**可靠的触发器（三条，按优先级）**：

| 优先级 | 触发路径 | 为什么可靠 |
|---|---|---|
| **1** | 设置 → 数据管理 → 任一分类行点「清理」→ 确认弹窗 | 无网络前置条件，**必弹**。⚠️ 见下方「注意」 |
| **2** | 播放任意视频 → 跳过片头/片尾设置（`skip_marker_dialog.dart:2259` 已走 `AppDialogShell`） | 同样无前置条件 |
| **3** | 设置 → 主题 → 任一需要二次确认的操作 | 同上 |

判据读什么（**逐条贴输出**）：

```text
① Unhandled Exception 计数 = 0
   判据命令：Select-String -Path <stdout> -Pattern 'Unhandled Exception' | Measure-Object | % Count
② 弹窗**真的画出来了**（不是黑屏/半屏）：
   截图绝对路径 + 字节数 + PNG 尺寸（0 字节 ⇒ exit 1）
③ 弹窗标题/正文**逐字**可读，且**没有**星号露出：
   本轮刚把 `**粗体**` 改成 `「粗体」`，肉眼确认一次
④ 关闭弹窗后再开一次，确认**第二次也正常**（单次成功可能是缓存）
```

⚠️ **注意（优先级 1 的坑）**：`lib/ui/settings/data_manage_page.dart:192`
那一处确认弹窗**仍然是裸 `AlertDialog`**，**没有**走 `AppDialogShell`
⇒ 它验的是旧路径，**不能**代表 `update_dialog` 的换壳结果。
**要验 `AppDialogShell` 换壳，必须真的让 `showUpdateDialog` 跑一次**
⇒ 办法：把隔离目录的 `ui-prefs.json` 里 `appupdate.autoCheck` 设为 **1**，
并保证 `res.release != null`（需要一个比本地 HEAD 更新的线上版本）。
★ **做不到就如实写「本条未验」**，不要用「数据管理弹窗正常」冒充。

### 6.4 收尾（脚本自己打印 `SURVIVORS=<n>`，非 0 即 exit 非 0；**不必再人工补**）

`tools/e2e_shots.ps1` 现在**自带**这条判据（2026-10-19 已修）：

```text
:171   $script:PidListForManifest = @()                  ← 声明处初始化
:208   $script:PidListForManifest = @($script:StartedPids)  ← ★ 清空**之前**留档
:210   $script:StartedPids = @()                          ← 清空
:659   $left = @($script:PidListForManifest | …)           ← 收尾读**留档**
:661   Write-Host ("SURVIVORS=" + $left.Count)            ← 机器可读
:665   if ($left.Count -gt 0) { Fail(…) }                 ← ⇒ exit 非 0
```

改前是**双重失效**（供后人理解为什么必须留档）：清空在前、复查在后 ⇒ `$left` 恒空；
且非 0 只 `Warn`、仍走到末尾 `exit 0`。现在两条都堵上了。

**已实测它能真的变红**（不是恒 0、也不是恒 1）：

```text
注入（塞一个「收尾杀不掉」的长命进程）：
  SURVIVORS=1
  FAIL: survivors: 1 process(es) from THIS run are still alive (pids: …)
  === EXITCODE=1 ===
反向对照（该 pid 不存在）：
  SURVIVORS=0
  OK   all our pids are gone
  === EXITCODE=0 ===
```

⇒ **批末直接读脚本自己打印的 `SURVIVORS=` 即可**，不必再人工补那段复查。
若读不到，按 §6.6 第 ① 条处理（**不许当成 0**）。

### 6.5 ★ 这条检查覆盖不到什么（批末报告措辞必须按这里的边界写）

```text
① 读不到 SURVIVORS ≠ 0
   什么时候：启动差集为空时脚本会在更早一步 Fail（"client process never
   appeared"），**根本走不到收尾** ⇒ SURVIVORS 这一行不会被打印。
   怎么表现：日志里没有 SURVIVORS= 这一行。
   ★ 读的人怎么判断：**读不到 ≠ 0**。它是「这条路径没跑到」，
     不是「全部清干净了」。批末报告要写「未走到收尾判据」，
     不许把它记成 SURVIVORS=0。

② 可能误报 1 个 survivor
   什么时候：taskkill 之后到进程真正回收之间有极短窗口，
             此刻 Get-Process 仍能查到。
   怎么表现：SURVIVORS=1，但该 pid 其实已在退出。
   ★ 方向是「多报」不是「漏报」⇒ 可以接受，重跑一次即消失。

③ ★★ 覆盖不到「本次启动派生出来的孤儿」
   什么时候：客户端自己 fork 出子进程，而那个子进程改了父进程
             （或已脱离进程树），它就**不在**启动时的 PID 差集里。
   怎么表现：SURVIVORS=0，但系统里其实还有一个残留进程。
   ★ 这是最该写清楚的一条，批末报告可直接引用下面这句话：

   ┌────────────────────────────────────────────────────────────┐
   │ 「SURVIVORS 只覆盖本次启动 PID 差集内的进程，                        │
   │   覆盖不到派生孤儿；它能证明『我起的那些都没了』，               │
   │   不能证明『系统里没有残留』。」                                  │
   └────────────────────────────────────────────────────────────┘
```

★ 三条的共同教训：**这条检查的结论强度是「我起的那些没了」**，
不是「机器干净了」。批末写结论时别把它放大。

### 6.6 ★★ 给下一个改这个脚本的人：判据要锚在「真正执行的那一行」

本轮修 `SURVIVORS` 时，我在**自己的门禁**上连踩三次「判据锚错对象」，
三次都是同一族错误 —— 与本会话反复出现的「行号会漂、代码形态不会」同源：

```text
★ 原则：行号会漂、代码形态不会；而**注释里逐字写着旧代码**，
        比行号更容易骗人（它不改行号，却会在文本匹配里先被命中）。

踩坑①  判据用 indexOf('PidListForManifest') 找留档
       ⇒ 命中的是**注释里提到它的那行**（偏移 1042），
         真正的语句在偏移 300 ⇒ 报出一个「留档在清空之后」的假红。
       修法：判据先**剔除注释行**，只对真正执行的语句做顺序判定。

踩坑②  判据用固定窗口 substring(anchor-900) 去找 $left 的定义
       ⇒ 那 900 字符里全是别的 Step/Ok 行，$left 根本不在里面
         ⇒ 恒失败（与「恒绿」同源的另一种假判据）。
       修法：改成按锚点 lastIndexOf 定位，不再用魔法窗口长度。

踩坑③  判据用 indexOf('SURVIVORS=') 找打印点
       ⇒ 先命中**注释**里写的 `SURVIVORS=<n>`，不是 Write-Host 那行。
       修法：锚点改用 `Write-Host ("SURVIVORS=` 这一行本身。

★ 同族的一条（本轮 Lead 踩的）：未跟踪文件（`??`）的「看起来像既有代码」是假象 ——
        git diff 看不到历史，据此推断「不是我方改的」会错。
        ⇒ **先问一句，别推断。**

★ 门禁 test/zz_t66_e2e_shots_survivor_test.dart（+6，第③组真起进程）
  里面的 `_stopFnCodeLines()` 就是踩坑①的修法：剔注释后再判顺序。
```

### 6.7 批末必须贴的读数清单（缺一条都算没跑完）

```text
□ 三个隔离环境变量的 echo 输出（证明没碰真实数据目录）
□ app.so 字节数
□ [SHELL] FIRST_FRAME_RENDERED 那一行
□ Unhandled Exception 计数 = 0
□ §6.3 弹窗的截图绝对路径 + 字节数 + PNG 尺寸
□ `SURVIVORS=0`（脚本自己打印的那行，§6.4）
    ⚠️ **读不到这一行不许当成 0** —— 按 §6.5 第 ① 条写「未走到收尾判据」
□ ★ 明写哪些条目**没验到**（如 showUpdateDialog 真弹窗那条），不许含糊带过
□ ★ 若报告里要写「没有残留进程」，必须同时引用 §6.5 第 ③ 条那句限定
    （SURVIVORS 只覆盖 PID 差集内的进程，覆盖不到派生孤儿）
```
