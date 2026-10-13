// ═══════════════════════════════════════════════════════════════════════
//  CodeRabbit PR #11：追更页重建指纹**必须**含 `_remaining` 的分钟数
// ═══════════════════════════════════════════════════════════════════════
//
// # 缺陷（已核实；修复前的论证是**错的**）
//
// 指纹里原来只有 `percentOf(p)`，而卡片副标题渲染的是 `_remaining(p)`
// （**分钟**粒度）。源码注释断言「反过来 `_remaining` 变了 `percent` 必变」——
// 反例：
// ```text
// duration=600, position 0 → 1
//   percentOf : (1*100)~/600 = 0   ⇒ 0 → 0  （没变）
//   _remaining: (600-0)~/60=10 → (600-1)~/60=9 ⇒ 10 → 9 分钟（变了）
// ⇒ 指纹判"没变" ⇒ load() 跳过 setState ⇒ 副标题停在旧分钟数
// ```
// ★ 一般规律：percent 一格 = `duration/100` 秒；`duration > 6000s`（约 100 分钟）
//   时一格 > 60 秒 ⇒ 长片上"分钟内抖动"是**常态**，不是边角。
//
// # 本文件怎么测
// 直接比**同一份数据改动前后**的指纹字符串（`debugFollowSignature`）——
// 比"多 pump 几帧数重建"更精确，也不会被动画/首帧噪声干扰。
//
// ⚠️ 同时钉住**阴性**：percent 真的没变、_remaining 也没变时，
//    指纹**必须**相同（否则"每秒都重建"的老毛病会回来）。

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/follow_page.dart';

Progress _p(String key, {required int pos, required int dur}) => Progress(
      key: key,
      provider: 'p',
      nativeId: key,
      title: '片$key',
      position: pos,
      duration: dur,
    );

void main() {
  group('PR#11 追更页指纹必须覆盖 _remaining（分钟）', () {
    test('★★★ 跨分钟但**不跨 percent** ⇒ 指纹必须变（修复前不变）', () {
      // duration=600 ⇒ percent 一格 = 6 秒；position 0 → 1 不跨格
      final before = FollowPageState.debugFollowSignature(
          const [], const [], [_p('a', pos: 0, dur: 600)]);
      final after = FollowPageState.debugFollowSignature(
          const [], const [], [_p('a', pos: 1, dur: 600)]);

      // ★ 仪器自检①：这两个位置**确实** percent 相同（否则本用例白测）
      expect(0 * 100 ~/ 600, 1 * 100 ~/ 600,
          reason: '★ 仪器自检：0 与 1 秒在 dur=600 下必须同 percent');
      // ★ 仪器自检②：而分钟数**确实**不同（10 → 9）
      expect((600 - 0) ~/ 60, 10);
      expect((600 - 1) ~/ 60, 9,
          reason: '★ 仪器自检：分钟数必须真的从 10 变到 9');

      expect(
        after,
        isNot(before),
        reason: '★★★ position 0→1 时 percent 没变、但副标题「剩 10→9 分钟」变了 '
            '⇒ 指纹**必须**变，否则 load() 跳过 setState ⇒ 副标题停在旧值。'
            '（修复前这里相同 ⇒ 红）',
      );
    });

    test('★★ 阴性对照：percent 与分钟**都没变** ⇒ 指纹必须相同', () {
      // ⚠️ 必须让 `position` 落在**同一个分钟档内**（否则分钟数会变，
      //    阴性对照就不成立了 —— 我第一版用 120→126，实测 398→397 分钟，
      //    自己撞了边界）。
      // duration=24000（400 分钟）⇒ percent 一格 240 秒；
      // 而"剩 N 分钟"在 295→296 秒都是同一档（395 分钟，实测过的安全点）。
      final a = FollowPageState.debugFollowSignature(
          const [], const [], [_p('a', pos: 295, dur: 24000)]);
      final b = FollowPageState.debugFollowSignature(
          const [], const [], [_p('a', pos: 296, dur: 24000)]);

      // 仪器自检：两处都真的没变
      expect(295 * 100 ~/ 24000, 296 * 100 ~/ 24000,
          reason: '★ 仪器自检：percent 必须相同');
      expect((24000 - 295) ~/ 60, (24000 - 296) ~/ 60,
          reason: '★ 仪器自检：分钟数必须相同（300/301 秒都在同一档）');

      expect(
        b,
        a,
        reason: '★★ 阴性对照：percent 与分钟都没变 ⇒ 指纹必须相同 —— '
            '否则「播了几秒回来就整棵重建」的老毛病（Owner 报的返回卡顿）会回来',
      );
    });

    test('★ 内容真的变了 ⇒ 指纹必须变（防"指纹恒等"的假绿）', () {
      final a = FollowPageState.debugFollowSignature(
          const [], const [], [_p('a', pos: 120, dur: 600)]);
      final b = FollowPageState.debugFollowSignature(
          const [], const [], [_p('a', pos: 500, dur: 600)]);
      expect(b, isNot(a), reason: '★ 防假绿：数据明显变了指纹必须跟着变');
    });
  });
}
