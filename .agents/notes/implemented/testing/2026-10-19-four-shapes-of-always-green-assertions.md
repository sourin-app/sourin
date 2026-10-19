# Agent Note: 恒绿断言的四种形态 —— 以及「看起来有判据」不等于有

Status: implemented

Independent: 与本轮其它笔记都不同 —— 那几篇分别讲
[判别式的唯一实现](../testing/2026-10-19-criteria-must-distinguish-cause-and-ciphertext.md)、
[断言钉机制不钉实现](../testing/2026-10-19-assertions-pin-mechanism-not-implementation.md)、
[证据型红](../testing/2026-10-19-evidence-gate-that-is-red-on-purpose.md)。
那几篇讲的是**判据该钉什么**；本篇讲的是**判据根本没在钉东西时的四种形态**。

## Problem

第 66 轮的收尾复核里，队友列了 5 条「你大概以为已验证、实际证明不了」的判据。
逐条核实后**4 条成立**。它们凑齐了恒绿断言的四种形态：

```text
① 锚在**原始文本**上，而缺陷藏在注释里
   crossgate：impl.contains(精确正则) 读的是未剥注释的全文
   ⇒ 把代码降级成通配正则、留着注释里的原样 ⇒ 仍然绿

② 只断「没抛异常」，而那条路径下**根本不会抛**
   ui_selfaudit 2.2：expect(takeException(), isNull)
   ⇒ 外壳 :210 `if (onClose == null) return shell;`
   ⇒ onClose 为 null 时 CallbackShortcuts 压根没挂 ⇒ 断言照样通过

③ 算出来的值**从未被 expect**
   ui_selfaudit 2.2 的 handled、2.1 的 found['update占位']
   ⇒ 只被 print 出来给人看 ⇒ 没有任何判据在用

④ 类型层面的**恒真**
   ui_selfaudit 1.5：expect(risky, isNotNull) —— List 永远非 null
   ⇒ 纯装饰，却让人以为"这里有检查"
```

## Decision

逐条改成**会红**的判据，并**各自做故障注入**：

```text
① stripComments(impl).contains(…)      注入"只降级代码" ⇒ 红
② expect(find.byType(CallbackShortcuts), findsWidgets)
   注入"短路掉 Esc 绑定"               ⇒ 红
③ 显式 expect(found['update占位'], 0)  并写明它测的不是 update 弹窗
④ expect(_touchedFiles, isNotEmpty)    ★ 防空转用清单非空，不是 isNotNull
```

★ 第 ④ 的通则：**防空转要断「输入非空」，不是断「输出非 null」。**
  后者对任何容器都成立。

## Alternatives considered

**A. 直接删掉这 4 条断言。**
最强理由：删了就不会假绿。
否决理由：删掉会**静默失去覆盖面**。
例如 ② 删掉后，将来有人把 Esc 绑定移除，**没有任何门禁会红** ——
而键盘打不开弹窗是用户能直接感知的缺陷。

**B. 把它们改成 `print` + 在 CI 里比对输出快照。**
最强理由：不涉及断言逻辑。
否决理由：输出快照极脆（改个行号就红），而这 4 条要的只是
「结构上正确」—— 用结构判据表达比快照稳得多。

**C. 只在注释里写「这条是恒绿的，别当真」。**
最强理由：成本最低，且诚实。
否决理由：**它仍然占着"门禁"的位置** ——
读全量读数的人会把 `+N` 当成"这 N 条都验过了"。
★ 诚实地标注一个假绿，不如把它变成真绿或删掉。

## Consequences

**验证（每条都有注入）**

```text
① 只降级 3 处代码、保留注释 ⇒ crossgate 红（改前是绿的）
② 外壳短路 Esc 绑定      ⇒ 2.2 红（改前是绿的）
③ 去掉 expect            ⇒ analyze 不变，但该条不再有覆盖 ⇒ 拒绝这条路
④ _touchedFiles 清空     ⇒ 1.5 红
还原后：+20 ~1 All tests passed!
```

**第 5 条未修（如实记）**

```text
_inLogCall 的窗口是「往前看 3 行」
⇒ 跨度 >3 行的跨行 debugPrint 会假红；
⇒ 日志未闭合时，中间夹的用户文案会被跳过（假绿）。
当前 16 个文件实测跨度全 ≤1 ⇒ **现状不触发**
⇒ 刻意不改：为不存在的情况增加复杂度，比留着它更贵。
```

**★ 一次操作事故（如实记）**

```text
做注入实验时，我把**产品文件**的备份（/tmp/ads.bak）
误用 `cp` 覆盖了**测试文件** ⇒ 596 增 478 删的行尾损坏
⇒ 立即 `git checkout --` 恢复并重做修改。

★ 判据：备份文件必须带**用途前缀**（ads.bak / uia.bak），
  否则回滚时会把 A 的备份灌进 B。文件名不带语义 = 迟早出事。
```

**何时该翻案**

```text
· 若 Dart 将来让 `@Tags` 能挂单个用例，则
  「证据型红」就不必拆文件（见 evidence-gate 那篇），
  本篇第 ② 条的注入手法也可以更直接。
· 若本仓改用别的判据框架（如 custom_lint），
  这四种形态要重新审一遍 —— 它们是框架无关的。
```