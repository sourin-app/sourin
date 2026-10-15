# 测试

> 本文原为根 [README.md](../README.md) 的「测试」一节，2026-10-15 拆分到 `docs/`，正文未改写。
> 文档地图见 [docs/README.md](README.md)；开发硬约束见 [docs/AGENTS.md](AGENTS.md)；
> 提交与评审纪律见 [CONTRIBUTING.md](../CONTRIBUTING.md)。

---

# 测试

## 跑测试

```bash
# ★ 规模取数：find test -name "*.dart" | wc -l / find rust/sourin_core -name "*.rs" | wc -l
# Dart 侧（约 374 个文件 / 约 14 万行）
flutter test

# Rust 侧（src 约 29 个 + tests 约 35 个文件 / 合计约 52 千行）
cd rust/sourin_core && cargo test
```

## 关于 native-media 标签

有一批测试会调 `MediaKit.ensureInitialized()`（真加载 libmpv）。
libmpv 在 `flutter_tester` 里**偶发原生崩溃**（第三方库的问题，改不了源码），
所以它们在 `dart_test.yaml` 里被标记为**默认跳过**。

要跑它们：

```bash
flutter test --run-skipped --tags native-media --concurrency=1
```

> ⚠️ `--concurrency=1` **不能**完全避免崩溃（实测串行 8 次里也红 5 次）。
> 它只是让输出更易读。

## 测试纪律

这个项目的测试有两个不寻常的要求，写在多处测试的文件头：

```text
① ★ 判据必须能测出**反面**
   一条永远为真的断言比没有断言更危险。所以关键测试都配「红度证明」：
   把修复代码改回缺陷写法，断言**必须**变红。测不出反面的结论作废。

② ★ 区分「测试环境错」和「产品 bug」
   同一条断言失败时，先问「是我的仪器错了吗」。
   本项目因此推翻过两次自己的根因（都记在对应测试的文件头）。
```
