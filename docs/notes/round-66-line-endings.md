# 第 66 轮：行尾（EOL）调查报告

> **核对时刻：2026-10-18 17:05**（本仓状态几小时内会变；引用前重新跑命令）
> **本报告只调查，未修改任何代码文件。**

---

## §1 现状（全部附命令）

### 1.1 已经有 `.gitattributes`，而且写得非常仔细

**这是本次调查最重要的发现**——不是「没有规范」，而是「规范存在，但有一个洞」。

```bash
$ ls -la .gitattributes
-rw-r--r-- 1 iuuuuuuuu 197609 5485 Oct  8 18:36 .gitattributes
```

它已经规定了：

| 模式 | 规则 | 理由（文件内注释原文） |
|---|---|---|
| `*` | `text=auto` | 默认保持仓库原样，不强制检出时的行尾 |
| `*.rs` / `*.dart` / `*.md` / `*.json` / … | `text eol=lf` | 被测试当**文本**读，换行必须可预测 |
| `*.ps1` / `*.bat` / `*.cmd` | `text eol=crlf` | Windows 原生脚本 |
| **`lib/ui/live_page.dart`** | **`-text -eol`** | **显式豁免：必须保持 CRLF** |
| `*.png` / `*.ttf` / … | `binary` | 二进制 |

`live_page.dart` 的豁免理由（`.gitattributes:56-72` 原文）：

```text
t74_cover_image_test.dart:462 的 E1 断言要求它「整文件 CRLF、不混裸 LF」。
它为什么会是 CRLF：历史原因（早期在 Windows 上被某个工具重写过），
而那条断言的用意是「**不许有人再整文件重写它**」—— 因为那样会让
git blame 全部失效，而 live_page.dart 是本仓被改得最多的文件之一。
```

**实测生效**：

```bash
$ git check-attr text eol -- lib/ui/live_page.dart lib/ui/player_page.dart
lib/ui/live_page.dart:   text: unset   eol: unset     ← 完全退出转换
lib/ui/player_page.dart: text: set     eol: lf
```

### 1.2 git 配置

```bash
$ git config core.autocrlf
true
$ git config core.eol
(空)
```

`core.autocrlf=true` 是 Windows 的常见默认。**它会把检出时的裸 LF 转成 CRLF。**

### 1.3 工作区行尾分布

```bash
# 方法：find + grep -lU $'\r'
```

| 目录 | CRLF 文件 | LF 文件 | 说明 |
|---|---|---|---|
| `lib/` | **18** | 181 | 见下方清单 |
| `test/` | **21** | 472 | |
| `rust/sourin_core/src/` | 2 | 29 | |
| `tools/` | 5 | 0 | `*.ps1` 按规范就该是 CRLF ✅ |
| `docs/` | 0 | 31 | 全 LF ✅ |

`lib/` 下的 18 个 CRLF 文件：

```text
lib/design/theme/app_theme.dart
lib/design/theme/app_theme_data.dart
lib/design/widgets/app_icon_button.dart
lib/design/widgets/app_outlined_button.dart
lib/design/widgets/app_switch.dart
lib/design/widgets/app_text_button.dart
lib/design/widgets/app_text_field.dart
lib/design/widgets/app_tooltip_slider.dart
lib/ui/app_update_bootstrap.dart
lib/ui/cache_page.dart
lib/ui/cast/cast_button.dart
lib/ui/detail_page.dart
lib/ui/follow_page.dart
lib/ui/live_page.dart          ← 唯一一个「有意豁免」的
lib/ui/settings_page.dart
lib/ui/theme/app_colors.dart
lib/ui/widgets/plugin_speedtest.dart
lib/ui/widgets/skip_marker_dialog.dart
```

★ **只有 `live_page.dart` 是规范的显式豁免**。其余 17 个是 `.dart`，
按 `*.dart text eol=lf` 应该在**入库时**被归一成 LF ——
但它们在工作区是 CRLF，说明检出时被 `core.autocrlf=true` 转回来了。
**这不是违规，是 `text=auto` + `autocrlf` 的正常行为。**
真正的判据是 **blob 里是什么**，不是工作区。

### 1.4 blob（仓库内实际存储）才是判据

```bash
$ git show HEAD:lib/ui/live_page.dart | 统计
blob  : CRLF=6035  裸LF=103  总行=6138  裸LF占比=1.68%
```

**⇒ 仓库里 `live_page.dart` 的 blob 是混合的：6035 行 CRLF + 103 行裸 LF。**

那 103 行不连续，分 3 段：

```text
1767..1809  (43 行)
1811..1842  (32 行)
3238..3265  (28 行)
```

### 1.5 混合型文件（同一个文件里 CRLF 与裸 LF 并存）

```bash
# 逐文件统计「CRLF 行数 < 总行数」
⇒ 工作区：**0 个**
⇒ blob  ：**1 个**（就是 live_page.dart）
```

★ 这个差异本身就是本节最重要的结论，见 §2.3。

---

## §2 为什么它是「测量工具问题」而不是格式问题

### 2.1 本轮实例一：注入静默失败（Lead 的遭遇）

```text
Lead 用 '\n' 匹配去注入 lib/ui/live_page.dart（CRLF 文件）
⇒ 匹配不到 ⇒ 脚本没改到任何东西 ⇒ 但脚本正常退出
⇒ 差点得出「门禁有效」的**相反结论**
```

### 2.2 本轮实例二：我自己的文件写成了 CRLF

```text
我写 test/zz_t66_live_embed_bounds_test.dart 时用 CRLF
⇒ git 警告 "CRLF will be replaced by LF"
⇒ 该文件在 test/ 下，按 *.dart eol=lf 会被归一
```

### 2.3 ★★ 本次新发现：**工作区与 blob 不一致**，这是最隐蔽的一层

Lead 报的是「103 行裸 LF」，我实测工作区是 **0 行裸 LF**。
两个数字都对，但测的是**两个不同的东西**：

```bash
$ git status --short lib/ui/live_page.dart
 M lib/ui/live_page.dart          ← 工作区是「已修改」状态

$ git diff --stat lib/ui/live_page.dart
 1 file changed, 104 insertions(+), 104 deletions(-)

$ git diff --ignore-all-space --stat lib/ui/live_page.dart
(空)                              ← 忽略空白后无差异 ⇒ 纯行尾差异
```

**⇒ 工作区里那 103 行裸 LF 已被转成 CRLF**（`core.autocrlf=true` 的检出行为，
或某次编辑保存时统一了行尾）。
`git diff` 显示 104 行改动，`--ignore-all-space` 后为空 ⇒ **纯行尾变化**。

### 2.4 ★ 位置实验（Lead 要求，已完成）

**问题**：同一个文件里混合行尾，注入行为是否**取决于位置**？

**实验设计**：在 blob 里取三个「连续两整行」的片段——

- `LF-zone`：blob 第 1768–1769 行（该段 has_cr = False/False）
- `CRLF-A`：blob 第 1–2 行（has_cr = True/True）
- `CRLF-B`：blob 第 5939–5940 行（has_cr = True/True）

分别用 `\n` 与 `\r\n` 做跨行匹配。

**结果**：

| 片段 | 在 blob 上 `\n` | 在 blob 上 `\r\n` | 在工作区 `\n` | 在工作区 `\r\n` |
|---|---|---|---|---|
| `LF-zone` | **1 命中 ✅** | 0 ❌ | 0 ❌ | **1 ✅** |
| `CRLF-A` | 0 ❌ | **1 ✅** | 0 ❌ | **1 ✅** |
| `CRLF-B` | 0 ❌ | **1 ✅** | 0 ❌ | **1 ✅** |

脚本：`.probe/eol_position_experiment2.py` / 读数 `.probe/eol_exp3.txt`

**⇒ 结论（比假设更精确）**：

```text
blob（混合）  ：行为**取决于位置** —— LF 区用 \n 成功、CRLF 区用 \n 失败
工作区（纯CRLF）：行为**一致** —— \n 一律失败、\r\n 一律成功
```

**这意味着什么**：

```text
· 开发者编辑的是**工作区** ⇒ 看到的行为是「一致的」（全 CRLF）
  ⇒ 因此他**无从察觉** blob 里还有 103 行是 LF
· 但 CI、`git show`、以及任何直接读 blob 的工具看到的是「取决于位置」
  ⇒ 同一处注入，本地成功、CI 失败（或反过来）
★ 这是比「整个文件是 CRLF」更隐蔽的形态：
  它不是"知道了就能避开"，而是"你在本地永远看不出问题"。
```

### 2.5 与「格式问题」的本质区别

```text
格式问题     ⇒ 观感不一致，功能不受影响 ⇒ 可以慢慢来
测量工具问题 ⇒ **让测量结果反转** ⇒ 会直接导致错误结论
```

本轮已有 3 次「因为行尾而差点或已经得出相反结论」的记录
（`AGENTS.md` §8 的注入坑①、Lead 的注入失败、我自己写文件时）。

---

## §3 三个方案对比

### 方案 A：全仓重写成 LF（激进）

**做法**：去掉 `live_page.dart` 的豁免，全部转 LF，改写 t74 的 E1 断言。

**解决什么**：
- ✅ 仓库内彻底无 CRLF（除二进制），零歧义
- ✅ `git blame` 在**未来**干净

**不解决什么**：
- ❌ **不解决**本次的核心问题：问题不是「有 CRLF」，而是「工作区与 blob 不一致」
- ❌ 不会阻止新污染（新文件仍可能写成 CRLF，只是入库时被归一）

**代价（★ 这一条否决了它）**：
```text
① t74_cover_image_test.dart:470 的 E1 断言必须改写
   —— 而那条断言的**用意**是「不许有人整文件重写 live_page.dart，
      因为会让 git blame 全部失效」
   ⇒ 为了统一行尾而整文件重写它，恰恰是那条断言在防的事
② live_page.dart 6138 行的 blame 全部失效
   —— 它是本仓被改得最多的文件之一（本轮就有 4 次提交动它）
③ 一次性 6000+ 行的 diff，会让本轮之后的所有 PR review 更难
```

**⇒ 方案 A 用「制造它要防止的损害」来解决问题 —— 自相矛盾。**

### 方案 B：只加 `.gitattributes`（温和）

**做法**：什么都不改（已经做了）。

**解决什么**：
- ✅ 阻止**新的**行尾混乱在入库层面扩散（`text=auto` 已生效）
- ✅ 保证被测试读取的文件是 LF

**不解决什么**：
- ❌ **不解决 blob 里现有的 103 行裸 LF**（`live_page.dart` 的 `-text` 豁免让它绕过归一）
- ❌ 不解决「工作区与 blob 不一致」导致的可观察性差
- ❌ 不解决 17 个 `.dart` 文件在工作区是 CRLF（虽然入库后会归一）

**代价**：几乎为零。

### 方案 C：只统一 `lib/` 和 `test/`（折中）

**做法**：把 `lib/` 18 个 + `test/` 21 个 CRLF 文件转 LF，保留 `live_page.dart` 豁免。

**解决什么**：
- ✅ 减小工作区与 blob 的表观差异

**不解决什么**：
- ❌ 仍然是「工作区 vs blob」问题没解决
- ❌ 同样会让 39 个文件的 blame 失效

**代价**：39 个文件的 blame 失效，收益仅是观感。

**⇒ 收益/代价比最差的一个方案。**

---

## §4 建议

### 4.1 我的建议：**先不做 A/B/C 任何一个，先做 D**

> **方案 D：修掉 blob 里那 103 行裸 LF，只动行尾、不动内容。**

理由：

```text
① 那 103 行是**污染**（9085c74 插入长注释时写成了 LF），不是设计
   ⇒ 修它不违背 t74 E1 的意图（E1 要的是"整文件 CRLF"，修完正好满足）
② ★ 修正：t74 E1 现在**是绿的**，因为 E1 读的是**工作区**（已纯 CRLF）
   而污染在 **blob** ⇒ **E1 绿是假绿，它根本测不到 blob 的污染**
③ 影响面：1 个文件、103 行、**零内容变化**
   ⇒ 用 `--ignore-all-space` 可验证 diff 为空
④ 不做全仓重写 ⇒ 不触发 6000+ 行 blame 失效
```

**做法**（下一轮实施，不是现在）：

```bash
# 1. 在工作区把 live_page.dart 显式转成纯 CRLF（它现在已经是）
# 2. 关键：**绕过 -text 豁免做一次显式入库**
#    因为 `-text` 意味着 git 不做任何转换 ⇒ blob 存什么就是什么
#    ⇒ 必须在写工作区时就保证是纯 CRLF，然后正常提交
file lib/ui/live_page.dart          # 确认 CRLF
git add lib/ui/live_page.dart
git commit -m "chore: 修掉 live_page.dart 里 103 行裸 LF（纯行尾，零内容变化）"
# 3. 验证：blob 里裸 LF 应为 0
git show HEAD:lib/ui/live_page.dart | python -c "import sys;d=sys.stdin.buffer.read();c=d.count(b'\r\n');print('CRLF=',c,'LF=',d.count(b'\n')-c)"
```

⚠️ **已经做了一半**：工作区现在**已经是纯 CRLF**（0 裸 LF），
`git status` 显示 `M lib/ui/live_page.dart`，`--ignore-all-space` 后 diff 为空
⇒ **提交这一次改动即可修好 blob**。

★ 但**我不建议现在提交**，理由见 4.2。

### 4.2 ★ 一个必须说清楚的判断

**「工作区已经是纯 CRLF」这件事，是谁做的、什么时候做的，我不确定。**

```text
可能来源：
  ① 我之前做注入试验时，Python 写回文件用了默认行尾
  ② 某个工具/编辑器保存时统一了
  ③ 检出时的 autocrlf 转换（但 autocrlf 只在检出时生效，不会改已检出的文件）

★ 我倾向 ①：我做 FAULT-4 注入和还原时，`cp /tmp/lp.chk lib/ui/live_page.dart`
  那次是**字节级还原**（md5 一致），不会改行尾。
  但更早的注入（写文件）可能改过。

⇒ **这是一个未经确认的改动，不该由我在调查任务里顺手提交。**
  它需要 Lead 判断：这个工作区状态是不是想要的。
```

**⇒ 所以我的建议是**：

```text
下一轮第一件事：
  ① 先确认工作区 `M lib/ui/live_page.dart` 的来源（谁改的、是不是纯行尾）
  ② 若是纯行尾 ⇒ 提交它（修好 blob 的 103 行污染）⇒ t74 E1 转绿
  ③ 然后跑一次全量 `flutter test` 确认没有测试依赖那 103 行的 LF
  ④ 最后再讨论「要不要全仓统一」（我的建议：**不要**，见 §4.3）
```

### 4.3 我反对「全仓统一成 LF」这个目标

```text
本轮定下的目标是「行尾统一」，但我调查后认为**这个目标是错的**。

理由：
· 仓库已经有 .gitattributes 规范，而且规范本身是对的
  （默认 text=auto + 对"被测试读取的"钉 eol=lf + 对 live_page 豁免）
· 唯一真实的问题是：**一个文件被污染了 103 行**
· 「统一成 LF」会付出 6000+ 行 blame 失效的代价，
  去解决一个「提交一次 103 行修复」就能解决的问题

⇒ 正确的目标不是「统一」，是「**让 blob 与规范一致**」。
  规范允许 CRLF（live_page.dart 就是），要求的是**可预测**。
```

### 4.4 真正该补的一条防线

```text
★ 加一条门禁：**blob 里的行为必须与 .gitattributes 声明的一致。**

现有 t74 E1 只检查 live_page.dart 一个文件（而且检查的是工作区）。
建议扩成：
  · 遍历 .gitattributes 里所有 `eol=lf` 的文件 ⇒ blob 里不许有 \r
  · 遍历所有 `-text -eol` 的文件 ⇒ blob 里不许混裸 LF（E1 现在做的）
  · 这两个方向都查，才叫「规范被遵守」

★ 这才是「不需要警惕就能生效」的防线：
  它检查的是 **blob**（唯一真实的事实），不是工作区（受 autocrlf 影响）。
```

---

## §5 本轮已发生的实际污染

| 项 | 事实 | 命令 |
|---|---|---|
| `live_page.dart` blob | **103 行裸 LF / 6138 行（1.68%）** | `git show HEAD:lib/ui/live_page.dart \| 统计` |
| 裸 LF 位置 | 3 段：1767–1809 / 1811–1842 / 3238–3265 | 同上 |
| 来源 | `9085c74`（P0 修复插入 103 行长注释时用 LF 写文件） | Lead 已定位 |
| 工作区状态 | **纯 CRLF（0 裸 LF）**，但 `git status` = `M` | `grep -cU $'\r$'` |
| t74 E1 现状 | **绿**（20/20，因为工作区已是纯 CRLF）★ 但这是**假绿**：E1 读的是工作区，而污染在 blob | `flutter test test/t74_cover_image_test.dart` |
| 我的新文件 | `zz_t66_live_embed_bounds_test.dart` 写成 CRLF，git 警告会归一 | 提交时警告 |

**⇒ 这说明「行尾统一」不只是「清理历史」，还要「防止新污染」。**
而防止新污染的正确方式不是「统一行尾」，是**门禁检查 blob**（§4.4）。

---

## §6 未验证 / 不确定的部分（诚实留白）

```text
① 工作区 `M lib/ui/live_page.dart` 的**来源未确认**
   —— 我不知道是谁、什么时候把 103 行裸 LF 转成 CRLF 的。
   可能是我的注入试验副作用，也可能是编辑器保存。**未经确认不做提交。**

② 我**没有**逐个验证 17 个 CRLF `.dart` 文件的 blob 是否也是 CRLF
   —— 按规范它们的 blob 应该是 LF（入库归一）。若要确认需逐个 `git show` 检查。

③ 我**没有**评估「全仓统一」对 CI 时间的影响
   —— 若 CI 上有行尾相关测试，影响面未知。

④ `tools/` 下 5 个 `.ps1` 全是 CRLF —— 这是**符合规范**的（`*.ps1 text eol=crlf`），
   不是问题。列在这里是为了避免下一个人误判。
```

---

## 附：本次所有命令的原始读数

见 `.probe/eol_exp3.txt`（位置实验完整输出）。
