#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""守卫：`.github/release-notes.md` 的「关于本版本」那节不许出现会腐烂的统计口径。

## 为什么有这条

原文曾写着「全量 Dart 测试 2243 通过 / 47 跳过 / 0 失败」——
那是 2026-10-08 建 CI 时**手填的常量**，之后 11 天、约 50 个 commit 一次没更新，
而「0 失败」还是**向用户作出的不实陈述**（当时的实测是 -23）。
⇒ 已改写为不变量（「全部自动化测试通过」），但**没有机制防止它再次腐化**。

## 判据的三个关键点

```text
① **只扫「关于本版本」那一节** —— 全文扫会误伤「下载」表的版本号、
   「系统要求」的 macOS 12 / API 24 / 150 MB。
② **先剥 HTML 注释** —— 那一节的注释里留了「2243 通过」这类**取证记录**，
   那是历史证据必须保留；朴素 grep 会命中它 ⇒ 假红。
③ **只禁「数字 + 统计词」的共现**，不禁裸数字。
   ⇒ 「Windows 10/11」「约 150 MB」「72px」都合法；
   ⇒ 「本次修了 12 个问题」也合法（12 后跟的是「个问题」）。
```

## 用法

```bash
python3 tools/guard_release_notes_numbers.py .github/release-notes.md
退出码 0 = 通过；1 = 命中；2 = 文件或小节缺失
```
"""
import re
import sys

SECTION = "## 关于本版本"

# 数字 + （可选量词）+ 统计词  |  统计词 + 数字
FORBIDDEN = re.compile(
    r"[0-9]+\s*(?:条|个|项|处)?\s*(?:通过|失败|跳过)"
    r"|(?:通过|失败|跳过)\s*[0-9]+"
)

HTML_COMMENT = re.compile(r"<!--.*?-->", re.DOTALL)


def strip_html_comments(text: str) -> str:
    """剥掉 HTML 注释，但**保留行数** —— 否则报错行号会错位。"""
    return HTML_COMMENT.sub(
        lambda m: "\n" * m.group(0).count("\n"), text
    )


def extract_section(text: str):
    """切出 `## 关于本版本` 到下一个 `## ` 之间的内容。返回 (正文, 起始行号)。

    起始行号是 1-based 的 `## 关于本版本` 所在行 —— 报错的行号据此换算。
    """
    lines = text.split("\n")
    start = None
    for i, line in enumerate(lines):
        if line.strip() == SECTION:
            start = i
            break
    if start is None:
        return None, 0
    for j in range(start + 1, len(lines)):
        if lines[j].startswith("## "):
            return "\n".join(lines[start:j]), start + 1
    return "\n".join(lines[start:]), start + 1


def scan(path: str):
    with open(path, encoding="utf-8") as fh:
        raw = fh.read()
    body, start_line = extract_section(raw)
    if body is None:
        print(f"::error::{path} 里找不到「{SECTION}」小节 —— "
              f"守卫无法判断它有没有腐烂，请确认小节名没被改。")
        return 2
    clean = strip_html_comments(body)
    hits = []
    for offset, line in enumerate(clean.split("\n")):
        for m in FORBIDDEN.finditer(line):
            hits.append((start_line + offset, m.group(0), line.strip()))
    if not hits:
        print(f"::notice::「{SECTION}」小节正文里没有会腐烂的统计口径。")
        return 0
    print(f"::error::「{SECTION}」小节里出现了会腐烂的统计读数：")
    for lineno, matched, line in hits:
        print(f"  L{lineno}: 命中「{matched}」  {line}")
    print("::error::**保留承诺，删掉手段** —— 那节该写不变量"
          "（如「全部自动化测试通过」），不是每次发布都要更新的数字。")
    print("::error::若这个数字确实是长期不变的，请把它改成中文写法"
          "（如「两千余项」）或挪进 HTML 注释作为取证记录。")
    return 1


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    return scan(sys.argv[1])


if __name__ == "__main__":
    sys.exit(main())