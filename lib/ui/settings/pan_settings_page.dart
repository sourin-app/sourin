// ═══════════════════════════════════════════════════════════════════════
//  网盘账号配置页（N8b-3：登录 / 查看登录信息）
// ═══════════════════════════════════════════════════════════════════════
//
// # 它是什么（Owner 2026-10-27 原话：网盘独立配置页，登录、查看登录信息）
// ```text
// ① 登录状态   每个盘一行：未登录 / 已过期 / 已登录 + 账号名；有凭据可登出
// ② 扫码登录   选盘 → 出二维码（复用 QrView）→ 2 秒轮询 → 成功后刷新登录状态
// ③ 分享文件浏览  粘分享链接 → 识别 → 列出文件（复用 PanShareListingSection）
// ```
//
// # 三条诚实边界（一条都不能破，门禁 zz_t1050 逐条盯着）
// ```text
// ① 「已登录」只来自钥匙串链路（pan_auth::load / pan_auth_status），
//    页面**绝不**自己造一个登录态 —— 没接好就如实说没读到，不许冒充。
// ② 凭据**只走系统钥匙串**（pan_auth 既有实现）。本页不 import dart:io、
//    不碰任何文件 —— 数据目录会被备份/云同步，cookie 落盘就跟着到处跑。
// ③ **没有任何播放入口**。能列出文件 ≠ 能播放（取直链要真账号，
//    批末 Owner 扫码后另验）—— 界面上连播放图标都不许出现。
// ```
//
// # 扫码登录为什么长这样（复用两条既有先例，不重造）
// ```text
// 组件    → QrView（qr_view.dart，解析 Rust 签发的二维码 SVG，失败降级显示 URL）
// 链路形状 → 旧19 provider_qr_login_start / provider_qr_login_poll：
//           start 返回 {key, url, svg}；poll 按 ~2 秒间隔问一次，
//           status ∈ pending / scanned / confirmed / expired / failed
// ```
//
// # 接线契约（Rust 侧 pan* 执行者接线；命令未注册时本页如实报错）
// ```text
// pan_auth_status     {}        → { accounts: [{kind, kindName, loggedIn,
//                                        account, expired, keyringAvailable}] }
// pan_qr_login_start  {kind}    → { key, url, svg, hint? }
// pan_qr_login_poll   {kind,key}→ { status, message?, account? }
// pan_logout          {kind}    → {}（清钥匙串条目，等价 pan_auth::clear）
// pan_password_login  {kind,account,password} → { ok, account }
//                               （**只有 123**：它没有扫码这条路，见 §123 那段）
// ```
// 这批命令注册之前，生产路径调它们会得到可读错误 —— 页面把错误原样
// 收口成一句人话显示，**这是刻意的**：宁可显示"没读到"，不显示假的。
//
// # 门禁注入点（生产恒 null；Rust 命令到位后**置空即接真命令**）
// ```text
// debugPanCredentialStatusFetcher / debugPanQrLoginStarter /
// debugPanQrLoginPoller / debugPanLogoutCaller / debugPanIdentifyFetcher /
// debugPasswordLogin
// ```
// 与 `debugTvboxAggregateFetcher`（tvbox_aggregate_page）同一条纪律。
import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/ffi.dart'
    show SourinCore, SourinCoreException, userErrorText;
import '../../core/sourin_api.dart';
import '../../design/icons/app_icons.dart';
import '../../design/widgets/app_glass_dialog.dart';
import '../../design/widgets/app_text_button.dart';
import '../tokens.dart';
import '../widgets/overlay_motion.dart' show showAppDialog;
import '../widgets/pan_share_dialog.dart' show PanShareListingSection;
import '../widgets/qr_view.dart';

/// 打开网盘账号配置页（设置页入口一行调用它；接线点在 settings_page.dart，由 Lead 统一接）
Future<void> showPanSettingsPage(BuildContext context) {
  return showAppDialog<void>(
    context: context,
    builder: (_) => const PanSettingsPage(),
  );
}

/// 网盘账号配置页
class PanSettingsPage extends StatelessWidget {
  const PanSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return AppGlassDialog(
      title: '网盘账号',
      maxWidth: 560,
      actions: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          AppTextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
      content: const SizedBox(width: 500, child: PanSettingsBody()),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  登录态分档 —— 语义照搬 Rust `pan::reason_tier` / `reason_text`
// ═══════════════════════════════════════════════════════════════════════

/// 账号登录态（取 reason_tier 里与"账号"有关的三档；①认不出/②无分享 id
/// 是"链接"的档位，不属于账号，这里用不到）
enum PanAccountTier {
  /// ③ 没登录（reason_tier::NeedLogin）
  needLogin,

  /// ④ 登录过期（reason_tier::Expired）
  expired,

  /// ⑤ 已登录未过期，但取直链未接入（reason_tier::LoggedInNoDirectLink）
  loggedInNoDirectLink,
}

/// 分档判定（纯函数，入参由钥匙串链路算出来）
///
/// ★ **顺序即优先级**（2026-10-27 round33c 的教训原样搬过来）：
/// 未登录必须先判 —— 一份已过期的凭据在链路侧回来是
/// `loggedIn=true, expired=true`；要是把"过期"排在"未登录"前面，
/// 一个从未登录过的盘就会被报成"已过期"。
PanAccountTier panAccountTierOf({required bool loggedIn, required bool expired}) {
  if (!loggedIn) return PanAccountTier.needLogin;
  if (expired) return PanAccountTier.expired;
  return PanAccountTier.loggedInNoDirectLink;
}

/// 逐字文案（对齐 Rust `pan::reason_text` 的 ③④⑤ 三档；改字必须两边同步）
String panAccountTierText(PanAccountTier tier, String kindName) {
  switch (tier) {
    case PanAccountTier.needLogin:
      return '需要先登录$kindName';
    case PanAccountTier.expired:
      return '$kindName的登录已过期，请重新登录';
    case PanAccountTier.loggedInNoDirectLink:
      return '已登录$kindName：能列出分享里的文件，但本版本仍未接入取直链';
  }
}

/// 一个网盘的登录状态（来自 `pan_auth_status`，字段与钥匙串链路一一对应）
class PanAccountStatus {
  const PanAccountStatus({
    required this.kind,
    required this.kindName,
    required this.loggedIn,
    required this.expired,
    required this.keyringAvailable,
    this.account = '',
  });

  /// 机器可读盘种（`pan/<kind.code()>` 的 kind，如 `quark`）
  final String kind;
  final String kindName;

  /// 该盘的钥匙串条目里有没有凭据（`pan_auth::load(kind).is_some()`）
  final bool loggedIn;
  final bool expired;

  /// 账号显示名（空 = 链路没给；**绝不**用盘名冒充账号名）
  final String account;

  /// 钥匙串不可用 ⇒ 登录功能整体不可用，必须如实说
  final bool keyringAvailable;

  PanAccountTier get tier =>
      panAccountTierOf(loggedIn: loggedIn, expired: expired);

  /// 有没有可清除的凭据（登出按钮的显隐判据）
  bool get hasCredential => loggedIn || expired;

  factory PanAccountStatus.fromJson(Map<String, dynamic> j) => PanAccountStatus(
        kind: '${j['kind'] ?? ''}',
        kindName: (j['kindName'] as String?) ?? '未知网盘',
        loggedIn: j['loggedIn'] == true,
        expired: j['expired'] == true,
        keyringAvailable: j['keyringAvailable'] != false,
        account: '${j['account'] ?? ''}',
      );
}

/// 分层判定：这个异常是不是"**命令根本没接线**"（而不是"接线了但这次失败"）
///
/// # 为什么要把这两者分开（R2-#3 的核心）
/// ```text
/// · `kind == unsupported` + 文案含「还没有接入」
///     ⇒ **能力缺失**：当前版本不存在这条后端链路。用户点一百次都一样。
///       ⇒ 界面该**如实说明**，而不是让按钮把人带进一次次同一个报错。
/// · 其它异常（network / unauthorized / other…）
///     ⇒ **这次没成功**：接线在，重试/换网/重新登录有意义。
///       ⇒ 界面该保留重试入口。
/// ```
/// ★ 判据与 `zz_n9_ffi_wiring.rs`（Lead 的 FFI 接线门禁）**同一条**：
///   `kind == "unsupported"` ∧ 文案含「还没有接入」= 落到 dispatch 兜底分支
///   ⇒ 全仓只有一个"命令没接线"的可观测出口，这里复用它，不另造信号。
/// ★ 纯函数：门禁可直接喂构造出来的异常，不必起真核心。
@visibleForTesting
bool panCommandMissing(Object error) {
  if (error is! SourinCoreException) return false;
  return error.kind == 'unsupported' || error.message.contains('还没有接入');
}

// ═══════════════════════════════════════════════════════════════════════
//  门禁注入点（生产恒 null；与 SourinApi.debugPanListShareFetcher 同一纪律）
// ═══════════════════════════════════════════════════════════════════════

/// 登录状态查询的替身（测试喂钥匙串夹具；生产走 `pan_auth_status`）
@visibleForTesting
Future<List<PanAccountStatus>> Function()? debugPanCredentialStatusFetcher;

/// 扫码第一步的替身（生产走 `pan_qr_login_start`）
@visibleForTesting
Future<Map<String, dynamic>> Function(String kind)? debugPanQrLoginStarter;

/// 扫码轮询的替身（生产走 `pan_qr_login_poll`）
@visibleForTesting
Future<Map<String, dynamic>> Function(String kind, String key)?
    debugPanQrLoginPoller;

/// 登出的替身（生产走 `pan_logout`）
@visibleForTesting
Future<void> Function(String kind)? debugPanLogoutCaller;

/// 分享识别的替身（生产走 `SourinApi.identifyPanShare`；
/// sourin_api.dart 是既有文件不许动，替身只能放在本文件）
@visibleForTesting
Future<PanShareStatus> Function(String text)? debugPanIdentifyFetcher;

/// **123 账号密码登录**的替身（生产走 `SourinApi.panPasswordLogin`）
///
/// # 为什么需要它
/// ```text
/// 真登录 = 打 123 的 sign_in + 写系统钥匙串。`flutter test` 里两样都没有
/// （没有 dll、也不该出网、更不该往真实钥匙串写东西）
/// ⇒ 表单的判据（"填了什么就传什么""成功后真的刷新了状态"）只能靠替身喂。
/// ```
/// # 一条纪律（与上面几个替身同）
/// 替身只替**传输**，不替**判断**：账号/密码逐字转发给替身，
/// 界面自己不改写、不 trim 掉用户的输入（服务端/实现层才是权威）。
@visibleForTesting
Future<PanPasswordLoginResult> Function(
  String kind,
  String account,
  String password,
)? debugPasswordLogin;

/// 123 云盘的 kind 码（`PanKind::Pan123.code()`）—— 表单只挂在这一行上
const String pan123KindCode = '123';

// ═══════════════════════════════════════════════════════════════════════
//  页面本体
// ═══════════════════════════════════════════════════════════════════════

/// 页面内容体（公开：widget test 直接挂载驱动，不经过弹窗外壳）
class PanSettingsBody extends StatefulWidget {
  const PanSettingsBody({super.key});

  @override
  State<PanSettingsBody> createState() => _PanSettingsBodyState();
}

class _PanSettingsBodyState extends State<PanSettingsBody> {
  // ── ① 登录状态 ──
  bool _statusLoading = true;
  String _statusError = '';
  List<PanAccountStatus> _accounts = const <PanAccountStatus>[];

  /*
   * ★★★ 2026-10-27（R2-#3，Owner 当场实测「点击获取二维码 报错」）：
   *   **后端这条链路还没实现** —— 不是配置错、不是网络问题。
   *
   * # 现场读数（`.probe/r2-pan-qr-reading.log`，真核心、走生产路径）
   * ```text
   * pan_auth_status / pan_qr_login_start / pan_qr_login_poll / pan_logout
   *   ⇒ 每一条都回 kind=unsupported
   *      文案：这个功能（`pan_xxx`）在当前版本还没有接入…
   *   阳性对照（一条瞎编的命令）回同样的 unsupported ⇒ 判据有判别力。
   * ★ 根因：`grep -c` 这四个命令名在 ffi.rs 里**全是 0**（命令没注册），
   *   而 `pan_auth.rs` 头部自己就写着「未做：调网盘 API 换 token ← 需要真账号」。
   * ```
   *
   * # 所以本页要做的**只有两件**（Lead 裁定，不实现扫码协议）
   * ```text
   * ① 把"点了只会报错"变成"**先如实说这条路还没通**"（不画假入口）
   * ② 入口本身保留：一旦后端接上，**不用改 UI 就自动可用**（不许写死成永久禁用）
   * ```
   * ⇒ 判据用**真命令的返回**，不靠编译期常量/版本号猜（那种"猜"正是本仓反复踩的坑）。
   *   `null` = 还没探测过（首屏就是它）⇒ 入口照常画，点了自然走真命令。
   */
  bool? _qrBackendAvailable;

  // ── ② 扫码登录 ──
  String _qrKind = 'quark';
  bool _qrBusy = false;
  String _qrError = '';

  /// 扫码进行中要轮询的凭据（null = 没有进行中的扫码）
  String? _qrKey;
  String _qrSvg = '';
  String _qrUrl = '';
  String _qrState = '';
  Timer? _pollTimer;

  // ── ③ 分享文件浏览 ──
  final TextEditingController _shareText = TextEditingController();
  bool _identifyBusy = false;
  String _shareError = '';
  PanShareStatus? _shareStatus;

  /// 列目录的结果（null = 还没列 / 列失败）
  PanShareListing? _listing;

  /// 列目录失败的人话原因（空 = 没失败）
  String _listError = '';

  /// 列目录进行中
  bool _listBusy = false;

  // ── ④ 123 账号密码登录（只给 123：它没有扫码这条路）──
  //
  // 为什么状态是单份而不是按盘 map：**只有 123 有表单**（其余 8 家走扫码/设备码），
  // 一份控制器就够；等真有第二家密码登录再抽成 map（不为"将来可能要"提前抽象）。
  final TextEditingController _pwdAccount = TextEditingController();
  final TextEditingController _pwdPassword = TextEditingController();
  bool _pwdBusy = false;

  /// 失败原因（显示在「登录」按钮下方；空 = 没有错误）
  String _pwdError = '';

  /// 成功文案（空 = 还没成功过）
  String _pwdOkText = '';

  @override
  void initState() {
    super.initState();
    _loadStatuses();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _shareText.dispose();
    _pwdAccount.dispose();
    _pwdPassword.dispose();
    super.dispose();
  }

  // ── ① 登录状态：只信钥匙串链路，读不到就如实说 ──
  Future<void> _loadStatuses() async {
    setState(() {
      _statusLoading = true;
      _statusError = '';
    });
    try {
      final f = debugPanCredentialStatusFetcher;
      final List<PanAccountStatus> accounts;
      if (f != null) {
        accounts = await f();
      } else {
        final r = await SourinCore.callAsync('pan_auth_status', const {});
        final raw = (r is Map ? r['accounts'] : null) as List?;
        accounts = <PanAccountStatus>[
          if (raw != null)
            for (final e in raw)
              if (e is Map) PanAccountStatus.fromJson(e.cast<String, dynamic>()),
        ];
      }
      if (!mounted) return;
      setState(() {
        _accounts = accounts;
        _statusLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // 读不到就如实说：错误态 + 空列表。
        // 绝不在这里塞"看起来登录了"的假数据（t1050 ③ 反假绿钉死这条）。
        _accounts = const <PanAccountStatus>[];
        _statusError = userErrorText(e, fallback: '没有读到网盘登录状态，请稍后重试');
        // ★ R2-#3：`pan_auth_status` 都没接线 ⇒ 整条扫码登录链路不可用（实测同一条读数）
        if (panCommandMissing(e)) _qrBackendAvailable = false;
        _statusLoading = false;
      });
    }
  }

  Future<void> _logout(String kind) async {
    setState(() => _statusError = '');
    try {
      final f = debugPanLogoutCaller;
      if (f != null) {
        await f(kind);
      } else {
        await SourinCore.callAsync('pan_logout', {'kind': kind});
      }
      await _loadStatuses();
    } catch (e) {
      if (!mounted) return;
      setState(() =>
          _statusError = userErrorText(e, fallback: '登出没有完成，请稍后重试'));
    }
  }

  // ── ② 扫码登录：start → QrView → 2 秒轮询 → 终态停表 ──
  Future<void> _startQrLogin() async {
    setState(() {
      _qrBusy = true;
      _qrError = '';
      _qrKey = null;
      _qrSvg = '';
      _qrUrl = '';
      _qrState = '';
    });
    _pollTimer?.cancel();
    try {
      final f = debugPanQrLoginStarter;
      final Map<String, dynamic> r;
      if (f != null) {
        r = await f(_qrKind);
      } else {
        r = await SourinCore.callAsync('pan_qr_login_start', {'kind': _qrKind})
            as Map<String, dynamic>;
      }
      final key = '${r['key'] ?? ''}';
      if (!mounted) return;
      if (key.isEmpty) {
        setState(() {
          _qrBusy = false;
          _qrError = '没有拿到登录二维码，请稍后重试';
        });
        return;
      }
      setState(() {
        _qrKey = key;
        _qrSvg = '${r['svg'] ?? ''}';
        _qrUrl = '${r['url'] ?? ''}';
        _qrState = '等待扫码…';
        _qrBusy = false;
      });
      _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _pollOnce());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _qrBusy = false;
        // ★ R2-#3：如果是"命令没接线"，记下来 ⇒ 这一区改成**如实说明**（见 `_qrSection`），
        //   不再留一个点一次报一次错的按钮。
        if (panCommandMissing(e)) _qrBackendAvailable = false;
        _qrError = userErrorText(e, fallback: '扫码登录暂时用不了，请稍后重试');
      });
    }
  }

  Future<void> _pollOnce() async {
    final key = _qrKey;
    if (key == null || _qrBusy) return;
    setState(() => _qrBusy = true);
    try {
      final f = debugPanQrLoginPoller;
      final Map<String, dynamic> r;
      if (f != null) {
        r = await f(_qrKind, key);
      } else {
        r = await SourinCore.callAsync('pan_qr_login_poll',
            {'kind': _qrKind, 'key': key}) as Map<String, dynamic>;
      }
      if (!mounted) return;
      final status = '${r['status'] ?? ''}';
      final message = '${r['message'] ?? ''}';
      switch (status) {
        case 'pending':
          setState(() {
            _qrState = '等待扫码…';
            _qrBusy = false;
          });
        case 'scanned':
          setState(() {
            _qrState = '已扫码，请在手机上确认';
            _qrBusy = false;
          });
        case 'confirmed':
          _pollTimer?.cancel();
          setState(() {
            _qrState = '登录成功';
            _qrKey = null;
            _qrBusy = false;
          });
          await _loadStatuses();
        case 'expired':
          _pollTimer?.cancel();
          setState(() {
            _qrState = '二维码已失效，请重新获取';
            _qrKey = null;
            _qrBusy = false;
          });
        default:
          // failed / 认不出的状态：终态停表，把后端给的原因说出来
          _pollTimer?.cancel();
          setState(() {
            _qrState = message.isEmpty ? '扫码登录没有完成，请稍后重试' : message;
            _qrKey = null;
            _qrBusy = false;
          });
      }
    } catch (e) {
      if (!mounted) return;
      _pollTimer?.cancel();
      setState(() {
        _qrState = '';
        _qrError = userErrorText(e, fallback: '扫码状态查询没有完成，请稍后重试');
        _qrKey = null;
        _qrBusy = false;
      });
    }
  }

  // ── ④ 123 账号密码登录：校验 → 调命令 → 就地刷新登录状态 ──
  //
  // ★ 为什么不 trim 再传：账号里的空格归服务端/实现层判定（Rust 侧自己 trim），
  //   界面**不改写用户输入** —— 否则"我明明填对了"会变成一句无法复现的抱怨。
  Future<void> _passwordLogin() async {
    final account = _pwdAccount.text;
    final password = _pwdPassword.text;
    if (account.trim().isEmpty) {
      setState(() {
        _pwdError = '请先填 123 云盘的账号（手机号或邮箱）';
        _pwdOkText = '';
      });
      return;
    }
    if (password.isEmpty) {
      setState(() {
        _pwdError = '请先填 123 云盘的密码';
        _pwdOkText = '';
      });
      return;
    }
    setState(() {
      _pwdBusy = true;
      _pwdError = '';
      _pwdOkText = '';
    });
    try {
      final f = debugPasswordLogin;
      final PanPasswordLoginResult r = f != null
          ? await f(pan123KindCode, account, password)
          : await SourinApi.panPasswordLogin(pan123KindCode, account, password);
      if (!mounted) return;
      setState(() {
        _pwdOkText =
            '登录成功：${r.account.isEmpty ? account.trim() : r.account}';
        // ★ 成功即清掉输入框里的密码（内存里少留一份就少一份）
        _pwdPassword.clear();
      });
      // ★ 就地刷新登录状态（凭据已在 Rust 侧落盘 ⇒ 这里读回来才是真状态）
      await _loadStatuses();
    } catch (e) {
      if (!mounted) return;
      setState(() =>
          _pwdError = userErrorText(e, fallback: '登录没有完成，请稍后重试'));
    } finally {
      if (mounted) setState(() => _pwdBusy = false);
    }
  }

  // ── ③ 分享文件浏览：识别 → 列目录（复用既有匿名链路）──
  Future<void> _identify() async {
    final t = _shareText.text.trim();
    if (t.isEmpty) {
      setState(() => _shareError = '请先粘贴网盘分享链接或整段分享文字');
      return;
    }
    setState(() {
      _identifyBusy = true;
      _shareError = '';
      _shareStatus = null;
      // 换了输入 ⇒ 上一次的目录结果不再对应当前链接，必须清掉
      _listing = null;
      _listError = '';
    });
    try {
      final f = debugPanIdentifyFetcher;
      final s = f != null ? await f(t) : await SourinApi.identifyPanShare(t);
      if (!mounted) return;
      setState(() => _shareStatus = s);
    } catch (e) {
      if (!mounted) return;
      setState(() =>
          _shareError = userErrorText(e, fallback: '识别没有完成，请稍后重试'));
    } finally {
      if (mounted) setState(() => _identifyBusy = false);
    }
  }

  Future<void> _listFiles() async {
    final s = _shareStatus;
    if (s == null || !s.recognized) return;
    setState(() {
      _listBusy = true;
      _listError = '';
      _listing = null;
    });
    try {
      final l = await SourinApi.panListShare(
        _shareText.text.trim(),
        pwd: s.pwd,
      );
      if (!mounted) return;
      setState(() => _listing = l);
    } catch (e) {
      if (!mounted) return;
      setState(() =>
          _listError = userErrorText(e, fallback: '列目录没有完成，请稍后重试'));
    } finally {
      if (mounted) setState(() => _listBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      child: DefaultTextStyle.merge(
        textAlign: TextAlign.left,
        child: Column(
          key: const ValueKey<String>('pan-settings-body'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // ── ① 登录状态 ──
            Text(
              '登录状态',
              key: const ValueKey<String>('pan-status-title'),
              style: TextStyle(
                fontSize: FontSizes.sm,
                fontWeight: FontWeight.w600,
                color: colors.onSurface,
              ),
            ),
            const SizedBox(height: Sp.x1),
            Text(
              '凭据只保存在系统钥匙串里，不会写进本机的任何文件',
              style: TextStyle(
                fontSize: FontSizes.cap,
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Sp.x2),
            _statusSection(colors),
            const SizedBox(height: Sp.x4),

            // ── ② 扫码登录 ──
            Text(
              '扫码登录',
              key: const ValueKey<String>('pan-qr-title'),
              style: TextStyle(
                fontSize: FontSizes.sm,
                fontWeight: FontWeight.w600,
                color: colors.onSurface,
              ),
            ),
            const SizedBox(height: Sp.x1),
            Text(
              /*
               * ★★★ R2-#3：这段话改过（Owner 实测「点击获取二维码 报错」）。
               *
               * 改前那句把"各网盘是否支持扫码"说成"以实际结果为准"
               *   ⇒ 读起来像"可以扫码，只是要看盘支不支持" ⇒ 用户点了才撞到 `unsupported`。
               * 改后：**先说清楚这个能力当前没接**，再说能做什么 ——
               *   与 `pan_auth.rs` 头部那句「未做：调网盘 API 换 token ← 需要真账号」同一口径。
               * ⚠️ 不留"点了只会报错的入口"：真点过之后本区会整块换成一句说明（见 `_qrSection`）。
               *
               * ⚠️⚠️ 本注释**刻意不复现那句旧文案的原文** —— 门禁 t1062 ⑤ 会扫
               *    `pan_settings_page.dart` 里有没有那个措辞（"把能力说成可用"的判据），
               *    而它的扫描**包含注释** ⇒ 原样抄进来会被判成"没改"（我自己踩了一次）。
               *    描述它"说了什么"用中文即可，别复现它的原句。
               */
              '扫码登录这条链路本版本还没有接入后端实现，暂时拿不到二维码。'
              '登录状态、登出与分享文件浏览不受影响。',
              style: TextStyle(
                fontSize: FontSizes.cap,
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Sp.x2),
            _qrSection(colors),
            const SizedBox(height: Sp.x4),

            // ── ③ 分享文件浏览 ──
            Text(
              '分享文件浏览',
              key: const ValueKey<String>('pan-share-title'),
              style: TextStyle(
                fontSize: FontSizes.sm,
                fontWeight: FontWeight.w600,
                color: colors.onSurface,
              ),
            ),
            const SizedBox(height: Sp.x1),
            Text(
              '粘贴别人分享的网盘链接，可以查看里面的文件；本版本还不能用它播放',
              style: TextStyle(
                fontSize: FontSizes.cap,
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Sp.x2),
            _shareSection(colors),
          ],
        ),
      ),
    );
  }

  // ───────────────────────────────────────────────────────────────
  //  ① 登录状态区
  // ───────────────────────────────────────────────────────────────
  Widget _statusSection(ColorScheme colors) {
    if (_statusLoading) {
      return Text(
        '正在读取登录状态…',
        key: const ValueKey<String>('pan-status-loading'),
        style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
      );
    }
    if (_statusError.isNotEmpty) {
      return Text(
        _statusError,
        key: const ValueKey<String>('pan-status-error'),
        style: TextStyle(fontSize: FontSizes.cap, color: colors.error),
      );
    }
    if (_accounts.isEmpty) {
      return Text(
        '还没有登录任何网盘账号',
        key: const ValueKey<String>('pan-status-empty'),
        style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
      );
    }
    return Column(
      key: const ValueKey<String>('pan-status-accounts'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final a in _accounts)
          Padding(
            padding: const EdgeInsets.only(bottom: Sp.x2),
            child: _accountRow(colors, a),
          ),
      ],
    );
  }

  Widget _accountRow(ColorScheme colors, PanAccountStatus a) {
    final ok = a.tier == PanAccountTier.loggedInNoDirectLink;
    final accent = ok ? colors.primary : colors.onSurfaceVariant;
    return Container(
      key: ValueKey<String>('pan-account-${a.kind}'),
      padding: const EdgeInsets.all(Sp.x2),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: Radii.rMd,
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                ok ? AppIcons.check_circle : AppIcons.error_outline,
                size: 16,
                color: accent,
              ),
              const SizedBox(width: Sp.x1),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      a.kindName,
                      style: TextStyle(
                        fontSize: FontSizes.cap,
                        fontWeight: FontWeight.w600,
                        color: colors.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    // ★ 分档逐字文案（照 reason_text 语义）—— 这是这行的重点
                    Text(
                      panAccountTierText(a.tier, a.kindName),
                      key: ValueKey<String>('pan-account-tier-${a.kind}'),
                      style: TextStyle(fontSize: FontSizes.cap, color: accent),
                    ),
                    if (a.account.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 2),
                      Text(
                        '账号：${a.account}',
                        key: ValueKey<String>('pan-account-name-${a.kind}'),
                        style: TextStyle(
                          fontSize: FontSizes.cap,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (!a.keyringAvailable) ...<Widget>[
                      const SizedBox(height: 2),
                      Text(
                        '本机没有可用的系统钥匙串，登录状态存不住',
                        style:
                            TextStyle(fontSize: FontSizes.cap, color: colors.error),
                      ),
                    ],
                  ],
                ),
              ),
              // 登出只在**确实有凭据**时出现（未登录给登出按钮 = 假入口）
              if (a.hasCredential) ...<Widget>[
                const SizedBox(width: Sp.x1),
                AppTextButton(
                  key: ValueKey<String>('pan-account-logout-${a.kind}'),
                  onPressed: () => _logout(a.kind),
                  child: const Text('登出'),
                ),
              ],
            ],
          ),
          /*
           * ★★★ 123 这一行**展开成账号密码表单**（其余 8 家这一行保持原样）。
           * ```text
           * 为什么只有 123：全 dex 里 `login.123pan.com` 下只有 `api/user/sign_in`，
           * 且全池 qrcode 命中 22 条**没有一条属于 123**
           * （`.probe/pan-login-evidence-remaining.md` §5.3）
           * ⇒ 它不是"扫码没做"，是**没有扫码这条路**；给它画二维码只会扫不动。
           * 反过来，其余 8 家**没有**密码表单（它们的密码登录协议不存在/未取证）
           * ⇒ 若哪天真接了第二家，这里按 kind 加分支即可，不是写死成"123 专属页"。
           * ```
           */
          if (a.kind == pan123KindCode) _passwordLoginForm(colors),
        ],
      ),
    );
  }

  // ───────────────────────────────────────────────────────────────
  //  ④ 123 的账号密码表单（账号 / 密码 + 登录；失败原因在按钮下方）
  // ───────────────────────────────────────────────────────────────
  Widget _passwordLoginForm(ColorScheme colors) {
    return Padding(
      padding: const EdgeInsets.only(top: Sp.x2),
      child: Column(
        key: const ValueKey<String>('pan-password-123-form'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // ★ 含 TextField ⇒ 就地补透明 Material 宿主（外壳规矩，同扫码/分享两区）
          Material(
            type: MaterialType.transparency,
            child: TextField(
              key: const ValueKey<String>('pan-password-123-account'),
              controller: _pwdAccount,
              textAlign: TextAlign.left,
              enabled: !_pwdBusy,
              decoration: const InputDecoration(
                labelText: '123 账号（手机号或邮箱）',
                isDense: true,
              ),
            ),
          ),
          const SizedBox(height: Sp.x1),
          Material(
            type: MaterialType.transparency,
            child: TextField(
              key: const ValueKey<String>('pan-password-123-password'),
              controller: _pwdPassword,
              textAlign: TextAlign.left,
              enabled: !_pwdBusy,
              // ★ 密码框必须遮蔽（不许明文回显在屏幕上/截图里）
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '密码',
                isDense: true,
              ),
              onSubmitted: (_) => _passwordLogin(),
            ),
          ),
          const SizedBox(height: Sp.x2),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: Sp.x2,
            runSpacing: Sp.x1,
            children: <Widget>[
              AppTextButton(
                key: const ValueKey<String>('pan-password-123-submit'),
                onPressed: _pwdBusy ? null : _passwordLogin,
                child: Text(_pwdBusy ? '正在登录…' : '登录'),
              ),
            ],
          ),
          // 失败原因显示在**按钮下方**（用户视线的落点），原样透出后端那句话
          if (_pwdError.isNotEmpty) ...<Widget>[
            const SizedBox(height: Sp.x1),
            Text(
              _pwdError,
              key: const ValueKey<String>('pan-password-123-error'),
              style: TextStyle(fontSize: FontSizes.cap, color: colors.error),
            ),
          ],
          if (_pwdOkText.isNotEmpty) ...<Widget>[
            const SizedBox(height: Sp.x1),
            Text(
              _pwdOkText,
              key: const ValueKey<String>('pan-password-123-ok'),
              style: TextStyle(fontSize: FontSizes.cap, color: colors.primary),
            ),
          ],
        ],
      ),
    );
  }

  // ───────────────────────────────────────────────────────────────
  //  ② 扫码登录区
  // ───────────────────────────────────────────────────────────────
  Widget _qrSection(ColorScheme colors) {
    /*
     * ★★★ R2-#3：后端没接线时**如实说明**，不画"点了只会报错"的假入口。
     *
     * # 为什么不是"把按钮禁掉"
     * ```text
     * 禁用按钮的语义是"当前条件不满足"（如没填链接），用户会去找条件。
     * 而这里是**功能不存在**（命令没注册）—— 该说的是一句实话，不是把按钮变灰。
     * ⇒ 所以：**整区替换成一句说明**，连选择网盘的下拉一起收掉
     *   （它此刻也选不出任何结果）。
     * ```
     *
     * # 为什么不是删掉整区
     * ```text
     * 后端接上那天，这段代码**不用改**就该自动恢复可用
     *   ⇒ 判据来自**真命令的返回**（`_qrBackendAvailable`），不是写死的常量。
     *     探测只发生在"用户真的点过"之后 ⇒ 首屏（null）照常画入口，零额外请求。
     * ```
     */
    if (_qrBackendAvailable == false) {
      return Container(
        key: const ValueKey<String>('pan-qr-unavailable'),
        width: double.infinity,
        padding: const EdgeInsets.all(Sp.x3),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest.withValues(alpha: 0.35),
          borderRadius: Radii.rLg,
          border: Border.all(color: colors.outlineVariant),
        ),
        child: Text(
          '本版本还没有接入网盘扫码登录（这条链路还缺后端实现），'
          '所以这里暂时拿不到二维码。登录状态一栏仍可用。',
          key: const ValueKey<String>('pan-qr-unavailable-text'),
          style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
        ),
      );
    }
    return Column(
      key: const ValueKey<String>('pan-qr-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // ★ 含 DropdownButton ⇒ 就地补透明 Material 宿主（外壳规矩）
        Material(
          type: MaterialType.transparency,
          child: DropdownButtonFormField<String>(
            key: const ValueKey<String>('pan-qr-kind'),
            initialValue: _qrKind,
            isDense: true,
            decoration: const InputDecoration(
              labelText: '选择网盘',
              isDense: true,
            ),
            items: <DropdownMenuItem<String>>[
              /*
               * ★ 2026-10-29：这份下拉只列**真能出码**的盘。
               * ```text
               * 摘掉 123：它没有扫码端点（官方只有账号密码 sign_in 与 open-api 令牌），
               *   留在下拉里只会让用户点了看到一句"没有扫码"——那正是"点了才撞墙"的形态；
               *   它的登录入口是上面那张账号/密码表单。
               * 补上 光鸭/迅雷：设备码族，码内容是服务端给的 verification_uri_complete（真链接）。
               * 天翼保留：虽然当前只到"做不完整"的如实报错，但它是可做的一家，
               *   摘掉会让用户以为"天翼不支持"——报错文案里已写清缺哪一步。
               * ```
               */
              for (final e in const <String, String>{
                'quark': '夸克网盘',
                'uc': 'UC 网盘',
                'baidu': '百度网盘',
                'aliyun': '阿里云盘',
                '115': '115 网盘',
                'guangya': '光鸭网盘',
                'xunlei': '迅雷云盘',
                'tianyi': '天翼云盘',
              }.entries)
                DropdownMenuItem<String>(value: e.key, child: Text(e.value)),
            ],
            onChanged: _qrKey == null
                ? (v) => setState(() => _qrKind = v ?? _qrKind)
                : null, // 扫码进行中不许换盘（换了二维码就作废）
          ),
        ),
        const SizedBox(height: Sp.x2),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: Sp.x2,
          runSpacing: Sp.x1,
          children: <Widget>[
            AppTextButton(
              key: const ValueKey<String>('pan-qr-start'),
              onPressed: _qrBusy ? null : _startQrLogin,
              child: Text(
                _qrBusy
                    ? '正在获取二维码…'
                    : (_qrKey == null ? '获取登录二维码' : '重新获取二维码'),
              ),
            ),
          ],
        ),
        if (_qrError.isNotEmpty) ...<Widget>[
          const SizedBox(height: Sp.x1),
          Text(
            _qrError,
            key: const ValueKey<String>('pan-qr-error'),
            style: TextStyle(fontSize: FontSizes.cap, color: colors.error),
          ),
        ],
        // 二维码只在实际拿到之后画（没拿过不许占位）
        if (_qrSvg.isNotEmpty || _qrUrl.isNotEmpty) ...<Widget>[
          const SizedBox(height: Sp.x2),
          QrView(
            key: const ValueKey<String>('pan-qr-view'),
            svg: _qrSvg,
            size: 180,
            // 解析失败降级成 URL 文本（qr_view.dart 的约定）
            fallback: Text(
              _qrUrl,
              textAlign: TextAlign.left,
              style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurface),
            ),
          ),
          const SizedBox(height: Sp.x1),
          Text(
            _qrState,
            key: const ValueKey<String>('pan-qr-status'),
            style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurface),
          ),
        ],
      ],
    );
  }

  // ───────────────────────────────────────────────────────────────
  //  ③ 分享文件浏览区
  // ───────────────────────────────────────────────────────────────
  Widget _shareSection(ColorScheme colors) {
    final s = _shareStatus;
    return Column(
      key: const ValueKey<String>('pan-share-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // ★ 含 TextField ⇒ 就地补透明 Material 宿主（外壳规矩）
        Material(
          type: MaterialType.transparency,
          child: TextField(
            key: const ValueKey<String>('pan-share-input'),
            controller: _shareText,
            textAlign: TextAlign.left,
            maxLines: 3,
            minLines: 2,
            decoration: const InputDecoration(
              labelText: '分享链接或整段文字',
              hintText: 'https://…  （提取码在正文里也可以）',
              isDense: true,
            ),
            onSubmitted: (_) => _identify(),
          ),
        ),
        const SizedBox(height: Sp.x2),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: Sp.x2,
          runSpacing: Sp.x1,
          children: <Widget>[
            AppTextButton(
              key: const ValueKey<String>('pan-share-identify'),
              onPressed: _identifyBusy ? null : _identify,
              child: Text(_identifyBusy ? '识别中…' : '识别'),
            ),
            if (s != null && s.recognized)
              AppTextButton(
                key: const ValueKey<String>('pan-share-list'),
                onPressed: _listBusy ? null : _listFiles,
                child: Text(_listBusy ? '正在列出文件…' : '列出分享里的文件'),
              ),
          ],
        ),
        if (_shareError.isNotEmpty) ...<Widget>[
          const SizedBox(height: Sp.x1),
          Text(
            _shareError,
            key: const ValueKey<String>('pan-share-error'),
            style: TextStyle(fontSize: FontSizes.cap, color: colors.error),
          ),
        ],
        if (s != null) ...<Widget>[
          const SizedBox(height: Sp.x2),
          _identifyResult(colors, s),
        ],
        if (_listError.isNotEmpty || _listing != null) ...<Widget>[
          const SizedBox(height: Sp.x2),
          // ★ 列目录三态容器是**复用**的（pan_share_dialog.dart），不重造
          PanShareListingSection(
            listing: _listing,
            error: _listError,
          ),
        ],
      ],
    );
  }

  /// 识别结果的紧凑面板（kindName + 分层原因 + 登录状态；与对话框同信息，不重造判档）
  Widget _identifyResult(ColorScheme colors, PanShareStatus s) {
    final bad = !s.recognized;
    final accent = bad ? colors.error : colors.primary;
    return Container(
      key: const ValueKey<String>('pan-identify-result'),
      padding: const EdgeInsets.all(Sp.x2),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: Radii.rMd,
        border: Border.all(color: accent.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            s.kindName,
            style: TextStyle(
              fontSize: FontSizes.cap,
              fontWeight: FontWeight.w600,
              color: accent,
            ),
          ),
          const SizedBox(height: 2),
          // ★ 分层的真实原因原样透出（这是识别面板的重点）
          Text(
            s.reason,
            style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurface),
          ),
          const SizedBox(height: 2),
          Text(
            s.loggedIn
                ? '登录状态：已登录${s.account != null && s.account!.isNotEmpty ? '（${s.account}）' : ''}'
                    '${s.expired ? '，但已过期' : ''}'
                : '登录状态：未登录',
            style: TextStyle(
              fontSize: FontSizes.cap,
              color: colors.onSurfaceVariant,
            ),
          ),
          // 能力边界：能列 ≠ 能播（resolvable 恒 false 时必须显式说）
          if (!s.resolvable) ...<Widget>[
            const SizedBox(height: 2),
            Text(
              '当前版本还不能用它播放（取直链需要登录账号）',
              style: TextStyle(
                fontSize: FontSizes.cap,
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
