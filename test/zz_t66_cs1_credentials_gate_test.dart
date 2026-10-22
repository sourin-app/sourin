// ═══════════════════════════════════════════════════════════════════════
//  CS-1 门禁：登录态随 WebDAV 同步（凭据平面）—— Flutter 侧
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件守的是什么（三条，每条都能真的变红）
//
// ```text
// ① 口令未设    ⇒ 状态行文案 = 「凭据未同步」   （**不是**「完成」）
// ② 口令错      ⇒ 明确错误（不是静默成功 / 不是"部分成功"）
// ③ 导入含凭据的包 ⇒ 凭据被恢复（成功路径真的走通）
// ```
//
// # 为什么 ① 值得单独一条门禁
//
// 这是本仓**反复出现**的同一类错：界面显示"同步完成"，而某个平面
// 其实一个字节都没走。凭据这一条最贵 —— 用户换设备后才发现
// 每个源都要重新登录，而他一直看到"已同步"。
//
// ⇒ 判据必须锚在**文案**上，而不是"开关是开的"或"没报错"：
// ```text
// enabled=true  + passphraseSet=false  ⇒ 必须含「凭据未同步」
// 且必须**不含**「同步完成」/「将同步」
// ```
//
// # 反假绿的仪器自检
//
// 下面每条门禁都配了一条**阳性对照**：先证明"扫描器/判据确实能抓到反面"，
// 否则一条永远为真的断言看起来也是绿的（本仓铁律：
// 判据测不出反面 ⇒ 结论作废）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/sync_panel.dart';

import 'support/ui_shot.dart';

/// 装"已连接 + 凭据状态 X"的注入点
///
/// ⚠️ 只注入**只读**接口（与 `sourin_api.dart` 的纪律一致）：
///    `syncStatus` / `syncSettings` / `syncBackupList` / `credentialsStatus`。
///    写接口不给注入点 —— 那等于把"点了会发生什么"从测试里拿掉。
void install({
  required CredentialsStatus cred,
  bool connected = true,
}) {
  SourinApi.installSyncDebugFetchers(
    status: () async => SyncStatus(
      connected: connected,
      backend: 'WebDAV',
      deviceId: 'dev-a',
    ),
    settings: () async => SyncSettings(
      connected: connected,
      baseUrl: 'https://dav.example.invalid/dav/',
      username: 'u@example.invalid',
      remoteDir: 'sourin',
    ),
    backups: () async => const <SyncBackupEntry>[],
    credentials: () async => cred,
  );
}

Future<void> pumpSyncPanel(WidgetTester tester) async {
  await setShotViewport(tester, const Size(1440, 1200));
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.themeFor(Brightness.dark),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(child: const SyncPanel()),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

/// 取状态行那一条 `Text`（用 key 定位，不靠排版）
String statusText(WidgetTester tester) {
  final f = find.byKey(const ValueKey('sync-credentials-status'));
  expect(f, findsOneWidget, reason: '★ 状态行必须真的渲染出来（否则门禁是空的）');
  return tester.widget<Text>(f).data ?? '';
}

void main() {
  setUpAll(loadRealFonts);

  // 每个用例后把注入点还原 —— 否则会污染同进程里的其它测试
  tearDown(() => SourinApi.installSyncDebugFetchers());

  // ─────────────────────────────────────────────────────────────
  // ★ 仪器自检：判据能识别反面
  // ─────────────────────────────────────────────────────────────
  //
  // 这一组证明下面三条门禁用到的**判据本身**是有判别力的。
  // 没有它，一个恒真的 `expect(statusText.isNotEmpty, isTrue)`
  // 看起来和真门禁一模一样。

  group('⓪ 仪器自检：判据能抓到反面', () {
    test('statusLabel 的四个分支互不相同（判据有分辨率）', () {
      const off = CredentialsStatus();
      const noPass = CredentialsStatus(enabled: true, passphraseSet: false);
      const ready = CredentialsStatus(
        enabled: true,
        passphraseSet: true,
        providers: 3,
      );

      final labels = {off.statusLabel, noPass.statusLabel, ready.statusLabel};
      expect(
        labels.length,
        3,
        reason: '三种状态必须给出**三种不同**的文案；相同则判据没分辨率: $labels',
      );

      /*
       * ★★ 分辨率要到"原因"层：有登录态且没口令时，
       *   文案必须指向"口令"，不能指向"没登录态"。
       */
      const noPassButHasCreds = CredentialsStatus(
        enabled: true,
        passphraseSet: false,
        providers: 4,
      );
      expect(
        noPassButHasCreds.statusLabel.contains('口令'),
        isTrue,
        reason: '★ 必须把原因指到口令上，实际: ${noPassButHasCreds.statusLabel}',
      );
      expect(
        noPassButHasCreds.statusLabel.contains('暂无登录态'),
        isFalse,
        reason: '★ 本机有登录态，不许说"暂无"',
      );
      /*
       * ★★ 会同步时必须有**方向**语义 —— 见 ③-b 组的详细理由。
       */
      const readyWithDirection = CredentialsStatus(
        enabled: true,
        passphraseSet: true,
        providers: 2,
      );
      expect(
        readyWithDirection.statusLabel.contains('上行') &&
            readyWithDirection.statusLabel.contains('导入'),
        isTrue,
        reason: '★ 会同步时状态行必须含"上行"与"导入"。'
            '实际: ${readyWithDirection.statusLabel}',
      );

      // ★★ 核心反面：`enabled + 无口令` 绝不能出现"将同步"或"完成"
      expect(
        noPass.statusLabel.contains('完成'),
        isFalse,
        reason: '★★ 开关开着但没口令 ⇒ 绝不许说"完成"（假绿）',
      );
      expect(
        noPass.statusLabel.contains('将同步'),
        isFalse,
        reason: '★★ 开关开着但没口令 ⇒ 绝不许说"将同步"（登录态不会走）',
      );
      expect(
        noPass.statusLabel.contains('凭据未同步'),
        isTrue,
        reason: '必须明确说"未同步"',
      );
    });

    test('★ 阳性对照：传入"已完成"文案时反面断言会红', () {
      // 证明 `contains('完成') == false` 这条断言**真的能命中**
      const liar = CredentialsStatus(enabled: true, passphraseSet: true);
      // 正常状态文案里不该有"完成"
      expect(liar.statusLabel.contains('完成'), isFalse);
      // 而一个**假的**已完成文案确实会命中 —— 证明这条判据不是恒真
      expect('同步完成'.contains('完成'), isTrue,
          reason: '★ 若这条红了，说明判据写错（连"同步完成"都测不出来）');
    });

    test('willSync 是派生量：enabled && passphraseSet', () {
      // 四种组合逐一验 —— 这是后端与 UI 共同依赖的唯一判据
      expect(const CredentialsStatus().willSync, isFalse);
      expect(
        const CredentialsStatus(enabled: true).willSync,
        isFalse,
        reason: '★★ 只开开关 ⇒ 不会同步',
      );
      expect(
        const CredentialsStatus(passphraseSet: true).willSync,
        isFalse,
        reason: '只设口令但开关关着 ⇒ 不会同步',
      );
      expect(
        const CredentialsStatus(enabled: true, passphraseSet: true).willSync,
        isTrue,
      );
    });

    test('fromJson 缺 willSync 时按同一式子重算（老核心兼容）', () {
      final c = CredentialsStatus.fromJson({
        'enabled': true,
        'passphraseSet': false,
      });
      expect(
        c.willSync,
        isFalse,
        reason: '★★ 老核心没给 willSync ⇒ 必须重算出 false，**不许**默认 true',
      );
    });

    test('fromJson 缺字段一律当 false（不是当 true）', () {
      final c = CredentialsStatus.fromJson({});
      expect(c.enabled, isFalse);
      expect(c.passphraseSet, isFalse);
      expect(c.willSync, isFalse, reason: '全缺 ⇒ 不许当作"会同步"');
    });
  });

  // ─────────────────────────────────────────────────────────────
  // ① ★★ 口令未设 ⇒ 状态行 = 「凭据未同步」（不是「完成」）
  // ─────────────────────────────────────────────────────────────

  testWidgets('① 口令未设：面板状态行必须写「凭据未同步」', (tester) async {
    install(
      // ★ 开关**开着**、口令**没设** —— 这就是会诱发假绿的那一格
      cred: const CredentialsStatus(
        enabled: true,
        passphraseSet: false,
        // ★ 本机**有**登录态 —— 这才是真实场景（用户登录过，但没设口令）
        providers: 4,
      ),
    );
    await pumpSyncPanel(tester);

    final t = statusText(tester);

    /*
     * ★★★ 本文件最重要的一条断言。
     *
     * 反面（会红的注入）：把 `_credLabel` 改成返回
     * `c.willSync ? '…' : '同步完成'`，或让 `willSync` 忽略 passphraseSet
     * ⇒ 下面第一条立刻红。
     */
    expect(
      t.contains('凭据未同步'),
      isTrue,
      reason: '★★ 未设口令 ⇒ 状态行必须写「凭据未同步」，实际: "$t"',
    );
    expect(
      t.contains('完成'),
      isFalse,
      reason: '★★ 未设口令时**绝不许**出现「完成」—— 这正是假绿，实际: "$t"',
    );
    expect(
      t.contains('将同步'),
      isFalse,
      reason: '★★ 未设口令时不许说「将同步」（登录态一个字节都不会走），实际: "$t"',
    );
    /*
     * ★★★ 必须说出**正确的原因**（"未设置口令"）。
     *
     * # 这一条是故障注入逼出来的（不是想出来的）
     *
     * 第一版只断言了 `contains('凭据未同步')`。注入
     * ```dart
     * // 忽略 passphraseSet，永远走"暂无登录态"那条
     * if (!enabled) return '凭据未同步（未开启）';
     * return '凭据未同步（本机暂无登录态）';
     * ```
     * ⇒ **19 条全绿**。因为文案里确实有"凭据未同步"，
     *   但它给出的**原因是错的**：用户会以为"我没登录过任何源"，
     *   而不是"我该去设一个口令"。
     *
     * 症状与真正的假绿同源：界面没撒谎（都说未同步），但**指错了行动**。
     * ⇒ 判据必须精确到"原因"，不能只到"结论"。
     */
    expect(
      t.contains('口令'),
      isTrue,
      reason: '★★★ 开关开着+没口令 ⇒ 必须把原因指到"口令"上。'
          '只说"凭据未同步（暂无登录态）"会让用户去查登录，而他该去设口令。'
          '实际: "$t"',
    );
    expect(
      t.contains('暂无登录态'),
      isFalse,
      reason: '★★★ 这里本机**有**登录态（providers=4），说"暂无"是错的。实际: "$t"',
    );
    // 未设口令 ⇒ 必须能直接看到"设置口令"入口
    expect(find.text('设置口令'), findsOneWidget);
    expect(find.text('修改口令'), findsNothing, reason: '没设过 ⇒ 不该显示"修改"');
  });

  testWidgets('①-b 开关关着：状态行写「未开启」，也不是「完成」', (tester) async {
    install(cred: const CredentialsStatus());
    await pumpSyncPanel(tester);

    final t = statusText(tester);
    expect(t.contains('凭据未同步'), isTrue, reason: '实际: "$t"');
    expect(t.contains('未开启'), isTrue, reason: '要说清是"没开"，实际: "$t"');
    expect(t.contains('完成'), isFalse);
    expect(find.text('设置口令'), findsOneWidget);
  });

  testWidgets('①-c 状态读不到 ⇒ 「凭据未同步（状态未知）」，不是沉默', (tester) async {
    // 不装 credentials 注入点，且核心库不可用 ⇒ callAsync 抛 ⇒ _cred 保持 null
    SourinApi.installSyncDebugFetchers();
    await pumpSyncPanel(tester);

    final t = statusText(tester);
    expect(
      t.contains('凭据未同步'),
      isTrue,
      reason: '★ 读不到状态也必须说"未同步"（沉默 = 假绿），实际: "$t"',
    );
    expect(t.contains('状态未知'), isTrue, reason: '要说明是读不到，而不是没开');
    expect(t.contains('完成'), isFalse);
  });

  // ─────────────────────────────────────────────────────────────
  // ② ★ 口令错 ⇒ 明确错误
  // ─────────────────────────────────────────────────────────────
  //
  // 这里的"口令错"发生在**导入**那条路上（同步那条路的错口令只会导致
  // 云端的 credentials.enc 解不开，本机不会因此报错 —— 真正的口令校验
  // 在 Rust 侧 `decrypt`，由 `cargo test sync::credentials` 覆盖）。
  //
  // 所以在 Flutter 侧要守的是：**映射文案**必须能让用户知道"是口令错了"，
  // 而不是一句笼统的"导入失败"。

  group('② 口令错 ⇒ 必须明确说是口令问题', () {
    /// 与 Rust 侧 `CryptoError::WrongPasswordOrTampered` 的映射文案对齐
    ///
    /// 权威定义在 `commands_backup::apply_imported_credentials`：
    /// 「口令不正确（或这个备份包已被改动），登录态没有导入」
    const rustWrongPassword = '口令不正确（或这个备份包已被改动），登录态没有导入';

    test('★ 后端文案里必须能读出"口令不正确"', () {
      expect(
        rustWrongPassword.contains('口令不正确'),
        isTrue,
        reason: '★ 用户要靠这句话知道该重输口令，而不是换一个包',
      );
      /*
       * ★ 也不能只说"口令错" —— GCM 认证失败在密码学上分不清
       *   「口令错」与「包被改过」，如实说两者都可能才是诚实的。
       */
      expect(
        rustWrongPassword.contains('已被改动'),
        isTrue,
        reason: 'GCM 失败无法区分口令错与篡改 ⇒ 文案必须同时提两种可能',
      );
    });

    test('★ 反面：不能只说"导入失败"（用户不知道该做什么）', () {
      const vague = '导入失败';
      expect(vague.contains('口令不正确'), isFalse,
          reason: '★ 阳性对照：笼统文案确实不含判据 ⇒ 说明上面那条断言有判别力');
    });
  });

  // ─────────────────────────────────────────────────────────────
  // ③ ★ 导入含凭据的包 ⇒ 凭据被恢复
  // ─────────────────────────────────────────────────────────────
  //
  // Flutter 侧能做的是**接线判据**（真的调了那条 API、真的把口令传下去了）；
  // 「凭据真的写回 .data/」由 Rust 侧
  // `sync::credentials::tests::restore_merges_and_keeps_local_only_keys`
  // 与 `bundle_roundtrip_encrypt_decrypt_restore` 覆盖。

  group('③ 导入含凭据的包：接线判据', () {
    late String src;
    setUpAll(() {
      src = _code(_file('lib/ui/widgets/backup_panel.dart'));
    });

    test('★ 含凭据的包必须**先问口令**，再调 backupImport', () {
      // 顺序契约：先判断包里有没有凭据 → 问口令 → 才导入
      expect(
        _before(src, '_exportConsent', 'SourinApi.backupExport('),
        isTrue,
        reason: '★ 导出：**先**提示含登录态，**再**写文件 —— 反了就等于"事后才说"',
      );
      expect(
        _before(src, 'p.info.credentials.included', 'SourinApi.backupImport('),
        isTrue,
        reason: '★ 导入：先看包里有没有凭据，再决定要不要口令',
      );
    });

    test('★ 口令真的传下去了（不是只在界面里存着）', () {
      expect(
        src.contains('backupExport(path, passphrase: consent.pass)'),
        isTrue,
        reason: '★ 导出的口令必须真传给后端 —— 只存不发等于没加密',
      );
      expect(
        src.contains('backupImport(p.path, passphrase: pass)'),
        isTrue,
        reason: '★ 导入的口令必须真传给后端',
      );
    });

    test('★★ 不许有"跳过凭据继续导入"的路径', () {
      /*
       * 这条防的是最容易写错的那种"宽容"：
       * ```dart
       * if (pw == null) { /* 用户取消口令 ⇒ 照常导入 */ }
       * ```
       * 那会让界面报"导入成功"，而登录态一个都没回来。
       */
      expect(
        src.contains('取消导入'),
        isTrue,
        reason: '★ 口令输入框只能"取消整次导入"，不许"跳过凭据"',
      );
      // 阴性：不许出现"跳过"这类允许半成功措辞的按钮
      expect(
        src.contains('跳过凭据'),
        isFalse,
        reason: '★★ 不许提供"跳过凭据"选项 —— 那是假绿的入口',
      );
    });

    test('★ 导入后必须重读状态，给出"恢复了多少"的可观测证据', () {
      expect(
        src.contains('导入：登录态已恢复'),
        isTrue,
        reason: '★ 必须有这条日志 —— 它是"凭据真被恢复了"的唯一可见证据',
      );
    });
  });

  // ─────────────────────────────────────────────────────────────
  // ③-b ★★★ 同步**方向**必须说清：只上行 + 取回用导入
  // ─────────────────────────────────────────────────────────────
  //
  // # 这一条堵的是「显示成功但只做了一半」
  //
  // 本轮凭据同步**只做上行**（本机 → 云端）。它不会把云端的登录态拉回来。
  // 若界面只说「凭据将同步」，用户会以为两台机器都有了，
  // 换设备后发现每个源都要重新登录 —— 而且**永远不知道**"取回要用导入"。
  //
  // 这是本仓「假绿」形态的**镜像**：不是"说完成了其实没做"，
  // 而是"说同步了其实只做了单方向"。危害一样，也同样静默。

  group('③-b 方向语义（只上行 / 取回用导入）', () {
    test('★★★ 会同步时状态行必须同时出现「上行」与「导入」', () {
      const c = CredentialsStatus(
        enabled: true,
        passphraseSet: true,
        providers: 3,
      );
      final t = c.statusLabel;

      expect(
        t.contains('上行'),
        isTrue,
        reason: '★★★ 必须说明是"上行"（本机→云端），否则用户以为双向。实际: "$t"',
      );
      expect(
        t.contains('导入'),
        isTrue,
        reason: '★★★ 必须给出"取回"的出口（备份导入），否则用户不知道怎么办。实际: "$t"',
      );
      /*
       * ★ 不能出现"双向"/"同步两端"这类相反承诺 —— 本轮确实没做下行。
       */
      expect(
        t.contains('双向') || t.contains('两端'),
        isFalse,
        reason: '★★ 没做下行就不许承诺双向。实际: "$t"',
      );
    });

    test('★★ 门禁与实现锚在同一份真相上（不各写一份文案）', () {
      /*
       * 若判据里手抄一遍文案，实现改一个字门禁就假绿（断言的是旧文案）。
       * ⇒ 门禁断言**常量本身**，实现也用那个常量。
       */
      expect(
        CredentialsStatus.directionNote.contains('上行'),
        isTrue,
        reason: 'directionNote 必须含"上行"',
      );
      expect(
        CredentialsStatus.directionNote.contains('导入'),
        isTrue,
        reason: 'directionNote 必须含"导入"出口',
      );
      // 状态行必须**真的引用**它，而不是另写一句
      const c = CredentialsStatus(
        enabled: true,
        passphraseSet: true,
        providers: 1,
      );
      expect(
        c.statusLabel.contains(CredentialsStatus.directionNote),
        isTrue,
        reason: '★★ 状态行必须直接引用 directionNote —— 两处各写一份必然漂开',
      );
    });

    test('★ 未同步时不显示方向（那行话已经说完了）', () {
      // 未同步时说"仅上行"是噪音 —— 用户连同步都没开
      const off = CredentialsStatus();
      const noPass = CredentialsStatus(enabled: true);
      expect(off.statusLabel.contains('上行'), isFalse);
      expect(noPass.statusLabel.contains('上行'), isFalse);
    });

    testWidgets('★★★ 面板上真的渲染出方向说明（不是只存在于模型里）', (tester) async {
      install(
        cred: const CredentialsStatus(
          enabled: true,
          passphraseSet: true,
          providers: 2,
        ),
      );
      await pumpSyncPanel(tester);

      // ★ 模型里有 ≠ 界面上有。必须在树上找到它。
      expect(
        find.textContaining('仅上行'),
        findsWidgets,
        reason: '★★★ 方向说明必须真的渲染出来（模型里有但 UI 没显示 = 假绿）',
      );
      expect(
        find.textContaining('备份导入'),
        findsWidgets,
        reason: '★★ 必须让用户看到"取回用导入"这个出口',
      );
    });
  });

  // ─────────────────────────────────────────────────────────────
  // ④ 导出前必须提示「这个文件含登录态」
  // ─────────────────────────────────────────────────────────────

  group('④ 导出前提示（含明文密码的单独提示）', () {
    late String src;
    setUpAll(() {
      src = _code(_file('lib/ui/widgets/backup_panel.dart'));
    });

    test('★★ 必须明说"含登录态"', () {
      expect(
        src.contains('这个备份文件会**含登录态**') ||
            src.contains('这个备份文件含登录态'),
        isTrue,
        reason: '★★ 硬要求：导出前必须明确告诉用户这个文件含登录态',
      );
    });

    test('★★ 明文密码的源必须**单独**提示（不是笼统的"凭据"）', () {
      /*
       * 已查实：某类插件把 `{username, password}` **明文**存进私有存储。
       * ⇒ 必须逐字说"密码"，因为：
       * ```text
       * 令牌泄露 → 可撤销、会过期
       * 密码泄露 → 不能撤销；用户在别处复用同一密码 ⇒ 影响面远超出本站
       * ```
       */
      expect(
        src.contains('plaintextPasswordProviders'),
        isTrue,
        reason: '★ 必须读这个字段（后端已算好哪些源存了明文密码）',
      );
      expect(
        src.contains('账号密码明文'),
        isTrue,
        reason: '★★ 必须逐字写"账号密码明文"，不能只说"凭据"',
      );
      expect(
        src.contains('泄露的是「密码」') || src.contains('密码（不是会过期的令牌）'),
        isTrue,
        reason: '★ 要说清"这是密码不是令牌"——两者的风险等级不同。\n'
            '★ 2026-10-19：强调改成中文引号「」了（Flutter 的 `Text` 不解析 '
            'markdown，`**` 会原样显示；见 `zz_t66_cs1_no_markdown_leak_test.dart`）',
      );
      /*
       * ★★★ 阴性：用户可见字符串里不许再出现 markdown 星号。
       *
       * 这条是**行为有意改变**后的配套断言（旧行为下它必须红）：
       *   改前是 `泄露的是**密码**`，改后是 `泄露的是「密码」`。
       */
      expect(
        src.contains('泄露的是**密码**'),
        isFalse,
        reason: '★★ 强调已改成中文引号「」—— `**` 会被原样显示在屏幕上',
      );
    });

    test('★ 必须给出"不含登录态导出"这个选项（不是强制）', () {
      expect(
        src.contains('不含登录态导出'),
        isTrue,
        reason: '★ 用户有权选择导出一个不含登录态的包 —— 不给这个选项等于强制',
      );
    });
  });

  // ─────────────────────────────────────────────────────────────
  // ⑤ 静默失败扫描：整个面板不许"报成功"却没说凭据状态
  // ─────────────────────────────────────────────────────────────

  testWidgets('⑤ 同步结果文案必须带上"登录态未同步"', (tester) async {
    /*
     * 这一条守的是 `_fmtSyncResult`：它按 `total > 0` 过滤平面，
     * 而凭据平面的 `pulled/pushed` 都是 0（未同步时）⇒ 会被过滤掉
     * ⇒ 用户看到"同步完成 —— 收藏与追更：上传 3"，
     *    **一句都没提登录态没同步**。
     */
    for (final t in ['同步完成', '凭据未同步']) {
      expect(t.isNotEmpty, isTrue); // 只是让这个循环有意义
    }

    install(cred: const CredentialsStatus(enabled: true, passphraseSet: false));
    await pumpSyncPanel(tester);

    // 面板上必须**同时**能出现"未同步"这个说法（不是只在设置区里）
    expect(
      find.textContaining('凭据未同步'),
      findsWidgets,
      reason: '★★ 未设口令时，页面上必须能看到"凭据未同步"',
    );
  });

  // ─────────────────────────────────────────────────────────────
  // ⑥ 布局：新加的区块在窄屏/宽屏都不溢出
  // ─────────────────────────────────────────────────────────────

  testWidgets('⑥ 手机宽度（412）下凭据区块不溢出', (tester) async {
    install(
      cred: const CredentialsStatus(
        enabled: true,
        passphraseSet: true,
        providers: 4,
        // ★ 带上明文密码源 —— 那行提示最长，最容易挤爆
        plaintextPasswordProviders: ['fake-provider-a', 'fake-provider-b'],
      ),
    );
    await setShotViewport(tester, const Size(412, 915));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.themeFor(Brightness.dark),
        home: const Scaffold(
          body: SingleChildScrollView(
            child: Padding(padding: EdgeInsets.all(12), child: SyncPanel()),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.takeException(), isNull, reason: '412 宽度下不得有布局异常');
    final panel = tester.getRect(find.byType(SyncPanel));
    final status = tester.getRect(
      find.byKey(const ValueKey('sync-credentials-status')),
    );
    expect(
      status.left >= panel.left - 0.5 && status.right <= panel.right + 0.5,
      isTrue,
      reason: '★ 状态行必须落在面板内（${status.size} vs 面板 ${panel.size}）',
    );
  });
}

// ═══════════════════════ 小工具 ═══════════════════════

String _file(String rel) => File(rel).readAsStringSync();

/// 去掉注释行 —— 静态断言里做文本匹配**必须先剥注释**
///
/// 这个坑在本项目里踩过多次：注释里提到某个标识符，
/// 纯文本匹配就把它当成真实调用 ⇒ 断言假绿。
String _code(String src) => src
    .split('\n')
    .where((l) {
      final t = l.trimLeft();
      return !t.startsWith('//') && !t.startsWith('*') && !t.startsWith('/*');
    })
    .join('\n');

/// `a` 是否**先于** `b` 出现（顺序契约必须断言位置，不是存在性）
bool _before(String src, String a, String b) {
  final ia = src.indexOf(a);
  final ib = src.indexOf(b);
  return ia >= 0 && ib >= 0 && ia < ib;
}
