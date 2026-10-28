// ═══════════════════════════════════════════════════════════════════════
//  网盘扫码登录弹窗 —— 「点登录要出二维码，不是空白」
// ═══════════════════════════════════════════════════════════════════════
//
// # 由来（Owner 2026-10-28 逐字）
// ```text
// > tvbox 聚合源播放的时候，如果是需要网盘登录 应该提示 然后点击登录出现二维码进行登录，
// > 而不是 点击登录 出现空白
// ```
//
// # 为什么会空白
// ```text
// 播放页的「登录」按钮走的是 `showProviderLoginDialog` → `ProviderLoginPanel`。
// 那个面板画的是**源自己声明的登录字段**（账号/密码/cookie 之类）。
// 而网盘类 csp 源（`csp-pan115` 等）**没有任何登录字段**（它们的凭据是扫码拿的）
// ⇒ 面板是空的 ⇒ 用户看到一片空白。
// ```
//
// # 这个弹窗做什么
// ```text
// 复用已经跑通的那条链路（pan_settings_page 的 ② 区）：
//   pan_qr_login_start(kind) → QrView 出二维码 → 每 2 秒 pan_qr_login_poll(kind, key)
//   → status=confirmed ⇒ 关闭并返回 true（调用方据此重试播放）
// 组件一律复用（QrView / SourinCore.callAsync），不另造一套。
// ```

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/ffi.dart';  // userErrorText 也在这里
import '../tokens.dart';
import 'app_loading.dart';
import 'overlay_motion.dart' show showAppDialog;
import 'qr_view.dart';

/// `csp-pan115` / `csp-pan-ali` 这类源 id → 盘种 code（与 Rust `PanKind::code()` 同一套词）
///
/// # 为什么按源 id 映射（而不是让后端多带一个字段）
/// ```text
/// 源 id 是**我们自己造的**、且稳定（`state.rs` 的 `csp-<kebab 类名>`）。
/// 网盘种从类名一一对应，映射表放这里、配一条门禁就够；
/// 让后端再带一个字段等于把同一份信息传两遍，还会在"导入的老配置"上缺字段。
/// ```
/// 返回 null ⇒ 不是网盘类 ⇒ 走原来的 `ProviderLoginPanel`。
String? panKindOfProvider(String providerId) {
  switch (providerId) {
    case 'csp-pan115':
      return '115';
    case 'csp-pan123':
      return '123';
    case 'csp-pan-ali':
      return 'aliyun';
    case 'csp-pan-tianyi':
      return 'tianyi';
    case 'csp-pan-xunlei':
      return 'xunlei';
    case 'csp-pan-guangya':
      return 'guangya';
    case 'csp-pan-share':
      // 分享链接解析走 UC/夸克的分享接口，登录态按 UC 处理
      return 'uc';
    case 'csp-pan-uc':
      return 'uc';
    case 'csp-pan-quark':
      return 'quark';
    default:
      return null;
  }
}

/// 盘种 code → 面向用户的名字（与 Rust `PanKind::display()` 对齐；认不出就原样显示 code）
String panKindDisplay(String kind) {
  switch (kind) {
    case 'quark':
      return '夸克网盘';
    case 'uc':
      return 'UC 网盘';
    case 'baidu':
      return '百度网盘';
    case 'aliyun':
      return '阿里云盘';
    case '123':
      return '123 网盘';
    case '115':
      return '115 网盘';
    case 'tianyi':
      return '天翼云盘';
    case 'guangya':
      return '光鸭云盘';
    case 'xunlei':
      return '迅雷云盘';
    default:
      return kind;
  }
}

/// 弹出「扫码登录 <盘>」；扫码成功返回 true。
///
/// 判据（调用方必须按它行动）：
/// ```text
/// true  ⇒ 凭据已写入钥匙串，可以**立刻重试**播放；
/// false ⇒ 用户关掉了 / 二维码过期 / 后端没有这条命令 —— 调用方**不许**重试
///         （重试只会再失败一次，把用户刚看到的提示冲掉）。
/// ```
Future<bool> showPanQrLoginDialog(
  BuildContext context, {
  required String kind,
}) async {
  final ok = await showAppDialog<bool>(
    context: context,
    builder: (ctx) => _PanQrLoginDialog(kind: kind),
  );
  return ok ?? false;
}

class _PanQrLoginDialog extends StatefulWidget {
  const _PanQrLoginDialog({required this.kind});

  final String kind;

  @override
  State<_PanQrLoginDialog> createState() => _PanQrLoginDialogState();
}

class _PanQrLoginDialogState extends State<_PanQrLoginDialog> {
  Timer? _timer;

  bool _busy = true;
  String _error = '';
  String _key = '';
  String _svg = '';
  String _url = '';
  String _state = '正在获取二维码…';

  /// 已经拿到终态就不再轮询（成功/过期/失败）
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final r = await SourinCore.callAsync(
        'pan_qr_login_start',
        {'kind': widget.kind},
      ) as Map<String, dynamic>;
      if (!mounted) return;
      final key = '${r['key'] ?? ''}';
      if (key.isEmpty) {
        setState(() {
          _busy = false;
          _error = '没有拿到登录二维码，请稍后重试';
        });
        return;
      }
      setState(() {
        _key = key;
        _svg = '${r['svg'] ?? ''}';
        _url = '${r['url'] ?? ''}';
        _state = '用手机扫码登录${panKindDisplay(widget.kind)}';
        _busy = false;
      });
      _timer = Timer.periodic(const Duration(seconds: 2), (_) => unawaited(_poll()));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        // ★ 不许把异常原文倒进用户可见字段（门禁 zz_t66_user_error_text_gate）
        _error = userErrorText(e, fallback: '扫码登录暂时用不了，请稍后重试');
      });
    }
  }

  Future<void> _poll() async {
    if (_finished || _key.isEmpty) return;
    try {
      final r = await SourinCore.callAsync(
        'pan_qr_login_poll',
        {'kind': widget.kind, 'key': _key},
      ) as Map<String, dynamic>;
      if (!mounted) return;
      final status = '${r['status'] ?? ''}';
      if (status == 'confirmed') {
        _finished = true;
        _timer?.cancel();
        if (mounted) Navigator.of(context).pop(true);
        return;
      }
      setState(() {
        _state = switch (status) {
          'scanned' => '已扫码，请在手机上确认',
          'expired' => '二维码已过期，请重新打开',
          'failed' => '登录失败，请重试',
          _ => '等待扫码…',
        };
      });
      if (status == 'expired' || status == 'failed') {
        _finished = true;
        _timer?.cancel();
      }
    } catch (_) {
      // 轮询失败不下结论（网络抖动很常见），下一轮继续；
      // 真正的失败由 status=failed 或用户关闭来体现。
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // R4-EXCEPTION: 自建外壳（裸 Dialog）那一类 —— 本弹窗要自己定宽（380）并把
    // 二维码居中，AppGlassDialog 只收 String 标题、不能承载 QrView 的定尺画布；
    // 控件只有 Text/Column/QrView/TextButton，无任何输入控件。
    // 见 _siteExemptions 同名键。
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Sp.x5, Sp.x5, Sp.x5, Sp.x4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                '扫码登录${panKindDisplay(widget.kind)}',
                style: TextStyle(
                  fontSize: FontSizes.lg,
                  fontWeight: FontWeights.semibold,
                  color: colors.onSurface,
                ),
              ),
              const SizedBox(height: Sp.x1),
              Text(
                '这个源要用你的${panKindDisplay(widget.kind)}账号才能取到播放地址。',
                style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: Sp.x3),
              if (_busy)
                // ★ 不许直接用 CircularProgressIndicator（门禁 zz_t64_migrated_widget_gate：
                //   本项目已把它迁到 AppLoading，自绘 _AppSpinner）
                const Padding(
                  padding: EdgeInsets.all(Sp.x4),
                  child: AppLoading(),
                )
              else if (_error.isNotEmpty)
                Text(
                  _error,
                  key: const ValueKey<String>('pan-qr-login-error'),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: FontSizes.cap, color: colors.error),
                )
              else ...[
                QrView(
                  key: const ValueKey<String>('pan-qr-login-view'),
                  svg: _svg,
                  size: 180,
                  fallback: Text(
                    _url,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurface),
                  ),
                ),
                const SizedBox(height: Sp.x2),
                Text(
                  _state,
                  key: const ValueKey<String>('pan-qr-login-status'),
                  style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
                ),
              ],
              const SizedBox(height: Sp.x4),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('关闭'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
