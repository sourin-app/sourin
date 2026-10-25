// ═══════════════════════════════════════════════════════════════════════
//  第19项收口（t1041）—— csp 源落盘 + 重启恢复的跨层门禁
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件守什么
//
// 第19项最后一块拼图是「**重启后源还在**」。它由三处代码共同保证，
// 少一处用户就会看到「导入成功、重启没了」：
// ```text
// ① model.rs   PersistedProvider::Tvbox 有 ext 字段（serde 缺省 None ⇒ 旧清单可读）
// ② tvbox.rs   导入 / 订阅更新**两条路径**都把 csp 源写进清单，并带上 ext
// ③ state.rs   恢复时 api 形如 csp_X ⇒ 走 csp::provider::CspProvider::new，
//              不许走 TvboxAppleCmsProvider::new（那对 "csp_Bili" 必然 Err）
// ```
// 这三处都**不会崩**、也不会报错：漏了只是"源悄悄消失"。
// 所以必须有门禁，而行为判据在 Rust 单测
// （`cargo test --lib t1041 --release`：真 bootstrap 两次 = 模拟重启）。
//
// ⚠️ 为什么这里只做静态断言（不跑 FFI 导入）：
//   `flutter test` 里 `import_tvbox_config` 会写真实数据目录
//   （用户 %APPDATA% 的那份）—— 测试不许碰用户数据。
//   行为断言放 Rust 侧；本文件锁"三处结构有没有被改回去"。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 去掉整行注释（判据对象是**代码**时必做）
String codeOnly(String path) {
  final buf = StringBuffer();
  for (final line in File(path).readAsStringSync().split('\n')) {
    final t = line.trimLeft();
    if (t.startsWith('//') || t.startsWith('/*') || t.startsWith('*')) continue;
    buf.writeln(line);
  }
  return buf.toString();
}

const modelRs = 'rust/sourin_core/src/model.rs';
const stateRs = 'rust/sourin_core/src/state.rs';
const tvboxRs = 'rust/sourin_core/src/tvbox.rs';
const persistRs = 'rust/sourin_core/src/persist.rs';

void main() {
  group('① model.rs：Tvbox 记录带 ext，且旧清单仍可读', () {
    test('★★★ ext 字段存在且是 Option（serde 缺省 None）', () {
      final code = codeOnly(modelRs);
      expect(
        code.contains('ext: Option<String>'),
        isTrue,
        reason: '★ 没有 ext，恢复出来的 csp 源就不是用户配的那个'
            '（站点列表/口令/分类名全丢）—— 能播但播的是别的东西',
      );
      // 同一段里必须有 serde default（否则旧 providers.json 会整份读不出来）
      final i = code.indexOf('ext: Option<String>');
      final seg = code.substring(i > 400 ? i - 400 : 0, i);
      expect(
        seg.contains('#[serde(default'),
        isTrue,
        reason: '★★ 缺 serde(default) ⇒ 旧清单（没有 ext）解析失败 ⇒ 全部源丢失。'
            '阴性对照在 persist.rs::old_tvbox_json_without_ext_still_loads',
      );
    });
  });

  group('② tvbox.rs：导入与订阅更新两条路径都落盘（含 ext）', () {
    test('★★★ 两处 Tvbox 记录都写 ext', () {
      final code = codeOnly(tvboxRs);
      final pushes = RegExp(r'PersistedProvider::Tvbox \{').allMatches(code).length;
      final exts = RegExp(r'ext: \{').allMatches(code).length;
      expect(pushes >= 2, isTrue, reason: '导入 + 更新两条路径都应有 Tvbox 记录，实际 $pushes');
      expect(
        exts >= 2,
        isTrue,
        reason: '★★★ 两条路径都必须写 ext（只改一条 = 「更新一次，源就变回默认站」，实际 $exts',
      );
    });

    test('★★ persisted 改吐真实值（不再按 csp 打 false）', () {
      final code = codeOnly(tvboxRs);
      expect(
        code.contains('"persisted": true'),
        isTrue,
        reason: '★ csp 源现在真的落盘，报告必须吐 true（旧值 job.csp.is_none() 是谎）',
      );
      expect(
        code.contains('job.csp.is_none()'),
        isFalse,
        reason: '★ persisted 里再出现 job.csp.is_none() = 又把 csp 标成"重启后没了"',
      );
    });

    test('★★ 不再有"不会保存/尚未落盘"的分支与告警', () {
      final code = codeOnly(tvboxRs);
      for (final bad in const ['不会保存', '尚未落盘', 'csp_unpersisted']) {
        expect(
          code.contains(bad),
          isFalse,
          reason: '★ 落盘已经实现，再说"$bad"就是过时的假话（用户会以为源留不住）',
        );
      }
    });

    test('★ notPersisted 仍输出（Dart 侧已接线，不许突然消失）', () {
      final code = codeOnly(tvboxRs);
      expect(
        code.contains('"notPersisted"'),
        isTrue,
        reason: 'Dart 的 SourinApi 解析这个键；删掉它会让界面读不到字段（现在恒为空列表）',
      );
    });
  });

  group('③ state.rs：重启恢复走 csp 路由，不许再喂给苹果CMS', () {
    test('★★★ csp 判断存在，且苹果CMS 调用在 else 分支里', () {
      final code = codeOnly(stateRs);
      // ★ 用**整句**匹配，不用裸符号：`if false && crate::csp::is_csp(api)`
      //   也含这段符号 —— 那是"把分支短路掉"的注入形态，裸 contains 会假绿
      expect(
        code.contains('if crate::csp::is_csp(api) {'),
        isTrue,
        reason: '★ 恢复必须按 api 形态分流（整句匹配：短路成 if false && … 也算没接）',
      );
      expect(
        code.contains('if false'),
        isFalse,
        reason: '★ 出现 if false 就是有分支被短路（注入/调试残留）',
      );
      expect(
        code.contains('crate::csp::provider::CspProvider::new('),
        isTrue,
        reason: '★★★ csp 源必须用 CspProvider 重建（注入 A 证明：去掉这行 ⇒ 重启恢复测试红）',
      );
      // 顺序：is_csp 判断要出现在 TvboxAppleCmsProvider::new 之前
      final iCsp = code.indexOf('crate::csp::is_csp(api)');
      final iApple = code.indexOf('crate::tvbox::TvboxAppleCmsProvider::new(');
      expect(iCsp > 0 && iApple > iCsp, isTrue,
          reason: '★★ 分流判断必须在苹果CMS 调用**之前**（顺序反了 csp 永远到不了正确分支）');
    });

    test('★★ 未实现的类：只跳过自己 + 有可查询的原因', () {
      final code = codeOnly(stateRs);
      expect(
        code.contains('RestoreFailure'),
        isTrue,
        reason: '★ 失败要落成可查询记录（日志用户在界面里看不到）',
      );
      expect(
        code.contains('write_restore_failures('),
        isTrue,
        reason: '★ 收集了不写 = 没有可查询处',
      );
      // 不许 panic/整体失败
      expect(
        code.contains('panic!') || code.contains('unreachable!'),
        isFalse,
        reason: '★★ 一条坏源不许带走全部源（本文件反复强调的纪律）',
      );
    });
  });

  group('④ persist.rs：失败报告的结构与"空即删"', () {
    test('★★ RestoreFailure 三字段 + 文件名固定', () {
      final code = codeOnly(persistRs);
      expect(code.contains('pub struct RestoreFailure'), isTrue);
      for (final f in const ['pub id: String', 'pub api: String', 'pub reason: String']) {
        expect(code.contains(f), isTrue, reason: '★ 缺字段 $f');
      }
      expect(
        code.contains('restore-failures.json'),
        isTrue,
        reason: '★ 文件名要稳定（排查脚本/后续命令会读它）',
      );
      expect(
        code.contains('std::fs::remove_file'),
        isTrue,
        reason: '★★ 空报告要**删文件**：陈旧告警比没有告警更误导',
      );
    });
  });

  group('⑤ Dart 侧未被改（本批只动 Rust）', () {
    test('★★ SourinApi 仍按 persisted 解析，默认 true', () {
      final api = File('lib/core/sourin_api.dart').readAsStringSync();
      expect(
        api.contains("persisted: j['persisted'] is bool ? j['persisted'] as bool : true"),
        isTrue,
        reason: '★ Rust 现在一律吐 true；Dart 侧保持原样（缺字段时按 true，与后端契约一致）',
      );
    });
  });
}
