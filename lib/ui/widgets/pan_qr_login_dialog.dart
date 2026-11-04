import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../design/widgets/app_glass_dialog.dart';
import '../../design/widgets/app_text_button.dart';
import '../tokens.dart';
import 'app_loading.dart';
import 'overlay_motion.dart' show showAppDialog;
import 'pan_login_session.dart';
import 'pan_web_login.dart';
import 'qr_view.dart';

String? panKindOfProvider(String providerId) => switch (providerId) {
  'csp-pan115' => '115',
  'csp-pan123' => '123',
  'csp-pan-ali' => 'aliyun',
  'csp-pan-tianyi' => 'tianyi',
  'csp-pan-xunlei' => 'xunlei',
  'csp-pan-guangya' => 'guangya',
  'csp-pan-share' || 'csp-pan-uc' => 'uc',
  'csp-pan-quark' => 'quark',
  _ => null,
};

String panKindDisplay(String kind) => switch (kind) {
  'quark' => '夸克网盘',
  'uc' => 'UC 网盘',
  'baidu' => '百度网盘',
  'aliyun' => '阿里云盘',
  '123' => '123 网盘',
  '115' => '115 网盘',
  'tianyi' => '天翼云盘',
  'guangya' => '光鸭云盘',
  'xunlei' => '迅雷云盘',
  _ => kind,
};

Future<bool> showPanQrLoginDialog(
  BuildContext context, {
  required String kind,
  PanLoginCommandCaller? commandCaller,
  void Function(Object error)? onFailure,
}) async =>
    await showAppDialog<bool>(
      context: context,
      builder: (_) => PanQrLoginDialog(
        kind: kind,
        commandCaller: commandCaller,
        onFailure: onFailure,
      ),
    ) ??
    false;

class PanQrLoginDialog extends StatefulWidget {
  const PanQrLoginDialog({
    super.key,
    required this.kind,
    this.commandCaller,
    this.onFailure,
  });
  final String kind;
  final PanLoginCommandCaller? commandCaller;
  final void Function(Object error)? onFailure;

  @override
  State<PanQrLoginDialog> createState() => _PanQrLoginDialogState();
}

class _PanQrLoginDialogState extends State<PanQrLoginDialog> {
  Timer? _timer;
  Timer? _deadline;
  int _generation = 0;
  bool _busy = true;
  bool _pollBusy = false;
  bool _webBusy = false;
  bool _finished = false;
  String _error = '';
  String _key = '';
  String _svg = '';
  String _state = '正在获取二维码…';
  bool? _webLoginAvailable;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
    unawaited(_probeWebLogin());
  }

  @override
  void dispose() {
    _generation++;
    _finished = true;
    _timer?.cancel();
    _deadline?.cancel();
    super.dispose();
  }

  Future<void> _probeWebLogin() async {
    final ok = await panWebviewRuntimeAvailable();
    if (mounted) setState(() => _webLoginAvailable = ok);
  }

  bool _current(int generation) =>
      mounted && generation == _generation && !_finished;

  void _stop(String message) {
    _finished = true;
    _timer?.cancel();
    _deadline?.cancel();
    if (mounted) {
      setState(() {
        _busy = false;
        _error = message;
        _state = '';
        _svg = '';
        _key = '';
      });
    }
  }

  Future<void> _start() async {
    if (_webBusy) return;
    final generation = ++_generation;
    _timer?.cancel();
    _deadline?.cancel();
    _finished = false;
    setState(() {
      _busy = true;
      _error = '';
      _key = '';
      _svg = '';
      _state = '正在获取二维码…';
    });
    try {
      final result = await callPanLoginCommand('pan_qr_login_start', {
        'kind': widget.kind,
      }, caller: widget.commandCaller);
      if (!_current(generation)) return;
      final key = '${result['key'] ?? ''}';
      final svg = '${result['svg'] ?? ''}';
      final url = '${result['url'] ?? ''}';
      if (key.isEmpty || (svg.isEmpty && url.isEmpty)) {
        _stop('没有拿到完整登录二维码，请重新获取');
        return;
      }
      setState(() {
        _key = key;
        _svg = svg;
        _busy = false;
        _state = '等待扫码…';
      });
      _timer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(_poll()),
      );
      _deadline = Timer(const Duration(minutes: 3), () {
        if (_current(generation)) _stop('本次扫码已超时，请重新获取二维码');
      });
    } catch (error) {
      if (!_current(generation)) return;
      widget.onFailure?.call(error);
      _stop(panLoginErrorText(error, fallback: '扫码登录暂时用不了，请重新获取二维码'));
    }
  }

  Future<void> _poll() async {
    if (_finished || _pollBusy || _key.isEmpty) return;
    final generation = _generation;
    _pollBusy = true;
    try {
      final result = await callPanLoginCommand('pan_qr_login_poll', {
        'kind': widget.kind,
        'key': _key,
      }, caller: widget.commandCaller);
      if (!_current(generation)) return;
      switch (result['status']) {
        case 'confirmed':
          _timer?.cancel();
          setState(() => _state = '正在检查应用是否识别账号…');
          await verifyPanLoginRecognition(
            widget.kind,
            caller: widget.commandCaller,
          );
          if (!mounted || !_current(generation)) return;
          _finished = true;
          _deadline?.cancel();
          Navigator.of(context).pop(true);
        case 'pending':
          setState(() => _state = '等待扫码…');
        case 'scanned':
          setState(() => _state = '已扫码，请在手机上确认');
        case 'expired':
          _stop('二维码已失效，请重新获取');
        default:
          _stop('扫码登录未完成，请重新获取二维码');
      }
    } catch (error) {
      if (_current(generation)) {
        _stop(panLoginErrorText(error, fallback: '扫码状态查询失败，请重新获取二维码'));
      }
    } finally {
      _pollBusy = false;
    }
  }

  Future<void> _openWebLogin() async {
    if (_webBusy) return;
    setState(() => _webBusy = true);
    _generation++;
    _finished = true;
    _timer?.cancel();
    _deadline?.cancel();
    try {
      final ok = await showPanWebLogin(context, kind: widget.kind);
      if (!mounted) return;
      if (ok) {
        Navigator.of(context).pop(true);
      } else {
        _stop('网页登录未完成，可重新获取二维码登录');
      }
    } catch (error) {
      if (mounted) {
        _stop(panLoginErrorText(error, fallback: '网页登录未完成，可重新获取二维码登录'));
      }
    } finally {
      if (mounted) setState(() => _webBusy = false);
    }
  }

  Future<void> _retry() async {
    if (_busy || _webBusy) return;
    await _start();
  }

  void _close() {
    _generation++;
    _finished = true;
    _timer?.cancel();
    _deadline?.cancel();
    Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AppGlassDialog(
      title: '扫码登录${panKindDisplay(widget.kind)}',
      maxWidth: 460,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_busy)
            const Padding(padding: EdgeInsets.all(Sp.x4), child: AppLoading())
          else if (_error.isNotEmpty)
            Text(
              _error,
              key: const ValueKey('pan-qr-login-error'),
              style: TextStyle(fontSize: FontSizes.cap, color: colors.error),
            )
          else ...[
            QrView(
              key: const ValueKey('pan-qr-login-view'),
              svg: _svg,
              size: 180,
              fallback: const Text(
                '二维码无法显示，请重新获取',
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: Sp.x2),
            Text(_state, key: const ValueKey('pan-qr-login-status')),
          ],
          if (PanWebLoginSpec.panWebLoginUnsupportedReason(widget.kind)
              case final String reason) ...[
            const SizedBox(height: Sp.x2),
            Text(
              reason,
              key: const ValueKey<String>('pan-qr-login-web-retired'),
            ),
          ],
        ],
      ),
      actions: Wrap(
        alignment: WrapAlignment.end,
        spacing: Sp.x1,
        children: [
          if (PanWebLoginSpec.of(widget.kind) != null)
            AppTextButton(
              key: const ValueKey<String>('pan-qr-login-web'),
              onPressed: _webBusy || _webLoginAvailable == false
                  ? null
                  : _openWebLogin,
              child: const Text('网页登录'),
            ),
          AppTextButton(
            key: const ValueKey('pan-qr-login-retry'),
            onPressed: _busy || _webBusy ? null : _retry,
            child: const Text('重新获取'),
          ),
          AppTextButton(
            key: const ValueKey('pan-qr-login-close'),
            onPressed: _close,
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}
