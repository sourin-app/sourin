# Agent Note: tvbox_pan_check 分享链接预检引擎（hp0 移植）

Status: implemented

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
（uncertain 恒不缓存）。reqwest 全程 .no_proxy()（t69 假红教训的纪律化）。
FFI `tvbox_pan_check`（items 序列化成字符串传——ffi.rs 的 args 解析器只有
a.str(，零改动解析器、binary 文件风险最小）。

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
- 接线①（player_page 线路面板打标 bad/locked）暂缓：等登录分流的
  player_page 在制品落定后由本组补（命令已是原语，接线是纯消费）。

## 边界（如实）

- 115/123/天翼/139/光鸭/caiyun unsupported（端点密文/需二次逆向/取流在
  运行时插件），不猜。
- 迅雷 captcha_sign 未取证，被拒降级 uncertain。
- 缓存键不含 pwd（无码 locked 会遮 10 分钟内有码重查）——下批项。
