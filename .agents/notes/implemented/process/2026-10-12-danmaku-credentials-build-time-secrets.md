# Agent Note: 外部弹幕服务凭证在构建期由 secrets 注入，只挂步骤级

Status: implemented

## Problem

构建需要外部弹幕服务的官方凭证。三个约束同时成立：
仓库里不能有真实凭证；凭证只被**构建那一步**需要；
且凭证内容可能含引号 / `$` / 反引号，不能让它参与命令文本解析。

## Decision

仓库里只留空占位符。三条发布构建的**步骤级** `env` 从 GitHub secrets 取值，
构建命令用对应 shell 语法（Windows `$env:NAME`、macOS/Android `$NAME`）引用。

Independent: 外部服务凭证走构建期 secrets。凭据管理的一条独立规则。

## Alternatives considered

- **挂 job 级 env** —— 它最强的论据是省事：一处声明，全 job 可用。
  否决理由：job 级 env 会注入到该 job 的**每一个**步骤，「全量测试」与
  第三方 Action（checkout / flutter-action）都能读到 Secret，扩大注入面（CWE-94）。

- **用 `${{ }}` 文本插值** —— 它最强的论据是写法直观、跨 shell 一致。
  否决理由：文本插值让含引号 / `$` / 反引号的 Secret 改变脚本解析；
  作为环境变量值交给 `--dart-define` 则不经 shell 二次解析。

- **把凭证写进仓库，或让用户自己填 AppId 输入框** —— 否决理由：
  前者是事故；后者 Owner 已明确要求删掉该输入框。

## Consequences

- **收益**：Secret 的可见范围收窄到构建那一步；凭证内容不进入命令解析面。
- **代价与已知上限**：fork PR 拿不到 secrets ⇒ 两个 env 为空串 ⇒ `dart-define` 也是空串 ⇒
  `String.fromEnvironment` 缺省空串，App 回落到用户自填凭证，行为不变（这是可接受的上限，
  不是缺陷）。
- **重访条件**：该服务取消开源客户端凭证政策，或改为公开的免签名接口。
