# Agent Note: 把「此刻安全」变成「持续安全」—— 弹幕发送的三层守卫

Status: implemented

> 前序：[../../implemented/feature/2026-10-19-capability-bit-can-lie.md](../feature/2026-10-19-capability-bit-can-lie.md)
> （那篇讲「声明 true 但没实现」；本篇讲**声明 false 的安全性怎么被持续钉住**）
> 同族：[../process/2026-10-20-doc-promises-vs-code-consumers.md](../process/2026-10-20-doc-promises-vs-code-consumers.md)
> （那篇讲「文档承诺 vs 代码消费者」；本篇是它的**执行面**）

## Problem

`docs/notes/danmaku-send-status.md` 第 ⑤ 条回答过「现在这个状态对用户安全吗」，
用了三层证据：

```text
① 能力位 false，三处一致（源码 / dist / 用户数据目录）
② false ⇒ 底栏整条不渲染（真跑验证）
③ 源码里没有 canSend / disabledReason 逃生口
```

**但那是一次性的。**

```text
若明天有人把 danmakuSend 改成 true，
或加一个 canSend 逃生口
⇒ 安全性**静默消失**，而没有任何东西会报。
```

这是「判据要能区分『查了没问题』与『没查』」的反面：
**查了一次，但没有东西在持续检查。**

而状态文档里那句最关键的约束还是**散文**：

> 「打开能力位这件事必须与解决闸门同时做，不能先开再说。」

散文不是机制。

## Decision

### 三条判据（`test/zz_t66_danmaku_send_safety_gate_test.dart`）

```text
① **部署一致性**：凡存在的 danmakuSend，值必须相同
   ⇒ 某处 true 而另一处 false = 部署漂移，用户在旧版/新版行为不一致

② **无逃生口**：lib/ui/** 里不许出现能力位级别的 canSend / disabledReason
   ⇒ 这类字段 = 「按钮在但点不动」的形态，与本仓「不支持就不显示」口径冲突

③ ★ **前置联动**：danmakuSend == true ⇒ 必须有「WebGL 闸门已解」的证据
   ⇒ 否则主动红，并打印三条翻案条件
```

### ③ 没有退一步 —— 用的是「代码里真有解法」，不是「文档某节存在」

Lead 给了退路：「至少做成 danmakuSend == true 时测试主动红并打印翻案条件」。

**没退。** 因为「文档某节存在」这种证据，任何人写一段 Markdown 就能骗过门禁。
证据探测器认的是**真实代码**：

```dart
bool hasFingerprintConstruction(String text)
  ⇒ 非注释行里出现 `dm_img_str: ...` / `'dm_img_list': ...` 这类构造形态

bool hasHostFingerprintHook(String libDir)
  ⇒ lib/ 里出现 webglFingerprint / glFingerprint / fingerprintHook 这类注入点
```

任一命中 ⇒ 视为闸门已解；都没有 ⇒ 红。

### ★ 证据探测器必须区分注释（否则门禁可被一句话骗绿）

私库源码 `bilibili.ts` 里**现在就有** `dm_img_str` 这个词 —— 但它在**注释里**
（说明卡点）。若探测器不区分，谁在注释里写一句 `dm_img_str` 就能把门禁骗绿。

判据：

```text
注释行（`//` / `*` / `/*`）一律跳过
只认「出现在非注释行，且像构造代码」
⇒ 有专门的自检用例钉住这一点
```

### 作用域无关（本仓已踩过三次的坑）

```text
❌ 不写「必须有 3 处」          ⇒ CI 上只有 1~2 处 ⇒ 永远红
❌ 不写「必须有用户数据目录那处」⇒ CI 上没有 ⇒ 永远红
✅ 写「凡存在的处值必须一致」+「至少查到 1 处」
✅ 覆盖度显式打印：查了几处 / 跳过哪几处 / 为什么
```

## ★ 写这个门禁时抓到自己的一个假绿

第一版用 `File.fromUri(Platform.script).parent.parent` 定位仓根。实测：

```text
Platform.script   = file:///D:/WishProject/sourin-flutter-spike/main.dart
                                  ↑ 不是测试文件，是 main.dart
appRoot 推算      = D:\WishProject            ← 多上了一层
⇒ sourin-plugins 被算到 D:\sourin-plugins（不存在）
⇒ 源码/产物两处全部跳过，只剩用户数据目录 1 处被查
⇒ 门禁**看起来全绿**，实际只覆盖 1/3
```

**救回来的是「覆盖度必须显式」**：报告里写着「查了 1 / 3 处」，
一眼看出不对。若只打印 `✅ 通过`，这会是一条永远绿的假门禁。

修正：改用 `Directory.current`（实测 `flutter test` 从仓根运行）。

⇒ 这条印证了本轮早先那条结论：**输出必须能区分「查了没问题」与「没查」。**

## Alternatives considered

### 退一步：danmakuSend==true 就无条件红 + 打印翻案条件

**最强的理由**：简单，几十行；不需要维护证据探测器；
而且「人工确认一次」本来也是合理流程。

**否定的原因**：

```text
无条件红 = 永远红（一旦有人真的解开了闸门）。
而本仓已经确认过：永远红的门禁会被绕过，比没有更糟。
⇒ 必须给「闸门已解」留一条真实的放行路径，否则它会逼人删掉门禁。
```

### 用「文档某节存在」当证据

**最强的理由**：实现最简单（`text.contains('## 闸门已解')`）；
改动小，不需要探测器。

**否定的原因**：

```text
Markdown 不是证据 —— 任何人写一段就能骗过。
门禁要防的正是「声明与事实不符」，用文档当证据是自相矛盾。
```

### 不检查部署一致性（只查源码）

**最强的理由**：源码是唯一真源，dist 与数据目录都是派生的；
查源码就够了，附加两处只会带来环境依赖。

**否定的原因**：

```text
实测存在真实漂移场景：改了源码忘 build ⇒ dist 旧 ⇒ 宿主加载 dist。
check-dist-fresh 只在私库侧防这个；应用侧没有对应守卫。
⇒ 应用侧多查一处，成本一个 file read，收益是能抓到部署漂移。
```

## Consequences

**收益**

```text
· 「此刻安全」变成「持续安全」：三条判据每次跑都验
· 状态文档 §⑤ 的散文变成机制（③）
· 覆盖度显式 ⇒ 作用域变化（CI 无数据目录）不会被误读成全绿
· 每个判据都有反恒绿自检（合成样本），防扫描器永远返回空
```

**代价**

```text
· 跨仓库依赖：本地依赖兄弟目录 sourin-plugins + 用户数据目录
  ⇒ CI 上只有 1/3 覆盖（已在报告里显式打印）
· ③ 的证据探测器认的是特定标识符（webglFingerprint 等）
  ⇒ 将来真做钩子时若起名不同，探测器会认不出 ⇒ 需同步更新
    （已在红字的 reason 里写清"若你确实解开了闸门但探测器没认出来，
      请更新 gateEvidence()"）
· 用户数据目录的读取是**只读**的（不写不删），
  但仍依赖本机安装了该应用 —— 未安装时按"跳过"处理，不算失败
```

## Testing

```text
正常态：6 passed —— 3/3 覆盖 / 逃生口 0 命中 / 闸门未解符合预期

注入 1（私库源码 danmakuSend: false → true）
  ⇒ ✗ 部署漂移：私库源码=true, 私库产物=false, 用户数据目录=false
  ⇒ Some tests failed（2 条红：① 部署漂移 + ③ 无闸门证据）

注入 2（lib/ui/player_bottom_bar.dart 加 `bool? canSend;`）
  ⇒ ✗ 逃生口扫描命中 1 处，精确报出 :284 与原文
  ⇒ Some tests failed（1 条红）

注入 3（三处全改 true，但不提供闸门证据）
  ⇒ ✗ ★★★ 你打开了 danmakuSend，但没有「WebGL 闸门已解」的证据
  ⇒ 打印三条翻案条件
  ⇒ Some tests failed（2 条红）

还原 ⇒ 6 passed，三处 sha256 回到 82ee7216…（与注入前一致）
```

**反恒绿自检**（防止扫描器永远返回空/永远返回同一值）：

```text
· _parseDeclared 对 true/false/无逗号/带注释 四种形态都有断言
· 注释行不能被当成声明（源码里真有那一行）
· 扫描器对合成样本：`bool? canSend;` 与 `final String? disabledReason;` 必命中，
  `bool get _canSend`（私有内部状态）与注释里的词**不**命中
· 证据探测器：注释里的 dm_img_* 不算证据；真实构造代码才算
```
