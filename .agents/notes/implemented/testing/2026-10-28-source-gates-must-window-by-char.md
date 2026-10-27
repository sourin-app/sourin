# Agent Note: 源码判据的窗口必须按**字符**取，不能按字节

Status: implemented

## Problem

`streamproxy.rs` 里有几处"读自己的源码、断言某个结构在不在"的判据（本仓常见手法：
`include_str!("streamproxy.rs")` + 找锚点 + 取一段窗口）。其中三处这样取窗口：

```rust
let block = &src[i..(i + 3000).min(src.len())];   // ← 按**字节**切片
```

文件主体是中文注释 ⇒ **切点落在多字节字符中间就 panic**：
`end byte index 28013 is not a char boundary; it is inside '═'`。

这个坑在本文件里已经被踩过并写在注释里（`default_client_is_direct_no_proxy` 那段
"三个坑"），当时只改了**那一处**，另两处继续按字节 —— 于是 2026-10-28 又炸了两次，
而且**炸得毫无道理**：

```text
同一天、同一份源码内容、只改行尾：
  CRLF（git 检出的默认形态）⇒ log_path_source_declares_test_guard 红（切点落在 '丢' 中间）
  LF                        ⇒ upstream_timeout_is_applied 红（切点落在 '═' 中间）
⇒ 两条判据**不可能同时绿**，除非文件的行尾分布恰好让两个切点都落在边界上。
   而"行尾分布"取决于谁在什么时候用什么工具改过这个文件 —— 这与被测语义毫无关系。
```

发现过程本身就是教训：我撤回一条失败的优化（见对应 rejected 笔记）时用
`git checkout -- streamproxy.rs` 还原，行尾从 CRLF 变 LF ⇒ 一条判据立刻红，
而且它报的是 `char boundary`，看起来像"我改坏了代码"，实际是**判据在测行尾**。

## Decision

**所有"读源码取窗口"的判据一律按字符取，不按字节。**

```rust
let block: String = src[i..].chars().take(3000).collect();
```

三处统一（本文件内）：`log_path_source_declares_test_guard`、`upstream_timeout_is_applied`、
`default_client_is_direct_no_proxy`（这一处 2026-10-26 已改，本次只是把口径写进笔记）。

判据的**语义不变**：仍然是"从锚点起的一段窗口里必须/不得出现某个结构"，
只是窗口长度从"3000 字节"变成"3000 字符" —— 对中文注释占比高的文件，
字符窗口覆盖的内容更多，判据**更严**而不是更松。

## Alternatives considered

1. **把文件行尾改回 CRLF，让两条判据同时绿**。
   最强理由：零代码改动，`git checkout` 一下就好，且 CRLF 本来就是本机检出的形态。
   **否决** —— 这是在"迁就判据"而不是修判据：下次任何人把行尾统一（IDE 格式化、
   跨平台贡献者、`git config` 变化）就再红一次，而且红的理由每次都看起来像"代码坏了"。
2. **把两条判据删掉**（"源码结构判据本来就是权宜之计"）。
   最强理由：本仓已有"源码判据不如行为判据"的共识，删掉能减少假红。
   **否决** —— 这两条守的是**行为测不到**的东西：`sp_log_file_path` 必须早退
   （测进程里不许解析真实日志路径）、共享 Client 不许配整请求 `timeout`（会切断长流）。
   删掉就等于这两件事没人守了。
3. **构造一份"混合行尾"的文件让两个切点都落在边界上**。
   最强理由：能立刻绿，且不需要动判据。
   **否决** —— 这是把一次性的运气固化成仓库状态；下一个改这个文件的人会随机踩雷。

## Consequences

- 收益：两条判据不再与行尾/无关内容耦合 ⇒ "红"只可能因为**真的改了被测结构**。
- 收益：口径统一后，本文件里三处源码判据用同一种写法，后来人照抄不会再踩。
- 代价：窗口语义从字节变字符 ⇒ 同样的 `take(3000)` 覆盖的字节数变多（中文 3 字节/字），
  判据**更严**；若将来有人把窗口调小以适应注释长度，要按字符数思考而不是字节数。
- 验证：`cargo test --lib` **1626 passed / 0 failed / 77 ignored**（LF 与 CRLF 两种行尾下
  两条判据都绿，实测过；见 `.probe/n1-prewarm-ab.log` 期间的两次红记录）。

## Relations

- 同族：[./2026-10-27-dead-exemptions-make-coverage-metrics-lie.md](./2026-10-27-dead-exemptions-make-coverage-metrics-lie.md)
  —— 都在讲"判据自己制造了假信号"。
- 相邻：[../bug-fix/2026-10-21-three-gates-wrong-object.md](../bug-fix/2026-10-21-three-gates-wrong-object.md)
  —— 那篇是"判据作用在错误的对象上"；本篇是"判据作用在正确的对象上、但**取景方式**错了"。
