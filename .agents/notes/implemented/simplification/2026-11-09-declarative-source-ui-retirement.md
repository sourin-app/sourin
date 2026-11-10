# Agent Note: 声明式源导入与编辑 UI 退役

Status: implemented

适用范围：2026-11-09 起的源管理 UI；只收紧声明式导入与编辑入口，不迁移或删除历史配置。

## Problem

正常新增入口只接受 TVBox，源列表也过滤旧声明式条目，但公开的
`ProviderImportDialog(seed: ...)` 仍能为声明式 seed 构造可提交的 JSON 表单。
设置页另留有声明式编排保存、文本回退和无调用的 `_configOf` 分派。
这些路径与后端停止支持声明式导入的现状不一致，用户会得到无法成功保存的编辑界面。

## Decision

导入弹窗只保留 TVBox 新增与旧 HTTP 配置编辑。声明式 seed 显示停止支持提示，
没有输入框、模板、编排按钮或提交按钮；未知 seed 同样只显示不可编辑提示。
关闭这种弹窗返回不含完成结果的取消，不调用核心命令。

设置页仅将 JS 交给源码编辑器、将 HTTP 交给原配置编辑弹窗，并核对返回 seed 的类型。
声明式编辑分派、编排保存、文本回退及无调用的 `_configOf` 删除。
共享 `SourceComposerDialog` 仍服务于 JS 的 `overridesOnly: true` 个性化覆盖，
HTTP 的 URL、请求头和保存命令保持可用。

TVBox 主地址、备用地址、多仓选择、导入结果与关闭时携带的完成结果保持原契约。
旧声明式配置的数据模型、历史、备份、存储格式和偏好文件保留；本决策不授权数据清理。

本决策部分取代[一屏源编排器](../feature/2026-10-17-source-composer-one-screen.md)
中的声明式产品入口，以及[声明式编辑保留源偏好](../bug-fix/2026-11-07-declarative-edit-preserves-source-preferences.md)
所描述的 UI 保存路径。两篇保留原 Decision，首部标明当前适用边界。
[JS 个性化覆盖层提案](../../proposed/architecture/2026-10-24-source-override-layer-after-call-js.md)
包含独立的覆盖层与数据变换能力，仍保留为提案，不因声明式入口退役而整篇拒绝或归档。

## Alternatives considered

- 只隐藏正常入口仍会让直接传入旧 seed 的调用方打开可提交表单。
- 删除整个共享编排器会破坏 JS 个性化覆盖；连同 HTTP 删除也超出已确认的退役范围。
- 自动转换或删除旧配置会改变用户数据，且不是本次 UI 清理的必要条件。

## Consequences

行为测试覆盖旧声明式 seed 的直接构造、损坏 JSON 的关闭结果、未知 seed 的拒绝、
HTTP URL/请求头回填，以及关闭编辑后 TVBox 新增不携带旧配置。
测试记录核心命令，确保只打开或关闭这些界面没有写入副作用。
主代理后续串行执行了导入、源管理、配置失效与公共弹窗关联回归，65 项全部通过。
真实入口验证覆盖取消不写入、JS 重载、窄屏菜单可达及明暗主题提交状态；
实机验证结果单独记录于根计划，这些 widget 测试不替代实机验收。

重启声明式编辑需要独立决策，同时恢复后端支持、真实产品入口与保存行为验证。
历史源码结构门禁若依赖已删除的旧页，应按当前产品路径重新建立证据，不能据此恢复死代码。

本次关键词审计其余命中分类如下：

- [Material 边界](../architecture/2026-10-17-material-keep-or-replace-verdicts.md)、
  [弹窗宽度约束](../bug-fix/2026-10-21-dialog-shell-width-clamp-not-height.md)与
  [退场焦点隔离](../bug-fix/2026-10-23-sheet-exit-keyboard-focus-isolation.md)
  只涉及仍保留的共享组件机制，与声明式入口是否开放无关。
- [片头记忆](../feature/2026-11-01-skip-memory-intro.md)中的“声明式”指片头片尾标注，
  与源导入无关。
- [搜索尊重源范围](../bug-fix/2026-11-08-search-respects-source-scope.md)
  将偏好保持扩展到通用注册路径，继续独立适用。
