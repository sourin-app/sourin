// ═══════════════════════════════════════════════════════════════════════
//  CS-1 端到端：设置口令后状态**真的**切换（真核心，不是替身）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件补的是哪个缺口
//
// CS-1 的其它检查都在**替身**上跑：`installSyncDebugFetchers` 只替换
// **只读**接口（`sync_status` / `credentialsStatus` / …），
// 而 `setCredentialsPassphrase` / `setCredentialsEnabled` 是**写**接口，
// 按 `lib/core/sourin_api.dart:2115-2121` 的纪律**故意不给注入点**：
//
// ```text
// 「注入了就等于把『按钮点了会发生什么』从测试里拿掉，
//   那正是最该测的部分」
// ```
//
// ⇒ 这个缺口**不应该靠加注入点补**（那会把最该测的部分测掉）。
//   正确做法：让**真核心**跑起来。
//
// # 怎么起真核心（不需要改任何产品代码）
//
// ```text
// lib/core/ffi.dart 用 `DynamicLibrary.open('sourin_core.dll')` —— 相对路径。
// ⇒ 把 dll 放在**当前工作目录**（仓库根）就能打开。
//   flutter test 的 cwd 是仓库根 ⇒ 只要 sourin_core.dll 在那里就行。
//
//   本文件用 `ensureCoreDll()` 自动把 build 产物拷到根目录（见下），
//   跑完不删（后续用例还要用；它已在 .gitignore 里）。
// ```
//
// # ★★★ 三条必须知道的纪律（每条都对应一次真实事故或一次裁决）
//
// ```text
// 纪律 1：口令存在**真实系统钥匙串**里，不属于数据目录
//   service = dsh-media-client-credential-key，key = credentials
//   ⇒ 上一个用例设的口令会**泄漏**到下一个用例
//   ⇒ 症状：`before.passphraseSet` 一上来就是 true，断言「初始应为未设」失败
//
// 纪律 2 ★★★：**只清「我自己设的那个口令」，绝不碰「本来就在的」**
//   本文件会读写开发者机器的真实钥匙串 ⇒ 那是别人的数据。
//   ⇒ setUp 里**先读一次**：
//       · passphraseSet == false ⇒ 本来就没有，我来负责后面设/清（touchedKeyring = true）
//       · passphraseSet == true  ⇒ 开发者自己设的 ⇒ **立即跳过，且绝不清空**
//   判据：**"清空"必须只作用于"我自己设的那个口令"，不能作用于"本来就在的"。**
//   ★ 机械保证：`touchedKeyring` 只在"本来没有"那条路径上置 true，
//     tearDown 只在这个标志为 true 时才清 ⇒ **结构上不可能误清别人的口令**。
//
// 纪律 3：`willSync` 需要**两个条件同时满足**
//   enabled=true **且** passphraseSet=true
//   ⇒ 只设口令、不开开关 ⇒ willSync=false ⇒ 状态行仍是「凭据未同步（未开启）」
//   ⇒ 这就是"派生字段"的意义：光有口令不等于会同步
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';

/// 把 build 产物里的 `sourin_core.dll` 放到**仓库根**，让 `DynamicLibrary.open` 能成功
///
/// ★ 不改产品代码：`ffi.dart` 本来就是按相对路径找 dll 的。
/// ★ 若各处都没有 dll，本函数返回 false，调用方应 `skip` 而不是假装通过。
bool ensureCoreDll() {
  final target = File('sourin_core.dll');
  if (target.existsSync()) return true;

  const candidates = <String>[
    'build/windows/x64/runner/Release/sourin_core.dll',
    'rust/sourin_core/target/release/sourin_core.dll',
    'rust/sourin_core/target/debug/sourin_core.dll',
  ];
  for (final c in candidates) {
    final f = File(c);
    if (!f.existsSync()) continue;
    f.copySync(target.path);
    return true;
  }
  return false;
}

void main() {
  final hasCore = ensureCoreDll();

  /// 非 null 时所有用例跳过（并打印原因）
  String? skipReason;

  /// 本用例是否**真的动过**钥匙串
  ///
  /// ★★★ 这是纪律 2 的机械保证：
  ///   只有"本来就没有口令"那条路径才会把它置 true。
  ///   「开发者本来就有口令」的路径上它恒为 false ⇒ tearDown **不可能**误清。
  bool touchedKeyring = false;

  /// 起一个隔离的核心实例
  Future<Directory> startCore() async {
    final tmp = Directory.systemTemp.createTempSync('cs1-e2e-');
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {
        // 目录删不掉不影响判据（Windows 上偶发文件占用）
      }
    });
    await SourinCore.startAsync(tmp.path);
    return tmp;
  }

  /// 清空口令（钥匙串是**全局**的，会跨用例泄漏）
  Future<void> clearPassphrase() async {
    try {
      await SourinApi.setCredentialsPassphrase('');
    } catch (_) {
      // 核心没起来时会抛，交给调用方的 skip 处理
    }
  }

  setUp(() async {
    skipReason = null;
    touchedKeyring = false;

    if (!hasCore) {
      skipReason = '缺少 sourin_core.dll（未找到构建产物）⇒ 未验证';
      return;
    }

    await startCore();

    /*
     * ★★★ 纪律 2 的落点：**先读，再决定动不动**。
     *
     * 这是本文件唯一读钥匙串"原有状态"的地方。
     * 若开发者本来就有口令 ⇒ 跳过，并且**不把 touchedKeyring 置 true**
     * ⇒ tearDown 不会清它。
     */
    final st = await SourinApi.credentialsStatus();
    if (st.passphraseSet) {
      skipReason = '钥匙串里已有口令（不是本测试设的）⇒ 不清空、不覆盖，跳过本次验证';
      // ignore: avoid_print
      print('[E2E-SKIP] $skipReason');
      return;
    }

    // 走到这里说明"本来就没有" ⇒ 我后面设的那个一律由我清
    touchedKeyring = true;
    // ignore: avoid_print
    print('[E2E-READY] 钥匙串原本无口令 ⇒ 本次会临时设一个，并在结束时清掉');
  });

  tearDown(() async {
    // ★★★ 绝不清「本来就在的」：只在动过时才清
    if (!touchedKeyring) return;
    await clearPassphrase();
  });

  /// 用例开头的统一守卫
  bool guard() {
    if (skipReason != null) {
      markTestSkipped(skipReason!);
      return false;
    }
    return true;
  }

  // ─────────────────────────────────────────────────────────────
  // ★★★ 核心：状态机四态
  // ─────────────────────────────────────────────────────────────

  test('★★★ 凭据同步的状态机：开关与口令两个条件缺一不可', () async {
    if (!guard()) return;

    // ① 起点：都没开（setUp 已保证口令为空）
    final s0 = await SourinApi.credentialsStatus();
    expect(s0.enabled, isFalse);
    expect(s0.passphraseSet, isFalse);
    expect(s0.willSync, isFalse);
    expect(s0.statusLabel, contains('未同步'),
        reason: '起点必须显示未同步');

    // ② 只开同步、不设口令
    final s1 = await SourinApi.setCredentialsEnabled(true);
    expect(s1.enabled, isTrue);
    expect(s1.passphraseSet, isFalse);
    expect(s1.willSync, isFalse,
        reason: '★ 只有开关没有口令 ⇒ 不该说"将同步"');
    expect(s1.statusLabel, contains('未同步'));
    expect(s1.statusLabel, contains('未设置口令'),
        reason: '★ 必须说清**为什么**未同步（这是上一轮修过的判据失真点）');

    // ③ 再设口令 ⇒ 两个条件齐了
    final s2 = await SourinApi.setCredentialsPassphrase('correct-horse-battery');
    expect(s2.enabled, isTrue);
    expect(s2.passphraseSet, isTrue);
    expect(s2.willSync, isTrue,
        reason: '★★★ 这就是 CS-1 第④步要证明的：状态真的切换了');
    expect(s2.statusLabel, contains('凭据将同步'));
    expect(s2.statusLabel, contains('仅上行'),
        reason: '★ 方向语义必须可见（只上行，取回靠导入）');

    // ④ 复核：是持久化的，不是一次性返回值
    final s3 = await SourinApi.credentialsStatus();
    expect(s3.passphraseSet, isTrue, reason: '★ 必须落进钥匙串');
    expect(s3.willSync, isTrue);
    expect(s3.statusLabel, s2.statusLabel,
        reason: '★ 重读的状态行必须与设置时返回的一致');

    // ⑤ 清口令 ⇒ 回到"开着但没口令"
    final s4 = await SourinApi.setCredentialsPassphrase('');
    expect(s4.enabled, isTrue, reason: '清口令不该动开关');
    expect(s4.passphraseSet, isFalse);
    expect(s4.willSync, isFalse);
    expect(s4.statusLabel, contains('未同步'));

    // ignore: avoid_print
    print('[E2E] 四态读数:');
    // ignore: avoid_print
    print('  ① 都没开      willSync=${s0.willSync}  "${s0.statusLabel}"');
    // ignore: avoid_print
    print('  ② 开同步无口令 willSync=${s1.willSync}  "${s1.statusLabel}"');
    // ignore: avoid_print
    print('  ③ 开同步+口令 willSync=${s2.willSync}  "${s2.statusLabel}"');
    // ignore: avoid_print
    print('  ④ 清口令      willSync=${s4.willSync}  "${s4.statusLabel}"');
  });

  // ─────────────────────────────────────────────────────────────
  // ★★ 故障注入：只设口令不开开关 ⇒ 必须**不**说"将同步"
  // ─────────────────────────────────────────────────────────────

  test('★★★ 故障注入：少了任何一个条件，状态行都不许说"将同步"', () async {
    if (!guard()) return;

    /*
     * 这是判别力检查：
     * 若 `statusLabel` 只判断 `passphraseSet`（而不看 enabled），
     * 那么「只设口令不开开关」也会显示"将同步" —— 用户会以为在同步，其实没有。
     * ⇒ 本用例专门造这个情形。
     */
    await SourinApi.setCredentialsEnabled(false);
    final onlyPass = await SourinApi.setCredentialsPassphrase('another-good-one');

    // ignore: avoid_print
    print('[E2E-INJECT] 只设口令不做开关: enabled=${onlyPass.enabled} '
        'pass=${onlyPass.passphraseSet} willSync=${onlyPass.willSync}');
    // ignore: avoid_print
    print('[E2E-INJECT] statusLabel = "${onlyPass.statusLabel}"');

    expect(onlyPass.passphraseSet, isTrue);
    expect(onlyPass.enabled, isFalse);
    expect(onlyPass.willSync, isFalse,
        reason: '★★★ 开关关着却说"将同步"就是骗用户');
    expect(onlyPass.statusLabel, isNot(contains('凭据将同步')),
        reason: '★★★ 关着开关时，状态行不许出现"凭据将同步"');
    expect(onlyPass.statusLabel, contains('未同步'),
        reason: '必须如实显示未同步');
  });
}
