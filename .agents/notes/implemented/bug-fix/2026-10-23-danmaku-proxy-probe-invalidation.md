# Agent Note: 代理配置变化使在途弹幕探测失效

Status: implemented

## Problem

设置页的服务地址和令牌变化已经使在途探测失效，但代理模式和自定义代理地址变化此前只保存偏好并刷新界面。旧请求随后成功、离线或抛异常时，仍可把旧连接条件下的结论渲染到新配置页面；成功路径还可能保存发起时的服务地址和令牌。

相关背景：[弹幕请求代理](../feature/2026-10-18-danmaku-request-proxy.md)定义独立代理配置；[设置与搜索边界](2026-10-23-danmaku-settings-search-boundary.md)处理诊断路径与设置边界。本笔记只记录代理配置变化与在途探测之间的失效契约，不替代上述决定。

## Decision

`DanmakuSourcePage._setProxy` 和 `_saveProxyUrl` 在保存代理偏好后调用既有 `_invalidate()`。模式赋值不再单独调用 `setState`，统一由失效逻辑刷新。失效逻辑递增序号、解除当前运行标记并清空结果和诊断；已有异步成功与异常分支的序号守卫丢弃旧响应。

代理偏好仍立即保存，服务地址和令牌仍仅在有效探测成功时保存。没有取消底层请求，也没有改变诊断模块的其他工作树改动。

新增六项 widget 行为测试挂载生产设置页，通过 `probeOverride` 和 `Completer` 控制响应时序，覆盖代理模式切换、自定义代理地址编辑与旧成功、离线、异常响应的组合。测试滚回结果区域后检查实际渲染文本、已保存偏好和测试按钮状态，避免将懒加载子项未挂载误判为结果已清除。

## Alternatives considered

### 仅刷新界面而保留探测序号

负对照保留原有 `setState` 刷新但移除本次失效逻辑，六项测试均失败。刷新本身没有使旧异步响应失效，因此不采用。

### 为代理变化另建异步状态或取消机制

既有 `_seq` 守卫已经覆盖成功和异常路径，复用它能保持单一失效契约。新增状态或取消机制会扩大修改范围，本次不采用。

## Consequences

收益：代理配置变化后，旧请求不再更新结果、诊断或服务地址与令牌偏好，用户可以立即重新测试。

代价：配置变化清空已有结论，需要重新测试；旧请求可能继续消耗网络资源直至结束，序号守卫只阻止结果生效。

本次修改只涉及两处代理处理、对应测试和本笔记；其他已有工作树修改保持原状。

## Verification

### 最终测试版本负对照

先读取生产文件和最终测试文件，再仅将两处代理处理临时恢复为修前逻辑：模式变化使用 `setState(() => _proxyMode = m)`，地址变化使用空 `setState`，不调用 `_invalidate()`。其余生产改动及最终测试内容保持不变。

实际命令：

```bash
export PATH="<flutter-sdk>/bin:$PATH"; flutter test test/zz_t1023_danmaku_proxy_probe_race_test.dart --concurrency=1
```

实际终态：`+0 -6: Some tests failed.`，退出码 `1`。六项均失败，覆盖两种代理变化与三种响应。

成功用例的实际断言输出为 `Expected: no matching candidates`，但找到包含 `stale-probe-version` 的已就绪状态文本，定位最终测试第 97 行。异常用例同样期望无匹配，却找到 `errno 0 · stale-probe-exception`，定位第 98 行。离线用例列于实际失败清单，最终测试第 99 行检查 `find.text(staleStatus.line)` 不存在；本次返回的完整离线错误正文被工具输出截断，未取得其逐字文本，不以早期版本日志替代。

### 精确恢复与修后回归

负对照后读取当前文件并逐处恢复两次 `_invalidate()`。恢复地址处理时一次 `edit` 返回 `file has not been read`，该次未修改文件；重新读取后恢复成功。随后核对生产差异，原有诊断模块改动仍保留。

实际执行的组合命令：

```bash
export PATH="<flutter-sdk>/bin:$PATH"; git diff --check; git diff --unified=3 -- lib/ui/settings/danmaku_source_page.dart; flutter test test/zz_t1023_danmaku_proxy_probe_race_test.dart test/task35_danmaku_source_page_test.dart --concurrency=1
```

Flutter 实际终态：`+12: All tests passed!`，组合命令最终退出码 `0`。新增六项与既有六项均通过。注意组合命令使用分号，最终退出码不代表前置检查通过；全仓 `git diff --check` 实际报告其他文件尾随空白，本任务没有修改这些文件。

### 独立复测与验收边界

Leader 消息确认已读取两处失效调用，并独立运行最终代理竞态与 task35 设置页测试，12 项通过、退出码 0。此项为 Leader 提供的独立复测结果，不冒充本代理亲自读取其原始日志。

### 双请求交错补测与独立复核

在原六项之外增加四项交错用例：代理模式或自定义地址变化后发起第二次请求，新请求先成功，旧请求随后成功或抛异常。测试断言请求计数确实达到 2、新结果持续显示、旧结果与旧异常均未上屏，并核对保存的代理配置、服务地址和令牌。

Leader 独立复跑时，模式切换两项先因查找“跟随系统”而失败；实际生产标签为“跟随系统代理”。修正精确标签后，两项在旧请求未完成时调用 pumpAndSettle 超时。此时加载动画仍持续运行，因此该处改为推进 400 毫秒的有限帧等待；其余请求计数、配置与结果断言保留。这两类失败属于测试交互问题，不作为生产竞态的故障注入证据，也不替代前述六项负对照。

Leader 随后独立运行完整竞态测试文件，实际终态为 `+10: All tests passed!`，退出码 `0`。完整日志保存在本地 `.probe/danmaku-interleave-bounded-pump-verification.log`，本次已重新读取核对全部十项用例与终态。此次仅修正测试交互，未修改生产代码。

以上是注入探针的 widget 行为验证，不是真实代理网络验证，也不代表真实客户端验收。真实代理连通、实际客户端交互和总计划验收尚未取得。本笔记的 implemented 仅描述局部修复已经落地，不标记总任务完成。
