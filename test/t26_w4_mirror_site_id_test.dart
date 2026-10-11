// ═══════════════════════════════════════════════════════════════════════
//  T26-W4 / CR-07 + CR-08：镜像进度那条的**正向**契约
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么单独一个文件（不是塞进 zz_ops13_mirror_write_test.dart）
//
// ```text
// zz_ops13_mirror_write_test.dart 必须在**缺陷代码上也能编译** ——
// 否则「修复前红」只是一句编译错误，证明不了任何行为。
// ⇒ 那个文件里**不能**出现 originEpisodeId（修复后才有的形参）。
//
// 而本文件测的正是 originEpisodeId / episodeTitle 这两个修复后才有的口子
// ⇒ 它在修复前是**诚实的编译期红**：
//   Error: No named parameter with the name 'originEpisodeId'.
// ★ 编译期红 ≠ 行为红。两件事分开写，谁也没冒充谁。
// ```
//
// # 本文件钉住什么（★ 行为）
//
// ```text
// ① 有站点集 id ⇒ 镜像那条**真的写出去**，且四个字段各就各位：
//    title          = **作品标题**（不是集标题）—— CR-07
//    episodeId      = **站点集 id**（不是本地文件名）—— CR-08
//    episodeTitle   = **集标题**（修复前它被塞进了 title，把作品标题顶掉）
//    position/duration 原样带过去
// ② 端到端：真 FFI 落库，站点键上读回来的 episodeId 就是站点集 id。
// ③ 会话自己那条（local 键）的 episodeId 仍然是**文件名** ——
//    两个标识符**本来就是两回事**（CR-08 要求③：不许拿文件名当站点集 id；
//    反过来也不许把站点集 id 写进本地那条）。
// ④ 不传 / 传空白 originEpisodeId ⇒ **一条镜像都不写**（默认安全）。
// ⑤ 作品标题是空白 ⇒ 也不写（Rust 对空标题是「保留旧值」，
//    写一条空标题只会白刷 updated_at，把「取更新的那条」判据带偏）。
// ```
//
// # 仪器
//
// ```text
// 1) sourin_core.dll 必须**先按绝对路径预载** —— lib/core/ffi.dart:222-259
//    的 Windows 分支只认裸名 open，而 SourinCore.startAsync 的工作 isolate
//    **不会**继承主 isolate 已映射的模块（实测：error code 126）。
//    DLL 不存在 ⇒ skip:（不是失败）。
// 2) 这里用裸 test() 而不是 testWidgets() —— 被测对象是纯函数 + FFI，
//    没有 widget；裸 test() 不跑在 FakeAsync 区里，真 await 才有意义。
// 3) 数据目录指到 TEMP 沙盒，**绝不碰** %APPDATA% 下的用户真实库。
// ```

import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/progress_origin.dart';
import 'package:sourin_spike/core/sourin_api.dart';

const String kTag = '[T26W4S]';
void log(String s) => debugPrint('$kTag $s');

/// 交付件里那颗 DLL（lib/core/ffi.dart:222-259 的 Windows 分支只认裸名）
const String _dllRel = r'build\windows\x64\runner\Release\sourin_core.dll';
final bool _dllReady = File(_dllRel).existsSync();

void _preloadCoreDll() {
  if (!_dllReady) return;
  DynamicLibrary.open(File(_dllRel).absolute.path);
  log('DLL 预加载 = OK（${File(_dllRel).absolute.path}）');
}

/// 本地会话那条的键 —— 与生产同形：**小写盘符 + 正斜杠**（cache_page 的
/// canonicalLocalPath），而「集号」是**文件名**（shell.dart 传
/// req.episode.fileName）。
const String localId = 'd:/t26w4/第01集.mp4';

/// 本地会话手上的集号 = **文件名**（与 shell.dart:4830 逐字同形）
const String localEpId = '第01集.mp4';

/// 在线侧的集号 = **站点集 id**（bilibili 的 ep id 长这样）
const String siteEpId = '51463';

const ProgressOrigin siteKey = ProgressOrigin(
    provider: 'bilibili', mediaId: 'BV1t26w4site');

void main() {
  late Directory sandbox;
  final mirrorCalls = <ProgressMirrorCall>[];

  setUpAll(() async {
    if (!_dllReady) return;
    _preloadCoreDll();
    sandbox = Directory(
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}'
        't26_w4_site_${DateTime.now().microsecondsSinceEpoch}');
    sandbox.createSync(recursive: true);
    if (!SourinCore.isStarted) {
      final started = await SourinApi.start(sandbox.path);
      log('start = $started');
    }
    log('isStarted = ${SourinCore.isStarted} sandbox=${sandbox.path}');
  });

  tearDownAll(() {
    try {
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    } catch (e) {
      log('清理沙盒失败（Windows 上 SQLite 可能仍被核心持有，不影响结论）: $e');
    }
  });

  setUp(() {
    mirrorCalls.clear();
    debugProgressMirrorSink = (ProgressMirrorCall call) async {
      mirrorCalls.add(call);
      log('镜像写入被拦截: $call');
    };
  });

  tearDown(() {
    debugProgressMirrorSink = null; // ★ 用完必须复位，否则污染同进程其它用例
  });

  final String? skipReason =
      _dllReady ? null : '交付件里的 sourin_core.dll 不在 ⇒ 环境不满足（跳过，不是失败）';

  // ─────────────────────────────────────────────────────────────────────
  //  A. 正向契约：有站点集 id ⇒ 镜像那条真的写出去，四个字段各就各位
  // ─────────────────────────────────────────────────────────────────────
  test('A. 有站点集 id ⇒ 镜像写出去：title 是作品标题、episodeId 是站点集 id',
      skip: skipReason, () async {
    await saveProgressWithMirror(
      provider: kProgressLocalProvider,
      id: localId,
      title: '本地剧',
      episodeId: localEpId,
      episodeTitle: '第01集',
      originEpisodeId: siteEpId,
      position: 30,
      duration: 100,
      mirror: siteKey,
    );

    log('拦截到 ${mirrorCalls.length} 条镜像: $mirrorCalls');
    expect(mirrorCalls.length, 1,
        reason: '★★★ 站点集 id 拿得到时，镜像那条**必须**写出去 —— '
            '一条都没有 = 「本地和线上彻底分开」原样没修');
    final c = mirrorCalls.single;
    expect(c.provider, 'bilibili', reason: '★★ 打到原来源的 provider 上');
    expect(c.mediaId, 'BV1t26w4site',
        reason: '★★ 打到原来源的站点内容 id 上');
    expect(c.title, '本地剧',
        reason: '★★★ CR-07：镜像的 title 是**作品标题** —— '
            '修复前这里写的是集标题「第01集」，会把站点键上那条在线记录的'
            '作品标题顶掉（upsert_progress 对非空 title 是覆盖写），'
            '之后 detail_page._resolveLocalOrigin 按标题认回来源也会失效');
    expect(c.episodeId, siteEpId,
        reason: '★★★ CR-08：镜像的 episodeId 是**站点集 id** —— '
            '修复前它恒为 null，会把在线记录已有的集 ID 覆盖成 NULL'
            '（store.rs 的 ON CONFLICT 里 episode_id=excluded.episode_id 无守卫）');
    expect(c.episodeTitle, '第01集',
        reason: '★★ CR-07：集标题终于有地方去了（走 episodeTitle）');
    expect(c.position, 30, reason: '★ 位置原样');
    expect(c.duration, 100, reason: '★ 时长原样');
  });

  // ─────────────────────────────────────────────────────────────────────
  //  B. 端到端：真 FFI 落库
  // ─────────────────────────────────────────────────────────────────────
  test('B. 端到端：站点键上读回来的 episodeId 就是站点集 id',
      skip: skipReason, () async {
    // ★ 摘掉注入点 ⇒ 走真 FFI（注入点只证明**调用了**，不证明**写对了**）
    debugProgressMirrorSink = null;
    const originProvider = 'bilibili';
    const originMediaId = 'BV1t26w4e2e';

    await saveProgressWithMirror(
      provider: kProgressLocalProvider,
      id: localId,
      title: '本地剧',
      episodeId: localEpId,
      episodeTitle: '第01集',
      originEpisodeId: siteEpId,
      position: 30,
      duration: 100,
      mirror: const ProgressOrigin(
          provider: originProvider, mediaId: originMediaId),
    );

    final got = await SourinApi.getProgress(originProvider, originMediaId);
    log('端到端读回站点键: title=${got?.title} episodeId=${got?.episodeId} '
        'episodeTitle=${got?.episodeTitle} pos=${got?.position}/${got?.duration}');
    expect(got, isNotNull,
        reason: '★★★ 站点键上必须真的有一条 —— 镜像没落库 = 功能没做');
    expect(got!.title, '本地剧', reason: '★★★ CR-07：作品标题');
    expect(got.episodeId, siteEpId,
        reason: '★★★ CR-08：站点集 id 真的进了 episode_id 列');
    expect(got.episodeTitle, '第01集');
    expect(got.position, 30);
    expect(got.duration, 100);

    // ★ 会话自己那条：集号仍然是**文件名** —— 两个标识符本来就是两回事
    final own = await SourinApi.getProgress(kProgressLocalProvider, localId);
    log('会话自己那条: episodeId=${own?.episodeId} pos=${own?.position}');
    expect(own, isNotNull);
    expect(own!.episodeId, localEpId,
        reason: '★★★ CR-08 要求③的反面：本地那条的集号**就该**是文件名 —— '
            '它和站点集 id 不是同一个标识，谁都不许替对方做主');
    expect(own.position, 30);
  });

  // ─────────────────────────────────────────────────────────────────────
  //  C/D/E. 默认安全：拿不到站点集 id（或标题为空）⇒ 一条都不写
  // ─────────────────────────────────────────────────────────────────────
  test('C. 不传 originEpisodeId ⇒ 一条镜像都不写（默认安全）',
      skip: skipReason, () async {
    await saveProgressWithMirror(
      provider: kProgressLocalProvider,
      id: localId,
      title: '本地剧',
      episodeId: localEpId,
      position: 30,
      duration: 100,
      mirror: siteKey,
    );
    expect(mirrorCalls, isEmpty,
        reason: '★★★ 拿不到站点集 id 就**整条跳过** —— '
            '写 episode_id=null 会在 store.rs 那里把在线记录已有的集 ID '
            '覆盖成 NULL（不可逆）；写文件名又会被在线那条「按集校验」挡掉。'
            '「少写一条镜像」只是退化成今天的样子，两者不对等');
  });

  test('D. originEpisodeId 是空白串 ⇒ 也不写（trim 后为空）',
      skip: skipReason, () async {
    await saveProgressWithMirror(
      provider: kProgressLocalProvider,
      id: localId,
      title: '本地剧',
      episodeId: localEpId,
      originEpisodeId: '   ',
      position: 30,
      duration: 100,
      mirror: siteKey,
    );
    expect(mirrorCalls, isEmpty,
        reason: '★ 空白串不是站点集 id —— 别让它溜进去当成键值');
  });

  test('E. 作品标题是空白 ⇒ 也不写（别白刷 updated_at）',
      skip: skipReason, () async {
    await saveProgressWithMirror(
      provider: kProgressLocalProvider,
      id: localId,
      title: '   ',
      episodeId: localEpId,
      episodeTitle: '第01集',
      originEpisodeId: siteEpId,
      position: 30,
      duration: 100,
      mirror: siteKey,
    );
    expect(mirrorCalls, isEmpty,
        reason: '★★ Rust 对空标题是「保留旧值」（store.rs 的 '
            'CASE WHEN excluded.title <> ''）⇒ 写一条空标题只会白刷 updated_at，'
            '把 pickResumeProgress「取更新的那条」判据带偏');
  });
}
