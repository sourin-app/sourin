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
// cookie 键是登录态的**本体**：__pus/__kps（quark/uc 族）、BDUSS（百度）——
// 这些键名同时是 Rust 侧扫码链路的实测基线
// （pan_login.rs：夸克 2026-10-27 真读数 6 键、百度 BDUSS 判据）。
// pre-login 页面本身会种别的键（如 quark/uc 的 ctoken），
// 已逐家真开页面取证过 ⇒ 那些键**故意不进判据**，否则未登录也会假绿。
// ```
//
// # ★★★ 115 为什么被撤掉（2026-11-01，Owner 报"115 网页登录没反应"）
// ```text
// 定性：**这条路架构上不通，不是判据写错、也不是 URL 写错**。
//
// ① 落盘形状过不了 Rust 侧判据（决定性，不依赖键名取证）：
//    csp/pan115.rs:449 is_logged(cookie) => cookie.contains("UID=")
//    （DEX 逐字 [logged]，有测试钉住 is_logged("CID=abc; SEID=xyz") == false）。
//    而网页登录落盘只做 trim + 非空校验（pan_login.rs validate_web_login_credential），
//    **没有任何键名映射** ⇒ 网页会话 cookie 无论叫什么，只要不含 UID=，
//    存进钥匙串后 115 仍然显示"需要先登录" ⇒ "存了却说没登录"的读数说谎。
// ② UID/CID/SEID/KID 的**唯一来源**是扫码换 cookie 的**响应体**，不是浏览器
//    cookie store：pan_login.rs pan115_cookie_from_body 从
//    POST passportapi.115.com/app/1.0/qandroid/1.0/login/qrcode/ 的 JSON 里
//    取出并**拼成字符串**（09:34 日志"4 个键（230 字节）"即此产物）。
// ③ 入口 URL 本身也错（我实测，只读 GET）：https://www.115.com/ 返回 357 字节
//    JS 跳壳页（window.location.href="https://115.com"）；https://115.com/ 是
//    **官网首页**（36KB，title「115科技官网_首页」），登录只是首页上的 JS 弹层，
//    未登录时 window.USER_ID='' —— 与 ui-judge-window 截到的 webview 标题一致。
// ④ 115 网页版登录态键名与域：**未取证到**（服务端 Set-Cookie 下发，须真登录后
//    才能读；我没有 Owner 账号、也不该在空窗开 webview 打扰）⇒ 如实标注，
//    **绝不编造键名**。
// ⇒ 结论：撤掉 115 的网页登录入口，如实说明原因并指路扫码。不硬凑判据。
// ```
//
// # ★★ 两处名单只改了一处（本批已知未同步，靠兜底保证点击有反馈）
// ```text
// 网页登录的"放不放按钮"有**两道闸门**：本文件的 PanWebLoginSpec.all，以及
// lib/ui/widgets/pan_qr_login_dialog.dart:144 那份同名的 _webLoginKinds
// （扫码弹窗里的那颗按钮）。本批**只改了本文件** —— pan_qr_login_dialog.dart
// 不在本批允许改动清单内（他人/W1 在制品边界），故那份名单仍含 '115'。
// 半边改不到 ⇒ 靠 showPanWebLogin 的兜底：spec == null 时**弹如实说明对话框**
// 而不是静默 return false ⇒ 即使扫码弹窗里的那颗按钮还在，点了也有人话反馈，
// 绝不会退回 Owner 报的"点了没反应"。
// ⚠️ 下批需同步：把 pan_qr_login_dialog.dart:144 的 _webLoginKinds 也去掉 '115'
//    （或改成直接读 PanWebLoginSpec.all，两处同一真源，才不会再漂）。
// ```
//
// # 三家以外的盘为什么不放（与 Rust 侧 pan_login.rs 注释同一口径）
// ```text
// 115      —— 见上：网页登录拿不到可保存的凭据（本批从四家撤到三家）；
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
  /// baidu→.baidu.com）
  final String cookieDomainSuffix;

  /// 登录态键（Lead 批复判据逐字：__pus/__kps、BDUSS）
  final List<String> requiredKeys;

  /// ★★ 网页登录的**三家**（2026-11-01 起；115 已撤，原因见本文件头
  /// 「115 为什么被撤掉」与 [panWebLoginUnsupportedReason]）。
  ///
  /// ```text
  /// 剩下三家能用，是因为它们的登录态键**确实是网页版会话 cookie**：
  ///   quark/uc 的 __pus/__kps、百度的 BDUSS，都是登录后由服务端 Set-Cookie
  ///   种在对应域上的真键名（已逐家取证，不是照搬扫码协议产物）。
  /// ```
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
  };

  /// 查某盘的配置；不在三家名单里 ⇒ null（调用方不放入口）
  static PanWebLoginSpec? of(String kind) => all[kind];

  /// ★★ 网页登录**撤掉**的盘 → 撤掉的原因（人话，必须指路替代方案）
  ///
  /// ```text
  /// 返回 null = 这家仍可用网页登录（或不在这套体系里，由调用方自行判断）。
  /// 返回非空 = 这家**没有**网页登录 ⇒ 调用方**不许**放按钮，且要把这句
  ///            原样显示给用户（"撤 ≠ 消失"：只有"未登录"两个字是假入口，
  ///            用户不知道该干嘛）。
  ///
  /// 文案三条硬线（测试逐条钉）：
  ///   ① 说清**为什么**（凭据形状对不上，不是"不支持"这种空话）；
  ///   ② 说清**该用哪条路**（指路扫码 —— 含"扫码"二字）；
  ///   ③ 不许出现"请稍后重试"这类把责任推给时间的空话。
  /// ```
  static String? panWebLoginUnsupportedReason(String kind) {
    switch (kind) {
      case '115':
        return '115 网盘不支持网页登录：它的登录态（UID/CID/SEID/KID）由扫码协议'
            '从服务端下发，网页 cookie 里拿不到可保存的凭据'
            '（即使存进去也会被判为未登录）⇒ 请用扫码登录。';
      default:
        return null;
    }
  }

  /// 被撤掉的盘（调用方用它决定"不放按钮 + 显示原因"）
  static bool panWebLoginRetired(String kind) =>
      panWebLoginUnsupportedReason(kind) != null;
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

/// 目标域上**还缺哪几个**登录态键（全齐 ⇒ 空表）
///
/// # 为什么要有它（修静默的本体）
/// ```text
/// 旧行为：判据不过就 return，弹窗只剩下转圈 —— Owner 看到的"登录完了没反应"
/// 正是这个形态（ui-judge-window 07:00:53→07:06 零错误行、一直转圈）。
/// 要给出**可行动**的反馈，就得说清"差哪个"，而不是"再等等"。
/// 键名只取自 spec.requiredKeys（客观事实）—— 取证不到的键**不会**出现在这里，
/// 所以不存在编造键名的路径。
/// ```
List<String> panWebLoginMissingKeys(
  List<CapturedCookie> cookies,
  PanWebLoginSpec spec,
) {
  final target = panWebTargetDomainCookies(cookies, spec);
  final missing = <String>[];
  for (final key in spec.requiredKeys) {
    final hit = target.any((c) => c.name.trim() == key && c.value.trim().isNotEmpty);
    if (!hit) missing.add(key);
  }
  return missing;
}

/// 目标域上**已经拿到**的 cookie 键数（用于"窗户里其实什么都没有"的判断）
int panWebLoginTargetCookieCount(
  List<CapturedCookie> cookies,
  PanWebLoginSpec spec,
) =>
    panWebTargetDomainCookies(cookies, spec).length;

/// "还没检测到登录态"的人话（**可行动**，不许只说"再等等"）
///
/// ```text
/// 三条硬线（测试逐条钉）：
///   ① 说清**等多久了**（waitedSeconds）—— 让用户知道程序在干活、不是死了；
///   ② 说清**在哪等**：{盘名} 的登录态 cookie 在 {域} 上（客观事实，取自 spec）；
///   ③ 说清**差什么**：还缺 K1/K2（取自 spec.requiredKeys，不编造）；
///      目标域上一个 cookie 都没有 ⇒ 改说"当前在该域上还没有拿到任何 cookie"，
///      这多半意味着**根本没进登录页 / 没登录成功**（115 那次就是这类）。
/// ```
String panWebLoginNotDetectedHint(
  PanWebLoginSpec spec,
  List<String> missingKeys, {
  required int waitedSeconds,
}) {
  final domain = spec.cookieDomainSuffix;
  final waited = waitedSeconds <= 0 ? 0 : waitedSeconds;
  final head = '还没检测到登录态（已等待 ${waited}s）：请确认已在弹出的窗口里完成登录。';
  final where = '${spec.kindName}的登录态 cookie 应在 $domain 域上。';
  if (missingKeys.isEmpty) {
    return '$head$where';
  }
  return '$head$where当前还缺：${missingKeys.join('/')}。';
}

/// 目标域上一条 cookie 都没有时的补充提示（多半是"压根没进登录页"）
String panWebLoginNoCookieHint(PanWebLoginSpec spec) =>
    '当前在 ${spec.cookieDomainSuffix} 域上还没有拿到任何 cookie '
    '⇒ 多半是登录窗口还没进入登录页（或登录没成功）。'
    '请回到窗口里确认页面是否已登录，或取消后用其它方式登录。';

/// 超时终态的人话（**停止 + 明确下一步**，不许停了还让人猜）
String panWebLoginTimeoutHint(PanWebLoginSpec spec, List<String> missingKeys) {
  final miss = missingKeys.isEmpty ? '' : '（最后仍缺：${missingKeys.join('/')}）';
  return '已等待 ${panWebLoginTimeout.inSeconds}s 仍未检测到${spec.kindName}的登录态$miss。'
      '本次网页登录已停止：请取消后确认登录窗口内是否真的完成了登录，'
      '或改用「扫码登录」。';
}

/// 网页登录的**等待上限**（超过 ⇒ 给终态错误并停表，不许无限转圈）
const Duration panWebLoginTimeout = Duration(seconds: 90);

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
///
/// # ★★★ spec == null 时**不许静默 return false**
/// ```text
/// 旧行为：`if (spec == null) return false;` —— 调用方拿到 false 什么都不做
/// ⇒ 用户看到的就是"点了没反应"（Owner 报的正是这个形态）。
/// 现行为：弹一个如实说明为什么没有网页登录 + 指路替代方案的对话框
/// ⇒ 即使别处（pan_qr_login_dialog.dart:144 那份名单）还给这家画了按钮，
///   点了也一定有人话反馈。撤功能 ≠ 点了没反应。
/// ```
Future<bool> showPanWebLogin(BuildContext context, {required String kind}) async {
  final spec = PanWebLoginSpec.of(kind);
  if (spec == null) {
    final reason = PanWebLoginSpec.panWebLoginUnsupportedReason(kind);
    if (reason != null && context.mounted) {
      await showAppDialog<void>(
        context: context,
        builder: (_) => _PanWebLoginUnsupportedDialog(reason: reason),
      );
    }
    return false; // 不在三家名单：不放网页登录（按钮也不该出现）
  }
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

/// 这家**没有**网页登录（如 115）⇒ 点了也要给一句人话 + 指路，不许静默
class _PanWebLoginUnsupportedDialog extends StatelessWidget {
  const _PanWebLoginUnsupportedDialog({required this.reason});

  final String reason;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AppGlassDialog(
      title: '没有网页登录',
      content: Text(
        reason,
        key: const ValueKey<String>('pan-web-login-unsupported'),
        style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurface),
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
  String _hint = '';
  final Stopwatch _waited = Stopwatch();

  @override
  void initState() {
    super.initState();
    _waited.start();
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
    _waited.stop();
    _timer?.cancel();
    if (mounted) Navigator.of(context).pop(false);
  }

  /// 超时 ⇒ **停表 + 终态错误 + 明确下一步**（不许无限转圈让人猜）
  void _onTimeout(List<String> missing) {
    _finished = true;
    _waited.stop();
    _timer?.cancel();
    unawaited(widget.webview.close());
    if (!mounted) return;
    setState(() {
      _state = '';
      _hint = '';
      _error = panWebLoginTimeoutHint(widget.spec, missing);
    });
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

    final waited = _waited.elapsed;
    final missing = panWebLoginMissingKeys(cookies, widget.spec);
    if (waited >= panWebLoginTimeout) {
      _onTimeout(missing);
      return;
    }

    if (!panWebLoginCaptured(cookies, widget.spec)) {
      // ★ 修静默：等过一小会儿还没捕获 ⇒ 如实说"还没检测到 + 在哪等 + 差什么"
      if (!mounted) return;
      setState(() {
        _state = '登录窗口已打开：请在弹出的窗口里完成登录';
        _hint = panWebTargetDomainCookies(cookies, widget.spec).isEmpty
            ? panWebLoginNoCookieHint(widget.spec)
            : panWebLoginNotDetectedHint(
                widget.spec,
                missing,
                waitedSeconds: waited.inSeconds,
              );
      });
      return;
    }

    // 命中判据 ⇒ 拼串落盘（键名+长度只进 Rust 侧日志，值绝不落）
    final cookie = panWebBuildCookieString(cookies, widget.spec);
    if (cookie == null || cookie.isEmpty) {
      // ★ 旧行为是静默 return（永远转圈）；现在如实说拼不出来
      if (!mounted) return;
      setState(() {
        _hint = '已在 ${widget.spec.cookieDomainSuffix} 域上看到登录态键，'
            '但拼不出可保存的 cookie 串（键名/值含分隔符）⇒ 本次不保存。'
            '请取消后用「扫码登录」。';
      });
      return;
    }
    _finished = true;
    _waited.stop();
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
        _hint = '';
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
      _hint = '';
    });
    Navigator.of(context).pop(true);
  }

  void _cancel() {
    _waited.stop();
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
          if (_hint.isNotEmpty)
            Text(
              _hint,
              key: const ValueKey<String>('pan-web-login-hint'),
              style:
                  TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
            ),
          if (_state.isNotEmpty) const SizedBox(height: Sp.x2),
          // ★ 转圈只在**还没到终态**时出现：有错误/超时还转 = 假象（"还在干活"）
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
            child: Text(_error.isEmpty ? '取消登录' : '关闭'),
          ),
        ],
      ),
    );
  }
}