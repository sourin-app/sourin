// T26-W7 · CR-04：镜像模式下「取不到校验表」不许把已经下好的安装包删掉
//
// 缺陷（CodeRabbit CR-04 / Major，app_update_controller.dart 的 verifySha256）：
//   镜像模式下它把路线改成 UpdateRoute.direct，于是「直连不通 = 校验表取不到」，
//   而旧代码对「取不到表」和「哈希对不上」一律 return false，调用方于是：
//     · 把已经经镜像好好下下来的安装包删掉；
//     · 告诉用户「文件校验未通过，已删除，请重试」。
//   对镜像用户这是死路：镜像通、直连不通是常态 ⇒ 永远更不了新。
//
// 本文件的用例（全部走回环，不访问外网）：
//   1 资产自带 digest 且对得上 ⇒ 通过，且一个校验表请求都不发（CR-04 要求①）；
//   2 镜像可达但内容对不上（digest 对不上）⇒ 明确「校验未通过」且文件被删；
//   3 校验表不可达（可信源整个停掉）⇒ 明确「取不到校验表」，且
//     已下载的安装包必须还在（CR-04 的核心）；
//   4 可信源明确回答「没有这张表」（HTTP 404，旧 Release 没有 digest）
//     ⇒ 判校验失败并删掉 ——「对方答了」和「压根没问到」不能混为一谈；
//   5 被控镜像同时换掉表和包的老攻击（CR-08-1b）仍然拦得住 ——
//     CR-04 的修复不许把 CR-08 的牙拔掉。
//
// 修复前/后读数见 .probe/ops/t26-w7-update.md：修复前 5 条里 4 条红（第 5 条是
// 安全用例，两版都必须绿）；变异体 MUT-B（把「失败就删」改回去）只让用例 3 变红。
//
// ⚠ 故意不调 TestWidgetsFlutterBinding.ensureInitialized()：它会把所有
//   HttpClient 请求拦成 400，那样测的就不是真实网络路径了。
// ⚠ 用例 3 会把可信源真的关掉：客户端必须把「连不上」判成「无法判定」，
//   而不是「文件坏了」。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/app_update/app_update_controller.dart';
import 'package:sourin_spike/core/app_update/release.dart';
import 'package:sourin_spike/core/app_update/route.dart';
import 'package:sourin_spike/core/app_update/sha256.dart';
import 'package:sourin_spike/core/clip_download.dart';
import 'package:sourin_spike/core/ui_prefs.dart';

import 'support/zz_cr_upd_origin.dart';

const _setup = 'Sourin-Setup-1.1.0.exe';
const _other = 'sourin-macos-v1.1.0.dmg';
const _tag = 'v1.1.0';
const _assetBase = '/repos/sourin-app/sourin/releases/download';
const _rel = _assetBase + '/' + _tag + '/';
const _mirrorPrefix = 'https://github.com/sourin-app/sourin/releases/download/';
const _mir = '/$_mirrorPrefix$_tag/';
const _githubPkg = '$_mirrorPrefix$_tag/$_setup';
const _githubDmg = '$_mirrorPrefix$_tag/$_other';

/// 当前平台该下的那个包（与 zz_cr_upd_08 的夹具保持同一套名字）
final _pkg = Platform.isWindows ? _setup : _other;

/// 造一份同时挂 .exe 与 .dmg 的 Release；[digest] 只挂在本平台那个包上
ReleaseInfo _release(String exeUrl, String dmgUrl, {String digest = ""}) {
  ReleaseAsset mk(String name, String url) => ReleaseAsset(
        name: name,
        size: 4,
        url: url,
        browserUrl: 'https://example.invalid/b',
        digest: name == _pkg ? digest : '',
      );
  return ReleaseInfo(
    tag: _tag,
    name: 'v1.1.0',
    notes: '',
    prerelease: false,
    htmlUrl: 'https://example.invalid/r',
    publishedAt: null,
    assets: [mk(_setup, exeUrl), mk(_other, dmgUrl)],
  );
}

/// 资产地址用 GitHub 绝对地址（镜像模式下由 RouteRewriter 改写到回环镜像上）
ReleaseInfo _releaseUnderTest({String digest = ""}) =>
    _release(_githubPkg, _githubDmg, digest: digest);

List<int> _sums(List<int> pkg, String name) =>
    utf8.encode(sha256OfBytes(pkg) + '  ' + name + '\n');

void main() {
  late Directory tmp;
  TestOrigin? trusted; // 可信直连源：校验表只能从这里取
  TestOrigin? mirror; // 被控镜像：安装包走这里

  setUp(() async {
    UiPrefs.debugResetForTest();
    tmp = await Directory.systemTemp.createTemp('t26_w7_mirror_checksum');
    await UiPrefs.load(tmp.path);
    ClipDownloader.debugSetDataDir(tmp.path);
  });
  tearDown(() async {
    AppUpdateController.assetUrl =
        'https://github.com/sourin-app/sourin/releases/download';
    AppUpdateController.instance.setRoute(const UpdateRouteConfig());
    ClipDownloader.debugSetDataDir(null);
    await trusted?.stop();
    await mirror?.stop();
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } catch (_) {
      // Windows 可能还持着刚校验完那个文件的句柄；临时目录留在 TEMP 里无妨
    }
  });

  /// 装好路由：镜像 = 回环源，可信基址 = 回环源 [trustedBase]
  AppUpdateController _wire(String trustedBase, String mirrorBase) {
    AppUpdateController.assetUrl = trustedBase + _assetBase;
    final c = AppUpdateController.instance;
    c.debugResetAvailable();
    c.setRoute(UpdateRouteConfig(
      route: UpdateRoute.mirror,
      customMirror: mirrorBase + '/',
    ));
    return c;
  }

  File _dest() => File(tmp.path +
      Platform.pathSeparator +
      'updates' +
      Platform.pathSeparator +
      _pkg);

  // ══════════════════════════════════════════════════════════════════
  //  1 digest 优先：对得上就通过，且一个校验表请求都不发
  // ══════════════════════════════════════════════════════════════════
  test('T26-W7-1 资产自带 digest 且对得上 ⇒ 通过，且零校验表请求', () async {
    final pkg = utf8.encode('GOOD-PACKAGE-BYTES');
    // 可信源什么都不提供：只要还有 digest 这条路，就不该有人去问它
    trusted = await TestOrigin.start({});
    mirror = await TestOrigin.start({_mir + _pkg: pkg});

    final c = _wire(trusted!.base, mirror!.base);
    final file = await c.downloadRelease(
      _releaseUnderTest(digest: 'sha256:' + sha256OfBytes(pkg)),
      onProgress: (_) {},
    );

    expect(file, isNotNull, reason: '摘要对得上 ⇒ 必须通过');
    expect(c.download.error, isNull);
    expect(_dest().existsSync(), isTrue);
    expect(mirror!.hits, contains(_mir + _pkg),
        reason: '安装包确实经镜像下过（$_pkg）—— 防止「选不到资产」被当成成功');
    expect(trusted!.hits, isEmpty,
        reason: 'CR-04 要求①：有资产自带 digest 就不该再去取校验表');
    expect(mirror!.hits.where((h) => h.endsWith('SHA256SUMS.txt')), isEmpty,
        reason: '镜像上更不该出现校验表请求');
  });

  // ══════════════════════════════════════════════════════════════════
  //  2 内容对不上：明确「校验未通过」并删掉
  // ══════════════════════════════════════════════════════════════════
  test('T26-W7-2 镜像可达但内容对不上 ⇒ 明确「校验未通过」且文件被删', () async {
    final goodPkg = utf8.encode('GENUINE-PACKAGE-BYTES');
    final evilPkg = utf8.encode('MALICIOUS-PACKAGE-BYTES');
    trusted = await TestOrigin.start({});
    mirror = await TestOrigin.start({_mir + _pkg: evilPkg});

    final c = _wire(trusted!.base, mirror!.base);
    final file = await c.downloadRelease(
      _releaseUnderTest(digest: 'sha256:' + sha256OfBytes(goodPkg)),
      onProgress: (_) {},
    );

    expect(mirror!.hits, contains(_mir + _pkg), reason: '安装包确实下过');
    expect(file, isNull, reason: '替身包对不上摘要 ⇒ 必须拒绝安装');
    expect(c.download.error, '文件校验未通过，已删除，请重试',
        reason: '这一态必须说「校验未通过」，不能含糊成「取不到校验表」');
    expect(_dest().existsSync(), isFalse, reason: '被拒的安装包不能留在磁盘上');
    expect(trusted!.hits, isEmpty, reason: 'digest 分支连表都不取');
  });

  // ══════════════════════════════════════════════════════════════════
  //  3 ★★ 校验表不可达：不许把已下好的包删掉（CR-04 的核心）
  // ══════════════════════════════════════════════════════════════════
  test('T26-W7-3 ★★校验表不可达 ⇒ 明确「取不到校验表」且不误删已下载文件', () async {
    final pkg = utf8.encode('GOOD-PACKAGE-BYTES');
    trusted = await TestOrigin.start({});
    final trustedBase = trusted!.base; // 关掉之前先把基址记下来
    mirror = await TestOrigin.start({_mir + _pkg: pkg});

    final c = _wire(trustedBase, mirror!.base);
    // 可信源整个停掉：这就是「镜像通、直连不通」的镜像用户现场
    await trusted!.stop();
    trusted = null;

    final file = await c.downloadRelease(
      _releaseUnderTest(), // 旧 Release：没有 digest，只能靠校验表
      onProgress: (_) {},
    );

    expect(mirror!.hits, contains(_mir + _pkg), reason: '安装包确实下过');
    expect(file, isNull, reason: '证明不了完整性 ⇒ 不许安装（不放行）');
    expect(c.download.error, contains('取不到校验表'),
        reason: '必须明说「取不到校验表」，而不是「文件校验未通过」');
    expect(c.download.error, isNot(contains('文件校验未通过')),
        reason: '网络失败不许被报成「文件校验未通过」（CR-04 原文）');
    expect(_dest().existsSync(), isTrue,
        reason: '★★ CR-04 的核心：文件是好好下下来的，只是暂时证明不了完整性，不能删');
  });

  // ══════════════════════════════════════════════════════════════════
  //  4 「对方答了」≠「压根没问到」：404 是明确的否定回答
  // ══════════════════════════════════════════════════════════════════
  test('T26-W7-4 可信源明确回答「没有这张表」(404) ⇒ 判校验失败并删掉', () async {
    final pkg = utf8.encode('GOOD-PACKAGE-BYTES');
    trusted = await TestOrigin.start({}); // 服务在，但这个路径 404
    mirror = await TestOrigin.start({_mir + _pkg: pkg});

    final c = _wire(trusted!.base, mirror!.base);
    final file = await c.downloadRelease(_releaseUnderTest(), onProgress: (_) {});

    expect(trusted!.hits, contains(_rel + 'SHA256SUMS.txt'),
        reason: '校验表确实问过可信源（否则这条是假绿）');
    expect(mirror!.hits, contains(_mir + _pkg), reason: '安装包确实下过');
    expect(file, isNull, reason: '这个版本根本没有校验表 ⇒ 证明不了完整性');
    expect(c.download.error, contains('没有提供校验表'),
        reason: '说清楚是「表不存在」，不是「网络取不到」，也不是「文件坏了」');
    expect(_dest().existsSync(), isFalse,
        reason: '对方明确答了「没有」⇒ 留着这个包没意义，也不该让用户去双击');
  });

  // ══════════════════════════════════════════════════════════════════
  //  5 CR-08 的牙还在：被控镜像换表+换包，仍然拦得住
  // ══════════════════════════════════════════════════════════════════
  test('T26-W7-5 ★被控镜像同时换掉表和包 ⇒ 仍然拒装（CR-08 未被 CR-04 拔牙）',
      () async {
    final goodPkg = utf8.encode('GENUINE-PACKAGE-BYTES');
    final evilPkg = utf8.encode('MALICIOUS-PACKAGE-BYTES');
    // 可信源：真表（真包的摘要）；镜像：自洽的假表 + 替身包
    trusted = await TestOrigin.start({
      _rel + 'SHA256SUMS.txt': _sums(goodPkg, _pkg),
    });
    mirror = await TestOrigin.start({
      _mir + 'SHA256SUMS.txt': _sums(evilPkg, _pkg),
      _mir + _pkg: evilPkg,
    });

    final c = _wire(trusted!.base, mirror!.base);
    final file = await c.downloadRelease(_releaseUnderTest(), onProgress: (_) {});

    expect(mirror!.hits, contains(_mir + _pkg), reason: '安装包仍走镜像');
    expect(mirror!.hits.where((h) => h.endsWith('SHA256SUMS.txt')), isEmpty,
        reason: '校验表绝不能经镜像取：被控镜像会把表和包一起换掉');
    expect(trusted!.hits, contains(_rel + 'SHA256SUMS.txt'),
        reason: '真校验表必须从可信源取');
    expect(file, isNull, reason: '替身包对不上真表的摘要 ⇒ 必须拒绝安装');
    expect(_dest().existsSync(), isFalse, reason: '被拒的安装包不能留在磁盘上');
    expect(c.download.error, contains('文件校验未通过'),
        reason: '这是「对不上」，不是「取不到」');
  });
}
