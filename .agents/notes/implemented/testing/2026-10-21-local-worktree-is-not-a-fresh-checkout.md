# Agent Note: 本机工作区不是「全新 checkout」—— 行尾与重渲染字节都因此说谎

Status: implemented

> 同域：[2026-10-21-windows-only-gates-need-platform-guards.md](../testing/2026-10-21-windows-only-gates-need-platform-guards.md)
> （同一批 macOS 红灯，那篇是「判据本身只在 Windows 成立」；本篇是
> **判据在哪儿都该成立，但本机看到的那份文件与 CI 拿到的不是同一个东西**）。
> Independent: 失效点在「被测对象的字节」而不在「判据的适用范围」。
> 也相关：[2026-10-21-gate-crashes-on-its-own-success-message.md](../bug-fix/2026-10-21-gate-crashes-on-its-own-success-message.md)
> （同一句原则的另一面：判据想说的话不能反过来决定判据的结论）。

## Problem

CI run `39538011233` 的 macOS job 从 6 条红降到 3 条，剩下 3 条**两个不同的原因**，
但**同一个根**：我在这台机器上看到的文件，和 CI 里那份不是同一个东西。

### ① 行尾：本机是 LF，CI 是 CRLF

`test/zz_t66_e2e_shots_survivor_test.dart` 的 `_stopFnCodeLines()` 里写着：

```dart
final end = src.indexOf('\n}\n', start);   // ← 写死 LF
```

而 `.gitattributes:87` 写着 `*.ps1 text eol=crlf`。本机那份文件当时是：

```text
$ git ls-files --eol tools/e2e_shots.ps1
i/lf    w/lf    attr/text eol=crlf
                 ^^^^^ 属性说要 CRLF，工作区却还是 LF
```

**git 只在重写文件时才应用 `eol=crlf`**，那份文件自入库起没被重写过 ⇒ 一直 LF。
CI 是全新 checkout ⇒ 全部 CRLF ⇒ `indexOf('\n}\n')` 命中 0 次：

```text
Expected: a value greater than <13947>
  Actual: <-1>
  函数体未正常闭合
```

★ 这**不是** macOS 问题：Windows 的全新 checkout 同样是 CRLF。
本机之所以一直绿，纯粹是那份文件的历史状态。

### ② 重渲染字节：本机重渲染恰好与封存一致

两个测试共用一条路径：

```text
test/zz_t66_cs1_evidence_shots_test.dart     → 渲染 SyncPanel，**覆盖**
                                                docs/notes/evidence/round-66-cs1/*.png
test/zz_t66_cs1_evidence_manifest_test.dart  → 拿上面那两张图比对 manifest 封存的
                                               sha256 / 宽高 / 字节数
```

```text
本机      重渲染 → 84060 B / 87453 B，sha256 与 manifest 逐字相同 ⇒ 绿
macOS     重渲染 → 34464 B / 35224 B，sha256 全不同          ⇒ 红
```

⇒ 本机的「绿」依赖「这台机器的引擎 + 字体渲染出的 PNG 与当初封存的字节完全相同」。
这是**巧合**，不是保证。

⚠️ 更要紧的后果：这层覆盖把 manifest 判据的保护力**自己废掉了**。
`zz_t66_cs1_evidence_shots_test.dart` 第 50~69 行本来就记着一条实测——

> 注入：把 `cs1-sync-disabled.png` 换成 5372 B 的纯色 PNG
> 结果：`+3 All tests passed！` ← 没红
> 原因：本文件的用例会**重新渲染并覆盖**那两张图

⇒ 也就是说：谁往证据目录里塞一张假图，manifest 门禁**拦不住**，
因为同一次 `flutter test` 里出图用例会先把假图换成真图。
**两条判据互相污染被测对象，于是两条都不算数。**

### ③ 顺带：报错信息自己也是坏的

`zz_t66_cs1_evidence_manifest_test.dart` 里：

```dart
bad.add('${e.name}: manifest=$e.bytes B 实际=$bytes B');
```

Dart 的 `$标识符` **只吃到标识符为止**，于是 `$e.bytes` = `${e}` + 字面量 `.bytes`。
CI 日志里就成了：

```text
manifest=Instance of '_Shot'.bytes B 实际=34464 B
```

断言没错，错的是**它想说的话**。而排错时人只有这句话可看。

## Decision

### ① 读文本的解析器当场归一化行尾

```dart
// test/zz_t66_e2e_shots_survivor_test.dart
return f.readAsStringSync().replaceAll('\r\n', '\n');
```

不改成同时试 `'\n}\n'` 和 `'\r\n}\r\n'` —— 那会把「行尾无关」这件事
散到每一处 `indexOf` / `split` 上，漏一处就再红一次。

### ② 「生成证据」与「校验证据」分成两条路径

```dart
const String kEvidenceDir = 'docs/notes/evidence/round-66-cs1';   // 归档，git 跟踪
const String kScratchDir  = 'build/evidence-shots/round-66-cs1';  // 临时，.gitignore:36 /build/

String get kOutDir {
  final override = Platform.environment['SOURIN_EVIDENCE_OUT']?.trim();
  return (override == null || override.isEmpty) ? kScratchDir : override;
}
```

- **默认**写 `build/` ⇒ 跑测试永不改动归档证据。
- 需要**故意刷新**归档时显式指路，不靠默认行为：

```text
SOURIN_EVIDENCE_OUT=docs/notes/evidence/round-66-cs1 \
  flutter test test/zz_t66_cs1_evidence_shots_test.dart
```

### ③ 报错信息补花括号

```dart
bad.add('${e.name}: manifest=${e.bytes} B 实际=$bytes B');
```

## Alternatives considered

### ① 把出图用例在非 Windows 上 skip 掉

**最强论据**：一行 `skip:` 就绿，和上一批的处置方式一致（那些确实该 skip）。

**为什么否决**：**它治不了真问题**。真问题是「出图用例会覆盖归档」，
这在 Windows 上同样成立 —— 只是 Windows 上重渲染的字节恰好一致，看不出来。
一旦 Flutter 版本升级导致渲染字节变化，Windows CI 也会红，而且
那时候 manifest 门禁会**顺带**失去对塞假图的保护力，没人会注意到。
⇒ 判据：**两件事都在同一台机器上做得成的平台，不该因为"看不出来"而不修。**

### ② 在 CI 里跑完出图就重新封存 manifest

**最强论据**：这样任何平台都能自洽，"证据"变成"当前代码渲染出来的东西"。

**为什么否决**：那样 manifest 记的就不再是**归档的那张图的身份**，
而是"跑这一次时渲染出的字节"。一张图在 CI 里被自动重封存，
事后没人能证明发布出去的那份证据与产品当时的样子对得上 ——
**证据的意义就是它不能随被测对象变化**。

### ③ 保留写归档，但把 manifest 门禁排在出图用例之前

**最强论据**：靠测试顺序解决，改动最小。

**为什么否决**：`flutter test` 的**文件顺序不是契约**（本仓已因并行/顺序踩过
`did not complete` 的坑）。把一条门禁的正确性押在顺序上，
换一次 Flutter 版本或改一个文件名就可能翻过来 —— 而且它翻过来时是**绿**的。

### ④ 本机也用 `git worktree add` 一份干净副本再验

**最强论据**：这才是"和 CI 等价"的正解，本仓已用过这个方法定位过 divergence。

**为什么否决（作为**替代**而不是补充）**：它能让**我**看见红，但改不了仓里的代码。
`worktree` 只能用来**发现**问题，不能用来**修**问题。
★ 但它是必备的第二步验证手段 —— 本次收尾就是这么复核的，见 Consequences。

## Consequences

### 收益

```text
· 行尾不再影响任何解析：CRLF / LF 的工作区都得到同一份逻辑内容
· manifest 判据恢复保护力：它现在比的一直是归档里真正封存的那两张图
· 报错信息能读出「84060 B vs 71 B」这种可以立刻定位的数字
· 归档目录不再被测试顺手改写（跑完 git status 干净）
```

### 读数（全部在同一台机器、同一批命令）

```text
【行尾】
把 tools/*.ps1 全部转成 CRLF（= 全新 checkout 的形态，git 仍认为干净）
  survivor 测试            → +6 All tests passed
故障注入：把归一化那行改回 return f.readAsStringSync();
  survivor 测试（CRLF）    → +5 -1
                             Expected: a value greater than <13947>
                               Actual: <-1>
                             函数体未正常闭合
                          ⇒ **逐字复现 CI 报错** ⇒ 归一化是承重的
还原后                    → +6 All tests passed

【证据路径】
两个文件一起跑（--concurrency=1）           → +11 All tests passed
跑完 git status docs/notes/evidence/...     → 空（归档未被改写）
build/evidence-shots/round-66-cs1/          → 两张新渲染的图落在这里

故障注入：往归档塞一张 71 B 的 1x1 PNG，再一起跑两个文件
  修前（本文件注释里记的实测）              → +3 全绿      ← 假绿
  修后                                      → +9 -2        ← ②③ 都红
    cs1-sync-disabled.png: manifest=1280x900 实际=1x1
    cs1-sync-disabled.png: manifest=84060 B 实际=71 B
还原（git checkout 那张 PNG，sha256 回到 47a69435…）→ +11 All tests passed

【5 个曾经红过的文件，CRLF 工作区下逐个单跑】
  zz_t66_ps1_bom_gate_test              → +3
  zz_t66_danmaku_send_safety_gate_test  → +6
  zz_t66_e2e_shots_survivor_test        → +6
  zz_t66_cs1_evidence_manifest_test     → +8
  zz_t66_cs1_evidence_shots_test        → +3
```

### 代价

```text
· 归档证据不再能"顺手"由测试刷新 —— 必须显式给 SOURIN_EVIDENCE_OUT，
  并重新封存 manifest。多一步，但这一条正是"证据不能自证"该有的成本。
· 出图用例的产物从仓库可见的 docs/ 挪到了 build/ ⇒ 想看新渲染的图要去
  build/evidence-shots/ 找。它在 .gitignore 里，不会误入库。
· 本机的 tools/*.ps1 现在是 CRLF（git 认为干净、内容与 index 一致），
  只是工作区形态与 CI 相同了；不是为了提交而改。
```

### 何时该翻案

```text
① 若哪天证据图改成由 CI 从产物直接抓真机截图（而不是 flutter_tester 渲染）
   ⇒ 「渲染字节随平台变化」这条消失，但「生成/校验必须分离」仍然成立
② 若无头渲染变得跨平台字节稳定（同一 Skia 版本 + 同一字体集，且能钉住）
   ⇒ 归档可以直接由测试写，但那时也应该先证明"两个平台字节相同"这个前提
③ 若 `.gitattributes` 把 `*.ps1` 改成 `eol=lf`（PS 5.1 需要 BOM，不必然需要 CRLF）
   ⇒ 归一化那行可以删，但留着无害
```

## 给下一个人的提醒

```text
★ 本次最值得记的不是那三处改动，而是这个操作：

    看到「本机绿、CI 红」时，第一个要查的不是判据，而是
    **本机那份文件是不是 CI 会拿到的那份文件**。

  两个立刻能用的探针：
  ```text
  git ls-files --eol <path>          # 看 index/工作区/属性 三者的行尾
  git worktree add /tmp/ci-eq HEAD   # 造一份"只有 git 里有"的干净副本
  ```
  第二个尤其关键：它能一次性排除「本机有、CI 没有」「本机旧、CI 新」
  这类差异（本仓之前就是靠它定位到两条笔记被 .gitignore 挡住没入库）。

★ 还有一条顺序上的经验：
  **先让本机工作区变成 CI 的形态（用 worktree 或直接改行尾），再复现；
  复现不了就不要开始改代码。** 本次 survivor ① 若跳过这一步，
  会得出"macOS 上 indexOf 行为不同"这种完全错误的结论。
```
