// ═══════════════════════════════════════════════════════════════════════
//  门禁：用户可见的错误文案不得带宿主噪声（Owner 第 7 条）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
// > 像图2 那种报错的信息,就不要加上溯影自己的信息了,
// > 就只显示插件的报错信息就足够了
//
// # 改前用户看到
// ```text
// SourinCoreException(other): 插件报错: 该内容需要大会员
// └──────────┬─────────────┘ └──┬──┘ └──────┬──────┘
//      ①宿主类名        ②宿主分类   ③宿主包装
// ⇒ 三样噪声，插件原文只剩最后一段
// ```
//
// # 这条门禁钉什么
// ```text
// ① displayMessage 只返回插件原文（①②③ 全剥掉）
// ② toString() 仍保留完整形态（日志/栈排障需要）
// ③ 老核心加的「插件报错: 」前缀要能被剥掉（向后兼容）
// ```

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/ffi.dart';

void main() {
  group('第 7 条：用户文案只留插件原文', () {
    test('★★★ displayMessage 不含类名与分类', () {
      final e = SourinCoreException('该内容需要大会员', 'other');

      expect(e.displayMessage, '该内容需要大会员');
      expect(e.displayMessage, isNot(contains('SourinCoreException')));
      expect(e.displayMessage, isNot(contains('other')));
    });

    test('★★★ displayMessage 剥掉老核心加的「插件报错: 」前缀', () {
      // 老版本 Rust 会包一层；新版本不再包，但已落库的日志/缓存可能还有
      final e = SourinCoreException('插件报错: 该内容需要大会员', 'other');

      expect(e.displayMessage, '该内容需要大会员',
          reason: '★★★ 老核心的包装要剥掉，否则升级后用户仍看到旧噪声');
    });

    test('★★ 多层前缀也剥干净（历史数据可能叠了多次）', () {
      final e = SourinCoreException('插件报错: 插件报错: 真的原因', 'other');
      expect(e.displayMessage, '真的原因');
    });

    test('★★★ toString 仍保留完整形态（日志用，不许也剥掉）', () {
      final e = SourinCoreException('该内容需要大会员', 'other');
      expect(e.toString(), contains('SourinCoreException'));
      expect(e.toString(), contains('other'));
      expect(e.toString(), contains('该内容需要大会员'),
          reason: '★ 排障时要能从日志看出异常类型与 kind，toString 不能瘦身');
    });

    test('★ kind 字段本身不受影响（代码分支仍要能用它）', () {
      final e = SourinCoreException('需要登录', 'unauthorized');
      expect(e.kind, 'unauthorized',
          reason: 'displayMessage 只影响展示，kind 是给代码判断用的');
    });

    test('★ 不含前缀的消息原样返回（不做多余处理）', () {
      final e = SourinCoreException('网络连接失败', 'network');
      expect(e.displayMessage, '网络连接失败');
    });

    test('★★ 反面：若 displayMessage 退回 toString，本断言会红', () {
      final e = SourinCoreException('该内容需要大会员', 'other');
      // 改前的展示形态
      final oldDisplay = e.toString();
      expect(e.displayMessage, isNot(oldDisplay),
          reason: '★★ 若这里变红，说明 displayMessage 与 toString 又变成同一个 —— '
              '那第 7 条就等于没修');
    });
  });
}
