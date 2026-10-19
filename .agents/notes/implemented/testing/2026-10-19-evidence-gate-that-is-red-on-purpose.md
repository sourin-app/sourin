# Agent Note: 故意让自己红的门禁 —— 证据留存 vs 全量读数可用

Status: implemented

Independent: 与本轮其它笔记都不同 —— 那几篇分别讲
[判别式的唯一实现](../testing/2026-10-19-criteria-must-distinguish-cause-and-ciphertext.md)、
[断言钉机制不钉实现](../testing/2026-10-19-assertions-pin-mechanism-not-implementation.md)、
[弹窗收拢](../feature/2026-10-19-dialog-shell-unification-and-hover-sticky-bit.md)。
本篇讲一个**具体的取舍**：一个门禁要不要故意保持红色。

## Problem

`zz_t66_skip_loadstate_review_test` 的用例 A 是**故意让自己红**的：

```text
skip_marker_dialog.dart:733
  static const Duration _kLoadTimeout = Duration(seconds: 10);

本测试用 fake clock，预算 12 × 250ms = **3 秒**
⇒ 即便 pump 也到不了 10 秒
⇒ TimeoutException 永不触发 ⇒ _LoadState 永远是 loading
⇒ test 框架收尾时打出「Pending timers: Timer (duration: 0:00:10.000000)」
```

它的**目的**就是让这个证据被打印出来（证明「10 秒超时」这个常量
真的挂上了 fake timer）。文件里写得很清楚：

```text
★ 这条测试**故意**留下一个 pending 的 fake 定时器，而且**故意让它红**。
```

### 但代价是真实的

```text
全量 flutter test 读数：+4638 ~77 **-43**
⇒ 这一条**永久贡献 1 个红**
⇒ 每个读全量的人都要重新判断"这条是不是真缺陷"
⇒ 更糟的是：将来真出缺陷时，红里多一条已知噪声，
   **真实的红更容易被略过**
```

## Decision

**保留"故意红"，但把它挪出默认套件。**

```text
用例 A 的断言与 print 全部保留（证据不许丢）
用 `@Tags(['evidence'])` 挂上
默认套件不跑 evidence ⇒ 全量读数恢复干净
显式跑：`flutter test --tags evidence` 能复现那个 pending timer 的输出
```

★ 判据是 MEMORY 里那条：**整文件 skip 会让断言过时永远暴露不出来** ——
所以必须留一条**能显式复跑**的路，而不是把它删掉或永久静音。

## Alternatives considered

**A. 维持现状（默认跑、默认红）。**
最强理由：证据每次全量跑都会自动打出来，不需要人记得去跑。
否决理由：全量读数被污染。`fulltest` 这次就为它单列了一行
「设计如此的红，不是缺陷，但它会一直污染全量读数」——
⇒ **污染是已经被观测到的成本**，不是假设。

**B. 用 `markTestSkipped` 让它变 `~` 而不是 `-`。**
最强理由：全量读数变干净，且不像 skip 那样"消失"。
否决理由：**`~` 比 `-` 更隐蔽** —— 它在读数里只是 `~1`，
没人会去看它是"故意跳过"还是"忘了跑"。
⇒ `~` 把一个**已知的显式选择**变成了一个**看不出来的空白**。

**C. 把 `_kLoadTimeout` 从 10 秒改成 3 秒（让 fake clock 能到）。**
最强理由：这样它就能自然地绿，全量读数干净且不需要 tag。
否决理由：那是在**为了门禁能过而改产品常量**。
而且改完之后「超时 10 秒」这件事就不再被验证了 ——
门禁证明了"3 秒会超时"，而产品是 10 秒。**证明的东西错了。**

**D. 删掉用例 A，只留 A2（加 `runAsync` 后能到 10 秒的那个）。**
最强理由：只保留能绿的那半，最干净。
否决理由：A2 绿**恰恰说明不了**"默认 fake clock 到不了 10 秒"这件事。
★ 而这正是本轮 `r6-live` / `untracked-triage` **两次**踩到的坑
  （"清理后才发现它一直绿"、"10 秒定时器在 fake clock 里到不了"）。
⇒ 删掉 A 就等于删掉那个教训的证据。

## Consequences

**改了什么**

```text
用例 A：断言与 print 一字未动
      + @Tags(['evidence'])
默认全量：不再计入 -1
显式复跑：flutter test --tags evidence test/zz_t66_skip_loadstate_review_test.dart
```

**拆成独立文件的代价（我踩了两个坑）**

```text
坑① `@Tags` 在 package:test 里**只能挂 library**，不能挂单个用例
    ⇒ 第一版挂在 testWidgets 上 ⇒ analyze 报 invalid_annotation_target
    ⇒ 而且即使挂对了，`@Tags` 只是**打标记**，不排除！
      实测默认套件照跑那条红。
    ⇒ 真正排除要在 dart_test.yaml 里写 `tags: {evidence: {skip: "..."}}`
      （本文件顶部 A/B/C 三组实测里，A 是唯一两条路径都对的）
    ⇒ 所以只能拆文件：一律留在主文件会让 A2/②/③ 三条**能绿的**一起退出默认套件。

坑② 我在重建 A 时**编了一条断言**「停在 loading ⇒ 转圈可见」
    ⇒ 实测被推翻：产品用 AppLoading 而不是 CircularProgressIndicator
    ⇒ 更糟的是它让失败原因从「pending timer」变成「断言不通过」
      ⇒ **证据被我自己的 bug 盖住了**，而框架那段文字反而不再显眼。
    ⇒ 修正后只剩一条断言：「失败文案没出现」，
      而这正是 A(失败文案=0) 与 A2(失败文案=1) 的**差值**。
    ★ 判据：一条「证据型红」的失败原因必须**只有那一个**。
      若你的断言也能红，它就会与证据竞争。
```

**验证**

```text
默认套件：  +5 ~1 All tests passed!        （读数干净）
显式复现：  flutter test test/… --run-skipped --tags evidence
            ⇒ +0 -1，且失败原因是
              「Pending timers: Timer (duration: 0:00:10.000000)」
              「A Timer is still pending even after the widget tree was disposed.」
            ⇒ 证据文字与原始版**逐字一致**
对照读数：  A: 失败文案=0   A2: 失败文案=1   ⇒ 差值成立
```

**已知上限**

```text
· 带 evidence tag 的人必须**知道**要跑它。
  所以用例文件头与计划文档里都写了「这条的证据要显式跑」。
  ★ 这仍是**依赖人的自觉** —— 无法从结构上保证。
· 若将来 CI 改成"必须全绿才发版"，这个 tag 就是唯一出口，
  需要在 CI 里显式跑一次 evidence 并允许它红。
```

**何时该翻案**

```text
· 若 framework 将来提供「预期失败」的正式表达
  （类似 Rust 的 `#[should_panic]` 或 pytest 的 `xfail`），
  应立刻改用它 —— 那比 tag 更强，因为它把"故意红"写在用例里
  而不是写在分类里。
· 若全量读数改成只报"新增红"（与基线 diff），
  那这条常驻红就不再是噪声 ⇒ 可以摘掉 tag。
```