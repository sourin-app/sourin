# 测试临时目录清理：Windows「文件被占用」的系统性风险

**日期**：2026-10-17 · **来源**：PR #30 CI 取证

---

## 现场（CI Windows 全量测试，原样）

```text
❌ test/zz_cr_dl_c13_local_episode_id_test.dart
   ★★ CR-13：点「已下载」的第03集 CR13…

PathAccessException: Deletion failed,
  path = 'C:\Users\RUNNER~1\AppData\Local\Temp\cr_dl_c13\logs'
  (OS Error: The process cannot access the file because it is being used by another process,
   errno = 32)
```

★ 注意：**不是断言失败**，是**清理临时目录时删不掉**。
本机 5/5 跑不出来 —— 占用与否取决于那个进程/时序窗口。

---

## 机制

```text
① 测试把 <dataDir> 指向临时目录
   （ClipDownloader.debugSetDataDir / CachePage.debugScanRootOverride）
② AppLog（lib/core/app_log.dart:189）往 <dataDir>/logs/ 写日志
   它用 writeAsString(mode: append, flush: false) —— 每次写自己开关句柄，
   所以它【不长期持有】句柄。
③ ★ 真正的因果（CodeRabbit CR 纠正了我第一版的错说法）：
   `AppLog.write` 与那个批量定时器都通过 `unawaited(...)` **异步**发起写入，
   `_flushBuffer` 把 `writeAsString` 的 Future 存进 `_pending`；
   而**测试清理前没有 await 那个 Future**。
   ⇒ `deleteSync` 执行时，写入**可能尚未完成** —— 该目录正被那个在途写入持有。
④ 测试收尾 deleteSync(recursive: true) 删整个 <dataDir>
⑤ Windows 不允许删除被占用的目录 ⇒ errno 32
   （Linux/macOS 允许 unlink 正在使用的文件 ⇒ 只有 Windows 会这样）

⚠️ **不要**据此推断"文件句柄一直开着"或"flush: false 导致句柄泄漏"：
   `writeAsString(..., flush: false)` **每次写自己开关句柄**，
   `AppLog` 并不长期持有句柄。问题出在**异步写入与删除之间的竞态**，
   不是句柄泄漏。
```

---

## 已修

`test/zz_cr_dl_c13_local_episode_id_test.dart`（commit `988f6a2`）：

```dart
try {
  e.deleteSync(recursive: true);
} on PathAccessException catch (err) {
  // ★ 必须看**错误码**，不能无条件吞（CodeRabbit CR）：
  //   只有 32 = ERROR_SHARING_VIOLATION（被占用）才容忍；
  //   errno 2（找不到）、5（拒绝访问）等**都是真错误，必须炸出来**。
  if (err.osError?.errorCode != 32) rethrow;
} on FileSystemException catch (err) {
  if (err.osError?.errorCode != 32) rethrow;
}
```

**验证**（catch 语义逐例真跑）：
```text
① PathAccessException errno 32（CI 原样）⇒ 被吞 ✓
② FileSystemException  errno 32          ⇒ 被吞 ✓
③ PathAccessException errno 5（拒绝访问）⇒ **rethrow** ✓
④ PathAccessException errno 2（找不到）  ⇒ **rethrow** ✓

实测读数：
```text
PROBE swallowed=2 rethrow5=true rethrow2=true
```
```
★ ③ 是关键：证明这不是「遇到删除失败就静默放过」。

---

## 尚未处理的系统性风险：19 个同类测试

扫描 `deleteSync(recursive: true)` ⇒ **53 个**测试文件用了这个模式，
其中 **0 个**有 try/catch 包裹。

进一步筛「会把 <dataDir> 指向临时目录」（即真会触发 AppLog 写 logs）：**19 个**，
例如：

```text
test/t101_cache_limit_test.dart
test/t26_w5_cache_cover_width_test.dart
test/t27_w1_online_first_test.dart
test/t27_w4_local_fav_play_test.dart
test/task18_clip_concurrency_test.dart
test/task18_entry_test.dart
test/zz_cr_cache_owner1009_test.dart
test/zz_cr_dl_c13_local_episode_id_test.dart   ← 已修
test/zz_media_r1_local_open_probe_test.dart
test/zz_t12_cache_page_probe_test.dart
test/zz_t12_defect_a_probe_test.dart
test/zz_t3_19_cache_page_probe_test.dart
（完整 19 个清单见 PR #30 对话）
```

⇒ 这 18 个**理论上会以同样方式偶发红**，只是 CI 还没咬到。

### 建议的下一步（未做）

1. **提到公共 helper**（推荐）：
   `test/support/temp_dir.dart`：
   `void deleteTempTree(Directory root)` —— 一处实现、19 处调用。
2. 或逐个加同样的 try/catch（18 处重复）。

⚠️ **本 PR 里没有贸然批量改**：这 18 个文件不属于本 PR 改动范围，
   在没有 CI 证据时批量改等于用猜测换风险。
   建议等它们真的在 CI 上红了再按 helper 收敛，或单开 PR。

---

## 附：为什么本机复现不出来

我试过三种办法在本机造 errno 32，**都失败**：
```text
① 同进程内 openSync 持有句柄再删 ⇒ Windows 允许（同进程不构成占用）
② Process.start + powershell [System.IO.File]::Open 抓句柄
   ⇒ 引号转义在这个环境不可靠，子进程没真抓住
③ 直接构造 PathAccessException 验证 catch 语义 ⇒ ✅ 成功
```
⇒ 最终采用 ③：不复现环境，而是**直接验证 catch 子句对 CI 那种异常的行为**。

## 一条 API 事实（写 probe 时被编译器纠正）

```dart
PathAccessException(String path, OSError osError, [String message = ""])
//                  ^^^^ 位置参数，不是具名参数
```