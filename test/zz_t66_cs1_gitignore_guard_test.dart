// ═══════════════════════════════════════════════════════════════════════
//  CS-1 门禁：`.gitignore` 的 `*credential*` 规则**不许静默吞掉合法文件**
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要这条（本轮撞了三次，每次都是静默的）
//
// `.gitignore:127` 有一条安全规则（防真实凭据落盘）：
// ```text
// *credential*
// ```
// 它会**无差别**匹配文件名。本轮被它吞掉的三次：
// ```text
// ① rust/sourin_core/src/sync/credentials.rs   （实现源码）
// ② test/zz_t66_cs1_credentials_gate_test.dart （门禁测试）
// ③ .agents/notes/proposed/.../2026-10-19-credential-sync-one-way.md （决策笔记）
// ```
// 三次的表现**完全相同**且**完全静默**：
// ```text
// git status 里根本不出现
// 不报错、不警告
// ⇒ 提交时少一个文件，而 CI 可能还是绿的（少的那份没人 import 就不报错）
// ```
//
// # ★ 为什么"没被忽略"不足以作为判据
//
// 直觉写法是：
// ```dart
// final r = Process.runSync('git', ['check-ignore', path]);
// if (r.exitCode == 0) fail('被忽略了');
// ```
// 但 `.gitignore` 有一个**"默认没被忽略"**的状态 ——
// 新增一条更宽的规则（比如 `test/`）后，这个判据仍然会说"没被忽略"
// （因为例外行存在），可实际命中的规则变了。
//
// ⇒ 必须**正向确认**：「确实有一条 `!` 例外行在放行它」。
//
// # 判据（实测得出，见下面的常量说明）
//
// ```text
// git check-ignore --no-index -v <path>
//   ├─ 被 `!` 例外放行 ⇒ exit 0，输出形如
//   │     .gitignore:143:!rust/sourin_core/src/sync/credentials.rs	<path>
//   │     ★ 冒号后的模式**以 `!` 开头** ⇒ 这就是"正向确认"
//   └─ 被普通规则命中 ⇒ exit 0，模式是 `*credential*`（无 `!`）⇒ 红
// ```
//
// ⚠️ **不能用 `git check-ignore -v`（不带 `--no-index`）**：
//    对被例外放行的文件它是 **exit 1 + 无输出**，
//    与"完全没命中任何规则"**无法区分** —— 那正是本门禁要防的混淆。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// ═══════════════════════════════════════════════════════════════════════
/// ★ CS-1 相关文件清单（**新增文件必须加进这里**，否则门禁不知道要检查它）
/// ═══════════════════════════════════════════════════════════════════════
///
/// # 为什么清单要手写而不是"扫 CS-1 目录"
///
/// CS-1 的文件**分散在四个目录**（`rust/.../sync/`、`test/`、`lib/`、
/// `.agents/notes/`），没有共同前缀可扫。而按文件名扫 `*credential*`
/// 恰好会漏掉**不含**该词的文件（如 `sync_panel.dart`）——
/// 而它们同样是 CS-1 的一部分。
///
/// ⇒ 手写清单 + 一条自检：清单里的每个路径**必须真实存在**
///   （防止清单腐化成死条目）。
const List<String> cs1Files = <String>[
  // ── Rust 实现 ──
  'rust/sourin_core/src/sync/credentials.rs',
  'rust/sourin_core/src/sync/mod.rs',
  'rust/sourin_core/src/commands_backup.rs',
  'rust/sourin_core/src/ffi.rs',
  // ── Dart 实现 ──
  'lib/core/sourin_api.dart',
  'lib/core/models.dart',
  'lib/ui/widgets/sync_panel.dart',
  'lib/ui/widgets/backup_panel.dart',
  // ── 门禁 ──
  'test/zz_t66_cs1_credentials_gate_test.dart',
  'test/zz_t66_cs1_render_point_uniqueness_test.dart',
  'test/zz_t66_cs1_gitignore_guard_test.dart',
  'test/zz_t66_cs1_user_text_gate_test.dart',
  // ── 决策笔记 ──
  '.agents/notes/proposed/feature/2026-10-19-login-state-sync-one-way.md',
];

/// ★★★ 本门禁**真正要守**的那一小撮：文件名命中 `*credential*` 的
///
/// # 为什么必须把它与 [cs1Files] 分开（本轮实测踩到，见下）
/// ```text
/// 2026-10-19 第一版门禁对 [cs1Files] 全部 10 个文件都要求"被 `!` 例外正向放行"
/// ⇒ 跑出 +8 -1，10 条 offender。
/// 但逐条 `git check-ignore --no-index -v` 复核后：其中 **8 个从来没被忽略过**
///   （lib/core/models.dart / lib/ui/widgets/sync_panel.dart / ffi.rs / …）
///   —— 它们的文件名不含 `credential`，压根不命中 `*credential*` 规则。
/// ⇒ 那条断言的真实问题是**清单腐化**：把"CS-1 的全部文件"当成了
///   "CS-1 里需要 gitignore 例外的文件"。
/// ```
///
/// # 判据：只有**命中该 glob** 的路径才可能需要例外
///
/// `git check-ignore --no-index` 对「本来就没被忽略」的文件返回 exit 1，
/// 对「被 `!` 例外放行」的文件返回 exit 0 且模式以 `!` 开头。
/// ⇒ 门禁只对**确实需要例外**的那几个提要求，其余交给「必须真实存在」自检。
const List<String> cs1CredentialNamedFiles = <String>[
  'rust/sourin_core/src/sync/credentials.rs',
  'test/zz_t66_cs1_credentials_gate_test.dart',
];

/// 假想的"探针"文件名 —— 它**必须仍然被忽略**
///
/// ★ 反向判据：证明 `*credential*` 这条安全规则的**边界没被拆掉**。
///   若有人把规则改成 `!*credential*.dart` 之类，本文件会红。
const String mustStayIgnoredProbe = 'test/zz_tmp_credential_probe.dart';

/// 跑 `git check-ignore --no-index -v <path>`，返回 (exitCode, stdout, stderr)
({int code, String out, String err}) checkIgnore(String path) {
  final r = Process.runSync(
    'git',
    ['check-ignore', '--no-index', '-v', path],
    runInShell: Platform.isWindows,
  );
  return (
    code: r.exitCode,
    out: (r.stdout as String).trim(),
    err: (r.stderr as String).trim(),
  );
}

/// 从 `check-ignore --no-index -v` 的输出里取出**命中的 gitignore 行号**
///
/// 输出格式：`<文件>:<行号>:<模式>\t<路径>`
/// 例：`.gitignore:143:!rust/sourin_core/src/sync/credentials.rs\trust/...`
int? hitLine(String out) {
  if (out.isEmpty) return null;
  final head = out.split('\t').first;
  final parts = head.split(':');
  if (parts.length < 3) return null;
  return int.tryParse(parts[1]);
}

/// 命中的模式是否是一条**`!` 例外**
bool isNegationHit(String out) {
  if (out.isEmpty) return false;
  final head = out.split('\t').first;
  final parts = head.split(':');
  if (parts.length < 3) return false;
  return parts[2].trimLeft().startsWith('!');
}

void main() {
  // ─────────────────────────────────────────────────────────────
  // ⓪ 仪器自检：先证明判据本身有判别力
  // ─────────────────────────────────────────────────────────────

  group('⓪ 仪器自检', () {
    test('★ 例外放行的文件：check-ignore --no-index 必须 exit 0 且模式带 `!`', () {
      final r = checkIgnore('rust/sourin_core/src/sync/credentials.rs');
      expect(
        r.code,
        0,
        reason: '★ 这条自检失败说明 git 行为变了或 git 不可用 —— '
            '下面的所有断言都会失去判据。stdout=${r.out} stderr=${r.err}',
      );
      expect(
        isNegationHit(r.out),
        isTrue,
        reason: '★ 命中行必须是 `!` 例外，实际输出: ${r.out}',
      );
      // 打出行号，便于人工核对是**哪一条**例外在放行
      printOnFailure('[GITIGNORE] credentials.rs 由 .gitignore:${hitLine(r.out)} 放行');
    });

    test('★ 反面对照：真被忽略的探针文件，命中模式**不带** `!`', () {
      final r = checkIgnore(mustStayIgnoredProbe);
      expect(
        r.code,
        0,
        reason: '★ 探针文件必须仍然被忽略（否则说明安全规则的边界被拆了）',
      );
      expect(
        isNegationHit(r.out),
        isFalse,
        reason: '★ 探针文件不该被 `!` 例外放行，实际输出: ${r.out}',
      );
      printOnFailure('[GITIGNORE] 探针由 .gitignore:${hitLine(r.out)} 忽略');
    });

    test('★★ 阳性对照：`-v`（不带 --no-index）对例外文件是 exit 1 无输出', () {
      /*
       * 这条锁的是**为什么不能用 `-v`**。
       * 若哪天 git 改了行为（`-v` 也开始报例外），本门禁的判据要重新审视。
       * ⇒ 把它写成断言：让判据的**前提**也是可检验的。
       */
      final r = Process.runSync(
        'git',
        ['check-ignore', '-v', 'rust/sourin_core/src/sync/credentials.rs'],
        runInShell: Platform.isWindows,
      );
      expect(
        r.exitCode,
        1,
        reason: '★ `-v`（无 --no-index）对例外文件应 exit 1 —— '
            '这正是它**不能**当判据的原因（与"没命中任何规则"无法区分）',
      );
      expect((r.stdout as String).trim(), isEmpty);
    });
  });

  // ─────────────────────────────────────────────────────────────
  // ① ★★★ CS-1 里**需要例外的那几个**必须被 `!` 正向放行
  // ─────────────────────────────────────────────────────────────

  test('★★★ CS-1 的每个文件都必须真实存在（清单不腐化）', () {
    /*
     * 这条**只**管"清单里的路径是真的" —— 它对 cs1Files 的**全部**条目生效。
     * 「要不要 gitignore 例外」是另一件事，见下面那条。
     */
    final missing = <String>[
      for (final p in cs1Files)
        if (!File(p).existsSync() && !Directory(p).existsSync())
          '$p —— **文件不存在**（清单腐化：把已删文件留在清单里）',
    ];
    expect(
      missing,
      isEmpty,
      reason: '★★★ 有 ${missing.length} 个 CS-1 路径在清单里但磁盘上不存在：\n'
          '${missing.join('\n')}\n\n'
          '修法：从 `cs1Files` 删掉，或把文件补回来。',
    );
    printOnFailure('[GITIGNORE] 清单 ${cs1Files.length} 个路径全部存在');
  });

  test('★★★ 命中 `*credential*` 的 CS-1 文件必须被 `!` 例外正向放行', () {
    final offenders = <String>[];
    final confirmed = <String>[];

    // ★ 只遍历 [cs1CredentialNamedFiles] —— 理由见它的文档注释：
    //   `git check-ignore` 对「本来就没被忽略」的文件返回 exit 1，
    //   拿它当"没放行"的红，会把 8 个无辜文件判成 offender。
    for (final p in cs1CredentialNamedFiles) {
      // 先确认文件真的存在 —— 否则 `git check-ignore` 也能返回结果，
      // 但那个结果毫无意义（清单腐化）
      if (!File(p).existsSync() && !Directory(p).existsSync()) {
        offenders.add('$p —— **文件不存在**（清单腐化：把已删文件留在清单里）');
        continue;
      }
      final r = checkIgnore(p);
      if (r.code != 0) {
        offenders.add('$p —— `git check-ignore --no-index` 没命中任何规则（exit ${r.code}）。'
            '它是**名字含 credential 的实现/门禁文件**，却被规则整条忽略掉了 ⇒ '
            '补一条精确例外 `!$p`（不要放宽 glob）。');
        continue;
      }
      if (!isNegationHit(r.out)) {
        offenders.add('$p —— ★ **被忽略了**！命中: ${r.out}\n'
            '    ⇒ 它不会进 git status、不会进提交、CI 也不会报错（静默丢失）。\n'
            '    修法：在 .gitignore 加**精确路径**例外 `!$p`（不要放宽 glob）。');
        continue;
      }
      confirmed.add(p);
    }

    expect(
      offenders,
      isEmpty,
      reason: '★★★ 有 ${offenders.length} 个含 credential 的 CS-1 文件没有被正向放行：\n'
          '${offenders.join('\n')}\n\n'
          '⚠️ 这是本轮撞了三次的坑（源码 / 门禁测试 / 决策笔记），'
          '每次都是**静默**的：git status 里根本不出现。',
    );

    expect(
      confirmed.length,
      cs1CredentialNamedFiles.length,
      reason: '★ 应当每个"名字含 credential"的 CS-1 文件都确认放行',
    );
    printOnFailure('[GITIGNORE] 已正向确认 ${confirmed.length} 个含 credential 的文件');
  });

  // ─────────────────────────────────────────────────────────────
  // ② ★★ 反向：安全规则的边界不许被拆掉
  // ─────────────────────────────────────────────────────────────

  test('★★ 假想的凭据探针文件必须**仍然**被忽略', () {
    /*
     * 这条防的是"为了让 CS-1 文件进来而放宽 glob"：
     * ```text
     * 错误修法：!*credential*.rs      ⇒ 任何 .rs 探针都能进库
     *           !test/zz_t66_cs1_*.dart ⇒ 将来的临时诊断也一起进
     *           !*credential*        ⇒ 规则本身失效（最糟）
     * ```
     * ⇒ 用一个**假想**的凭据文件名做探针：它必须仍然被忽略。
     *
     * ⚠️ 用假想文件（不落盘）而不是真造一个：
     *    `git check-ignore` 对着不存在的路径也能判定，
     *    而造真文件会有"忘了删"的风险（那才是真事故）。
     */
    final r = checkIgnore(mustStayIgnoredProbe);
    expect(
      r.code,
      0,
      reason: '★★ `$mustStayIgnoredProbe` 必须仍然被忽略 —— '
          '否则说明 `*credential*` 这条安全规则的**边界被拆掉了**',
    );
    expect(
      isNegationHit(r.out),
      isFalse,
      reason: '★★ 探针不许被 `!` 例外放行，实际: ${r.out}',
    );
    // 命中的应当是那条安全 glob 本身
    expect(
      r.out.contains('*credential*'),
      isTrue,
      reason: '★★ 探针应当由 `*credential*` 这条规则忽略，实际: ${r.out}',
    );
  });

  // ─────────────────────────────────────────────────────────────
  // ③ ★ .gitignore 里的每条 `!` 例外都必须指向**真实存在**的路径
  // ─────────────────────────────────────────────────────────────

  test('★ 没有死例外（每条 `!` 都指向现存文件）', () {
    final lines = File('.gitignore').readAsLinesSync();
    final dead = <String>[];
    var checked = 0;

    for (var i = 0; i < lines.length; i++) {
      final t = lines[i].trim();
      if (!t.startsWith('!')) continue;
      // 跳过纯注释（`!` 开头的行不可能是注释，但防御一下）
      if (t.startsWith('#!')) continue;

      final pattern = t.substring(1);
      /*
       * ★ 必须处理**前导 `/`**（锚定仓库根的写法）。
       *
       * # 第一版漏了它（实测被这条门禁自己抓到）
       * ```text
       * .gitignore:205  `!/.agents/assets/agent-notes-board.html`
       * 我把它当成相对路径 `/.agents/assets/...` 去 File() 判存在
       * ⇒ Windows 上解析成「当前盘符根」⇒ 不存在 ⇒ 报「死规则」
       * 而那个文件**真实存在**（74323 字节）
       * ```
       * ⇒ 假红。前导 `/` 在 .gitignore 里表示"从仓库根算起"，
       *   判存在时必须把它剥掉。
       */
      final noAnchor = pattern.startsWith('/') ? pattern.substring(1) : pattern;
      final path = noAnchor.endsWith('/')
          ? noAnchor.substring(0, noAnchor.length - 1)
          : noAnchor;
      checked++;
      if (!File(path).existsSync() && !Directory(path).existsSync()) {
        dead.add('.gitignore:${i + 1}  `$t` → `$path` 不存在（死规则）');
      }
    }

    expect(
      checked,
      greaterThan(0),
      reason: '★ 一条例外都没扫到 ⇒ `!` 检测失效（本门禁是假绿）',
    );
    expect(
      dead,
      isEmpty,
      reason: '★ 死例外会让 .gitignore 越来越难懂，且掩盖真正的例外：\n'
          '${dead.join('\n')}',
    );
    printOnFailure('[GITIGNORE] 检查了 $checked 条 `!` 例外，全部指向现存路径');
  });

  // ─────────────────────────────────────────────────────────────
  // ④ 清单自身不许腐化
  // ─────────────────────────────────────────────────────────────

  test('★ cs1Files 清单里没有重复项', () {
    final seen = <String>{};
    final dups = <String>[];
    for (final p in cs1Files) {
      if (!seen.add(p)) dups.add(p);
    }
    expect(dups, isEmpty, reason: '重复项: $dups');
  });

  test('★★ cs1Files 必须覆盖所有已知会被 `*credential*` 命中的 CS-1 文件', () {
    /*
     * 反向自查：本清单若漏了某个"名字含 credential"的 CS-1 文件，
     * 那条文件就会静默丢失而门禁不知道。
     * ⇒ 扫一遍 CS-1 的实现目录，把名字含 credential 的文件捞出来，
     *   要求它们**都在清单里**。
     */
    final roots = <String>[
      'rust/sourin_core/src',
      'test',
      '.agents/notes',
    ];
    final suspicious = <String>[];

    void walk(Directory d) {
      for (final e in d.listSync(followLinks: false)) {
        final rel = e.path.replaceAll('\\', '/');
        if (e is Directory) {
          if (rel.contains('/.git') || rel.endsWith('/target')) continue;
          walk(e);
        } else if (e is File) {
          final base = rel.split('/').last.toLowerCase();
          if (base.contains('credential')) suspicious.add(rel);
        }
      }
    }

    for (final r in roots) {
      final d = Directory(r);
      if (d.existsSync()) walk(d);
    }

    final missing = suspicious
        .where((p) => p.contains('zz_t66_cs1') && !cs1Files.contains(p))
        .toList();
    expect(
      missing,
      isEmpty,
      reason: '★★ 这些 **CS-1** 文件名含 credential 但**不在** `cs1Files` 清单里 ⇒ '
          '本门禁不检查它们（可能正被静默忽略）：\n${missing.join('\n')}',
    );
  });

  /// ☆ 存量审计（**报告，不必红**）
  ///
  /// # 它发现的东西（2026-10-19 实测）
  ///
  /// 仓库里有两篇**既有**决策笔记被 `*credential*` 静默吞掉，
  /// 从来没进过库，也没人发现：
  /// ```text
  /// .agents/notes/implemented/process/2026-10-12-danmaku-credentials-build-time-secrets.md
  /// .agents/notes/implemented/process/2026-10-15-dev-data-seed-readonly-no-credentials.md
  /// ```
  /// 两篇都是 35/45 行的真笔记（构建期凭证注入 / 开发数据播种）。
  /// ⇒ 说明这个坑**不是本轮引入的**，它一直存在，
  ///   只是没人对着 `git status` 数过笔记文件。
  ///
  /// ⚠️ 我没替它们加例外：那两篇是否该进库是**内容决策**（Lead 定），
  ///    且它们与本轮 CS-1 无关。这里只如实列出来 ——
  ///    **把已知缺口变成可见的读数，而不是悄悄补一条规则**。
  test('☆ 存量审计：名字含 credential 的文件的跟踪状态（报告）', () {
    final rows = <String>[];
    for (final p in scanCredentialNamedFiles()) {
      final tracked = Process.runSync(
        'git',
        ['ls-files', '--error-unmatch', p],
        runInShell: Platform.isWindows,
      ).exitCode ==
          0;
      final r = checkIgnore(p);
      final verdict = tracked
          ? '已进库'
          : (isNegationHit(r.out) ? '未进库（有 `!` 例外）' : '★ 未进库且被忽略');
      rows.add('$p  →  $verdict');
    }
    if (rows.isNotEmpty) {
      printOnFailure('[GITIGNORE-AUDIT]\n${rows.join('\n')}');
    }
    expect(scanCredentialNamedFiles(), isNotEmpty,
        reason: '★ 一个都没扫到 ⇒ 扫描器坏了');
  });
}

/// 扫 CS-1 的实现目录，捞出**名字含 credential** 的文件
///
/// ★ 提成顶层函数（而不是测试内的局部变量）：存量审计那条用例也要用它，
///   两处各写一份就是"同一份真相两处维护"。
List<String> scanCredentialNamedFiles() {
  final roots = <String>['rust/sourin_core/src', 'test', '.agents/notes'];
  final found = <String>[];

  void walk(Directory d) {
    for (final e in d.listSync(followLinks: false)) {
      final rel = e.path.replaceAll('\\', '/');
      if (e is Directory) {
        if (rel.contains('/.git') || rel.endsWith('/target')) continue;
        walk(e);
      } else if (e is File) {
        final base = rel.split('/').last.toLowerCase();
        if (base.contains('credential')) found.add(rel);
      }
    }
  }

  for (final r in roots) {
    final d = Directory(r);
    if (d.existsSync()) walk(d);
  }
  found.sort();
  return found;
}
