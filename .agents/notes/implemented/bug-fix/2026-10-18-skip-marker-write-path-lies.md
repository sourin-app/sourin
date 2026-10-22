# Agent Note: 写跳过点时失败会撒谎 —— 按钮永久禁用 / 重置报「已重置」

Status: implemented

> 同域：[2026-10-18-skip-marker-read-timeout.md](./2026-10-18-skip-marker-read-timeout.md)
> 那篇修的是同一个弹窗的**读路径**（`getSkipMarker` 无超时 ⇒ 永久转圈 +
> 失败被画成「未设置」）；本篇修**写路径**（`setSkipMarker` / `clearSkipMarker`）。
> 两者是同一族缺陷的两半：**故障被伪装成正常状态**。
> 读路径伪装成"你没设过"，写路径伪装成"保存中…"和"已重置"。

## Problem

`SkipMarkerDialog` 的两条写路径都没有超时，且失败处理都是"装作没事"。

### ① `_save()`：核心层挂住 ⇒ 按钮永久禁用

```dart
// 改前
await SourinApi.setSkipMarker(widget.provider, widget.id, ...);   // 无超时
```

`_saving` 只有在「成功」或「抛异常」时才复位。若核心层卡住
（死锁 / 线程池排队满 / 数据库文件锁），Future **永不完成**：

```text
_saving 永远 true
  ⇒ _canSave 永远 false（它第一行就是 `if (_saving) return false;`）
  ⇒ 保存按钮永久禁用（onPressed == null）
  ⇒ 文案永久「保存中…」
  ⇒ 用户点不动、也没法重试，只能关窗重开
```

### ② `_reset()`：失败仍然宣称「已重置」并清空本地值

```dart
// 改前
try {
  await SourinApi.clearSkipMarker(widget.provider, widget.id);   // 无超时
} catch (e) {
  debugPrint('[SKIPDLG] 清除失败: $e');      // ← 只记日志，用户看不到
}
if (!mounted) return;
setState(() {                                // ← ★ 无论成败都清空
  _introStart = null; _introEnd = null;
  _outroStart = null; _outroEnd = null;
});
_toast('已重置');                            // ← ★ 失败也说"已重置"
```

```text
⇒ 用户以为清掉了，实际根本没删
⇒ 下次打开发现跳过点还在 ⇒ 判定"这软件有 bug"
```

**这是本轮最严重的一处，因为「重置」是删数据的操作。**
静默失败不只是体验问题 —— 用户以为删了、实际没删，是**隐私风险**
（比如他想清掉某个看过的记录）。

### ③ 附带发现：保存过程中会闪一句假报错

```dart
// _footer()
if (!_canSave)
  Text('区间不合法：需要 起点 < 终点，且片头在片尾之前'),
```

而 `_canSave` 混了两件事：**输入是否合法** 与 **当前是否在忙**。

```text
⇒ _saving == true 时 _canSave 必为 false
⇒ 保存过程中底栏会显示「区间不合法：…」
⇒ 而此刻区间**明明是合法的**（用户刚因为合法才点的保存）
⇒ 假报错
```

## Decision

### ① 两条写路径都加 10 秒超时

与读路径共用 `_kLoadTimeout`（同一个核心层、同一个理由：
**兜底不挂死，不是 SLA 守护**）。

```dart
await SourinApi.setSkipMarker(...).timeout(_kLoadTimeout);
await SourinApi.clearSkipMarker(...).timeout(_kLoadTimeout);
```

超时后**必须复位** `_saving` / `_resetting`，否则按钮永久卡在"进行中"。

### ② `_reset()` 失败时**重读服务器**，而不是保留本地值

```dart
} on TimeoutException {
  setState(() {
    _resetting = false;
    _saveError = '重置失败：核心层 ${_kLoadTimeout.inSeconds} 秒无响应';
  });
  _toast('重置失败：超时');
  // ★★ 必须重读，让 UI 显示服务器的真实状态
  _loadState = _LoadState.loading;
  await _loadExisting();
}
```

**判据：失败后 UI 显示的必须是服务器的真实状态，不是本地猜的。**

### ③ 判据拆成三个，而不是打补丁

```dart
bool get _inputValid { ... }                  // 纯输入校验（区间）
bool get _busy => _saving || _resetting;      // 忙的种类只在这里增长
bool get _canSave => _inputValid && !_busy;   // 能否按按钮
```

底栏提示用 `_inputValid`（它要说的是"输入有错"），
按钮用 `_canSave`（它要说的是"能不能点"）。

### ④ 失败原因进 `_saveError`（底栏持久可见）+ toast（浮层）

不能只靠 toast —— `showAppToast` 在找不到 `ToastHost` 时是**静默 no-op**
（这是它相对 `ScaffoldMessenger.maybeOf` 的改进，但也意味着它不保证可见）。

## Alternatives considered

### ① 「保留本地值，不重读服务器」

**最强论据**：省掉一次 FFI 往返，实现最简单 —— 失败时什么都不做即可。

**为什么否决**：

```text
本地值本身也未必可信：
  · 可能上游刚被别处改过（另一台设备 / 另一个页面）
  · 可能是上一次读取超时留下的陈旧值（读路径也有超时了）
⇒ 「保留本地值」等于用**一个不一定对的数**去回答「服务器现在是什么」
⇒ 用户看到的可能仍是错的，只是错法不同
⇒ 唯一可靠的做法：**问服务器**
```

★ 而且成本极低：一次本地读，毫秒级。

### ② 「补丁式 `if (!_canSave && !_saving)`」

**最强论据**：改动最小（一个条件），不动 `_canSave` 的既有语义，
不影响任何其它调用点。

**为什么否决**：**因为"忙"这个维度会继续增长，而且已经增长了。**

```text
改这一轮时 `_resetting` 是**新加的**状态
⇒ 补丁式当场就要写成 `!_canSave && !_saving && !_resetting`（三个条件）
⇒ 下次再加一种忙（比如"预取中"/"校验中"）就要补第四个
⇒ **漏补一次，假报错就回来了**，而且回来的方式很隐蔽
   （只在那个特定状态下闪现一下）

⇒ 拆开后：`_busy` 再怎么增长，提示文案只看 `_inputValid`，永远不受影响。
★ 这不是"代码更干净"，是**把增长点收敛到一处**。
```

### ③ 「失败时静默保持『保存中…』」

**最强论据**：零改动，且用户至少知道"在忙"。

**为什么否决**：这正是本缺陷本身的形态 —— **把故障伪装成正常状态**。
和读路径那条「失败画成未设置」是同一族。而且它让用户**无法判断该等还是该重开**。

### ④ 「顺便把 `getProgress` 的 4 处无超时调用也一起改」

**最强论据**：同一类问题，一次改完更彻底。

**为什么否决**：改动面大（`detail_page:1411,1892` / `cache_page:463,553`），
且没有真机证据说明那些路径也会挂。本轮只修本次缺陷的直接来源，
其余登记为后续项。

## Consequences

### 门禁（7 条，`test/zz_t66_skip_write_path_test.dart`）

```text
① 保存超时 ⇒ 显式失败 + _saving 复位（按钮恢复可点）
② 阴性对照：保存成功 ⇒ 弹窗正常关闭
③ 重置超时 ⇒ 绝不显示「已重置」
④ 重置失败 ⇒ 重读服务器，UI 显示真实值
⑤ 阴性对照：重置成功 ⇒ 显示「已重置」且本地清空
⑥ 源码级：两个 .timeout() 真接线 + catch 里不许报已重置（已剥注释）
⑦ 保存进行中不显示「区间不合法」
```

②⑤ 是阴性对照：证明加了失败态没有把成功路径弄坏。
③④ 成对：③ 证明失败不撒谎，④ 证明失败后显示的是**真实状态**。

### 故障注入（两次，都验红并还原）

```text
注入 A：删掉 _reset 两个失败分支里的重读
        ⇒ ④ 变红（readCount=1，应为 2）
注入 B：删掉 _save 的 .timeout()
        ⇒ ①⑥ 变红
```

### 数据安全影响

```text
改前：重置失败 ⇒ 用户看到「已重置」⇒ 以为删了，实际没删 ⇒ 隐私风险
改后：重置失败 ⇒ 「重置失败：…」+ 重读服务器 ⇒ UI 显示真实值
```

**这是本改动最重要的收益，不是"按钮不再卡住"。**

### 还没覆盖的

```text
· getProgress 的 4 个调用点（detail_page:1411,1892 / cache_page:463,553）
  仍然无超时 —— 同一类问题，建议单独一轮用同样的三态 + 超时模式。
· 10 秒是兜底值，**没有做 p99 实测**。将来若测了，应按 p99 × 10 调整
  并同步读路径的 _kLoadTimeout。
· 未真机验证（只在 flutter test 环境跑过）。
```

### 何时该翻案

```text
① 若真机实测出 set_skip_marker / clear_skip_marker 的 p99
   ⇒ 按 p99 × 10 调整超时（与读路径一起改）
② 若 Rust 侧改成保证不阻塞（有界队列 + 显式超时）
   ⇒ 本层超时可退化，但**失败态仍要保留**（失败与成功必须可区分）
③ 若将来 Rust 返回结构化错误码 ⇒ 失败文案应改用错误码而不是异常字符串
④ 若 UI 将来支持"乐观更新 + 回滚"（先本地改、失败再回滚并提示）
   ⇒ 本方案可简化，但**回滚时必须显式告诉用户**，不能静默
```
