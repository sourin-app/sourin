# Agent Note: tvbox_pan_check 分享链接预检引擎（hp0 移植）

Status: implemented

Applies: 2026-11-09, anonymous checks through the application command and the retained internal checker entry points.

Independent: 取证底稿 = [reference-apk-benchmark](../../../../.probe/reference-apk-benchmark.md)
①⑤ 两节（FongMi fork 的 hp0 预检引擎逐字协议）；消费方 = pan-share-native-conversion
（转存前的"值不值得转"前置）与线路诊断（crank 报告的死链标注需求）。

## Problem

参考 APK 播放前先把分享链接逐条探活（状态机 ok/locked/bad/uncertain/unsupported
+ 缓存 + 归因文案），点进去才知道死链的体验被它消灭在列表层。我们无此层。

## Decision

新建 pan_check.rs：零凭据预检，五家（夸克/UC/百度/阿里/迅雷，协议逐字取自
T2 取证表；UC 走 pan_list 实测主机不走密文未证形态）+ unsupported 如实
（115/123/天翼/139/光鸭/caiyun——115/123 端点在 hp0.z 密文未解，如实声明）。
Semaphore(4) 限流 + 风控 30s host 冷却（退避不硬重试）+ 10min 进程内缓存
（uncertain 恒不缓存）。请求配方禁用环境代理，应用命令再显式应用当前全局策略。
每批预检固定 ProxyStore、策略修订和来源 provider；所有并发请求共用同一不可变
transport。普通请求保持 12 秒配方，百度保持独立 15 秒与手动重定向配方；
后者将 client 注入已有匿名协议，不读取账号。两类 client 必须来自同一修订，
构造期间发生策略变化最多重试三次，失败返回错误，不回退直连。
缓存键包含分享 URL、提取码、store 身份、provider 和修订；冷却使用同一策略
命名空间。过期或旧修订条目会清理，在途旧修订不得发布结果或冷却状态。
仅复用一个最新 transport，旧操作持有自己的 Arc，防止 store 地址被复用。
FFI `tvbox_pan_check`（items 序列化成字符串传——ffi.rs 的 args 解析器只有
a.str(，零改动解析器、binary 文件风险最小），provider 是可选来源标识。
播放器在 await 前捕获 provider，并保留代次检查。具体传输决策遵循
[CSP 全局代理与原配方](../architecture/2026-11-09-csp-global-routing-retains-engine-recipes.md)。

## Alternatives considered

- **迅雷 captcha_sign 硬猜**：算法未取证（hp0.z 密文未解），被拒时按
  uncertain 降级如实，不猜。否决硬猜。
- **全量并入 pan_drive**：pan_drive 是凭据工具链，预检是零凭据只读——
  职责分离，单独文件。否决。
- **并发不限流**：上游风控（"请求过于频繁，已停止以避免触发风控"文案就在
  hp0 归因里）。Semaphore(4) + 冷却。否决。

## Consequences

- 门禁：定向 16/16（axum 假服务器回放：ok/locked/expired/illegal/签名降级
  uncertain/429 冷却零重打/缓存命中零请求/截断闸/FFI 形状）；注入证红
  （夸克 ok 判定改坏 ⇒ 红 RC=101）；全量 cargo 1978/0。
- 复核（fix-t94-dialog-wiring）通过；当场修三小项：lib.rs LF 归位、
  百度 debug 日志不落含 receive_code 的 URL（提取码不进日志）、
  MAX_CHECK_ITEMS=100 截断。
- 线路面板消费遵循[预检接线](2026-11-01-pan-check-line-wiring.md)，不阻塞起播，
  换集/换源使旧结果失效。
- 本地代理行为验证覆盖五类协议、百度内部跳转、热变、提取码缓存隔离、
  多 store/provider 隔离、冷却切换和失败不直连。真实 AppState 命令内核测试
  不代表跨 FFI ABI、外部服务可用性或账号播放验收。

## 边界（如实）

- 115/123/天翼/139/光鸭/caiyun unsupported（端点密文/需二次逆向/取流在
  运行时插件），不猜。
- 迅雷 captcha_sign 未取证，被拒降级 uncertain。
- 未绑定应用策略的旧内部 global_checker 调用仍保留原路径，不能从应用命令的
  完成推断所有 listing/selected-file/cleanup 已接入代理。账号与临时副本操作
  是独立边界，仍须验证其 session、owner 和 generation 保护。
