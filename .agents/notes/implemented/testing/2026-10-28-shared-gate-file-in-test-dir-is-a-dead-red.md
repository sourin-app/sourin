# Agent Note: 共享门禁件混进测试目录 = 一条永远红、又什么都不守的假红

Status: implemented

## Problem

`test/zz_cr_nit_shell_theme_gate.dart` 是**共享门禁实现**（69 行，导出
`kShellThemeBinding` / `shellThemeBindingHasMatch` / `bareApproximateMaterialThemeLines`），
**没有 `main()`**，被两个测试 import：

```text
test/theme_regression_test.dart              ← 真门禁
test/zz_cr_nit_theme_gate_not_false_test.dart ← 它的反向验证
```

但它放在 `test/` 且**以 `zz_` 开头** —— 而全量跑法是 `flutter test test/zz_*.dart`：

```text
Failed to load "test/zz_cr_nit_shell_theme_gate.dart":
  Missing definition of `main` method.
```

后果：**每次全量都有一条红，而它一条断言都没在守**。它不区分「产品坏了」与
「跑法收录了一个非测试文件」，也不提供任何信息 —— 只是稳定地把"全绿"变成"1 红"。
（批末我一共两次看到它，前几次都按"仪器故障"手工豁免过去了，等于绕开而不是修好。）

## Decision

两件事一起做：

```text
① 挪位：test/zz_cr_nit_shell_theme_gate.dart → test/_support/shell_theme_gate.dart
   —— 仓库既有约定（同目录已有 strip_comments.dart / markdown_bold.dart 等共享件）。
   两个消费者的 import 与本文件内部的相对 import 一起改；
   `zz_cr_nit_theme_gate_not_false` 里那条"必须 import 共享实现"的**路径断言**同步更新
   （断言的是"只有一份实现"这件事，路径变了语义不变）。

② 补测：新增 test/zz_cr_nit_shell_theme_gate_selftest.dart
   共享实现此前**没人测过自己** —— 正则写宽容了，两个消费者会一起静默变松。
   用人造源码钉住五种行为：
     只出现在注释里        ⇒ 不许通过（2026-10 那次"守注释"的病灶）
     MaterialApp.theme     ⇒ 通过（M4 之前的形态）
     AppThemeHost 注入     ⇒ 通过（M4 之后的产品根）
     算了 theme 但没挂宿主 ⇒ 不许通过
     裸 toApproximateMaterialTheme 只扫**剥注释后**的真实代码
   最后再真跑一遍 `lib/shell.dart`（门禁与产品不许脱节）。

③ 加守则：test/zz_gate_test_files_must_have_main_test.dart
   `test/zz_*.dart` 里出现没有 main 的文件 ⇒ 红，报错信息直接写"共享件挪到 test/_support/"。
```

## Alternatives considered

1. **给这个文件补一个 `main()`，让它变成一个真测试**。
   最强理由：不用挪位置、不用改 import，最小改动。
   **否决** —— 它的定位是"同一纪律的唯一实现"，被两处 import；
   给它加 main 会让它在全量里跑两遍（自己一遍 + 两个消费者各一遍），
   而且它内部只有正则与纯函数，**单独跑没有任何被测对象**。
   真要覆盖它，应该由 selftest 用人造源码覆盖（已做）。
2. **在全量脚本里排除这个文件名**（`find ... ! -name 'zz_cr_nit_shell_theme_gate.dart'`）。
   最强理由：一行搞定，别碰代码。
   **否决** —— 那是把"目录里混了非测试文件"这件事藏进脚本，
   下一个人加共享件照样会踩；而且排除名单会越长越长。
3. **什么都不做，每次跑全量时手工豁免它**。
   **否决** —— 我已经手工豁免过两次。**稳定的红必须被消灭或被证明**，
   靠人记住"这条可以忽略"是最糟的一类门禁债务。

## Consequences

- 收益：全量 zz_ 集从"永远 1 红"变成可全绿（这条红不再掩盖别的真红）。
- 收益：共享实现第一次有自己的行为判据（5 条），并且加了
  "`zz_` 必须有 main"的结构守则 —— 这一类假红被从根上封死。
- 代价：共享件的位置变了，历史笔记/文档里若提到旧路径会过期。
  缓解：旧路径在 git 里可查（`git log --follow`），且两个消费者的 import 是唯一硬引用。
- 代价：`zz_` 前缀现在**强制**意味着"可执行测试"，共享件必须放 `_support/`。
  这条约束是新的（此前只是习惯），守则会强制它。

## Relations

- 同族：[./2026-10-28-gates-follow-the-implementation-shape.md](./2026-10-28-gates-follow-the-implementation-shape.md)
  —— 那篇是"判据跟不上实现形态"；本篇是"文件被放错目录，红得没有信息量"。
- 反例对照：[./2026-10-27-dead-exemptions-make-coverage-metrics-lie.md](./2026-10-27-dead-exemptions-make-coverage-metrics-lie.md)
  —— 那篇讲"死豁免让覆盖率说谎"；本篇讲"死红让全绿说谎"。
