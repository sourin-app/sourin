// ═══════════════════════════════════════════════════════════════════════
//  T-CACHE ③：**真的接线了**（防"写了没调用"）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么必须单独有这一条（本仓 ⑥ 规矩一）
//
// ```text
// DiskCache 单测全绿 ⇏ 首页真的用了它。
// 典型假绿：我把 disk_cache.dart 写得很对、测得很全，
//   但 home_page 里**一行都没调** ⇒ 用户重启后照样冷加载，
//   而所有门禁都是绿的。
// ```
// ⇒ 本文件**读真实源码文本**，钉住三处接线点：
// ```text
// ① shell.dart   ：DiskCache.init(dir) + homeListCache.preload()
// ② home_page.dart：put() 落盘 + preload() 真读目录
// ③ my_shelf.dart ：initState 预热 + load 成功后写盘
// ```
//
// ⚠️ 判据是"剥掉注释后的真实代码"（本仓 t1014 同款做法）——
//    否则注释里写一句 "DiskCache.init" 就能骗过门禁（假绿）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 剥掉 // 行注释与 /* */ 块注释
///
/// ⚠️ 必须剥：本项目的注释里大量引用代码片段（如 "调 DiskCache.init"），
///    不剥的话门禁会被注释骗过 —— 那正是假绿。
String stripComments(String s) {
  var out = s.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  out = out.replaceAll(RegExp(r'//[^\n]*'), '');
  return out;
}

String readCode(String rel) => stripComments(File(rel).readAsStringSync());

void main() {
  group('① shell.dart：注入数据目录 + 启动预热', () {
    test('★★★ 真的调了 DiskCache.init（否则缓存写不到正确目录）', () {
      final c = readCode('lib/shell.dart');
      expect(c.contains('DiskCache.init('), isTrue,
          reason: '★★ 不 init ⇒ DiskCache 不知道数据目录 ⇒ 读写全空操作，'
              '而单测仍然全绿（典型假绿）');
    });

    test('★★★ init 传的是 _resolveDataDir 的结果（保证 DATA_DIR_OVERRIDE 生效）', () {
      final c = readCode('lib/shell.dart');
      expect(c.contains('DiskCache.init(dir)'), isTrue,
          reason: '★ 必须用那个 dir 变量（它 = _resolveDataDir() 的返回值）——'
              '写死别的路径会让探针跑进用户真实数据目录');
    });

    test('★★★ 真的 await 了 preload（首帧命中靠它）', () {
      final c = readCode('lib/shell.dart');
      expect(c.contains('await homeListCache.preload()'), isTrue,
          reason: '★★ preload 不 await ⇒ 首帧时缓存还没进内存 ⇒ 照样骨架，'
              '等于整个需求没做');
    });

    test('★ 预热失败不影响启动（必须有 try/catch）', () {
      final c = readCode('lib/shell.dart');
      final i = c.indexOf('homeListCache.preload()');
      expect(i, greaterThan(0));
      // 往前后各取一段，确认在 try 里
      final around = c.substring(i - 200 < 0 ? 0 : i - 200, i + 200);
      expect(around.contains('try'), isTrue,
          reason: '★ 缓存是纯优化 —— 它失败绝不能让应用起不来');
    });
  });

  group('② home_page.dart：写穿 + 真读目录', () {
    test('★★★ HomeListCache.put 里真的落了盘', () {
      final c = readCode('lib/ui/home_page.dart');
      final i = c.indexOf('void put(String provider, HomeSnapshot s)');
      expect(i, greaterThan(0), reason: 'put 还在（重构掉了？）');
      final body = c.substring(i, i + 600);
      /*
       * ⚠️ put 里调的是 `_persist(...)`，而 `_persist` 才调 DiskCache.write。
       *    ★ 我第一版直接断言 put 里出现 'DiskCache.write(' ⇒ **假红**：
       *      断言比实现更具体了。这里改成断言**这条链真的接上**：
       *      put → _persist → DiskCache.write（三段都验，少一段就红）。
       */
      expect(body.contains('_persist(provider, s)'), isTrue,
          reason: '★★★ put 里必须调 _persist ⇒ 否则重启后缓存没了（正是 Owner 报的那件事）');
      final pi = c.indexOf('Future<void> _persist(String provider');
      expect(pi, greaterThan(0), reason: '_persist 必须存在');
      final pbody = c.substring(pi, pi + 300);
      expect(pbody.contains('DiskCache.write('), isTrue,
          reason: '★★★ _persist 必须真的落到 DiskCache.write（链条不能断）');
    });

    test('★★★ preload 真的读数据目录（不是空实现）', () {
      final c = readCode('lib/ui/home_page.dart');
      final i = c.indexOf('Future<int> preload()');
      expect(i, greaterThan(0), reason: 'preload 方法必须存在');
      final body = c.substring(i, i + 1600);
      expect(body.contains('DiskCache.dataDir'), isTrue,
          reason: '★ 得知道去哪个目录找');
      expect(body.contains('DiskCache.read('), isTrue,
          reason: '★★★ 必须真的读文件 —— 空实现也能"返回 0 条"而不报错');
      expect(body.contains('HomeSnapshot.fromJson('), isTrue,
          reason: '★ 读回来的 JSON 必须经 fromJson 还原成模型');
    });

    test('★★★ HomeSnapshot 有 toJson/fromJson 且 fromJson 复用现成的 fromJson', () {
      final c = readCode('lib/ui/home_page.dart');
      expect(c.contains('Map<String, dynamic> toJson()'), isTrue);
      expect(c.contains('static HomeSnapshot? fromJson('), isTrue);
      expect(c.contains('ProviderGroup.fromJson('), isTrue,
          reason: '★ 必须复用现成的解析 —— 另写一套必然与线上报文漂移');
      expect(c.contains('MediaItem.fromJson('), isTrue);
    });

    test('★★★ 文件名做了净化（provider id 来自插件，不能直接拼路径）', () {
      final c = readCode('lib/ui/home_page.dart');
      expect(c.contains('RegExp('), isTrue,
          reason: '★ 必须过滤掉路径分隔符等字符 —— 否则插件能控制写到哪里');
      final i = c.indexOf('_fileNameFor');
      final body = c.substring(i, i + 400);
      expect(body.contains('replaceAll'), isTrue,
          reason: '★ 净化必须真的做（replaceAll），不能只是有个函数名');
    });
  });

  group('③ my_shelf.dart：预热 + 写盘', () {
    /*
     * ★★★ 2026-10-15 修掉的一个**假绿门禁**（故障注入抓出来的）
     *
     * ```text
     * 第一版：initState 往后取 400 字符，断言里面含 '_preloadFromDisk()'
     * 故障注入：把 initState 里那行**调用**删掉
     *   ⇒ 门禁**仍然全绿**（！）
     * 原因：400 字符窗口**越过了 initState 的右花括号**，
     *       把下面方法的**定义** 'Future<void> _preloadFromDisk() async {'
       也圈进来了 —— 而它同样含 '_preloadFromDisk()' 这个子串。
     * ```
     * ⇒ 改成**只取 initState 的函数体**（按花括号配对切），
     *   并显式断言那个窗口里**不含** 'Future<void>'（定义不在里面）。
     */
    /// 取某个函数（含签名）的**函数体文本**（按花括号配对）
    String bodyOf(String code, String signature) {
      final i = code.indexOf(signature);
      expect(i, greaterThan(0), reason: '找不到函数: $signature');
      final open = code.indexOf('{', i);
      expect(open, greaterThan(0));
      var depth = 0;
      for (var k = open; k < code.length; k++) {
        final ch = code[k];
        if (ch == '{') depth++;
        if (ch == '}') {
          depth--;
          if (depth == 0) return code.substring(open, k + 1);
        }
      }
      fail('花括号不配对: $signature');
    }

    test('★★★ initState 里真的预热了（Owner：重启后还在）', () {
      final c = readCode('lib/ui/widgets/my_shelf.dart');
      final body = bodyOf(c, 'void initState()');
      expect(body.contains('_preloadFromDisk()'), isTrue,
          reason: '★★★ 不预热 ⇒ 上面那块"我的收藏"重启后照样转圈');
      expect(body.contains('Future<void>'), isFalse,
          reason: '★ 这个窗口必须**只含 initState 的函数体** ——'
              '含到别的方法定义就会让上面的断言变假绿（实测抓到过）');
      // 反向：preload 之后仍要照常 load()（预热不许把刷新吃掉）
      expect(body.contains('load()'), isTrue,
          reason: '★ 预热 ≠ 不刷新 —— 拉新那一步必须还在');
    });

    test('★★★ load() 成功之后真的写盘了', () {
      final c = readCode('lib/ui/widgets/my_shelf.dart');
      final body = bodyOf(c, 'Future<void> load() async');
      expect(body.contains('_persistToDisk()'), isTrue,
          reason: '★★ 不写盘 ⇒ 预热永远读不到东西（看起来"功能没生效"）');
    });

    test('★★★ _persistToDisk 真的调了 DiskCache.write', () {
      final c = readCode('lib/ui/widgets/my_shelf.dart');
      final i = c.indexOf('Future<void> _persistToDisk()');
      expect(i, greaterThan(0));
      final body = c.substring(i, i + 400);
      expect(body.contains('DiskCache.write('), isTrue);
      expect(body.contains('kShelfCacheFile'), isTrue);
    });

    test('★★★ 三份数据都序列化了（漏一份就是"重启后少一块"）', () {
      final c = readCode('lib/ui/widgets/my_shelf.dart');
      final i = c.indexOf('Future<void> _persistToDisk()');
      final body = c.substring(i, i + 500);
      for (final k in ['favorites', 'following', 'history']) {
        expect(body.contains("'$k'"), isTrue,
            reason: '★ $k 这一路没写进缓存');
      }
    });
  });

  group('④ 不设过期时间（Owner：不限制时间）', () {
    test('★★★ 生产默认 TTL = null（永不因时间作废）', () {
      final c = readCode('lib/ui/home_page.dart');
      expect(c.contains('const Duration? kHomeCacheTtl = null;'), isTrue,
          reason: '★★★ Owner：「不限制时间,可以启动后异步刷新替换」'
              '⇒ 改回具体时长前必须先问 Owner');
    });

    test('★★★ DiskCache 里**没有** TTL 判断（它只管存/取）', () {
      final c = readCode('lib/core/disk_cache.dart');
      expect(c.contains('ttl'), isFalse,
          reason: '★★ 磁盘缓存不设过期 —— 新鲜度由调用方按时间戳判'
              '（Owner：「切换源检测时间对比 然后再替换」）');
    });
  });
}