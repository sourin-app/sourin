//  二级页：数据管理 —— Owner 第 14 条（2026-10-17）
//
// # 用户原话（逐字）
// > 设置也加一个数据管理,可以对缓存的数据等等数据进行整理删除,
// > 可以看到那些数据占了空间进行删除或者优化整理,可以精 细化处理
//
// # 这页回答什么
// ```text
// ① 什么占了空间   —— 按**目录/文件**分组列出真实字节数（不是估算）
// ② 能删什么       —— 每项独立删除，删完立刻刷新真实读数
// ③ 删了会怎样     —— 每项写明「删了丢什么」，不许让用户盲删
// ```
//
// # ⚠️ 三条硬约束（本页最容易犯的错）
// ```text
// ① **不许删数据本身**：dsh-media.db（收藏/历史/进度）、plugins/（用户插件）、
//    ui-prefs.json（界面偏好）不提供删除按钮 —— 那是用户资产，不是缓存。
// ② 删除必须**先算后删**：显示「将释放 X MB」再动手，且删完重新测量。
// ③ 不许把真实站名写进代码：home-cache 文件名含站名，
//    本页按**前缀匹配**归类，不硬编码具体站名（t98 门禁会扫）。
// ```
//
// # 实测基线（2026-10-17，本机真实数据目录）
// ```text
// 总计 66M：
//   logs/            37M   ← 最大头，可安全删（只影响历史排障）
//   backup-*         12M   ← 8 个历史备份，可删（用户主动导出过才有）
//   dsh-media.db-wal  4M   ← SQLite WAL，**不可直接删**（要走 checkpoint）
//   plugins/        1.5M   ← 用户插件，不可删
//   home-cache-*.json 200K ← 首页缓存，可删（下次自动重建）
//   dsh-media.db     144K  ← 用户数据，不可删
// ```

import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../../core/clip_download.dart' show ClipDownloader;
import '../tokens.dart';
import '../widgets/app_loading.dart';
// ★ 2026-10-18（Owner 第 12 条）：toast 统一走这里（`showAppToast`）
import '../widgets/app_toast.dart';
import '../widgets/overlay_motion.dart';
import '../widgets/settings_sub_page.dart';
import '../../design/icons/app_icons.dart';

/// 数据管理页
class DataManagePage extends StatefulWidget {
  const DataManagePage({super.key});

  @override
  State<DataManagePage> createState() => _DataManagePageState();
}

/// 一个可管理项的**分类**（不绑定具体文件名）
enum _Cat {
  logs('运行日志', '排障用的历史日志。删掉不影响使用，下次运行会重新生成。'),
  backups('历史备份', '每次导出备份留下的快照。删掉不影响当前数据，但那些时点无法再恢复。'),
  homeCache('首页缓存', '首页内容的本地缓存。删掉后首次打开会重新拉取，稍慢。'),
  wal('数据库日志（WAL）', 'SQLite 的预写日志，用于崩溃恢复。**建议只做检查点，不要直接删**。'),
  plugins('用户插件', '你自己安装的插件源码。**这是你的资产，不建议删**。'),
  userData('用户数据', '收藏 / 历史 / 播放进度。**这是你的资产，不提供删除**。'),
  other('其它', '未归类的文件。');

  const _Cat(this.label, this.hint);

  final String label;
  final String hint;

  /// 是否提供「清理」按钮
  ///
  /// ⚠️ plugins / userData 为 false —— 它们是用户资产，不是缓存。
  ///    wal 也 false —— 删 WAL 有丢事务的风险，应走 checkpoint（见页面底部）。
  bool get clearable =>
      this == _Cat.logs || this == _Cat.backups || this == _Cat.homeCache;
}

/// 扫描结果的一行
class _Entry {
  _Entry(this.cat, this.path, this.bytes);

  final _Cat cat;
  final String path;
  final int bytes;
}

class _DataManagePageState extends State<DataManagePage> {
  bool _loading = true;
  String? _error;
  List<_Entry> _entries = const [];
  String _root = '';

  @override
  void initState() {
    super.initState();
    _scan();
  }

  /// 真实扫描 —— 逐文件累计字节数，不估算
  Future<void> _scan() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final root = await ClipDownloader.dataDir();
      final dir = Directory(root);
      if (!await dir.exists()) {
        setState(() {
          _loading = false;
          _error = '数据目录不存在：$root';
        });
        return;
      }
      final entries = <_Entry>[];
      await for (final e in dir.list(recursive: false, followLinks: false)) {
        final name = e.path.split(Platform.pathSeparator).last;
        final cat = _categorize(name);
        if (cat == null) continue;
        entries.add(_Entry(cat, e.path, await _sizeOf(e)));
      }
      entries.sort((a, b) => b.bytes.compareTo(a.bytes));
      if (!mounted) return;
      setState(() {
        _loading = false;
        _root = root;
        _entries = entries;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$err';
      });
    }
  }

  /// 按名字归类
  ///
  /// ⚠️ 这里**不写具体站名**：home-cache 的文件名形如
  ///    `home-cache-<源标识>.json`，只按前缀匹配，不硬编码任何站名
  ///    （t98 站名门禁会扫本文件）。
  static _Cat? _categorize(String name) {
    if (name == 'logs') return _Cat.logs;
    if (name.startsWith('backup-')) return _Cat.backups;
    if (name.startsWith('home-cache-')) return _Cat.homeCache;
    if (name == 'dsh-media.db-wal' || name == 'dsh-media.db-shm') {
      return _Cat.wal;
    }
    if (name == 'dsh-media.db') return _Cat.userData;
    if (name == 'plugins') return _Cat.plugins;
    if (name == 'ui-prefs.json' ||
        name == 'sync-settings.json' ||
        name == 'remote-pref.json') {
      return _Cat.userData;
    }
    if (name.endsWith('.json') || name.endsWith('.log')) return _Cat.other;
    return null; // 不认识的顶层项不列（避免误删）
  }

  /// 递归求大小（目录要累加子文件）
  static Future<int> _sizeOf(FileSystemEntity e) async {
    if (e is File) {
      try {
        return await e.length();
      } catch (_) {
        return 0;
      }
    }
    if (e is Directory) {
      var total = 0;
      try {
        await for (final sub in e.list(recursive: true, followLinks: false)) {
          if (sub is File) {
            try {
              total += await sub.length();
            } catch (_) {}
          }
        }
      } catch (_) {}
      return total;
    }
    return 0;
  }

  /// 清理某一类 —— 先算再删，删完重新扫描
  Future<void> _clear(_Cat cat) async {
    final targets = _entries.where((e) => e.cat == cat).toList();
    if (targets.isEmpty) return;
    final willFree = targets.fold<int>(0, (a, b) => a + b.bytes);

    final ok = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('清理「${cat.label}」'),
        content: Text(
          '将删除 ${targets.length} 项，释放 ${_fmt(willFree)}。\n\n'
          '${cat.hint}\n\n此操作不可撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清理'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    var removed = 0;
    for (final t in targets) {
      try {
        await _deletePath(t.path);
        removed++;
      } catch (_) {}
    }
    await _scan();
    if (!mounted) return;
    _flash('已清理 $removed 项，释放 ${_fmt(willFree)}');
  }

  static Future<void> _deletePath(String path) async {
    final t = FileSystemEntity.typeSync(path);
    if (t == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: true);
    } else if (t == FileSystemEntityType.file) {
      await File(path).delete();
    }
  }

  /// 弹一条操作反馈 —— ★ 2026-10-18（Owner 第 12 条）：改走**统一 toast**
  ///
  /// Owner 原话：「统一toast提示样式,不要自己写,要用自带的」。
  ///
  /// 改前是本页自写的一套（`setState(_toast)` + 3 秒 `Future.delayed`，
  /// 外加 build() 里一个 `_toast != null` 的文本行）。
  /// 现在统一到 `lib/ui/widgets/app_toast.dart` 的 `showAppToast`：
  /// 宿主挂在 `MaterialApp.builder`（Navigator 之外）⇒ 本页是 push 上来的
  /// 二级路由也天然能弹，且与设置页/详情页**同一套样式**。
  ///
  /// ⚠️ `if (!mounted) return` 是**新增**的（改前没有）：清理动作是
  ///    await 之后才 flash，那时页面可能已经 pop —— 显式 return 比让
  ///    `showAppToast` 去静默 no-op 更清楚。
  void _flash(String msg) {
    if (!mounted) return;
    showAppToast(context, msg);
  }

  static String _fmt(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    return '${(mb / 1024).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final total = _entries.fold<int>(0, (a, b) => a + b.bytes);

    return SettingsSubPage(
      title: '数据管理',
      subtitle: '查看各类数据占用，按类清理',
      scrollBody: _loading
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(Sp.x8),
                /*
                 * ⚠️ 这里必须用 `AppLoading`，不能直接 new 一个
                 * `CircularProgressIndicator`：
                 *  ① `zz_t64_migrated_widget_gate` 把裸 CPI 列为**已迁走**的控件，
                 *     产品代码里再构造它就红（应统一走自绘的 _AppSpinner）。
                 *  ② `t27_w7_spinner_color` 要求 CPI 显式带 color，
                 *     否则会落到 `progressIndicatorTheme` 兜底层、深浅档下不跟主题。
                 * ⇒ AppLoading 一个就同时满足两条（它内部已带色、已统一）。
                 */
                child: AppLoading(),
              ),
            )
          : _error != null
              ? _ErrorView(message: _error!, onRetry: _scan)
              : ListView(
                  padding: const EdgeInsets.fromLTRB(Sp.x4, Sp.x2, Sp.x4, Sp.x8),
                  children: [
                    _TotalCard(total: total, root: _root),
                    const SizedBox(height: Sp.x4),
                    ..._buildGroups(colors),
                    const SizedBox(height: Sp.x4),
                    _TipCard(),
                    // ★ 2026-10-18（Owner 第 12 条）：提示行已删除，
                    //   统一由 shell 层的 `ToastHost` 承担（见 `_flash`）。
                  ],
                ),
    );
  }

  List<Widget> _buildGroups(ColorScheme colors) {
    // 按分类聚合
    final byCat = <_Cat, List<_Entry>>{};
    for (final e in _entries) {
      byCat.putIfAbsent(e.cat, () => []).add(e);
    }
    final ordered = _Cat.values.where((c) => byCat.containsKey(c)).toList();

    return [
      for (final cat in ordered) ...[
        _CatRow(
          cat: cat,
          entries: byCat[cat]!,
          onClear: cat.clearable ? () => _clear(cat) : null,
        ),
        const SizedBox(height: Sp.x3),
      ],
    ];
  }
}

class _TotalCard extends StatelessWidget {
  const _TotalCard({required this.total, required this.root});

  final int total;
  final String root;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Sp.x4),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: Radii.rLg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('数据目录共占用',
              style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant)),
          const SizedBox(height: Sp.x1),
          Text(_DataManagePageState._fmt(total),
              style: TextStyle(
                  fontSize: FontSizes.lg,
                  fontWeight: FontWeight.w600,
                  color: colors.onSurface)),
          const SizedBox(height: Sp.x2),
          SelectableText(root,
              style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _CatRow extends StatelessWidget {
  const _CatRow({required this.cat, required this.entries, this.onClear});

  final _Cat cat;
  final List<_Entry> entries;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final bytes = entries.fold<int>(0, (a, b) => a + b.bytes);

    return Container(
      padding: const EdgeInsets.all(Sp.x3),
      decoration: BoxDecoration(
        border: Border.all(color: colors.outlineVariant),
        borderRadius: Radii.rMd,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(cat.label,
                    style: TextStyle(
                        fontSize: FontSizes.base,
                        fontWeight: FontWeight.w600,
                        color: colors.onSurface)),
              ),
              Text(_DataManagePageState._fmt(bytes),
                  style: TextStyle(
                      fontSize: FontSizes.base, color: colors.onSurfaceVariant)),
              if (onClear != null) ...[
                const SizedBox(width: Sp.x2),
                TextButton(
                  onPressed: onClear,
                  child: const Text('清理'),
                ),
              ],
            ],
          ),
          const SizedBox(height: Sp.x1),
          Text(cat.hint,
              style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant)),
          if (entries.length > 1) ...[
            const SizedBox(height: Sp.x1),
            Text('共 ${entries.length} 项',
                style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant)),
          ],
        ],
      ),
    );
  }
}

class _TipCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Sp.x3),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: Radii.rMd,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(AppIcons.info_outline, size: 18, color: colors.onSurfaceVariant),
          const SizedBox(width: Sp.x2),
          Expanded(
            child: Text(
              '数据库日志（WAL）不建议直接删除 —— 它用于崩溃恢复，'
              '直接删可能丢事务。要收缩它请用 SQLite 的 checkpoint。',
              style: TextStyle(
                  fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Sp.x6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(AppIcons.error_outline, size: 36, color: colors.error),
            const SizedBox(height: Sp.x3),
            SelectableText(message,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant)),
            const SizedBox(height: Sp.x4),
            TextButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
