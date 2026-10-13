// ///////////////////////////////////////////////////////////////////////////
//  OPS-13 反馈 C：续播进度「来源身份」—— 纯判据（不挂页面、不碰 FFI）
// ///////////////////////////////////////////////////////////////////////////
//
// # Owner 原话（逐字）
//
// > 续播进度,我希望的是我缓存这集了,但是如果我在线看,他还能记得我看过
// > 而不是 本地和线上的就彻底分开了,你懂不
//
// # 本文件钉住什么
//
// `lib/core/progress_origin.dart` 是「统一键」的**唯一下拉点**。它是纯函数，
// 所以这里全部是**行为断言**（不是「看源码里有没有那行字」）。
//
// # ★ 为什么单列一个文件（而不是塞进挂页面的那个）
//
// 挂 `MediaPage`/`PlayerPage` 的用例需要 media_kit / 真 dll 才能真跑；
// 而这一批判据**零依赖** —— 任何机器上都必须能跑、必须能红。
// 混在一起的话，环境一跳过就把纯判据一起跳掉了。
//
// # ★ 环境探针那条为什么在最后
//
// `flutter_tester` 能不能加载 `sourin_core.dll` 决定「端到端」那两条
// （`zz_ops13_mirror_write_test.dart` / `zz_ops13_resume_read_test.dart`）
// 是真跑还是如实跳过。这里先量出来并**如实打印**，
// 免得后面那两条悄悄变成假绿。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/models.dart' show Progress;
import 'package:sourin_spike/core/progress_origin.dart';
import 'package:sourin_spike/ui/cache_page.dart' show kLocalProvider;

String _src(String rel) => File(rel).readAsStringSync();

/// 剥掉行注释与块注释（判据对象是**代码**时必做）
///
/// ⚠️ 本仓大量长注释里**引用**了被删掉的旧代码 —— 只做 `contains`
///    会让「旧代码还在」这类断言**假绿**（`t67_repoint_test.dart` 同款说明）。
///
/// # ★★★ 块注释必须**行首锚定**（这是实测踩出来的坑，不是洁癖）
///
/// 不锚定的话，**行注释里的 glob** 会被当成块注释开头：
/// ```text
/// //   拼键只有一处 = Rust（不 import `lib/ui/**`）
///                                 ↑ 这个 `/*` 让 `/*…*/` 一路吞到下一个 `*/`
/// ```
/// 实测：本文件的行注释里写了 `lib/core/**` / `lib/ui/**` ⇒
///   `lib/core/progress_origin.dart` 被吞掉 **13215 字符**（19435 → 6220），
///   连 `String canonicalProgressKey(` 那行签名都被删掉 ⇒
///   测试报 `Expected: a value greater than <-1> / Actual: <-1>`。
///
/// 本仓块注释**一律独占整行**（本文件与 `progress_origin.dart` 都如此），
/// 所以 `^[ \t]*/\* … \*/[ \t]*$` 这个锚定**不丢**任何真注释。
String _stripComments(String src) {
  final noBlock = src.replaceAll(
      RegExp(r'^[ \t]*/\*[\s\S]*?\*/[ \t]*$', multiLine: true), ' ');
  return noBlock
      .split('\n')
      .map((l) {
        final i = l.indexOf('//');
        return i >= 0 ? l.substring(0, i) : l;
      })
      .join('\n');
}

/// 切出某个声明的**声明体**（块体 `{ … }` 或表达式体 `=> …;` 都行）
///
/// ★ 与 `test/t67_repoint_test.dart:200 rustFnBody()` 是**同一个手法**：
///   从签名起找 `{`，数大括号到配平 —— 不依赖任何魔数。
///   不精确切的话，断言会命中**后面另一个声明**里的同名符号（本仓踩过）。
///
/// ⚠️ 表达式体没有大括号（`canonicalProgressKey` 就是），此时切到
///    其后的**第一个 `;`**。这个简化对「表达式里没有分号字面量」成立 ——
///    本函数就是这种形状；若哪天改成块体，走的是上面那条配平分支。
String _fnBodyOf(String src, String signature) {
  /*
   * ★★ 先**在原文上**找签名、切体，最后才剥注释（顺序不能反）：
   * ```text
   * ① 先剥再找：剥注释会**删掉行**，签名行可能一起没了（本文件踩过，
   *    见 `_stripComments` 的说明）—— 那时 `indexOf` = -1，报错信息还
   *    完全指不到真因
   * ② 切完再剥：注释里的**旧代码**不会造成假绿，因为断言只看切出来的那段
   * ```
   */
  final at = src.indexOf(signature);
  expect(at, greaterThan(-1), reason: '★ 找不到 `$signature`');
  final open = src.indexOf('{', at);
  final arrow = src.indexOf('=>', at);
  final semi = src.indexOf(';', at);
  final isExprBody = arrow > -1 &&
      (open < 0 || arrow < open) &&
      (semi < 0 || arrow < semi);
  if (isExprBody) {
    expect(semi, greaterThan(arrow), reason: '表达式体必须以 `;` 结束');
    return _stripComments(src.substring(at, semi + 1));
  }
  expect(open, greaterThan(-1), reason: '`$signature` 后面必须有 `{`');
  var depth = 0;
  for (var i = open; i < src.length; i++) {
    if (src[i] == '{') depth++;
    if (src[i] == '}') {
      depth--;
      if (depth == 0) return _stripComments(src.substring(at, i + 1));
    }
  }
  fail('`$signature` 的大括号不配平');
}

/// 从一个 Dart 源串里抽出 `{ ... }` 里的字符串字面量集合
///
/// 用于把 core 与 ui 两份后缀表**逐字**比对（同一个源比同一个源的反面：
/// 这里是两个**不同**的源，正好能证伪「只改了一处」）。
Set<String> _extsOf(String src, String decl) {
  final i = src.indexOf(decl);
  if (i < 0) return const <String>{};
  final open = src.indexOf('{', i);
  final close = src.indexOf('}', open);
  if (open < 0 || close < 0) return const <String>{};
  final body = src.substring(open + 1, close);
  return RegExp("'([^']*)'")
      .allMatches(body)
      .map((m) => m.group(1)!)
      .toSet();
}

void main() {
  group('① 命名空间常量：只有一处定义这条铁律', () {
    test('★★★ kProgressLocalProvider 必须与 kLocalProvider 是同一个值', () {
      /*
       * # 为什么这条是硬判据
       *
       * `local` 这个字面量现在有两处：`lib/ui/cache_page.dart:787`（历史）
       * 与 `lib/core/progress_origin.dart`（本轮，因为 core 不许 import ui）。
       * 谁改了一处而没改另一处，本地进度的键就**静默**对不上了 ——
       * 不报错，只是永远查不到（Rust 侧注释原话：拼错不会报错，只会静默查不到）。
       */
      expect(
        kProgressLocalProvider,
        kLocalProvider,
        reason: '★★★ 两个常量必须同值 —— 否则本地进度键会静默错位',
      );
    });
  });

  group('② 键格式：与 Rust progress_key 同构（两边一起钉）', () {
    test('★★★ 键 = "provider:mediaId:episodeId"，与 Rust 的 format! 逐字同构', () {
      /*
       * ★★★ 2026-10-12：主键由「按作品」扩成「**按集**」。
       *   老：`provider:mediaId`（一个作品一行，换集就覆盖）
       *   新：`provider:mediaId:episodeId`（每集一行；null ⇒ 空串哨兵）
       */
      expect(canonicalProgressKey('bilibili', 'BV1xx411c7mD', '51463'),
          'bilibili:BV1xx411c7mD:51463');
      expect(canonicalProgressKey('dandanplay', '36578', '3'), 'dandanplay:36578:3');
      /*
       * ★ episodeId 为 null ⇒ **空串哨兵**（不能留 null：SQLite 唯一约束
       *   允许重复 NULL ⇒ 同一单片会被插成多行）。
       */
      expect(
        canonicalProgressKey('bilibili', 'BV1xx411c7mD', null),
        'bilibili:BV1xx411c7mD:',
        reason: '★ episodeId 为 null 时用空串哨兵，而不是省掉那一段',
      );
      expect(canonicalProgressKey('dandanplay', '36578'), 'dandanplay:36578:',
          reason: '★ 不传 episodeId 等价于传 null ⇒ 空串哨兵');
      /*
       * ★ 本地键：绝对路径里既有 `:`（盘符）又有 `/`，**不做任何转义**。
       *   转义的话就与 Rust 那条键不一致了 —— 而 Rust 是唯一拼键的地方。
       */
      expect(canonicalProgressKey('local', 'D:/源影/第01集.mp4', '第01集.mp4'),
          'local:D:/源影/第01集.mp4:第01集.mp4');
      /*
       * ★★★ 空白**不 trim**（2026-10-13 翻转：以前这里断言 `' 3 '` ⇒ `'bilibili:BV1:3'`）
       *
       * # 为什么翻（CodeRabbit 在 PR #18 / #21 / #23 / #24 上各点了一次）
       * ```text
       * 老口径：两端都 trim
       *   Rust   `episode_id.map(str::trim)`  按 char::is_whitespace 去**所有 Unicode 空白**
       *   SQLite `TRIM(x)`                    默认**只去半角空格**
       *   ⇒ 这两套规则**永远追不平** —— 补字符集也只是把不等价的地方推远一点
       * ```
       * 真正的不变量不是「都 trim」，而是「**两端逐字同构**」，
       * 而 trim 恰好做不到这一点。最终裁决：
       *
       * ```text
       * NULL ⇒ 空串，其余**原样**
       *   （与 `Db::migrate` 的 `COALESCE(episode_id,'')` 逐字一致）
       * ```
       *
       * 回归锁在 Rust 侧：`store::tests::progress_migration_rewrites_key_and_preserves_data`
       * 的 `padded.key == "cycani:3613: ep1 "` —— 带空白的 episode_id 必须**原样**进键。
       * 若哪天有人把 trim 加回任一侧，那条 Rust 用例先红。
       */
      expect(
        canonicalProgressKey('bilibili', 'BV1', ' 3 '),
        'bilibili:BV1: 3 ',
        reason: '★★ episodeId 前后空白**原样进键**（不 trim）—— '
            'Rust 的 progress_key 现在是 `episode_id.unwrap_or("")`，'
            'Dart 若 trim 就拼出 `...:3` ⇒ 同一集裂成两条记录',
      );
      expect(
        canonicalProgressKey('bilibili', 'BV1', '   '),
        'bilibili:BV1:   ',
        reason: '★ 全是空白也**不**折叠成空串哨兵 —— 原样进键，'
            "否则与 Rust 的 COALESCE(episode_id,'') 不同构",
      );
    });

    test('★★★ 两端格式契约（源码扫描）：Rust 与 Dart 的拼法必须一致', () {
      final rust = _src('rust/sourin_core/src/store.rs');
      /*
       * ★★ 同样收进**函数体内**：`str::trim` 只出现在 `progress_key` 的
       *    文档注释里（作为「以前是这样」的反例）—— 对整文件 contains
       *    永远命中 ⇒ 真把 trim 加回代码也照样绿。
       */
      final rustBody = _fnBodyOf(rust, 'pub(crate) fn progress_key(');
      expect(rustBody.contains('format!("{provider}:{native_id}:{ep}")'), isTrue,
          reason: '★ Rust 侧的 progress_key 变了 —— Dart 侧必须同步（它是唯一拼键点）');
      expect(rustBody.contains('episode_id.unwrap_or("")'), isTrue,
          reason: '★ Rust 侧必须是「NULL ⇒ 空串」这一条规则');
      expect(rustBody.contains('str::trim'), isFalse,
          reason: '★★ progress_key 体内不许出现 str::trim —— 见 Dart 侧的同款理由');
      final dart = _src('lib/core/progress_origin.dart');
      /*
       * ★★ 断言必须落在**声明体内**，且先剥注释 —— 少一条就假绿：
       * ```text
       * ① 不剥注释：本文件与 progress_origin.dart 的文档里**引用**了旧写法
       *    `?.trim()` 作为反例 ⇒ 只 contains 就永远绿
       * ② 不切体：命中文件里任何一处同名串 ⇒ 函数体改了也照样绿
       * ```
       * ⇒ `_fnBodyOf` 切体 + `_stripComments` 剥注释，两条一起才钉得住。
       */
      final body = _fnBodyOf(dart, 'String canonicalProgressKey(');
      expect(body.contains(r"${episodeId ?? ''}"), isTrue,
          reason: '★ Dart 侧的拼法必须是 provider + ":" + mediaId + ":" + '
              '(episodeId ?? "") —— ★★ **不许带 trim**：Rust 侧是 '
              '`episode_id.unwrap_or("")`（NULL ⇒ 空串，其余原样），'
              'Dart 若 trim 就不同构');
      expect(body.contains('.trim()'), isFalse,
          reason: '★★ 声明体里不许出现 `.trim()` —— 见上一条的理由');
    });
  });

  group('③ ProgressOrigin.of：不猜', () {
    test('★★★ 任一侧缺失/全空白 => null（宁可没有来源，也不要错的来源）', () {
      expect(ProgressOrigin.of(provider: null, mediaId: '36578'), isNull);
      expect(ProgressOrigin.of(provider: 'dandanplay', mediaId: null), isNull);
      expect(ProgressOrigin.of(provider: '', mediaId: '36578'), isNull);
      expect(ProgressOrigin.of(provider: 'dandanplay', mediaId: ''), isNull);
      expect(ProgressOrigin.of(provider: '   ', mediaId: '36578'), isNull);
      expect(ProgressOrigin.of(provider: 'dandanplay', mediaId: '  '), isNull);
    });

    test('★ 两侧都在 => 原样（首尾空白裁掉）', () {
      final o = ProgressOrigin.of(provider: ' bilibili ', mediaId: ' BV1 ');
      expect(o, isNotNull);
      expect(o!.provider, 'bilibili');
      expect(o.mediaId, 'BV1');
      expect(o, ProgressOrigin.of(provider: 'bilibili', mediaId: 'BV1'),
          reason: '★ 值相等 => == 成立（否则 `if (origin == ...)` 之类的判断会静默失效）');
    });
  });

  group('④ localProgressOrigin：从 CachedPlayRequest 的两个字段得到来源', () {
    test('★★★ 旁文件没来源 => null', () {
      expect(localProgressOrigin(originProvider: null, originMediaId: null),
          isNull);
      expect(localProgressOrigin(originProvider: '', originMediaId: ''), isNull);
    });

    test('★★★ 来源本身就是 local => null（镜像到 local 键 = 原地重写）', () {
      expect(
        localProgressOrigin(originProvider: 'local', originMediaId: 'D:/a.mp4'),
        isNull,
        reason: '★ 旁文件写 local 时不能拿它当"原来源" —— 那会写一条重复的 local 键',
      );
    });

    test('★ 真来源 => 原样透出', () {
      final o = localProgressOrigin(
          originProvider: 'bilibili', originMediaId: 'BV1xx411c7mD');
      expect(o!.provider, 'bilibili');
      expect(o.mediaId, 'BV1xx411c7mD');
    });
  });

  group('⑤ mirrorOriginFor：三条拒绝 + 一条放行', () {
    const origin = ProgressOrigin(provider: 'bilibili', mediaId: 'BV1');

    test('★★★ 没有来源 => 不镜像', () {
      expect(mirrorOriginFor(null, sessionProvider: 'local'), isNull);
    });

    test('★★★ 来源是 local => 不镜像', () {
      expect(
        mirrorOriginFor(
            const ProgressOrigin(provider: 'local', mediaId: 'D:/a.mp4'),
            sessionProvider: 'bilibili'),
        isNull,
      );
    });

    test('★★★ 来源 provider == 会话 provider => 不镜像（会覆盖会话自己那条）', () {
      /*
       * 这一条是**硬约束**，不是洁癖：镜像那条按设计**不带 episode_id**
       * （见 PlayerPage._saveProgress），一旦真打到会话自己的键上，
       * 就会把正常那条的 episode_id 抹成 NULL
       * => 续播的「按集校验」（player_page.dart:3390）失效
       * => 上一集的进度串到这一集。
       */
      expect(mirrorOriginFor(origin, sessionProvider: 'bilibili'), isNull);
    });

    test('★ 来源是别的站点 => 放行（本地会话的常规情形）', () {
      expect(mirrorOriginFor(origin, sessionProvider: 'local'), origin);
      expect(mirrorOriginFor(origin, sessionProvider: 'dandanplay'), origin);
    });
  });

  group('⑥ mirrorProgressTitle：标题优先，退到文件名时要去后缀', () {
    test('★★★ 有集标题 => 用它（不看文件名）', () {
      expect(
        mirrorProgressTitle(episodeTitle: '第03集', episodeFileName: '第03集 x.mp4'),
        '第03集',
      );
    });

    test('★★★ 没有集标题 => 文件名去后缀（本地会话手上只有文件名）', () {
      /*
       * 本地会话的 `episodeId` 是文件名（shell.dart:4830 传 `req.episode.fileName`），
       * 而 `CachedEpisode` 根本没有 `episodeTitle` 字段（cache_page.dart:134-156）
       * => 不剥后缀的话，播放记录里会出现「第01集.mp4」这种条目。
       */
      expect(
        mirrorProgressTitle(episodeTitle: '', episodeFileName: '第01集 CR13.mp4'),
        '第01集 CR13',
      );
      expect(
        mirrorProgressTitle(episodeTitle: '  ', episodeFileName: '正片.mkv'),
        '正片',
      );
      // `.part`（下载中的半截文件）也要剥
      expect(
        mirrorProgressTitle(episodeTitle: '', episodeFileName: '第02集.mp4.part'),
        '第02集',
      );
      // 没有后缀 => 原样
      expect(
        mirrorProgressTitle(episodeTitle: '', episodeFileName: '无后缀'),
        '无后缀',
      );
    });

    test('★★★ 两边都空 => null（不写镜像）', () {
      /*
       * ★ 不能退化成空串：Rust 的 upsert_progress 对空标题是「保留旧值」
       *   （store.rs:932-947 的 CASE WHEN excluded.title <> ''），
       *   写一条空标题只会白刷 updated_at，把「取更新的那条」判据带偏。
       */
      expect(mirrorProgressTitle(episodeTitle: '', episodeFileName: ''), isNull);
      expect(mirrorProgressTitle(episodeTitle: ' ', episodeFileName: '  '), isNull);
      expect(mirrorProgressTitle(episodeTitle: '', episodeFileName: '.mp4'), isNull);
    });
  });

  group('⑦ progressBelongsToCurrentEpisode：与 player_page.dart:3390 逐字等价', () {
    test('★★★ 四种组合', () {
      // ① 进度那条没有集信息（老数据 / 镜像那条）=> 放行
      expect(
        progressBelongsToCurrentEpisode(
            progressEpisodeId: null, currentEpisodeId: '51463'),
        isTrue,
        reason: '★ 镜像那条故意不带 episode_id —— 就是靠这里放行，否则永远续不上',
      );
      expect(
        progressBelongsToCurrentEpisode(
            progressEpisodeId: '', currentEpisodeId: '51463'),
        isTrue,
      );
      // ② 当前会话不知道自己是哪一集 => 放行（= :3390 的 curEpId != null 不成立）
      expect(
        progressBelongsToCurrentEpisode(
            progressEpisodeId: '51463', currentEpisodeId: null),
        isTrue,
      );
      // ③ 同一集 => 放行
      expect(
        progressBelongsToCurrentEpisode(
            progressEpisodeId: '51463', currentEpisodeId: '51463'),
        isTrue,
      );
      // ④ 不同集 => 拒绝（上一集的进度不能串到这一集）
      expect(
        progressBelongsToCurrentEpisode(
            progressEpisodeId: '51463', currentEpisodeId: '51464'),
        isFalse,
        reason: '★★ 这条拒绝必须还在 —— 否则看完第 3 集点开第 4 集会被 seek 到结尾',
      );
      expect(
        progressBelongsToCurrentEpisode(
            progressEpisodeId: '51463', currentEpisodeId: '第01集.mp4'),
        isFalse,
        reason: '★ 本地会话的"集号"是文件名 —— 站点集 id 与它**必然不等**',
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑨ OPS-13 反馈 C ②：pickResumeProgress —— **按位置单调合并**
  // ═══════════════════════════════════════════════════════════════════
  //
  // # 缺陷（本轮修的**概念性**错误）
  // ```text
  // 改前：return mirror.updatedAt > session.updatedAt ? mirror : session;
  // ⇒ 本地每 5 秒落盘 ⇒ 本地(新)恒赢 ⇒ 在线的 254s(旧) 被本地的 3s(新) 顶掉
  //   ⇒ 每次点进去都从第 3 秒重播（Owner 报的「每次都是重新播放」）。
  // ★ session 与 mirror 是**同一条进度的两个视图**，不是两个竞争的真源 ⇒
  //   判据应是「同一集里看到哪了」= 位置更靠后的那条；updatedAt 只破平局。
  // ```
  //
  // ⚠️ 现有测试（zz_ops13_resume_read_test 方向②）只覆盖「一侧为 null」与
  //    「两侧位置大小与时间戳**同向**」—— 恰恰漏了**反向**这一种，就是漏网的那条。
  group('⑨ pickResumeProgress：位置单调合并（治 ②）', () {
    Progress mk(int pos, int updatedAt, {String? epId}) => Progress(
          key: 'k',
          provider: 'p',
          nativeId: 'n',
          title: 't',
          episodeId: epId,
          position: pos,
          duration: 1800,
          updatedAt: updatedAt,
        );

    test('★★★ 本地 3s@新 vs 在线 254s@旧 ⇒ 取**在线 254s**（本轮的核心修复）',
        () {
      final session = mk(3, 2000); // 本地：新，但只看了 3 秒
      final mirror = mk(254, 1000); // 在线：旧，但看到 254 秒
      final picked = pickResumeProgress(session: session, mirror: mirror);
      expect(picked!.position, 254,
          reason: '★★★ 必须取**位置更靠后**的那条 —— '
              '按 updatedAt 选边会取到本地的 3s ⇒ 永远从头播');
    });

    test('★★★ 反向：本地 800s@新 vs 在线 100s@旧 ⇒ 取本地 800s', () {
      final picked = pickResumeProgress(
          session: mk(800, 2000), mirror: mk(100, 1000));
      expect(picked!.position, 800,
          reason: '★ 位置大者赢与「谁先谁后」无关 —— 这一条与上一条一起'
              '证明判据是「位置」而不是「时间戳」');
    });

    test('★★ 位置相等（都有效）⇒ 用 updatedAt 破平局（取更新的）', () {
      expect(
        pickResumeProgress(session: mk(254, 1000), mirror: mk(254, 2000))!
            .updatedAt,
        2000,
      );
      expect(
        pickResumeProgress(session: mk(254, 2000), mirror: mk(254, 1000))!
            .updatedAt,
        2000,
      );
    });

    test('★★ position=0 视为「没进度」⇒ 被对侧有效位置压过', () {
      expect(
        pickResumeProgress(session: mk(0, 9999), mirror: mk(120, 1))!.position,
        120,
        reason: '★ 0 秒 = 没进度（_prepareResume 也按 pos<=0 早退）—— '
            '它不该靠"更新"压掉对侧真实看过的 120s',
      );
      expect(
        pickResumeProgress(session: mk(120, 1), mirror: mk(0, 9999))!.position,
        120,
      );
    });

    test('★ 两侧都无效（0）⇒ 取 session（与老路径逐字同构）', () {
      final s = mk(0, 1);
      final picked = pickResumeProgress(session: s, mirror: mk(0, 9999));
      expect(identical(picked, s), isTrue);
    });

    test('★ 一侧为 null ⇒ 取另一侧（老数据/镜像缺失必须继续能续播）', () {
      expect(pickResumeProgress(session: null, mirror: mk(9, 1))!.position, 9);
      expect(pickResumeProgress(session: mk(9, 1), mirror: null)!.position, 9);
      expect(pickResumeProgress(session: null, mirror: null), isNull);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑩ isAnotherEpisode：**文件名 vs 站点集 id** 不许判成「另一集」（治 ③）
  // ═══════════════════════════════════════════════════════════════════
  //
  // # 缺陷（实测日志）
  // ```text
  // [PLAYER] 进度属于另一集（51463 ≠ 第01集.mp4），不续播
  // 本地会话的 curEpId = 文件名（第01集.mp4），镜像的 progressEpisodeId =
  //   站点集 id（51463）⇒ 旧守卫判「另一集」⇒ 拒绝续播。
  // ```
  group('⑩ isAnotherEpisode：两套标识体系不许误判（治 ③）', () {
    test('★★★ 站点集 id vs 本地文件名 ⇒ **不是**另一集（放行）', () {
      expect(
        isAnotherEpisode(
            progressEpisodeId: '51463', currentEpisodeId: '第01集.mp4'),
        isFalse,
        reason: '★★★ 实测日志里被误杀的正是这一对 —— '
            '一侧像文件名即说明是两套标识，不能按「不等 ⇒ 另一集」处理',
      );
      expect(
        isAnotherEpisode(
            progressEpisodeId: '第01集.mp4', currentEpisodeId: '51463'),
        isFalse,
        reason: '★ 对称：哪一侧是文件名都一样',
      );
    });

    test('★★ 都是站点集 id 且不等 ⇒ 是另一集（拒绝，守卫不能全丢）', () {
      expect(
        isAnotherEpisode(
            progressEpisodeId: '51463', currentEpisodeId: '51464'),
        isTrue,
        reason: '★★ 这条拒绝必须还在 —— 同一个站点里看完第 3 集，'
            '点开第 4 集不能被 seek 到结尾',
      );
    });

    test('★ 两侧相等 ⇒ 不是另一集', () {
      expect(
        isAnotherEpisode(
            progressEpisodeId: '51463', currentEpisodeId: '51463'),
        isFalse,
      );
      expect(
        isAnotherEpisode(
            progressEpisodeId: '第01集.mp4',
            currentEpisodeId: '第01集.mp4'),
        isFalse,
      );
    });

    test('★ 任一侧为空/空白 ⇒ 放行（没有集号可比，不猜）', () {
      for (final pair in [
        [null, '51463'],
        ['', '51463'],
        ['   ', '51463'],
        ['51463', null],
        ['51463', ''],
      ]) {
        expect(
          isAnotherEpisode(
              progressEpisodeId: pair[0], currentEpisodeId: pair[1]),
          isFalse,
          reason: '★ $pair —— 缺集号时放行（与 progressBelongsToCurrentEpisode 同口径）',
        );
      }
    });

    test('★ 边界：文件名样只认**视频后缀**（点在前、后缀在表内）', () {
      expect(isVideoFileName('第01集.mp4'), isTrue);
      expect(isVideoFileName('第01集.MKV'), isTrue, reason: '★ 大小写不敏感');
      expect(isVideoFileName('51463'), isFalse);
      expect(isVideoFileName(''), isFalse);
      expect(isVideoFileName('.mp4'), isFalse,
          reason: '★ 整个串就是后缀（dot==0）⇒ 不算文件名（与 mirrorProgressTitle 同口径）');
      expect(isVideoFileName('a.txt'), isFalse, reason: '★ 非视频后缀不算');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑪ 后缀表同值：core 的 _kVideoExts 必须与 ui 的 kVideoExts 一致
  // ═══════════════════════════════════════════════════════════════════
  //
  // core 不许 import ui（见 progress_origin.dart 文件头）⇒ 两份字面量。
  // 谁改一处没改另一处，「文件名样」判据就会与「视频后缀」判据漂开
  // （例如新增 .m2ts：磁盘认得、判据不认得 ⇒ 张冠李戴）。这里直接读两个文件钉住。
  group('⑪ 后缀表：core 与 ui 两份字面量必须同值', () {
    test('★★★ _kVideoExts（core）== kVideoExts（ui）', () {
      final core = _src('lib/core/progress_origin.dart');
      final ui = _src('lib/ui/cache_page.dart');
      final coreSet = _extsOf(core, 'const Set<String> _kVideoExts');
      final uiSet = _extsOf(ui, 'const Set<String> kVideoExts');
      expect(coreSet, isNotEmpty, reason: '★ 锚点必须找到（否则这条门禁是空的）');
      expect(coreSet, uiSet,
          reason: '★★★ 两份后缀表必须逐字相同 —— 否则「文件名样」判据与'
              '「视频后缀」判据会静默漂开（新增一个后缀时只改一处）');
    });
  });

  group('⑧ 环境探针：真核心能不能在本测试进程里加载', () {
    test('★ 探针（决定端到端两条是真跑还是如实跳过）', () async {
      final dir = Directory('${Directory.systemTemp.absolute.path}'
          '${Platform.pathSeparator}ops13_core');
      var ok = false;
      String why = '';
      try {
        if (!dir.existsSync()) dir.createSync(recursive: true);
        await SourinCore.startAsync(dir.path);
        ok = SourinCore.isStarted;
        why = ok ? '核心已启动' : 'startAsync 返回了但 isStarted=false';
      } catch (e) {
        why = e.toString();
      }
      // ignore: avoid_print
      print('[OPS13] 真核心探针: ok=$ok  why=$why');
      if (!ok) {
        return markTestSkipped(
            'flutter_tester 加载不了 sourin_core.dll（$why）—— '
            '端到端那两条会如实跳过并打印原因');
      }
      expect(SourinCore.isStarted, isTrue);
    });
  });
}
