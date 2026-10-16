// ═══════════════════════════════════════════════════════════════════════
//  T-CACHE ②：DiskCache 落盘 → 读回（真文件，不是 mock）
// ═══════════════════════════════════════════════════════════════════════
//
// # 守的是什么
// ```text
// ① 写出去 → 读回来，data 与 at **逐字节相等**
// ② 坏文件（半个 JSON / 不是 JSON / 不是本类的信封）⇒ 返回 null，**不抛**
// ③ 版本不符 ⇒ 返回 null（格式改过就别拿旧文件硬解）
// ④ 数据目录未就绪 ⇒ 返回 null（应用还没 init 就有人读）
// ⑤ ★ **不因"存了多久"返回 null** —— Owner：「不限制时间」
// ⑥ 原子写：写完后**不留 .tmp 垃圾**
// ```
//
// ⚠️ 全程用真实临时目录（dart:io）—— 落盘这条路必须真跑，
//    否则就是"测了个 mock"（假绿）。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/disk_cache.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sourin-diskcache-test-');
    DiskCache.debugResetForTest(tmp.path);
  });

  tearDown(() async {
    DiskCache.debugResetForTest(null);
    try {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('① 落盘 → 读回', () {
    test('★★★ 写进去的数据与时间戳都能原样读回', () async {
      final at = DateTime(2026, 10, 15, 12, 0, 0);
      final payload = <String, Object?>{
        'provider': 'srca',
        'sections': [
          {'id': 's1', 'title': '热门', 'items': []},
        ],
      };
      final ok = await DiskCache.write('t1.json', payload, at: at);
      expect(ok, isTrue, reason: '★ 写必须真的成功（失败会静默降级，这里要显式抓）');

      final e = await DiskCache.read('t1.json');
      expect(e, isNotNull, reason: '★★ 写进去了就必须读得回来');
      expect(e!.at, at, reason: '★ at 要精确到毫秒地往返');
      expect(jsonEncode(e.data), jsonEncode(payload),
          reason: '★★★ 数据逐字节相等 —— 差一点就是"缓存读回来缺字段"');
    });

    test('★★ 不传 at ⇒ 用当前时间（且是合理的现在）', () async {
      final before = DateTime.now().subtract(const Duration(seconds: 2));
      await DiskCache.write('t2.json', {'x': 1});
      final e = await DiskCache.read('t2.json');
      expect(e, isNotNull);
      expect(e!.at.isAfter(before), isTrue);
      expect(e.at.isBefore(DateTime.now().add(const Duration(seconds: 2))), isTrue);
    });

    test('★★ 覆盖写：第二次写的内容完全顶掉第一次（不留旧尾巴）', () async {
      await DiskCache.write('t3.json', {'v': 'first', 'pad': 'x' * 500});
      await DiskCache.write('t3.json', {'v': 'second'});
      final e = await DiskCache.read('t3.json');
      expect(e, isNotNull);
      expect((e!.data as Map)['v'], 'second');
      expect((e.data as Map).containsKey('pad'), isFalse,
          reason: '★★ 原地覆盖写必须**截断** —— 否则旧内容会残留在尾巴上'
              '（本仓 download_queue 的原子替换专门记过这条）');
    });

    test('★ 写完之后**不留 .tmp 垃圾**（原子替换要真的搬走临时文件）', () async {
      await DiskCache.write('t4.json', {'x': 1});
      final names = await tmp.list().map((e) => e.path.split(Platform.pathSeparator).last).toList();
      expect(names.where((n) => n.endsWith('.tmp')), isEmpty,
          reason: '★ .tmp 残留会一直在用户数据目录里堆积');
    });
  });

  group('② 坏输入一律降级（绝不抛 —— 缓存是纯优化）', () {
    test('★★★ 文件不是 JSON ⇒ null，不抛', () async {
      await File('${tmp.path}${Platform.pathSeparator}bad.json')
          .writeAsString('这不是 JSON {{{');
      expect(await DiskCache.read('bad.json'), isNull);
    });

    test('★★★ 写到一半的半个 JSON ⇒ null，不抛', () async {
      final full = jsonEncode({'v': 1, 'at': 1, 'data': {'a': 1}});
      await File('${tmp.path}${Platform.pathSeparator}half.json')
          .writeAsString(full.substring(0, full.length ~/ 2));
      expect(await DiskCache.read('half.json'), isNull,
          reason: '★ 断电/崩溃留下的半截文件必须能降级');
    });

    test('★★ JSON 合法但不是本类的信封（缺 v / 缺 at）⇒ null', () async {
      await File('${tmp.path}${Platform.pathSeparator}other.json')
          .writeAsString(jsonEncode({'hello': 'world'}));
      expect(await DiskCache.read('other.json'), isNull);

      await File('${tmp.path}${Platform.pathSeparator}nov.json')
          .writeAsString(jsonEncode({'at': 1, 'data': {}}));
      expect(await DiskCache.read('nov.json'), isNull);

      await File('${tmp.path}${Platform.pathSeparator}noat.json')
          .writeAsString(jsonEncode({'v': kDiskCacheVersion, 'data': {}}));
      expect(await DiskCache.read('noat.json'), isNull);
    });

    test('★★★ 版本不符 ⇒ null（格式改过就别硬解旧文件）', () async {
      await File('${tmp.path}${Platform.pathSeparator}oldver.json').writeAsString(
        jsonEncode({'v': kDiskCacheVersion + 99, 'at': 1, 'data': {'x': 1}}),
      );
      expect(await DiskCache.read('oldver.json'), isNull);
    });

    test('★★ 文件不存在 ⇒ null（第一次跑的正常情形）', () async {
      expect(await DiskCache.read('nope.json'), isNull);
    });

    test('★★★ 数据目录未就绪 ⇒ 读写都安全返回（不抛）', () async {
      DiskCache.debugResetForTest(null);
      expect(DiskCache.ready, isFalse);
      expect(await DiskCache.read('x.json'), isNull);
      expect(await DiskCache.write('x.json', {'a': 1}), isFalse,
          reason: '★ 没 init 就写 ⇒ 返回 false（而不是抛到调用方脸上）');
    });
  });

  group('③ 不限制时间（Owner 明确要求）', () {
    test('★★★ 存了 30 天照样读得回来 —— 绝不因"太老"作废', () async {
      final ancient = DateTime.now().subtract(const Duration(days: 30));
      await DiskCache.write('old.json', {'keep': 'me'}, at: ancient);
      final e = await DiskCache.read('old.json');
      expect(e, isNotNull,
          reason: '★★★ Owner：「不限制时间,可以启动后异步刷新替换」'
              '⇒ 旧数据也要先画出来，由后台刷新替换，而不是当没有');
      /*
       * ⚠️ 时间戳只精确到**毫秒**（存的是 millisecondsSinceEpoch）——
       *    所以不能直接比 DateTime 相等（微秒部分会丢）。
       *    ★ 这是我第一版写错的地方：断言比真实精度更严 ⇒ 假红。
       */
      expect(e!.at.millisecondsSinceEpoch, ancient.millisecondsSinceEpoch);
      expect(e.ageFrom(DateTime.now()).inDays, greaterThanOrEqualTo(29));
    });
  });

  group('④ 删除', () {
    test('★ remove 之后读不到，且不抛', () async {
      await DiskCache.write('d.json', {'x': 1});
      expect(await DiskCache.read('d.json'), isNotNull);
      await DiskCache.remove('d.json');
      expect(await DiskCache.read('d.json'), isNull);
      await DiskCache.remove('d.json'); // 再删一次不该抛
    });
  });

  group('⑤ 并发写（实机抓到的真缺陷，2026-10-15）', () {
    test('★★ 同一份缓存并发写：每一笔都必须成功，且盘上留下完整 JSON', () async {
      /*
       * # 这个缺陷是实机跑出来的，不是想出来的
       *
       * 真机上日志出现：
       *   [DISK-CACHE] shelf-cache.json 写入彻底失败:
       *     rename=PathNotFoundException ... errno = 2
       *     fallback=PathNotFoundException ... errno = 2
       *
       * # 根因
       *     改前每一笔写都用**同一个**固定临时名 '<target>.tmp'：
       *       writer A: 写 tmp  -> 创建
       *       writer B: 写 tmp  -> 覆盖同一个路径
       *       writer A: rename  -> 成功（tmp 被消费掉）
       *       writer B: rename  -> errno 2（tmp 没了）
       *       writer B: 兜底读 -> 也是 errno 2
       *     ⇒ B 那份快照**静默丢失**，而且日志说"彻底失败"。
       *
       * 并发是真会发生的：MyShelf.load() 在 Future.wait 之后落盘，
       * 而 load() 可以被触发不止一次。
       *
       * # 判据
       *     并发写 N 笔 ⇒ **每一笔都返回 true**（不许静默丢数据），
       *     且最终盘上是一份**完整可解析**的 JSON，
       *     且不留下任何 .tmp 垃圾。
       */
      const n = 12;
      final results = await Future.wait(<Future<bool>>[
        for (var i = 0; i < n; i++) DiskCache.write('race.json', {'who': i}),
      ]);
      expect(results.where((r) => r).length, n,
          reason: '★ 并发写每一笔都必须成功 —— 任何一笔 false 都是静默丢数据');

      final e = await DiskCache.read('race.json');
      expect(e, isNotNull, reason: '最终盘上必须是一份完整可解析的信封');
      expect(e!.data, isA<Map>(), reason: '内容必须完整（不是半个 JSON）');

      // 不留临时文件垃圾
      final leftovers = tmp
          .listSync()
          .where((x) => x.path.endsWith('.tmp'))
          .toList();
      expect(leftovers, isEmpty,
          reason: '★ 并发写之后不许在数据目录留 .tmp 垃圾');
    });
  });
}