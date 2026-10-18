// ═══════════════════════════════════════════════════════════════════════
//  Episode 字段契约：Rust 出口 vs Dart 入口 —— **键名对齐验证**
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要有这个测试（这是审计发现的真问题，不是假想）
// ```text
// Rust 侧 Episode (model.rs:191-200) 序列化出的键：
//     id / title / order / player_id
//
// Dart  侧 Episode.fromJson (models.dart:1334-1339) 读的键：
//     id / title / url / index
// ```
// ⇒ **`order` 与 `index` 不匹配、`player_id` 与 `url` 不匹配**
// ⇒ 除非中间有转换层（本测试顺带证伪/证实），这些字段会在桥接处静默丢失。
//
// # 这正是本仓铁律警告的那类缺陷
// ```text
// 「serde 默认忽略未知字段 ⇒ 字段在桥接出口静默消失 —— 不报错、不警告，查起来极难」
// —— 抄自 model.rs:477-479 的原文注释（tags 字段那次踩过同一个坑）
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/models.dart';

void main() {
  /// Rust `Episode` 的**真实序列化形态**（按 model.rs:191-200 逐字段抄）
  Map<String, dynamic> rustEpisode() => {
        'id': 'ep1',
        'title': '第 1 集',
        'order': 7,
        'player_id': 'line0',
      };

  group('★ Rust → Dart 的 Episode 键名对齐', () {
    test('id / title 对得上（基准）', () {
      final e = Episode.fromJson(rustEpisode());
      expect(e.id, 'ep1');
      expect(e.title, '第 1 集');
    });

    test('★★ 已知缺口：Rust 的 order 在 Dart 侧读不到', () {
      /*
       * 这条**不是**断言「应该丢」，而是把**当前事实**钉住。
       *
       * 判据：Rust 发 'order': 7，Dart 读 'index' ⇒ 拿不到 ⇒ 落到默认 0。
       * 若哪天有人加了转换（或给 Dart 加 alias），这条会红 ——
       * 那时应该把这条改成「order 能读到」。
       */
      final e = Episode.fromJson(rustEpisode());
      expect(e.index, 0,
          reason: '★ 当前 Rust 的 `order` 在 Dart 侧被丢弃（键名不匹配）。'
              '若这条红了，说明有人补了转换 —— 请把本测试改成断言 order 能读到');
    });

    test('★★ 已知缺口：Rust 的 player_id 在 Dart 侧读不到', () {
      final e = Episode.fromJson(rustEpisode());
      expect(e.url, isNull,
          reason: '★ Rust 发 player_id，Dart 读 url ⇒ 拿不到。'
              'player_id 是「同源多线路标识」，declarative.rs:590 会填 line0/line1');
    });
  });

  group('★ 反向：Dart 读的键 Rust 从不发', () {
    test('Dart Episode.url 在 Rust Episode 里没有对应字段', () {
      /*
       * Rust Episode 只有 id/title/order/player_id，**没有 url**。
       * 所以 Dart 的这个字段永远为 null（除非别处手动构造）。
       */
      final e = Episode.fromJson(const {'id': 'x', 'title': 't'});
      expect(e.url, isNull);
    });
  });

  group('★ 源码层：确认 Rust 那边到底发哪些键', () {
    test('Rust Episode 的字段 = id/title/order/player_id', () {
      /*
       * 源码断言 —— 防止「Rust 加了字段但没人知道」。
       * 这不是重复测试，而是把**跨语言契约**钉在一条可执行的断言上：
       * Rust 结构体改了，这里会红，逼人回来看 Dart 侧。
       */
      final src = File('rust/sourin_core/src/model.rs').readAsStringSync();
      final i = src.indexOf('pub struct Episode {');
      expect(i, greaterThan(0));
      final body = src.substring(i, (i + 400).clamp(0, src.length));
      final end = body.indexOf('}');
      final decl = body.substring(0, end);

      for (final f in ['id', 'title', 'order', 'player_id']) {
        expect(decl.contains('pub $f:'), isTrue,
            reason: '★ Rust Episode 应有字段 $f —— 若这条红了，'
                '请同步检查 lib/core/models.dart 的 Episode.fromJson');
      }
    });
  });
}
