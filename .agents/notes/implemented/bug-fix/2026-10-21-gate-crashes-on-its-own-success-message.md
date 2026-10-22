# Agent Note: 门禁在自己的**成功路径**上崩掉 —— 退出码由"它想说的话"决定了

Status: implemented

> 同域：[2026-10-18-dev-tools-output-language-and-z-flag.md](../process/2026-10-18-dev-tools-output-language-and-z-flag.md)
> （那篇定「工具输出文案一律英文，不靠 BOM、不靠控制台代码页」）；
> [2026-10-21-windows-only-gates-need-platform-guards.md](../testing/2026-10-21-windows-only-gates-need-platform-guards.md)
> （同期另一类：判据在别的平台上恒红）。
> Independent: 本篇是**同一工具在同一平台上，无论判据结果如何都红**，
> 与那两篇的「平台假设」和「输出语言」都不是同一个失效点 —— 详见下面「为什么不适用英文化」。

## Problem

`tools/guard_release_notes_numbers.py` 在 CI run `39538011233` 的 Windows job 上 exit 1，
但**扫描本身是通过的**：

```text
Traceback (most recent call last):
  File "tools/guard_release_notes_numbers.py", line 105, in <module>
    sys.exit(main())
  File "tools/guard_release_notes_numbers.py", line 101, in main
    return scan(sys.argv[1])
  ...  L85: print(f"::notice::「{SECTION}」小节正文里没有会腐烂的统计口径。")
UnicodeEncodeError: 'charmap' codec can't encode character '\u300c' …
```

⇒ **绿的时候红，红的时候也红** —— 每次都红，于是这条门禁的输出里
再也读不出任何信息，等价于不存在。

### 真因：runner 的区域决定 Python 的 stdout 编码

```text
GitHub `windows-latest` = en-US 区域 ⇒ Python 输出被重定向（非 tty）时
按 locale 编码 cp1252 ⇒ 任何 CJK 字符都崩
本机（zh-CN）= gbk ⇒ 报的是 'gbk' codec can't encode character '\u21c4'
```

**同一个 bug，两种码页。** 而本机那次报 `\u21c4` 时，我把它判成
「只是显示问题，解析已经成功了」就放过了 —— 那次误判让这个 bug 多活了一轮。

### 为什么这道门禁此前从没暴露过

CI 里它一直红在**更早的地方**（`python3` 在 windows runner 上不存在，见
commit `6db33ba`）。装上 Python 之后，它第一次真正跑起来，才暴露出
「跑起来也必然红」这一层。

## Decision

在脚本最顶部（`import sys` 之后）把两个流强制成 UTF-8 并加降级兜底：

```python
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
```

- `encoding="utf-8"` —— GitHub 的日志与 `::notice::` 注释本来就按 UTF-8 解码
  （同仓 Dart/Node 步骤的中文在日志里一直显示正常），所以显示也是对的。
- `errors="replace"` —— 即使碰上既不支持 UTF-8 又不肯收降级字符的怪终端，
  最多把那一个字符打成 `?`，**绝不让门禁因打印而改变退出码**。

★ 判据：**门禁的退出码只能由判据本身决定，不能由"它想说的话"决定。**

## Alternatives considered

### ① 按既有决策把输出文案改成英文（`2026-10-18-dev-tools-output-language-and-z-flag.md`）

**最强论据**：那是本仓**已经写下的**决策，且更彻底 —— 不依赖任何编码。
本仓 `tools/live_probe_count.ps1` 已按它把 19 处判定文案全改英文。

**为什么否决**：**这条规则在本脚本上不成立**，因为本脚本必须回显
**文件内容里的中文**：

```text
  L183: 命中「2243 通过」  本次修了 12 个问题，全量测试 2243 通过。
        ↑ 标签可以英文化        ↑ 这一段是被检查的 .md 原文，无法 ASCII 化
```

英文标签消不掉这一个 CJK 片段 ⇒ 崩照旧。★ 判据：**"输出用英文"这条规则
只覆盖工具自己写的固定文案，覆盖不到它转述的、来自用户内容的那部分。**

### ② 在 workflow 里给这一步加 `env: PYTHONIOENCODING: utf-8`

**最强论据**：一行 YAML 的事，不碰脚本；且能让"所有"python 步骤一起受益。

**为什么否决**：修的是**调用点**而不是**工具**，于是
本机直接跑、别的 workflow 跑、别人 clone 下来跑，全都还是崩的。
★ 而且这个坑的第一步（`python3` 不存在）已经证明过：
**同一道门禁在不同调用点会有不同的失效方式，把修复留在调用点等于每次都要再想一遍。**
改在脚本里，它自己就带着这个保证走。

### ③ 只把 `::notice::` 那一条（L85）改成英文，红的那几条不动

**最强论据**：最小改动，只修"崩在任何情况都会红"的那一条，红路径本来就该红。

**为什么否决**：红路径**也需要**人读出「命中了哪一行、命中的是什么」——
如果它崩在打印上，用户看到的是 traceback 而不是「L183 命中『2243 通过』」，
**门禁就失去了"告诉人哪里错了"的功能**，只剩一个退出码。
本次故障注入就是为了确认这一点：注入后必须能看到 `L183: 命中「2243 通过」`。

## Consequences

### 收益

```text
· 门禁的退出码重新只由判据决定：通过 = 0，命中 = 1，不再受 runner 区域影响
· 命中时人能直接读到行号与命中的原文（故障注入已验证）
· 顺带把「本地码页不同 ⇒ 同一段代码报不同的 UnicodeEncodeError」记进注释，
  下一个人看到 'gbk' 或 'charmap' 都不会再判成"只是显示问题"
```

### 读数

```text
修前（CI，cp1252）      ：UnicodeEncodeError ⇒ exit 1（扫描其实通过）
修前（本机，gbk）        ：同样的崩，报 '\u21c4' —— 我误判成显示问题

修后（本机 gbk，干净）   ：::notice::「## 关于本版本」……  rc=0
修后（PYTHONIOENCODING=cp1252 模拟 CI，干净）：同上 rc=0
用同一环境跑**修前**版本 ：UnicodeEncodeError: '\u300c' ⇒ 复现了 CI 那个崩

故障注入（在「## 关于本版本」标题后第 2 行插入
          「本次修了 12 个问题，全量测试 2243 通过。」）：
  cp1252 下 ⇒ rc=1，并打印
    L183: 命中「2243 通过」  本次修了 12 个问题，全量测试 2243 通过。
  ⇒ 证明它**仍然能真变红**，且红的时候能说清哪里错了
还原后 ⇒ rc=0，git diff 空
```

### 代价

```text
· 本机 GBK 控制台下，中文 notice 会显示成乱码（字节是 UTF-8，终端按 GBK 解）。
  但退出码与 GitHub 日志都正确 ⇒ 属于纯显示问题，且只影响本机肉眼。
· 没有做"所有 python 工具统一加这个头部"的批量治理 —— 本仓另一个 python 脚本
  （tools/gen_release_notes.py）跑在 ubuntu 上（默认 UTF-8），当前不受影响。
  真出现第三个再抽公共模块，现在抽属于为两个调用点造框架。
```

### 何时该翻案

```text
① 若 CI 的 windows runner 切到 UTF-8 区域（或 Python 改默认 UTF-8 模式）
   ⇒ 这个头部不再必需，但留着无害（`errors="replace"` 仍然保命）
② 若出现第三个跑在 Windows 上的 python 门禁 ⇒ 把它抽成公共小模块，
   而不是复制粘贴这段头部
③ 若把该门禁的输出改成结构化 JSON（`::error::` 里只放机器可读字段）
   ⇒ 编码问题会彻底消失，但人读日志的成本会上升，届时需要重新权衡
```

## 给下一个人的提醒

```text
★ 本次最值得记的不是"加了三行 reconfigure"，而是这个形态：

  **一道门禁如果连"我通过了"这句话都说不出来，它就不是门禁。**

  它的两种红（真命中 / 打印崩）在调用方看来完全一样：exit 非 0。
  于是人会开始忽略它 —— 而"被忽略的红灯"和"绿灯"在效果上没有区别。

  ⇒ 判据：**看到一道门禁长期恒红，先分清它是"判据命中"还是"工具自己坏了"。**
    区分方法：在本地用**它那台的编码**（本次是 `PYTHONIOENCODING=cp1252`）
    跑一遍，看退出码是否随内容变化。若内容干净也红 ⇒ 坏的
    是工具，不是被检查的东西。
```
