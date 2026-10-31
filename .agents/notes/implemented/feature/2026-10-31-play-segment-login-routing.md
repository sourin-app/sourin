# Agent Note: 起播分段打点 + getProgress 并行 + NEED_LOGIN 就地登录分流

Status: implemented

Independent: P1/P3 兑现 .probe/perf-audit-20261031.md 的优化排序；
登录分流兑现本批网盘直链转换（pan-share-native-conversion）的"未登录可一键登录"闭环。
三件事共享 player_page/ffi.dart 落点故合篇。

## Problem

性能审计的两大缺口：真机起播→首帧 p50=4.0s / **p90=20.4s** 长尾无法归因
（缺分段观测）；detail_page 的 getProgress 与前链无依赖仍串行。
体验缺口：网盘直链转换的 NEED_LOGIN 错误只报"请登录"，用户要自己跑到
设置里找登录入口——"点一下直接登录"断在半路。

## Decision

```text
P1 起播分段打点（零行为变化）：playback.rs ①resolve 开始 ②探测结束（P9 的
  2500ms 批截止段在此可量化）③maybe_proxy 结束；player_page ④open 完成
  ⑤首帧已出（自 open）。真机起播 p90=20.4s 的长尾从此可分段归因。
P3 getProgress 并行：与 getDetail 并行起跑（原串行在链尾；真 FFI 实测
  0.81ms/次 × 串行条数），unawaited(catchError) 防未处理异常，尾部 await
  同一 future（错误语义不变）。
登录分流：NEED_LOGIN 错误的 login_kind 带过 FFI 边界 → Dart _errorLoginKind
  → _loginAndRetry 直弹对应盘扫码/网页登录（空则原 provider 面板兜底）。
```

## 互检打回实录（本篇最有价值的部分）

第一版被复核人 fix-quark-builder-error 打回 **P1：登录分流是端到端死代码**——
Dart 半边做对了，但 login_kind 在 Rust 侧就被丢掉：playback.rs 的 map_err 只留
e.message，ffi.rs err_json 信封只有 error/kind。Dart 读的 value['login_kind']
恒 null ⇒ 分流分支永远走不到 ⇒ **只钉 Dart 读半边的门禁是假绿**（门禁绿、功能死）。

修法：playback.rs 错误出口经 provider_err_to_string 给 message 追加
`\x1flogin_kind=<盘种>` 私有序列化标记（日志落盘在标记之前 ⇒ 日志干净）；
ffi.rs err_json 剥标记并发射可选字段（无标记时输出逐字不变）；
跨端断言补上"NEED_LOGIN 经完整序列化后 JSON 里真有 login_kind"这层。

P3 备案：④ 日志 url 未脱敏（沿用既有起播行口径）；分段①在 ensure_session
之前，会话失败会留只有①的孤儿时间戳（可接受）。

## 教训

**跨端功能（Rust→Dart）的门禁必须钉到"序列化之后"那一层**——只钉消费端
源码形状， producers 丢字段时门禁照样绿。本篇的跨端断言
（login_kind_survives_resolve_error_envelope）就是这层。

## Alternatives considered

- **起播长尾直接上"探测后台回填"**：那是 P2 单独立项（动推送通道，风险中），
  没有分段观测之前连"哪段最肥"都不知道——先打点再动刀。否决跳步。
- **login_kind 塞进错误 message 让 Dart 正则解析**：正是本篇实际做的形态
  （\x1f 私有标记），但它必须配 err_json 结构化发射与跨端断言——裸字符串
  约定没有门禁就是隐式协议。否决裸约定。
- **_loginAndRetry 直接全局查"哪个盘没登录"**：越权猜测，错误里带了
  login_kind 就用错误里的。否决。

## Consequences

- 门禁：Rust play_segment + login_kind_marker 组、Dart playback_segment_seam
  5/5 + nonmedia_guard 11/11，全部注入证红实测。
- P2 一并修：player_page 全部 _errorKind 赋值/清空点配对 _errorLoginKind
  （陈旧 loginKind 误分流窗口关闭，复核逐点位号核对）。
- 事故留档：整改中批量替换脚本异常曾截断 player_page.dart，因 T4-I 已提交
  可 checkout 后逐条重放全部在制品编辑（16/16 复核零损失）。教训：大文件
  改动只用 edit 逐处替换，不用带异常路径的批量脚本。
