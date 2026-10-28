# Agent Note: 源卡片的代理模式摘要行恢复常显（N5a）

Status: implemented

## Problem

Owner 反馈「把 具体插件 是否 直连还是走代理 这个功能给删除了」。取证结论：`ProxyPanel` 与每源代理配置**从未被删**（`_panels()` → `ProxyPanel(providerId:)` 一直在，`tvbox_aggregate_page.dart` 还复用了它）；真因是两个既有改动叠加后**入口消失了**——第 07 项（插件卡片点击展开）把 `_panels()` 从「恒渲染」改成「展开才挂载」，原卡片上恒显的「⚙ 直连 ⌄」摘要行随之从折叠态消失；用户点开卡片前再也看不到任何代理线索，感知就是"被删"。另发现 `settings_page.dart` 的 `_panels` 设计注释仍写着「ProxyPanel 永远显示」，与「展开才挂载」自相矛盾（注释漂移）。

## Decision

- 卡片正文新增 `_ProxyModeSummary` 私有组件：常显一行「⚙ {ProxyConfig.summary}」（直连 / 跟随系统 / 自定义·地址，摘要文案复用模型现有 getter，单一事实源）。
- 显示条件零占位垃圾：读取中或读取失败（测试环境无核心 DLL 必然抛错）→ `SizedBox.shrink()`，不占行高。
- 点摘要 = `onToggleDetails`（展开卡片），面板本体仍遵守第 07 项「展开才挂载」——摘要常显**不等于**面板常开。
- 数据走 `SourinApi.proxyConfigWithPassword`（内部 `ProxyCache` 共享缓存，N 张卡只打 1 次全量 IPC）；`_ProviderCard` 与 `settingsProviderCardForTest` 各加一条 `loader` 测试缝，测试注入假 loader 驱动真实渲染。
- 同批修正 `_panels` 的过时注释，写明摘要行与面板挂载的分工。

## Alternatives considered

- **把 `ProxyPanel` 改回恒渲染（撤掉第 07 项的展开门控）**——最强理由：改动最小、一行都不用加。否决：第 07 项是为了修"26 张卡恒挂面板"的回归簇（39 项测试被打断的教训），撤掉等于把已收口的回归放回来。
- **给「配置」弹窗重新挂 `ProxyPanel(defaultOpen: true)`**——理由：弹窗场景语义本来如此（`defaultOpen` 的注释先于代码）。否决：js 插件普遍没有 config 声明，「配置」现在分派到编排器/表单，再塞代理弹窗会把三条路径搅在一起；而且 Owner 的诉求是"在卡片上看到"，不是"在弹窗里看到"。
- **把摘要塞进现有 `_sourceMetaText` 行**——理由：不加行高。否决：该行是 `@type/@updated` 元信息且"两样都缺整行不画"，混入异步加载的代理摘要会破坏它的确定性渲染契约。

## Consequences

- 收益：折叠态一眼可见每个源的代理模式（直连/跟随系统/自定义·地址），Owner 报的"功能被删"消除；点击直达面板，层级没有变深。
- 代价：每张卡多一行（~20px），26 张卡的列表整体变高；新增 26 次缓存读（共享缓存下是 1 次全量 IPC 的重复读，量级可忽略）。
- 边界：`onActivate == null` 的调用方（将来的搜索预览卡）只展示不可点；测试环境无 DLL 时整行消失属预期形态。

## Testing

- 新门禁 `test/zz_t1054_proxy_mode_summary_test.dart`（2 用例 4 断言）：自定义摘要常显地址 + 点摘要展开（`ProxyPanel` 才挂载）；直连可见 + loader 抛错零尺寸。
- 注入证明能红：把摘要挂载包进 `if (false)` ⇒ `+0 -2`、退出码 1（`.probe/n5a-injectA.log`），恢复后 `+4` 全绿（含既有 `settings_plugin_experience_test` 两用例）。
- 测试坑（记录）：换 loader 的第二个 `pumpWidget` 若不加 `KeyedSubtree` 换树，Element 复用旧 State、旧 cfg 残留——验的会是 State 缓存而不是"失败 ⇒ 零尺寸"。

Independent: 本篇记录 2026-10-27 批内一次具体改动的决策；已按标题关键词在 .agents/notes 全树检索（同日与相关主题），未发现记录同一决定的笔记，故不构成取代关系。正文未改，仅补声明。
