# Agent Note: 固定 URL 的封面 provider 复用请求头与缓存身份

Status: implemented

适用：2026-11-19，`lib/ui/widgets/cover_image.dart` 的 `_CoverNetworkImage`。
与[海报 Image 配置复用](2026-11-19-poster-image-configuration-reuse.md)部分重叠：
那篇减少父级对同一个 Image 的重复更新，本篇只减少 provider 的重复解析与散列，不能替代首次挂载或解码。
[内联封面请求头](../bug-fix/2026-11-10-inline-cover-request-headers.md)仍持有传输元数据解释，
[封面生命周期](../bug-fix/2026-11-08-library-cover-lifecycle.md)仍持有持久化和恢复权限。

当场按 cover/provider、请求头/hash 与图片配置检索 proposed/implemented/rejected：上述三篇为部分重叠的职责，
不存在另一篇固定 URL provider 解析复用决定；既有传输、持久化和 Image 生命周期均不被替换。

## Problem

ImageCache 会对同一个 provider 多次执行 hash 和相等性比较。固定 URL 的请求头策略每次返回
同一结果，但重复 getter 会再次解析 URI，相等比较又反复构造请求头 Map 的散列。
这类分配不会带来新的请求信息，也不能解决首次图像解码或 shader 链接成本。

## Decision

provider 构造时按完整 URL 解析并保存请求头；其 scale 与头策略对这个 URL 固定。
相等比较限定 `_CoverNetworkImage` 类型与精确 URL，hash 以该类型和完整 URL 延迟计算一次。
查询参数仍参与身份；与 SDK 默认 NetworkImage 不共用键，避免失败默认请求污染正确头策略的缓存。

这里只改变重复计算，保留源请求头与本地代理策略、超时、取消、gzip/进度、透明哨兵拒绝和解码尺寸。
不把播放流的 transport 超时应用到视频，不合并不同 URL/query 的图像，也不把 provider 缓存身份
当成作品身份或封面恢复授权。

## Verification

以下是已有验证的范围，补记时不重跑：`test/cover_image_headers_test.dart` 包含
同 URL 的相等/hash/Map 命中、query 差异、稳定 headers 引用及与 SDK NetworkImage 的隔离。
真实回环 HTTP、错误响应、透明哨兵、可见小图和缩放解码的既有断言继续保留。
原补验的 input/header 四项通过记录与首次导入失败在
`.probe/perf-product-candidate-20261119-root-v1/targeted-tests-v1.log`、
`targeted-tests-v2.log`、`targeted-tests-v3.log` 中保留；两项旧 HEAD 文本行尾断言失败不算整组绿。
完整范围见[控件分配及后继测量](../../../../FINAL_ACCEPTANCE_20261118.md)。

## Alternatives considered

- **继续每次重算 headers 与 hash**：最少状态、容易跟随动态策略；但这里策略只依赖不可变 URL，
  因此重复解析没有新增信息。
- **按请求头归一化或省略 query 合并 cache key**：可能增加命中率；但会改变原请求与内容身份，
  不满足精确 URL/query 和默认 provider 隔离，故不采用。

## Consequences

收益只确定为同一 provider 避免重复 URI/头 hash 计算；每个 provider 多保留一份 headers 引用
和延迟 hash。现有组件验证不证明应用帧时间改善、严格原始 20 场景性能通过或新整包验收。
若头策略变为依赖 URL 以外的可变配置，必须重访相等/hash 输入，不能仅更新 getter。
源码或头策略等 owning inputs 没变化时，沿用已有范围，不重复测试。
