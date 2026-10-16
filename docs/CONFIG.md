# 配置说明

> 本文原为根 [README.md](../README.md) 的「配置说明」一节，2026-10-15 拆分到 `docs/`，正文未改写。
> 文档地图见 [docs/README.md](README.md)；开发硬约束见 [docs/AGENTS.md](AGENTS.md)；
> 提交与评审纪律见 [CONTRIBUTING.md](../CONTRIBUTING.md)。

---

# 配置说明

> 本文是最详细的一篇 —— 所有可调项、它们存在哪、怎么手改。

配置分**三层**，从「用户点的」到「系统级的」：

```text
① 界面设置      设置页里能点的开关与滑杆        → ui-prefs.json
② 数据目录文件  源列表 / 订阅 / 同步 / 数据库   → 见 [DATA-DIR.md](DATA-DIR.md)
③ 环境变量      编译期与运行期的逃生开关        → 进程环境
```

## ① 界面设置（`ui-prefs.json`）

全部偏好都是**扁平键值对**，存在 `<数据目录>/ui-prefs.json`。
文件不存在 / 损坏时**降级为空偏好**（不会让应用起不来）。

### 外观

| 键 | 取值 | 默认 | 说明 |
|---|---|---|---|
| `dsh.theme` | `system` / `light` / `dark` | `system` | 跟随系统 / 浅色 / 深色 |
| `dsh.pageTransition` | `slideRight` / `fade` / `slideUp` / `zoom` / `fadeUp` / `none` | `slideRight` | 页面切换动画风格 |
| `dsh.homeSource` | 源 id | 空 | 首页默认站点 |

### 窗口

| 键 | 取值 | 说明 |
|---|---|---|
| `dsh.window.bounds` | `x,y,w,h` | 上次的窗口位置与大小。**会自动夹进显示器工作区**（扣掉任务栏）—— 换分辨率 / 拔掉副屏后不会跑到屏幕外 |
| `dsh.closeAction` | `ask` / `tray` / `quit` | 点 X 的行为。`ask` = 每次都问；选过一次之后自动记住 |

### 播放

| 键 | 取值 | 默认 | 说明 |
|---|---|---|---|
| `dsh.playprefs.lastVolume` | 0 ~ 100 | 95 | 上次的音量 |
| `dsh.playprefs.lastSpeed` | 0.5 ~ 3.0 | 1.0 | 上次的倍速 |
| `dsh.playprefs.endAction` | `none` / `next` / `loop` | — | 播完之后干什么 |
| `dsh.playprefs.episodeStartAction` | `fromStart` / `prompt` | `fromStart` | 切集时从头播放或显示提示 |
| `dsh.playprefs.countdownBeforeNext` | 秒 | — | 「下一集」倒计时秒数 |
| `dsh.playprefs.keepSourceOnNext` | `0` / `1` | — | 连播时保持当前源（不自动换源） |
| `dsh.playprefs.autoSkip` | `0` / `1` | — | 自动跳过片头片尾 |
| `dsh.playprefs.hwdecMode` | `auto` / `auto-safe` / `no` / … | `auto` | 硬解模式，直接透传给 mpv 的 `hwdec` |
| `dsh.playprefs.videoZoom` | 50 ~ 200 | 100 | 画面缩放百分比 |

> `hwdecMode` 是最常需要手改的一项。播某些老片源花屏 / 黑屏时，改成 `no`（软解）
> 通常能解决 —— 在设置页「播放与下载」里就能切，不用改文件。

### 下载

| 键 | 取值 | 默认 | 说明 |
|---|---|---|---|
| `dsh.download.concurrency` | 0 ~ 8 | 4 | **片段**下载的并发数（0 = 不限制）。整片下载**不走这个** —— 它固定串行，把带宽留给播放 |
| `dsh.cache.limitMb` | 64 / 128 / 256 / 512 | 256 | 片段缓存上限。超了从**最旧**的开始删 |

> **整片下载不受缓存上限管**。它落在 `视频/源影/<剧名>/`，是你自己的文件，
> 不会被自动淘汰 —— 否则下一集就会把上一集删掉。

### 弹幕

| 键 | 取值 | 默认 | 说明 |
|---|---|---|---|
| `dsh.danmaku.enabled` | `0` / `1` | 1 | 弹幕总开关 |
| `dsh.danmaku.fontScale` | 见设置页滑杆范围 | — | 字号缩放 |
| `dsh.danmaku.opacity` | 见设置页滑杆范围 | — | 不透明度 |
| `dsh.danmaku.speed` | 见设置页滑杆范围 | — | 滚动速度 |
| `dsh.danmaku.area` | 见设置页滑杆范围 | — | 显示区域（占屏比） |
| `dsh.danmaku.appId` | 字符串 | 空 | 自定义弹幕服务器的 AppId |
| `dsh.danmaku.appSecret` | 字符串 | 空 | 自定义弹幕服务器的 AppSecret |

> ⚠️ **`appId` / `appSecret` 目前是明文存在 `ui-prefs.json` 里**。设置页里也如实
> 写明了这一点。只有你自己填了自定义弹幕服务器才会用到；外部视频站弹幕走扫码登录的
> cookie，不需要这两项。

### 字幕

| 键 | 取值 | 默认 | 说明 |
|---|---|---|---|
| `dsh.subtitle.enabled` | `0` / `1` | 1 | 字幕自动加载总开关 |
| `dsh.subtitle.autoLoad` | `0` / `1` | 1 | 播放时自动匹配外挂字幕 |
| `dsh.subtitle.languages` | 逗号分隔 | — | 优先语言（如 `zh,en`） |
| `dsh.subtitle.lastKeyword` | 字符串 | 空 | 上次搜索字幕用的关键词 |
| `dsh.subtitle.attribution` | `0` / `1` | 1 | 是否显示字幕来源标注 |

### 源偏好

| 键 | 取值 | 说明 |
|---|---|---|
| `dsh.srcpref.<provider>:<id>` | 源 id | 每部剧**单独记住**上次用的源。换源之后下次打开还是那个源 |
| `dsh.bili.*` | — | 外部视频站相关（登录态、自动更新开关与间隔、上次同步时间） |

## ② 数据目录文件

| 文件 | 内容 | 能否手改 |
|---|---|---|
| `ui-prefs.json` | 上面所有界面偏好 | ✅ 改完重启生效 |
| `provider-order.json` | 源列表的顺序 | ✅ 数组顺序 |
| `disabled-providers.json` | 被停用的源 id | ✅ |
| `third-party-providers.json` | 第三方源持久化 | ⚠️ 一般别手改 |
| `tvbox-sources.json` | TVBox 订阅来源（每个源从哪个配置来的） | ✅ 可手填链接 |
| `remote-pref.json` | 手机遥控的开关与端口 | ✅ |
| `sync-settings.json` | WebDAV 云同步配置 | ⚠️ **密码不在这个文件里**（走系统凭据存储） |
| `dsh-media.db` | SQLite：收藏 / 历史 / 进度 / 片头片尾 | ⚠️ 建议只读 |
| `plugins/*.js` | 已安装的插件 | ✅ 见 [PLUGINS.md](PLUGINS.md) |
| `plugins/.data/*.json` | 插件的私有数据（如 外部视频站 cookie） | ⚠️ 含凭据 |
| `logs/` | 运行日志（按天） | ✅ 排查问题看这个 |
| `mpv-cache/` | 播放缓存 | ✅ 可随时删 |
| `clip-cache/` | 片段下载缓存 | ✅ 可随时删（设置页有「清空」） |

## ③ 环境变量

### 编译期（`--dart-define`）

| 变量 | 说明 |
|---|---|
| `DATA_DIR_OVERRIDE` | 覆盖数据目录。**开发与测试必用** —— 指到临时目录就不会碰到你正在用的真实数据 |
| `DANDANPLAY_APP_ID` | 外部弹幕服务的官方 API 凭证（AppId）。仓库里只有空占位符，发版时构建期注入（见下发版说明）；空缺时回落到用户自填凭证 |
| `DANDANPLAY_APP_SECRET` | 外部弹幕服务的官方 API 凭证（AppSecret）。**敏感值** —— 只放 GitHub secrets，绝不写进仓库 |

```bash
flutter build windows --release -t lib/shell.dart \
  --dart-define=DATA_DIR_OVERRIDE=D:\tmp\sourin-dev
```

> ⚠️ 这一条很重要：**真实用户数据目录是 `%APPDATA%\app.sourin.player`**，
> 里面有真实的收藏、进度、片头片尾。开发调试时一定要用 `DATA_DIR_OVERRIDE` 隔离，
> 否则一次写探针就可能把用户数据改掉。

#### 外部弹幕服务凭证（发版说明）

外部弹幕识别（番剧/条目匹配）需要一对官方凭证：`DANDANPLAY_APP_ID` /
`DANDANPLAY_APP_SECRET`。开源仓库里只有空占位符 —— 发版时由 GitHub Actions
在构建期注入真值（该服务的官方文档「安全注意事项」允许开源客户端这么做）：

1. 到该外部弹幕服务的开放平台申请一对 AppId / AppSecret。
2. 本仓库 **Settings → Secrets and variables → Actions** 里新增两个 secret：
   `DANDANPLAY_APP_ID` 与 `DANDANPLAY_APP_SECRET`。
3. `.github/workflows/build.yml` 已接好通道：凭证 env 只挂在三个平台的
   **构建那一步**（`env: DANDANPLAY_APP_ID: ${{ secrets.DANDANPLAY_APP_ID }}`，
   Secret 同理）—— 不挂 job 级，避免「全量测试」与第三方 Action 也读到 Secret
   （最小权限）。构建命令自动追加对应 shell 语法的引用：Windows 是
   `--dart-define=DANDANPLAY_APP_ID="$env:DANDANPLAY_APP_ID"`，macOS / Android
   是 `--dart-define=DANDANPLAY_APP_ID="$DANDANPLAY_APP_ID"`。
4. fork 的 PR 拿不到 secrets（GitHub 内建规则）⇒ 构建出的包与未配置时行为逐字一致：
   App 回落到用户自填凭证，无需任何额外处理。

⚠️ 凭证真值只允许存在于 GitHub secrets 与开发者本机环境，**永远不要**写进
README、源码、issue 或截图。

### 运行期（进程环境变量）

| 变量 | 取值 | 说明 |
|---|---|---|
| `SOURIN_DRAG_SELFTEST` | `1` | 启动时跑一次「标题栏拖拽」自检然后退出。结果写到 `%TEMP%\sourin_drag_selftest.txt` |
| `SOURIN_WF_DEPENDS_ON_SIZE` | `0` | 让窗口边框**不**注册尺寸依赖（模拟修复前的行为，用来复现「白角」）。**只用于验证** |
| `SOURIN_NO_REMOTE_AUTOSTART` | 任意 | 不自动启动手机遥控服务 |
| `SOURIN_PREFETCH_DISABLE` | 任意 | 关掉流代理的预取。★ 在**构造** `StreamProxy` 时读一次并存进实例字段（2026-10-08 改）—— 改前是每次请求现读全局，会让并发跑的测试互相干扰（见 `streamproxy.rs` 的 `prefetch_switch_is_per_instance_not_process_global`） |
| `SOURIN_PREFETCH_DEBUG` | 任意 | 打开预取的调试日志 |

> 默认全部**关闭** —— 生产行为与不设这些变量时逐字相同。
