// ═══════════════════════════════════════════════════════════════════════
//  网盘分享链接识别对话框
// ═══════════════════════════════════════════════════════════════════════
//
// # 它存在的理由：把"为什么不能播"说清楚
//
// 用户粘贴一个网盘链接，产品当前**不能播**（取直链未实现）。
// 但"不能播"有五种完全不同的原因，对应完全不同的下一步动作：
//
// ```text
// 认不出这个盘        → 换个链接 / 这是别的服务
// 认出了但链接不完整  → 复制完整分享链接
// 需要先登录          → 去登录（未来）
// 登录已过期          → 重新登录
// 已登录但功能没做    → 等更新
// ```
//
// 混成一句「不支持」等于没说话 —— 这正是后端返回分层 `reason` 的原因，
// 本对话框只负责把它**原样、不打折**地显示出来。
//
// # 它**不**承诺能播
// `resolvable` 恒为 false。界面上也不会出现"播放"按钮 ——
// 不给假入口比给一个点了没反应的按钮好。
//
// # 外壳规矩（docs/AGENTS.md §3.5）
// `AppGlassDialog` + 显式 `maxWidth`；content 含 `TextField` ⇒ 就地包
// `Material(type: transparency)`；所有 Text 显式 `TextAlign.left`。
import 'package:material_ui/material_ui.dart';

import '../../core/sourin_api.dart';
import '../../design/icons/app_icons.dart';
import '../../design/widgets/app_glass_dialog.dart';
import '../../design/widgets/app_text_button.dart';
import '../tokens.dart';
import 'overlay_motion.dart';

/// 打开网盘链接识别对话框
Future<void> showPanShareDialog({required BuildContext context}) {
  return showAppDialog<void>(
    context: context,
    builder: (_) => const PanShareDialog(),
  );
}

class PanShareDialog extends StatefulWidget {
  const PanShareDialog({super.key});

  @override
  State<PanShareDialog> createState() => _PanShareDialogState();
}

class _PanShareDialogState extends State<PanShareDialog> {
  final TextEditingController _text = TextEditingController();
  bool _busy = false;
  String _error = '';
  PanShareStatus? _status;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _identify() async {
    final t = _text.text.trim();
    if (t.isEmpty) {
      setState(() => _error = '请先粘贴网盘分享链接或整段分享文字');
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
      _status = null;
    });
    try {
      final s = await SourinApi.identifyPanShare(t);
      if (!mounted) return;
      setState(() => _status = s);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '识别失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = _status;
    return AppGlassDialog(
      title: '识别网盘链接',
      maxWidth: 560,
      actions: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          AppTextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
          SizedBox(width: Sp.x2),
          AppTextButton(
            onPressed: _busy ? null : _identify,
            child: Text(_busy ? '识别中…' : '识别'),
          ),
        ],
      ),
      content: SizedBox(
        width: 500,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '把网盘分享链接（或整段分享文字，含提取码）粘进来，'
              '这里会告诉你它属于哪个网盘、缺什么、下一步该做什么。',
              textAlign: TextAlign.left,
              style: t.textTheme.bodySmall?.copyWith(
                color: t.colorScheme.onSurface.withValues(alpha: 0.72),
              ),
            ),
            SizedBox(height: Sp.x3),
            // ★ 含 TextField ⇒ 必须就地补透明 Material 宿主
            Material(
              type: MaterialType.transparency,
              child: TextField(
                controller: _text,
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
            if (_error.isNotEmpty) ...[
              SizedBox(height: Sp.x2),
              Text(
                _error,
                textAlign: TextAlign.left,
                style: t.textTheme.bodySmall
                    ?.copyWith(color: t.colorScheme.error),
              ),
            ],
            if (s != null) ...[
              SizedBox(height: Sp.x4),
              _resultPanel(t, s),
            ],
          ],
        ),
      ),
    );
  }

  Widget _resultPanel(ThemeData t, PanShareStatus s) {
    // 认不出时用错误色，认出但不可播用中性色 —— 颜色本身就在传递"卡在哪"
    final bad = !s.recognized;
    final accent = bad ? t.colorScheme.error : t.colorScheme.primary;
    return Container(
      padding: EdgeInsets.all(Sp.x3),
      decoration: BoxDecoration(
        color: t.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: Radii.rMd,
        border: Border.all(color: accent.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(bad ? AppIcons.error_outline : AppIcons.check_circle,
                  size: 16, color: accent),
              SizedBox(width: Sp.x1),
              Expanded(
                child: Text(
                  s.kindName,
                  textAlign: TextAlign.left,
                  style: t.textTheme.labelLarge?.copyWith(color: accent),
                ),
              ),
            ],
          ),
          if (s.shareId.isNotEmpty) ...[
            SizedBox(height: Sp.x1),
            _kv(t, '分享 ID', s.shareId),
          ],
          if (s.pwd != null && s.pwd!.isNotEmpty) ...[
            SizedBox(height: Sp.x1),
            _kv(t, '提取码', s.pwd!),
          ],
          SizedBox(height: Sp.x1),
          _kv(
            t,
            '登录状态',
            s.loggedIn
                ? '已登录${s.account != null ? '（${s.account}）' : ''}'
                    '${s.expired ? '，但已过期' : ''}'
                : '未登录',
          ),
          if (!s.keyringAvailable) ...[
            SizedBox(height: Sp.x1),
            Text(
              '本机没有可用的系统钥匙串 ⇒ 无法安全保存登录状态',
              textAlign: TextAlign.left,
              style: t.textTheme.labelSmall
                  ?.copyWith(color: t.colorScheme.error),
            ),
          ],
          SizedBox(height: Sp.x2),
          // ★ 分层的真实原因 —— 这是整个对话框的重点
          Text(
            s.reason,
            textAlign: TextAlign.left,
            style: t.textTheme.bodySmall?.copyWith(
              color: t.colorScheme.onSurface,
            ),
          ),
          SizedBox(height: Sp.x1),
          // 如实说明能力边界，不给假入口
          Text(
            s.resolvable
                ? '可以取流'
                : '当前版本还不能用它播放（取直链功能尚未接入）',
            textAlign: TextAlign.left,
            style: t.textTheme.labelSmall?.copyWith(
              color: t.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }

  Widget _kv(ThemeData t, String k, String v) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 64,
          child: Text(
            k,
            textAlign: TextAlign.left,
            style: t.textTheme.labelSmall?.copyWith(
              color: t.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ),
        Expanded(
          child: Text(
            v,
            textAlign: TextAlign.left,
            style: t.textTheme.labelSmall?.copyWith(
              color: t.colorScheme.onSurface,
            ),
          ),
        ),
      ],
    );
  }
}
