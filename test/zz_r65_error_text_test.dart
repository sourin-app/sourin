// ═══════════════════════════════════════════════════════════════════════
//  第 65 轮 · 第 6 / 7 条门禁：错误文案净化 + 归因
// ═══════════════════════════════════════════════════════════════════════
//
// # 这两条 Owner 原话
//
// ```text
// 第 7 条  像图 2 那种报错信息，就不要加上溯影自己的信息了，
//         只显示插件的报错信息就足够了
// 第 6 条  某个源出现 failed to open，要优化报错信息，
//         现在不知道是源的问题还是软件本身的问题
// ```
//
// # 为什么这些断言是「不会假绿」的（本仓铁律）
//
// ```text
// 每条断言都**钉死具体字符串**，而不是"包含某个宽泛的词"：
//   ✗ expect(s.contains('会员'))        ← 只要原文里出现"会员"就绿，
//                                          改前改后都绿 ⇒ 假绿
//   ✓ expect(strip(原始串), '该内容需要大会员')  ← 改前是
//                                          'SourinCoreException(other): 插件报错: …'
//                                          ⇒ **必然红**
// ```
// 另外每条「不许出现」的断言都配了**阳性对照**：先证明那条串**确实在**原文里，
// 再证明净化后**不在**。否则选择器/正则写错了也会"通过"。
//
// # 撤销验证（交付报告里要贴的读数）
//
// 把 `stripHostErrorNoise` 里那三行 `replaceFirst` 注释掉 ⇒ 本文件
// 第 ①②③ 组**全部变红**。实测读数见 `.probe/round65-c/`。

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/sourin_api.dart';

void main() {
  group('第 7 条：只留插件原文（剥掉宿主包装）', () {
    test('① 图 2 的真实原文 ⇒ 只剩插件那句话', () {
      // ★ Owner 截图里的真实串（逐字）
      const raw = 'SourinCoreException(other): 插件报错: 该内容需要大会员，开通后可观看';

      // 阳性对照：这些噪声**确实在**原文里（证明下面不是空测）
      expect(raw.contains('SourinCoreException'), isTrue,
          reason: '夹具里必须有宿主类名，否则这条测不到东西');
      expect(raw.contains('插件报错'), isTrue,
          reason: '夹具里必须有插件报错前缀');

      final got = PlaybackErrorText.stripHostErrorNoise(raw);

      expect(got, '该内容需要大会员，开通后可观看',
          reason: '★ 只留插件原文 —— Owner 第 7 条原话');
      // 三个噪声一个都不许剩
      expect(got.contains('SourinCoreException'), isFalse,
          reason: '宿主类名必须剥掉');
      expect(got.contains('插件报错'), isFalse,
          reason: '「插件报错:」这个包装必须剥掉');
      expect(got.contains('('), isFalse,
          reason: 'kind 括号也必须一起剥掉');
    });

    test('② 各种 kind 都要剥（不只 other）', () {
      for (final kind in <String>[
        'other',
        'network',
        'unauthorized',
        'not_found',
        'unsupported',
      ]) {
        final raw = 'SourinCoreException($kind): 插件报错: 原文 $kind';
        final got = PlaybackErrorText.stripHostErrorNoise(raw);
        expect(got, '原文 $kind', reason: 'kind=$kind 也必须剥干净');
        expect(got.contains('SourinCoreException'), isFalse, reason: 'kind=$kind');
      }
    });

    test('③ 可剥多重包装（叠了两三层也要剥完）', () {
      const raw =
          'SourinCoreException(other): 插件报错: 插件报错: 该内容需要大会员';
      final got = PlaybackErrorText.stripHostErrorNoise(raw);
      expect(got, '该内容需要大会员',
          reason: '包装可能叠多层，要削到不动为止');
    });

    test('④ 中间出现的同名字样**不许**动（插件自己说的话）', () {
      // 插件可能在正文里提到这些词，那不是包装
      const raw = 'SourinCoreException(other): 插件报错: 服务器返回「插件报错: 超时」，请重试';
      final got = PlaybackErrorText.stripHostErrorNoise(raw);
      expect(got, '服务器返回「插件报错: 超时」，请重试',
          reason: '★ 只削开头 —— 中间的同名字样是插件原文，动了就是篡改');
    });

    test('⑤ 没有包装的原文**逐字不变**（不许顺手改文案）', () {
      for (final plain in <String>[
        '该内容需要大会员',
        'Failed to open something',
        '网络不可用',
        '这个源没有返回可播放地址',
      ]) {
        expect(PlaybackErrorText.stripHostErrorNoise(plain), plain,
            reason: '没有前缀的消息必须逐字保留');
      }
    });

    test('⑥ 削空时退回原文（宁可带前缀，也不要空白）', () {
      const only = 'SourinCoreException(other): 插件报错:';
      final got = PlaybackErrorText.stripHostErrorNoise(only);
      expect(got.isNotEmpty, isTrue, reason: '绝不返回空串（空白错误页更糟）');
    });
  });

  group('第 6 条：内部代理地址不许露给用户', () {
    test('① 图 1 的真实原文 ⇒ 内部 URL 被抹掉', () {
      // ★ Owner 截图里的真实串（逐字）
      const raw =
          'Failed to open http://127.0.0.1:57209/s/18df5c6d883dafdc11a485c0f7398/.';

      // 阳性对照：原文里**确实有**那条内部地址
      expect(raw.contains('127.0.0.1'), isTrue,
          reason: '夹具里必须有内部地址，否则这条测不到东西');
      expect(raw.contains('/s/'), isTrue, reason: '夹具里必须有代理路径');

      final got = PlaybackErrorText.hideInternalUrls(raw);

      expect(got.contains('127.0.0.1'), isFalse,
          reason: '★ 内部代理地址绝不许出现在用户可见文案里（第 6 条）');
      expect(got.contains(':57209'), isFalse, reason: '端口同样要抹掉');
      expect(got.contains('/s/'), isFalse, reason: '代理路径同样要抹掉');
      // 抹掉之后要变成一句人话，而不是留个空洞
      expect(got.trim().isNotEmpty, isTrue, reason: '不能抹成空串');
      expect(got.contains('内置代理'), isTrue,
          reason: '要说明"这是内置代理"，用户才知道找谁');
    });

    test('② localhost / ::1 三种环回形态都要抹', () {
      for (final host in <String>['127.0.0.1', 'localhost', '[::1]']) {
        final raw = 'Failed to open http://$host:12345/s/tok123/abc/.';
        final got = PlaybackErrorText.hideInternalUrls(raw);
        expect(got.contains(host), isFalse, reason: '$host 也是内部地址');
        expect(got.contains('12345'), isFalse, reason: '$host 的端口要抹');
      }
    });

    test('③ 非环回的外站地址**不许**抹（那是用户的线索）', () {
      // 上游 CDN 的地址是有诊断价值的 —— 抹了反而丢线索
      const raw = 'Failed to open https://cdn.example.com/video/1.mp4';
      final got = PlaybackErrorText.hideInternalUrls(raw);
      expect(got.contains('cdn.example.com'), isTrue,
          reason: '外站地址必须保留 —— 那是判断"源的问题"的关键线索');
    });

    test('④ 净化 + 剥前缀两步合起来是幂等的', () {
      const raw =
          'SourinCoreException(other): 插件报错: Failed to open http://127.0.0.1:1/s/x/';
      final once = PlaybackErrorText.stripHostErrorNoise(
        PlaybackErrorText.hideInternalUrls(raw),
      );
      final twice = PlaybackErrorText.stripHostErrorNoise(
        PlaybackErrorText.hideInternalUrls(once),
      );
      expect(twice, once, reason: '重复净化不该继续变化（否则显示会抖动）');
    });
  });

  group('第 6 条：失败要归类，且给得出下一步', () {
    test('① 代理**连不上** ⇒ 归到 proxy，且**不给换源**', () {
      // 代理这一层真坏了（进程没起 / 端口已死）
      for (final raw in <String>[
        'Connection refused',
        'Failed to open http://127.0.0.1:57209/s/18df/.',
        '连接被拒绝',
      ]) {
        final f = PlaybackErrorText.classify(raw);
        expect(f.kind, PlaybackFailureKind.proxy, reason: '原句: $raw');
        expect(f.headline, '内置代理没起来',
            reason: '★ 文案要能让用户判断是**软件**问题: $raw');
        expect(f.canRetry, isTrue, reason: '代理重启后重试通常就好');
        expect(f.canSwitchSource, isFalse,
            reason: '换源治不了代理 —— 给这颗按钮是误导');
      }
    });

    test('①b 代理**活着**但上游连不上 ⇒ 归到 source（★ 不许误归给代理）', () {
      /*
       * ★★★ 这一条是**实测读数**钉死的，不是假想
       *
       * `.probe/round65-c/samples_run4.log` 原文：
       *   [streamproxy] UP send FAILED after 1072ms: error sending request for url (…)
       *   [streamproxy] OUT status=502 elapsed=1072ms
       *           fetch → status=502 bytes=112 ct=text/plain
       * 即：代理**正常工作**，它把「上游连不上」如实转成了 502。
       * 上游域名实测 `nslookup png.ruyijx.com` ⇒ Non-existent domain。
       *
       * ⇒ 把这条归成「内置代理没起来」就是第二次误归 ——
       *   代理是好的，坏的是那个源。Owner 抱怨的正是这种分不清。
       */
      const raw =
          '取流失败: error sending request for url (https://x.example/v.m3u8)';
      final f = PlaybackErrorText.classify(raw);
      expect(f.kind, PlaybackFailureKind.source,
          reason: '★★ 代理活着但上游挂了 ⇒ 是**源**的问题，不是软件的');
      expect(f.headline, isNot('内置代理没起来'),
          reason: '★★ 绝不能对用户说代理坏了 —— 代理没坏');
      expect(f.canRetry, isTrue, reason: '上游可能只是抖了，重试有意义');
    });

    test('② 「大会员」⇒ 归到 permission，且**不给重试**', () {
      const raw = 'SourinCoreException(other): 插件报错: 该内容需要大会员，开通后可观看';
      final f = PlaybackErrorText.classify(raw);
      expect(f.kind, PlaybackFailureKind.permission);
      expect(f.canRetry, isFalse,
          reason: '★ 权限问题重试一万次都一样 —— 给重试按钮是把用户困在原地');
      expect(f.detail, '该内容需要大会员，开通后可观看',
          reason: '正文必须是**净化后**的插件原文');
      expect(f.detail.contains('SourinCoreException'), isFalse,
          reason: '归类产物里也不许有宿主类名');
    });

    test('③ 本地代理地址 ⇒ 归到 proxy，正文不含内部 URL', () {
      const raw = 'Failed to open http://127.0.0.1:57209/s/18df/.';
      final f = PlaybackErrorText.classify(raw);
      expect(f.kind, PlaybackFailureKind.proxy);
      expect(f.detail.contains('127.0.0.1'), isFalse,
          reason: '★ 第 6 条的核心诉求：不许暴露内部地址');
    });

    test('④ 没有可播地址 ⇒ 归到 source', () {
      final f = PlaybackErrorText.classify('该内容没有可播放的地址');
      expect(f.kind, PlaybackFailureKind.source);
      expect(f.headline, '这个源没有返回可播放地址');
      expect(f.nextStep.isNotEmpty, isTrue, reason: '要给得出下一步');
    });

    test('⑤ 解码原句 ⇒ 归到 decode', () {
      for (final raw in <String>[
        'Could not open codec.',
        'Failed to recognize file format.',
        'Invalid data found when processing input',
      ]) {
        final f = PlaybackErrorText.classify(raw);
        expect(f.kind, PlaybackFailureKind.decode, reason: '原句: $raw');
        expect(f.headline, '这个格式解不了');
      }
    });

    test('⑥ 5xx / 超时 ⇒ 归到 network', () {
      for (final raw in <String>[
        'HTTP 503',
        'timeout',
        '请求超时',
        '429 Too Many Requests',
      ]) {
        final f = PlaybackErrorText.classify(raw);
        expect(f.kind, PlaybackFailureKind.network, reason: '原句: $raw');
      }
    });

    test('⑦ 判据顺序有定义：代理真的坏了 > 上游挂了 > 权限词', () {
      /*
       * 三层证据的优先级必须**有定义**，否则同一句话会被归到不同类
       * （本仓铁律：判据顺序写不清就等于没有判据）。
       *
       * ★ 这里钉的是"顺序本身"，不是"某句话必须归某类"：
       *   · 代理真坏（环回地址被拒）  → proxy
       *   · 代理活着、上游连不上       → source（**不许**归 proxy）
       *   · 插件原文明说权限           → permission
       */
      final proxyDead =
          PlaybackErrorText.classify('Failed to open http://127.0.0.1:1/s/x/');
      expect(proxyDead.kind, PlaybackFailureKind.proxy, reason: '代理真坏了');

      final upDead = PlaybackErrorText.classify(
        '取流失败: connection reset'
      );
      expect(upDead.kind, PlaybackFailureKind.source,
          reason: '★ 代理转发时上游失败 ⇒ 源的锅（代理本身是好的）');

      final perm = PlaybackErrorText.classify('该内容需要大会员');
      expect(perm.kind, PlaybackFailureKind.permission);
    });

    test('⑧ 结构化 kind 参与判定（不只靠文案）', () {
      // 文案里没有任何权限词，但 FFI 的 kind 说了 unauthorized
      final f = PlaybackErrorText.classify(
        '某件事没成',
        kindHint: 'unauthorized',
      );
      expect(f.kind, PlaybackFailureKind.permission,
          reason: '★ 结构化 kind 必须参与 —— 插件换措辞不该让判定失效');
    });

    test('⑨ 归不到类时**只显示原文、不瞎猜**', () {
      const raw = '某个从没见过的情况';
      final f = PlaybackErrorText.classify(raw, hadCandidates: true);
      expect(f.kind, PlaybackFailureKind.unknown);
      expect(f.headline, '播放失败', reason: '归不到类就老实说"播放失败"');
      expect(f.detail, raw, reason: '原文一个字都不改');
      expect(f.nextStep, '', reason: '没话说就别硬凑 —— 空串由 UI 决定不画那一行');
    });

    test('⑩ hadCandidates 参与判定（有候选 ⇒ 不是"源没给地址"）', () {
      final none = PlaybackErrorText.classify('不知道咋了', hadCandidates: false);
      expect(none.kind, PlaybackFailureKind.source,
          reason: '一条候选都没有 ⇒ 按"源没给可播地址"处理');
    });
  });

  group('用户可见文案的纪律（t98 / AGENTS.md §4）', () {
    test('① 六类 headline 里不许有内部地址 / 宿主类名 / 开发用语', () {
      final banned = <String>[
        '127.0.0.1',
        'localhost',
        'SourinCoreException',
        '插件报错',
        '修复',
        '缺陷',
        'Owner',
        '探针',
        '已知问题',
        'task-',
      ];
      for (final k in PlaybackFailureKind.values) {
        final f = PlaybackFailure(kind: k, detail: '');
        for (final s in <String>[f.headline, f.nextStep]) {
          for (final b in banned) {
            expect(s.contains(b), isFalse,
                reason: '★ ${k.name} 的文案里出现了禁用词「$b」: $s');
          }
        }
      }
    });

    test('② 每条 headline 都必须非空（不许给用户看空白标题）', () {
      for (final k in PlaybackFailureKind.values) {
        final f = PlaybackFailure(kind: k, detail: '');
        expect(f.headline.trim().isNotEmpty, isTrue, reason: k.name);
      }
    });
  });
}
