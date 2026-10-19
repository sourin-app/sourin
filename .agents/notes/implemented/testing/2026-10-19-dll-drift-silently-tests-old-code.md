# Agent Note: 改了 Rust 却测到旧代码 —— DLL 漂移是静默的

Status: implemented

Independent: 与本仓其它 testing 笔记不同 —— 那几篇讲**判据本身**对不对
（[恒绿断言的四种形态](../testing/2026-10-19-four-shapes-of-always-green-assertions.md)、
[作废数字要 grep 全部位置](../testing/2026-10-19-invalidating-a-number-means-grepping-all-its-sites.md)、
[固定字符窗口](../testing/2026-10-19-source-scan-judge-should-not-use-fixed-window.md)、
[红测试的三种成因](../testing/2026-10-19-three-causes-of-a-red-test.md)）。
本篇讲一个**更靠底层**的失效：**判据与被测物之间的连接断了**，
而它**不会让任何门禁变红**。

## Problem

`test/zz_t66_*` 这批门禁通过 `DynamicLibrary.open('sourin_core.dll')`
（`lib/core/ffi.rs:263`）加载 Rust 核心。而该 DLL 有**两个落点**：

```text
sourin_core.dll                              ← 仓库根（测试加载的就是它）
rust/sourin_core/target/release/sourin_core.dll  ← cargo 的产物
```

**实测两者不同源**：

```text
$ md5sum sourin_core.dll rust/sourin_core/target/release/sourin_core.dll
  666b2e0926c001bd12a52142c6f511b8   ← 仓库根
  5be8b5d4ef9136065a23c4901d8340bc   ← cargo 最新产物
```

⇒ ★★ **改完 Rust、`cargo build` 成功之后，测试跑的仍然是旧代码。**

### 它是怎么被发现的（这个过程本身就是教训）

队友做「明文泄露」注入验证：

```text
① 把 Rust 里的 `_v1` 从密文换成明文
② cargo build --release 成功
③ 跑 e2e 门禁 ⇒ **+24 全绿**
④ ⇒ 他差点得出结论：「这条门禁抓不到明文泄露」
⑤ 回头查 ⇒ 根目录 DLL 的 md5 是 666b2e09，cargo 产物是 c084fbdde9
⑥ 把 cargo 产物 cp 到仓库根 ⇒ 立刻 +20 -4
```

★ **「注入无效」与「门禁无效」的读数完全一样（都绿）。**
  第 ④ 步那个结论若是没查就写进报告，
  就会得出一个**方向完全相反**的判断（而实际上那条门禁很好）。

## Decision

本次只做两件事：

### ① 修好它暴露出来的真 P0（编译失败）

```text
src/commands_backup.rs:428   backup_export(state, path, passphrase)   ← CS-1 加的第 3 参
src/commands_backup.rs:1005  backup_import(state, path, passphrase)   ← 同上
tests/batch6_backup.rs       export ×4 + import ×9 仍传 2 参 ⇒ 13 处 E0061
⇒ cargo test --no-fail-fast 下 **0 个测试二进制跑起来**
⇒ ★ 「Rust 491 全绿」不可能是当天状态（491 只在 --lib 下成立）
```

修法：13 处补 `None`（不设口令 = 旧行为）。

★ **我第一版只补了 import 那 9 处** ⇒ 立刻又撞上 export 的 4 处。
⇒ 教训：报「N 处」时**要把涉及的函数都列出来**，否则容易只修一半。

### ② 登记 sha 一致性门禁为待办（**未实施**）

```text
判据：跑任何依赖 FFI 的门禁前，先断言
      md5(sourin_core.dll) == md5(rust/sourin_core/target/release/sourin_core.dll)
★ 这条门禁必须在「cargo build 之后、测试之前」跑，否则测的仍是旧的。
```

## Alternatives considered

**A. 每次验证前手动 `cp` DLL（就是现在这样）。**
最强理由：零改动、立刻可用。
否决理由：**它是流程约定，不是门禁** ——
  本轮已经因为忘了这一步而得出过反向结论。
  ⇒ 人会忘，机器不会。

**B. 让测试直接加载 cargo 的产物路径（`target/release/sourin_core.dll`）。**
最强理由：从根上消除「两个落点」。
否决理由：**测试环境未必经过 `cargo build`**；
  而 CI 的流程是「编 Rust → 把核心放进 Windows 构建目录」（`build.yml:228`），
  路径与本机不同 ⇒ 改测试会与 CI 脱节。
⇒ 真正该做的是让**两条链路共用同一个来源**，那是架构改动，超出本次范围。

**C. 在 `ffi.rs` 里加一句「加载失败就 fail 而不是 fallback」。**
最强理由：加载失败不该静默。
否决理由：**这里不是「加载失败」** —— 旧 DLL 是**能加载的**，
  它只是**过期的**。加载成功不等于代码是新的 ⇒ 这条判据抓不到本例。

## Consequences

**★ 可迁移的判据**

```text
凡是用「动态库 / 外部进程 / 子模块」做被测物的门禁，
都要先问一句：**被加载的那份，和我刚改的那份，是同一份吗？**

判据很便宜：两个 md5 比一下。
★ 而「注入无效」与「门禁无效」读数相同（都绿），
  所以**每一次注入都必须先证明字节到了被加载的那个文件**，
  再看红绿 —— 否则你分不清是「我的注入没生效」还是「门禁抓不到」。
```

**★ 与本会话方法论的关系**

```text
这属于 AGENTS §8 的「改了 Rust 但行为没变」，
但它比那条更难发现：
  §8 说的「改了没生效」至少会看到行为没变；
  而「加载了旧 DLL」时，**测试会给出完全正常的读数**，
  只是那个读数对应的是另一个版本的代码。
⇒ 判据：**任何「注入无效」的第一反应都该是「被加载的字节对不对」**，
  而不是「门禁太弱」。
```

**★ 顺带记一个假警报**

```text
队友看到根 DLL 里 grep 不到 `set_credentials_passphrase`，
怀疑是「DLL 陈旧」的证据。
★ 实际：那两个是 `ffi.rs` 里的**分发字符串**，不是导出符号；
  且 `ffi.rs` 含 79 个 NUL 字节 ⇒ 普通 grep 会把它当二进制文件而误报。
⇒ 判据：对二进制/含 NUL 的文件做符号检查，要先剥 NUL，
  且要分清「导出符号」与「字符串常量」。
```

**已知上限**

```text
· sha 一致性门禁**尚未实施** ⇒ 本轮修完后，那条风险仍然存在。
· 本次只验证了 `cargo test`（55 个二进制全过）；
  ★ 但**依赖 FFI 的 Dart 门禁**（`zz_t66_*` 那批）是否受影响，
  我没有重跑 —— 它们读的是根目录那份 DLL。
```

**何时该翻案**

```text
· 若 CI 与本机统一到同一个 DLL 落点（而不是各自拷一份），
  这条笔记的核心建议自动失效，可归档。
· 若本仓引入 build fingerprint（如把 git sha 编进 DLL 并在加载时校验），
  那比 md5 门禁更强 —— 因为它连「忘了 build」都能抓到。