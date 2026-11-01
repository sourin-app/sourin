// ═══════════════════════════════════════════════════════════════════════
//  TVBox 订阅链接血缘修复 · **认领探针**（血缘批次，2026-11-01）
// ═══════════════════════════════════════════════════════════════════════
//
// # 它做什么（只做这一件事，做完即退）
//
// 对「贴文本导入 ⇒ sidecar 里 source_url=None」的存量 TVBox 子站，
// 调一次 `adopt_tvbox_orphans`（验证型认领）把 Owner 指定的订阅链接
// 接回它们的血缘上。链接配对不上会 Err，绝不盲写（Rust 侧判据见
// `tvbox::adopt_tvbox_orphans`）。
//
// # 为什么是探针而不是 UI / 不是直接改文件
//
// ```text
// 直接改 tvbox-sources.json ：运行中的 App 持有内存态，会被覆盖 ⇒ 禁止
// UI 按钮                  ：一次性迁移操作不值得上常驻界面
// 本探针                    ：走 App 自己的 FFI 路径写 sidecar，安全且可留证据
// ```
//
// # 批末执行顺序（lead 裁定，防内存态覆盖 —— 顺序不能换）
//
// ```text
// ① 部署新构建
// ② 停 App（否则它的内存态 source_url=None 会写回覆盖认领结果）
// ③ 跑本探针（参数化真数据目录，adopt 一次即退）
// ④ 再启动 App（新实例从磁盘加载认领后的 sidecar）
// ⑤ 触发一次订阅更新（或等 60s 定时首轮：last≤0 ⇒ 到点）→ 验收
//    设置页聚合卡应显示「上次更新：MM-dd HH:mm」
// ```
//
// # 用法
//
// ```text
// flutter run -t lib/t1100_tvbox_adopt_probe.dart -d windows \
//   --dart-define=DATA_DIR_OVERRIDE=<真数据目录> \
//   --dart-define=ADOPT_URL=https://8815.kstore.vip/tvbox/wmz \
//   --dart-define=ADOPT_CONFIRM=yes
// ```
//
// 三样参数缺一不可：DATA_DIR_OVERRIDE 指向真数据目录是**显式授权**的
// 一次性动作（t1034 那种"必须落 .probe 下"的隔离护栏在这里恰好相反 ——
// 本探针的存在意义就是接真数据），所以另设 ADOPT_CONFIRM=yes 作双保险。
library;

import 'dart:io';

import 'package:flutter/widgets.dart';

import 'core/ffi.dart';
import 'core/sourin_api.dart';

late File _logFile;
int _ok = 0;
int _bad = 0;

void _say(String s) {
  final ts = DateTime.now().toIso8601String().substring(11, 23);
  final line = '$ts [ADOPT] $s';
  // ignore: avoid_print
  print(line);
  try {
    _logFile.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  } catch (_) {}
}

void _check(bool cond, String what, {String detail = ''}) {
  if (cond) {
    _ok++;
    _say('OK   $what${detail.isEmpty ? '' : '  ($detail)'}');
  } else {
    _bad++;
    _say('FAIL $what${detail.isEmpty ? '' : '  ($detail)'}');
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  const override = String.fromEnvironment('DATA_DIR_OVERRIDE');
  const adoptUrl = String.fromEnvironment('ADOPT_URL');
  const confirm = String.fromEnvironment('ADOPT_CONFIRM');
  if (override.isEmpty || adoptUrl.isEmpty || confirm != 'yes') {
    // ignore: avoid_print
    print('[ADOPT] !! 拒绝启动：需要 --dart-define=DATA_DIR_OVERRIDE=<数据目录> '
        'ADOPT_URL=<订阅链接> ADOPT_CONFIRM=yes（三样缺一不可）');
    exit(3);
  }
  if (!adoptUrl.startsWith('http://') && !adoptUrl.startsWith('https://')) {
    // ignore: avoid_print
    print('[ADOPT] !! 拒绝启动：ADOPT_URL 必须是 http/https 地址：$adoptUrl');
    exit(3);
  }
  final dataDir = Directory(override);
  if (!dataDir.existsSync()) {
    // ignore: avoid_print
    print('[ADOPT] !! 拒绝启动：数据目录不存在：$override');
    exit(3);
  }
  final logDir = Directory(
      '${Directory.current.path}${Platform.pathSeparator}.probe'
      '${Platform.pathSeparator}t1100_tvbox_adopt_probe');
  await logDir.create(recursive: true);
  _logFile = File('${logDir.path}${Platform.pathSeparator}probe.log');
  await _logFile.writeAsString('');

  _say('══════ TVBox 血缘认领 · 一次性探针 ══════');
  _say('数据目录 = $override');
  _say('认领链接 = $adoptUrl');
  final sidecar =
      File('$override${Platform.pathSeparator}tvbox-sources.json');
  final sidecarLen = sidecar.existsSync() ? sidecar.lengthSync() : 0;
  _say('sidecar 现状 = 存在=${sidecar.existsSync()} $sidecarLen 字节');

  // ── 启动真实核心（真实 DLL、真实数据目录）──
  final started = await SourinCore.startAsync(override);
  _check(started['ok'] == true, '核心已启动', detail: '$started');
  if (started['ok'] != true) {
    _say('RESULT FAIL core_not_started');
    exit(1);
  }

  // ── 认领前读数：无主子站有多少（聚合卡此刻应是「从未更新」）──
  try {
    final before = await SourinApi.listTvboxSources();
    _say('认领前 sources=${before.sources.length} '
        'aggregate.lastUpdateAt=${before.aggregate?.lastUpdateAt ?? 0}');
  } catch (e) {
    _say('认领前 listTvboxSources 读数失败（不阻断）：$e');
  }

  // ── 认领（核心动作，一次即退）──
  try {
    final r = await SourinCore.callAsync('adopt_tvbox_orphans', {
      'url': adoptUrl,
    });
    _say('adopt 返回 = $r');
    final claimed = (r is Map) ? (r['claimed'] ?? -1) : -1;
    final unmatched = (r is Map) ? (r['unmatched'] ?? -1) : -1;
    _check(claimed is int && claimed > 0, '认领成功：claimed>0',
        detail: 'claimed=$claimed unmatched=$unmatched');
  } catch (e) {
    _bad++;
    _say('FAIL 认领失败（Rust 侧 Err，盘上未写）：$e');
    _say('RESULT FAIL adopt_error');
    _say('DONE');
    exit(1);
  }

  // ── 认领后读数：sidecar 应已带链接（聚合时间仍是 0 —— 更新在 App 重启后触发）──
  final after = sidecar.existsSync() ? sidecar.readAsStringSync() : '';
  _check(after.contains('sourceUrl') || after.contains('source_url'),
      'sidecar 已含订阅链接字段',
      detail: '${after.length} 字节');
  _say('NOTE 聚合时间在 App 重启后的第一次订阅更新才盖章（last≤0 ⇒ 到点），'
      '本探针不代替 App 触发更新');

  _say('');
  _say('══ 汇总 ══');
  _say('判据通过=$_ok 判据失败=$_bad');
  _say('RESULT ${_bad == 0 ? 'PASS' : 'FAIL'} ok=$_ok bad=$_bad');
  _say('DONE');
  exit(_bad == 0 ? 0 : 1);
}
