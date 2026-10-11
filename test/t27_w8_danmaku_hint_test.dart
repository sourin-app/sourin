// ══════════════════════════════════════════════════════════════════════
//  T27-08（w8-hint）门禁：弹幕「没收到凭证」提示**按数据源事实**改写
// ══════════════════════════════════════════════════════════════════════
//
// # 业主原话
// > 8.弹弹play提示没获取到凭证
//
// # 本文件要证的一件事
// 提示的**内容**必须跟着真实数据源走，而不是永远一句「去官网免费申请」：
//   ① 本机弹弹play 在线 ⇒ 「检测到本机弹弹play，但当前数据源是官方 API」
//      + 一键「改用本机弹弹play」（本机源免签名，不申请任何凭证就能用）；
//   ② 本机不在线且没凭证 ⇒ 说清「在弹幕设置里选数据源：本机 / 官方」，
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
  group('① 本机弹弹play 在线：说清「本机可用、这次走的是官方」，并给一键改用', () {
    test('标题点出「检测到本机弹弹play」+「官方 API」', () {
      final h = DanmakuHint.of(missing403(), localOnline: true);
      expect(h, isNotNull);
      expect(h!.title, contains('本机弹弹play'));
      expect(h.title, contains('官方 API'),
          reason: '★ 只写「检测到本机」不够：得说清这次请求其实走了官方');
    });

    test('正文用 w5 的真源端口（不硬编码），且说明免申请', () {
      final h = DanmakuHint.of(missing403(), localOnline: true)!;
      expect(h.text, contains(DanmakuLocalService.hostPort),
          reason: '★★ 端口必须来自 w5 的 DanmakuLocalService.hostPort（真源）');
      expect(h.text, contains('不用申请任何凭证'),
          reason: '★ 本机源免签名 ⇒ 不许再让用户去申请凭证');
      expect(h.text, contains('AppId'));
      expect(h.text, contains('AppSecret'));
    });

    test('动作是「改用本机弹弹play」，带 useLocalDanmaku 开关', () {
      final h = DanmakuHint.of(missing403(), localOnline: true)!;
      expect(h.action, isNotNull);
      expect(h.action!.label, '改用本机弹弹play');
      expect(h.action!.useLocalDanmaku, isTrue,
          reason: '★ 宿主据此重建客户端并重取（player_page 的 _useLocalDanmakuSource）');
      expect(h.action!.openDanmakuSettings, isTrue,
          reason: '★ 面板仍要能打开：那里有「数据源」状态行与「重新获取弹幕」');
      expect(h.action!.openBiliSheet, isFalse);
    });
  });

  group('② 本机不在线且没凭证：改说「选数据源」，删掉「免费申请」', () {
    test('默认（不传 localOnline）就是这一态 —— 标题保持 t100 钉的那句', () {
      final h = DanmakuHint.of(missing403());
      expect(h, isNotNull);
      expect(h!.title, '弹幕服务没收到凭证',
          reason: '★ t100:534/551/608 逐字钉着这个标题，不许改');
      expect(h.title, isNot(contains('本机弹弹play')),
          reason: '★ 没探测到本机就不能说「检测到本机」');
    });

    test('正文说清两个数据源 + 保留 B 站这条路', () {
      final h = DanmakuHint.of(missing403(), localOnline: false)!;
      expect(h.text, contains('本机弹弹play'));
      expect(h.text, contains('官方 API'));
      expect(h.text, contains('AppId'));
      expect(h.text, contains('AppSecret'));
      expect(h.text, contains('弹幕设置'));
      expect(h.text, contains('哔哩哔哩弹幕'),
          reason: '★ t100:537 钉着：必须给「另一条路」');
    });

    test('★ 「免费申请」这种可能已过时的表述必须删干净', () {
      final h = DanmakuHint.of(missing403(), localOnline: false)!;
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

  group('③ 凭证填了但被拒：不许被数据源分支抢走', () {
    test('Invalid AppId ⇒ 「凭证没通过」+ 原文，与本地是否在线无关', () {
      for (final online in <bool>[false, true]) {
        final h = DanmakuHint.of(invalidAppId403(), localOnline: online)!;
        expect(h.title, '凭证没通过',
            reason: '★ 本地在线也不能把「凭证不对」改说成「改用本机」（online=$online）');
        expect(h.text, contains('Invalid AppId'), reason: '★ 服务端原文不许改写');
        expect(h.action!.openDanmakuSettings, isTrue);
        expect(h.action!.openBiliSheet, isFalse);
        expect(h.action!.useLocalDanmaku, isFalse);
      }
    });

    test('Invalid Signature 同上（t100:554-566 逐字钉着）', () {
      final h = DanmakuHint.of(invalidSignature403(), localOnline: true)!;
      expect(h.title, '凭证没通过');
      expect(h.text, contains('Invalid Signature'));
      expect(h.url, 'https://dev.dandanplay.com');
    });
  });

  group('④ 判不出来 ⇒ 一个字都不猜（本地在线也一样）', () {
    test('500 / 非 403 ⇒ null', () {
      expect(DanmakuHint.of(serverError()), isNull);
      expect(DanmakuHint.of(serverError(), localOnline: true), isNull);
      expect(DanmakuHint.of(DanmakuException('没认出 BV 号')), isNull);
    });
  });

  group('⑤ 源码钉：文案只出自 core 的真源，动作真接到宿主', () {
    test('core：三态判定读 localOnline，端口取自 DanmakuLocalService', () {
      final src = stripComments(File('lib/core/danmaku.dart').readAsStringSync());
      expect(src,
          contains('static DanmakuHint? of(DanmakuException e, {bool localOnline = false})'),
          reason: '★ 三态的输入就是「本机在线吗」这一个事实');
      expect(src, contains('DanmakuLocalService.hostPort'),
          reason: '★★ 端口必须是 w5 的真源，不许在文案里硬编码');
      expect(src, contains('useLocalDanmaku'));
    });

    test('core：DanmakuHint 区里不许再出现硬编码端口', () {
      final src = stripComments(File('lib/core/danmaku.dart').readAsStringSync());
      final idx = src.indexOf('class DanmakuHint {');
      expect(idx, isNonNegative);
      final region = src.substring(idx, src.indexOf('static DanmakuHint htmlPage'));
      expect(region.contains("'127.0.0.1:2080'"), isFalse,
          reason: '★ 端口只走 DanmakuLocalService.hostPort 一个真源');
    });

    test('host：动作开关真的接上（点了会重建客户端 + 重取）', () {
      final src = stripComments(File('lib/ui/player_page.dart').readAsStringSync());
      expect(src, contains('void _useLocalDanmakuSource()'),
          reason: '★ 动作必须有实现');
      expect(src, contains('if (a.useLocalDanmaku) _useLocalDanmakuSource();'),
          reason: '★ 开关必须被 _runDanmakuHintAction 消费');
      final i = src.indexOf('void _useLocalDanmakuSource()');
      final body = src.substring(i, src.indexOf('\n  }', i));
      expect(body, contains('_resetDanmakuClient()'),
          reason: '★★ 构造快照：不重建客户端的话，「改用本机」等于没改');
      expect(body, contains('_danmakuLocalStatus = null'),
          reason: '★ 重新探测（用户可能刚启动本机弹弹play）');
      expect(body, contains('_loadDanmaku()'));
    });

    test('host：面板里的 hint 也要按真实数据源重算（不只提示条）', () {
      final src = stripComments(File('lib/ui/player_page.dart').readAsStringSync());
      expect(src, contains('DanmakuHint.of(e, localOnline:'),
          reason: '★ 提示条与面板必须同一份判据');
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
   * 用户点「改用本机弹弹play」时会清缓存 —— 那一刻旧提示还在屏幕上，
   * 若判定现读缓存，标题会当场从「检测到本机弹弹play」跳回
   * 「没收到凭证」（刚点的按钮像是自己消失了）。所以事实必须**落快照**，
   * 且判定段里不许有 IO/await（探测是异步的，会把提示推到一个之后）。
   */
  group('⑥ 事实的时点：按「产生这条失败时」的读数判，不许重探', () {
    test('host：hint 用失败当时记下的事实（不读探测缓存）', () {
      final src = stripComments(File('lib/ui/player_page.dart').readAsStringSync());
      expect(src, contains('bool? _danmakuHintLocalOnline;'),
          reason: '★ 失败当时的事实要落一个字段');
      expect(src, contains('_danmakuHintLocalOnline = usingLocal;'),
          reason: '★ 写入点在 catch 里（= 本次请求真正用的源）');
      expect(src, contains('final localOnline = _danmakuHintLocalOnline ?? false;'),
          reason: '★ 判定读的是那份快照');
      expect(src, contains('? DanmakuHint.of(e, localOnline: localOnline)'),
          reason: '★ 提示条走这条判据');
    });

    test('host：判定路径里不许现探（纯同步；探测是 IO）', () {
      final src = stripComments(File('lib/ui/player_page.dart').readAsStringSync());
      final i = src.indexOf('final localOnline = _danmakuHintLocalOnline ?? false;');
      expect(i, isNonNegative);
      final region = src.substring(i, src.indexOf('_flash(', i));
      expect(region, isNot(contains('_ensureDanmakuLocalStatus')),
          reason: '★★ catch 块里现探会把提示推到一个异步之后，且读数可能已变');
      expect(region, isNot(contains('await')),
          reason: '★ 这一段必须是纯同步判定');
    });

    test('core：两态只由 localOnline 决定（一个事实开关）', () {
      final src = stripComments(File('lib/core/danmaku.dart').readAsStringSync());
      final i = src.indexOf(
          'static DanmakuHint? of(DanmakuException e, {bool localOnline = false})');
      final j = src.indexOf('final missing =', i);
      final region = src.substring(j, src.indexOf('return DanmakuHint(', j));
      expect(region, contains('if (localOnline)'),
          reason: '★ 只有「本机在线吗」这一个事实决定走哪一支');
    });
  });
}
