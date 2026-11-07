# Agent Note: 开发数据目录播种只读真实目录，凭据一律不带

Status: implemented

## Problem

`-Dev` 起来时是一间空数据目录，只有核心自释放的 demo 插件 ——
插件调试、追更、播放进度一条都验不了。而把真实数据目录整份拷过去又是事故：
实测里面确含真实凭据（插件私有存储里有 token 与会话 cookie；
`ui-prefs` 的 53 个 key 里 35 个是用户观看痕迹：分P绑定 / 测速历史 / 源级偏好）。

## Decision

`-Dev` 起来前用 `tools/seed_dev_data.ps1` 把真实数据目录的**内容**播一份到隔离目录。
两条硬约束：**只读源目录**；**凭据类一律不拷**。

```text
拷   plugins/*.js            用户自己装的插件源码
拷   ui-prefs.json           按 key 过滤后的界面/外观/播放偏好
拷   状态 json + dsh-media.db 三件套（收藏/历史/进度/片头片尾）
拷   tvbox-sources.json      仅导入身份字段，不含订阅链接或更新结果
拷   tvbox-aggregate.json    仅启用/隐藏源 ID、solo 与格式版本
不拷 sync-settings.json / remote-pref.json / plugins/.data/
不拷 ui-prefs 的 dsh.bili.* / dsh.speedtest.* / dsh.srcpref.* / dsh.homeSource
```

播种是**单向**的：跑完源目录必须逐文件哈希不变。

适用：2026-11-07 起的播种脚本。聚合渠道以 `tvbox-sources.json` 判定导入来源，
因此它与 `third-party-providers.json` 必须一起进入隔离目录。只保留
`siteKey`、`siteName`、`api`、`installedAt`；`sourceUrl` 与
`lastUpdateError` 可能携带凭据，更新状态在无订阅链接的副本里也不沿用。
保持默认不覆盖、显式 `-Force` 重播的语义。

2026-11-08 补齐聚合选择播种：导入身份不能替代启用集合，空集合也必须原样
保留，不能把所有已导入子源自动启用。仅复制 `enabledSiteIds`、`hiddenSiteIds`
中的字符串和 `solo`，不携带 `pan` 分享文本、密码、备注或未知字段。外观白名单
同时加入 `dsh.appearance.logo`，保持隔离预览所选标识。假源的敏感字段诱饵、
默认保留、Force 重播、空选择和逐文件哈希测试均覆盖；纯净旧代码下新用例因
缺少聚合选择文件失败。

Independent: 播种只读且不带凭据。开发数据安全的一条独立规则。

## Alternatives considered

- **整份拷 `ui-prefs.json` / 整个 `plugins\`** —— 它最强的论据是简单且保真：
  拷得越全，开发环境越接近真实。否决理由：实测确含真实凭据，整份拷是事故。

- **拷贝 `sync-settings.json` 后「把自动开关改成安全值」** —— 它最强的论据是
  既不丢配置又不触发同步。否决理由：仍然把用户的网盘地址与账号搬进了临时目录；
  正确做法是**不拷**。

- **用 `-Target` 指到真实目录做「原地刷新」** —— 否决理由：那是写真实数据目录，
  已加硬闸拒绝（exit 2）。

## Consequences

- **收益**：临时目录里不出现用户凭据；开发环境具备真实的插件与观看状态。
- **代价与已知上限**：插件播过去后是「未配置」状态，要自己重新填。
  这个代价换的是「临时目录里不出现用户凭据」。
  TVBox 子站可按既有配置读取内容，但隔离副本不自动更新原订阅。
- **重访条件**：不加默认值。若确实需要带凭据调试，应做成**显式的**
  `-IncludeCredentials` 开关并在输出里回显警告，而不是放开白名单。
