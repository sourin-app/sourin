# Agent Note: 探针显式选择夹具，不发现开发机数据

Status: implemented

Related: [凭据入口命名空间隔离](../bug-fix/2026-10-31-keyring-test-isolation.md)、[开发播种只读且不带凭据](../process/2026-10-15-dev-data-seed-readonly-no-credentials.md)。本决定只补旧诊断的文件输入和临时副本边界，不更改产品数据位置、登录协议或Owner指示下的真实数据开发启动授权。

## Problem

七个T38诊断的机器路径直接指向本机plugins及其私有store；另一个历史换源诊断直接指向固定工作区快照。即使这些诊断原本需忽略项显式运行，固定路径和缺输入时提前return仍会把未执行伪装成成功，且复制生命周期可能删到同名任务目录。源码中的真实机器路径也是全树提交前置的一部分，不能只改文档或随机替换用户名。

## Decision

T38只接受显式SOURIN_T38_FIXTURE_ROOT：绝对本地磁盘目录，含plugins/srca.js、plugins/.data/srca.json和reference/srca.js。缺输入、空白/control、原始dot段、相对路径、ADS、非普通文件及每个路径组件的Windows reparse/symlink均在消费前报错，不退回用户/AppData或仓库.data。原real_creds_required_echo与Option API保留；缺失夹具是真错误，不是绿return。原29项断言、5个ignore及原网络选择保持。

选定输入只读；provider拿到的是process/clock/atomic唯一create_dir建立、create_new逐文件复制的可写副本。RAII只清理本实例创建的目录，不按固定workspace名预删；副本须在输入root之外。此为静态任务快照边界，不宣称对并发恶意替换路径的OS沙箱。

历史换源ignored测试要求SOURIN_T67_SNAPSHOT_DB，先检查显式输入/原始dot段/absolute/local-disk，再验证选定文件存在并复制到原temp路径；原ignore与完整迁移断言保持。没有读取真实DB或运行该历史诊断。

## Alternatives considered

- 仅把硬编码常量换成env：最小diff且保留调用关系，但仍留下固定目录删除、越界/reparse复制、静默missing和副本寿命问题，因此不选。
- 自动寻找用户插件目录并只读：最接近过去诊断输入，但读取真实私有store本身并非测试默认权限，且换机不确定；不选。
- 删除旧断言、加skip或用mock登录代替：能让普通测试绿，却掩盖原账户断言的未验证状态；不选。既有网络ignored项保留原选择，本轮不执行账户链。

## Consequences

实际std-only helper测试11 passed/0 failed/0 ignored，含缺输入真实子进程exit23、只读源字节、唯一副本/Drop cleanup、并发副本以及真实mklink /J的root/ancestor/member/tree逃逸拒绝。四个源故障（隐式回退、dot正规化、junction检查、复制隔离）都编译0而同测试真实exit101，最后冻结原helper再跑11/11。最初多filter误中子串的日志保留，不冒充negative-only；后继--exact先行负控另有原件。

七targets以cargo --offline --locked --no-run真实编译exit0；这只证明接线可编译，不代表旧账户目标动态通过。根另从当前store.rs逐字提取实际纯输入函数和两条测试，用rustc --test真实2/2；隐式fallback故障在相同缺输入断言真实exit101，未访问DB。回执位于统一任务目录sourin-performance-20261120-round15/parallel/isolated-t38及root-snapshot-test。

收益是测试输入可复现、无隐式真人目录访问、缺覆盖不再伪绿；代价是操作者必须显式准备正确输入，不保证账户/上游网络成功。原七target的29断言、5ignore及历史数据库迁移测试本轮均未动态执行；真实账户、外链、普通启动、性能及完整18+12不因此升级为通过。重新考虑只限输入合同或复制所有权变化，并须重新做真实路径负控；不以旧helper绿外推产品。
