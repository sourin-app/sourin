#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""守卫：`docs/PITFALLS.md` 顶部汇总表里的「条数」必须等于台账里真实的行数。

## 为什么有这条

台账顶部的汇总表原先写的是**手填的常量**（A17 / B19 / C28 那一版），
而台账每天都在加条目、删条目（本文件的维护规则是「解决即删」）——
**没有任何东西在检查那两个数**。后来干脆改成了「见下」：不写数字，
于是「数字错了」的问题变成了「数字没有」的问题，同样读不出规模。

★ 两种形态是同一个病：**计数是副本，副本必然漂移**（见 A 组同名条目）。
⇒ 唯一不会再漂移的写法：数字由脚本从台账本身算出来，且 CI 每次核对。

## 判据口径（唯一权威，写在这里，别处只准引用）

```text
范围  = 两个显式标记之间的块      <!-- A组开始 --> … <!-- A组结束 -->
条目  = 块内**首格加粗**的行      即 `| **标题** | …`
剔除  = 表头行 / 分隔行（|---）/ 非加粗的表格行
```

★ 为什么必须「首格加粗」而不是「任何以 `|` 开头的行」：
C 组块首还有一张**症状 → 怎么办**速查表（6 行，首格是普通文字）。
按「任何 `|` 行」数 ⇒ C 组会数成 28（把速查表算成条目）。
**同一个数被两种口径数出来是 23 和 28** —— 这正是本文件反对的
「口径不写在判据里，就只能靠人记」。所以口径写死在这里，脚本按它算。

用显式标记而不是「按 `## A.` 标题切」：标题是给人读的、会被改措辞，
标记只服务于机器 ⇒ 改标题不该影响计数。

## 用法

```bash
python tools/count_pitfalls.py            # 只打印（默认 --check）
python tools/count_pitfalls.py --check    # 算出数与文档里的数不一致 ⇒ 退出码 1
python tools/count_pitfalls.py --write    # 把算出来的数写回文档
```

退出码：0 = 一致（或已写入）；1 = 不一致；2 = 文件/标记/表格缺失（**2 算失败**：
「查不到」不能当成「没问题」，这条同 `.agents/notes-scripts/notes-coverage.mjs`）。
"""
import re
import sys
from pathlib import Path

DOC = Path("docs/PITFALLS.md")
GROUPS = ("A", "B", "C")

# ★ 打印中文必须先保底，否则这门禁会**在自己的成功路径上崩**
#   （实测过：Windows 控制台 cp936 下含 U+21C4 / U+2705 的输出直接
#    UnicodeEncodeError ⇒ 判据在它该通过的时候失败）。
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
# ★ stderr 也要：漏了它会出现「stdout 正常、报错路径崩/花屏」——
#   实测（2026-10-21）：标记缺失走 stderr 打印，`⇒` 在 cp936 下被
#   backslashreplace 成字面量 `\u21d2`，红的时候**读不出人话**。
#   门禁在红的时候更需要可读，不是更不需要。
try:
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

_SEP = re.compile(r"^\|[\s:|-]+\|?\s*$")
_DATE = re.compile(r"20\d\d-\d\d-\d\d")


def _die_missing(group: str):
    """标记缺失 ⇒ stderr 一句话 + 退出码 2（「没核对」≠「数不一致」）。"""
    print(f"[count_pitfalls] 文档里找不到 {group} 组的开始/结束标记 "
          f"⇒ 本次什么都没核对（退出码 2，不是「数不一致」）", file=sys.stderr)
    sys.exit(2)


def count_groups(text: str) -> tuple[dict, list]:
    """返回 ({组: 条数}, 剔除明细)。剔除明细用于「报数字时同时报剔除掉了什么」。"""
    counts, dropped = {}, {}
    for g in GROUPS:
        start = text.find(f"<!-- {g}组开始 -->")
        end = text.find(f"<!-- {g}组结束 -->")
        if start < 0 or end < 0 or end <= start:
            # ★ 显式 2，**不要** `raise SystemExit("消息")`：
            #   传字符串时 Python 把消息打到 stderr 并以 **1** 退出 ——
            #   与 docstring 里「2 = 标记缺失」不符，读日志的人会以为是
            #   「数不一致」（1）。两个都非零，门禁照样红；但退出码是给
            #   人分类用的，混成同一个值等于这条判据只到结论不到原因。
            #   实测踩过：ci-gate 在 CI 里跑出来就是 1（2026-10-21）。
            _die_missing(g)
        block = text[start:end].split("\n")
        n = 0
        skip = {"marker": 0, "blank": 0, "separator": 0, "prose": 0, "other_row": 0}
        for line in block:
            s = line.strip()
            if not s:
                skip["blank"] += 1
                continue
            if s.startswith("<!--"):
                skip["marker"] += 1
                continue
            if not s.startswith("|"):
                skip["prose"] += 1
                continue
            if _SEP.match(s):
                skip["separator"] += 1
                continue
            if not s.startswith("| **"):
                # 非条目表格行（如 C 组块首的「症状 → 怎么办」速查表）
                skip["other_row"] += 1
                continue
            n += 1
        counts[g] = n
        dropped[g] = skip
    return counts, [dropped[g] for g in GROUPS]


def table_rows(text: str) -> list:
    """汇总表里 A/B/C 三行的行号（0 起）。"""
    rows = []
    for i, line in enumerate(text.split("\n")):
        m = re.match(r"^\|\s*\*\*([ABC])\.\s", line)
        if m:
            rows.append((i, m.group(1)))
    return rows


def replace_count(line: str, n: int) -> str:
    """把一行的最后一格换成数字（保留行首行尾原有格式）。

    ★ 上一版这里写错了：`f"{core} {n} |"` 里 core 仍带着旧的那一格，
      于是写出了「见下 17」——**看着像写成功了**（数字出现了），
      而表格里多了一格。⇒ 必须先把最后一格切掉再拼。
    """
    body = line.rstrip()
    assert body.endswith("|"), body
    head, _, _old = body[:-1].rpartition("|")
    return f"{head.rstrip()} | {n} |"


def main(argv: list) -> int:
    write = "--write" in argv
    if not DOC.exists():
        print(f"::error::{DOC} 不存在")
        return 2
    text = DOC.read_text(encoding="utf-8")
    counts, dropped = count_groups(text)
    rows = table_rows(text)
    if [g for _, g in rows] != list(GROUPS):
        print(f"::error::汇总表里没有 A/B/C 三行（找到 {[g for _, g in rows]}）")
        return 2

    print("按台账实测：", " / ".join(f"{g}={counts[g]}" for g in GROUPS),
          f"（合计 {sum(counts.values())}）")
    for g, d in zip(GROUPS, dropped):
        print(f"  {g} 组剔除：分隔行 {d['separator']} / 标记 {d['marker']} / "
              f"空行 {d['blank']} / 非表格行 {d['prose']} / 非条目表格行 {d['other_row']}")

    lines = text.split("\n")
    bad = []
    for i, g in rows:
        cur = lines[i].rstrip()
        cell = cur[:-1].rstrip().rsplit("|", 1)[-1].strip()
        want = str(counts[g])
        print(f"  文档里的 {g} 组 = {cell!r}，实测 = {want}")
        if cell != want:
            bad.append((i, g, cell, want))

    if not bad:
        print("✅ 一致")
        return 0

    if write:
        for i, g, _, want in bad:
            lines[i] = replace_count(lines[i], counts[g])
        out = "\n".join(lines)
        DOC.write_text(out, encoding="utf-8")
        print(f"已写回 {len(bad)} 处")
        return 0

    print("::error::汇总表的条数与台账不一致 —— 台账加删条目后必须同步（或跑 --write）")
    for _, g, cell, want in bad:
        print(f"::error::  {g} 组：文档写 {cell}，实测 {want}")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
