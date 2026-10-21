# Agent Note: 注入面门禁改数「可执行行」—— 注释里引用被守文本不算注入

Status: implemented

> 同域：[门禁必须有能力变红](2026-10-12-gates-must-be-able-to-fail.md)
> （本篇保住的是「能变红」，代价见 Consequences）。
> 同域：[把两处「静默的不一致」改成 CI 里的显式失败](../process/2026-10-21-ci-gates-and-secrets-preflight.md)
> —— 本篇是那件事的**下游**：预检步骤必须拿到凭证值，于是凭证 env 从 3 处变成 5 处。

## Problem

`test/t27_w11_ci_appkey_inject_test.dart` 用**整文件文本计数**钉住凭证注入面：

```dart
expect(occurrences(workflow, kAppIdEnvLine), 3);      // 只许三条 build 步骤各一次
```

这条判据在 PR #32 上一次性红了三条（Windows 与 macOS 各 3 条，`全量测试` 步骤）：

```text
①  Expected: <3>  Actual: <6>      DANDANPLAY_APP_ID 的 env 声明应恰好在三条 build 步骤各一次
②  Expected: <1>  Actual: <2>      Windows 形态的 AppId dart-define 应只出现一次
⑤  Expected: true Actual: <false>  「APP_ID」的取值必须是 ${{ secrets.* }} 表达式
```

三个失败**同源**，而且都不是真的坏了：

```text
失败 ①② 的一部分：build.yml 里新写的一段注释**原样引用**了这两行文本
  #     DANDANPLAY_APP_ID: ${{ secrets.DANDANPLAY_APP_ID }}     # ⇒ 空串
  #   --dart-define=DANDANPLAY_APP_ID="$env:DANDANPLAY_APP_ID"
  ⇒ kAppIdEnvLine 5 → 6，kAppIdDefineWin 1 → 2
失败 ① 的另一部分：新增的两步「凭据预检」（windows / macos）**必须**拿到凭证值，
  因为 tools/check_required_secrets.sh 判的是**值空不空**（Actions 不提供列 secret 名的能力）
  ⇒ 凭证 env 从 3 处变成 5 处，且这 5 处全部是**步骤级**
失败 ⑤：注释里那行同样被 `kSecretValueMustBeExpression` 匹配到，而它后面跟的是 `# ⇒ 空串`
  ⇒ 逐行扫描把「注释的例子」当成了「注入点」
```

★ 关键点：门禁红在「**注释写得太详细**」上。而本仓的注释正是判据的唯一权威说明处
（`docs/AGENTS.md`：一个事实只应有一个权威陈述处，其余必须是指针）。
让注释为了迁就一个计数器而改写成「某变量: 某 secrets 表达式」这种含糊说法，
是把**说明**降级去伺候**机械**，方向反了。

## Decision

三处改动，判据本身（步骤级、只取自 `secrets.*`、job 级不许出现）一条没松：

### 一、计数只在**可执行行**上做

```dart
List<String> codeOnlyLines(List<String> allLines) =>
    allLines.where((l) => !l.trimLeft().startsWith('#')).toList();
```

★ 为什么是「整行注释」而不是「去掉行尾注释」：行尾注释在本仓大量出现（`# ⇒ 空串` 这种），
按行尾切会在 `#` 出现在字符串里时切错；而**注入只可能发生在可执行行**，
所以「只数非注释行」是从判据的语义出发的最小改动，不是图省事。

### 二、白名单从「三条 build」扩到「三条 build + 两条预检」，且**逐步点名**

```text
带凭证 env 的步骤集合 == {三条 --release 的 flutter build} ∪ {两步「凭据预检」}
每步块内：AppId 恰好 1 次、AppSecret 恰好 1 次
其他任何步骤带凭证 env ⇒ 红（「凭证注入面被扩散了」）
带凭证的步骤总数 == 5
```

★ 为什么不是「≥3」：`≥` 会让「随手给某个步骤加 env」永远合法，
最小权限判据就只剩一句口号。白名单要**能被列举**，新增时必须有人写下理由。

### 三、保留 job 级禁令（①b 原样未动）

`^      DANDANPLAY_(APP_ID|APP_SECRET):` 出现在 6 空格缩进 ⇒ 直接 `fail`。
这条是真正的最小权限底线（job 级 env 会让「全量测试」与第三方 Action 都读到 Secret），
本轮改动**没有**碰它。

## Alternatives considered

**A. 改注释：把那段 ```yaml 示例改成不含原文的转述（例如「变量名: 表达式」）。**
最强理由：零代码改动，门禁的判据一个字都不用动 —— 红的直接原因确实是注释。
否决理由：那段注释的全部价值就是**指着原文**说「它长这样，所以空串照样能编进去」。
把它改成转述，读者就得自己去 build.yml 里找原文对照，而注释里最该留下的是**可核对的原文**。
⇒ 用「让说明变模糊」来换「计数器不变红」，是在给门禁付不该付的代价。

**B. 给预检步骤换一套变量名（`APP_ID_FOR_PREFLIGHT`），让注入面看起来还是 3 处。**
最强理由：这样 `occurrences(workflow, kAppIdEnvLine) == 3` 原样成立，最难的那条断言不用动。
否决理由：变量名是**输入契约**，换名意味着 workflow 里要维护两份映射，
而两份映射迟早有一份漏改 —— 而且它**没有减少任何暴露面**（值一样被注入，只是叫了别的名字）。
⇒ 这是把「计数不便」伪装成「安全问题解决了」。

**C. 预检改成「不信环境变量，改用 GitHub API 查 secrets 总数」。**
最强理由：那是**事实核查**（能区分「没配」与「配了但这步读不到」），比查值强。
否决理由：`GITHUB_TOKEN` 没有读 secrets 的权限，要读就得另配 PAT
⇒ 为了守一个凭据，先给门禁自己加一个新凭据（详见
[把两处「静默的不一致」改成 CI 里的显式失败](../process/2026-10-21-ci-gates-and-secrets-preflight.md) 里方案 A）。

**D. 让 `全量测试` 等步骤也保留凭证 env（「反正都在同一个 job 里」）。**
最强理由：省事，且这些步骤确实在同一个 runner 上，凭据本来就已经在这个机器的环境里了。
否决理由：这正是 ①b 要禁的那件事的弱化版 —— 注入面每多一步，就多一个
「这个步骤的日志 / 第三方 Action / 上传的产物」可能带出值的机会。
⇒ 主 job 里除了发布构建与预检，其余步骤一律不挂凭证。

## Consequences

- **收益**：门禁仍然能红，而且红得更有分辨力。故障注入实测（真实注入，随后还原）：
  ```text
  往「- name: 全量测试」步骤块内插一行 DANDANPLAY_APP_ID: ${{ secrets.DANDANPLAY_APP_ID }}
    ⇒ ① 失败，报： 「- name: 全量测试」带着凭证 env，但它既不是发布构建也不是凭据预检
                    ⇒ 凭证注入面被扩散了（要么去掉，要么在白名单里显式说明理由）
    ⇒ 还原后 7 条全绿（flutter test test/t27_w11_ci_appkey_inject_test.dart → All tests passed）
  ```
- **收益**：注释从此可以自由引用被守文本 —— 判据与说明不再互相拉扯。
- **代价**：① 现在**依赖步骤名**（`_isPreflightLine` 认的是「凭据预检」四个字）。
  把预检步骤改名会让它不再被识别 ⇒ 红在「不是白名单」上。这个红是**该红**的
  （改名等于换了注入点的身份），但报错信息读起来像「注入面扩散了」，
  读的人要先想到「我是不是改了步骤名」。⇒ 已在 `_isPreflightLine` 上方写明这一条。
- **代价**：`codeOnlyLines` 只切整行注释。若将来有人把凭证写进行尾注释
  （`... # DANDANPLAY_APP_ID: 明文`），它不会被扫到 —— 但那段文本也不会被执行，
  不是注入点；真明文只能出现在可执行行，那条路仍然被 ⑤ 扫着。
- **何时翻案**：
  ```text
  · 若预检改成「查 API 事实」（方案 C 的否决理由消失），凭证 env 就只剩 3 处，
    白名单应改回 3，并把 ⑤ 的扫描范围继续保持「可执行行」。
  · 若将来出现第三类必须拿凭证的步骤（例如签名服务预检），
    白名单要**显式**加它并写一行「为什么它也要」，不要为了省事改成 `>= 3`。
  ```
