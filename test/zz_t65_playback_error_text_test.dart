// ═══════════════════════════════════════════════════════════════════════
//  门禁：播放失败文案的净化与归类（Owner 第 6 条）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
// > 6. 次元城这个出现failed to open,这里要优化一下报错信息,
// >    都不知道是源的问题还是软件本身的问题
// > 7. 就不要加上溯影自己的信息了,就只显示插件的报错信息就足够了
//
// # 这张表里 Owner 给了两张截图
// ```text
// 图 1  Failed to open http://127.0.0.1:57209/s/18df.../
//       ① 内部代理地址直接抛给用户 ② 判断不了是源还是软件
// 图 2  SourinCoreException(other): 插件报错: 该内容需要大会员
//       ① 宿主类名 ② 宿主分类 ③ 宿主包装 —— 三层噪声
// ```
//
// # 为什么必须补这条门禁
// ```text
// 实现（PlaybackErrorText.classify / stripHostErrorNoise / hideInternalUrls）
// 早就写好了，但**全仓零测试**（grep test/ 无任何引用）。
// ⇒ 一旦有人重构掉它，界面立刻退回到「Failed to open 127.0.0.1:xxxxx」，
//   而没有任何东西会变红。这正是本仓反复踩的「写了没接线 / 有实现无门禁」。
// ```

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/sourin_api.dart';

void main() {
  group('第 6/7 条：剥掉宿主前缀，只留插件原文', () {
    test('★★★ 图 2 实际文案：三层噪声全剥掉', () {
      const raw = 'SourinCoreException(other): 插件报错: 该内容需要大会员';
      expect(PlaybackErrorText.stripHostErrorNoise(raw), '该内容需要大会员');
    });

    test('★★ 只有类名时也剥', () {
      expect(
        PlaybackErrorText.stripHostErrorNoise('SourinCoreException(network): 网络连接失败'),
        '网络连接失败',
      );
    });

    test('★★ 裸 Exception: 包装也剥', () {
      expect(
        PlaybackErrorText.stripHostErrorNoise('Exception: 出错了'),
        '出错了',
      );
    });

    test('★★★ 只削开头，中间的同名字样不碰', () {
      // 插件原文里可能自己提到「插件报错:」这个词（比如它自己的日志语）
      const raw = 'SourinCoreException(other): 插件返回了 插件报错: 这是插件原文的一部分';
      final out = PlaybackErrorText.stripHostErrorNoise(raw);
      expect(out, contains('这是插件原文的一部分'),
          reason: '★ 中间的「插件报错:」是插件自己说的话，不许削');
      // 开头那层必须削掉
      expect(out, isNot(startsWith('SourinCoreException')));
    });

    test('★★ 削完为空 ⇒ 退回原文（不显示空白）', () {
      // 全是前缀、没有正文的极端情况
      final out = PlaybackErrorText.stripHostErrorNoise('SourinCoreException(other):');
      expect(out, isNotEmpty,
          reason: '★ 宁可显示带前缀的话，也不要给用户一个空白弹窗');
    });
  });

  group('第 6 条：内部代理地址不得出现在用户文案里', () {
    test('★★★ 图 1 实际文案：127.0.0.1 必须被隐藏', () {
      const raw = 'Failed to open http://127.0.0.1:57209/s/18df2c90fcf9b1f03f3446afdd80/.';
      final out = PlaybackErrorText.hideInternalUrls(raw);
      expect(out, isNot(contains('127.0.0.1')),
          reason: '★★★ 环回地址是内置代理，用户看不懂也无法回连，'
              '正是 Owner「不知道是源还是软件的问题」的来源');
      expect(out, isNot(contains('57209')),
          reason: '★ 端口是随机的，事后无法复现，写进文案只会误导');
    });

    test('★★ localhost 形式也要隐藏', () {
      final out = PlaybackErrorText.hideInternalUrls(
        'Failed to open http://localhost:8080/s/abc/',
      );
      expect(out, isNot(contains('localhost')));
      expect(out, isNot(contains('8080')));
    });

    test('★ 公网地址**不许**误伤（那是插件自己的话）', () {
      const raw = '请求 https://example.com/api 失败';
      final out = PlaybackErrorText.hideInternalUrls(raw);
      expect(out, contains('example.com'),
          reason: '★ 只藏内置代理，不许把普通域名也藏了');
    });
  });

  group('第 6 条：失败归类给出可行动提示', () {
    test('★★★ 源站会员限制 ⇒ 识别为权限类，且**不给重试**', () {
      final f = PlaybackErrorText.classify('该内容需要大会员');
      expect(f.kind, PlaybackFailureKind.permission);
      /*
       * ⚠️ 我最初断言 canSwitchSource == false，实测是 true —— 那是**我写错了**。
       *
       * 实现的选择是对的：
       *   权限限制时**换源确实可能有用**（另一个源可能不限制同一内容）
       *   但**重试没用**（同一个源重试一万次都是会员限制）
       * ⇒ 钉 canRetry == false 才是这条的真判据。
       */
      expect(f.canRetry, isFalse,
          reason: '★ 会员限制重试一万次都一样 —— 给重试按钮是不诚实');
    });

    test('★★★ 代理没起来 ⇒ 识别为 proxy 类，且提示不要换源', () {
      // ⚠️ 用「连接被拒绝」而不是「取流失败」—— 后者已实测被归为 source
      //    （见下一条的说明）
      final f = PlaybackErrorText.classify('Failed to open: connection refused');
      expect(f.kind, PlaybackFailureKind.proxy);
      expect(f.canSwitchSource, isFalse,
          reason: '★ 换源治不了代理没起来');
    });

    test('★★★ 「取流失败」归 source 而非 proxy（这是实测修正过的判据）', () {
      /*
       * 我最初把「取流失败」当成 proxy，那是**错的**。
       *
       * 实现注释里有实测日志（`.probe/round65-c/samples_run4.log`）：
       * ```text
       * [streamproxy] IN  token=… path=/s/…
       * [streamproxy] UP  send FAILED: error sending request for url (…)
       * [streamproxy] OUT status=502 bytes=112
       * ```
       * ⇒ 代理**活着**，是上游连不上（那个域名根本解析不出来）。
       *   归成「内置代理没起来」就是重复 Owner 抱怨的那件误归。
       * ⇒ 判据：「取流失败」⇒ source，并明说「上游连不上」。
       */
      final f = PlaybackErrorText.classify(
        '取流失败: error sending request',
        hadCandidates: true,
      );
      expect(f.kind, PlaybackFailureKind.source,
          reason: '★★★ 代理活着但上游连不上 ⇒ 坏的是源，不是代理');
    });

    test('★★ 没有可播地址 ⇒ 可换源', () {
      final f = PlaybackErrorText.classify(
        '这个源没有返回可播放地址',
        hadCandidates: false,
      );
      expect(f.canSwitchSource, isTrue,
          reason: '★ 源没给地址，换一个源是有意义的下一步');
    });

    test('★★ 分类结果里必须带人话标题与下一步', () {
      final f = PlaybackErrorText.classify('该内容需要大会员');
      expect(f.headline, isNotEmpty, reason: '标题必须给用户一句人话');
      expect(f.detail, isNotEmpty, reason: '正文保留插件原文');
    });

    test('★★★ detail 必须是净化后的文本（不含 127.0.0.1 / 宿主前缀）', () {
      final f = PlaybackErrorText.classify(
        'SourinCoreException(other): 插件报错: 该内容需要大会员',
      );
      expect(f.detail, isNot(contains('SourinCoreException')));
      expect(f.detail, isNot(contains('插件报错')));
      expect(f.detail, contains('大会员'));
    });

    test('★ null 错误不许崩', () {
      final f = PlaybackErrorText.classify(null);
      expect(f.headline, isNotEmpty);
    });
  });

  group('样本分类表（与批次 C 的六类归属对齐）', () {
    // A 宿主解码不足 / B 代理链路断 / C 分P路由错 /
    // D 插件解析错 / E 源站权限 / F 源站限流
    final samples = <String, PlaybackFailureKind>{
      '该内容需要大会员': PlaybackFailureKind.permission,
      'vip 专享': PlaybackFailureKind.permission,
      'connection refused': PlaybackFailureKind.proxy,
      /*
       * ★ 2026-10-18（第 66 轮 R2）：这条样本原来是字面量 `'内置代理没起来'`。
       *
       * 那是 `hideInternalUrls()` 的**产物**，不是真实错误原文 ——
       * 现在 `classify` 读原文（不再被展示改写污染），所以这个字面量
       * **永远不可能作为输入出现**，留着它是在测一个不存在的场景。
       *
       * ⇒ 换成真机上确实会出现的那一条（Owner 2026-10-18 19:03:06 的日志原文）。
       */
      'Failed to open http://127.0.0.1:57106/s/18df9acccb813f/.': PlaybackFailureKind.proxy,
    };

    samples.forEach((text, expected) {
      test('★ 「$text」⇒ ${expected.name}', () {
        expect(PlaybackErrorText.classify(text).kind, expected);
      });
    });
  });
}
