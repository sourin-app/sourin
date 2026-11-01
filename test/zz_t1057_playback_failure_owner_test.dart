// test/zz_t1057_playback_failure_owner_test.dart
//
// ══════════════════════════════════════════════════════════════════════════
//  N5b：播放失败的**归属**层 ——「插件还是播放器本体」（2026-10-27）
// ══════════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
// ```text
// 播放失败定位与诊断，这个如果播放失败应该具体是谁的问题，
// 在界面上显示出来是插件还是播放器本体的问题
// ```
//
// # 守什么
// ```text
// ① 映射表七档**逐档**断言（不是抽查两档 —— 漏一档就等于那一档
//    会悄悄落到别的归属上，用户被指去查错方向）
// ② 三向纪律：
//    · source ⇒ 插件（插件取流失败/空列表）
//    · proxy / timeout ⇒ 服务·网络（**我们自己**的代理那一段，不许推给插件）
//    · decode ⇒ 播放器；permission ⇒ **说不清**（不冒认）
// ③ 徽标真的上屏：构造真 PlaybackFailure ⇒ 真 `_ErrorOverlay` 渲染出
//    owner.label，且**顺序**在 headline 之后、正文之前（分诊要在细节前）
// ④ 没归类（failure == null）⇒ **不画归属**（不许猜）
// ⑤ 文案门禁：label 里不许出现开发用语 / 内部地址 / 端口
// ```
//
// # 为什么"归属错了比不显示更糟"
// ```text
// 计划 N5b 明文纪律。若把 proxy 判成插件，用户会去换源（无效方向）；
// 若把 permission 判成播放器，用户会去查 libmpv（更无效）。
// ⇒ 每条断言都带 **禁止落档** 的反向判据（不只是"等于某个值"）。
// ```

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/sourin_api.dart';

void main() {
  group('① 映射表：九档逐档（漏一档 = 那一档会悄悄错档）', () {
    test('★★★ 每一档都必须有明确归属，且与下表逐档一致', () {
      const expected = <PlaybackFailureKind, PlaybackFailureOwner>{
        PlaybackFailureKind.source: PlaybackFailureOwner.plugin,
        PlaybackFailureKind.proxy: PlaybackFailureOwner.service,
        PlaybackFailureKind.timeout: PlaybackFailureOwner.service,
        PlaybackFailureKind.decode: PlaybackFailureOwner.player,
        PlaybackFailureKind.permission: PlaybackFailureOwner.unknown,
        PlaybackFailureKind.network: PlaybackFailureOwner.remote,
        // N-23018：分享的文件已不存在 = 网盘/分享侧的内容现实（插件如实转述）
        PlaybackFailureKind.shareFileGone: PlaybackFailureOwner.unknown,
        // N-23018 v2：临时转存副本被去重卡住 = 我们发起的清理与网盘处理的交互
        PlaybackFailureKind.tempCopyStuck: PlaybackFailureOwner.service,
        PlaybackFailureKind.unknown: PlaybackFailureOwner.unknown,
      };

      // ★★★ 先钉住"档数没变"：将来谁加了第八档而忘了加映射，
      //     这条立刻红 —— 否则新档会静默落进默认分支。
      expect(
        expected.length,
        PlaybackFailureKind.values.length,
        reason: '★★★ 映射表必须覆盖**全部**档位：新增档位时忘了加映射，'
            '用户看到的归属就是错的（或缺失）。'
            '当前映射 ${expected.length} 档 / 枚举 ${PlaybackFailureKind.values.length} 档',
      );

      for (final k in PlaybackFailureKind.values) {
        expect(expected.containsKey(k), isTrue,
            reason: '★ 档位 $k 没有归属 —— 必须显式表态，不许靠默认值');
        expect(ownerOf(k), expected[k],
            reason: '★ $k 的归属错了');
      }
    });
  });

  group('② 三向纪律（每条都带反向判据：禁止落错档）', () {
    test('★★★ source 必须是插件，**不许**被判成服务层（"取不到就赖自己"）', () {
      expect(ownerOf(PlaybackFailureKind.source), PlaybackFailureOwner.plugin);
      expect(ownerOf(PlaybackFailureKind.source),
          isNot(PlaybackFailureOwner.service),
          reason: '★★★ source 是**插件真实取流失败** —— 判成服务层等于'
              '把插件的锅背在自己身上，用户就不会去换源');
    });

    test('★★★ proxy / timeout 必须是服务层，**不许**被判成插件（旧08 的核心教训）', () {
      for (final k in <PlaybackFailureKind>[
        PlaybackFailureKind.proxy,
        PlaybackFailureKind.timeout,
      ]) {
        expect(ownerOf(k), PlaybackFailureOwner.service, reason: '★ $k 归属错');
        expect(ownerOf(k), isNot(PlaybackFailureOwner.plugin),
            reason: '★★★ $k 发生在**内置代理**那一段（环回地址被拒 / 等太久）'
                '—— 推给插件会让用户去换一个本来没问题的源。'
                '这正是旧08「不要把代理的问题说成插件的问题」的延续');
      }
    });

    test('★★ decode ⇒ 播放器；permission ⇒ 说不清（不冒认）', () {
      expect(ownerOf(PlaybackFailureKind.decode), PlaybackFailureOwner.player,
          reason: '★ 取到流但本机解不了 ⇒ 就是播放器（libmpv）这一侧');
      expect(ownerOf(PlaybackFailureKind.permission),
          PlaybackFailureOwner.unknown,
          reason: '★★ 源站要会员/地区限制 —— **不是**播放器的错，'
              '也**不是**插件的错（插件如实转述了源站的拒绝）。'
              '判成 plugin 会冤枉插件、判成 player 会把用户引去查解码器，'
              '⇒ 如实说"说不清"是唯一不误导的选项');
      expect(ownerOf(PlaybackFailureKind.permission),
          isNot(PlaybackFailureOwner.player));
      expect(ownerOf(PlaybackFailureKind.permission),
          isNot(PlaybackFailureOwner.plugin));
    });

    test('★★ network ⇒ 源站；unknown ⇒ 说不清（不许被"就近归入"某侧）', () {
      expect(ownerOf(PlaybackFailureKind.network), PlaybackFailureOwner.remote);
      expect(ownerOf(PlaybackFailureKind.unknown),
          PlaybackFailureOwner.unknown);
    });

    test('★★ shareFileGone（N-23018）⇒ 说不清（不冒认，permission 同款纪律）', () {
      expect(ownerOf(PlaybackFailureKind.shareFileGone),
          PlaybackFailureOwner.unknown,
          reason: '★ 文件在网盘/分享侧没了 —— 插件只是如实转述，'
              '判成 plugin 冤枉插件、判成 player 引去查解码器，'
              '判成 service 更是八竿子打不着 ⇒ 如实说"说不清"');
      expect(ownerOf(PlaybackFailureKind.shareFileGone),
          isNot(PlaybackFailureOwner.plugin));
      expect(ownerOf(PlaybackFailureKind.shareFileGone),
          isNot(PlaybackFailureOwner.service));
      expect(ownerOf(PlaybackFailureKind.shareFileGone),
          isNot(PlaybackFailureOwner.player));
    });

    test('★★★ tempCopyStuck（N-23018 v2）⇒ service（认在自己头上）', () {
      // 与 shareFileGone 相反：卡住是**我们发起的清理**与网盘处理交互所致
      // （purge 异步删除 + save 同名去重）⇒ 判成 unknown 会让用户以为
      // 谁都没办法，而"稍后重试"恰好是宿主这层能等好的。
      expect(ownerOf(PlaybackFailureKind.tempCopyStuck),
          PlaybackFailureOwner.service,
          reason: '★ 卡住源自宿主的 purge/自愈交互 —— service 认账，'
              '用户才知道"等一等/重试"是有效动作');
      expect(ownerOf(PlaybackFailureKind.tempCopyStuck),
          isNot(PlaybackFailureOwner.plugin),
          reason: '★ 插件只是取流，去重卡住与它无关');
      expect(ownerOf(PlaybackFailureKind.tempCopyStuck),
          isNot(PlaybackFailureOwner.unknown),
          reason: '★ 这不是"说不清"——成因明确在宿主这层');
    });
  });

  group('③ 文案（用户可见）', () {
    test('★★★ 五个 label 全部非空、互不相同、不含开发用语', () {
      final labels = <PlaybackFailureOwner, String>{
        for (final o in PlaybackFailureOwner.values) o: o.label,
      };

      for (final e in labels.entries) {
        expect(e.value.trim(), isNotEmpty, reason: '${e.key} 的文案不许为空');
      }
      expect(labels.values.toSet().length, PlaybackFailureOwner.values.length,
          reason: '★★ 五个归属的文案必须互不相同 —— '
              '两个归属显示同一句话，用户根本分不出是谁的问题');

      // ★ 开发用语 / 内部实现（AGENTS §4 + 本仓既有文案门禁同款）
      final banned = <RegExp>[
        RegExp(r'libmpv|mpv\b'),
        RegExp(r'127\.0\.0\.1|localhost'),
        RegExp(r':\d{4,}'), // 端口
        RegExp(r'null|Exception'), // 空值/异常类名漏出来
        RegExp(r'代理'), // ⚠️ 内部组件名（旧08 timeout 档同款禁令）
      ];
      for (final e in labels.entries) {
        for (final re in banned) {
          expect(re.hasMatch(e.value), isFalse,
              reason: '★★ 用户可见文案「${e.value}」命中了内部术语 ${re.pattern} '
                  '—— 用户看不懂，且会误导排查方向');
        }
      }
    });

    test('★ 归属文案要能回答"该找谁"，因此必须点名一个主体', () {
      // 每个 label 都要出现"插件/播放器/服务/网络/源站/说不清"之一，
      // 否则它就是一句无信息量的空话。
      final subjects = <RegExp>[
        RegExp(r'插件'),
        RegExp(r'播放器'),
        RegExp(r'服务|网络'),
        RegExp(r'源站'),
        RegExp(r'说不清'),
      ];
      for (final o in PlaybackFailureOwner.values) {
        expect(subjects.any((re) => re.hasMatch(o.label)), isTrue,
            reason: '★ 「${o.label}」没有点名任何主体 —— 用户读完还是不知道找谁');
      }
    });
  });

  group('④ PlaybackFailure 上的 owner 快捷方式', () {
    test('★★ 由 kind 推出 owner（不是另存一份、也就不会漂移）', () {
      const f = PlaybackFailure(
        kind: PlaybackFailureKind.proxy,
        detail: '这一条流取不到',
      );
      expect(f.owner, PlaybackFailureOwner.service,
          reason: '★ owner 必须由 kind 推出来 —— 若哪天有人把 owner 存成'
              '独立字段，两份就会漂移（本仓铁律：判据只有一个来源）');
    });
  });
}