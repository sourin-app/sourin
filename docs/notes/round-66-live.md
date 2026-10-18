# 第 66 轮 · 直播侧汇总

> 本文件汇总本轮**直播相关**的修复。
> 每一笔都写明：缺陷 → 根因 → 改法 → 验证 → **已知局限**。
> 最后一节如实记录本轮出现的**假绿教训**，包括 Lead 与本人各自犯的错。

**行号说明**：所有行号在写作时用 `grep` 重新核对过（本仓行号几小时内会漂）。
若与当前源码不符，**以代码为准**，不要相信本文件的数字。

**提交范围**（6 笔，均已核实存在于 git 历史）：

| 提交 | 主题 |
|---|---|
| `8e8be90` | 直播暂停意图 —— 状态回传 |
| `1841531` | 暂停门禁从「纸糊」修成「真的会红」 |
| `bbf119c` | 探测结论只镜像了 1/4 |
| `9085c74` | 探测结果在页面卸载时被丢弃 |
| `3ada995` | 筛选条「菜」缺陷 |
| `ddb0794` | 播放页 N11 鼠标卡顿（底栏装卸） |

---

## 一、直播暂停意图（`8e8be90` + `1841531`）

### ① 缺陷（Owner 原话 + 现象）

Owner 报的症状是：**进详情页暂停后返回，仍在播放**（暂停意图丢失）。

### ② 根因

`_playing` 是**回报的现状**，不是**用户的意图**。两者在这些场景下会分歧：

```text
· 进全屏 ⇒ 直播页会 pause 内嵌播放器（不是本页）
· 选集抽屉 ⇒ 本页自己 pause（_pausedForEpisodeSheet）
· 全屏里切台 ⇒ 内嵌播放器被主动停
```

⇒ 拿 `_playing` 当判据，会把「我们暂停的」当成「用户要暂停的」，
回到直播页后该自动接手的场景反而变成**黑屏**。

### ③ 改法

新增 `bool? _userWantsPause`（`lib/ui/player_page.dart:1518`），
**只在用户手势的那一个入口**写：

```text
:11294   _userWantsPause = true;
:11297   _userWantsPause = false;
:14033   Navigator.of(context).pop<bool>(_userWantsPause);   ← 随 pop 带回
```

**为什么是三态 `bool?` 而不是 `bool`**：
```text
null = 用户**从未表达过**意图 ⇒ 直播页保持原行为（不做任何自动操作）
false = 用户明确表示要播
true  = 用户明确表示要停
★ 压成两态（bool）会把「没表态」误判成「要播」或「要停」，
  两者都是编造用户意图。
```

**放弃的方案**：监听 `_playing` 变化来推断意图 —— 无法区分「我们停的」
和「用户停的」，正是缺陷本身。

### ④ 验证

`1841531` 把门禁从「纸糊」修成「真的会红」：3 种注入现在全红。

### ⑤ ★ 已知局限

- 三态语义**曾是两态**（Lead 自己引入的缺陷，见最后一节）。
- 门禁最初有 2 条是纸糊的（`indexOf` 起始位置 + 源头没测），已修。

---

## 二、直播可用性持久化（`bbf119c` + `9085c74`）

### ① 缺陷

Owner 抱怨「**迟早要被拉黑**」—— 每次启动对全部频道做可用性探测。

### ② 根因（两笔，两个不同缺陷）

**`9085c74`：结果在页面卸载时被丢弃**
```text
真实进程实测：876 次请求之后，`live-availability.json` 仍然 **MISSING**
⇒ `_mirrorProbeIntoHealth()` / `_persistHealth()` 永远到不了落盘那一步
```

**`bbf119c`：探测结论只镜像了 1/4**
```text
落盘内容 = `{"data":{}}` ⇒ 下次启动读到空 ⇒ 仍然全量重探
```

### ③ 改法

```text
:1860   Future<void> _loadHealthThenMaybeProbe()   ← 先读盘，再决定要不要探
:1832   void _mirrorProbeIntoHealth()              ← 探测结论翻译成健康状态
:1530   unawaited(_loadHealthThenMaybeProbe());
```

逻辑：
```text
① 读 <dataDir>/live-availability.json
② 有**未超过 10 分钟**的条目 ⇒ 灌进 _health 与 _probe，**完全跳过探测**
③ 没有 ⇒ 延迟 _probeDelay（30 秒）再探
```

★ 过期条目**保留不删**：Owner 要求「定时再刷新掉状态」，
直接清掉会让灰/红点突然消失，用户以为状态丢了。

### ④ 验证

跑真实进程验证「876 次请求 → 缓存命中」，而不是只跑单元测试。

### ⑤ ★ 已知局限

10 分钟/30 秒这两个数字是**拍的**，没有做过网络行为实测
（多少 QPS 会被判定为滥用）。Owner 的「拉黑」风险仍有残余。

---

## 三、筛选条「菜」缺陷（`3ada995`）

### ① 缺陷（Owner 原话）

> 直播页面,右侧搜索框显示很奇怪

现象：筛选条第三格显示成一个「**菜**」字。

### ② 根因

`lib/ui/live_page.dart:4724` 附近，`_BarDropdown` 的 `Row` 是：

```text
ConstrainedBox(maxWidth: 88) > Text(ellipsis)   然后**硬跟** Icon(15px)
```

`Row` 默认让非 flexible 子项**先按自己的意愿要空间**，而 `Icon` 是
**不可压缩**的：

```text
总宽 = 88 + 15 = 103px
格子 = 80.7px（右栏固定 300px ÷ 3 格）
⇒ 溢出 22.3px ⇒ 箭头被推出格子右边界
⇒ 压到相邻的「管理」图标上
⇒ 三者叠在一起 = 看起来像一个「菜」字
```

**「菜」不是字体问题**（我一度怀疑树摇字体缺字形，已排除：
打包字体的 `maxp.numGlyphs = 165` 是正常的树摇结果，且 `AppIcons` 全是 `const`）。

**触发条件**：`categoryDisplay: _groupFilter ?? '分类'` ——
用户**选中一个长分类名**才会触发。真实数据里最长 8 字：

```text
"TVBox 直播" / "科教·生活·科学" / "地下城与勇士" / "三角洲行动"
（`.probe/t66_real_names.txt`，30 个名字）
```

★ 我第一版探针只测了 fallback 字符串「全部分类」（4 字），
**没测真实长名字** ⇒ 测不出来。Lead 指出这一点后改成读真实数据才复现。

### ③ 改法

```text
:4724   ConstrainedBox(maxWidth: 88) → Flexible
:4739   Icon(AppIcons.arrow_drop_down, size: 15)   保持不变（不可压缩）
```

`Flexible`（`fit: loose`）⇒ Text 只拿「剩余可用宽」，拿多少 ellipsis 多少
⇒ Row 永不超 ⇒ **箭头永远可见、永不出格**。

**顺带删掉 `maxWidth: 88`**：它在 80.7px 的格子里**比可用宽还大**，
完全没起作用，只是把溢出从 `Text` 挪到了 `Row`。

**fallback 缩短**（B 部分）：
```text
:4114   groupDisplay:  「全部分组」→「分组」
:4124   categoryDisplay:「全部分类」→「分类」
        sourceDisplay: 「全部源」 →「源」
```

**Tooltip 补全**：改前 `message: tooltip ?? ''`，只有「源」那格传了 tooltip
⇒ 分组/分类两格**悬停什么都不显示**。改成 `tooltip ?? display`。

### ④ 验证

| 项 | 改前 | 改后 |
|---|---|---|
| 文字实际宽 | 79.8px | 53.7px（ellipsis 生效） |
| 需要宽 | 96.0px | 96.0px |
| 箭头 | **被挤出格子** | 完整可见 |
| 相邻重叠 | 是 | **false** |

门禁 `test/zz_t66_live_filterbar_test.dart`（6 条），故障注入 6 红。

★ **1 条注入无效，如实记录**：`Flexible(child: Icon(...))` **没让测试变红** ——
Icon 是无内在宽度的渲染盒，包进 Flexible 后仍按 15px 布局，
该宽度下不触发挤压 ⇒ **这个注入「语法上像故障但语义无变化」**，
不可当作验证。换成「真删箭头」「文字改 ConstrainedBox(200)」后都能红。

### ⑤ ★ 已知局限

```text
**长名字仍然截断。**
300px 右栏每格 80.7px，8 字名字要 96px，改后显示「科教·生…」（约 4 字）。
A+B 修掉的是**视觉错乱**（箭头不再被挤掉、不再重叠、不再出现「菜」字），
**不是**「显示不全」。

缩短 fallback 省的 24px 在**选中长名字时不受益**（那时显示的是名字本身）。
要完全显示需要改布局（窄容器只显示 2 格 / 加宽右栏），
那会动 task-34 的信息架构，**本轮不做**。
```

---

## 四、播放页 N11 鼠标卡顿（`ddb0794`）

### ① 缺陷（Owner 原话）

> 播放页那个鼠标动一下 出现控件，也很卡顿

### ② 根因

`lib/ui/player_page.dart:15435` 附近，底栏包装层是 `shrink ⇄ child` **装卸**：

```dart
// 改前
final keepForFade = !_bottomOccupied && _controlsAnim.value > 0;
if (!_chromeVisible && !keepForFade) return const SizedBox.shrink();
return child!;
```

`child` 是整个 `_BottomBar`（**333 行 / 128 个后代元素**）。
控制条一收起 ⇒ 返回 shrink ⇒ 整棵子树 **deactivate**；
鼠标一动叫回来 ⇒ **重新 activate**。

实测「叫回」那一次重建 **398** 个元素 / **85ms**：

```text
IconTheme×22, DefaultSelectionStyle×22, GestureDetector×17,
RawGestureDetector×17, Focus×13, Actions×12, InkWell×11,
_MaterialInterior×11, _ShapeBorderPaint×11 …
8 轮 all = 8/398/8/398/… 合计 1624（门禁自带改前基线 188，涨 8.6 倍）
```

### ③ 改法

```dart
// 改后
if (_bottomOccupied) return const SizedBox.shrink();  // 占据态：原样卸下
return child!;                                        // 其余：恒挂，只翻 opacity
```

**为什么只需 4 行**：淡出**底栏自己早就做好了** ——
`lib/ui/player/player_bottom_bar.dart:752-754` 已有
`IgnorePointer → Opacity`，由 `fade` 驱动，而 `fade` 就是 `_bottomFade`
（与顶栏**同一个** `_controlsFade` 实例）。
⇒ 包装层只需负责**结构**问题：占据态要不要留在树上。

**占据态仍整条卸下**：`_bottomOccupied`（错误层/选集/换源/设置/弹幕/
字幕/直播频道/音频提示/画面死亡）时那块归占据者 ——
留在树里会 ① 叠字 ② 抢点击。

### ④ ★★ 我在这一笔里**推翻了自己的假设**（值得记）

```text
我最初判断（Lead 按代码结构核实过）：`_TopBar` 重建面太大。
实测：_TopBar 内重建 = **1**，_TopBar 外 = **397**
⇒ 假设错误。`_TopBar` 当初的改法（常挂 + Opacity）**是对的**，
  缺的是底栏这半边没同步改。
```

**方法上的教训**：Lead 核实的是「代码结构长什么样」，这没错；
但**结构存在 ≠ 它是重建的来源**。必须实测「谁在重建」。

### ⑤ 验证

| 项 | 改前 | 改后 |
|---|---|---|
| 8 轮 all | 1624 | **20**（81×） |
| 帧 p50 | 55ms | **1.6ms**（34×） |
| 帧 max | 73ms | **2.0ms**（36×） |
| 淡出曲线 | `1.00→…→0.00` | `1.00→…→0.00`（**同形，未变硬切**） |

门禁 `test/zz_t66_n11_bottombar_test.dart`（5 条），故障注入 3 红。

★ **注入 1 精确复现 `all=1624`** —— 与改前基线一字不差
⇒ 证明这个数字就是缺陷本身，不是量错了。

### ⑥ ★ 已知局限

```text
· 85ms 是 flutter_tester + software rendering 的读数，真机会低。
  但 8.6 倍（188→1624）这个**相对**对比有效。
· 真正判据是「切换时重新插入 333 行子树」这个**结构性事实**，
  它与渲染后端无关。
· `t72_jank` P0、`zz_t66_player_jank` P0/T1/T2 是 **pre-existing 红**
  （逐个核对过基线），本次未处理。
  ★ 其中 `zz_t66_player_jank` 的 **T6 本次由红转绿**。
```

---

## 五、★ 本轮直播侧的「假绿」教训

> 这一节如实写，**包括 Lead 犯的错**和**本人犯的错**。
> 详细目录见 `docs/notes/round-66-fake-green-catalog.md`。

### A. 门禁只测「代码写了」，不测「运行时执行」

```text
· `t72_jank_test` 只在**窗口模式**跑，而 `_noteCursorActivity()` 第一行是
  `if (!_fullscreen) return;` ⇒ 光标那条路径在它里面**从不执行**。
  ⇒ 「t72 绿着 + 用户觉得卡」并存的结构性原因。
· `LiveChannelList.header` 从未被渲染（构造了但没人挂）。
· `AppTextButton` 零调用点。
```

★ 共同点：**判据是「源码里存在某个字符串」，而不是「运行时真的发生了」。**

### B. 规则钉住实现细节

**本人犯的（`keepForFade` 那条）**：
```text
t27_w13_chrome_ssot_test.dart A3 / t27_w13_defect4_bar_linkage_test.dart B2
原本逐字钉住：
  expect(page.contains('if (!_chromeVisible && !keepForFade) {'), isTrue);
  expect(RegExp(r'keepForFade =[\s\S]{0,120}?_controlsAnim\.value\s*>\s*0')...);
```
N11 的修复让 `keepForFade` **不再需要**（底栏恒挂）⇒ 变量消失**恰恰是改进**，
但门禁红了。

**修法（不是换字面量）**：改成断言**契约**——
```text
① 不许用 `_chromeVisible` 决定「要不要卸下底栏」（这才是「同源」的真实意图）
② 底栏必须喂 `fade: _bottomFade`（与顶栏同一条动画）
③ 只在 `_bottomOccupied` 时卸下
```

**★ 关键验证**：新门禁在**旧实现**下必须红（否则就是把好门禁改成废门禁）。
实测：旧实现 ⇒ A3 红 + B2 红 ✅ / 新实现 ⇒ 13/13 绿 ✅ /
注入 A（fade 换别的 Animation）⇒ A4+B2 红 ✅ /
注入 B（删掉占据态分支）⇒ A3+T2 红 ✅。

### C. Lead 犯的错（如实记录）

**① 9 条 pause 门禁里有 2 条是「纸糊」的**
```text
· `indexOf` 起始位置错 ⇒ 搜到的不是那一段
· 「源头」没测 ⇒ 只验了下游，上游改了也不会红
⇒ `1841531` 已修成「3 种注入全红」。
```

**② 三态被压成两态（自己引入的缺陷）**
```text
`_userWantsPause` 本应是 `bool?`（null = 用户从未表态）。
压成 `bool` 会把「没表态」误判成「要播」或「要停」——
两者都是**编造用户意图**。
⇒ 现已恢复三态。
```

### D. 本人的其他失误（一并记录）

```text
· 「菜」的第一版探针只测 fallback 字符串，**没测真实长名字**
  ⇒ 测不出来。Lead 指出后改成读真实数据才复现 96px。
· `Flexible(child: Icon)` 注入**无效**（语义无变化），
  我一开始把它当成「门禁通过」的证据 —— 已改成「真删箭头」重测。
· SourceBar 探针第一版把 `GlassCard` 包在 `Scaffold(body:)` 上，
  报 99.3% —— 那测的是「整个 body 玻璃化」，不是「SourceBar 玻璃化」。
  修正为 `SizedBox(height:52, width:560)` 约束后得 **39.6%**。
· 我一度怀疑打包字体缺字形（20KB vs 1.6MB），
  实测 `maxp.numGlyphs = 165` 是**正常的树摇结果** ⇒ 排除。
```

### E. 一条通用判据（本轮反复验证有效）

```text
★ 故障注入后如果**没红**，先判断是「门禁弱」还是「注入无效」。
  「语法上像故障但语义无变化」的注入**不可**算作验证通过。
★ 新写的门禁必须证明它在**旧实现**下会红 —— 否则它可能是恒绿的摆设。
```

---

## 六、本文件未覆盖的部分（明确边界）

```text
· 设置页家族玻璃化 ⇒ **本轮裁决不做**。
  理由：`SettingsBlock` 是共享组件（实测 lib/ui/ 下 32 处 / 13 个文件），
  `live_groups_page` 只占 3 处。改它 = 一次性改动 13 个设置页外观，
  且会让 live_groups 成为「13 个设置页里唯一的异类」——
  与 Owner 要的「风格契合」**相反**（契合对象应是同一家族）。
  ⇒ 作为**独立下一轮任务**（一处改、13 页同时生效、一次性验截图+性能）。
· 截图/像素读数见 `.probe/shots/t66/`，原始读数见 `.probe/t66_*.txt`。
```
