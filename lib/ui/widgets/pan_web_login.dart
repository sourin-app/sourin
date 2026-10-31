// ═══════════════════════════════════════════════════════════════════════
//  网盘网页登录（W1，2026-10-31）—— WebView2 独立窗口 + cookie 捕获落盘
// ═══════════════════════════════════════════════════════════════════════
//
// # 由来（Owner 2026-10-31 原话）
// ```text
// > 还有这些应该都要支持webview登录回调的，不然如果是在手机上怎么扫码？
// ```
// 扫码登录（pan_qr_login_dialog / pan_settings_page ② 区）要求"用手机扫
// 屏幕上的码"；可本应用就跑在桌面/大屏上，扫码是兜底不是主路。
// 网页登录 = 弹一个真浏览器窗口，用户在里面完成账号密码/短信登录，
// 我们从 WebView2 的 cookie store 里捕获登录态键落盘。
//
// # 链路（选型与批复见 pubspec.yaml 的 desktop_webview_window 注释）
// ```text
// ① WebviewWindow.isWebviewAvailable() 探测 ⇒ 不可用 ⇒ 按钮置灰 + 提示装 Runtime
// ② WebviewWindow.create + launch(登录入口 URL)   （独立原生窗口，关窗 = 取消）
// ③ 每 2 秒 getAllCookies() → 纯函数判据：目标域 + 登录态键全存在
// ④ 命中 ⇒ 拼接 "k=v; …"（只取目标域，同名后到覆盖，注入键丢弃）
//    → SourinCore.callAsync('pan_save_credential', {kind, account, cookie})
//    → Rust pan_login::command_save_credential → pan_auth::save（钥匙串唯一入口）
// ⑤ 成功 ⇒ 关登录窗口、弹窗返回 true；调用方刷新登录状态
// ```
//
// # 判据为什么钉在"键存在"而不是"URL 特征"（Lead 批复附加 ④）
// ```text
// 登录后 URL 千变万化（跳转/风控页/活动页都有可能），按 URL 猜必然漂；
// cookie 键是登录态的**本体**：__pus/__kps（quark/uc 族）、BDUSS（百度）、
// UID/CID/SEID（115）——这些键名同时是 Rust 侧扫码链路的实测基线
// （pan_login.rs：夸克 2026-10-27 真读数 6 键、115 四键验收判据、百度 BDUSS 判据）。
// pre-login 页面本身会种别的键（如 quark/uc 的 ctoken、115 的 acw_tc），
// 已逐家真开页面取证过 ⇒ 那些键**故意不进判据**，否则未登录也会假绿。
// ```
//
// # 四家以外的盘为什么不放（与 Rust 侧 pan_login.rs 注释同一口径）
// ```text
// 天翼     —— 网页态适配未完成，如实报错不动；
// 阿里     —— 网页登录态是 bearer token，从 cookie 映射不出本仓凭据形状；
// 光鸭/迅雷 —— 设备码族，已有自己的登录路；
// 123      —— 走账号密码表单（pan_settings_page 的 123 行）。
// ```

import 'dart:async';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/ffi.dart' show SourinCore, userErrorText;
import '../../design/widgets/app_glass_dialog.dart';
import '../../design/widgets/app_text_button.dart';
import '../tokens.dart';
import 'app_loading.dart';
import 'overlay_motion.dart' show showAppDialog;

// ═══════════════════════════════════════════════════════════════════════
//  每盘配置与判据（纯函数，test/pan_web_login_test.dart 直接单测）
// ═══════════════════════════════════════════════════════════════════════

/// 一家网盘的网页登录配置
///
/// [requiredKeys] 是**登录态键**（判据本体）；只认"目标域上这些键全部存在
/// 且值非空"才算登录成功。
class PanWebLoginSpec {
  const PanWebLoginSpec({
    required this.kind,
    required this.kindName,
    required this.loginUrl,
    required this.cookieDomainSuffix,
    required this.requiredKeys,
  });

  /// 机器可读盘种（与 Rust `PanKind::code()` 同一套词）
  final String kind;
  final String kindName;

  /// 登录窗口打开的入口 URL（2026-10-31 逐家真开页面取证：四家均 HTTP 200 可达）
  final String loginUrl;

  /// 登录态 cookie 的目标域后缀（label 边界匹配，见
  /// [panWebCookieDomainMatches]；取证：quark→.quark.cn、uc→.uc.cn、
  /// baidu→.baidu.com、115→.115.com）
  final String cookieDomainSuffix;

  /// 登录态键（Lead 批复判据逐字：__pus/__kps、BDUSS、UID/CID/SEID）
  final List<String> requiredKeys;

  /// 四家已批复的网页登录（**只有这四家**；其余盘没有条目 ⇒ 不放按钮）
  static const Map<String, PanWebLoginSpec> all = <String, PanWebLoginSpec>{
    'quark': PanWebLoginSpec(
      kind: 'quark',
      kindName: '夸克网盘',
      loginUrl: 'https://pan.quark.cn/',
      cookieDomainSuffix: 'quark.cn',
      requiredKeys: <String>['__pus', '__kps'],
    ),
    'uc': PanWebLoginSpec(
      kind: 'uc',
      kindName: 'UC 网盘',
      loginUrl: 'https://drive.uc.cn/',
      cookieDomainSuffix: 'uc.cn',
      requiredKeys: <String>['__pus', '__kps'],
    ),
    'baidu': PanWebLoginSpec(
      kind: 'baidu',
      kindName: '百度网盘',
      loginUrl:
          'https://passport.baidu.com/v2/?login&u=https%3A%2F%2Fpan.baidu.com%2Fdisk%2Fmain',
      cookieDomainSuffix: 'baidu.com',
      requiredKeys: <String>['BDUSS'],
    ),
    '115': PanWebLoginSpec(
      kind: '115',
      kindName: '115 网盘',
      loginUrl: 'https://www.115.com/',
      cookieDomainSuffix: '115.com',
      requiredKeys: <String>['UID', 'CID', 'SEID'],
    ),
  };

  /// 查某盘的配置；不在四家名单里 ⇒ null（调用方不放入口）
  static PanWebLoginSpec? of(String kind) => all[kind];
}

/// 捕获到的一条 cookie（与 desktop_webview_window 的 WebviewCookie 解耦：
/// 纯函数不依赖插件类型，单测可以直接造夹具）
class CapturedCookie {
  const CapturedCookie({
    required this.domain,
    required this.name,
    required this.value,
  });

  /// cookie 归属域（WebView2 给的形状：'.quark.cn' 或 'pan.quark.cn' 都有可能）
  final String domain;
  final String name;
  final String value;
}

/// WebView2 Runtime 是否可用（设置页/扫码弹窗用它决定"网页登录"按钮的置灰）
///
/// # 为什么是异步探测而不是编译期常量
/// ```text
/// Runtime 是否存在是**机器事实**（Win11 自带、老 Win10 可能没有），
/// 写死任何一个值都是猜。探测失败（插件不可用等异常）按"不可用"处理 ——
/// 如实说，不许把"没探到"当"可用"。
/// ```
Future<bool> panWebviewRuntimeAvailable() async {
  try {
    return await WebviewWindow.isWebviewAvailable();
  } catch (_) {
    return false;
  }
}

/// 域后缀匹配（**label 边界**）
///
/// ```text
/// '.quark.cn' / 'pan.quark.cn' 命中 'quark.cn'；
/// 'evilquark.cn' **不**命中 —— 后缀必须落在域标签边界上
/// （否则拼一个恶意域就能把 cookie 混进目标域，测试有注入证红）。
/// ```
bool panWebCookieDomainMatches(String domain, String suffix) {
  final d = domain.trim().toLowerCase();
  final s = suffix.trim().toLowerCase();
  if (d.isEmpty || s.isEmpty) return false;
  return d == s || d.endsWith('.$s');
}

/// 目标域上的 cookie（多域混入只取目标域）
List<CapturedCookie> panWebTargetDomainCookies(
  List<CapturedCookie> cookies,
  PanWebLoginSpec spec,
) {
  return cookies
      .where((c) => panWebCookieDomainMatches(c.domain, spec.cookieDomainSuffix))
      .toList(growable: false);
}

/// 判据：目标域上 [PanWebLoginSpec.requiredKeys] 全部存在且值非空
///
/// # 为什么值非空也算判据
/// ```text
/// 键在值空 = "见过这个名字"而不是"登录态在手"（与 Rust 侧
/// bduss_from_cookie 对空值不算的口径一致）。
/// ```
bool panWebLoginCaptured(List<CapturedCookie> cookies, PanWebLoginSpec spec) {
  if (spec.requiredKeys.isEmpty) return false;
  final target = panWebTargetDomainCookies(cookies, spec);
  for (final key in spec.requiredKeys) {
    final hit = target.any((c) => c.name.trim() == key && c.value.trim().isNotEmpty);
    if (!hit) return false;
  }
  return true;
}

/// 把目标域 cookie 拼成 `k=v; …`（pan_save_credential 的 `cookie` 入参形状）
///
/// # 三条硬线（测试逐条证红）
/// ```text
/// ① 只取目标域（多域混入丢弃）；
/// ② 同名后到覆盖（与 Rust merge_cookie 同一条语义：登录后下发的键才是新的）；
/// ③ 注入键丢弃：name 含 '=' / ';' / 空白、value 含 ';' / 换行的 cookie
///    会把拼接结果撑破，一律不进串。全被丢弃 ⇒ null（调用方当作没捕获到）。
/// ```
String? panWebBuildCookieString(
  List<CapturedCookie> cookies,
  PanWebLoginSpec spec,
) {
  final target = panWebTargetDomainCookies(cookies, spec);
  final parts = <String, String>{};
  for (final c in target) {
    final name = c.name.trim();
    final value = c.value.trim();
    if (name.isEmpty || value.isEmpty) continue;
    if (name.contains(';') || name.contains('=') || name.contains(' ')) continue;
    if (value.contains(';') || value.contains('\n') || value.contains('\r')) {
      continue;
    }
    parts[name] = '$name=$value'; // 后到覆盖（Map 保持首次插入的位置，值取新）
  }
  if (parts.isEmpty) return null;
  return parts.values.join('; ');
}

// ═══════════════════════════════════════════════════════════════════════
//  UI 链路（独立原生窗口 + Flutter 侧等待弹窗）
// ═══════════════════════════════════════════════════════════════════════

/// 打开网页登录；返回 true = 凭据已落钥匙串（调用方应刷新登录状态）。
///
/// ```text
/// false 的含义与 showPanQrLoginDialog 一致：用户取消 / Runtime 缺失 /
/// 登录窗口打不开 / 保存失败 —— 调用方**不许**据此重试播放。
/// ```
Future<bool> showPanWebLogin(BuildContext context, {required String kind}) async {
  final spec = PanWebLoginSpec.of(kind);
  if (spec == null) return false; // 不在四家名单：不放网页登录（按钮也不该出现）
  if (!await panWebviewRuntimeAvailable()) {
    if (!context.mounted) return false;
    await showAppDialog<void>(
      context: context,
      builder: (_) => const _WebView2MissingDialog(),
    );
    return false;
  }
  if (!context.mounted) return false;
  final Webview webview;
  try {
    webview = await WebviewWindow.create(
      configuration: CreateConfiguration(
        title: '登录${spec.kindName}',
        windowWidth: 1080,
        windowHeight: 800,
      ),
    );
    await webview.launch(spec.loginUrl);
  } catch (e) {
    if (!context.mounted) return false;
    await showAppDialog<void>(
      context: context,
      builder: (dctx) => AppGlassDialog(
        title: '网页登录',
        content: Text(
          userErrorText(e, fallback: '登录窗口打不开，请稍后重试'),
        ),
        actions: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            AppTextButton(
              onPressed: () => Navigator.of(dctx).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
    return false;
  }
  if (!context.mounted) return false;
  final ok = await showAppDialog<bool>(
    context: context,
    builder: (_) => _PanWebLoginWaitingDialog(webview: webview, spec: spec),
  );
  return ok ?? false;
}

/// WebView2 Runtime 缺失的人话提示（Lead 批复附加 ③：不许点了没反应）
class _WebView2MissingDialog extends StatelessWidget {
  const _WebView2MissingDialog();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AppGlassDialog(
      title: '网页登录不可用',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '本机没有可用的 WebView2 运行时（网页登录靠它打开浏览器窗口）。',
            style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurface),
          ),
          const SizedBox(height: Sp.x1),
          Text(
            '请安装 Microsoft Edge WebView2 Runtime 后重启应用：',
            style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurface),
          ),
          const SizedBox(height: Sp.x1),
          SelectableText(
            'https://go.microsoft.com/fwlink/p/?LinkId=2124703',
            style: TextStyle(fontSize: FontSizes.cap, color: colors.primary),
          ),
        ],
      ),
      actions: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          AppTextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}

/// 等待弹窗：登录窗口开着，这里每 2 秒查一次 cookie store
class _PanWebLoginWaitingDialog extends StatefulWidget {
  const _PanWebLoginWaitingDialog({required this.webview, required this.spec});

  final Webview webview;
  final PanWebLoginSpec spec;

  @override
  State<_PanWebLoginWaitingDialog> createState() =>
      _PanWebLoginWaitingDialogState();
}

class _PanWebLoginWaitingDialogState extends State<_PanWebLoginWaitingDialog> {
  Timer? _timer;
  bool _finished = false;
  String _state = '登录窗口已打开：请在弹出的窗口里完成登录，检测到登录态后这里会自动保存';
  String _error = '';

  @override
  void initState() {
    super.initState();
    unawaited(widget.webview.onClose.then((_) => _onWindowClosed()));
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => unawaited(_poll()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// 用户直接关了登录窗口 = 取消
  void _onWindowClosed() {
    if (_finished) return;
    _finished = true;
    _timer?.cancel();
    if (mounted) Navigator.of(context).pop(false);
  }

  Future<void> _poll() async {
    if (_finished) return;
    final List<WebviewCookie> raw;
    try {
      raw = await widget.webview.getAllCookies();
    } catch (_) {
      return; // 单次查询失败不下结论（窗口刚开/正在跳转都可能出现），下一轮继续
    }
    if (_finished) return;
    final cookies = <CapturedCookie>[
      for (final c in raw)
        CapturedCookie(domain: c.domain, name: c.name, value: c.value),
    ];
    if (!panWebLoginCaptured(cookies, widget.spec)) return;

    // 命中判据 ⇒ 拼串落盘（键名+长度只进 Rust 侧日志，值绝不落）
    final cookie = panWebBuildCookieString(cookies, widget.spec);
    if (cookie == null || cookie.isEmpty) return; // 判据过了但拼不出串：等下一轮再看
    _finished = true;
    _timer?.cancel();
    String account = '';
    try {
      final r = await SourinCore.callAsync('pan_save_credential', {
        'kind': widget.spec.kind,
        'account': '',
        'cookie': cookie,
      }) as Map<String, dynamic>;
      account = '${r['account'] ?? ''}';
    } catch (e) {
      if (!mounted) return;
      unawaited(widget.webview.close());
      setState(() {
        _state = '';
        _error = userErrorText(e, fallback: '登录态已拿到，但保存没有完成，请稍后重试');
      });
      return;
    }
    unawaited(widget.webview.close());
    if (!mounted) return;
    setState(() {
      _state = account.isEmpty
          ? '登录成功'
          : '登录成功：$account';
    });
    Navigator.of(context).pop(true);
  }

  void _cancel() {
    if (_finished) {
      Navigator.of(context).pop(false);
      return;
    }
    _finished = true;
    _timer?.cancel();
    unawaited(widget.webview.close());
    Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AppGlassDialog(
      title: '网页登录${widget.spec.kindName}',
      maxWidth: 420,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_state.isNotEmpty) ...[
            Text(
              _state,
              key: const ValueKey<String>('pan-web-login-status'),
              style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurface),
            ),
            const SizedBox(height: Sp.x2),
          ],
          if (_error.isEmpty) ...[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: Sp.x2),
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: AppLoading(),
                ),
              ),
            ),
          ],
          if (_error.isNotEmpty)
            Text(
              _error,
              key: const ValueKey<String>('pan-web-login-error'),
              style: TextStyle(fontSize: FontSizes.cap, color: colors.error),
            ),
        ],
      ),
      actions: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          AppTextButton(
            key: const ValueKey<String>('pan-web-login-cancel'),
            onPressed: _cancel,
            child: const Text('取消登录'),
          ),
        ],
      ),
    );
  }
}