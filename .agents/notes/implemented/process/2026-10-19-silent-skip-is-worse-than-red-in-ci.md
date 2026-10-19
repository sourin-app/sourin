# Agent Note: CI 上「静默 skip」比「红」更危险 —— 以及它的判据该怎么写

Status: implemented

Independent: 与本轮其它笔记都不同 —— 那几篇分别讲
[恒绿断言的四种形态](../testing/2026-10-19-four-shapes-of-always-green-assertions.md)、
[阈值按实测不按传说](../testing/2026-10-19-thresholds-from-measurement-not-from-myth.md)、
[作废一个数字要 grep 全部位置](../testing/2026-10-19-invalidating-a-number-means-grepping-all-its-sites.md)。
那几篇讲**测试文件里**的判据；本篇讲**CI 环境里**的判据，
而这里的失效形态是「**整批用例根本没跑，但 job 绿**」。

## Problem

复核查出一条真隐患（2026-10-19，`release-verify`）：

```text
build.yml 的 windows 主 job 顺序：
  :240  flutter pub get
  :261  flutter test          ← 测试在这里
  :280  flutter build windows  ← 供出 libmpv-2.dll 的步骤在**之后**

而 build.yml 自己 :896-898 写着（2026-10-12，CodeRabbit 指出、
**已用 CI 实测证实**）：光 `flutter pub get` **供不出** libmpv-2.dll
没有 actions/cache 缓存 build/
⇒ CI 上 libmpv **本来就不存在**
```

依赖 libmpv 的文件走 `markTestSkipped` ⇒ **exit 0** ⇒ **CI 绿**。

**★ 但真正致命的只有 2 个文件**（复核逐文件核了标签）：

```text
46 个文件带 `native-media` 标签、默认 skip ⇒ 裸 flutter test 本来就不选，
  跳不跳都无所谓
★ 不带标签、会进默认套件的两个：
    test/zz_t66_player_jank_test.dart     8 条
    test/zz_t66_n11_bottombar_test.dart  7 条
  ⇒ 这 15 条在 CI 上全部静默 skip，而 job 绿。
```

**而我 6 轮下来一直在用 `player_jank` 的读数做判据** ——
它在 CI 上**一次都没跑过**。

## Decision

### ★★★ 位置是这个改动的关键 —— 我第一版放错，差点让仓库冻结

```text
第一版我把它排在「全量测试之后、构建之前」：

  :260  全量测试            ← libmpv 还不存在
  :297  ★ 我的断言          ← **它跑的时候 libmpv 必然不在 ⇒ 100% FIRED**
  :318  构建 Windows 发布版   ← **全文唯一**供出 libmpv-2.dll 的步骤

⇒ 它**自己制造了它要检测的那个缺失**：
   FIRED → 构建步骤不执行 → libmpv 永远供不出来 → 下次还是红
   ⇒ 自我封闭的循环，不会自愈。

★ 而 `Windows` 是**必需检查**（`CONTRIBUTING.md:26`，对管理员也生效）
  ⇒ 那个位置会让**所有 PR 永久 blocked**，仓库进入冻结态。
  ⇒ publish 也 `needs: [windows, macos, android]` ⇒ 连发版都发不出。
```

★ **我第一反应是「这需要 Owner 拍板」——那是错的。**
复核指出真正的问题是**位置**，而我把它误读成「缺一个前置构建步骤」。

⇒ 修法：挪到 `核验产物` 之后（那里 `Test-Path $mpv` 已经 throw 过）

```text
  :260  全量测试
  :301  构建 Windows 发布版   ← 供出 libmpv
  :322  核验产物（Test-Path throw 过）
  :387  ★ 断言守卫            ← 现在 libmpv 必定存在
```

代价只是**重跑两个文件**（它们在全量测试里已跑过一遍，当时是 skip），
**不需要新增一次完整构建**。

验证：libmpv 就位时守卫命令输出 `+13 All tests passed!`
（player_jank 8 + n11_bottombar 7 - 2 条因 `~` 计入）且守卫放行 ✔

★ **教训（这一条比改动本身更值钱）**：

```text
一条 CI 守卫的位置，决定它是「发现问题的探测器」
还是「制造问题的缺陷」。

判据：**守卫依赖某个产物时，它必须排在「产出该产物」之后。**
      排在之前 ⇒ 它报的是「你自己还没造出来的东西」，而非「别人弄坏了」。
```

### ★★ 挪位置时我差点把整个文件写空

```text
用 Python 脚本做「抽块 + 插块」时，`write()` 传了 list 而非 str
⇒ TypeError 在**文件已被截断写入之后**才抛出
⇒ git diff 显示 1747 行全删
⇒ 立即 `git checkout --` 恢复（代价：那一批改动一起没了，要重做）
```

★ 判据：**对 tracked 文件做结构性改动，用 `edit` 工具或先备份**。
  脚本批量改文件时，类型错误会在**写坏文件之后**才暴露。

### ★★ 顺带：`bash -e` 会吞掉 `::error::` 诊断

```text
`shell: bash` 实为 `bash --noprofile --norc -eo pipefail {0}`
⇒ 若 `out=$(flutter test <不存在的文件>)` 失败，`-e` 让整个 step 立刻中止
⇒ **走不到 grep** ⇒ 结果虽然正确（红），但 `::error::` 那句不会打印
⇒ 读者只看到「Could not find a file named ...」，分不清是门禁失效还是文件被删。
```

### 用可执行断言，而不是环境变量

```yaml
- name: 断言：默认套件里没有因缺件而静默 skip 的用例
  shell: bash
  run: |
    out=$(flutter test test/zz_t66_player_jank_test.dart \
                              test/zz_t66_n11_bottombar_test.dart \
                              --reporter=expanded 2>&1)
    echo "$out"
    if echo "$out" | grep -q '夹具缺失'; then
      echo "::error::libmpv 缺失 ⇒ 这 15 条门禁是**静默 skip**，不是通过。"
      exit 1
    fi
```

**为什么不用 `SOURIN_REQUIRE_LIBMPV=1`**（复核给的三条，我采纳）：

```text
① 它覆盖不到：实测 16 个依赖 libmpv 的文件里只有 **9 个**写了那个开关，
   另 7 个设了也照样静默 skip。
② ★ 它单独做会让主 job **每次必红**（libmpv 注定不在）
   ⇒ 团队很快会去关掉它 ⇒ 比现在更糟。
⇒ 所以真正的修法有先后：**先让主 job 真的 build 出 libmpv，再开断言**。
```

★ 我在注释里把这条「会红」的事实**明写出来**了 ——
因为它会让维护者困惑「为什么刚加的步骤就红」。

## Alternatives considered

**A. 只补一段文档，说明哪些文件会静默 skip。**
最强理由：零风险，不碰 CI 行为。
否决理由：**不解决假绿**。读全量读数的人仍然要靠人眼分辨
`~15` 是「缺件」还是「设计如此」—— 而这正是它做不到的原因。

**B. 直接在主 job 设 `SOURIN_REQUIRE_LIBMPV=1`。**
最强理由：一行，最标准。
否决理由：**它会让主 job 每次红**（libmpv 注定不在），
而「每次都红的门禁」会被关掉 —— 这是 CI 纪律里反复出现的一个陷阱。

**C. 把 `flutter build windows` 提到 `flutter test` 之前，然后开断言。**
最强理由：彻底（那 15 条真的跑了）。
否决理由：**为 15 条测试给拦合并的主 job 加一次完整 windows 构建**，
成本与收益要 Owner 拍板，不是技术问题。
⇒ 本次只做断言（把静默失效变成显式失败），**构建那步留给 Owner 决定**。

## Consequences

**★ 这条断言本身也踩了一次坑（已修）**

```text
我第一版判据写的是：grep -q '夹具缺失\|libmpv'
⇒ 实测在本机 libmpv **就位**时仍然 FIRED —— 误报！
```

原因：`zz_t66_player_jank_test.dart:216` 在成功时也会正常打印
`[LIBMPV] 夹具 = <路径>`，被 `grep libmpv` 命中。
★ 只有 `:221` 的 `[LIBMPV] 夹具缺失 ⇒ …` 才是缺件信号。

⇒ 判据收紧成只匹配「夹具缺失」，并把这次误报写进注释。

**注入验证（双向，都实跑）**

```text
libmpv 就位        ⇒ +7 All tests passed!      ⇒ GUARD PASSES ✓ 不误报
两个候选路径都缺  ⇒ +0 ~7 All tests skipped.  ⇒ GUARD FIRED ✓ 正确拦下
```

★ 第二条第一次**没测对**：我只移走了 `build/windows/x64/libmpv/` 那一个候选，
而 `_libmpvCandidates()` 返回**两个**（还有 `runner/Release/`）⇒ 测试照跑 ⇒ 守卫漏。
⇒ 必须移走**全部候选**才能触发。这条已记：
**验证「缺件」类守卫，要先确认缺件判据本身有几个候选路径。**

**★ 附带修掉的脏工作树**

```text
.dsh-progress/ 是 DSH 运行时产物（承载本会话 agent），未被 gitignore
⇒ 每次跑完 `git status` 都不干净，会让 Owner 以为我漏了东西
⇒ 已加进 .gitignore:109（与 .probe/ 同类，但由 harness 生成）
```

**已知上限**

```text
· ★ 这条断言**现在就会让主 job 红**（因为还没让主 job build 出 libmpv）。
  这是有意的（把静默失效变成显式失败），但它需要 Owner 拍板下一步：
  是给主 job 加一次完整 windows 构建，还是明确接受这 15 条不在 CI 跑。
· 那 7 个「没有 `SOURIN_REQUIRE_LIBMPV` 开关」的文件仍然只靠
  `markTestSkipped`。本断言只覆盖会进默认套件的那 2 个；
  若将来某个无开关文件被去掉标签，本断言不会自动覆盖它。
```

**何时该翻案**

```text
· 若 Owner 决定给主 job 加构建，则本断言从「必然红」变成「真守卫」——
  那时才可以在别处再引入 `SOURIN_REQUIRE_LIBMPV=1` 加强。
· 若本仓将来改用 `flutter build` 的缓存或 setup-step 供出 libmpv，
  `:896-898` 那段注释的前提要同步更新，否则它会变成下一个「自相矛盾的注释」。
```

**★ 顺带发现（本篇的另一个教训）**

`build.yml` 里 `:840-846` 与 `:896-898` **两段注释自相矛盾**：
前者说「`flutter pub get` 会触发 CMake 配置供出 libmpv」，
后者说「**实测否定**了那句」。
⇒ CI 实测已赢，但前者仍在文件里 ⇒ 下一个人读到会困惑。
⇒ **未修**（改动面涉及整段重写），记进待办。