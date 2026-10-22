# Agent Note: 判据已经存在 ≠ 用户看得到 —— 补上「取数/搜索」那条被漏接的线

Status: implemented

> 同域：[2026-10-19-dns-hijack-needs-authoritative-truth.md](../testing/2026-10-19-dns-hijack-needs-authoritative-truth.md)
> 那篇讲**判据本身**（判 DNS 是否被劫持必须与 DoH 真值对照）。本篇讲**接线**：
> 判据早就写好了，却只挂在一条路上，用户实际走的那条没有它。
> 相邻：[2026-10-19-danmaku-panel-seven-items.md](../feature/2026-10-19-danmaku-panel-seven-items.md)（R3 七个子项整体）

## Problem

被要求「新增 `dnsHijacked` 归因分类，让弹窗说真话」。动手前 grep，发现它**早就存在**：

```text
lib/ui/widgets/danmaku_settings_dialog.dart
  :208  enum DanmakuProbeFailure { ... dnsHijacked ... }
  :485  factory DanmakuProbeReport.forHijackedDns(...)
  :385  static bool isKnownForgedAddress(...)
```

但去数它的**调用点**，只有一处：

```dart
// :2473（_diagnose 内）
if (DanmakuProbeReport.looksForged(local)) { ... }
```

而 `_diagnose` 只在**用户手点「测试连接」**时才跑（`:2447`，调用点 `:2430`）。

用户报的「弹幕来源搜不了」根本不经过它：

```text
搜索 → lib/ui/player_page.dart:7378  catch (DanmakuException)
     → 面板 _searchResultBody（改动前）
       Text('搜索失败：${err.message}')
     ⇒ 画出来的是 core 的原文：
       「连不上弹幕服务（地址不通或服务没起来）。请检查地址 / 服务是否在运行。」
```

**被判成「服务没起来」的那次故障，真因是 DNS 被劫持、服务本体是活的。**
用户看到这句会去查服务 —— 方向错的，而且他查不出任何东西，因为服务没坏。

⇒ 缺口不是「没有判据」，是**判据只接了一条路**。本仓已有的「写了 ≠ 接线了」
（AGENTS.md §4）在这一处的具体形态：类存在、断言全绿、门禁覆盖的是那条**用户不走的**路。

### 为什么不能靠加一次 DNS 查询补上

唯一能让那条路自己拿到地址的办法，是在失败时再解析一次。
但那是一次**新增网络请求**，且落在**产品热路径**（取弹幕、搜索）上：

```text
· DoH 本身要走网络，而本机 DNS 已被劫持 ⇒ 它也可能被拦（见同域那篇的替代方案③）
· 取弹幕是高频动作，失败时再多一次外部请求 = 每失败一次多一次等待
· 「不引入网络探测依赖到热路径」是本轮明写的硬约束
```

## Decision

### 判据需要的输入本来就在异常里，此前被丢掉了

`SocketException.address` = **本机解析到、并去连的那个 IP**。
它一直在 `catch` 的异常本体上，只是 core 把它扔了：

```dart
// lib/core/danmaku.dart:2290（改动前是无参的 `on SocketException {`）
} on SocketException catch (e) {
  throw DanmakuException(
    '连不上弹幕服务（地址不通或服务没起来）。请检查地址 / 服务是否在运行。',
    uri: _safeUri(uri),
    resolvedAddress: _addressOf(e),   // ★ 本轮唯一新增的信号
  );
}
```

⇒ **零新增网络请求**：`looksForged` 是纯函数查表，喂它这个地址即可定案。
这条路的判据**不发一个包**。

### 「拿不到地址」必须被当成「没有证据」，不能当成「正常」

```text
只有 on SocketException 那一支有 resolvedAddress：
  · 超时（on TimeoutException）    ⇒ 空串 —— 那一支仍由「测试连接」路的 DoH 腿兜底
  · 服务端返回错误 / 非网络失败      ⇒ 空串
⇒ 空串一律**不判** hijacked。
```

这一条是**防"所有失败都归 DNS"**的唯一依据，比正向判定更重要：
判错成劫持会把用户从「查服务」推向「改 DNS」，而后者根本没坏 —— 比说错更糟。

### 分类入口复用同一份判据，不新造第二套

```dart
// lib/ui/widgets/danmaku_settings_dialog.dart:708
static DanmakuProbeReport fromDanmakuException(DanmakuException e, {String url = ''})
```

面板的搜索失败分支据此分级，且**保留 core 原文** —— 只在上面补一条"这一步该做什么"，
不翻译掉服务端真实说法。未命中时行为与改前**逐字同形**，故不劫持的场景零影响。

### 同步更正了一处已被推翻的结论（它会误导下一个人）

`test/zz_t66_r3_probe_truth_test.dart` 的文件头仍写着：

```text
⇒ **DNS 本身没被污染**（本机能解析出地址），**断在 TCP**
```

这句已被两轮实测推翻（真值是**劫持**）。它在一个**门禁文件的头部**，
比散落在文档里更危险 —— 读门禁的人会把它当成既定事实。已就地更正，并写明
**是什么证据推翻的**，使读者能据此判断「什么算证据」而不是只记住结论。

## Alternatives considered

### ① 在取数/搜索失败时也调一次 `dohLookup`

**最强论据**：与「测试连接」那条路完全同构，判定能力最强 —— 表抓不到的轮换新段也能识破。

**为什么否决**：**把网络探测引进产品热路径**，且这正是本轮明令禁止的。
更实际的问题是它自相矛盾：本机 DNS 已被劫持时 DoH 可能同样被拦，
拿它当这条路的判据 = 用可能同源的证据定案。

### ② 在 UI 层重新 `InternetAddress.lookup` 一次拿地址

**最强论据**：不碰 core，只改 UI，改动面最小。

**为什么否决**：**那是一次真实 DNS 查询**，落在搜索/取弹幕的失败路径上。
而且与①同病：解析器已被劫持时，它只会**再返回同一个假地址** ——
不构成独立证据，却付出了延迟代价。

### ③ 干脆不给这条路分级，保持原样

**最强论据**：零风险、零改动；判据表已知会轮换，本来就不是全集。

**为什么否决**：**未命中那张表 ≠ 正常**。而当前这句原文是「服务没起来」——
它不是"没说清楚"，是**说错了**，且指向一个没坏的东西。
本轮的全部意义就是让 UI 别把劫持说成服务故障。

### ④ 复用 `_diagnose`，让搜索失败也去跑一次完整分层诊断

**最强论据**：复用既有链路，不写第二套。

**为什么否决**：`_diagnose` 会做 `InternetAddress.lookup` + `Socket.connect`（各带 4s/6s 超时），
是**为用户主动点按钮设计的深度诊断**。搜索失败是后台路径，
把一次最长 10s 的分层探测挂上去会让面板卡住。

## Consequences

### 收益

```text
· 取数/搜索那条路现在与「测试连接」共用同一判据 ⇒ 两处不会漂移
· 零新增网络请求 ⇒ 热路径的延迟与依赖面没有变化
· resolvedAddress 顺手修掉一个信息丢失：core 早就知道连的是哪个地址，却没往外带
```

### 代价（必须记住）

```text
· **只覆盖「连不上」那一支**。超时分支拿不到地址 ⇒ 空串 ⇒ 落 connectionTimeout，
  其 remedy 已如实写明「**也可能**是本机 DNS 返回了假地址」，不是把话说死。
· **仍然只认已知伪造段**。轮换走的新段在这条路上识破不了（同域那篇的既定取舍）。
  ⇒ 若要补齐，只有「测试连接」那条路的 DoH 对照能做到，别在这条路上加探测。
· `resolvedAddress` 是一个 IP，会进 `detail` 与用户可见文案。已确认它不含 token
  （与既有 uri 字段同级），但**它是新出现在用户面前的信息**，将来若要脱敏需一并处理。
· 表会漂移的约束同样适用于本条链路：一旦有人复制一份判据到别处，两处就会分叉。
```

### 门禁

```text
test/zz_t66_r3_dns_hijack_test.dart（新建，13 条）
  ① 伪造段（SoftLayer / Dropbox / face:b00c）⇒ dnsHijacked
     且 remedy 必须含「DNS 换成可信的」**且** 不含「服务没起来」
     且 failure != connectionTimeout
  ② 反证：DoH 真值地址 / 空串 / 超时 / HTTP 5xx ⇒ **一律不是** dnsHijacked
     且 remedy 不含「换 DNS」   ← 这一半才是防过判的
  ③ 零网络：函数是同步的（改成 async 会直接编译不过）
     + 源码核对：函数体内不得出现 HttpClient / dohLookup
  ④ 伪造段表反证：5 个 DoH 真值地址一个都不许命中
```

```text
注入（双向，均用 edit 真改码、analyze 0 error 佐证非编译失败）：
  A 恒不命中  `if (false && …)`  ⇒ +8 -5   红（含①组与③组的同步断言）
  B 恒命中    `if (true || …)`   ⇒ +9 -4   红
    ★ B 杀掉的正是 ② 组 —— 说明反证那半边真的在起作用，不是摆设
还原：grep INJECT 0 命中、analyze 0 error、git status 无残留
回归：7 个 R3 门禁 +94 -0；t27_w8 / t27_w5 / task35 / t65b +56 -0
```

★ 写这条门禁时我自己踩了一次：断言写成 `contains('换 DNS')`，
而真实文案是「把系统 DNS 换成可信的」⇒ `+10 -3` 红。
我改的是**断言**，不是文案 —— 文案本来是对的。断言要对着真实措辞钉。

### 何时该翻案

```text
① 若将来给取数/搜索路也接上可靠的加密解析真值 ⇒ ② 的第一项代价消失，本篇可简化
② 若 core 改用别的传输层、不再抛 SocketException ⇒ resolvedAddress 失效，须换信号源
③ 若伪造段表被证明长期抓不到新形态 ⇒ 应重新评估「只靠表」在这条路上是否够用
```

## 原始读数（可复跑）

```text
本机 DNS（本轮实测，伪造地址会轮换 ⇒ 两次采样不同）
  python -c "import socket;print(sorted({x[4][0] for x in socket.getaddrinfo('danmu-api-delta.vercel.app',443)}))"
DoH 真值（绕开本机 resolver）
  curl -s --max-time 12 "https://cloudflare-dns.com/dns-query?name=danmu-api-delta.vercel.app&type=A" \
    -H "accept: application/dns-json"
三层因果与文案对照
  docs/notes/2026-10-19-dns-hijack-vs-tcp.md
```
