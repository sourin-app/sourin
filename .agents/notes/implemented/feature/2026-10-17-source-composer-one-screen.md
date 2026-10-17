# Agent Note: 源编排器从三步向导改成一屏分区卡片，并接进编辑入口

Status: implemented

## Problem

Owner 原话：

> 点击编辑还是老样子的配置,没有可见的可视化编排,这里肯定也要用到modal,一起给换了

核实后是三件事叠在一起，而不是「没做」：

```text
① 编排器**是三步向导**（source_composer_dialog.dart 的 _step 0/1/2），
   每步一屏，必须点「下一步」。
   问题不在丑，在**它逼用户按实现的顺序思考**：
     · 想改一个 JSONPath，得先点两次「下一步」走过去
     · 走到第 3 步时看不到第 1 步填了什么（要退回去核对）
     · 端点顺序决定 JSON 里 endpoints 的键序，而三步表单里**根本排不了序**

② 从「编辑」入口**到不了**编排器：
   _editProvider 对 declarative 走 ProviderImportDialog.showEdit
   ⇒ 一个**裸 JSON 文本框**。编排器只在导入弹窗里有个按钮（provider_import_dialog.dart:644）。

③ 更隐蔽的一条：那个按钮调 SourceComposerDialog 时**没传 initial**
   ⇒ 从编辑进去点「可视化编排」，编排器是**空白**的，编辑已有源等于从零重填；
   而且编完只写回 JSON 文本框，用户还得再点一次「保存」。
```

## Decision

① 编排器改成**一屏两栏**：左栏三块分区卡片（站点 / 端点 / 字段映射），右栏常驻实时预览。
   没有「下一步」，三块同时在屏。

   为什么是左右两栏而不是上下堆叠：
   ```text
   上下堆叠时，用户改上面的字段、预览在下面看不见（要滚动）。
   而本条的核心验收是「改字段 → 预览立即更新」——看不见的更新等于没更新。
   ⇒ 右栏必须**常驻可见**。
   ```
   窄屏（< 760dp）退化成上下，但仍是**同一屏**，不是另一步。
   760 这个数是算出来的：弹窗 860 − padding 48 = 812，两栏各 396dp，
   左栏「标签 132 + 输入框」还剩 264dp 够填 JSONPath；
   手机 411dp 时两栏各 171dp、输入框只剩 39dp —— 不可用，所以退化。

② 端点拖拽排序，**拖完把新顺序写回 Map**：
   ```text
   只动显示用的 _order 就是「假拖拽」——界面上的行换了位置，
   但 _d.endpoints 的插入序没变 ⇒ toJson() 输出的键序照旧。
   用户拖了三下，保存出来的 JSON 一个字都没变。
   ```
   做法是按新序**整体重建** `_d.endpoints`（LinkedHashMap，插入序即迭代序）。
   实测过，不是推断：
   ```text
   DEFAULT keys = [categories, list, detail, search]
   REBUILT keys = [search, detail, list, categories]
   ```
   ⇒ 不必改 model 的跨文件契约，风险最小。

③ 编辑入口对 `kind == 'declarative'` 直达编排器，**带初值**、**提交即落盘**：
   ```text
   js           ⇒ 源码编辑器（配置就是源码）—— 一字不动
   declarative  ⇒ 本改动：composerDraftFromJson 还原初值 → 编排 → importDeclarativeProvider
   http         ⇒ ProviderImportDialog（要填 baseUrl + headers）
   ```
   提交后直接 import，不再写回文本框 —— 「编辑完还要回去点保存」正是这次被点名的那层别扭，
   一屏化之后它会**更明显**（没有「下一步」的仪式感兜着）。

④ 弹窗外壳**保持** AppDialogShell（width 860）—— 它本来就满足，不必换。

## Alternatives considered

**保持三步向导，只把步骤指示器做得更漂亮**
最强理由：改动最小，不碰数据流，回归面几乎为零。
否定原因：Owner 的原话是「没有可见的**编排**」，而向导的本质是「一次只看一部分」——
把它做漂亮仍是一次只看一部分。而且三步表单**物理上放不下拖拽排序**（排序需要看见全部端点）。

**把两个 TextField 直接塞进设置页一级列表**
最强理由：用户不用点进二级页。
否定原因：地址+Token+测试+状态是四个控件，一级页是行高 ~56 的入口行列表，塞进去破坏整页节奏；
且 Owner 要的是「能被发现」，一条带状态的入口行就满足。

**给 ComposerDraft 加 fromJson factory**
最强理由：解析逻辑和数据模型放一起，内聚。
否定原因：`source_composer_model.dart` 是纯数据层，被单测与 rust 侧契约共同依赖；
而「解析用户磁盘上那份 JSON」属于 UI 适配（要容忍缺字段、类型不对），
放 dialog 里可以随手改而不动跨文件契约。

**抽一个共享 widget，让弹幕面板与编排器复用表单**
未采纳：两者使用场景不同（播放中调节 vs 静态配置），硬绑在一起得不偿失。

## Consequences

**代价（必须说清）**
```text
· 卡片用 Material 而不是 Container(decoration:) —— 这是被测试逼出来的：
  ListTile 的底色/水波纹画在**最近的 Material 祖先**上，中间隔一层带底色的
  DecoratedBox 就全被盖住（Flutter 直接抛断言）。
· 窄屏退化成上下时，预览要滚动才看得到 —— 这是 411dp 下的取舍，不是遗漏。
· 编排器表单与弹幕面板的「自建服务」表单仍是两份（同一类取舍）。
```

**何时该翻案**
```text
· 若出现「编辑声明式源时想直接改原始 JSON」的真实需求 ⇒ 那时加一个「文本模式」切换，
  而不是把可视化拆掉。
· 若端点数量不再是固定的 4 个（比如插件能自定义端点）⇒ 拖拽列表要换成可滚动的，
  shrinkWrap + NeverScrollable 那个前提就不成立了。
```

**出处**
```text
lib/ui/widgets/source_composer_dialog.dart   （主改动：一屏 + 拖拽 + composerDraftFromJson）
lib/ui/settings_page.dart                    （_editProvider 加 declarative 分支 + 两个新方法）
test/task40_composer_visual_test.dart        （判据 ①②③④，7 条）
test/task40_composer_wiring_test.dart        （接线，4 条）
test/t135_source_composer_wiring_test.dart   （改为断言新行为：三块同屏 + 无「下一步」）
```

## Verification

### 真实应用（窗口截图，非无头渲染）

```text
SHOT1 从「编辑」入口打开编排器：① 站点 / ② 端点 / ③ 字段映射 **三块同屏**，
      右栏实时预览；底部只有「取消 / 保存」，**没有「下一步」**。
SHOT2 拖动中：「分类」被提起（带阴影）拖到「搜索」下方。
SHOT3 松手后：右栏 JSON 的 capabilities 与 endpoints 键序
      从 categories,list,detail,search → list,detail,search,categories。**真的变了。**
SHOT4 在 base 框输入后，右栏 JSON 的 base 行**立即**跟着变，全程没点任何按钮。
SHOT5 + SHOT6 保存终点：见下。
```

### 提交路径（Lead 点名必须补验的终点）

用独立测试源 `test-save-probe` + 独立数据目录，真机点「保存」，然后读回文件：

```text
改前磁盘： base = https://original.example.com
界面改成： https://saved.example.net
点保存后： base = https://saved.example.net.com     ← 见下方「如实说明」

落盘内容与预览 JSON **逐字段一致**：
  id=test-save-probe / name=保存探针源 / base=…（如上）
  capabilities = [list, detail]        （与预览一致）
  endpoints    = [list, detail]        （与预览一致，且键序一致）
```

**清场**：UI「移除这个源」→ 确认 → 磁盘 entries 从 1 变 **0**，卡片从「1 个」变「0 已启用」。
沙盒数据目录已整体删除，真实 `%APPDATA%\app.sourin.player` 全程未被触碰。

### 故障注入（四条，全部按要求变红）

```text
① 预览不跟随输入（去掉 onChanged 里的 setState）
   → 判据③ 红：Expected contains '改过的名字' / Actual '{\n'
② 假拖拽（只动 UI 顺序，不重建 Map）
   → 判据② **UI 层与数据层同时**红；Actual 仍为原顺序
③ 编排器不传初值（还原改前的真缺陷）
   → 判据④「带初值」红
④ declarative 分支挪到 js 之前（会毁掉 JS 插件编辑）
   → 判据④「JS 路径未破坏」红（顺序断言）
```

## 如实说明的已知限制

```text
· 拖拽只用鼠标验过；触摸与 TV 方向键焦点**未实测**。
  ReorderableListView 自带触摸支持，但方向键能否拖拽我不敢断言。
· 中文输入法在自动化里打不进去（IME 组合态），
  所以编辑验证用的是 ASCII 的 base 字段 —— 是工具限制，不是产品问题。
· 保存验证里 base 变成了 saved.example.net.com：
  我清空输入时按的是固定次数的退格，没退干净，残留了 '.com' 尾巴。
  ⇒ 这**不是**产品缺陷（预览里逐字显示的就是这个值，落盘与之完全一致）；
     反而顺带证明了「预览所见 = 落盘所得」。
```