// ══════════════════════════════════════════════════════════════════════
//  T27-08（w8-hint）门禁：弹幕「没收到凭证」提示**按数据源事实**改写
// ══════════════════════════════════════════════════════════════════════
//
// # 业主原话
// > 8.弹弹play提示没获取到凭证
//
// # 本文件要证的一件事
// 提示的**内容**必须跟着真实数据源走，而不是永远一句「去官网免费申请」：
//   ① 本次请求**走的是本机弹弹play**、而本机回了 401/403
//      ⇒ 「本机弹弹play 拒绝了这次请求」+ 一键**改用官方 API**（换一条真正
//        不同的路）。★ T27-14 修：改前这一支写的是「检测到本机…但当前数据源
//        是官方 API」——**与事实相反**，且按钮「改用本机」点了还是打本机
//        ⇒ 死循环。判据也从「本机在不在线」改成「这次请求走了哪个源」。
//   ② 本次走的是官方、本机不在线且没凭证 ⇒ 说清「在弹幕设置里选数据源」，
//      并**删掉**「免费申请」这种可能已过时的表述；
//   ③ 凭证填了但被拒（Invalid AppId / Invalid Signature）⇒ 仍然是
//      「凭证没通过」，一个字都不许被数据源分支抢走（t100:554-566 钉着）。
//
// ⚠️ 端口只从 w5 的真源 DanmakuLocalService.hostPort 取（不硬编码），
//    本文件不复制 w5 的实现，只读它的常量。
// ══════════════════════════════════════════════════════════════════════

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/danmaku.dart';

// ── 造异常：逐字复刻 core/danmaku.dart `_decode` 的 403 分支 ──────────

/// 无凭证访问官方 API 的**真实**组合（X-Error-Message 原文）
DanmakuException missing403() => DanmakuException(
      '弹幕服务拒绝了这次请求：Missing Authentication Headers',
      statusCode: 403,
      xErrorMessage: 'Missing Authentication Headers',
      uri: 'https://api.dandanplay.net/api/v2/match',
    );

/// 凭证填了但 AppId 不对
DanmakuException invalidAppId403() => DanmakuException(
      '弹幕服务拒绝了这次请求：Invalid AppId',
      statusCode: 403,
      xErrorMessage: 'Invalid AppId',
    );

/// 凭证填了但签名不对
DanmakuException invalidSignature403() => DanmakuException(
      '弹幕服务拒绝了这次请求：Invalid Signature',
      statusCode: 403,
      xErrorMessage: 'Invalid Signature',
    );

/// 判不出类别（500）
DanmakuException serverError() => DanmakuException(
      '弹幕服务返回 HTTP 500',
      statusCode: 500,
    );

/// 把注释替换成空格（保留换行 ⇒ 行号不变）—— 静态审计用
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  var inLine = false;
  var inBlock = false;
  var inString = false;
  var quote = '';
  while (i < src.length) {
    final c = src[i];
    final n = i + 1 < src.length ? src[i + 1] : '';
    if (inLine) {
      if (c == '\n') {
        inLine = false;
        out.write(c);
      } else {
        out.write(' ');
      }
      i++;
      continue;
    }
    if (inBlock) {
      if (c == '*' && n == '/') {
        inBlock = false;
        out.write('  ');
        i += 2;
        continue;
      }
      out.write(c == '\n' ? c : ' ');
      i++;
      continue;
    }
    if (inString) {
      if (c == '\\') {
        out.write('  ');
        i += 2;
        continue;
      }
      if (c == quote) inString = false;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && n == '/') {
      inLine = true;
      out.write('  ');
      i += 2;
      continue;
    }
    if (c == '/' && n == '*') {
      inBlock = true;
      out.write('  ');
      i += 2;
      continue;
    }
    if (c == "'" || c == '"') {
      inString = true;
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

void main() {
  group('① 本次请求走了本机、本机却拒绝 ⇒ 如实说「本机拒绝」+ 改用官方 API', () {
    test('标题如实说「本机弹弹play 拒绝了这次请求」（不许写成走了官方）', () {
      final h = DanmakuHint.of(missing403(), usedLocalSource: true);
      expect(h, isNotNull);
      expect(h!.title, contains('本机外部弹幕'));
      expect(h.title, contains('拒绝'),
          reason: '★ 本次请求打的就是本机 ⇒ 必须说「本机拒绝了这次请求」');
      expect(h.title.contains('官方 API'), isFalse,
          reason: '★★ T27-14 红线：本次走的是**本机**，标题绝不能出现「官方 API」'
              '（改前那句「但当前数据源是官方 API」与事实相反）');
      expect(h.title.contains('检测到本机'), isFalse,
          reason: '★ 不是「检测到本机」，而是「本机拒绝了」——两者事实不同');
    });

    test('正文用 w5 的真源端口（不硬编码），并**如实**说本机免签名', () {
      final h = DanmakuHint.of(missing403(), usedLocalSource: true)!;
      expect(h.text, contains(DanmakuLocalService.hostPort),
          reason: '★★ 端口必须来自 w5 的 DanmakuLocalService.hostPort（真源）');
      expect(h.text, contains('免签名'),
          reason: '★ 本机源免签名 ⇒ 用它来解释「它不该 401/403」');
      expect(h.text, contains('AppId'));
      expect(h.text, contains('AppSecret'));
    });

    test('动作是「改用官方 API」，带 useOfficialDanmaku 开关（换真路，不死循环）', () {
      final h = DanmakuHint.of(missing403(), usedLocalSource: true)!;
      expect(h.action, isNotNull);
      expect(h.action!.label, '改用官方 API',
          reason: '★★ T27-14 红线：这次已经走本机 ⇒ 只有换官方才是真出路');
      expect(h.action!.useOfficialDanmaku, isTrue,
          reason: '★ 宿主据此粘住「强制官方」并重取（_useOfficialDanmakuSource）');
      expect(h.action!.useLocalDanmaku, isFalse,
          reason: '★★ 绝不能再给「改用本机」—— 点了还是打本机 ⇒ 死循环');
      expect(h.action!.openDanmakuSettings, isTrue,
          reason: '★ 面板仍要能打开：那里有「数据源」状态行与「重新获取弹幕」');
      expect(h.action!.openBiliSheet, isFalse);
    });
  });

  group('② 本机不在线且没凭证：改说「选数据源」，删掉「免费申请」', () {
    test('默认（不传 usedLocalSource）就是这一态 —— 标题保持 t100 钉的那句', () {
      final h = DanmakuHint.of(missing403());
      expect(h, isNotNull);
      expect(h!.title, '弹幕服务没收到凭证',
          reason: '★ t100:534/551/608 逐字钉着这个标题，不许改');
      expect(h.title, isNot(contains('本机外部弹幕')),
          reason: '★ 没探测到本机就不能说「检测到本机」');
    });

    test('正文说清两个数据源 + 保留 B 站这条路', () {
      final h = DanmakuHint.of(missing403(), usedLocalSource: false)!;
      expect(h.text, contains('本机外部弹幕'));
      expect(h.text, contains('官方 API'));
      expect(h.text, contains('AppId'));
      expect(h.text, contains('AppSecret'));
      expect(h.text, contains('弹幕设置'));
      expect(h.text, contains('外部视频源弹幕'),
          reason: '★ t100:537 钉着：必须给「另一条路」');
    });

    test('★ 「免费申请」这种可能已过时的表述必须删干净', () {
      final h = DanmakuHint.of(missing403(), usedLocalSource: false)!;
      expect(h.text.contains('免费申请'), isFalse,
          reason: '★★ 业主第 8 条的误导源头之一：本机弹弹play 根本不用申请');
      expect(h.text.contains('去官网'), isFalse);
    });

    test('官方地址与两个出口照旧（t100:538-543 的语义不变）', () {
      final h = DanmakuHint.of(missing403())!;
      expect(h.url, 'https://dev.dandanplay.com');
      expect(h.action!.label, '去弹幕设置');
      expect(h.action!.openDanmakuSettings, isTrue);
      expect(h.action!.openBiliSheet, isTrue);
      expect(h.action!.useLocalDanmaku, isFalse,
          reason: '★ 没探测到本机 ⇒ 不许给「改用本机」这个动作（点了也连不上）');
    });
  });

  /*
   * ══════════════════════════════════════════════════════════════════
   *  ★★★ CodeRabbit PR#5 N2：两条边都要有出路（出口不对称）
   * ══════════════════════════════════════════════════════════════════
   *
   * # 触发链（本文件逐条核实过）
   * ```text
   * ① 本机在线、本机回 403 ⇒ 提示【第 1 态】⇒ 用户点「改用官方 API」
   *    ⇒ 宿主置 _danmakuForceOfficial，usingLocal 变 false；
   * ② 官方（没凭证）也回 403 ⇒ usingLocal=false ⇒ 提示走【第 2 态】；
   * ③ 但第 2 态的动作只有 openDanmakuSettings / openBiliSheet，
   *    **没有**任何能清掉那颗粘性标记的入口 ⇒ 文案建议「选本机」，
   *    而面板里没有数据源切换控件 ⇒ 用户**无路可走**，本会话内每次重取
   *    都被钉在官方。A7 修好了「本机失败 ⇒ 改走官方」，却留下
   *    「官方失败 ⇒ 没有回头路」。
   * ```
   *
   * # 修法与判据
   * ```text
   * DanmakuHint.of(..., allowUseLocal: true) 时，第 2 态给
   * forceLocalDanmaku（宿主消费 = 重建客户端真换边，并清掉粘性标记）。
   * 置位条件是**真实读数**「本机在线、且用户确实点过『改用官方 API』
   * 并失败了」—— 不是「本机在不在线」，否则本机不在线时也会挂一颗
   * 点了必然连不上的死按钮（② 组正是在钉那条）。
   * ```
   *
   * # 阴性对照（撤销验证）
   * ```text
   * 把 `forceLocalDanmaku: allowUseLocal` 去掉（还原改前）
   * ⇒ ③e 变红（第 2 态没有任何换回本机的动作）。
   * ```
   */
  group('③e【N2】官方那条边也失败 ⇒ 第 2 态必须给「换回本机」的回头路', () {
    test('allowUseLocal=true ⇒ 动作里存在一个能换回本机的开关', () {
      final h = DanmakuHint.of(missing403(), allowUseLocal: true)!;
      expect(h.title, '弹幕服务没收到凭证',
          reason: '★ 标题仍与 t100:534/551/608 一致（改的是动作，不是标题）');
      expect(h.action, isNotNull);
      /*
       * ★★ 本组要证的核心：两条边都有出路。
       *    第 2 态的既有两个出口（设置面板 / B 站）**都不**能切回本机源，
       *    所以必须有一个真正换边的开关。
       */
      expect(
        h.action!.forceLocalDanmaku || h.action!.useLocalDanmaku,
        isTrue,
        reason: '★★ N2 红线：官方也失败时，动作里必须有能换回本机弹弹play 的入口 '
            '（否则文案建议「选本机」而用户没有入口）',
      );
      expect(h.action!.openDanmakuSettings, isTrue,
          reason: '★ 设置面板这个出口照旧保留（数据源状态行在那里）');
      expect(h.action!.openBiliSheet, isTrue,
          reason: '★ 改用 B 站这条路也照旧保留');
      expect(h.action!.useOfficialDanmaku, isFalse,
          reason: '★ 不能再给「改用官方」—— 本次走的就是官方，点了原样复现（又一个死循环）');
    });

    test('allowUseLocal=false（本机不在线）⇒ 一个字都不许加，仍是改前形态', () {
      final h = DanmakuHint.of(missing403())!;
      expect(h.action!.forceLocalDanmaku, isFalse,
          reason: '★★ 本机不在线时「改用本机」是一颗点了必然连不上的死按钮');
      expect(h.action!.useLocalDanmaku, isFalse);
      expect(h.action!.label, '去弹幕设置');
      expect(h.action!.openDanmakuSettings, isTrue);
      expect(h.action!.openBiliSheet, isTrue);
    });

    test('★ host：回头路真的接线了（forceLocalDanmaku 被消费 + 能清粘性标记）', () {
      final src = stripComments(File('lib/ui/player_page.dart').readAsStringSync());
      expect(src, contains('if (a.forceLocalDanmaku) _useLocalDanmakuSource();'),
          reason: '★★ 开关必须被 _runDanmakuHintAction 消费（只置不接线 = 假修）');
      // 回头路要真的能把「强制官方」掰回来
      final i = src.indexOf('void _useLocalDanmakuSource()');
      expect(i, isNonNegative);
      final body = src.substring(i, src.indexOf('\n  }', i));
      expect(body, contains('_danmakuForceOfficial = false'),
          reason: '★★ 换回本机必须清掉粘性「强制官方」（否则重取还是官方）');
    });

    test('★ host：allowUseLocal 的判据是「官方真的失败过」，不是「本机在线」', () {
      final src = stripComments(File('lib/ui/player_page.dart').readAsStringSync());
      // 判据来源：选路结果 —— 只有 localStatus.online && _danmakuForceOfficial
      // 时 usingLocal 才为 false（官方那条边真的被走过）
      expect(src, contains('_danmakuOfficialFailed = !usingLocal && localStatus.online;'),
          reason: '★★ 错误判据（本机在线）会在本机不在线时挂死按钮');
      expect(src, contains('allowUseLocal: _danmakuOfficialFailed,'),
          reason: '★ 提示条与面板必须用同一份判据');
    });
  });

  group('③ 凭证填了但被拒：不许被数据源分支抢走', () {    test('Invalid AppId ⇒ 「凭证没通过」+ 原文，与走的是哪个源无关', () {
      for (final usedLocal in <bool>[false, true]) {
        final h = DanmakuHint.of(invalidAppId403(), usedLocalSource: usedLocal)!;
        expect(h.title, '凭证没通过',
            reason: '★ 换源也不能把「凭证不对」改说成「改用本机/官方」（usedLocal=$usedLocal）');
        expect(h.text, contains('Invalid AppId'), reason: '★ 服务端原文不许改写');
        expect(h.action!.openDanmakuSettings, isTrue);
        expect(h.action!.openBiliSheet, isFalse);
        expect(h.action!.useLocalDanmaku, isFalse);
        expect(h.action!.useOfficialDanmaku, isFalse);
      }
    });

    test('Invalid Signature 同上（t100:554-566 逐字钉着）', () {
      final h = DanmakuHint.of(invalidSignature403(), usedLocalSource: true)!;
      expect(h.title, '凭证没通过');
      expect(h.text, contains('Invalid Signature'));
      expect(h.url, 'https://dev.dandanplay.com');
    });
  });

  group('④ 判不出来 ⇒ 一个字都不猜（走了本机也一样）', () {
    test('500 / 非 403 ⇒ null', () {
      expect(DanmakuHint.of(serverError()), isNull);
      expect(DanmakuHint.of(serverError(), usedLocalSource: true), isNull);
      expect(DanmakuHint.of(DanmakuException('没认出 BV 号')), isNull);
    });
  });

  group('⑤ 源码钉：文案只出自 core 的真源，动作真接到宿主', () {
    test('core：两态判定读 usedLocalSource，端口取自 DanmakuLocalService', () {
      final src = stripComments(File('lib/core/danmaku.dart').readAsStringSync());
      expect(
          src,
          contains('static DanmakuHint? of('),
          reason: '★ 解析函数存在');
      expect(src, contains('bool usedLocalSource = false'),
          reason: '★ T27-14：判据是「这次请求走了本机吗」（不是「本机在不在线」）');
      expect(src, contains('DanmakuLocalService.hostPort'),
          reason: '★★ 端口必须是 w5 的真源，不许在文案里硬编码');
      expect(src, contains('useLocalDanmaku'));
      expect(src, contains('useOfficialDanmaku'));
    });

    test('core：DanmakuHint 区里不许再出现硬编码端口', () {
      final src = stripComments(File('lib/core/danmaku.dart').readAsStringSync());
      // ★ 2026-10-17：不写死大括号（改 'class DanmakuHint{ ' 或加 implements 都会红）
      final idx = src.indexOf('class DanmakuHint');
      expect(idx, isNonNegative);
      final region = src.substring(idx, src.indexOf('static DanmakuHint htmlPage'));
      expect(region.contains("'127.0.0.1:2080'"), isFalse,
          reason: '★ 端口只走 DanmakuLocalService.hostPort 一个真源');
    });

    test('host：动作开关真的接上（改用本机 / 改用官方都会重建客户端 + 重取）', () {
      final src = stripComments(File('lib/ui/player_page.dart').readAsStringSync());
      expect(src, contains('void _useLocalDanmakuSource()'),
          reason: '★ 动作必须有实现');
      expect(src, contains('if (a.useLocalDanmaku) _useLocalDanmakuSource();'),
          reason: '★ 开关必须被 _runDanmakuHintAction 消费');
      expect(src, contains('void _useOfficialDanmakuSource()'),
          reason: '★ T27-14：改用官方也是一个真动作');
      expect(src, contains('if (a.useOfficialDanmaku) _useOfficialDanmakuSource();'),
          reason: '★ T27-14：开关必须被消费');
      final i = src.indexOf('void _useLocalDanmakuSource()');
      final body = src.substring(i, src.indexOf('\n  }', i));
      expect(body, contains('_resetDanmakuClient()'),
          reason: '★★ 构造快照：不重建客户端的话，「改用本机」等于没改');
      expect(body, contains('_danmakuLocalStatus = null'),
          reason: '★ 重新探测（用户可能刚启动本机弹弹play）');
      expect(body, contains('_loadDanmaku()'));
      final j = src.indexOf('void _useOfficialDanmakuSource()');
      final body2 = src.substring(j, src.indexOf('\n  }', j));
      expect(body2, contains('_danmakuForceOfficial = true'),
          reason: '★★ T27-14 红线：必须粘住「强制官方」，否则选了还是走本机 ⇒ 死循环');
      expect(body2, contains('_resetDanmakuClient()'));
      expect(body2, contains('_loadDanmaku()'));
    });

    test('host：选路**真的消费** _danmakuForceOfficial（否则按钮还是死循环）', () {
      final src = stripComments(File('lib/ui/player_page.dart').readAsStringSync());
      /*
       * ★★ 这是「不死循环」的证据链：`_useOfficialDanmakuSource` 置了标记，
       *    选路那一行必须**读它**。只置不读 = 标记是死的 ⇒ 重取又走本机
       *    ⇒ 401/403 原样复现 ⇒ 与改前的死循环**一模一样**。
       */
      expect(src, contains('final usingLocal = localStatus.online && !_danmakuForceOfficial;'),
          reason: '★★ 选路必须被强制标记掰到官方（只置标记不读 = 假修）');
      // 反向：用户点「改用本机」必须把标记清回来（否则从此永远回不去本机）
      final i = src.indexOf('void _useLocalDanmakuSource()');
      final body = src.substring(i, src.indexOf('\n  }', i));
      expect(body, contains('_danmakuForceOfficial = false'),
          reason: '★ 「改用本机」要能重置粘性标记，不然本机这条路被永久封死');
    });

    test('host：面板里的 hint 也要按真实数据源重算（不只提示条）', () {
      final src = stripComments(File('lib/ui/player_page.dart').readAsStringSync());
      expect(src, contains('DanmakuHint.of(e, allowUseLocal:'),
          reason: '★ 提示条与面板必须同一份判据');
      /*
       * ⚠️ N2 说明：本条原为 `contains('DanmakuHint.of(e, usedLocalSource:')`，
       *    那是**命名参数的书写顺序**（N2 给两处补了 allowUseLocal 参数，
       *    顺序随之调整）。判定意图（面板那份 hint 也按数据源重算）不变，
       *    仍由下面这条等价断言守住 —— 不降低任何行为要求。
       */
      expect(src, contains('usedLocalSource: usingLocal)'),
          reason: '★ 面板里的 hint 也按「本次走了哪个源」重算（不只提示条）');
      expect(src, contains('final h = (e.statusCode == 401 || e.statusCode == 403)'),
          reason: '★ 提示条也要按数据源重算（不只面板）');
    });
  });

  /*
   * ⑥ 为什么单独钉「事实的**时点**」
   *
   * 事实有两个来源，看起来等价、其实不等价：
   *   · `_danmakuLocalStatus`（w5 的探测缓存，可被清成 null 强制重探）；
   *   · 「产生这条失败时**真正用的**那个源」（`usingLocal`）。
   * 用户点「改用官方 API」时会清缓存 —— 那一刻旧提示还在屏幕上，
   * 若判定现读缓存，标题会当场变回「没收到凭证」（刚点的按钮像是自己消失了）。
   * 所以事实必须**落快照**，且判定段里不许有 IO/await（探测是异步的）。
   */
  group('⑥ 事实的时点：按「产生这条失败时」的读数判，不许重探', () {
    test('host：hint 用失败当时记下的事实（不读探测缓存）', () {
      final src = stripComments(File('lib/ui/player_page.dart').readAsStringSync());
      expect(src, contains('bool? _danmakuHintUsedLocalSource;'),
          reason: '★ 失败当时的事实要落一个字段');
      expect(src, contains('_danmakuHintUsedLocalSource = usingLocal;'),
          reason: '★ 写入点在 catch 里（= 本次请求真正用的源）');
      expect(src, contains('final usedLocalSource = _danmakuHintUsedLocalSource ?? false;'),
          reason: '★ 判定读的是那份快照');
      expect(src, contains('? DanmakuHint.of(e, allowUseLocal: _danmakuOfficialFailed,'),
          reason: '★ 提示条走这条判据');
      // ⚠️ N2：与⑤组同样的参数顺序调整 —— 判定意图不变，等价断言跟上。
      expect(src, contains('usedLocalSource: usedLocalSource)'),
          reason: '★ 提示条把「失败当时的事实」注入判据');
    });

    test('host：判定路径里不许现探（纯同步；探测是 IO）', () {
      final src = stripComments(File('lib/ui/player_page.dart').readAsStringSync());
      final i = src.indexOf('final usedLocalSource = _danmakuHintUsedLocalSource ?? false;');
      expect(i, isNonNegative);
      final region = src.substring(i, src.indexOf('_flash(', i));
      expect(region, isNot(contains('_ensureDanmakuLocalStatus')),
          reason: '★★ catch 块里现探会把提示推到一个异步之后，且读数可能已变');
      expect(region, isNot(contains('await')),
          reason: '★ 这一段必须是纯同步判定');
    });

    test('core：两态只由 usedLocalSource 决定（一个事实开关）', () {
      final src = stripComments(File('lib/core/danmaku.dart').readAsStringSync());
      final i = src.indexOf('bool usedLocalSource = false');
      expect(i, isNonNegative);
      final j = src.indexOf('final missing =', i);
      final region = src.substring(j, src.indexOf('return DanmakuHint(', j));
      expect(region, contains('if (usedLocalSource)'),
          reason: '★ 只有「这次走了本机吗」这一个事实决定走哪一支');
    });
  });
}
