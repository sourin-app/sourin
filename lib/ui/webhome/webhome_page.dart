// ═══════════════════════════════════════════════════════════════════════
//  T6 webHome：HTML 首页 —— 内嵌 WebView + fm 桥接线 + 自动回退
// ═══════════════════════════════════════════════════════════════════════
//
// # 双模式关系（设计书第四节）
// 不替换原生首页：本页只在「启用且未回退」时由 home_page 的接入点顶上；
// ① 加载失败/白屏超时 → 自动回退原生（本次会话）；② 右上角常驻
// 「回原生首页」按钮（手动）+ ⚙（设置）。
//
// # 安全边界执行点
// - 方法白名单：FmBridge.dispatch（白名单外一律 unknown-method）；
// - net.request：字面量判据 + **DNS 解析后再判**（防 rebinding）；
// - 凭据零打印：日志只有 method + host + path（query 都不给），headers/body 不落日志。
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
// ★ 主题体系门禁（theme_regression ① / r7 ⑤）：lib/ 禁 flutter/material，
//   统一 material_ui（Theme/Icons/Scaffold 都从这里来，与 settings_sub_page 同款）。
import 'package:material_ui/material_ui.dart';

import '../../core/app_log.dart';
import '../widgets/app_toast.dart';
import 'fm_bridge.dart';
import 'fm_sdk_js.dart';
import 'webhome_store.dart';

/// HTML 首页加载后多久仍"空白"就判失败回退（白屏看门狗）
const Duration webhomeBlankWatchdog = Duration(seconds: 8);

class WebHomePage extends StatefulWidget {
  const WebHomePage({
    super.key,
    this.onOpenDetail,
    this.onOpenLive,
    required this.onBackToNative,
    required this.onOpenSettings,
  });

  /// 与 HomePage 同名回调同语义（shell 注入，本页原样转发）
  final void Function(String provider, String id)? onOpenDetail;
  final void Function(String provider, String channelId, String name)?
      onOpenLive;
  final VoidCallback onBackToNative;
  final VoidCallback onOpenSettings;

  @override
  State<WebHomePage> createState() => _WebHomePageState();
}

class _WebHomePageState extends State<WebHomePage> {
  InAppWebViewController? _controller;
  FmBridge? _bridge;
  WebHomeCache? _cache;
  Timer? _blankTimer;
  bool _fallbackReported = false;

  @override
  void initState() {
    super.initState();
    _cache = WebHomeCache.instance..ensureLoaded();
    _bridge = FmBridge(
      onPlayVod: (provider, id) {
        AppLog.write('WEBHOME', 'player.playVod provider=$provider id=$id');
        widget.onOpenDetail?.call(provider, id);
      },
      onOpenLive: (provider, channelId, name) {
        AppLog.write(
            'WEBHOME', 'app.openLive provider=$provider channel=$channelId');
        widget.onOpenLive?.call(provider, channelId, name);
      },
      onNetRequest: _netRequest,
      onCacheGet: (k) => _cache!.get(k),
      onCacheSet: (k, v) => _cache!.set(k, v),
      onCacheDelete: (k) => _cache!.del(k),
      onLog: (level, msg) =>
          AppLog.write('WEBHOME/js', '[$level] ${AppLog.redact(msg)}'),
      onToast: (msg) {
        if (!mounted) return;
        // ★ 玻璃 toast 体系（zz_t66_glass_toast）：SnackBar 全仓禁用，
        //   统一走 showAppToast（ToastHost 挂在 shell，找不到宿主时静默 no-op）。
        showAppToast(context, msg);
      },
    );
  }

  @override
  void dispose() {
    _blankTimer?.cancel();
    super.dispose();
  }

  /// # net.request 宿主代发
  ///
  /// 字面量判据（桥层已过）之后**必须**再做解析段判据：
  /// DNS 解析出的每个 IP 重过白名单。
  /// ⚠️ 措辞纪律（T6 互检 P2-1）：双判**收窄 TOCTOU 窗口**，**未闭合**
  /// DNS rebinding —— 解析与连接之间的窗口仍在；按解析出的 IP 直连
  /// （绑定 socket）是下批项（威胁模型自洽：HTML 是用户自写）。
  Future<Map<String, Object?>> _netRequest(FmNetRequest req) async {
    final uri = Uri.tryParse(req.url);
    if (uri == null || uri.host.isEmpty) {
      return const {'error': 'bad-args'};
    }
    try {
      final ips = await InternetAddress.lookup(uri.host)
          .timeout(const Duration(seconds: 10));
      if (!isNetRequestTargetAllowed(uri,
          resolvedIps: ips.map((e) => e.address))) {
        AppLog.write('WEBHOME', 'net.request rejected(dns): ${_describe(uri)}');
        return const {'error': 'target-not-allowed'};
      }
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      try {
        final request = await client.openUrl(req.method, uri);
        // ⚠️ headers 可能带凭据：只加不记。
        req.headers.forEach(request.headers.add);
        if (req.body != null) request.add(utf8.encode(req.body!));
        final response =
            await request.close().timeout(netRequestTimeout);
        final builder = BytesBuilder(copy: false);
        var total = 0;
        var truncated = false;
        await for (final chunk in response) {
          total += chunk.length;
          if (total > netResponseMaxBytes) {
            truncated = true;
            break;
          }
          builder.add(chunk);
        }
        final body = utf8.decode(builder.takeBytes(), allowMalformed: true);
        // ★ 日志只有 method + host + path（query 可能带 token，不给）。
        AppLog.write('WEBHOME',
            'net.request ${req.method} ${_describe(uri)} → ${response.statusCode}${truncated ? ' (truncated)' : ''}');
        return {
          'status': response.statusCode,
          'contentType': response.headers.value('content-type') ?? '',
          'body': body,
          if (truncated) 'truncated': true,
        };
      } finally {
        client.close(force: true);
      }
    } catch (e) {
      AppLog.write('WEBHOME', 'net.request failed: ${_describe(uri)} $e');
      return {'error': 'network-error'};
    }
  }

  static String _describe(Uri u) => '${u.host}${u.path}';

  Future<Object?> _handleFm(List<dynamic> args) async {
    if (args.isEmpty || args.first is! String) {
      return const {'error': 'bad-args'};
    }
    final method = args.first as String;
    final payload = args.length > 1 ? args[1] : null;
    // navigation.back：页内能后退就后退，否则回原生首页。
    if (method == fmMethodBack) {
      final c = _controller;
      if (c != null && await c.canGoBack()) {
        await c.goBack();
      } else {
        widget.onBackToNative();
      }
      return const {'ok': true};
    }
    return _bridge!.dispatch(method, payload);
  }

  void _startBlankWatchdog() {
    _blankTimer?.cancel();
    _blankTimer = Timer(webhomeBlankWatchdog, () async {
      if (_fallbackReported || !mounted) return;
      try {
        final c = _controller;
        if (c == null) return;
        final r = await c.evaluateJavascript(source: '''
JSON.stringify({
  text: (document.body && document.body.innerText || '').trim().length,
  media: document.querySelectorAll('img,canvas,video,svg').length
})''');
        dynamic m = r;
        if (m is String) m = jsonDecode(m);
        final text = m is Map ? m['text'] : null;
        final media = m is Map ? m['media'] : null;
        final blank =
            (text is num && text == 0) && (media is num && media == 0);
        if (blank) {
          _fallbackReported = true;
          WebHomeController.instance
              .reportLoadFailure('blank-page after ${webhomeBlankWatchdog.inSeconds}s');
          widget.onBackToNative();
        }
      } catch (_) {
        // 读数失败本身不回退 —— 页面可能只是还没起 DOM；靠看门狗下一轮。
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final html = WebHomeController.instance.html;
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: InAppWebView(
              initialData: InAppWebViewInitialData(
                data: html,
                mimeType: 'text/html',
                encoding: 'utf-8',
              ),
              initialSettings: InAppWebViewSettings(
                transparentBackground: false,
                supportZoom: false,
                // ★ cookie 隔离（P2-2 探针实测口径，.probe/t6_webview_probe/
                //   RESULTS_COOKIE.md）：incognito 走 WebView2
                //   IsInPrivateModeEnabled（in_app_webview.cpp:76），进程内
                //   种 cookie 可行，但**不是可靠的"纯内存不落盘"**——
                //   硬退出后 Set-Cookie 头种的 cookie 跨进程仍在，且
                //   incognito 下 CookieManager.getCookies 恒为空（宿主盲区）。
                //   与网盘登录 webview 的隔离来自"不同插件、不同数据目录"
                //   （desktop_webview_window 用 webview_window_WebView2），
                //   不来自 incognito。若 Lead 要求硬隔离：WebviewEnvironment
                //   支持 userDataFolder（webview_environment_settings.h:17），
                //   给 webHome 配独立目录即可，另行立项。
                incognito: true,
              ),
              initialUserScripts: UnmodifiableListView<UserScript>([
                UserScript(
                  source: kFmSdkJs,
                  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                ),
              ]),
              onWebViewCreated: (c) async {
                _controller = c;
                c.addJavaScriptHandler(
                    handlerName: 'fm',
                    callback: (args) async => _handleFm(args));
              },
              onLoadStop: (_, __) => _startBlankWatchdog(),
              onReceivedError: (c, request, error) async {
                // ★ 主文档加载失败才回退；子资源失败不回退。
                if (_fallbackReported) return;
                final current = await c.getUrl();
                final isMain =
                    request.url.toString() == (current?.toString() ?? '');
                if (!isMain) return;
                _fallbackReported = true;
                WebHomeController.instance.reportLoadFailure(
                    'load-error ${error.type} ${error.description}');
                widget.onBackToNative();
              },
              onConsoleMessage: (_, msg) {
                // 兜底：SDK 劫持之外的原生 console 也落日志。
                AppLog.write('WEBHOME/console',
                    '[${msg.messageLevel}] ${AppLog.redact(msg.message)}');
              },
            ),
          ),
          // ── 常驻右上角：回原生首页 + 设置 ──
          Positioned(
            top: 8,
            right: 12,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _PillButton(
                  icon: Icons.home_outlined,
                  label: '回原生首页',
                  onTap: widget.onBackToNative,
                ),
                const SizedBox(width: 6),
                _PillButton(
                  icon: Icons.tune,
                  label: 'HTML 首页',
                  onTap: widget.onOpenSettings,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface.withValues(alpha: 0.85),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: colors.onSurface),
              const SizedBox(width: 4),
              Text(label, style: TextStyle(fontSize: 12, color: colors.onSurface)),
            ],
          ),
        ),
      ),
    );
  }
}
