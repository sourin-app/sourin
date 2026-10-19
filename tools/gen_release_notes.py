#!/usr/bin/env python3
# ═══════════════════════════════════════════════════════════════════════
#  从 git 历史归纳「这一版改了什么」，注入 .github/release-notes.md
# ═══════════════════════════════════════════════════════════════════════
#
# # 为什么需要它（Owner 2026-10-19 反馈）
#
# ```text
# 「最近发的几个版本都没有更新说明，全都是默认的」
# ```
# 取证（不是猜）：
# ```text
# · .github/release-notes.md 是**静态模板**，172 行里没有一节是"这一版改了什么"。
# · 线上 v1.3.0 的 release body 实测 2974 字符，内容是**下载表格 + 安装说明 + 平台注意事项**
#   ⇒ 有正文，但**没有任何版本差异信息**。
# · 模板 `## 关于本版本` 那段写的是「**首个公开版本**」——
#   从 v1.0 到 v1.3 一直是同一句话 ⇒ 用户看到的"更新说明"确实等于没有。
# ```
#
# # 做法：从 git 提交归纳，而不是让人手写
#
# ```text
# 判据：仓库的提交信息已经**分类**（`修：` / `测试：` / `优化：` / `开发：` / `文档：`），
#       且都是中文人话 ⇒ 直接按 tag 区间归纳，比"让人每次手写"更可能长期被执行。
# ⚠️ 不是完美方案：提交信息里的技术细节对用户无意义 ⇒ 只保留**面向用户**的类别，
#    并剔除测试/开发/文档类（用户不关心 CI 与门禁）。
# ```
#
# # 用法
#
# ```bash
# python tools/gen_release_notes.py --from v1.2.0 --to v1.3.0 --notes .github/release-notes.md
# # 输出：把 `.github/release-notes.md` 里的 __CHANGELOG__ 占位替换成归纳结果
# ```
#
# ⚠️ **不做**：不调 GitHub API（本机常被限流，且 CI 里没必要多一次网络依赖）。

from __future__ import annotations

import argparse
import re
import subprocess
import sys

# ── 提交信息前缀 → 面向用户的分类 ───────────────────────────────────
#
# ★ 只收「用户能感知」的类别。测试 / 开发 / 文档 / CI 一律不进更新说明
#   （它们对用户是噪声，而更新说明的唯一用途是让用户知道**自己会看到什么变化**）。
#
# ★★ 2026-10-19（批末复核查出并修）：原来**漏了中文「新增」「功能」「回退」**
# ```text
# 实测（review 报告）：v1.0.0..v1.3.0 四个区间，`### 新增` 一次都没出现。
# 原因：USER_FACING 只有 `feat`（英文）没有 `新增`（中文），
#       而本仓提交信息是**中文前缀**为主 ⇒ 「新增：xxx」直接返回 None 被静默丢弃。
# 后果：用户永远看不到「新增了什么」——而这正是更新说明里最该有的部分。
# ```
# ⚠️ 顺序有意义：先匹配更具体的词。`功能` 必须排在 `修` 之前判断吗？不用 ——
#    `修` 不会误吞 `功能`。但 `回退` 必须自己一档，否则会被当成"没前缀"丢掉。
USER_FACING = [
    ("新增", "新增"),
    ("功能", "新增"),
    ("feat", "新增"),
    ("优化", "改进"),
    ("改进", "改进"),
    ("perf", "改进"),
    ("修", "修复"),
    ("fix", "修复"),
    ("回退", "调整"),
    ("调整", "调整"),
]

# 明确**不**进更新说明的前缀（防止把门禁/CI 的改动写进用户可见文案）
INTERNAL_PREFIXES = ("测试", "开发", "文档", "docs", "test", "chore", "ci", "refactor", "style")


def run(cmd: list[str]) -> str:
    out = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if out.returncode != 0:
        sys.stderr.write(f"[gen_release_notes] 命令失败: {' '.join(cmd)}\n{out.stderr}\n")
        sys.exit(2)
    return out.stdout


def commits_between(frm: str, to: str) -> list[str]:
    """取区间内的提交标题（不含合并提交）"""
    return [
        line.strip()
        for line in run(
            ["git", "log", "--no-merges", "--pretty=%s", f"{frm}..{to}"]
        ).splitlines()
        if line.strip()
    ]


def classify(title: str) -> tuple[str, str] | None:
    """返回 (分类, 去掉前缀后的正文)；内部改动返回 None"""
    # 形如 `修：xxx` / `fix(scope): xxx` / `feat: xxx`
    m = re.match(r"^([^:：（(]+)[:：（(]", title)
    if not m:
        return None
    prefix = m.group(1).strip().lower()

    for internal in INTERNAL_PREFIXES:
        if prefix.startswith(internal.lower()):
            return None

    for key, label in USER_FACING:
        if prefix.startswith(key.lower()):
            body = title[m.end():].strip()
            # ★★ 2026-10-19（复查后修）：scope 剥离原来只处理
            #   「正文以 `(` 开头」的情况（`fix(scope): xxx` 里那个 `(` 被
            #   前缀匹配吃掉了 ⇒ 正文从 `player): xxx` 开始 ⇒ 永不匹配）
            #   实测漏网：`player): 会话被换掉时…` / `pe): 多对一续播…` /
            #             `backup): 旧格式备份…`
            #   ⇒ 现在两种形态都剥：`(scope)` 或裸 `scope)`
            body = re.sub(r"^\([^)]*\)\s*", "", body)      # (scope) xxx
            body = re.sub(r"^[A-Za-z0-9_\-\s]*\)\s*", "", body)  # scope) xxx
            body = scrub_for_users(body)
            return (label, body) if body else None
    # ★★ 2026-10-19（复查后加）：**不再静默丢弃**。
    #   实测 v1.0.0..v1.3.0 有 43/156 条既不匹配内部也不匹配用户可见，
    #   返回 None 就 continue，**无任何日志** —— 写「功能：」的人不会知道
    #   它进了黑洞。现在打到 stderr，让丢的东西可见。
    sys.stderr.write(
        f"[gen_release_notes] 丢弃（前缀不识别）: {title[:60]}\n"
    )
    return None


# ── 用户可见文案的清洗（AGENTS §4 铁律）────────────────────────────
#
# ★ 提交信息里混着大量**开发过程用语**：`CR #29`、`t1015`、`门禁`、`探针`、
#   具体站点名…… 这些**不许**出现在用户能读到的更新说明里。
#   实测：v1.2.0..v1.3.0 归纳出的 29 行里有 **14 处**这类命中。
#
# 判据：能删的删（编号/括号引用），删了会读不通的整条丢弃 ——
#       宁可少一条，也不要给用户看一句他看不懂的话。
_SCRUB_RULES = [
    # 括号里的 CR 编号 / 测试编号 / 轮次：整段删
    (r"\s*[（(]\s*CR\s*#?\d+[^）)]*[)）]", ""),
    (r"\s*[（(]\s*(?:第[一二三四五六七八九十\d]+轮|Owner\s*\d+)[^）)]*[)）]", ""),
    # 行内的 `CR #NN` / `tNNNN` / `zz_tNN_*`：删词本身
    (r"\bCR\s*#?\d+\b", ""),
    (r"\bzz_t\d+[A-Za-z0-9_]*\b", ""),
    (r"\bt\d{3,4}(?:_[A-Za-z0-9_]+)?\b", ""),
]

# 删词后**必然**失去主语的开发用语 —— 遇到就整条丢，不做删词
#
# ★★★ 2026-10-19（第三次复查，这是最终取舍）
# ```text
# 前两版尝试"删词后清理悬空尾巴"，实测仍有 4 条读不通：
#   「在 macOS 上跑不动（cmd / 直接调 python）」  ← 主语 t1015 被删
#   「bili 音轨在缺 audio_url / 源未注册时只打印」← 主语"探针"被删
#   「真机里那条恒真」                            ← 宾语"断言"被删
#   「在英文控制台下读不回中文（ 的形状）」        ← "CI runner"被删
# ⇒ 这些词是**句子主语/宾语**，删掉必然残缺，靠后处理救不回来。
# ⇒ 取舍：**整条丢**。理由：用户看到一句读不懂的话，比少看到一条更糟；
#   而这些条目对应的都是**内部工具问题**（测试脚本/探针），用户本来也不关心。
# ```
_DROP_WHOLE_IF_CONTAINS = (
    # 这些词常作主语：删掉后句子必然缺主语
    "探针", "门禁", "断言", "假绿", "假红", "CI runner", "代码页",
    "autocrlf", "worktree", "stash",
)

# 可以安全删除的（它们是修饰成分，删掉句子仍完整）
_DROP_WORDS = (
    "CodeRabbit", "codeRabbit", "PR #", "PR#", "commit", "注入",
)

# 具体视频网站名（仓库铁律：不许出现）
_SITE_NAMES = ("bilibili", "哔哩哔哩", "次元城", "cycani")


def scrub_for_users(body: str) -> str:
    """把一条提交标题清洗成**用户能读懂**的句子；读不通就返回空串（调用方丢弃）"""
    s = body
    for pat, rep in _SCRUB_RULES:
        s = re.sub(pat, rep, s)

    # ★★ 2026-10-19（复查后收紧）：开发用语**从正文里删掉**，而不是整条丢弃。
    #   实测原做法误伤 11 条真修复（见 _DROP_WORDS 的注释）。
    for w in _DROP_WORDS:
        s = re.sub(re.escape(w), "", s, flags=re.IGNORECASE)

    # ★★★ 2026-10-19（第三次复查，最终取舍）：有些词是**句子主语/宾语**，
    #   删掉必然残缺，靠后处理救不回来 ⇒ **整条丢**。
    #   实测这四句删词后仍读不通：
    #     「在 macOS 上跑不动（cmd / 直接调 python）」  ← 主语 t1015
    #     「bili 音轨在缺 audio_url / 源未注册时只打印」← 主语"探针"
    #     「真机里那条恒真」                            ← 宾语"断言"
    #     「在英文控制台下读不回中文（ 的形状）」        ← "CI runner"
    #   ⇒ 用户看到读不懂的话，比少看到一条更糟。
    low0 = s.lower()
    if any(w.lower() in low0 for w in _DROP_WHOLE_IF_CONTAINS):
        return ""
    if any(w in low0 for w in _SITE_NAMES):
        return ""

    # ★★★ 2026-10-19（第二次复查，`release-verify` 指出）：删词会把残句风险
    #   **从入口搬到出口** —— 他只管开头，删完的**结尾悬空**没人管。实测：
    # ```text
    # 原文 …+ 行为门禁            ⇒ 删「门禁」后：…+ 行为          ← 悬空
    # 原文 （错配弹幕 / pin 残留 / 门禁假绿）
    #                             ⇒ 删后：（错配弹幕 / pin 残留 / ） ← 括号里空槽
    # 原文 （含 40+ 条新硬门禁）   ⇒ 删后：（含 40+ 条新硬）        ← 数量词失去宾语
    # ```
    # ⇒ 先做**结构清理**，再判残句。顺序很重要：清理后可能整条变成空壳。
    s = _cleanup_dangling(s)

    # 删词后可能留下空括号 / 悬空的分隔符
    s = re.sub(r"[（(]\s*[)）]", "", s)
    s = re.sub(r"^[+＋、,，:：\-\s]+", "", s)
    s = re.sub(r"[+＋、,，:：\-\s]+$", "", s)
    s = re.sub(r"\s{2,}", " ", s).strip(" ：:，,、-—")

    low = s.lower()
    # 太短或只剩标点 ⇒ 丢弃
    if len(s) < 4:
        return ""

    # ★★ 删除编号后可能留下**读不通的残句**（实测：「在 macOS 上跑不动」
    #    原本是「t1015 在 macOS 上跑不动」，主语被删掉了）。
    #    ⇒ 判据：必须以**动词/名词性开头**，不能以这些「缺主语」的形态开头。
    #    宁可少一条，也不要给用户看一句半截话。
    if _starts_like_orphan(s):
        return ""

    # ★★★ 2026-10-19（第三次复查）：还有一类**语义残缺**，删词后主语/宾语没了，
    #   但开头结尾都"正常"，靠位置判据抓不到。实测样本：
    # ```text
    # 「在 macOS 上跑不动（cmd / 直接调 python）」  ← 主语是 t1015，被删了
    # 「bili 音轨在缺 audio_url / 源未注册时只打印」← 主语是"探针"，被删了
    # 「真机里那条恒真」                            ← 宾语是"断言"，被删了
    # 「在英文控制台下读不回中文（ 的形状）」        ← 括号里剩个空格
    # ```
    # ⇒ 判据（保守）：**删除后必须仍含至少一个中文动词性成分**。
    #   这里用"是否含常见动词/结果词"做启发式，命中不了就丢 ——
    #   宁可少一条，也不给用户看一句读不懂的话。
    if not _has_meaningful_verb(s):
        return ""
    return s


# 判「这句话有没有说出一个可理解的结果」
#
# ⚠️ 这是**启发式**，不是分词器。判据：句子里含下面任一动词/结果词。
#    误判方向是"丢多了"（用户少看到一条），而不是"丢少了"（用户看到半截话）。
_VERB_HINTS = (
    "修", "改", "加", "减", "删", "换", "移", "接", "补", "去掉",
    "不再", "不会", "可以", "支持", "显示", "隐藏", "恢复", "退出",
    "卡", "慢", "快", "错", "失效", "崩溃", "丢", "漏", "重复", "缺",
    "统一", "收口", "拆", "合", "排序", "缓存", "持久化", "秒开",
    "自动", "手动", "默认", "禁止", "允许", "校验", "拦截", "跳过",
    "崩", "闪", "黑", "白", "花", "抖", "糊", "小", "大", "多", "少",
)


def _has_meaningful_verb(s: str) -> bool:
    for v in _VERB_HINTS:
        if v in s:
            return True
    return False


# 结尾悬空 / 结构破损的清理规则
#
# ★ 这些都在「删词之后」跑 —— 删词会产生它们。
_DANGLING_RULES = [
    # ① ★ 先删 markdown 粗体标记 —— 用户看到会**原样显示星号**（AGENTS §4）
    #     实测：「含 1 处**从改文案那天起就一直红**的」
    (r"\*\*([^*]*)\*\*", r"\1"),
    # ①b 删完粗体后可能剩下的孤立星号
    (r"\*{1,}", ""),
    # ② 结尾悬空的连接词：`… + 行为` / `… 与` / `… 和` / `… 及`
    (r"[+＋/／、,，]\s*[^+＋/／、,，（）()]{0,6}$", ""),
    # ② 括号里只剩分隔符或空白：`（错配弹幕 / pin 残留 / ）` ⇒ 去掉末尾那个 `/ `
    (r"[/／、,，+＋]\s*([)）])", r"\1"),
    # ②b 括号内结尾残留空格：`（pin 残留 ）` ⇒ `（pin 残留）`
    (r"\s+([)）])", r"\1"),
    # ③ 括号内以数量词结尾且失去宾语：`（含 40+ 条新硬）` ⇒ 整个括号删掉
    (r"[（(][^）)]{0,12}?\d+\s*[+＋]?\s*条[^）)]{0,4}[)）]", ""),
    # ④ 结尾是孤立的「+ xxx」且 xxx 太短（≤2 字，明显是被删剩的）
    (r"\s*[+＋]\s*[^+＋/／、,，（）()]{1,2}$", ""),
    # ⑤ 结尾悬空的破折号 / 冒号
    (r"[—\-－:：]+\s*$", ""),
]


def _cleanup_dangling(s: str) -> str:
    """把删词后产生的悬空尾巴收拾掉（跑两遍：一遍可能触发下一遍的条件）"""
    for _ in range(2):
        before = s
        for pat, rep in _DANGLING_RULES:
            s = re.sub(pat, rep, s)
        s = re.sub(r"\s{2,}", " ", s).strip(" ：:，,、-—+＋/／")
        if s == before:
            break
    return s


# 删掉主语后常见的残句开头（实测 v1.2.0..v1.3.0 归纳出的真实样本）
#
# ★★ 2026-10-19（复查后修正）：原来写 `"在 "`（**带空格**）—— 中文没有词间空格，
#    于是「在播放页按返回键会卡住」能过，而「在 macOS 上不再崩溃」被误杀。
#    实测被误删的合法句：
#      「在 macOS 上不再崩溃」「在 Windows 11 上安装包会报错」
#      「对 4K 视频的硬解支持」「剩余的 3 处卡顿」
#    ⇒ 改法：这些词只在**后面紧跟英文/数字**时才算残句（说明原主语被删了）。
#      中文紧跟时是正常句子开头，放行。
_ORPHAN_PREFIXES = (
    "在 ", "的 ", "了 ", "和 ", "与 ", "对 ", "把 ", "被 ", "将 ",
    "第二轮", "第三轮", "第一轮", "剩余", "以及",
)

# 「在/对/剩余 + 英文或数字」⇒ **可能是**残句（原主语被删）
#
# ★★★ 2026-10-19（第二次复查，这条最难）：不能只看开头就判残句。
# ```text
# 实测两句话开头一样，但一个是残句、一个是完整句：
#   ✗ 残句：「在 macOS 上跑不动」      ← 原本是「t1015 在 macOS 上跑不动」
#   ✓ 完整：「在 macOS 上不再崩溃」    ← 本来就是完整的，主语是"它"
# ⇒ 判据不是"开头有没有英文"，而是**有没有动词/结果**。
#   但用中文分词判断动词不现实（本脚本不引依赖）。
# ⇒ 改用**保守策略**：只要句子够长（≥8 个汉字）且不是以孤立的
#   「词 + 纯英文 + 无后续」结尾，就**保留**。
#   宁可多留一句读得通的，也不要丢掉用户真正关心的修复。
# ```

# 明确该丢的残句形态（这些是**确定**读不通的）
#
# ⚠️ 「剩余」「以及」**不在**这里：实测「剩余的 3 处卡顿」是完整句，
#    删了会误伤。它们只在「剩余+ASCII 且中文过短」时才丢（见 _ORPHAN_ASCII_RE）。
_ORPHAN_HARD = (
    "第二轮", "第三轮", "第一轮",
)

# 「在/对/把/被/将/和/与/剩余/以及 + 英文或数字」⇒ 可能是残句（需再看长度）
_ORPHAN_ASCII_RE = re.compile(
    r"^(?:在|对|把|被|将|和|与|剩余|以及)\s*[A-Za-z0-9]"
)


def _starts_like_orphan(s: str) -> bool:
    # ① 以「——」或标点开头 ⇒ 一定是残句
    if s and s[0] in "—－-，,。:：、":
        return True

    # ② 这些词开头 ⇒ 确定是残句（原主语被删，后面接什么都不通）
    for p in _ORPHAN_HARD:
        if s.startswith(p):
            return True

    # ③ 「在/对/把/被/将/和/与 + 英文」⇒ **只在句子很短时**才算残句。
    #    实测：「在 macOS 上跑不动」7 字（含空格）⇒ 残句
    #          「在 macOS 上不再崩溃」11 字 ⇒ 完整句，保留
    if _ORPHAN_ASCII_RE.match(s):
        # 汉字数（去掉英文/数字/空格/标点后的中文长度）
        han = len(re.findall(r"[\u4e00-\u9fff]", s))
        # ★ 阈值 6：中文部分少于 6 个字 ⇒ 读不出完整意思 ⇒ 丢
        if han < 6:
            return True

    return False


def build_changelog(titles: list[str]) -> str:
    buckets: dict[str, list[str]] = {}
    for t in titles:
        got = classify(t)
        if got is None:
            continue
        label, body = got
        buckets.setdefault(label, [])
        # 去重（同一个问题常有多条提交）
        if body not in buckets[label]:
            buckets[label].append(body)

    if not buckets:
        return ""

    # 固定顺序：新增 → 改进 → 修复
    order = ["新增", "改进", "修复"]
    lines: list[str] = []
    for label in order:
        items = buckets.get(label)
        if not items:
            continue
        lines.append(f"### {label}")
        lines.append("")
        for it in items:
            lines.append(f"- {it}")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--from", dest="frm", required=True, help="上一个 tag，如 v1.2.0")
    ap.add_argument("--to", dest="to", default="HEAD", help="本版 tag 或 HEAD")
    ap.add_argument("--template", default=".github/release-notes.md")
    ap.add_argument(
        "--out",
        default="",
        help="输出文件。**留空则打印到 stdout**；"
        "★ 绝不回写模板（第一版就地改写，导致模板被某一版的更新说明污染）",
    )
    ap.add_argument(
        "--allow-empty",
        action="store_true",
        help="允许归纳结果为空（默认**报错退出**，防止又发出一版没有说明的 release）",
    )
    args = ap.parse_args()

    titles = commits_between(args.frm, args.to)
    changelog = build_changelog(titles)

    if not changelog:
        if args.allow_empty:
            changelog = "### 本版无用户可见变更\n"
        else:
            sys.stderr.write(
                f"[gen_release_notes] ★ 归纳结果为空（{args.frm}..{args.to}，"
                f"{len(titles)} 条提交）。\n"
                "  ⇒ 这会让 release 又是「默认说明」—— 正是本脚本要防的事。\n"
                "  ⇒ 要么修正提交信息前缀，要么显式传 --allow-empty。\n"
            )
            return 1

    src = open(args.template, encoding="utf-8").read()
    if "{{CHANGELOG}}" not in src:
        sys.stderr.write(
            f"[gen_release_notes] ★ 模板 {args.template} 里没有 {{{{CHANGELOG}}}} 占位。\n"
            "  ⇒ 先在 .github/release-notes.md 里加一节，否则本脚本无处注入。\n"
        )
        return 1

    out = src.replace("{{CHANGELOG}}", changelog.rstrip())

    if args.out:
        with open(args.out, "w", encoding="utf-8", newline="\n") as f:
            f.write(out)
        sys.stderr.write(f"[gen_release_notes] 已写出 {args.out}\n")
    else:
        sys.stdout.write(out)

    sys.stderr.write(
        f"[gen_release_notes] ok: {args.frm}..{args.to} "
        f"{len(titles)} 提交 → {len(changelog.splitlines())} 行更新说明\n"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
