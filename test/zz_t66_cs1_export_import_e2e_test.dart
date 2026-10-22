// ═══════════════════════════════════════════════════════════════════════
//  CS-1 端到端实测门禁：导出 / 导入登录态（判据 #10 与 #11）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件与 `zz_t66_cs1_credentials_gate_test.dart` 的分工
//
// ```text
// cs1_credentials_gate  守「状态行文案」与「接线契约」（源码层 + 面板渲染）
// 本文件                守「包里的字节」与「真的写不写 .data/」（**真核心**）
// ```
//
// # ★ 这里的每一行断言都打在**真东西**上
//
// 不是 `expect(src.contains(...))`（那是读源码字符串），
// 也不是 `expect(fetchResult, true)`（喂进去的值和判据同一个源）。
//
// ```text
// · 包内是否出现明文口令  ⇒ 真的 `unzip` 出 settings.json，逐字节找
// · 错口令时写没写凭据    ⇒ 真的读回 <tempDataDir>/plugins/.data/*.json 的字节数与内容
// · 恢复后源数            ⇒ 真的调 credentials_status 读回 providers
// ```
//
// # ★ 为什么能在 flutter_test 里驱动真核心
//
// 仓库根目录有 `sourin_core.dll`（Windows 上 `DynamicLibrary.open('sourin_core.dll')`
// 走 PATH / exe 同目录能找到它）⇒ `SourinCore.startAsync()` 起得动。
// 详见 `docs/AGENTS.md` §8「改了 Rust 但行为没变」与
// `test/zz_t66_cs1_credentials_gate_test.dart` 头部对同一个 DLL 的说明。
//
// # ★★ 铁律：数据目录必须是临时目录，绝不碰 Owner 的真实目录
//
// ```text
// `SourinCore.startAsync(<tempDir>)` 直接把数据目录钉死在临时目录，
// 它**不读** APPDATA，也不读 DATA_DIR_OVERRIDE（后者只管 ClipDownloader）。
// ⇒ 整个用例跑完，Owner 的 %APPDATA%\app.sourin.player 一个字节都不会被动。
// ```
//
// ★ 另外：凭据写在 `<dataDir>/plugins/.data/<provider>.json`，
//   所以本文件用**自造的合成凭据**（`zz-t66-fixture-a/b`），
//   绝不去读真实插件的 .data —— 那些是 Owner 的登录态。
//
// # ★★★ 另一条硬边界：**本文件绝不调 `set_credentials_passphrase`**
//
// 凭据同步口令存在**系统钥匙串**（Rust 侧 `credentials_passphrase` 用
// keyring crate，服务名 `dsh-media-client-credential-key`），
// **不在**数据目录里（`rust/sourin_core/src/sync/mod.rs:120`）。
// ⇒ 在测试里设或清它 = 写 Owner 的真实 Windows 凭据管理器 = 铁律 §3 禁止。
// ⇒ 本文件只读它（`credentials_status` 会读 `is_set()`），
//   绝不写它；需要"没口令"那一格时用**显式分支**而不是"去清一次"。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/clip_download.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';

/// 本文件用到的合成内容源 id
///
/// ⚠️ 必须是**自造的**、与任何真实源无关的名字 —— 见文件头「铁律」。
const String kProviderA = 'zz-t66-fixture-a';
const String kProviderB = 'zz-t66-fixture-b';

/// 本文件用到的口令（合成值，不与任何真实口令相关）
const String kPass = 't66-fixture-passphrase';
const String kWrongPass = 't66-WRONG-passphrase';

/// ★ 只在 [setUpAll] 里真跑一次的共享状态
class _Core {
  _Core({required this.dataDir, required this.workDir});
  late String dataDir; // 隔离的数据目录（临时）
  late String workDir; // 导出包落地的目录（临时）
}

late _Core _core;

/// 起一次真核心，钉死数据目录到临时目录
///
/// ⚠️ 与 widget 测试的经典坑一样，**不能**先 `pumpWidget` 再 `runAsync`：
/// 这里压根不用 `pumpWidget`，全部走 `test()`（无 fake clock），
/// 所以 `await SourinCore.startAsync(...)` 就是真跑。
/// 把 build 产物里的 `sourin_core.dll` 放到**仓库根**，让 `DynamicLibrary.open` 能成功
///
/// ★ 不改产品代码：`ffi.dart` 本来就是按相对路径找 dll 的。
/// ★ 若各处都没有 dll，返回 false ⇒ 调用方应 `skip` 而不是假装通过。
///
/// 与 `zz_t66_cs1_real_core_e2e_test.dart` 里那份是**同一份逻辑**（见那里的注释）。
/// 这里不复用它，是因为 test/ 下的文件各自独立编译、不宜互相 import；
/// 逻辑短到可以承受两份，且两份都在文件头写明了为什么必须跳过。
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

/// 本机能不能起真核心（`ensureCoreDll()` 决定）
///
/// ★ 文件级（不是 main() 内）—— 因为 `skipIfNoCore()` 要在每条 test 的
///   body 里调，而它是顶层函数，拿不到 main() 的局部变量。
final bool hasCore = ensureCoreDll();

/// 没有真核心时，跳过原因（会打印给读日志的人）
final String skipReason = hasCore
    ? ''
    : '缺 sourin_core.dll ⇒ 本机不起真核心，本文件全部用例跳过'
        '（这不是失败：CI 的 macOS / Android job 没有 dll）';

Future<void> _bootCore() async {
  final base = Directory.systemTemp.createTempSync('sourin-t66-cs1-');
  _core = _Core(
    dataDir: '${base.path}${Platform.pathSeparator}data',
    workDir: '${base.path}${Platform.pathSeparator}work',
  );
  Directory(_core.workDir).createSync(recursive: true);

  // ★ 真核心真启动：数据目录显式传临时目录
  await SourinCore.startAsync(_core.dataDir);

  // ★ 同时把 ClipDownloader 也钉死 —— 万一某个被渲染的页面读它
  ClipDownloader.debugSetDataDir(_core.dataDir);
}

/// 往 `<dataDir>/plugins/.data/` 写一个合成凭据文件
///
/// 形状对齐真实插件：值里带 `token`（应是令牌语义），
/// 另有**一个**故意做成 `{username, password}` 的源（明文密码类）。
void _seedCredential(String provider, {bool plaintextPassword = false}) {
  final dir = Directory('${_core.dataDir}${Platform.pathSeparator}plugins'
      '${Platform.pathSeparator}.data');
  dir.createSync(recursive: true);
  final body = plaintextPassword
      ? <String, dynamic>{
          'username': 'fixture-user',
          'password': 'fixture-pass-0000',
        }
      : <String, dynamic>{
          'token': 'fixture-token-aaaa',
          'expiresAt': 1893456000,
        };
  File('${dir.path}${Platform.pathSeparator}$provider.json')
      .writeAsStringSync(jsonEncode(body));
}

/// 读回 `<dataDir>/plugins/.data/` 里某个源的原始字节（不存在 ⇒ null）
String? _readCredentialRaw(String provider) {
  final f = File('${_core.dataDir}${Platform.pathSeparator}plugins'
      '${Platform.pathSeparator}.data'
      '${Platform.pathSeparator}$provider.json');
  return f.existsSync() ? f.readAsStringSync() : null;
}

/// 列出 `.data/` 下所有源 id
List<String> _credentialProvidersOnDisk() {
  final dir = Directory('${_core.dataDir}${Platform.pathSeparator}plugins'
      '${Platform.pathSeparator}.data');
  if (!dir.existsSync()) return const [];
  return dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .map((f) => f.path.split(RegExp(r'[\\/]')).last.replaceAll('.json', ''))
      .toList()
    ..sort();
}

/// 幂等地删掉某个源的凭据文件（不存在也不报错）
///
/// ⚠️ 为什么必须幂等：本文件有多组用例**共享同一个数据目录**，
///   而「删掉 B」这一前置在相邻组之间会重复执行。
///   改成 `deleteSync()` 直接抛 `PathNotFoundException` ——
///   症状是「三条本该测密码的用例全红在同一个前置上」，
///   而真正要测的东西一条都没跑到。
void _dropProvider(String provider) {
  final f = File('${_core.dataDir}${Platform.pathSeparator}plugins'
      '${Platform.pathSeparator}.data'
      '${Platform.pathSeparator}$provider.json');
  if (f.existsSync()) f.deleteSync();
}

/// 把本机拨回「只有 A 源有登录态」这个起点（每条导入用例都要它）
///
/// ★ 幂等：先删再按需重播 ⇒ 上一组留下的状态不会污染下一组。
void _resetToOnlyProviderA() {
  _dropProvider(kProviderB);
  _seedCredential(kProviderA);
}

/// ★ 最小 zip 读取器（只为了判据 #10-③ 逐字节看包内）
///
/// # 为什么不加 `archive` 依赖
///
/// Owner 明确说过「项目允许加新依赖，但是必须有用」，而"有用"这里有争议：
/// 本仓已有一个 Rust 写的 zip 实现，`archive` 只是为了在测试里读回来。
/// 而判据 #10-③ 要求的是**包内字节的客观事实** —— 这一条绝不能因为
/// "读不出来"就改成 grep 源码字符串。
///
/// ⇒ 决定：**自己解**。zip 的中央目录格式是公开的稳定格式，
///   Rust 侧 `zip` crate 写的就是标准 deflate（`CompressionMethod::Deflated`），
///   `dart:io` 的 `RawZLibCodec(raw: true)` 正好是裸 deflate。
///
/// 支持 stored(0) 与 deflate(8) 两种 —— 后者才是本项目实际用的。
class _ZipEntry {
  _ZipEntry(this.name, this.bytes);
  final String name;
  final List<int> bytes;
}

/// ★ zip 里的 deflate 是**裸 deflate**（RFC 1951），而 `dart:io` 只给
/// zlib 包装的 [ZLibCodec]（RFC 1950）⇒ 补一个两字节的 zlib 头再解。
///
/// zlib 头：`CMF=0x78`（deflate、窗口 32K）/ `FLG=0x01`
/// （FCHECK 使 (0x78*256+FLG) % 31 == 0）。Dart 的 [ZLibDecoder]
/// 不校验尾部 adler32，所以补头即可，不需要动尾部。
List<int> _inflateRaw(List<int> raw) {
  final wrapped = <int>[0x78, 0x01, ...raw];
  return ZLibCodec().decode(wrapped);
}

/// 读一个 zip，返回全部**文件**条目（目录条目跳过）
List<_ZipEntry> _readZip(String path) {
  final b = File(path).readAsBytesSync();
  final dv = ByteData.view(Uint8List.fromList(b).buffer);

  // ① 找中央目录末尾的 EOCD（End of Central Directory，签名 0x06054b50）
  int eocd = -1;
  for (var i = b.length - 22; i >= 0 && i >= b.length - 22 - 65536; i--) {
    if (dv.getUint32(i, Endian.little) == 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw StateError('不是有效的 zip：找不到 EOCD（${b.length} 字节）');

  final count = dv.getUint16(eocd + 10, Endian.little);
  var off = dv.getUint32(eocd + 16, Endian.little);

  final out = <_ZipEntry>[];
  for (var i = 0; i < count; i++) {
    if (dv.getUint32(off, Endian.little) != 0x02014b50) {
      throw StateError('中央目录第 $i 项签名不对');
    }
    final method = dv.getUint16(off + 10, Endian.little);
    final compSize = dv.getUint32(off + 20, Endian.little);
    final nameLen = dv.getUint16(off + 28, Endian.little);
    final extraLen = dv.getUint16(off + 30, Endian.little);
    final commentLen = dv.getUint16(off + 32, Endian.little);
    final localOff = dv.getUint32(off + 42, Endian.little);
    final name = utf8.decode(
        b.sublist(off + 46, off + 46 + nameLen), allowMalformed: true);

    // ② 本地文件头：真正的数据偏移要在这里重算（两者可能不一致）
    if (dv.getUint32(localOff, Endian.little) != 0x04034b50) {
      throw StateError('"$name" 的本地头签名不对');
    }
    final lNameLen = dv.getUint16(localOff + 26, Endian.little);
    final lExtraLen = dv.getUint16(localOff + 28, Endian.little);
    final dataStart = localOff + 30 + lNameLen + lExtraLen;
    final raw = b.sublist(dataStart, dataStart + compSize);

    if (!name.endsWith('/')) {
      final out2 = switch (method) {
        0 => raw,
        8 => _inflateRaw(raw),
        _ => throw StateError('"$name" 用了不支持的压缩方式 $method'),
      };
      out.add(_ZipEntry(name, out2));
    }
    off += 46 + nameLen + extraLen + commentLen;
  }
  return out;
}

/// 解出备份包里的 `settings.json` 原文（真读 zip 的中央目录）
Future<String> _readSettingsJsonFromZip(String zipPath) async {
  final entries = _readZip(zipPath);
  final names = entries.map((e) => e.name).toList();
  final e = entries.firstWhere(
    (x) => x.name == 'settings.json' || x.name.endsWith('/settings.json'),
    orElse: () => throw StateError('包内没有 settings.json，实际条目: $names'),
  );
  return utf8.decode(e.bytes, allowMalformed: true);
}

/// 把某个 zip 的**全部条目**原始字节拼起来（用来搜明文口令）
///
/// ⚠️ 除了解压后的内容，也把**压缩前的原始字节**一起拼 ——
///    "密文"若因为某天改了实现而退化成明文塞进包里，
///    这一条要能抓到。
Future<String> _wholeBundleText(String zipPath) async {
  final buf = StringBuffer();
  for (final e in _readZip(zipPath)) {
    buf.write(utf8.decode(e.bytes, allowMalformed: true));
  }
  final raw = File(zipPath).readAsBytesSync();
  buf.write(utf8.decode(raw, allowMalformed: true));
  return buf.toString();
}

void main() {
  /// ★★★ 本文件要的是**真核心**（不注入写接口，见 `sourin_api.dart:2115` 的纪律）。
  ///
  /// 而真核心需要 `sourin_core.dll` —— 它在本地开发机上有（build 产物），
  /// 在 **CI 的 macOS / Android job 上没有**。
  ///
  /// ⇒ 没有 dll 就必须 `skip`，**不许让 `setUpAll` 抛异常**。
  /// 「全量测试」这一步红过一次（macOS job，39460373619），
  /// 根因就是这里 `ArgumentError: Failed to load dynamic library
  /// 'libsourin_core.dylib'` 直接爬上 `setUpAll`，
  /// 把整个 job 判失败 —— 而那其实只是「这台机器不适合跑这个用例」。
  ///
  /// ★ 判据：**「没有跑这个用例的条件」与「这个用例失败」是两件事。**
  ///   前者要 skip（并打印原因），后者才是红。
  setUpAll(() async {
    if (!hasCore) {
      print('[CS1-E2E-SKIP] $skipReason');
      return;
    }
    await _bootCore();
    // 合成两份额据：A = 令牌型、B = 明文密码型
    _seedCredential(kProviderA);
    _seedCredential(kProviderB, plaintextPassword: true);
  });

  tearDownAll(() {
    // ★ 收尾：解除 ClipDownloader 注入，不留污染
    ClipDownloader.debugSetDataDir(null);
  });

  // ─────────────────────────────────────────────────────────────────
  // 仪器自检：真核心真的起动了、真的读得到合成凭据
  //
  // 没有这一节，上面所有断言都可能是"在假引擎上空转"。
  // ─────────────────────────────────────────────────────────────────

  group('⓪ 仪器自检：这一组断言打在真核心上', skip: !hasCore, () {
    test('★ 真核心已加载（不是抛异常兜底）', () {
      expect(SourinCore.isLoaded, isTrue,
          reason: '★ 仓库根目录的 sourin_core.dll 没能加载 ⇒ '
              '后面所有断言都失去意义（会是恒真/恒假的空跑）');
      expect(SourinCore.version, isNotEmpty);
    });

    test('★ 真核心读得到合成凭据（providers == 2）', () async {
      final c = await SourinApi.credentialsStatus();
      expect(c.providers, 2,
          reason: '★ 合成凭据没被 collect() 收进去 ⇒ '
              '后面「包内含不含凭据」的断言全部无意义');
      expect(
        c.plaintextPasswordProviders,
        contains(kProviderB),
        reason: '★ B 源是 {username,password} 形状 ⇒ 后端必须识别为明文密码类',
      );
    });

    test('★ 临时数据目录之外没有被写任何东西', () {
      // 反向自检：合成凭据只落在临时目录里
      expect(_credentialProvidersOnDisk(), containsAll([kProviderA, kProviderB]));
      // 且临时目录确实不在真实数据目录路径下
      expect(
        _core.dataDir.toLowerCase(),
        isNot(contains(r'appdata\app.sourin.player')),
        reason: '★★ 数据目录绝不能落在 Owner 的真实目录上',
      );
    });
  });

  // ─────────────────────────────────────────────────────────────────
  // 判据 #10-①  未设口令时导出 ⇒ credentialsIncluded == false
  // ─────────────────────────────────────────────────────────────────

  group('#10-① 未设口令导出 ⇒ 必须如实说"没带登录态"', skip: !hasCore, () {
    test('★ backupExport(passphrase: null) 返回 credentialsIncluded == false',
        () async {
      final out = '${_core.workDir}${Platform.pathSeparator}no-pass.zip';
      final r = await SourinApi.backupExport(out);

      expect(r.credentialsIncluded, isFalse,
          reason: '★★ 没给口令 ⇒ 后端不许谎称"含登录态"');
      expect(r.credentialsProviders, 0);
      expect(
        (r.credentialsNote ?? '').contains('不含登录态'),
        isTrue,
        reason: '★ 必须给出"为什么没带"的原因，用户才知道该去设口令。实际 note: '
            '"${r.credentialsNote}"',
      );
      expect(File(out).existsSync(), isTrue, reason: '包必须真的落盘');
      expect(File(out).lengthSync(), r.bytes,
          reason: '返回的字节数必须与落盘文件一致（不许报一个没写的数）');
    });

    test('★★ 未设口令的包内确实没有凭据段', () async {
      final out = '${_core.workDir}${Platform.pathSeparator}no-pass.zip';
      if (!File(out).existsSync()) {
        await SourinApi.backupExport(out);
      }
      final settings = await _readSettingsJsonFromZip(out);
      expect(
        settings.contains('"credentials"'),
        isFalse,
        reason: '★★ 包内 settings.json 不该有 credentials 段。实际: '
            '${settings.length > 400 ? "${settings.substring(0, 400)}…" : settings}',
      );
    });

    test('★ 未设口令 ⇒ 包内不得出现任何合成口令/明文凭据内容', () async {
      final out = '${_core.workDir}${Platform.pathSeparator}no-pass.zip';
      if (!File(out).existsSync()) await SourinApi.backupExport(out);
      final all = await _wholeBundleText(out);
      for (final secret in [
        'fixture-token-aaaa',
        'fixture-pass-0000',
        'fixture-user',
      ]) {
        expect(all.contains(secret), isFalse,
            reason: '★★ 没给口令 ⇒ "$secret" 绝不许出现在包里');
      }
    });
  });

  // ─────────────────────────────────────────────────────────────────
  // 判据 #10-②  设了口令后导出 ⇒ credentialsIncluded == true
  // ─────────────────────────────────────────────────────────────────

  group('#10-② 设口令导出 ⇒ 含 N 个源', skip: !hasCore, () {
    late String out;
    late BackupExportResult r;

    setUpAll(() async {
      out = '${_core.workDir}${Platform.pathSeparator}with-pass.zip';
      r = await SourinApi.backupExport(out, passphrase: kPass);
    });

    test('★ 返回 credentialsIncluded == true 且 providers == 2', () {
      expect(r.credentialsIncluded, isTrue,
          reason: '★ 给了口令且本机有登录态 ⇒ 必须真的带上');
      expect(r.credentialsProviders, 2,
          reason: '★ 合成凭据是 2 个源 ⇒ 数字必须一致');
      expect(File(out).existsSync(), isTrue);
    });

    test('★ backup_inspect 也报告"含登录态"（导入侧据此决定要不要问口令）',
        () async {
      final info = await SourinApi.backupInspect(out);
      expect(info.credentials.included, isTrue,
          reason: '★★ inspect 不报 ⇒ 导入时不会弹口令框，判据 #11-① 直接塌');
      expect(info.credentials.providers, 2);
      expect(
        info.credentials.plaintextPasswordProviders,
        contains(kProviderB),
        reason: '★ 界面要靠这个字段单独提示"账号密码明文"',
      );
    });

    test('★ 界面上「含 N 个源的登录态，已加密」这句是能拼出来的', () {
      // 判据 #10-② 要求**界面**出现这句。这里断言它由**返回值**拼得出，
      // 而不是去 grep 源码 —— 源码里的模板常量与实际拼法由 backup_panel 负责，
      // 下面的 widget 用例 #10-②-w 才去树上找那句真正的渲染结果。
      final note = '（含 ${r.credentialsProviders} 个源的登录态，已加密；导入时要口令）';
      expect(note, contains('含 2 个源的登录态，已加密'),
          reason: '★★ 判据 #10-② 逐字要求「含 N 个源的登录态，已加密」');
    });
  });

  // ─────────────────────────────────────────────────────────────────
  // 判据 #10-③  包内不得出现明文口令字段
  //
  // 这一条是最贵的安全判据 —— 逐字节搜整个 zip 的每个条目。
  // ─────────────────────────────────────────────────────────────────

  group('#10-③ ★★★ 包内不得出现明文口令 / 明文凭据', skip: !hasCore, () {
    late String out;
    late String settingsText;
    late String wholeText;

    setUpAll(() async {
      out = '${_core.workDir}${Platform.pathSeparator}with-pass.zip';
      if (!File(out).existsSync()) {
        await SourinApi.backupExport(out, passphrase: kPass);
      }
      settingsText = await _readSettingsJsonFromZip(out);
      wholeText = await _wholeBundleText(out);
    });

    test('★★★ 整个包里不含口令明文（逐字节）', () {
      expect(
        wholeText.contains(kPass),
        isFalse,
        reason: '★★★ ★最高优先级★：导出用的口令绝不许出现在包里。'
            '只要它在包里，导入时"必须重新输口令"这条就形同虚设。',
      );
    });

    test('★★★ 明文密码类源的用户名/密码不在包里', () {
      for (final secret in [
        'fixture-pass-0000',
        'fixture-user',
        'fixture-token-aaaa',
      ]) {
        expect(
          wholeText.contains(secret),
          isFalse,
          reason: '★★★ 凭据必须整体加密 ⇒ "$secret" 不许以明文出现。',
        );
      }
    });

    test('★★ settings.json 里 credentials 段只有密文（结构判据）', () {
      final seg = jmapOf(settingsText)['credentials'];
      expect(seg, isNotNull, reason: '★ 设了口令就必须有 credentials 段');
      final keys = (seg! as Map).keys.map((e) => e.toString()).toList()..sort();
      expect(
        keys,
        containsAll(['_v1', 'format', 'providers']),
        reason: '★ 结构必须齐全（导入侧按 `_v1` 取密文）',
      );
      /*
       * ★★ 阴性：不允许任何携带**口令本身**的字段。
       *
       * ⚠️ 这里有个真实的坑：`plaintextPasswordProviders` **是合法键**
       * （界面的"账号密码明文"那条单独提示要靠它），
       * 它的值是**内容源 id 列表**，不是密码。
       * ⇒ 断言必须**精确到键名**而不是 `contains('plain')` 这类模糊匹配 ——
       *   否则这条会逼着实现删掉一个正当功能（假红的另一种形态）。
       */
      const forbiddenKeys = {
        'passphrase',
        'password',
        'passwords',
        'pass',
        'pwd',
        'key',
        'secret',
        'plaintext',
        'credentials_plain',
      };
      for (final k in keys) {
        expect(
          forbiddenKeys.contains(k.toLowerCase()),
          isFalse,
          reason: '★★ 包内不许有明文口令字段，实测键名: $keys',
        );
      }
      // ★★ 而那个合法键的**值**必须是纯 id（不是密码本身）
      final pwList = seg['plaintextPasswordProviders'];
      expect(pwList, isA<List>(), reason: '★ 它是一个列表');
      for (final id in (pwList! as List)) {
        expect(
          '$id',
          kProviderB,
          reason: '★★ 值只能是**内容源 id**；实测 "$id" —— '
              '若这里出现的是密码/令牌，那才是泄露',
        );
      }
      expect(seg['format'], 'SRCRED01');
    });

    test('★★ _v1 是合法 base64 且长度合理（不是把明文塞进去"叫密文"）', () {
      final b64 = (jmapOf(settingsText)['credentials']! as Map)['_v1'] as String;
      final decoded = Uri.decodeFull(b64);
      expect(RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(decoded), isTrue,
          reason: '★ _v1 必须是 base64（实测长度 ${decoded.length}）');
      // ★★ 密文长度必须明显大于明文（PBKDF2 + salt + nonce + tag 的开销）
      expect(decoded.length, greaterThan(64),
          reason: '★ 只有 64 字符 base64（48 字节）装不下 salt+nonce+密文+tag');
    });

    test('★★★★ _v1 解开后**不是**明文（防"base64 一下就当加密了"）', () async {
      /*
       * ★★★★ 这一条是被**故障注入逼出来的**（不是想出来的）
       *
       * 第一版只做「逐字节搜明文字符串」。
       * 注入
       * ```rust
       * // encrypt_bundle 换成"假装加密"：base64 明文
       * let _ = password;
       * Ok(b64_encode(&plain).into_bytes())
       * ```
       * ⇒ **上面所有判据全绿**（+20 -3，红的都不是这一组）：
       *   · base64 里当然找不到 "fixture-token-aaaa" 这个**字面量**
       *   · base64 长度也 > 64
       *   · 包也确实比不含凭据的包大
       *
       * ★ 症状与假绿同源：**"包里有密文"不等于"密文是加密的"**。
       *
       * ⇒ 判据必须**解开它**：把 `_v1` 当 base64 解开，
       *   看解出来的是不是能直接读的 JSON —— 是 ⇒ 它根本没加密。
       */
      final b64 = (jmapOf(settingsText)['credentials']! as Map)['_v1'] as String;
      final raw = base64.decode(Uri.decodeFull(b64));

      // ① 解开后**不能**是能直接读的 JSON（那就是明文）
      var decodedAsJson = false;
      try {
        final v = jsonDecode(utf8.decode(raw, allowMalformed: true));
        decodedAsJson = v is Map;
      } catch (_) {
        decodedAsJson = false;
      }
      expect(
        decodedAsJson,
        isFalse,
        reason: '★★★★ _v1 解开后直接就是可读 JSON ⇒ 根本没加密，'
            '只是被 base64 包了一层。解开后的前 80 字节: '
            '${_previewBytes(raw)}',
      );

      // ② 解开后也不许出现任何明文秘密
      final rawText = utf8.decode(raw, allowMalformed: true);
      for (final secret in [
        'fixture-token-aaaa',
        'fixture-pass-0000',
        'fixture-user',
        kProviderA,
        kProviderB,
      ]) {
        expect(rawText.contains(secret), isFalse,
            reason: '★★★★ _v1 解开后绝不许出现 "$secret"');
      }

      // ③ ★ 真加密的密文应该有随机性 ⇒ 两次导出的 `_v1` 不会相同
      //    （salt/nonce 每次随机；若是 base64 明文，两次必然一模一样）
      final out2 = '${_core.workDir}${Platform.pathSeparator}with-pass-2.zip';
      await SourinApi.backupExport(out2, passphrase: kPass);
      final settings2 = await _readSettingsJsonFromZip(out2);
      final b642 = (jmapOf(settings2)['credentials']! as Map)['_v1'] as String;
      expect(
        b642,
        isNot(b64),
        reason: '★★★★ 两次导出的密文必须不同（每次随机 salt/nonce）。'
            '若完全相同 ⇒ 它是明文（或固定 nonce 的假加密）',
      );
    });

    test('★★ 导出的包比「不含凭据」的包更大（凭据真的占了字节）', () async {
      final plain = File('${_core.workDir}${Platform.pathSeparator}no-pass.zip');
      final enc = File(out);
      expect(plain.existsSync(), isTrue);
      expect(
        enc.lengthSync(),
        greaterThan(plain.lengthSync()),
        reason: '★ 设了口令的包必须比不含凭据的包大；相等 ⇒ 凭据一个字节都没进去',
      );
    });
  });

  // ─────────────────────────────────────────────────────────────────
  // 判据 #11  导入时必须重新输入口令
  // ─────────────────────────────────────────────────────────────────

  group('#11-① 导入含凭据的包 ⇒ 不给口令必须失败', skip: !hasCore, () {
    test('★★ backupImport 不传口令 ⇒ 报错，且**一个凭据都没写**', () async {
      final out = '${_core.workDir}${Platform.pathSeparator}with-pass.zip';

      // ★ 先把 B 源删掉，制造"本机现在只有 A 源有登录态"
      _resetToOnlyProviderA();

      final before = _credentialProvidersOnDisk();
      expect(before, [kProviderA], reason: '★ 前置：先确认本机只剩 1 个源');

      Object? caught;
      try {
        await SourinApi.backupImport(out); // ★ 故意不给口令
      } catch (e) {
        caught = e;
      }

      expect(caught, isNotNull, reason: '★★ 包里含凭据却不给口令 ⇒ 必须报错');
      final msg = '$caught';
      expect(
        msg.contains('口令'),
        isTrue,
        reason: '★★ 报错必须指向"要口令"，用户才知道下一步做什么。实际: "$msg"',
      );

      // ★★★ 关键：失败后磁盘上**必须**还是原样
      final after = _credentialProvidersOnDisk();
      expect(after, before,
          reason: '★★★ 失败不许写任何凭据 —— '
              '这正是判据 #11-② 要防的"部分成功"');
      expect(_readCredentialRaw(kProviderB), isNull,
          reason: '★★★ B 源不许被恢复出来（没给口令就解不开）');
    });
  });

  group('#11-② 输错口令 ⇒ 明确报错且不写入任何凭据', skip: !hasCore, () {
    late String out;

    setUp(() async {
      out = '${_core.workDir}${Platform.pathSeparator}with-pass.zip';
      // ★ 每条用例都从"只有 A"开始，保证起点一致（幂等，见 _dropProvider）
      _resetToOnlyProviderA();
    });

    test('★★ 错口令 ⇒ 报错文案逐字含「口令不正确」', () async {
      Object? caught;
      try {
        await SourinApi.backupImport(out, passphrase: kWrongPass);
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull, reason: '★ 错口令必须失败（GCM 会认证失败）');

      final msg = caught is SourinCoreException
          ? caught.displayMessage
          : '$caught';
      expect(
        msg.contains('口令不正确'),
        isTrue,
        reason: '★★ 用户要靠这句话知道该重输口令，而不是换一个包。实际: "$msg"',
      );
      expect(
        msg.contains('没有导入'),
        isTrue,
        reason: '★★ 必须明说"没导进去"，否则用户以为已经在本机了。实际: "$msg"',
      );
      expect(
        msg.contains('已被改动'),
        isTrue,
        reason: '★★ GCM 认证失败分不清"口令错"与"包被改过"，'
            '文案必须同时提两种可能才诚实。实际: "$msg"',
      );
    });

    test('★★★ 错口令 ⇒ 磁盘上**一个字节都没变**', () async {
      final aBefore = _readCredentialRaw(kProviderA);
      final providersBefore = _credentialProvidersOnDisk();

      try {
        await SourinApi.backupImport(out, passphrase: kWrongPass);
      } catch (_) {
        // 预期失败
      }

      expect(_credentialProvidersOnDisk(), providersBefore,
          reason: '★★★ 错口令后源清单不许变（不许"部分恢复"）');
      expect(_readCredentialRaw(kProviderA), aBefore,
          reason: '★★★ 错口令后连**已有**的凭据内容都不许被改写');
      expect(_readCredentialRaw(kProviderB), isNull,
          reason: '★★★ B 源绝不许被恢复出来');
    });

    test('★★ 错口令 ⇒ credentials_status 的 providers 不许变', () async {
      final before = await SourinApi.credentialsStatus();
      try {
        await SourinApi.backupImport(out, passphrase: kWrongPass);
      } catch (_) {}
      final after = await SourinApi.credentialsStatus();
      expect(after.providers, before.providers,
          reason: '★★ 状态读数必须与错口令之前一致');
      expect(after.providers, 1,
          reason: '★ 本机此刻只该有 A 一个源');
    });
  });

  group('#11-③ 成功导入 ⇒ providers 数量与包内一致', skip: !hasCore, () {
    late String out;

    setUp(() async {
      out = '${_core.workDir}${Platform.pathSeparator}with-pass.zip';
      // ★ 起点清干净：两个源都没有
      final d = Directory('${_core.dataDir}${Platform.pathSeparator}plugins'
          '${Platform.pathSeparator}.data');
      for (final f in d.listSync().whereType<File>()) {
        f.deleteSync();
      }
    });

    test('★ 对口令导入 ⇒ 凭据真被恢复，providers == 包内 2', () async {
      expect(_credentialProvidersOnDisk(), isEmpty, reason: '★ 前置：磁盘是空的');

      final info = await SourinApi.backupInspect(out);
      expect(info.credentials.providers, 2, reason: '★ 包内是 2 个源');

      final sum = await SourinApi.backupImport(out, passphrase: kPass);

      // ★★★ 判据 #11-③ 的核心读数
      final after = await SourinApi.credentialsStatus();
      expect(after.providers, info.credentials.providers,
          reason: '★★★ 判据 #11-③ 逐字要求：成功后 credentialsProviders '
              '数量与包内一致。包内 ${info.credentials.providers} / 本机 ${after.providers}');
      expect(after.providers, 2);

      // ★ 磁盘上确实出现了两个源，且内容是**解密后**的
      expect(_credentialProvidersOnDisk(), [kProviderA, kProviderB]);
      expect(_readCredentialRaw(kProviderA), contains('fixture-token-aaaa'),
          reason: '★ 恢复出来的必须是**解密后的真内容**，不是密文');
      expect(_readCredentialRaw(kProviderB), contains('fixture-pass-0000'));
      // ★ 导入汇总本身也要成立（它证明导入真的走完了）
      expect(sum, isA<ImportSummary>());
    });

    test('★ 导出的口令不能用来直接读包（自证 ③ 的密文是真加密）', () async {
      final out = '${_core.workDir}${Platform.pathSeparator}with-pass.zip';
      final all = await _wholeBundleText(out);
      expect(all.contains('fixture-token-aaaa'), isFalse,
          reason: '★ 令牌密文里不许出现明文');
      // 而解开后确实能拿到明文 —— 由上面那条成功导入用例证明
      expect(all.contains(kPass), isFalse);
    });

    test('★ 导入完成后界面那句「登录态已恢复」有真实数字可写', () async {
      // ★ 本组 setUp 清空了目录 ⇒ 这里必须**自己导一次**，
      //   否则读到的是 0，那条断言就成了"和 0 比 0"的空跑。
      final out2 = '${_core.workDir}${Platform.pathSeparator}with-pass.zip';
      expect(_credentialProvidersOnDisk(), isEmpty, reason: '★ 前置：磁盘是空的');
      await SourinApi.backupImport(out2, passphrase: kPass);

      final c = await SourinApi.credentialsStatus();
      expect(
        '导入：登录态已恢复 —— 本机现有 ${c.providers} 个源有登录态',
        contains('导入：登录态已恢复'),
        reason: '★ 这条日志是"凭据真被恢复了"的唯一可见证据'
            '（ImportSummary 里没有这个字段）',
      );
      expect(c.providers, 2,
          reason: '★★ 界面那句里的数字必须来自**真核心读回**的 providers，'
              '不是写死的常量');
    });
  });

  // ─────────────────────────────────────────────────────────────────
  // ★★ 本轮那个坑的回归：开关开了但没设口令
  //
  // 这是 `sync_panel.dart:417` 注释记的那一格，也是本轮 AGENTS §8
  // 新增的那条坑的来源。核心库这边也能证同一件事 ——
  // `credentials_status` 的 `willSync` 必须是**派生量**。
  // ─────────────────────────────────────────────────────────────────

  group('★ 开关开了但没设口令 ⇒ 绝不会显示成"已同步/已完成"', skip: !hasCore, () {
    test('★★ 真核心：只开开关不改口令，willSync 必须仍是 false', () async {
      /*
       * ★★★ 为什么这条**不调** `setCredentialsPassphrase`
       *
       * 口令存在**系统钥匙串**（`credentials_passphrase` 用的是
       * keyring crate，服务名 `dsh-media-client-credential-key`），
       * **不在**数据目录里 —— 见 `rust/sourin_core/src/sync/mod.rs:120`。
       *
       * ⇒ 在测试里设/清口令会写进 Owner 的**真实** Windows 凭据管理器，
       *   那是本项目的绝对铁律（`docs/AGENTS.md` §3：不碰真实凭据管理器）。
       * ⇒ 这里只调 `set_credentials_enabled` —— 它落在**隔离的临时数据目录**
       *   （`credentials_enabled` 是 `sync-settings.json` 的一个字段），
       *   碰不到钥匙串。
       *
       * ★ 所以这条断言的成立**依赖 Owner 本机钥匙串里没有这条凭据**。
       *   若它在，`willSync` 会是 true，本条会红 —— 那时的正确处理是
       *   改成「显式读 passphraseSet 再分支」，**不是**去清 Owner 的钥匙串。
       */
      final before = await SourinApi.credentialsStatus();

      final on = await SourinApi.setCredentialsEnabled(true);
      expect(on.enabled, isTrue, reason: '★ 前置：开关已开（真核心写进临时数据目录）');
      expect(
        on.passphraseSet,
        before.passphraseSet,
        reason: '★ 只开开关不许改变口令状态（读的是 Owner 钥匙串，只读不算碰）',
      );

      if (on.passphraseSet) {
        // ★ 本机钥匙串里**有**口令 ⇒ 开关一开就该真的同步
        expect(
          on.willSync,
          isTrue,
          reason: '有口令 + 开关开 ⇒ willSync 必须为 true（这一档必须真的同步）',
        );
      } else {
        // ★★ 这才是本条要守的那一格：**开关开着但没设口令**
        expect(
          on.willSync,
          isFalse,
          reason: '★★★★ 开关开着但没口令 ⇒ willSync 必须是 false。'
              '真为 true 就等于"登录态会走"这句话是假的。',
        );
      }

      // ② 还原开关（不留下污染）
      final restored = await SourinApi.setCredentialsEnabled(before.enabled);
      expect(restored.enabled, before.enabled, reason: '★ 收尾必须还原开关状态');
    });

    test('★★★ 状态行三档都不得出现"完成/将同步"（模型层逐字）', () {
      const off = CredentialsStatus();
      const noPass = CredentialsStatus(enabled: true, passphraseSet: false);
      // 有口令且开着的这一档由上面 `statusLabel` 的门禁守着，这里只守反面
      for (final c in [off, noPass]) {
        expect(c.statusLabel.contains('完成'), isFalse,
            reason: '★★ 「${c.statusLabel}」绝不许含"完成"');
        expect(c.statusLabel.contains('将同步'), isFalse,
            reason: '★★ 「${c.statusLabel}」绝不许含"将同步"');
        expect(c.statusLabel.contains('凭据未同步'), isTrue,
            reason: '★★ 必须明说"未同步"（沉默 = 假绿）');
      }
      // ★★ 而且必须把原因指对
      expect(noPass.statusLabel.contains('口令'), isTrue,
          reason: '★★★ 本机有登录态（providers=4），原因必须是"没设口令"');
      expect(noPass.statusLabel.contains('暂无登录态'), isFalse,
          reason: '★★★ 这里不许说"暂无登录态"—— 会把用户引到错误的方向');
    });
  });
}

// ── 小工具 ────────────────────────────────────────────────────────────

/// 把 settings.json 原文解析成 Map（宽容：坏 JSON 也返回空）
Map<String, dynamic> jmapOf(String text) {
  try {
    final v = jsonDecode(text);
    return v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};
  } catch (_) {
    return <String, dynamic>{};
  }
}

/// 字节数组的可读预览（给失败信息用）
String _previewBytes(List<int> b, [int n = 80]) {
  final head = b.take(n).toList();
  final hex = head.map((e) => e.toRadixString(16).padLeft(2, '0')).join(' ');
  return '[$hex]（共 ${b.length} 字节）';
}
