// ═══════════════════════════════════════════════════════════════════════
//  「有新版本」对话框
// ═══════════════════════════════════════════════════════════════════════
//
// # 交互契约（三种输入都要能用）
// ```text
// 鼠标  : 点按钮
// 触摸  : 同上（按钮 ≥ 48dp 高）
// 遥控器: ↑↓ 移动焦点 / ←→ 切按钮 / 确认键触发
// ```
//
// # 外壳：AppDialogShell（2026-10-19，R4）
//
// 改前用 Material 的 `AlertDialog` —— 那是**框架原生外壳**，与全仓
// 其余 6 个弹窗长得不一样（标题栏没有副标题、没有右上角关闭钮、
// 底部按钮条不靠右、圆角/底色/描边全是框架默认值）。
// 现在收拢到 `AppDialogShell`（见 `app_dialog_shell.dart` 与
// `docs/AGENTS.md` §3.5）。
//
// ⚠️ 换掉 `AlertDialog` 时**必须保留焦点/键盘行为**：
//   改前靠 `AlertDialog` 拿到 `MaterialLocalizations`（`showDialog` 的
//   route 本身就会提供，但一旦外层树缺它，`MaterialLocalizations.of`
//   会在**真机第一次弹窗**时崩 —— 而 4131 条单测可能一条都碰不到）。
//   ⇒ 外壳内部没有 `MaterialLocalizations` 依赖；`showAppDialog` 走
//     `showDialog`，路由自带。改完必须**真机**验一次（见本轮报告 ④）。
//
// ⚠️ 宽度：改前写在 `content: SizedBox(width: 460)` 里 ——
//   那管的是**内容**不是**卡片**，卡片实际宽度由 `AlertDialog` 自己的
//   内边距+内容宽决定（实测比 460 宽）。现在由外壳的 `width` 管卡片，
//   460 是 §3.5 的「窄弹窗」档。

import 'package:material_ui/material_ui.dart';

import '../../core/app_update/app_update_controller.dart';
import '../../core/app_update/install.dart';
import '../../core/app_update/release.dart';
import '../tokens.dart';
import 'app_dialog_shell.dart';
import 'app_toast.dart';
import 'overlay_motion.dart';
import 'release_notes.dart';
import '../../design/icons/app_icons.dart';

/// 显示更新对话框。返回 true 表示用户点了「下载」
Future<bool> showUpdateDialog(
  BuildContext context,
  ReleaseInfo release, {
  required UpdatePlatform platform,
}) async {
  final asset = selectAsset(release, platform);
  final r = await showAppDialog<bool>(
    context: context,
    builder: (ctx) => _UpdateDialog(release: release, asset: asset),
  );
  return r ?? false;
}

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.release, required this.asset});
  final ReleaseInfo release;
  final ReleaseAsset? asset;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final c = AppUpdateController.instance;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final d = c.download;
        return AppDialogShell(
          title: '发现新版本 ${widget.release.version}',
          /*
           * 副标题：一句话说清"这窗干嘛用的"。
           *
           * ⚠️ **不许**把安装包名/大小写进来 —— 正文第一行已经写了
           *    （见下面的 `asset.prettySize` 那一段）
           *    ⇒ 同一句话在标题栏和正文各出现一次，用户读到两遍，
           *      而且 `app_update_ui_test.dart` 的
           *      `find.textContaining('Sourin-Setup-1.1.0.exe') findsOneWidget`
           *      会直接变红（实测过：我第一版就是复制的，-3）。
           *      副标题只补充"正文没说的信息"。
           */
          subtitle: '先看看改了什么，再决定要不要现在更新',
          /*
           * 图标：与其余带图标的标题栏同族
           * （composer=auto_fix_high / skip=movie / subtitle=subtitles）。
           * `download_outlined` 语义直指「这是一个更新/下载对话框」。
           */
          icon: AppIcons.download_outlined,
          onClose: () => Navigator.pop(context, false),
          /*
           * ★ 窄弹窗 460（§3.5 白名单档）。
           *
           * 为什么是"窄"而不是默认 560：正文是**发行说明**（多行纯文本 +
           * 列表），460 的换行长度中文约 28 字/行 —— 再宽就超过舒适阅读行长。
           * ⚠️ 改前这个 460 写在 `content: SizedBox(width: 460)` 里，
           *    管的是**内容**；现在它管**卡片**（外壳的 `width`）。
           *    所以卡片比改前**窄**了（改前卡片 ≈ 460 + AlertDialog 内边距）。
           *    这是有意的：卡片宽度应该由设计档位决定，不是内容的副产物。
           */
          width: 460,
          /*
           * `fill: false` —— 本弹窗只经 `showAppDialog` 挂载（没有常挂宿主、
           * 也没有 `SheetExitMotion`），与 `plugin_edit_dialog.dart` 同一处境：
           * `fill: true` 会让外壳把遮罩层铺满视口（在路由里其实等价），
           * 但 `false` 让"定位交给宿主"这条语义更直白，且与同走
           * `showAppDialog` 的 `plugin_edit_dialog` 保持一致。
           */
          fill: false,
          actions: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('稍后'),
              ),
              const SizedBox(width: Sp.x2),
              TextButton(
                // ★ 必须先 await 落盘再关窗（CR-1015）：
                //   用户点「忽略」往往就是不想再看到它了，随后可能立刻退出 ——
                //   而这一按的全部意义就是「下次别再弹」。写盘是异步的，
                //   fire-and-forget 会让进程比写盘先走 ⇒ 下次照样弹。
                //   落盘只有几毫秒，且 flush() 幂等，用户感知不到。
                onPressed: () async {
                  await c.ignoreVersion(widget.release.tag);
                  if (!context.mounted) return;
                  Navigator.pop(context, false);
                },
                child: const Text('忽略此版本'),
              ),
              const SizedBox(width: Sp.x2),
              FilledButton(
                onPressed: d.active || widget.asset == null
                    ? null
                    : () async {
                        if (!InstallLaunch.canInstallDirectly) {
                          final msg = await InstallLaunch.openInBrowser(
                              widget.asset!.browserUrl);
                          if (!context.mounted) return;
                          showAppToast(context, msg ?? '请在浏览器里完成更新。');
                          Navigator.pop(context, false);
                          return;
                        }
                        Navigator.pop(context, true);
                      },
                child: Text(d.active ? '下载中…' : '下载更新'),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.asset == null)
                Padding(
                  padding: const EdgeInsets.only(bottom: Sp.x3),
                  child: Text('这个版本没有提供当前设备的安装包，可以到下载页手动获取。',
                      style: TextStyle(
                          fontSize: FontSizes.sm, color: colors.onSurfaceVariant)),
                )
              else if (widget.asset!.prettySize.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: Sp.x3),
                  child: Text('${widget.asset!.name} · ${widget.asset!.prettySize}',
                      style: TextStyle(
                          fontSize: FontSizes.cap, color: colors.onSurfaceVariant)),
                ),
              ...buildReleaseNotes(
                widget.release.notes,
                linkColor: colors.onSurface,
              ),
              if (d.active || d.error != null) ...[
                const SizedBox(height: Sp.x3),
                _Progress(d),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress(this.d);
  final UpdateDownloadState d;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // ★ 用 colorScheme.error 而不是 AppPalette.of(...).error —— 两者取值一致
    //   （theme_bridge.dart 把角色展平进 ColorScheme），而这个对话框从头到尾
    //   用的都是 colorScheme；只把错误色换成色板会变成"一半一半"。
    //   ⚠️ 历史：早先这里试过 AppPalette.of，它当时在 MaterialApp 之外会
    //   **assert 崩掉**；现已改成按 Theme.brightness 兜底（2026-10-10）。
    //   也就是说这里换回 AppPalette 现在也是安全的 —— 留着这条注释是为了
    //   下一个人别再重新踩一次那个坑。
    final danger = colors.error;
    if (d.error != null) {
      return Row(children: [
        Icon(AppIcons.error_outline, size: 18, color: danger),
        const SizedBox(width: Sp.x2),
        Expanded(
          child: Text(d.error!,
              style: TextStyle(fontSize: FontSizes.sm, color: danger)),
        ),
      ]);
    }
    final pct = d.total > 0 ? '${(d.fraction * 100).toStringAsFixed(0)}%' : '…';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(value: d.total > 0 ? d.fraction : null),
        const SizedBox(height: Sp.x1),
        Row(
          children: [
            Expanded(
              child: Text('正在下载 $pct',
                  style: TextStyle(
                      fontSize: FontSizes.cap, color: colors.onSurfaceVariant)),
            ),
            TextButton(
              onPressed: AppUpdateController.instance.cancelDownload,
              child: const Text('取消', style: TextStyle(fontSize: FontSizes.cap)),
            ),
          ],
        ),
      ],
    );
  }
}