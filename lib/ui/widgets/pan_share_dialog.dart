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

import '../../core/ffi.dart' show userErrorText;
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

  /// 匿名列目录的结果（null = 还没列 / 列失败）
  PanShareListing? _listing;

  /// 列目录失败的人话原因（空 = 没失败）
  String _listError = '';

  /// 列目录进行中
  bool _listBusy = false;

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
      // 换了输入 ⇒ 上一次的目录结果不再对应当前链接，必须清掉
      _listing = null;
      _listError = '';
    });
    try {
      final s = await SourinApi.identifyPanShare(t);
      if (!mounted) return;
      setState(() => _status = s);
    } catch (e) {
      if (!mounted) return;
      // ★ 不许把异常原文倒进用户可见字段（本仓硬约束，
      //   门禁 zz_t66_user_error_text_gate 会抓）。走统一收口。
      setState(() => _error = userErrorText(e, fallback: '识别没有完成，请稍后重试'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 真的去列一次目录（第 20 项：把"能列出文件"这句话兑现）
  ///
  /// ⚠️ 失败就**如实说原因**，绝不用空列表冒充"这个分享里没文件" ——
  ///    那是两种完全不同的处境（Rust 侧也一样：拿不到就 Err）。
  Future<void> _listFiles() async {
    final s = _status;
    if (s == null || !s.recognized) return;
    setState(() {
      _listBusy = true;
      _listError = '';
      _listing = null;
    });
    try {
      final l = await SourinApi.panListShare(
        _text.text.trim(),
        pwd: s.pwd,
      );
      if (!mounted) return;
      setState(() => _listing = l);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _listError = userErrorText(e, fallback: '列目录没有完成，请稍后重试');
      });
    } finally {
      if (mounted) setState(() => _listBusy = false);
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
              /*
               * ★ 第 20 项「看得见 / 列得出」：识别成功且拿到分享 id 后，
               *   给一个**真的会去列目录**的入口。
               *   改前 reason 对用户承诺"未登录也能列出分享里的文件"，
               *   但产品里没有任何地方能列 ⇒ 承诺跑在能力前面。
               */
              if (s.recognized) ...[
                SizedBox(height: Sp.x2),
                AppTextButton(
                  key: const ValueKey<String>('pan-share-list-files'),
                  onPressed: _listBusy ? null : _listFiles,
                  child: Text(_listBusy ? '正在列出文件…' : '列出分享里的文件'),
                ),
              ],
              if (_listError.isNotEmpty || _listing != null) ...[
                SizedBox(height: Sp.x2),
                PanShareListingSection(
                  listing: _listing,
                  error: _listError,
                ),
              ],
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

/// 分享目录区块的**三态容器**：有清单 / 只有失败原因 / 两者都没有
///
/// # 为什么再抽一层（而不是让对话框自己写 if）
/// ```text
/// 三态每一条都是用户可见行为：
///   ① 有清单      ⇒ 必须画列表（否则"列得出"这件事没兑现）
///   ② 只有失败    ⇒ 必须画原因（否则用户以为"这个分享里没文件"）
///   ③ 两者都没有  ⇒ **零尺寸**（没点过"列出文件"时不许占位）
/// 让对话框内联写 if 的话，测试只能整页挂载 + 起 FFI 才能驱动 —— 那是假门槛。
/// ⇒ 抽成公开 widget，测试直接喂三态。
/// ```
class PanShareListingSection extends StatelessWidget {
  const PanShareListingSection({super.key, this.listing, this.error = ''});

  final PanShareListing? listing;
  final String error;

  @override
  Widget build(BuildContext context) {
    final l = listing;
    if (l != null) return PanShareListingView(listing: l);
    if (error.isNotEmpty) {
      final t = Theme.of(context);
      return Text(
        error,
        key: const ValueKey<String>('pan-share-listing-error'),
        textAlign: TextAlign.left,
        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error),
      );
    }
    // 没点过「列出文件」⇒ 一个像素都不占
    return const SizedBox.shrink();
  }
}

/// 分享目录的**文件列表区**（公开：可被 widget test 直接渲染）
///
/// # 为什么抽成公开 widget（与 `TvboxImportResultView` / `TvboxUpdateResultView` 同一条纪律）
/// ```text
/// 私有方法让"列表到底画没画、有没有点名条目"在测试里摸不到，
/// 只能退化成本文件里出现某个字符串的伪判据 —— 那种判据抓不到
/// "if 恒 false 把整块摘掉"这一类回归。
/// ⇒ 判据对象必须能被测试直接喂数据渲染。
/// ```
///
/// # 它会说的三件事（也**只**说这三件）
/// ```text
/// ① 标题 + "N 个条目"（N 来自真实条目数，不是另算）
/// ② 逐条：名字 / 大小 / 是否目录（目录不显示"0 B"噪声）
/// ③ note 原文 + "可列不可播"（resolvable 恒 false 时显式说出来）
/// ```
/// ⚠️ 这里**不**出现播放 / 下载按钮：能列 ≠ 能播，假入口比没有更糟。
class PanShareListingView extends StatelessWidget {
  const PanShareListingView({super.key, required this.listing});

  final PanShareListing listing;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final shown = listing.entries.take(50).toList(growable: false);
    return Container(
      key: const ValueKey<String>('pan-share-listing'),
      width: double.infinity,
      padding: EdgeInsets.all(Sp.x3),
      decoration: BoxDecoration(
        color: t.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: Radii.rMd,
        border: Border.all(color: t.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            listing.title.isEmpty ? '分享里的文件' : listing.title,
            key: const ValueKey<String>('pan-share-listing-title'),
            textAlign: TextAlign.left,
            style: t.textTheme.labelLarge?.copyWith(
              color: t.colorScheme.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: Sp.x1),
          Text(
            '${listing.count} 个条目',
            key: const ValueKey<String>('pan-share-listing-count'),
            textAlign: TextAlign.left,
            style: t.textTheme.labelSmall?.copyWith(
              color: t.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          for (var i = 0; i < shown.length; i++) ...[
            SizedBox(height: 2),
            Row(
              key: ValueKey<String>('pan-share-listing-entry-$i'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  shown[i].isDir
                      ? AppIcons.folder_outlined
                      : AppIcons.description_outlined,
                  size: 14,
                  color: t.colorScheme.onSurface.withValues(alpha: 0.65),
                ),
                SizedBox(width: Sp.x1),
                Expanded(
                  child: Text(
                    shown[i].name,
                    textAlign: TextAlign.left,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.textTheme.labelSmall
                        ?.copyWith(color: t.colorScheme.onSurface),
                  ),
                ),
                if (shown[i].sizeText.isNotEmpty) ...[
                  SizedBox(width: Sp.x2),
                  Text(
                    shown[i].sizeText,
                    textAlign: TextAlign.right,
                    style: t.textTheme.labelSmall?.copyWith(
                      color: t.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ],
            ),
          ],
          if (listing.count > shown.length) ...[
            SizedBox(height: 2),
            Text(
              '还有 ${listing.count - shown.length} 个条目未列出',
              textAlign: TextAlign.left,
              style: t.textTheme.labelSmall?.copyWith(
                color: t.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
          if (listing.note.isNotEmpty) ...[
            SizedBox(height: Sp.x2),
            Text(
              listing.note,
              key: const ValueKey<String>('pan-share-listing-note'),
              textAlign: TextAlign.left,
              style: t.textTheme.labelSmall?.copyWith(
                color: t.colorScheme.onSurface,
                height: 1.4,
              ),
            ),
          ],
          const SizedBox(height: Sp.x1),
          // ★ 能力边界：能列 ≠ 能播。这句必须**始终**出现（resolvable 恒 false 时）
          if (!listing.resolvable)
            Text(
              '这里只能列出文件，当前版本还不能用它播放（取直链需要登录账号）',
              key: const ValueKey<String>('pan-share-listing-not-resolvable'),
              textAlign: TextAlign.left,
              style: t.textTheme.labelSmall?.copyWith(
                color: t.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
        ],
      ),
    );
  }
}
