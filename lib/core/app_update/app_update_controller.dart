// ═══════════════════════════════════════════════════════════════════════
//  版本更新 —— 协调者（检查 / 下载 / 安装 / 节流 / 偏好）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么不做成一个全局单例到处直接调用
//
// 检查更新的时机有三处（启动、关于页手动、发现新版本后的提示），
// 但**彼此要共享同一份状态**（"已经查过了没有"、正在下载、不要重复提示）。
// 单例 + `ChangeNotifier` 是这里最省事且不引第三方状态管理的样子。
//
// # 两条硬约束
// ```text
// ① 任何网络失败都**不抛到调用方**，只在状态里记一句 —— 更新查不到
//    是日常（断网、镜像挂了、公司内网），不该弹错误。
// ② 启动时最多自动查一次/天，且可完全关闭。用户手动查**不受节流限制**。
// ```

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app_log.dart';
import '../clip_download.dart';
import '../ui_prefs.dart';
import 'app_version.dart';
import 'client.dart';
import 'release.dart';
import 'route.dart';
import 'semver.dart';
import 'sha256.dart';

/// 一次检查的结果
class UpdateCheckResult {
  const UpdateCheckResult({
    required this.checked,
    this.release,
    this.message,
  });

  /// 是否成功联系到服务
  final bool checked;

  /// 比当前版本新的那个 Release（没有则 null）
  final ReleaseInfo? release;

  /// 给用户看的说明（成功/失败都用它，失败时不弹窗只写日志）
  final String? message;
}

/// 下载进度
class UpdateDownloadState {
  const UpdateDownloadState({
    required this.active,
    this.bytes = 0,
    this.total = -1,
    this.error,
  });

  final bool active;

  /// 已下载字节（-1 表示仍在解析）
  final int bytes;

  /// 总字节；服务器不给 Content-Length 时为 -1
  final int total;
  final String? error;

  static const idle = UpdateDownloadState(active: false);

  /// 0~1；总量未知时返回 0（UI 走不确定态动画）
  double get fraction => total <= 0 ? 0 : (bytes / total).clamp(0.0, 1.0);

  UpdateDownloadState copyWith({
    bool? active,
    int? bytes,
    int? total,
    String? error,
  }) =>
      UpdateDownloadState(
        active: active ?? this.active,
        bytes: bytes ?? this.bytes,
        total: total ?? this.total,
        error: error,
      );
}

/// 校验一个下载到的安装包的结果（CR-04：这几种情况必须能分开）
///
/// 旧接口是个 `bool`，于是「文件被换过」和「连不上校验表」在调用方眼里
/// 长得一模一样 —— 而这两种情况的处置**正好相反**：
/// ```text
/// 内容对不上  ⇒ 文件已经被替换 / 下坏了 ⇒ 必须删掉，绝不能让用户去装；
/// 根本没问到  ⇒ 文件还是从镜像好好下下来的 ⇒ **不能删** —— 镜像用户
///              直连不通是常态，删了等于他永远更不了新（CR-04 就是这条）。
/// ```
enum UpdateVerifyResult {
  /// 摘要对上了（资产自带的 digest，或可信源上的 `SHA256SUMS.txt`）
  ok,

  /// 内容对不上：被替换 / 下坏了 / 表里根本没有它 ⇒ **删掉**
  mismatch,

  /// 可信源明确回答「没有这张表」（HTTP 非 200）⇒ 以后也不会自己冒出来 ⇒ **删掉**
  missingTable,

  /// 无法判定：压根没问到答案（连不上 / 超时）⇒ 文件留着，但不给装
  unverified;

  /// 这个结果下，调用方该不该把安装包留在磁盘上
  ///
  /// 只有「压根没问到」才留 —— 那还有救（等会儿网络好了再校验一次）；
  /// 「有答案且答案是否定的」留着没意义，也不该让用户拿着去双击。
  bool get keepFile => this == UpdateVerifyResult.unverified;

  /// 直接写进 [UpdateDownloadState.error] 的那句话
  String get errorMessage => switch (this) {
        UpdateVerifyResult.mismatch => '文件校验未通过，已删除，请重试',
        UpdateVerifyResult.missingTable => '这个版本没有提供校验表，已删除，请重试',
        UpdateVerifyResult.unverified => '取不到校验表，安装包已保留，请稍后重试',
        UpdateVerifyResult.ok => '',
      };
}

class AppUpdateController extends ChangeNotifier {
  AppUpdateController._();

  static final AppUpdateController instance = AppUpdateController._();

  // ── 偏好键 ──
  static const _kRoute = 'appupdate.route';
  static const _kAutoCheck = 'appupdate.autoCheck';
  static const _kIncludePrerelease = 'appupdate.includePrerelease';
  static const _kLastCheck = 'appupdate.lastCheckAt';
  static const _kIgnored = 'appupdate.ignoredVersion';

  static const repoOwner = 'sourin-app';
  static const repoName = 'sourin';

  /// API 根。测试时指向回环服务器（见 [debugSetApiBaseForTest]）。
  static String get apiBase => _apiBaseOverride ?? _apiBase;

  static const _apiBase = 'https://api.github.com';

  static String? _apiBaseOverride;

  /// 测试用：把 API 根指到回环服务器，让 [check] 不出网也能跑通
  @visibleForTesting
  // ignore: avoid_setters_without_getters
  static void debugSetApiBaseForTest(String? base) => _apiBaseOverride = base;

  /// 测试用：把 Release 资产的下载源指到别处（镜像回环服务器用）
  @visibleForTesting
  static String assetUrl = 'https://github.com/$repoOwner/$repoName/releases/download';

  // ── 状态 ──
  UpdateRouteConfig _route = const UpdateRouteConfig();
  bool _autoCheck = true;
  bool _includePrerelease = false;
  DateTime? _lastCheckAt;
  String _ignoredVersion = '';
  bool _checking = false;
  ReleaseInfo? _available;
  UpdateDownloadState _download = UpdateDownloadState.idle;
  bool _cancelled = false;

  UpdateRouteConfig get route => _route;
  bool get autoCheck => _autoCheck;
  bool get includePrerelease => _includePrerelease;
  bool get checking => _checking;
  ReleaseInfo? get available => _available;
  UpdateDownloadState get download => _download;
  DateTime? get lastCheckAt => _lastCheckAt;

  /// 是否该在启动时自动查一次
  ///
  /// 规则：开着 + 从没查过（或距上次超过 [_autoInterval]）+ 没在下载中。
  bool get shouldAutoCheck {
    if (!_autoCheck || _checking || _download.active) return false;
    if (_lastCheckAt == null) return true;
    return DateTime.now().difference(_lastCheckAt!) >= _autoInterval;
  }

  /// 自动检查间隔：**每天最多一次**
  static const _autoInterval = Duration(hours: 24);

  UpdateHttp get _http => UpdateHttp(_route);

  // ── 偏好 ──

  void loadPrefs() {
    _route = UpdateRouteConfig(
      route: UpdateRoute.parse(UiPrefs.get(_kRoute)),
      proxyHost: UiPrefs.get('appupdate.proxyHost') ?? '',
      proxyPort: int.tryParse(UiPrefs.get('appupdate.proxyPort') ?? '') ?? 0,
      followSystemProxy:
          UiPrefs.get('appupdate.followSystemProxy') == '1',
      mirrorName: UiPrefs.get('appupdate.mirrorName') ?? '',
      customMirror: UiPrefs.get('appupdate.customMirror') ?? '',
    );
    _autoCheck = UiPrefs.get(_kAutoCheck) != '0';
    _includePrerelease = UiPrefs.get(_kIncludePrerelease) == '1';
    _lastCheckAt = DateTime.tryParse(UiPrefs.get(_kLastCheck) ?? '');
    _ignoredVersion = UiPrefs.get(_kIgnored) ?? '';
  }

  void setRoute(UpdateRouteConfig c) {
    _route = c;
    c.toPrefs().forEach((k, v) => UiPrefs.set('appupdate.$k', v));
    notifyListeners();
  }

  void setAutoCheck(bool v) {
    _autoCheck = v;
    UiPrefs.set(_kAutoCheck, v ? '1' : '0');
    notifyListeners();
  }

  void setIncludePrerelease(bool v) {
    _includePrerelease = v;
    UiPrefs.set(_kIncludePrerelease, v ? '1' : '0');
    notifyListeners();
  }

  /// 忽略某个版本（之后不再提示它）
  void ignoreVersion(String tag) {
    _ignoredVersion = tag;
    UiPrefs.set(_kIgnored, tag);
    if (_available?.tag == tag) _available = null;
    notifyListeners();
  }

  String get ignoredVersion => _ignoredVersion;

  // ── 检查 ──

  /// 查一次更新。[manual] 为 true 时忽略节流并把结果给 UI
  Future<UpdateCheckResult> check({bool manual = false}) async {
    if (_checking) {
      return const UpdateCheckResult(checked: false, message: '正在检查…');
    }
    _checking = true;
    if (manual) notifyListeners();

    try {
      final current = (await AppVersion.load()).version;
      final rel = _includePrerelease
          ? await _fetchLatestOfAny()
          : await _fetchLatest();
      final newer = _pickNewer(releases: [rel], current: current);
      // ⚠️ 检查时间必须在「是否被忽略」判断**之前**落盘（CR-07）：
      // 旧代码在忽略分支直接 return，_lastCheckAt 从来没被写进去 ⇒
      // shouldAutoCheck 恒为 true ⇒ 每次启动都重新查、重新弹窗，
      // 「忽略此版本」等于白按。
      _lastCheckAt = DateTime.now();
      UiPrefs.set(_kLastCheck, _lastCheckAt!.toIso8601String());
      if (newer != null && newer.tag == _ignoredVersion) {
        // 手动检查（「关于」页）仍把 release 交回 UI，用户可以反悔；
        // 自动检查（启动弹窗）只认 release != null，所以这里必须置空。
        _available = manual ? newer : null;
        if (manual) notifyListeners();
        return UpdateCheckResult(
          checked: true,
          release: manual ? newer : null,
          message: '已是最新版本',
        );
      }
      _available = newer;
      notifyListeners();
      return UpdateCheckResult(
        checked: true,
        release: newer,
        message: newer == null ? '当前已是最新版本 ${_short(current)}' : null,
      );
    } on ReleaseParseException catch (e) {
      AppLog.write('UPDATE', '发布信息解析失败: $e');
      return const UpdateCheckResult(checked: false, message: '更新信息读取异常');
    } catch (e) {
      // 网络失败不是错误 —— 断网时用户不该看到红框
      AppLog.write('UPDATE', '检查更新失败（静默）: $e');
      return const UpdateCheckResult(
        checked: false,
        message: '连不上更新服务，已改为稍后再试',
      );
    } finally {
      _checking = false;
      if (manual) notifyListeners();
    }
  }

  static String _short(String v) => v.length > 12 ? '${v.substring(0, 12)}…' : v;

  /// 从一批候选里挑出**比当前版本新**的（已是最新时返回 null）
  ///
  /// 单独抽出来是为了能离线测：候选是现成的 [ReleaseInfo]。
  ReleaseInfo? _pickNewer({
    required List<ReleaseInfo> releases,
    required String current,
  }) {
    final cur = SemVer.tryParse(current);
    if (cur == null) return null;
    ReleaseInfo? best;
    for (final r in releases) {
      final v = SemVer.tryParse(r.tag);
      if (v == null) continue;
      if (v.compareTo(cur) <= 0) continue;
      if (best == null) {
        best = r;
        continue;
      }
      final bv = SemVer.tryParse(best.tag)!;
      if (v.compareTo(bv) > 0) best = r;
    }
    return best;
  }

  Future<ReleaseInfo> _fetchLatest() async {
    final body = await _http.getText(Uri.parse('$apiBase/repos/$repoOwner/$repoName/releases/latest'),
        headers: {'Accept': 'application/vnd.github+json'});
    return parseReleaseJson(jsonDecode(body) as Map<String, dynamic>);
  }

  Future<ReleaseInfo> _fetchLatestOfAny() async {
    final body = await _http.getText(Uri.parse('$apiBase/repos/$repoOwner/$repoName/releases?per_page=20'),
        headers: {'Accept': 'application/vnd.github+json'});
    final list = parseReleaseListJson(jsonDecode(body) as List<dynamic>);
    if (list.isEmpty) throw ReleaseParseException('没有可用的发布记录');
    return list.first;
  }

  /// 当前平台该下的那个资产（没有则 null）
  ReleaseAsset? assetFor(ReleaseInfo rel) {
    final (platform, abi) = UpdateHttp.currentTarget();
    return selectAsset(rel, platform, abi: abi);
  }

  // ── 下载 ──

  /// 下载某个 Release 的本平台安装包
  ///
  /// - [onDone] 返回可打开的文件路径；null 表示失败（已记进 [download].error）
  /// 校验分两段（见 [verifySha256]）：
  ///
  /// ```text
  /// ① 资产自带 digest  ⇒ 离线比对，不发任何请求（首选）；
  /// ② 没有 digest      ⇒ 取可信源的 SHA256SUMS.txt 比对。
  /// ```
  ///
  /// 失败分两种，处置不同：
  /// ```text
  /// 有答案而答案是否定的（内容对不上 / 表里没有它 / 表确实不存在）
  ///                                 ⇒ 删掉安装包，返回 null；
  /// 压根没问到（连不上 / 超时）      ⇒ **保留**安装包，返回 null。
  /// ```
  /// ★ CR-04：以前两种情况都删包并报「文件校验未通过」，于是镜像用户
  /// （镜像通、直连不通）永远更不了新。
  Future<File?> downloadRelease(
    ReleaseInfo rel, {
    void Function(UpdateDownloadState)? onProgress,
  }) async {
    final asset = assetFor(rel);
    if (asset == null) {
      _download = const UpdateDownloadState(
        active: false,
        error: '这个版本没有提供当前设备的安装包',
      );
      notifyListeners();
      return null;
    }

    final dir = Directory('${await ClipDownloader.dataDir()}/updates');
    await dir.create(recursive: true);
    final dest = File('${dir.path}${Platform.pathSeparator}${asset.name}');

    _cancelled = false;
    _download = const UpdateDownloadState(active: true, bytes: 0, total: -1);
    notifyListeners();

    try {
      final url = Uri.parse(RouteRewriter(_route).rewriteDownloadUrl(asset.url));
      await _http.download(
        url,
        dest,
        onProgress: (done, total) {
          _download = _download.copyWith(bytes: done, total: total);
          onProgress?.call(_download);
          notifyListeners();
        },
        cancelled: () async => _cancelled,
      );

      final vr = await verifySha256(
        dest,
        asset.name,
        tag: rel.tag,
        digest: asset.digest,
      );
      _download = UpdateDownloadState(
        active: false,
        bytes: await dest.length(),
        total: await dest.length(),
      );
      notifyListeners();
      if (vr != UpdateVerifyResult.ok) {
        _download = _download.copyWith(error: vr.errorMessage);
        // ★ 只有「根本没问到」才留着文件 —— 镜像用户直连取不到校验表是
        //   常态，删掉等于让他永远更不了新（CR-04）；有答案而答案是否定的
        //   （哈希不符 / 表里没这个资产 / 表确实不存在）就没必要留。
        if (!vr.keepFile) {
          try {
            dest.deleteSync();
          } catch (_) {}
        }
        notifyListeners();
        return null;
      }
      return dest;
    } on UpdateCancelled {
      _download = UpdateDownloadState.idle.copyWith(error: '已取消下载');
      notifyListeners();
      return null;
    } catch (e) {
      AppLog.write('UPDATE', '下载更新包失败: $e');
      _download = const UpdateDownloadState(
          active: false, error: '下载失败，请检查网络或下载方式设置');
      notifyListeners();
      return null;
    }
  }

  /// 取消正在进行的下载
  void cancelDownload() => _cancelled = true;

  /// 测试用：直接摆一个下载状态（截图与状态机断言用，不碰网络）
  @visibleForTesting
  void debugSetDownloadState(UpdateDownloadState s) {
    _download = s;
    notifyListeners();
  }

  /// 测试用：清掉已缓存的「有新版」状态
  @visibleForTesting
  void debugResetAvailable() {
    _available = null;
    _checking = false;
    notifyListeners();
  }

  /// 把一个文件与「期望的 SHA-256」对一遍
  ///
  /// 只回答一件事：**字节是不是那些字节**。拿不到期望值（null）就返回
  /// [UpdateVerifyResult.unverified] —— 那说的是「我没法判定」，不是「文件坏了」，
  /// 调用方据此决定删不删（见 [downloadRelease]）。
  Future<UpdateVerifyResult> verifyFileAgainstSha256(
    File file,
    String? want, {
    required String what,
  }) async {
    if (want == null) return UpdateVerifyResult.unverified;
    final got = await sha256OfFile(file);
    if (got != want) {
      AppLog.write('UPDATE', '校验不符（$what）：期望 $want 实得 $got');
      return UpdateVerifyResult.mismatch;
    }
    return UpdateVerifyResult.ok;
  }

  /// 用 Release 里的 `SHA256SUMS.txt` 校验一个文件
  ///
  /// # 校验表必须来自可信源（CR-08 / CWE-494）
  ///
  /// 旧代码把校验表也按当前路线（镜像）改写，于是被控镜像可以**同时**替换
  /// `SHA256SUMS.txt` 和安装包 —— 摘要对得上，校验形同虚设。
  /// 现在：镜像模式下校验表一律**直连**取，不经镜像。
  ///
  /// # 「取不到」和「对不上」是两回事（CR-04）
  ///
  /// 以前无论哪种情况都返回 false，调用方于是把**已经好好下下来的安装包**
  /// 删掉，还告诉用户「文件校验未通过」。对镜像用户这是死路：镜像通、直连不通
  /// ⇒ 校验表永远取不到 ⇒ 永远更不了新。现在这几种情况分开报：
  /// ```text
  /// ok           摘要对上（资产自带的 digest，或可信源上的 SHA256SUMS.txt）
  /// mismatch     内容对不上，含「表里没有这个资产」⇒ 无法证明完整性，删掉
  /// missingTable 可信源明确回答「没有这张表」⇒ 同样删掉（以后也不会自己冒出来）
  /// unverified   没问到答案（连不上 / 超时）⇒ 文件留着，但不放行安装
  /// ```
  /// 注意 [unverified] **不等于放行**：调用方照样返回 null、不安装，只是不删文件。
  ///
  /// [digest] 是 GitHub 给这条资产算的摘要（形如 `sha256:<hex>`）。有它就不用
  /// 发任何网络请求 —— 这正是 CR-04 要的「优先用资产自带 digest」。
  Future<UpdateVerifyResult> verifySha256(
    File file,
    String assetName, {
    required String tag,
    String digest = '',
  }) async {
    // ① 首选：资产自带的摘要，离线就能判 —— 镜像用户没有任何额外网络要求
    final wantFromDigest = sha256FromDigest(digest);
    if (wantFromDigest != null) {
      return verifyFileAgainstSha256(file, wantFromDigest, what: '资产自带的 digest');
    }
    if (tag.isEmpty) return UpdateVerifyResult.mismatch;
    // ② 退回校验表。
    //
    // ★ 取表的路线**一字未改**：仍然只从 [assetUrl]（可信源）取，绝不改写成
    //   镜像地址 —— CR-08 / CWE-494 的牙必须留着：被控镜像若能同时换掉
    //   「表」和「包」，摘要照样对得上，校验就形同虚设。镜像模式下这里依旧
    //   把路线降级成 direct：镜像服务代理的是「一个具体文件」，不提供
    //   校验表这类文本。
    //
    // ★ CR-04 的修复点在**下面那段异常判读**：以前无论哪种失败都返回 false，
    //   调用方于是把已经好好下下来的包删掉，还报「文件校验未通过」。
    final sumsHttp = UpdateHttp(_route.route == UpdateRoute.mirror
        ? _route.copyWith(route: UpdateRoute.direct)
        : _route);
    final sumsUrl = Uri.parse('$assetUrl/$tag/SHA256SUMS.txt');
    String text;
    try {
      text = await sumsHttp.getText(sumsUrl);
    } catch (e) {
      // 「对方答了」和「压根没问到」必须分开（CR-04）：
      // [UpdateHttp.getText] 会把每个候选地址的错误都吞掉，最后统一抛
      // [UpdateNetworkException]，所以要顺着它的 [UpdateNetworkException.cause]
      // 看 —— 里面是 [HttpException] 就说明**可信源明确回答了**（非 200）。
      if (e is UpdateNetworkException && e.cause is HttpException) {
        AppLog.write('UPDATE', '可信源明确回答没有这张校验表（判为校验失败）: $e');
        return UpdateVerifyResult.missingTable;
      }
      // 连不上 / 超时 —— 判「无法判定」，让调用方保留文件（CR-04）
      AppLog.write('UPDATE', '取校验表失败（判为无法判定，不放行也不删包）: $e');
      return UpdateVerifyResult.unverified;
    }
    final want = expectedSha256(parseSha256Sums(text), assetName);
    if (want == null) {
      AppLog.write('UPDATE', '校验表里没有 $assetName ⇒ 判为校验失败');
      return UpdateVerifyResult.mismatch;
    }
    return verifyFileAgainstSha256(file, want, what: 'SHA256SUMS.txt');
  }

  /// 把 GitHub 的资产 `digest` 字段规整成裸的十六进制摘要
  ///
  /// 认的形状：`sha256:<64 位十六进制>`（GitHub 现在的写法），以及裸的
  /// 64 位十六进制。**只认 sha256**：别的算法（sha512…）长度不同，不能被
  /// 当成 sha256 去比对。认不出来（空 / 其它算法 / 长度不对）返回 null ⇒
  /// 退回校验表那条路。
  static String? sha256FromDigest(String raw) {
    final s = raw.trim().toLowerCase();
    if (s.isEmpty) return null;
    var hex = s;
    if (s.startsWith('sha256:')) {
      hex = s.substring('sha256:'.length).trim();
    } else if (s.contains(':')) {
      // 形如 `sha512:…` / `md5:…`：不是 sha256，别猜
      return null;
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hex)) return null;
    return hex;
  }
}
