// ══════════════════════════════════════════════════════════════════════
//  第 19 项 · TVBox 聚合（`tvbox_agg`）：**Dart 侧 id 契约**门禁
// ══════════════════════════════════════════════════════════════════════
//
// # 这条门禁守的是什么（先读这段，否则会以为它测错了层）
// ```text
// 「聚合条目点击后路由到子 provider」这条**路由逻辑在 Rust**
//   （`rust/sourin_core/src/tvbox_aggregate.rs:473-495`：`native.split_once("::")`
//    ⇒ 取子站 id ⇒ `registry.get(cid)`；缺前缀时给可读错误）。
// Dart **不含**路由逻辑，也不该含。Dart 侧唯一要守的契约是：
//   ★ **不许改写 id** —— 聚合条目的 id 形如
//        `tvbox_agg:<子站id>::<子站原生id>`
//     其中 `::` 是**双层**分隔，Dart 任何一层（`MediaItem.fromJson` /
//     `MediaDetail.fromJson` / `getDetail` 的入参）都不许把它切掉、截断、重拼。
//   一旦 Dart 把 id 规整成 `tvbox_agg:<最后一段>` 或做 `split(':').last`，
//   Rust 那边就会报"聚合条目的 id 缺少子站前缀"，用户看到的是
//   **每一条聚合内容都打不开**。
//
// 为什么这个风险是真实的（不是假想）：
//   `MediaId::parse`（`model.rs:62-68`）只按**第一个冒号**切
//   ⇒ `tvbox_agg:sub1::123` ⇒ provider=`tvbox_agg`、native=`sub1::123`（`::` 留着）。
//   任何"顺手清洗 id"的 Dart 代码都会破坏这个不变量。
// ```
//
// # 三条判据 + 各自的注入（档位按第 40 轮口径标注）
// ```text
// ① 聚合条目 JSON ⇒ MediaItem.id **逐字保留**，且首冒号切分后
//    provider == 'tvbox_agg'、native 仍带 `<子站>::` 前缀 ...... 产品注入红
// ② MediaDetail 同理（详情回来时 id 也不许被改写） ...... 产品注入红
// ③ 缺前缀的错误体（Rust 原文）⇒ Dart 抛**可读** SourinCoreException，
//    消息里带「缺少子站前缀」，不是崩溃、不是静默 ...... 样本级自检
// ```
//
// 跑法（不带 tag，进默认全量）
// ```powershell
// flutter test test/zz_t1050_tvbox_agg_id_contract_test.dart --concurrency=1
// ```

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/ffi.dart' show SourinCore, SourinCoreException;
import 'package:sourin_spike/core/models.dart';

/// 真实形态（`tvbox_aggregate.rs:302-307` 的 `wrap_item`）：
/// `id.provider = 'tvbox_agg'`、`id.native = '<子站id>::<子站原生id>'`
/// ⇒ 序列化成字符串就是下面这个（`model.rs:70-72` 的 `as_key`）。
const String kAggId = 'tvbox_agg:sub1::3862';

/// 与 Rust `MediaId::parse` 同一条规则：**只按第一个冒号**切
({String provider, String native}) splitKey(String key) {
  final i = key.indexOf(':');
  expect(i, greaterThan(0), reason: 'id 里必须至少有一个冒号：$key');
  return (provider: key.substring(0, i), native: key.substring(i + 1));
}

void main() {
  group('① 聚合条目：id 逐字保留 + 首冒号切分后仍带子站前缀', () {
    test('MediaItem.fromJson 不许改写 id', () {
      final it = MediaItem.fromJson(<String, dynamic>{
        'id': kAggId,
        'title': '某部剧',
        'provider': 'tvbox_agg',
      });

      expect(it.id, kAggId,
          reason: '★★★ 聚合条目的 id 必须**逐字**保留（任何清洗都会让 Rust 侧'
              '报"缺少子站前缀"，等于每条聚合内容都打不开）');

      final parts = splitKey(it.id);
      expect(parts.provider, 'tvbox_agg',
          reason: '★★ 首冒号左边必须是聚合 provider 本身');
      expect(parts.native.contains('::'), isTrue,
          reason: '★★★ native 必须**仍带 `<子站id>::` 双层前缀**（实际 '
              '${parts.native}）—— 被切掉就等于不知道路由回哪个子站');
      expect(parts.native, 'sub1::3862',
          reason: '★ 精确到子站 id + 原始 native');

      // 反面：最常见的"顺手清洗"写法必须被这条判据否掉
      expect(it.id.split(':').last, isNot(parts.native),
          reason: '说明：`split(":").last` 会得到 `3862`（丢掉 sub1::）—— '
              '这正是本门禁要挡住的形态');
      // ignore: avoid_print
      print('AGG_ID|item|id=$kAggId|provider=${parts.provider}|'
          'native=${parts.native}');
    });
  });

  group('② 聚合详情：回落时 id 同样不许被改写', () {
    test('MediaDetail.fromJson 不许改写 id', () {
      final d = MediaDetail.fromJson(<String, dynamic>{
        'id': kAggId,
        'title': '某部剧',
        'episodes': <dynamic>[],
      });
      expect(d.id, kAggId,
          reason: '★★★ 详情返回的 id 与列表条目必须是同一个 key '
              '（否则"点进去"与"收藏/进度"会对不上）');
      final parts = splitKey(d.id);
      expect(parts.provider, 'tvbox_agg');
      expect(parts.native, 'sub1::3862');
      // ignore: avoid_print
      print('AGG_ID|detail|id=${d.id}|native=${parts.native}');
    });
  });

  group('③ 缺前缀的错误体 ⇒ 可读异常（不是崩溃、不是静默）', () {
    testWidgets('喂 Rust 原文错误 ⇒ SourinCoreException 里带「缺少子站前缀」',
        (t) async {
      /*
       * 这条走的是**真实的完成路径**：
       *   debugOpenPendingCall ⇒ 建表项
       *   debugFeedNativeResult ⇒ `_deliverResult` ⇒ `{"error":…}` 分支
       *     ⇒ `completer.completeError(SourinCoreException(...))`
       * 与 `_onNativeResult` 是同一条路径（后者只多一步从 Rust 内存读字符串）。
       *
       * ⚠️ 档位：**样本级自检**（在测试内喂错误体），不是产品注入 ——
       *    产品侧的这句错误文案在 Rust（`tvbox_aggregate.rs:282-286`），
       *    本任务不许改 Rust，所以这里只能钉"Dart 会不会把它原样抛出来"。
       */
      final id = SourinCore.debugOpenPendingCall('get_detail');
      final fut = SourinCore.debugPendingFuture(id);
      expect(fut, isNotNull, reason: '前置：表项要建起来');

      SourinCore.debugFeedNativeResult(
        id,
        '{"error":"聚合条目的 id 缺少子站前缀（应为 <子站id>::<原始id>）：3862",'
        '"kind":"other"}',
      );

      final err = await fut!.then<Object?>((v) => v, onError: (Object e) => e);
      expect(err, isA<SourinCoreException>(),
          reason: '★ 错误体必须变成 SourinCoreException（不是裸 Map、不是崩溃）');
      final msg = (err as SourinCoreException).message;
      expect(msg.contains('缺少子站前缀'), isTrue,
          reason: '★★ 必须**原样透出** Rust 的可读文案（实际：$msg）—— '
              '用户要看到"缺子站前缀"，而不是"未知错误"');
      expect(msg.contains('<子站id>::<原始id>'), isTrue,
          reason: '★ 文案里要带**正确形态**，用户/维护者才知道该长什么样');
      // ignore: avoid_print
      print('AGG_ERR|kind=${err.kind}|msg=$msg');
    });

    testWidgets('样本级自检的反向：错误体换成"未知错误" ⇒ 上面那条必须红',
        (t) async {
      final id = SourinCore.debugOpenPendingCall('get_detail');
      final fut = SourinCore.debugPendingFuture(id);
      SourinCore.debugFeedNativeResult(
          id, '{"error":"未知错误","kind":"other"}');
      final err = await fut!.then<Object?>((v) => v, onError: (Object e) => e);
      final msg = (err as SourinCoreException).message;
      // 这条断言是**故意反着写**的：证明"文案里有没有『缺少子站前缀』"
      // 这件事真的有判别力（不是恒真）。
      expect(msg.contains('缺少子站前缀'), isFalse,
          reason: '★★ 若这条红了，说明上面 ③ 的判据恒真（假的）');
      // ignore: avoid_print
      print('AGG_ERR|negative|msg=$msg');
    });
  });
}
