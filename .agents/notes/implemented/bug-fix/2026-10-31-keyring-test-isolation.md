# Agent Note: 凭据入口的环境变量隔离

Status: implemented

Applies from 2026-11-14 to all Rust core keyring entry constructors. The pan
test-isolation decision established on 2026-10-31 continues to apply.

Independent: 与 [2026-10-30-pan-login-t5-aliyun-bizext-115-cookie-baidu-unicast.md](2026-10-30-pan-login-t5-aliyun-bizext-115-cookie-baidu-unicast.md)
（登录协议修复）无关——本篇修的是**测试基建**破坏用户凭据的问题；
也与 2026-10-31-aliyun-bizext-lossy-and-body-dump.md（凭据落盘路径）无关，
本篇管的是"测试不许碰真凭据"。

Relations: complements the [keyring-only credential storage contract](../architecture/2026-10-25-pan-auth-keyring-only.md).
Storage format and production service names retain that separate contract.

## Problem（真实事故，非假设）

```text
09:33 Owner 扫码登录 UC（[PAN] 凭据已落盘）
13:40 / 13:47 两轮 cargo test --lib --release（全量）
14:14 检查：UC 凭据消失（Owner 被迫 14:26 重登）
14:20 Lead 跑 pan_auth --ignored（两个 ignored 钥匙串测试真跑）
14:28 检查：115 凭据也消失（CredRead 实证 pan/115.dsh-media-client-pan 不存在）
```

缺陷点：
1. `empty_cookie_acts_as_logout` **没挂 #[ignore]**（运行时 if-return 假跳过——
   正是本文件 2026-10-27 注释批评过的反模式），每次普通全量测试真跑：
   `save(cred(Uc,"x=y"))` 覆盖真 UC 凭据 → `clear(Uc)` 删除。
2. `roundtrip`/`collide` 虽已 `#[ignore]`，但任何人跑 `--ignored`
   就在真服务名 `dsh-media-client-pan` 上 save/clear Quark/Pan115/Tianyi。

钥匙串是**进程外共享状态**：测试在这个服务名上写的每个条目都是用户真凭据的
覆盖/删除。pan_auth 的 cookie 只存钥匙串（实现区禁文件写入有门禁），
⇒ 测试污染 = 用户登录态直接蒸发。

The settings UI also reads proxy, WebDAV and credential-sync passphrase entries.
A private data directory and a pan-only service override cannot isolate those
platform-store reads, including disconnected backup settings and availability
probes.

## Decision

```text
credential_namespace::service_name resolves every Entry service before construction.
Only an absent SOURIN_KEYRING_SERVICE uses each exact legacy service:
dsh-media-client-pan / dsh-media-client-proxy / dsh-media-client-sync /
dsh-media-client-credential-key. Entry users and stored-value formats stay unchanged.
A valid configured raw Unicode value P supplies pan's exact service P and the
separate services P-proxy, P-sync and P-credential-key. Valid values are not trimmed.
Empty, whitespace-only, control-character or non-Unicode configured values reject
before any Entry construction. Read helpers return None/unavailable and mutations
return Err; no missing-entry or configuration-error branch falls back to legacy.
The pan __probe__ constructor obeys the same rule as credential reads and writes.
测试模块 isolate_keyring()（OnceLock 一次性设为 dsh-media-client-pan-test），
三个旧钥匙串测试第一句都调它，将其平台后端条目与 legacy pan 服务分离。
empty_cookie 摘掉运行时 return 反模式、补 #[ignore]（与兄弟一致）。
新增源码门禁 tests_never_reference_real_keyring_service：测试模块不许出现
裸生产服务名（判据 concat! 拼接防自证陷阱；锚点用 `mod tests` 而非
#[cfg(test)]——后者被 :297 文档注释里的同款字面量截断扫描区，第一版假绿被
证红打脸后改锚，教训留档）。
```

## Alternatives considered

- **三个测试全挂 #[ignore] 完事**：隔离后它们可以真跑（验证真实 keyring 语义），
  挂 ignore 等于永久放弃这条覆盖。否决。
- **测试里 try/finally 恢复原条目**：测试根本读不到"用户原来的值"（读出来就是
  被覆盖前的）——覆盖已经发生，恢复无从谈起。否决。
- **换 keyring crate 的多 profile 能力**：crate 没有命名空间概念。否决。

## Consequences

- The caller must choose a unique namespace for an isolated application instance
  and compare all four derived service names with every legacy name. An arbitrary
  valid override is a configuration value, not proof of isolation by itself.
- `tests/credential_namespace.rs` installs an in-memory recording keyring builder
  before real public reads, writes, empty-input deletes, explicit clears and pan
  probes. It verifies actual constructor/backend service and user records, legacy
  defaults, raw Unicode overrides, missing-entry isolation and zero backend calls
  for invalid overrides. It invokes no platform credential backend and serializes
  environment changes. Mock roundtrips do not establish OS keyring persistence,
  remote authentication, application UI, startup or complete-package acceptance.
- 2026-11-14: the frozen four-test integration fixture was actually linked to the
  original normal core, whose complete tracked Rust inputs match the pre-fix
  committed core. It executed 1 passed / 3 failed / 0 ignored, with actual
  namespace, missing-entry and invalid-override assertions. The process used only
  the recording backend, preserved its inputs and naturally drained its owned
  job for over eight seconds. An earlier missing native-library link failure is
  retained separately and is not semantic RED. GREEN remains pending a fresh
  normal core built from the new local commit; no application isolation or
  complete-product acceptance is inferred from RED.
- Historical 2026-10-31 gate: `cargo test --lib --release` ⇒ **1944 passed / 0 failed / 92 ignored**
  （empty_cookie 从 passed 转 ignored、+1 新门禁，净变化 ±0）；
  `pan_auth --ignored` 单跑 3 passed（隔离空间里"空 cookie=登出"语义不回归）。
- Historical 2026-10-31 evidence: 全量测试与 --ignored 前后，真实钥匙串 7 条凭据
  （123/aliyun/baidu/guangya/quark/uc/xunlei）blob 逐字节 IDENTICAL（SHA-256 比对）。
- 证红：服务名临时换回裸真名 ⇒ 新门禁 FAILED（RC=101）。
- 边界：`-test` 命名空间偶发一条测试残留（首次并行运行出现、复跑自愈），
  判定为 keyring crate 进程内缓存与 OS 的瞬态不同步，只影响隔离空间；
  根修需动 crate，超出本篇范围，如复发另案。

## 教训（通用）

**测试与用户数据共享任何进程外存储时，"先隔离再跑"必须是结构性的**
（入口处改服务名/表名/目录），运行时 if-return 与 try-finally 恢复都是纸糊的。
本仓同族先例：测试目录隔离（dart_test.yaml 多档）、SOURIN_LOG_FILE 重定向。
