# Agent Note: pan_auth 钥匙串测试污染真实凭据 —— service 名环境变量隔离

Status: implemented

Independent: 与 [2026-10-30-pan-login-t5-aliyun-bizext-115-cookie-baidu-unicast.md](2026-10-30-pan-login-t5-aliyun-bizext-115-cookie-baidu-unicast.md)
（登录协议修复）无关——本篇修的是**测试基建**破坏用户凭据的问题；
也与 2026-10-31-aliyun-bizext-lossy-and-body-dump.md（凭据落盘路径）无关，
本篇管的是"测试不许碰真凭据"。

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

## Decision

```text
service 名改为 fn service_name()：优先读 SOURIN_KEYRING_SERVICE，
未设置用生产值 dsh-media-client-pan（生产进程不设该变量 ⇒ 行为零变化）。
测试模块 isolate_keyring()（OnceLock 一次性设为 dsh-media-client-pan-test），
三个钥匙串测试第一句都调它 ⇒ 任何跑法（默认/--ignored/单条）真条目物理不可达。
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

- 门禁：`cargo test --lib --release` ⇒ **1944 passed / 0 failed / 92 ignored**
  （empty_cookie 从 passed 转 ignored、+1 新门禁，净变化 ±0）；
  `pan_auth --ignored` 单跑 3 passed（隔离空间里"空 cookie=登出"语义不回归）。
- **决定性验收**：全量测试与 --ignored 前后，真实钥匙串 7 条凭据
  （123/aliyun/baidu/guangya/quark/uc/xunlei）blob 逐字节 IDENTICAL（SHA-256 比对）。
- 证红：服务名临时换回裸真名 ⇒ 新门禁 FAILED（RC=101）。
- 边界：`-test` 命名空间偶发一条测试残留（首次并行运行出现、复跑自愈），
  判定为 keyring crate 进程内缓存与 OS 的瞬态不同步，只影响隔离空间；
  根修需动 crate，超出本篇范围，如复发另案。

## 教训（通用）

**测试与用户数据共享任何进程外存储时，"先隔离再跑"必须是结构性的**
（入口处改服务名/表名/目录），运行时 if-return 与 try-finally 恢复都是纸糊的。
本仓同族先例：测试目录隔离（dart_test.yaml 多档）、SOURIN_LOG_FILE 重定向。
