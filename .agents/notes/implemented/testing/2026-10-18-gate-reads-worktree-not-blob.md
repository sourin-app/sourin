# Agent Note: E1 门禁读工作区 ⇒ 假绿（测量对象被 git 自动转换替换）

Status: implemented

> 同域：本篇是「假绿」的一个实例 —— 测了工作区而不是 blob。总原则见
> [2026-10-12-gates-must-be-able-to-fail.md](../testing/2026-10-12-gates-must-be-able-to-fail.md)；
> 相关实例见
> [2026-10-18-fake-green-cache-label-reads-source.md](./2026-10-18-fake-green-cache-label-reads-source.md)
> 与 [2026-10-14-red-baseline-needs-clean-worktree.md](./2026-10-14-red-baseline-needs-clean-worktree.md)。

## Problem

E1 门禁断言「仓库里不许有裸 LF」，旧实现这样读文件：

```dart
String _src(String rel) => File(rel).readAsStringSync();   // 读**工作区**
```

而本机 `core.autocrlf = true` ⇒ 检出时 git 把 blob 里的裸 LF **自动转成 CRLF**。
于是「工作区里有没有裸 LF」永远回答 `false` ⇒ **这条断言在任何 blob 状态下都恒绿**。

实测（第 66 轮）：blob 里 `lib/ui/live_page.dart` 有 **103 行裸 LF**，
而工作区是 0 行、E1 全绿 —— 它一次都没发现过。

### 这是「假绿」最纯粹的一种

不是断言写错了，也不是门禁没跑，而是**测量对象被 git 的自动转换替换了**。
这类缺陷极难在 review 里看出来：代码读起来完全正常，「读文件然后检查内容」
是再自然不过的写法；错的是那个文件**不是你以为的那个文件**。

`core.autocrlf` 的默认值还因平台而异（Windows 常为 true，Linux/macOS 为 false），
所以同一个门禁在 CI 上可能是对的、在开发机上恒绿 —— 或者反过来。

## Decision

**测量对象从工作区换成 blob。**

```dart
String? _gitBlob(String rel) {
  final r = Process.runSync('git', ['show', 'HEAD:$rel']);
  if (r.exitCode != 0) return null;
  return r.stdout as String;
}
```

`must`：读取失败返回 **`null`，绝不退回读工作区**。
退回等于把那个假绿原样恢复 —— 而且更隐蔽：它只在出错路径上发生。

**E1 改成双向检查**（只查一半会漏掉另一类污染）：

| 文件类别 | 断言 |
|---|---|
| 豁免文件（`.gitattributes` 里 `-text -eol`，如 `live_page.dart`）| blob 里**不许混裸 LF** |
| 被钉 `eol=lf` 的文件（`cover_image` / `poster_card` / `follow_page` / `detail_page`）| blob 里**不许有 CR** |

**新增 E1b 自检**（本仓惯例：每条「零命中」式断言都要配阳性对照）。
「零命中」断言有个天然风险 —— 如果判据本身坏掉（比如正则写错、读错对象），
它也会一直绿，看起来完全正常。所以必须证明判据**既能命中也能不命中**：

- 豁免文件的 blob 必须**含** CRLF（否则 `_gitBlob` 读错了对象）
- `eol=lf` 文件的 blob 必须**不含** CR
- 字符串层面双向：`'a\r\nb'` 剥完不剩裸 LF；`'a\nb'` 剥完**必须**剩裸 LF

第三条是关键：它在同一段测试里同时验证「能命中」与「不会误命中」。

## Alternatives considered

- **把 `core.autocrlf` 关掉再读工作区** — 不用换测量对象，改动最小。
  否掉：那要求门禁**修改开发者的 git 配置**，是不可接受的副作用；
  而且 CI 与开发机的配置仍可能不同，同一份断言两边结论不一致。
- **读工作区，但先自己把 CRLF 转成 LF 再判断** — 不用起子进程，更快。
  否掉：那等于**在测试里模拟 git 的行为**。模拟一旦与真实 git 有偏差
  （比如 `.gitattributes` 的 `-text` 豁免没有正确模拟），门禁测的就是
  模拟器的行为，而不是仓库的真实状态。测量对象仍不是 blob。
- **用 `git diff --check` 代替自己写判据** — git 自带能力，不必重造。
  否掉：`--check` 只报尾随空白与「空白错误」，不回答
  「blob 里有多少行裸 LF」这种具体计数；而且它的输出格式会随 git 版本变化。
- **只在 CI 里跑这条门禁（Linux 上 autocrlf=false，读工作区也对）** —
  不必改实现。否掉：本地钩子与开发机上就失去保护，而问题恰恰是
  「本机全绿、CI 才红」这种双向不一致最难查。
- **不做 E1b 自检，只改测量对象** — 少写一半代码。否掉：改完之后
  「零命中」断言仍然可能是坏的，而这次改动的全部意义就是消除假绿。
  不配阳性对照，等于把假绿从一个地方挪到另一个地方。

## Consequences

- **收益**：E1 第一次真正能发现 blob 里的行尾污染。实测确认它能抓到
  103 行裸 LF —— 那是旧实现从未发现过的真实污染。
- **收益**：确立了一条可复用的判据纪律 —— **门禁要测仓库的真实状态
  （blob），不要测工作区**。工作区经过了 git 的转换，不是事实来源。
- **收益**：E1b 的阳性对照让这条门禁具备「证明自己没坏」的能力，
  而不是只在坏掉时静默通过。
- **代价**：每次跑 E1 要 `git show` 若干文件，起子进程比同步读文件慢。
  实测 t74 全量 21 条仍可接受。
- **代价**：判断依赖 `HEAD` 这个具体的 revision。若在 detached HEAD
  或 rebase 中间态运行，`HEAD:$rel` 可能不是人期望的那个版本。
  重访信号：E1 在非常规 git 状态下报出难以解释的结果时。
- **已知缺口**：只修了 t74 里的 E1。同仓其它用 `File(...).readAsStringSync()`
  做「源码文本断言」的测试，若也在检查行尾类属性，同样会被 autocrlf 欺骗。
  本次没有全仓排查。

## Verification

```text
t74 全量  ⇒ 21/21 绿
```

**故障注入（全部在工作区干净的条件下完成，不靠污染工作区）**：

| 注入 | 结果 |
|---|---|
| 让 `_gitBlob` 返回含裸 LF 的内容 | 红，精确指向「blob 里混进了裸 LF」|
| 让 `cover_image` 的 blob 含 CR | 红，精确指向「blob 里混进了 CR」|

两次注入都**没有改动工作区** —— 这一点很重要：如果靠污染工作区来造故障，
那测的仍然是工作区，就没证明「测量对象已经换成 blob」。
