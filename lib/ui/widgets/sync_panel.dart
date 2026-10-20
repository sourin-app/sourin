// ═══════════════════════════════════════════════════════════════════════
//  云盘同步面板（2026-09-29 从 settings_page.dart 搬到「备份与恢复」二级页）
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户指令（原话）
//
// > 云盘同步合并到备份二级页去
//
// # 搬了什么
//
// ```text
// 原来（settings_page.dart 一级页）      现在（本文件 + backup_page.dart）
// ────────────────────────────────────  ──────────────────────────────────
// _Block(title: '云盘同步', …)          SyncPanel.build() 里的 SettingsBlock
// _sync / _syncBusy（宿主字段）         _SyncPanelState 的 _sync / _syncBusy
// _configureWebdav / _testSync          同名方法（搬进来，逻辑一字未改）
// _syncNow / _disconnectSync            同名方法（同上）
// class _WebdavDialog                   搬进本文件（私有，仍只被一处引用）
// ```
//
// # ★ 为什么做成「自包含无参 widget」而不是「把 host 传进来」
//
// 与 `backup_panel.dart` 同一个理由（见那个文件头的「为什么这个页面最简单」）：
// `const SyncPanel({super.key})` 无参、无回调、不依赖宿主 State ⇒
// `backup_page.dart` 里只要多写一行 `SyncPanel()`，**零状态传递**。
//
// ⚠️ 而且这**不是**风格偏好，是硬约束 ——
//    `test/task43_plugins_subpage_test.dart` 会扫 `settings_page.dart`，
//    把「名字像二级页（`*PageState`）」**或**「类体里出现 `host`」的
//    `State` 类取**并集**挑出来，要求每个都含
//    `valueListenable: host._dataRev,` 与 `valueListenable: host._toastRev,`。
//    ⇒ 本面板若叫 `_SyncPageState`、或用了 `host`，就会被**要求订阅宿主**，
//      而它根本没有宿主 ⇒ 测试变红。
//    ⇒ 命名 `_SyncPanelState` + 完全不碰 `host` = **正确沉默**
//      （原 `_WebdavDialogState` 的沉默就是这条判据的既有正例）。
//
// # ★ 两个「搬过来才发现」的行为差异（都按更正确的方向处理了）
//
// ## ① `syncStatus()` 失败 = 「未配置」，不是「加载失败」
//
// 原来它挂在 `loadAll()` 的 `Future.wait` 里 —— 那个 `Future.wait` 外层
// 的 `catch` 会把**整页**变成「加载失败：…」。可是
// `about_page.dart:61-69` 已经实测记过：「用户**没配云盘**时这个接口可能
// 直接报错（那是正常状态，不是故障）」。⇒ 没配云盘的用户本来会连
// 设置页都打不开。现在单独 `try/catch`，失败就当作未配置（`_sync` 保持 null）。
//
// ## ② `_disconnectSync` 现在也置 `_syncBusy`
//
// 原来那一个方法**漏了** `_syncBusy` 的 set/finally（另外三个都有）——
// 断开期间按钮仍然可点。这里补上；行为上只是「点不动」而不是「能连点」。
//
// # 消息怎么报（不再有宿主的 toast）
//
// 原来走宿主的 `_flash()`（写宿主 Stack 里的 toast + `_toastRev`）。
// 本面板在另一条路由上，用不了 ⇒ 改用 `backup_panel.dart:523-534` 的
// 现成范式：**面板内联一行** `_msg(text, color)`。
// 好处是同步结果（「同步完成：收藏(12) / 进度(3)」）会**留在页面上**，
// 不会 3 秒后自己消失。
//
// ═══════════════════════════════════════════════════════════════════════
//  ★ 2026-09-29 第二批：WebDAV 预设 + 保留份数 + 自动 / 手动整体备份
// ═══════════════════════════════════════════════════════════════════════
//
// 用户原话：
// > 配置云盘这里,搞几个预设,点击后自动填充域名和配置信息,比如坚果云,
// > 选择后自动填充坚果云的网址 然后默认也是选择坚果云
//
// > 还要可以配置最多保存数量,按照日期时间保存,最多保存指定数量,默认10个,
// > 可以自动,也可以手动,比如 间隔多长时间保存一次,或者有数据变动就保存,
// > 这可以参考 阅读 app这个保存阅读记录的方式去保存,他那个就耗很低的流量,
// > 好像整体备份和别的备份是拆分开的,你调研一下然后实现
//
// # ① 预设（`_kWebdavPresets`）
//
// 只放**官方文档能查证**的服务地址。联网调研的逐条来源见
// `.probe/t91_sync_iface.md`（契约）与下面预设表里每个条目的注释；
// 凡是「功能存在但地址只有第三方文档」的一律**不收录**
// （123云盘 / 城通 / 天翼云 / 移动云盘），**明确没有 WebDAV 的绝不编**
// （百度网盘 / 阿里云盘 / 腾讯微云 / 夸克 / Box —— Box 官方 2023 年已下线 WebDAV）。
//
// ★ 踩过的坑：坚果云国际版 `nutstore.net` **没有**独立 WebDAV 地址
//   （实测该站所有链接都指回 `jianguoyun.com`）⇒ 全仓**不得**出现
//   `dav.nutstore.net` 之类编造的地址（`test/t91_sync_presets_test.dart` 有断言）。
//
// # ② 为什么是「保留份数」而不是「保留天数」
//
// 用户要的是「最多保存指定数量,默认10个」。后端按**文件名里的日期时间**排序
// （`dsh-backup-<设备>-yyyyMMdd-HHmmss.zip` 定长 ⇒ 字典序即时间序），
// 超出份数就删最旧的；`retainCount` 由 Rust 侧兜底 `max(1, …)`。
//
// ★ 这里用**选项胶囊**而不是数字输入框：
//   ① 本仓已有 `SettingsGestureChoice`（设置页手势配置在用），一点即改、无校验分支；
//   ② 数字框要处理空串 / 0 / 超大值 / 防抖，收益只是「任意 N」——
//      而 API（`SourinApi.setSyncSettings(retainCount: …)`）本来就能收任意 N，
//      将来想改成输入框不必动后端。
//
// # ③ 为什么有**两个**间隔（别合并！）
//
// 这是照「阅读 App 分开存」的结论做的（详见 `models.dart` 里 `SyncSettings`
// 的注释与 `.probe/t91_sync_iface.md` §6）：
//
// ```text
// 增量同步（几 KB）  data/favorites.jsonl + progress.jsonl + providers.json
//                    「多久看一眼云端」= autoIntervalMinutes（默认 30 分钟）
// 整体备份（整包 zip）backup/snapshots/dsh-backup-*.zip
//                    「整包备份间隔」  = autoBackupIntervalMinutes（默认 1 天）
// ```
//
// ★ 如果只有一个间隔，打开自动同步就等于「每 30 分钟上传一个整包」——
//   那正是用户说的「耗流量」。两个间隔分开之后：
//   没数据变动 ⇒ 签名不变 ⇒ **一个写请求都不发**（只 GET 比对）。
//
// # ④ 手动那一路
//
// 「立即备份」= `sync_backup_now`（上传一份 + 按份数清理旧份）；
// 下面的列表列出云端已有的份，可以逐份删除（★ 云盘删除通常**不进回收站**，
// 所以删除前有确认框，确认框里写明这一点）。
//
// ⚠️ 「改小保留份数」不会立刻删 —— 后端是在**下一次上传成功后**才跑清理。
//    所以胶囊下面那句提示写的是「下次备份时自动删掉多出来的」。

import 'package:material_ui/material_ui.dart';

import '../../core/sourin_api.dart';
import '../tokens.dart';
import 'overlay_motion.dart';
import '../../design/widgets/app_glass_dialog.dart';
import '../../design/widgets/app_text_button.dart';
import 'settings_kit.dart';
import '../../design/icons/app_icons.dart';

/// 云盘同步面板（WebDAV）
///
/// 自包含：无参、无回调、不依赖宿主 State —— 见文件头。
class SyncPanel extends StatefulWidget {
  const SyncPanel({super.key});

  @override
  State<SyncPanel> createState() => _SyncPanelState();
}

class _SyncPanelState extends State<SyncPanel> {
  SyncStatus? _sync;
  SyncSettings? _settings;
  List<SyncBackupEntry> _backups = const [];
  bool _syncBusy = false;

  /*
   * ★ 凭据同步状态（CS-1）
   *
   * `null` = 还没读到（或核心库不可用）。
   * ⚠️ 读到 `null` 时状态行显示「凭据未同步（状态未知）」——
   *    **不许**退化成"同步完成"或干脆不显示（那就是假绿）。
   */
  CredentialsStatus? _cred;

  /// 面板内联消息（替代原来的宿主 toast，见文件头「消息怎么报」）
  String _ok = '';
  String _err = '';

  /// 忙的时候正在做哪一步（进度圈旁边那行字）
  ///
  /// 用一个字段而不是从 `_ok` 反推：`_ok` 是**结果**，
  /// 一旦某步失败它会被 `_sayErr` 清掉，进度圈就没了文字。
  String _busyHint = '';

  /// 四个动作都用它包一层，把 `_syncBusy` 与提示语绑在一起 ——
  /// 少写一处 `setState(() => _syncBusy = true)` 就少一处忘记置提示的错误。
  Future<T?> _busy<T>(String hint, Future<T> Function() body) async {
    if (!mounted) return null;
    setState(() {
      _syncBusy = true;
      _busyHint = hint;
    });
    try {
      return await body();
    } finally {
      if (mounted) {
        setState(() {
          _syncBusy = false;
          _busyHint = '';
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  /// 拉一次同步状态 + 设置 + 云端备份列表
  ///
  /// ⚠️ `syncStatus()` 失败**不是**故障：没配云盘时后端可能直接报错（见文件头 ①）。
  /// 而 `syncSettings()` / `syncBackupList()` 按契约「永不失败」
  /// （没配云盘时前者回默认值、后者回空列表，见 `.probe/t91_sync_iface.md` §3.1）。
  Future<void> _reload() async {
    try {
      final s = await SourinApi.syncStatus();
      if (!mounted) return;
      setState(() => _sync = s);
    } catch (e) {
      debugPrint('[SYNC] 云盘状态读取失败（未配置时属正常）: $e');
    }
    await _reloadSettings();
    /*
     * ★ 顺序：备份列表在凭据状态**之前**。
     *
     * 这不是随意排的 —— 每多一次串行 `await`，后面那次就多晚一帧才拿到数据。
     * 实测：把凭据状态插在中间后，`t95` 的「已连接态」用例
     * （只 `pump` 50ms）看到的是「云端备份（0 份）」而不是 3 份 ——
     * 数据没错，是**还没回来**。⇒ 把新加的那次放到最后，
     * 保证既有面板的时序不被改变。
     */
    await _reloadBackups();
    await _reloadCredentials();
  }

  /// 读凭据同步状态
  ///
  /// 契约上**永不失败**（纯本地读），但仍包一层：核心库不可用时
  /// `callAsync` 会抛 —— 那时 `_cred` 保持 `null`，状态行显示"状态未知"。
  Future<void> _reloadCredentials() async {
    try {
      final c = await SourinApi.credentialsStatus();
      if (!mounted) return;
      setState(() => _cred = c);
    } catch (e) {
      debugPrint('[SYNC] 凭据同步状态读取失败: $e');
    }
  }

  Future<void> _reloadSettings() async {
    try {
      final s = await SourinApi.syncSettings();
      if (!mounted) return;
      setState(() => _settings = s);
    } catch (e) {
      // 契约上不该发生（§3.1 永不失败）—— 真发生了也别把面板搞崩
      debugPrint('[SYNC] 云盘设置读取失败（契约上不该发生）: $e');
    }
  }

  Future<void> _reloadBackups() async {
    try {
      final list = await SourinApi.syncBackupList();
      if (!mounted) return;
      setState(() => _backups = list);
    } catch (e) {
      debugPrint('[SYNC] 云端备份列表读取失败（未配置时属正常）: $e');
    }
  }

  void _sayOk(String m) {
    if (!mounted) return;
    setState(() {
      _ok = m;
      _err = '';
    });
  }

  void _sayErr(String m) {
    if (!mounted) return;
    setState(() {
      _err = m;
      _ok = '';
    });
  }

  Future<void> _configureWebdav() async {
    final r =
        await showAppDialog<
          ({String url, String user, String pass, String dir})
        >(
          context: context,
          // ★ 把已配置的地址/用户名/目录传进去 ⇒ 对话框打开时就是「当前值」，
          //   而不是每次都空白重填（`_settings` 可能还没拉到，那就走默认 坚果云）
          builder: (_) => _WebdavDialog(initial: _settings),
        );
    if (r == null) return;

    await _busy('正在检查地址并准备目录…', () async {
      try {
        /*
         * ★ 后端会「先建目录再自检」并返回自检结果
         *
         * 原版 2026-09-15 修的 bug：`test()` 会 PROPFIND 含 remote_dir
         * 的完整路径，目录不存在就 404 → 报「路径不存在」让用户
         * 以为填错了地址。所以必须 prepare() 在前。
         */
        final msg = await SourinApi.configureWebdav(
          baseUrl: r.url,
          username: r.user,
          password: r.pass,
          remoteDir: r.dir.isEmpty ? null : r.dir,
        );
        await _reload();
        _sayOk(msg);
      } catch (e) {
        _sayErr('配置失败：$e');
      }
    });
  }

  Future<void> _testSync() async {
    await _busy('正在测试连接…', () async {
      try {
        final msg = await SourinApi.testSync();
        _sayOk(msg);
      } catch (e) {
        _sayErr('测试失败：$e');
      }
    });
  }

  Future<void> _syncNow() async {
    await _busy('正在同步…', () async {
      try {
        final sums = await SourinApi.syncNow();
        await _reload();
        _sayOk(_fmtSyncResult(sums));
      } catch (e) {
        _sayErr('同步失败：$e');
      }
    });
  }

  /// 把每一步的汇总说成人话
  ///
  /// ★ 只列**真的动了**的平面 —— 三个平面全 0 时说「无变化」，
  ///   而不是把「收藏与追更(0) / 播放进度(0) / 内容源配置(0)」端给用户。
  static String _fmtSyncResult(List<SyncSummary> sums) {
    if (sums.isEmpty) return '同步完成（没有可同步的内容）';
    final moved = sums.where((s) => s.total > 0).toList();
    if (moved.isEmpty) return '同步完成（收藏、进度、内容源都没有变化）';

    final parts = <String>[];
    for (final s in moved) {
      final bits = <String>[
        if (s.pulled > 0) '拉取 ${s.pulled}',
        if (s.pushed > 0) '上传 ${s.pushed}',
      ];
      final base = '${s.label}：${bits.join(' / ')}';
      parts.add(s.conflicts > 0 ? '$base（有 ${s.conflicts} 条按较新的一份为准）' : base);
    }
    return '同步完成 —— ${parts.join('；')}';
  }

  // ── 整体备份（手动那一路，契约 §1/§5）─────────────────────────────

  /// 立即上传一份整体备份，并按保留份数清理旧份
  Future<void> _backupNow() async {
    await _busy('正在打包并上传…', () async {
      try {
        final r = await SourinApi.syncBackupNow();
        await _reloadBackups();
        final pruned =
            r.pruned.isEmpty ? '' : '，并清理了 ${r.pruned.length} 份旧备份';
        _sayOk(
          '已备份 ${_fmtBytes(r.bytes)}，云端现有 ${r.total} 份$pruned',
        );
      } catch (e) {
        _sayErr('备份失败：$e');
      }
    });
  }

  Future<void> _deleteBackup(SyncBackupEntry e) async {
    final ok = await _confirm(
      title: '删除云端备份',
      message:
          '确定删掉云端的这一份备份吗？\n\n'
          '${e.name}\n\n'
          '⚠️ 云盘上的删除一般不进回收站，删了就找不回来了。',
      okLabel: '删除',
    );
    if (!ok) return;
    await _busy('正在删除…', () async {
      try {
        await SourinApi.syncBackupDelete(e.name);
        await _reloadBackups();
        _sayOk('已删除这份备份');
      } catch (err) {
        _sayErr('删除失败：$err');
      }
    });
  }

  // ── 设置（保留份数 / 自动同步 / 两个间隔，契约 §1/§2/§6）─────────────

  /// 只改传进来的字段，其余保持不动；返回改完的完整设置
  Future<void> _patch({
    int? retainCount,
    bool? autoEnabled,
    int? autoIntervalMinutes,
    bool? autoOnChange,
    int? autoBackupIntervalMinutes,
  }) async {
    // `SettingsGestureToggle` 的 onChanged 不可为 null（见 settings_kit.dart），
    // 所以「忙时点不动」得在这里挡。
    if (_syncBusy) return;
    await _busy('正在保存设置…', () async {
      try {
        final s = await SourinApi.setSyncSettings(
          retainCount: retainCount,
          autoEnabled: autoEnabled,
          autoIntervalMinutes: autoIntervalMinutes,
          autoOnChange: autoOnChange,
          autoBackupIntervalMinutes: autoBackupIntervalMinutes,
        );
        if (!mounted) return;
        setState(() => _settings = s);
        _sayOk('设置已保存，最多 1 分钟后按新设置自动执行');
      } catch (e) {
        _sayErr('设置保存失败：$e');
      }
    });
  }

  // ── ★ 凭据同步（CS-1，2026-10-19）────────────────────────────────
  //
  // 登录态随云同步：口令存系统钥匙串，凭据加密后跟着云盘走。
  //
  // # ★★ 状态行是这一段的全部意义（防假绿）
  //
  // ```text
  // 未设口令 + 开关开着  ⇒ 「凭据未同步（未设置口令）」  ← 最容易写成"完成"的那条
  // 开关关着            ⇒ 「凭据未同步（未开启）」
  // 两个都满足          ⇒ 「凭据将同步：N 个源」
  // 状态读不到          ⇒ 「凭据未同步（状态未知）」
  // ```
  //
  // ⚠️ 判据用后端给的 `willSync`（= enabled && passphraseSet），
  //    **不在这里自己拼** —— 自己拼必然有人漏一个条件。

  /// 开关凭据同步
  Future<void> _toggleCredentials(bool on) async {
    await _busy('正在保存凭据同步设置…', () async {
      try {
        final c = await SourinApi.setCredentialsEnabled(on);
        if (!mounted) return;
        setState(() => _cred = c);
        /*
         * ★★ 开了开关但没设口令 ⇒ **必须**提示"还没真正同步"。
         *
         * 只报"已开启"会让用户以为登录态已经在走了 —— 那正是假绿。
         */
        if (on && !c.passphraseSet) {
          _sayErr('已开启，但还没设置口令 ⇒ 凭据未同步。请点「设置口令」。');
        } else {
          _sayOk('凭据同步${on ? '已开启' : '已关闭'}');
        }
      } catch (e) {
        _sayErr('凭据同步设置保存失败：$e');
      }
    });
  }

  /// 设 / 改 / 清口令
  Future<void> _setPassphrase() async {
    final r = await showAppDialog<({String pass, bool clear})>(
      context: context,
      builder: (_) => _PassphraseDialog(hasExisting: _cred?.passphraseSet == true),
    );
    if (r == null) return;

    await _busy('正在保存口令…', () async {
      try {
        final c = await SourinApi.setCredentialsPassphrase(r.clear ? '' : r.pass);
        if (!mounted) return;
        setState(() => _cred = c);
        if (r.clear) {
          _sayOk('口令已清除 —— 凭据将不再同步');
        } else {
          _sayOk(
            c.enabled
                ? '口令已设置，下次同步会带上登录态'
                : '口令已设置（凭据同步开关还关着）',
          );
        }
      } catch (e) {
        _sayErr('口令保存失败：$e');
      }
    });
  }

  /// 当前状态行文案（**唯一判据**，见上面的大段注释）
  ///
  /// ★ 抽成方法而不是写在 build 里：这样单测能直接断言文案，
  ///   而不用去 find 某个 `Text`（后者会把排版也绑进断言）。
  String _credLabel(CredentialsStatus? c) {
    /*
     * ★ 读不到状态时**也走同一条判据**（`CredentialsStatus.unknown.statusLabel`），
     *   而不是在这里另写一句 "凭据未同步（状态未知）"。
     *   理由是实测出来的：面板里再写一份，同一句话就有两个渲染点，
     *   而本门禁的"唯一性"检查会把它们判红 —— 因为故障注入只能打中一个。
     */
    return (c ?? CredentialsStatus.unknown).statusLabel;
  }

  /// 状态行的颜色：真的会同步才用主题色，否则用中性色
  ///
  /// ⚠️ **不许**在"未设置口令"时用成功色 —— 颜色本身也是判据，
  ///   绿色的「凭据未同步」比文字更容易被误读成"没问题"。
  Color _credColor(CredentialsStatus? c, ColorScheme colors) =>
      (c?.willSync ?? false) ? colors.primary : colors.onSurfaceVariant;

  /// 凭据同步那一块 UI
  Widget _credentialsSection(ColorScheme colors) {
    final c = _cred;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _subTitle(colors, '登录态（凭据）'),
        const SizedBox(height: Sp.x1),
        _note(
          colors,
          '把各内容源已保存的登录态一起同步到云盘，换设备不用重新登录。'
          '凭据用你的口令加密后才上传（AES-256-GCM），口令本身只存在系统钥匙串里。',
        ),
        const SizedBox(height: Sp.x2),
        // ★★ 状态行 —— 未设口令时**必须**显示「凭据未同步」
        Row(
          children: [
            Icon(
              (c?.willSync ?? false)
                  ? AppIcons.check_circle_outline
                  : AppIcons.error_outline,
              size: 14,
              color: _credColor(c, colors),
            ),
            const SizedBox(width: Sp.x1),
            Flexible(
              child: Text(
                _credLabel(c),
                key: const ValueKey('sync-credentials-status'),
                style: TextStyle(
                  fontSize: FontSizes.cap,
                  color: _credColor(c, colors),
                ),
              ),
            ),
          ],
        ),
        /*
         * ★★ 同步**方向**的说明**不在这里另起一行**。
         *
         * # 为什么不（这是实测发现的重复）
         *
         * 第一版我在状态行下面又加了一行 `_note(directionNote)`，
         * 而 `statusLabel` 里**也**含这句 ⇒ 屏幕上同一句话出现两次。
         * 更糟的是它让门禁失去判别力：
         * ```text
         * 注入"把 statusLabel 里的方向语义去掉" ⇒ 面板上仍有那行独立 note
         * ⇒ find.textContaining('仅上行') 照样找得到 ⇒ **门禁仍绿**
         * ```
         * ⇒ 方向文案**只有一个渲染点**（就是状态行那个 Text），
         *   门禁断言它，注入才真的会红。
         */
        if (c != null && c.plaintextPasswordProviders.isNotEmpty) ...[
          const SizedBox(height: Sp.x2),
          // ★ 明文存了账号密码的源 —— 单独提示（比 Cookie 严重一档）
          _note(
            colors,
            '⚠️ 这些源把「账号密码明文」存在本机：'
            '${c.plaintextPasswordProviders.join('、')}。'
            '它们会被一起加密同步 —— 如果你不希望密码离开这台设备，'
            '请先在这些源里登出，再关闭上面的开关。',
          ),
        ],
        const SizedBox(height: Sp.x3),
        SettingsGestureToggle(
          label: '随云盘同步登录态',
          hint: '关掉后只同步收藏 / 追更 / 进度 / 源配置',
          value: c?.enabled ?? false,
          onChanged: _toggleCredentials,
        ),
        const SizedBox(height: Sp.x3),
        Wrap(
          spacing: Sp.x2,
          runSpacing: Sp.x2,
          children: [
            OutlinedButton.icon(
              onPressed: _syncBusy ? null : _setPassphrase,
              icon: const Icon(AppIcons.lock_outline, size: 16),
              label: Text(
                (c?.passphraseSet ?? false) ? '修改口令' : '设置口令',
              ),
            ),
            if (c?.passphraseSet ?? false)
              OutlinedButton.icon(
                onPressed: _syncBusy ? null : _clearPassphrase,
                icon: const Icon(AppIcons.delete_outline, size: 16),
                label: const Text('清除口令'),
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _clearPassphrase() async {
    final ok = await _confirm(
      title: '清除凭据同步口令',
      message: '清除后：\n\n'
          '· 登录态「不再」同步（云端已有的那份不会被删）\n'
          '· 已导出的含凭据的备份包「仍然需要」那个口令才能导入\n\n'
          '忘记口令时也只能清除后重新设一个（旧包就解不开了）。',
      okLabel: '清除',
    );
    if (!ok) return;
    await _busy('正在清除口令…', () async {
      try {
        final c = await SourinApi.setCredentialsPassphrase('');
        if (!mounted) return;
        setState(() => _cred = c);
        _sayOk('口令已清除');
      } catch (e) {
        _sayErr('清除失败：$e');
      }
    });
  }

  Future<void> _disconnectSync() async {
    final ok = await _confirm(
      title: '断开云盘',
      message:
          '确定断开云盘同步吗？\n\n'
          '凭据仍保留在系统钥匙串里，重新配置时不用再输密码。',
    );
    if (!ok) return;
    await _busy('正在断开…', () async {
      try {
        await SourinApi.disconnectSync();
        await _reload();
        _sayOk('已断开云盘（密码仍保留在系统中）');
      } catch (e) {
        _sayErr('$e');
      }
    });
  }

  /// 本地确认框（原来借用宿主 `SettingsPageState._confirm`）
  Future<bool> _confirm({
    required String title,
    required String message,
    String okLabel = '确定',
    String? cancelLabel = '取消',
  }) async {
    final r = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AppGlassDialog(
        title: title,
        content: Text(message),
        // ★ `cancelLabel == null` 时**不画取消钮**（与改前 `if (cancelLabel != null)`
        //   逐字等价）—— AppGlassDialogActions 固定两键，这一档自己拼。
        // 改前确认键是 FilledButton（主色）⇒ 非错误色。
        actions: cancelLabel == null
            ? AppTextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(okLabel),
              )
            : AppGlassDialogActions(
                cancelLabel: cancelLabel,
                confirmLabel: okLabel,
                confirmIsDestructive: false,
                onCancel: () => Navigator.pop(ctx, false),
                onConfirm: () => Navigator.pop(ctx, true),
              ),
      ),
    );
    return r ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final connected = _sync?.connected == true;
    final s = _settings;

    return SettingsBlock(
      title: '云盘同步',
      trailing: Text(
        connected ? '已连接' : '未配置',
        style: TextStyle(
          fontSize: FontSizes.cap,
          color: connected ? colors.primary : colors.onSurfaceVariant,
        ),
      ),
      children: [
        Text(
          '收藏、追更、播放进度与内容源配置会跨设备同步。'
          '支持任意 WebDAV 服务（坚果云、Nextcloud、群晖等）。',
          style: TextStyle(
            fontSize: FontSizes.sm,
            color: colors.onSurfaceVariant,
            height: 1.6,
          ),
        ),
        // ★ 已连接时把「连的是哪、账号是谁、目录在哪、上次什么时候同步过」
        //   摆出来 —— 换到第二台设备后用户要靠这三行确认自己没连错地方。
        if (connected) ...[
          const SizedBox(height: Sp.x3),
          _connInfo(colors, s),
        ],
        const SizedBox(height: Sp.x4),
        Wrap(
          spacing: Sp.x2,
          runSpacing: Sp.x2,
          children: [
            FilledButton.tonalIcon(
              onPressed: _syncBusy ? null : _configureWebdav,
              icon: const Icon(AppIcons.cloud_outlined, size: 16),
              label: Text(connected ? '重新配置' : '配置云盘'),
            ),
            if (connected) ...[
              OutlinedButton.icon(
                onPressed: _syncBusy ? null : _testSync,
                icon: const Icon(AppIcons.network_check, size: 16),
                label: const Text('测试连接'),
              ),
              OutlinedButton.icon(
                onPressed: _syncBusy ? null : _syncNow,
                icon: const Icon(AppIcons.sync, size: 16),
                label: const Text('立即同步'),
              ),
              FilledButton.tonalIcon(
                onPressed: _syncBusy ? null : _backupNow,
                icon: const Icon(AppIcons.backup_outlined, size: 16),
                label: const Text('立即备份'),
              ),
              OutlinedButton.icon(
                onPressed: _syncBusy ? null : _disconnectSync,
                icon: const Icon(AppIcons.link_off, size: 16),
                label: const Text('断开'),
              ),
            ],
          ],
        ),
        /*
         * ★ 凭据同步（CS-1）
         *
         * ⚠️ **不受 `connected` 门控** —— 与自动备份那几块不同：
         *    用户可以先设口令、再配云盘（两个独立操作）。
         *    而"没口令 ⇒ 必须显示未同步"这条判据，恰好在
         *    **还没连上云盘**时最容易被漏掉（界面以为没什么可显示的）。
         */
        const SizedBox(height: Sp.x5),
        _credentialsSection(colors),
        // ★ 忙时给一行明确的进度文案 ——
        //   网络操作要好几秒到几十秒（整包备份更大），按钮变灰但页面
        //   毫无变化的话，用户会以为「点了没反应」而去连点。
        if (_syncBusy) ...[
          const SizedBox(height: Sp.x3),
          _busyLine(colors),
        ],
        if (connected && s != null) ...[
          const SizedBox(height: Sp.x5),
          _autoSection(colors, s),
          const SizedBox(height: Sp.x5),
          _backupSection(colors),
        ],
        if (_err.isNotEmpty) ...[
          const SizedBox(height: Sp.x3),
          _msg(_err, colors.error),
        ],
        if (_ok.isNotEmpty) ...[
          const SizedBox(height: Sp.x3),
          _msg(_ok, colors.primary),
        ],
      ],
    );
  }

  /// 已连接时的连接详情（地址 / 账号 / 目录 / 上次同步）
  ///
  /// 用户会同时开好几台设备，改错地址的代价（数据写到别人的网盘目录里）
  /// 比什么都大，所以这四行常驻。
  Widget _connInfo(ColorScheme colors, SyncSettings? s) {
    final backend = _sync?.backend;
    final rows = <(String, String)>[
      if (backend != null && backend.isNotEmpty) ('服务', backend),
      if (s != null && s.baseUrl.isNotEmpty) ('地址', s.baseUrl),
      if (s != null && s.username.isNotEmpty) ('账号', s.username),
      if (s != null)
        ('目录', s.remoteDir.isEmpty ? '网盘根目录' : s.remoteDir),
      if (s != null && s.lastSyncAt > 0)
        ('上次同步', _fmtTime(s.lastSyncAt)),
      if (s != null && s.lastBackupAt > 0)
        ('上次备份', _fmtTime(s.lastBackupAt)),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (k, v) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '$k　',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                  TextSpan(
                    text: v,
                    style: TextStyle(color: colors.onSurface),
                  ),
                ],
              ),
              style: TextStyle(fontSize: FontSizes.cap, height: 1.6),
            ),
          ),
      ],
    );
  }

  /// 忙时的那一行
  ///
  /// 用固定尺寸的进度圈而不是 `setState` 里的第二个状态 ——
  /// 动画交给 widget 自己跑，避免每次 `setState` 都重建整页。
  Widget _busyLine(ColorScheme colors) => Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            // T27-07：onSurface 随主题（dark #FAFAFA / light 近黑）。
            child: CircularProgressIndicator(color: colors.onSurface, strokeWidth: 2),
          ),
          const SizedBox(width: Sp.x2),
          Text(
            _busyHint,
            style: TextStyle(
              fontSize: FontSizes.cap,
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      );

  /// 自动同步 / 备份设置（只在已连接时显示 —— 这些参数由云端那一路用）
  Widget _autoSection(ColorScheme colors, SyncSettings s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _subTitle(colors, '自动备份'),
        const SizedBox(height: Sp.x1),
        _note(
          colors,
          '增量同步只传收藏/追更/进度的接口（几 KB）；'
          '「整体备份」才把整包传上去。参考阅读 App 的做法：进度随时同步，'
          '整包一天一份 —— 数据没变动时后端一个写请求都不发。',
        ),
        const SizedBox(height: Sp.x3),
        SettingsGestureToggle(
          label: '自动同步',
          hint: '关掉后只能手动同步 / 手动备份；改完最多 1 分钟生效',
          value: s.autoEnabled,
          onChanged: (v) => _patch(autoEnabled: v),
        ),
        if (s.autoEnabled) ...[
          const SizedBox(height: Sp.x3),
          SettingsGestureToggle(
            label: '数据变动就同步',
            hint: '收藏 / 追更 / 进度一有变化就同步',
            value: s.autoOnChange,
            onChanged: (v) => _patch(autoOnChange: v),
          ),
          const SizedBox(height: Sp.x3),
          SettingsGestureChoice<int>(
            label: '多久看一眼云端（增量同步）',
            options: _withCurrent(const [0, 10, 30, 60], s.autoIntervalMinutes),
            value: s.autoIntervalMinutes,
            labelOf: _intervalLabel,
            onChanged: (v) => _patch(autoIntervalMinutes: v),
          ),
          const SizedBox(height: Sp.x3),
          SettingsGestureChoice<int>(
            label: '整体备份间隔（上传整包）',
            options: _withCurrent(const [
              0,
              60,
              360,
              720,
              1440,
              4320,
              10080,
            ], s.autoBackupIntervalMinutes),
            value: s.autoBackupIntervalMinutes,
            labelOf: _backupIntervalLabel,
            onChanged: (v) => _patch(autoBackupIntervalMinutes: v),
          ),
        ],
        const SizedBox(height: Sp.x3),
        SettingsGestureChoice<int>(
          label: '云端最多保留几份整体备份',
          options: _withCurrent(const [3, 5, 10, 20, 50], s.retainCount),
          value: s.retainCount,
          labelOf: (n) => '$n 份',
          onChanged: (v) => _patch(retainCount: v),
        ),
        const SizedBox(height: Sp.x1),
        _note(
          colors,
          '超出份数的旧备份会在下一次备份成功后自动删掉。'
          '只会删除本应用自己创建的 dsh-backup- 开头的备份，'
          '该目录里的其它文件一律不动。',
        ),
      ],
    );
  }

  /// 云端已有备份的列表（可逐份删除）
  Widget _backupSection(ColorScheme colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _subTitle(colors, '云端备份（${_backups.length} 份）'),
        const SizedBox(height: Sp.x1),
        _note(
          colors,
          '每份都是完整的 zip（收藏 / 追更 / 进度 / 源配置 / 插件），'
          '按「设备 + 日期时间」命名。',
        ),
        const SizedBox(height: Sp.x3),
        if (_backups.isEmpty)
          Text(
            '云端还没有备份。点上面的「立即备份」传一份。',
            style: TextStyle(
              fontSize: FontSizes.cap,
              color: colors.onSurfaceVariant,
              height: 1.6,
            ),
          )
        else
          for (final e in _backups) _backupRow(colors, e),
      ],
    );
  }

  Widget _backupRow(ColorScheme colors, SyncBackupEntry e) {
    final meta = _parseBackupName(e.name);
    final when = meta.time.isNotEmpty ? meta.time : _fmtTime(e.modified);
    final sub = [
      if (meta.device.isNotEmpty) meta.device,
      _fmtBytes(e.bytes),
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.x1),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  when,
                  style: TextStyle(
                    fontSize: FontSizes.sm,
                    color: colors.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  sub,
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: _syncBusy ? null : () => _deleteBackup(e),
            icon: const Icon(AppIcons.delete_outline, size: 18),
            tooltip: '删除这一份',
          ),
        ],
      ),
    );
  }

  Widget _subTitle(ColorScheme colors, String text) => Text(
    text,
    style: TextStyle(
      fontSize: FontSizes.sm,
      fontWeight: FontWeight.w600,
      color: colors.onSurface,
    ),
  );

  Widget _note(ColorScheme colors, String text) => Text(
    text,
    style: TextStyle(
      fontSize: FontSizes.cap,
      color: colors.onSurfaceVariant,
      height: 1.6,
    ),
  );

  Widget _msg(String text, Color color) => Text(
    text,
    style: TextStyle(fontSize: FontSizes.sm, color: color, height: 1.6),
  );

  // ── 小工具（`backup_panel.dart` 里同名的两个是**私有**的，跨文件用不了；
  //    抽公共 util 要动那个被断言锁住的文件，不划算 —— 这里各写一份）──

  /// 选项里万一没有当前值（例如设置文件是在别处写的），把当前值补进去
  /// —— 否则 `SettingsGestureChoice` 会一个胶囊都不高亮，看起来像没选中。
  static List<int> _withCurrent(List<int> base, int v) {
    if (base.contains(v)) return base;
    return [...base, v]..sort();
  }

  static String _intervalLabel(int m) {
    if (m <= 0) return '仅变动时';
    if (m < 60) return '$m 分钟';
    if (m % 60 == 0) return '${m ~/ 60} 小时';
    return '$m 分钟';
  }

  static String _backupIntervalLabel(int m) {
    if (m <= 0) return '关';
    if (m < 60) return '$m 分钟';
    if (m < 1440) return '${m ~/ 60} 小时';
    if (m % 1440 == 0) return '${m ~/ 1440} 天';
    return '${(m / 1440).toStringAsFixed(1)} 天';
  }

  static String _fmtBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  static String _fmtTime(int ms) {
    if (ms <= 0) return '时间未知';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String p(int x) => x.toString().padLeft(2, '0');
    return '${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}';
  }

  /// 拆 `dsh-backup-<设备>-<yyyyMMdd>-<HHmmss>.zip` ⇒ 给人看的「时间 + 设备」
  ///
  /// ★ 时间取**文件名里**那个（= 导出时刻，本地时区），不用远端 mtime ——
  ///   后者是服务器收文件的时刻，时区也未必和用户一致。拆不出来才退回 mtime。
  static ({String time, String device}) _parseBackupName(String name) {
    var s = name;
    if (s.startsWith('dsh-backup-')) {
      s = s.substring('dsh-backup-'.length);
    }
    if (s.toLowerCase().endsWith('.zip')) {
      s = s.substring(0, s.length - 4);
    }
    // 设备名里的 `-`/`_` 是保留的（`backup::default_backup_name` 会净化），
    // 所以设备段本身可能含 `-` ⇒ 前一段用贪婪匹配。
    final m = RegExp(r'^(.*)-(\d{8})-(\d{6})$').firstMatch(s);
    if (m == null) return (time: '', device: s);
    final d = m.group(2)!;
    final t = m.group(3)!;
    return (
      time:
          '${d.substring(0, 4)}-${d.substring(4, 6)}-${d.substring(6, 8)} '
          '${t.substring(0, 2)}:${t.substring(2, 4)}:${t.substring(4, 6)}',
      device: m.group(1) ?? '',
    );
  }
}

/// WebDAV 配置对话框
///
/// [initial] 非空时用当前已保存的地址/用户名/目录预填（重新配置的场景），
/// 为空时默认选中**坚果云**并把地址填好（用户要求：默认也是选择坚果云）。
class _WebdavDialog extends StatefulWidget {
  const _WebdavDialog({this.initial});

  final SyncSettings? initial;

  @override
  State<_WebdavDialog> createState() => _WebdavDialogState();
}

class _WebdavDialogState extends State<_WebdavDialog> {
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _dir = TextEditingController();

  /// 最近一次点过的预设（**注意**：它只管「提示文案」，
  /// 胶囊的「选中」是另外算的 —— 见下面 `_urlMatchesPreset`）
  _WebdavPreset? _preset;

  /// 地址校验提示（例如还留着 `<主机>` 占位符没替换）
  String _hint = '';

  /// ★ 远程目录是不是**用户自己定的**
  ///
  /// 用户要求（原话）：「webdav 的默认就用那个占位，软件的名字，
  /// **除非用户主动删除那个输入框的名字或者修改才按照用户的意思来**」。
  ///
  /// 所以默认值 = 软件名（[kDefaultWebdavDir]），但**一旦这个值有了
  /// 用户意志**（自己删空、自己改字、或者来自上一次保存的配置），
  /// 就不再被任何自动逻辑覆盖 —— 尤其是切预设时不许"顺手补回来"。
  bool _dirFromUser = false;

  @override
  void initState() {
    super.initState();
    final init = widget.initial;
    if (init != null && init.baseUrl.trim().isNotEmpty) {
      // 重新配置：把当前值摆出来，并高亮能对上的那个预设
      _url.text = init.baseUrl;
      _user.text = init.username;
      _dir.text = init.remoteDir;
      /*
       * ★ 上一次保存下来的目录 = 用户意志（哪怕它是空的）
       *
       * 用户把目录删空存过一次 ⇒ 那次就是要「用根目录」。
       * 再打开对话框时不能因为「现在是空的」又补回默认值。
       */
      _dirFromUser = true;
      for (final p in _kWebdavPresets) {
        if (_normUrl(p.url) == _normUrl(init.baseUrl)) {
          _preset = p;
          break;
        }
      }
    } else {
      // 首次配置：默认坚果云（用户要求），地址与远程目录一起填好
      _preset = _kWebdavPresets.first;
      _url.text = _preset!.url;
      _dir.text = kDefaultWebdavDir;
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _pass.dispose();
    _dir.dispose();
    super.dispose();
  }

  void _applyPreset(_WebdavPreset p) {
    setState(() {
      _preset = p;
      _hint = '';
      _url.text = p.url;
      /*
       * ★ 远程目录只在**还没有用户意志**时才补默认值
       *
       * 老写法是 `if (_dir.text.trim().isEmpty) _dir.text = 'sourin';`
       * —— 那会把「用户主动删空（= 想用根目录）」当成「还没填」，
       * 切个预设就悄悄补回来。用户明确说过：
       * 「除非用户主动删除那个输入框的名字或者修改才按照用户的意思来」。
       */
      if (!_dirFromUser && _dir.text.trim().isEmpty) {
        _dir.text = kDefaultWebdavDir;
      }
    });
  }

  /// 地址是否与某个预设完全一致 —— 决定胶囊高不高亮。
  /// （用户手改地址之后预设自动"取消选中"，但提示文案留着，免得边改边丢说明）
  bool _urlMatchesPreset(_WebdavPreset p) =>
      _normUrl(_url.text) == _normUrl(p.url);

  /// 比较地址时忽略结尾斜杠与大小写 —— 后端 `normalize_base_only()`
  /// 会把结尾斜杠去掉再存，所以「刚存的地址」和「预设里的地址」可能差一个 `/`。
  static String _normUrl(String s) {
    var t = s.trim();
    while (t.endsWith('/')) {
      t = t.substring(0, t.length - 1);
    }
    return t.toLowerCase();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final p = _preset;
    return AlertDialog(
      // R4-EXCEPTION: content 是 WebDAV 配置表单 —— SizedBox(width:420) +
      // 自带 SingleChildScrollView(clipBehavior) + 预设 pill 的 Wrap + 表单字段。
      // AppGlassDialog 的 maxWidth 默认 380 ⇒ 塞不下 420 宽的表单；
      // 且它自带滚动区会与外壳的滚动区嵌套。
      title: const Text('配置云盘（WebDAV）'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('服务预设', style: TextStyle(fontSize: FontSizes.sm)),
              const SizedBox(height: Sp.x1),
              Wrap(
                spacing: Sp.x2,
                runSpacing: Sp.x2,
                children: [
                  for (final item in _kWebdavPresets)
                    SettingsGesturePill(
                      text: item.name,
                      selected: _urlMatchesPreset(item),
                      onTap: () => _applyPreset(item),
                    ),
                ],
              ),
              if (p != null && p.note.isNotEmpty) ...[
                const SizedBox(height: Sp.x2),
                Text(
                  p.note,
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    color: colors.onSurfaceVariant,
                    height: 1.6,
                  ),
                ),
              ],
              const SizedBox(height: Sp.x3),
              const Text('地址', style: TextStyle(fontSize: FontSizes.sm)),
              const SizedBox(height: Sp.x1),
              TextField(
                controller: _url,
                onChanged: (_) {
                  // 每次输入都要重建：预设胶囊的「选中」是按当前地址算的
                  // （`_urlMatchesPreset`），不重建就不会跟着变。
                  setState(() {
                    _hint = '';
                  });
                },
                decoration: const InputDecoration(
                  hintText: 'https://dav.jianguoyun.com/dav/',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: Sp.x3),
              const Text('用户名', style: TextStyle(fontSize: FontSizes.sm)),
              const SizedBox(height: Sp.x1),
              TextField(
                controller: _user,
                decoration: InputDecoration(
                  hintText: p?.userHint ?? '',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: Sp.x3),
              const Text('密码', style: TextStyle(fontSize: FontSizes.sm)),
              const SizedBox(height: Sp.x1),
              TextField(
                controller: _pass,
                obscureText: true,
                decoration: InputDecoration(
                  hintText: p?.passHint ?? '留空则沿用已保存的密码',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: Sp.x3),
              const Text('远程目录', style: TextStyle(fontSize: FontSizes.sm)),
              const SizedBox(height: Sp.x1),
              TextField(
                controller: _dir,
                /*
                 * ★ 用户一动手，这个框就归用户了
                 *
                 * 删空 ⇒ 用户要「用根目录」（后端 `remoteDir: ''` 就是根）；
                 * 改成别的 ⇒ 用用户的名字。
                 * 两种情况都不许再被 `_applyPreset` 补回默认值 ——
                 * 这正是用户说的「除非用户主动删除那个输入框的名字
                 * 或者修改才按照用户的意思来」。
                 */
                onChanged: (_) {
                  if (!_dirFromUser) {
                    setState(() => _dirFromUser = true);
                  }
                },
                decoration: const InputDecoration(
                  hintText: '留空则用根目录',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_hint.isNotEmpty) ...[
                const SizedBox(height: Sp.x2),
                Text(
                  _hint,
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    color: colors.error,
                    height: 1.6,
                  ),
                ),
              ],
              const SizedBox(height: Sp.x3),
              /*
               * ★ 提前告知"会先建目录再自检"
               *
               * 否则用户看到目录被自动创建会疑惑。
               */
              Text(
                '配置时会自动创建远程目录（如果还不存在），然后自检连通性。',
                style: TextStyle(
                  fontSize: FontSizes.cap,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final url = _url.text.trim();
            if (url.isEmpty || _user.text.trim().isEmpty) return;
            /*
             * ★ 占位符没替换就拦下来
             *
             * 预设里带 `<主机>` / `<用户名>` / `<UserID>` 的那几个是模板 ——
             * 直接保存必然连接失败（后端会报「无法连接（检查地址与网络）」），
             * 用户只会以为是自己密码错了。这里当场说清楚。
             */
            if (url.contains('<') || url.contains('>')) {
              setState(() => _hint = '地址里还有 <…> 占位符，请先替换成你自己的信息。');
              return;
            }
            Navigator.pop(context, (
              url: url,
              user: _user.text.trim(),
              pass: _pass.text,
              dir: _dir.text.trim(),
            ));
          },
          child: const Text('保存并测试'),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  WebDAV 服务预设
// ═══════════════════════════════════════════════════════════════════════
//
// ★ 收录标准（只收**官方文档能查证**的）：
//   ✅ 有官方 WebDAV 文档的服务：坚果云 / Nextcloud / ownCloud / 群晖 /
//      pCloud / Koofr / Yandex Disk / InfiniCLOUD
//   ❌ 功能存在但地址只有第三方文档（不收录，宁缺毋滥）：
//      123云盘 / 城通网盘 / 天翼云盘 / 中国移动云盘
//   ❌ 明确没有原生 WebDAV（绝不编地址）：
//      百度网盘 / 阿里云盘 / 腾讯微云 / 夸克 / 115 / 迅雷 / Box（官方已下线）
//
// ★ 哪些能直接填、哪些要替换：见每个 `url` 里的 `<…>` 与 `note`。

/// 一个 WebDAV 服务预设
/// 设置 / 修改凭据同步口令的对话框
///
/// # 三条纪律（每一条都对应一个真实的坑）
///
/// ```text
/// ① 口令输入用 obscureText —— 但这个 App 可能没有 TextField 的先例；
///    直接用 material_ui 的 TextField（本文件已 import 整个 material_ui）
///
/// ② **不显示**当前口令（那要读钥匙串，而且显示明文本身就没必要）
///    ⇒ 只显示"已设置 / 未设置"
///
/// ③ **不允许空口令**（空 = 清除，走另一个按钮 + 二次确认）
///    ⇒ 否则用户手滑点确定就把口令清空了，而他很可能是想改一个
/// ```
class _PassphraseDialog extends StatefulWidget {
  const _PassphraseDialog({required this.hasExisting});

  /// 已经设过口令（影响标题与提示文案）
  final bool hasExisting;

  @override
  State<_PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<_PassphraseDialog> {
  final _ctl = TextEditingController();
  final _ctl2 = TextEditingController();
  String _err = '';

  @override
  void dispose() {
    _ctl.dispose();
    _ctl2.dispose();
    super.dispose();
  }

  void _submit() {
    final p = _ctl.text;
    if (p.isEmpty) {
      setState(() => _err = '口令不能为空（要清除口令请用「清除口令」按钮）');
      return;
    }
    /*
     * ★ 短口令要拦：口令是**唯一**的密钥来源，
     *   4 位数字在离线爆破面前等于没有（PBKDF2 只保护"不知道口令的人"）。
     *   这里只做**下限提示**，不强制复杂度 —— 强制复杂度会让用户写便利贴。
     */
    if (p.length < 8) {
      setState(() => _err = '口令太短（至少 8 位）—— 它是解开登录态的唯一钥匙');
      return;
    }
    if (p != _ctl2.text) {
      setState(() => _err = '两次输入的口令不一致');
      return;
    }
    Navigator.pop(context, (pass: p, clear: false));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      // R4-EXCEPTION: content 是**口令表单**（两个 TextField + 错误文案 +
      // 警示文案，包在 SizedBox(width:380) 的 Column 里）⇒ 不是确认框。
      // AppGlassDialog 内容区 textAlign:center 会让两个输入框居中；
      // 且 maxHeight 默认 420 可能压掉下面的「忘记口令」警示。
      title: Text(widget.hasExisting ? '修改凭据同步口令' : '设置凭据同步口令'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.hasExisting
                  ? '改口令只会影响「以后」的同步与导出；'
                      '云端已有的那份、以及之前导出的备份包仍需要「旧口令」才能解开。'
                  : '这个口令用来加密登录态（各内容源已保存的登录态）。'
                      '它只存在系统钥匙串里，不会上传、也不会写进备份包。',
              style: TextStyle(
                fontSize: FontSizes.cap,
                color: colors.onSurfaceVariant,
                height: 1.6,
              ),
            ),
            const SizedBox(height: Sp.x3),
            TextField(
              controller: _ctl,
              autofocus: true,
              obscureText: true,
              decoration: const InputDecoration(labelText: '口令（至少 8 位）'),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: Sp.x2),
            TextField(
              controller: _ctl2,
              obscureText: true,
              decoration: const InputDecoration(labelText: '再输一次'),
              onSubmitted: (_) => _submit(),
            ),
            if (_err.isNotEmpty) ...[
              const SizedBox(height: Sp.x2),
              Text(
                _err,
                style: TextStyle(fontSize: FontSizes.cap, color: colors.error),
              ),
            ],
            const SizedBox(height: Sp.x3),
            Text(
              '⚠️ 忘记口令 = 云端那份和已导出的备份包都解不开（没有找回途径）。'
              '建议存进密码管理器。',
              style: TextStyle(
                fontSize: FontSizes.cap,
                color: colors.onSurfaceVariant,
                height: 1.6,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}

class _WebdavPreset {
  const _WebdavPreset({
    required this.name,
    required this.url,
    this.userHint = '',
    this.passHint = '',
    this.note = '',
  });

  final String name;

  /// 地址模板；含 `<…>` 的需要用户替换
  final String url;

  /// 用户名输入框的提示（各服务要填的东西不一样）
  final String userHint;

  /// 密码输入框的提示（坚果云 / Koofr 等**必须**用应用密码）
  final String passHint;

  /// 选中后显示在地址框下方的说明
  final String note;
}

/// ★ 第一个 = 默认选中项（用户要求：默认也是选择坚果云）
/// ★ WebDAV 远程目录的**默认值 = 软件的名字**
///
/// 用户原话（2026-09-29）：
/// > webdav 的默认就用那个占位，软件的名字，
/// > **除非用户主动删除那个输入框的名字或者修改才按照用户的意思来**
///
/// 所以：默认填它（不是只写进 `hintText` —— 那样看着像填好了其实没填，
/// 与「默认也是选择坚果云」同一个坑），但用户一旦删空或改成别的，
/// 就以用户的为准（见 `_WebdavDialogState._dirFromUser`）。
const String kDefaultWebdavDir = 'sourin';

const List<_WebdavPreset> _kWebdavPresets = [
  _WebdavPreset(
    name: '坚果云',
    url: 'https://dav.jianguoyun.com/dav/',
    userHint: '坚果云账号邮箱（完整邮箱）',
    passHint: '第三方应用密码（不是登录密码）',
    note:
        '密码要去官网「账户信息 → 安全选项 → 第三方应用管理 → '
        '添加应用密码」生成，用登录密码连不上。地址结尾的 / 必须留着。',
  ),
  _WebdavPreset(
    name: 'Nextcloud',
    url: 'https://<主机>/remote.php/dav/files/<用户名>/',
    userHint: 'Nextcloud 用户名',
    passHint: '应用密码（推荐）',
    note:
        '把 <主机> 换成你的域名（装在子目录就带上路径），'
        '<用户名> 换成你的用户名。建议用「应用密码」，官方说还能明显更快。',
  ),
  _WebdavPreset(
    name: 'ownCloud',
    url: 'https://<主机>/remote.php/dav/files/<用户名>/',
    userHint: 'ownCloud 用户名',
    passHint: '应用密码（推荐）',
    note:
        '把 <主机>、<用户名> 换成你自己的。旧版 ownCloud 也可以用 '
        'https://<主机>/remote.php/webdav',
  ),
  _WebdavPreset(
    name: '群晖 NAS',
    url: 'https://<主机>:5006/',
    userHint: 'DSM 用户名',
    passHint: 'DSM 登录密码',
    note:
        '把 <主机> 换成 NAS 的地址或 IP。要先在「套件中心」安装并启用 '
        'WebDAV Server；走 http 的话端口是 5005。',
  ),
  _WebdavPreset(
    name: 'pCloud',
    url: 'https://webdav.pcloud.com',
    userHint: 'pCloud 账号邮箱',
    passHint: '账号密码（不是应用密码）',
    note:
        '欧洲区换成 https://ewebdav.pcloud.com。'
        '加密文件夹（Crypto Folder）WebDAV 访问不到。',
  ),
  _WebdavPreset(
    name: 'Koofr',
    url: 'https://app.koofr.net/dav/Koofr',
    userHint: '注册邮箱',
    passHint: '应用密码（必须）',
    note:
        '主机名区分大小写，照抄即可。没有应用密码就登不上 —— '
        '官方原话是「without an application-specific password, '
        'you will not be able to set up a WebDAV connection」。',
  ),
  _WebdavPreset(
    name: 'Yandex Disk',
    url: 'https://webdav.yandex.ru',
    userHint: 'Yandex 用户名',
    passHint: '应用密码（类型选 WebDAV）',
    note:
        '密码要用「应用密码」，类型选 WebDAV。'
        '2026-06-22 起需要付费的 Yandex 360 套餐；'
        '另外通过 WebDAV 删掉的文件不进回收站。',
  ),
  _WebdavPreset(
    name: 'InfiniCLOUD',
    url: 'https://<UserID>.infini-cloud.net/dav/',
    userHint: 'Connection ID（= UserID）',
    passHint: 'Apps Password',
    note:
        '你的 ID 就在地址里，把 <UserID> 换成它（旧域名 teracloud.jp 还能用）。'
        '要先在 My Page 打开 Apps Connection 再生成 Apps Password。',
  ),
];
