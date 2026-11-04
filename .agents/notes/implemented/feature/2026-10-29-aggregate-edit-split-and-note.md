# Agent Note: 聚合源编辑拆成「只编辑链接」+「管理子源」两个弹窗，并加备注/去重/只显示聚合源

Status: implemented

后续局部扩展：[源筛选与多模板管理](2026-11-04-settings-owned-html-home-library-and-source-filters.md)
增加筛选范围内批选和排序，保留屏外选择；本文独立编辑入口、源身份和扇出决定不变。

Independent: 与 `2026-10-29-restore-auto-disabled-sources.md`（谁参与搜索）不同：
本篇只改**配置入口与配置项**（弹窗结构、备注、去重、列表过滤），不改扇出、不改搜索。

## Problem（Owner 一次给了四条）

```text
① 聚合源编辑的时候只能编辑链接；子源管理单独再做一个编辑配置弹窗
② 要可以起备注 —— 如果有多个聚合源，有备注就能区分了
③ 还要可以去重
④ 链接编辑里的「网盘与凭据」不是已经拆成公用配置了吗？这里就移除掉（登录凭据同理）
⑤ 其他源暂时全部关闭，只保留 tvbox 聚合源用来测试
```

原状：一个 `TvboxAggregatePage` 把三块（订阅链接/子源勾选/网盘与凭据）塞在一页里，
「编辑链接…」点进去看到的是**一整页子源勾选 + 网盘凭据**，与"编辑链接"这个名字完全不符。

## Decision

```text
① 拆两个入口：
   ·「编辑链接…」`agg-edit-link` → 弹窗里**只有**链接 + 备注（零 Checkbox、零凭据区）
   ·「管理子源…」`agg-manage-sites` → 弹窗里是子源列表 + 去重按钮 + 保存
   （保存键分开：`agg-link-save` / `agg-sites-save`，失败文案画在各自弹窗内）
② 备注：`AggregateConfig::note`（trim、最多 60 字）随配置落盘；页面头部显示，空则不画
③ 去重：`tvbox_aggregate_dedupe_sites` —— 判据 `(站名, api)` 都相同才算重复，
   保留第一个、其余**停用**（不是删除，可一键恢复）；幂等（没有重复返回 0）
④ 页面不再挂「网盘与凭据」区（`TvboxAggregateCredentialsSection` 类保留但**不 mount**）
⑤ `AggregateConfig::solo`：**只在列表层**过滤（`commands::list_providers`），
   子站搜索/扇出一切照旧 —— 真停用子站会让聚合源变空，与"用来测试"正好相反
```

## Alternatives considered

### A. 去重就**删除**重复的源

**最强理由**：列表最干净，用户不用再管。

**否掉的原因**：删除不可逆（配置里那条记录就没了，重导才会有）。
Owner 的诉求是"列表别重复"，不是"把这些站从磁盘抹掉"；停用可一键恢复，代价更小。

### B. solo 用"把其它源全部停用"来实现

**最强理由**：复用一个已有概念（停用），不动代码。

**否掉的原因（这是本轮最关键的判断）**：
`enabled_children` 只认 enabled 的源 ⇒ 全停用会把**聚合源自己的子站一起清空**，
结果剩一个空聚合源、"搜什么都 0 条"，跟"用来测试"正好相反。
⇒ solo 必须做在**列表层**（`list_providers` 过滤），扇出不动。真机验证：
`list_providers` 只剩 1 个（tvbox_agg），而聚合候选子站仍有 72 个。

### C. 编辑链接弹窗里保留"网盘与凭据"（反正已经能隐藏）

**最强理由**：少删一块 UI。

**否掉的原因**：那两块已经拆到网盘账号页做**公用配置**，留在聚合源编辑里会出现
"两份入口改同一份配置"的歧义，且与"这个弹窗只编辑链接"的语义冲突。
⇒ 移除（类保留，避免动无关代码）。

## Consequences

**收益**

- 「编辑链接」名副其实：两个输入框，保存只改链接/备注。
- 多份订阅/多个聚合时靠**备注**区分（页面头部可见）。
- 子源重复能一键清掉（停用，可恢复），真机数据里 `csp-4kzhinan-79a914e4 / -47098b5a` 这类重复正是判据来源。
- solo 让"只留聚合源做测试"成为**可逆开关**，且不会把子站一起关掉。

**代价与边界**

- 备注只存在聚合配置里（不进 manifest，manifest 是编译期常量）⇒ 换机器要随配置同步。
- 去重按 `(站名, api)`：同名但**不同 api** 的站会被当作不同源保留（有意为之，避免误删）。
- 现在只支持**一个**聚合源 id（`tvbox_agg`）；备注已为"多聚合"留好位置，但多实例化不在本批范围。

## 验证结果（已发生）

```text
Rust：cargo test --lib tvbox_aggregate --release → 26 passed
  solo_flag_roundtrips_and_defaults_off   （默认关 / 存得住 / 响应带 solo）
  note_roundtrips_and_clips               （trim、落盘、响应带 note、超长截 60）
  dedupe_keeps_first_and_respects_api     （保留第一个、同 api 才算重复、不同 api 不误删）
故障注入（已实测真红）：
  `next.solo = solo` → `let _ = solo`      ⇒ solo_flag_roundtrips_and_defaults_off FAILED
  `next.note = clipped` → `String::new()`  ⇒ note_roundtrips_and_clips FAILED
  dedupe key 只按站名                      ⇒ dedupe_keeps_first_and_respects_api FAILED（误删 b1）
Dart：flutter test zz_t1088（9 条）+ zz_t1049（8 条）→ 17 passed
  ① 编辑链接弹窗：两个输入框 / 零 Checkbox / 零 agg-credentials / 零 pan-share-body
  ② 管理子源弹窗：列表 + 去重按钮
  ③ 去重文案（N 来自响应）+ 刷新
  ④ 备注逐字传参 + 页面回填、空备注不画行
  ⑤ 页面不挂凭据区
  ⑥ solo 回显 + 传参 true/false
真机（本机 108 源）：solo 打开后 `list_providers` = 1（tvbox_agg），聚合候选子站 = 72（不受影响）
```

## Relations

- 谁参与搜索（扇出范围）：[./2026-10-29-restore-auto-disabled-sources.md](./2026-10-29-restore-auto-disabled-sources.md)
- 转存目录（同批另一条）：[./2026-10-29-pan-temp-dir-for-share-save.md](./2026-10-29-pan-temp-dir-for-share-save.md)
